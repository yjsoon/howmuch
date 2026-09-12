import { describe, expect, test } from "bun:test";
import {
  ApiError,
  api,
  BulkApprovalError,
  isWriteRequest,
  notifyLocalWrite,
  setLocalWriteHandler,
  setUnauthorizedHandler,
  shouldHandleUnauthorized,
} from "./client";

describe("speculative requests", () => {
  test("a 401 does not end the session when the caller decides for itself", async () => {
    const originalFetch = globalThis.fetch;
    let endedSessions = 0;
    setUnauthorizedHandler(() => { endedSessions += 1; });
    globalThis.fetch = (async () => new Response(
      JSON.stringify({ error: { name: "not_authorized", detail: "Invalid credentials" } }),
      { status: 401, headers: { "content-type": "application/json" } },
    )) as typeof fetch;
    try {
      await expect(api.plans({ handleUnauthorized: false })).rejects.toBeInstanceOf(ApiError);
      expect(endedSessions).toBe(0);
      await expect(api.plans()).rejects.toBeInstanceOf(ApiError);
      expect(endedSessions).toBe(1);
    } finally {
      globalThis.fetch = originalFetch;
      setUnauthorizedHandler(null);
    }
  });
});

describe("shouldHandleUnauthorized", () => {
  test("ignores auth-route failures and stale epochs after a new session starts", () => {
    expect(shouldHandleUnauthorized("/api/auth/login", 1, 1)).toBe(false);
    expect(shouldHandleUnauthorized("/api/auth/personal-tokens", 1, 1)).toBe(true);
    expect(shouldHandleUnauthorized(`/api/auth/personal-tokens/${"a".repeat(32)}`, 1, 1)).toBe(true);
    expect(shouldHandleUnauthorized("/v1/plans", 1, 1)).toBe(true);
    expect(shouldHandleUnauthorized("/v1/plans", 1, 2)).toBe(false);
    expect(shouldHandleUnauthorized("/api/auth/personal-tokens", 1, 2)).toBe(false);
  });

  test("uses cookie-authenticated personal token management endpoints", async () => {
    const originalFetch = globalThis.fetch;
    const requests: Array<{ path: string; init?: RequestInit }> = [];
    globalThis.fetch = (async (path: string | URL | Request, init?: RequestInit) => {
      requests.push({ path: String(path), init });
      const data = requests.length === 1
        ? { tokens: [{ id: "a".repeat(32), name: "CLI", created_at: 1, revoked_at: null }] }
        : requests.length === 2
          ? { token: { id: "b".repeat(32), name: "Server", created_at: 2, revoked_at: null }, value: "hm_pat_secret" }
          : { token: { id: "b".repeat(32), name: "Server", created_at: 2, revoked_at: 3 } };
      return new Response(JSON.stringify({ data }), { headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    try {
      expect(await api.personalApiTokens()).toHaveLength(1);
      expect((await api.createPersonalApiToken("Server")).value).toBe("hm_pat_secret");
      expect((await api.revokePersonalApiToken("b".repeat(32))).revoked_at).toBe(3);
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(requests.map((entry) => entry.path)).toEqual([
      "/api/auth/personal-tokens",
      "/api/auth/personal-tokens",
      `/api/auth/personal-tokens/${"b".repeat(32)}`,
    ]);
    expect(requests.map((entry) => entry.init?.method)).toEqual([undefined, "POST", "DELETE"]);
    expect(requests.every((entry) => entry.init?.credentials === "same-origin")).toBeTrue();
  });

  test("sends a compare-and-set request for cleared status changes", async () => {
    const originalFetch = globalThis.fetch;
    let captured: { path: string; init?: RequestInit } | null = null;
    globalThis.fetch = (async (path: string | URL | Request, init?: RequestInit) => {
      captured = { path: String(path), init };
      return new Response(JSON.stringify({ data: { transaction: { id: "txn-1", cleared: "cleared" } } }), {
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    try {
      expect((await api.updateTransactionCleared("plan-1", "txn-1", "uncleared", "cleared")).cleared).toBe("cleared");
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(captured).not.toBeNull();
    expect(captured!.path).toBe("/v1/plans/plan-1/transactions/txn-1/cleared");
    expect(captured!.init?.method).toBe("PATCH");
    expect(JSON.parse(String(captured!.init?.body))).toEqual({ expected_cleared: "uncleared", cleared: "cleared" });
  });

  test("creates a reward card with plan_id and the constructed card", async () => {
    const originalFetch = globalThis.fetch;
    let captured: { path: string; init?: RequestInit } | null = null;
    const card = {
      id: "card_native",
      name: "Native cashback",
      issuer: "UOB",
      type: "cashback" as const,
      ynabAccountId: "acct-native-card",
      featured: true,
      earningRate: 1,
    };
    globalThis.fetch = (async (path: string | URL | Request, init?: RequestInit) => {
      captured = { path: String(path), init };
      return new Response(JSON.stringify({ data: { card } }), {
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    try {
      expect(await api.createRewardCard("plan-1", card)).toEqual(card);
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(captured).not.toBeNull();
    expect(captured!.path).toBe("/api/rewards/cards");
    expect(captured!.init?.method).toBe("POST");
    expect(JSON.parse(String(captured!.init?.body))).toEqual({ plan_id: "plan-1", card });
  });

  test("patches a reward card by id", async () => {
    const originalFetch = globalThis.fetch;
    let captured: { path: string; init?: RequestInit } | null = null;
    const card = {
      id: "card_native",
      name: "Native cashback",
      issuer: "UOB",
      type: "cashback" as const,
      ynabAccountId: "acct-native-card",
      featured: true,
      earningRate: 2,
    };
    globalThis.fetch = (async (path: string | URL | Request, init?: RequestInit) => {
      captured = { path: String(path), init };
      return new Response(JSON.stringify({ data: { card } }), {
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    try {
      expect((await api.updateRewardCard("plan-1", "card_native", card)).earningRate).toBe(2);
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(captured).not.toBeNull();
    expect(captured!.path).toBe("/api/rewards/cards/card_native");
    expect(captured!.init?.method).toBe("PATCH");
    expect(JSON.parse(String(captured!.init?.body))).toEqual({ plan_id: "plan-1", card });
  });

  test("deletes a reward card by id", async () => {
    const originalFetch = globalThis.fetch;
    let captured: { path: string; init?: RequestInit } | null = null;
    globalThis.fetch = (async (path: string | URL | Request, init?: RequestInit) => {
      captured = { path: String(path), init };
      return new Response(JSON.stringify({ data: { card: { id: "card_native" } } }), {
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    try {
      expect((await api.deleteRewardCard("plan-1", "card_native")).id).toBe("card_native");
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(captured).not.toBeNull();
    expect(captured!.path).toBe("/api/rewards/cards/card_native");
    expect(captured!.init?.method).toBe("DELETE");
    expect(JSON.parse(String(captured!.init?.body))).toEqual({ plan_id: "plan-1" });
  });

  test("patches miles valuation on reward settings", async () => {
    const originalFetch = globalThis.fetch;
    let captured: { path: string; init?: RequestInit } | null = null;
    globalThis.fetch = (async (path: string | URL | Request, init?: RequestInit) => {
      captured = { path: String(path), init };
      return new Response(JSON.stringify({ data: { settings: { milesValuation: 0.04 } } }), {
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    try {
      expect((await api.updateRewardSettings("plan-1", { milesValuation: 0.04 })).milesValuation).toBe(0.04);
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(captured).not.toBeNull();
    expect(captured!.path).toBe("/api/rewards/settings");
    expect(captured!.init?.method).toBe("PATCH");
    expect(JSON.parse(String(captured!.init?.body))).toEqual({ plan_id: "plan-1", milesValuation: 0.04 });
  });

  test("treats account preferences as optional on an older server", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () => new Response(JSON.stringify({
      error: { name: "not_found", detail: "Route not found" },
    }), { status: 404, headers: { "content-type": "application/json" } })) as typeof fetch;
    try {
      expect(await api.accountPreferences("plan-1")).toBeNull();
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("reads the account preference revision and sends it in a compare-and-set write", async () => {
    const originalFetch = globalThis.fetch;
    const requests: Array<{ path: string; init?: RequestInit }> = [];
    const preferences = {
      favourite_account_ids: ["cash"],
      account_order: [],
      account_order_by_group: {},
      account_group_sorts: {},
      custom_account_groups: [],
    };
    globalThis.fetch = (async (path: string | URL | Request, init?: RequestInit) => {
      requests.push({ path: String(path), init });
      const revision = requests.length;
      return new Response(JSON.stringify({ data: {
        account_preferences: preferences,
        account_preferences_revision: revision,
      } }), { headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    try {
      expect(await api.accountPreferences("plan-1")).toEqual({
        account_preferences: preferences,
        account_preferences_revision: 1,
      });
      expect(await api.updateAccountPreferences("plan-1", preferences, 1)).toEqual({
        account_preferences: preferences,
        account_preferences_revision: 2,
      });
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(requests[1]!.path).toBe("/v1/plans/plan-1/account_preferences");
    expect(requests[1]!.init?.method).toBe("PUT");
    expect(JSON.parse(String(requests[1]!.init?.body))).toEqual({
      account_preferences: preferences,
      expected_revision: 1,
    });
  });
});

describe("approveTransactions", () => {
  test("sends 101 ids as sequential batches of 100 and 1", async () => {
    const originalFetch = globalThis.fetch;
    const requests: Array<{ path: string; init?: RequestInit }> = [];
    const mockFetch: typeof fetch = async (path, init) => {
      requests.push({ path: String(path), init });
      return new Response(JSON.stringify({ data: { transaction_ids: [] } }), {
        headers: { "content-type": "application/json" },
      });
    };
    globalThis.fetch = mockFetch;
    try {
      const ids = Array.from({ length: 101 }, (_, index) => `txn-${index}`);
      expect(await api.approveTransactions("plan-1", ids)).toEqual({ approvedCount: 101 });
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(requests.map((entry) => entry.path)).toEqual([
      "/v1/plans/plan-1/transactions",
      "/v1/plans/plan-1/transactions",
    ]);
    expect(requests.map((entry) => entry.init?.method)).toEqual(["PATCH", "PATCH"]);
    const firstBody = JSON.parse(String(requests[0]?.init?.body));
    const secondBody = JSON.parse(String(requests[1]?.init?.body));
    expect(firstBody.transactions).toHaveLength(100);
    expect(firstBody.transactions[0]).toEqual({ id: "txn-0", approved: true });
    expect(firstBody.transactions[99]).toEqual({ id: "txn-99", approved: true });
    expect(secondBody).toEqual({ transactions: [{ id: "txn-100", approved: true }] });
  });

  test("reports completed ids when a later batch fails", async () => {
    const originalFetch = globalThis.fetch;
    let requestCount = 0;
    const mockFetch: typeof fetch = async () => {
      requestCount += 1;
      if (requestCount === 1) {
        return new Response(JSON.stringify({ data: { transaction_ids: [] } }), {
          headers: { "content-type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ error: { detail: "write failed" } }), {
        status: 500,
        headers: { "content-type": "application/json" },
      });
    };
    globalThis.fetch = mockFetch;
    let caught: unknown;
    try {
      await api.approveTransactions(
        "plan-1",
        Array.from({ length: 101 }, (_, index) => `txn-${index}`),
      );
    } catch (cause) {
      caught = cause;
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(requestCount).toBe(2);
    expect(caught).toBeInstanceOf(BulkApprovalError);
    if (!(caught instanceof BulkApprovalError)) {
      throw new Error("Expected BulkApprovalError.");
    }
    expect(caught.approvedCount).toBe(100);
  });

  test("rejects an empty approval", async () => {
    await expect(api.approveTransactions("plan-1", [])).rejects.toThrow("must not be empty");
  });
});

describe("write invalidation", () => {
  test("classifies the verbs that change server state", () => {
    expect(isWriteRequest("POST")).toBe(true);
    expect(isWriteRequest("PATCH")).toBe(true);
    expect(isWriteRequest("put")).toBe(true);
    expect(isWriteRequest("DELETE")).toBe(true);
    expect(isWriteRequest("GET")).toBe(false);
    expect(isWriteRequest("HEAD")).toBe(false);
    // `fetch` defaults to GET, so an absent method is a read.
    expect(isWriteRequest(undefined)).toBe(false);
  });

  test("a successful write notifies the cache once; a read does not", async () => {
    const originalFetch = globalThis.fetch;
    let writes = 0;
    setLocalWriteHandler(() => { writes += 1; });
    globalThis.fetch = (async () => new Response(
      JSON.stringify({ data: { settings: {}, account: { id: "account-1" } } }),
      { status: 200, headers: { "content-type": "application/json" } },
    )) as typeof fetch;
    try {
      await api.settings("plan-1");
      expect(writes).toBe(0);
      await api.updateAccountIcon("plan-1", "account-1", "bank");
      expect(writes).toBe(1);
    } finally {
      globalThis.fetch = originalFetch;
      setLocalWriteHandler(null);
    }
  });

  test("a write rejected by the server still invalidates", async () => {
    // The server can commit and then fail to answer, so a non-2xx write is not
    // proof that nothing changed. Only one of the two possible answers is safe.
    const originalFetch = globalThis.fetch;
    let writes = 0;
    setLocalWriteHandler(() => { writes += 1; });
    globalThis.fetch = (async () => new Response(
      JSON.stringify({ error: { name: "conflict", detail: "Nope" } }),
      { status: 409, headers: { "content-type": "application/json" } },
    )) as typeof fetch;
    try {
      await expect(api.updateAccountIcon("plan-1", "account-1", "bank")).rejects.toThrow();
      expect(writes).toBe(1);
    } finally {
      globalThis.fetch = originalFetch;
      setLocalWriteHandler(null);
    }
  });

  test("a write whose request never completes still invalidates", async () => {
    const originalFetch = globalThis.fetch;
    let writes = 0;
    setLocalWriteHandler(() => { writes += 1; });
    globalThis.fetch = (async () => { throw new TypeError("Failed to fetch"); }) as typeof fetch;
    try {
      await expect(api.updateAccountIcon("plan-1", "account-1", "bank")).rejects.toThrow("Failed to fetch");
      expect(writes).toBe(1);
    } finally {
      globalThis.fetch = originalFetch;
      setLocalWriteHandler(null);
    }
  });

  test("a failed read never invalidates", async () => {
    const originalFetch = globalThis.fetch;
    let writes = 0;
    setLocalWriteHandler(() => { writes += 1; });
    globalThis.fetch = (async () => { throw new TypeError("Failed to fetch"); }) as typeof fetch;
    try {
      await expect(api.settings("plan-1")).rejects.toThrow("Failed to fetch");
      expect(writes).toBe(0);
    } finally {
      globalThis.fetch = originalFetch;
      setLocalWriteHandler(null);
    }
  });

  test("notifyLocalWrite covers writes that bypass the shared request path", async () => {
    let writes = 0;
    setLocalWriteHandler(() => { writes += 1; });
    try {
      notifyLocalWrite();
      expect(writes).toBe(1);
    } finally {
      setLocalWriteHandler(null);
    }
  });
});
