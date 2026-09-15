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

  test("fetches one parent transaction directly with its subtransactions", async () => {
    const originalFetch = globalThis.fetch;
    let capturedPath = "";
    globalThis.fetch = (async (path: string | URL | Request) => {
      capturedPath = String(path);
      return new Response(JSON.stringify({
        data: {
          transaction: {
            id: "txn/older",
            subtransactions: [{ id: "sub-1", amount: -5000 }],
          },
        },
      }), { headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    try {
      expect((await api.transaction("plan 1", "txn/older")).subtransactions?.[0]?.id).toBe("sub-1");
    } finally {
      globalThis.fetch = originalFetch;
    }
    expect(capturedPath).toBe("/v1/plans/plan%201/transactions/txn%2Folder");
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

describe("bulk transaction commands", () => {
  test("categorises through the collection PATCH in bounded chunks", async () => {
    const originalFetch = globalThis.fetch;
    const requests: Array<{ path: string; init?: RequestInit }> = [];
    globalThis.fetch = (async (path: string | URL | Request, init?: RequestInit) => {
      requests.push({ path: String(path), init });
      // The server echoes the rows it committed; a matching category confirms.
      const body = JSON.parse(String(init?.body)) as { transactions: Array<{ id: string; category_id: string | null }> };
      return new Response(JSON.stringify({ data: { transaction_ids: [], transactions: body.transactions } }), {
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    let summary;
    try {
      summary = await api.categoriseTransactions(
        "plan-1",
        Array.from({ length: 101 }, (_, index) => ({ id: `txn-${index}`, category_id: "food" })),
      );
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(summary).toMatchObject({ applied_count: 101, unresolved_count: 0, unattempted_count: 0 });
    expect(requests.map((entry) => entry.path)).toEqual([
      "/v1/plans/plan-1/transactions",
      "/v1/plans/plan-1/transactions",
    ]);
    expect(requests.map((entry) => entry.init?.method)).toEqual(["PATCH", "PATCH"]);
    const firstBody = JSON.parse(String(requests[0]?.init?.body));
    expect(firstBody.transactions).toHaveLength(100);
    expect(firstBody.transactions[0]).toEqual({ id: "txn-0", category_id: "food" });
    expect(JSON.parse(String(requests[1]?.init?.body)).transactions).toEqual([{ id: "txn-100", category_id: "food" }]);
  });

  test("marks a failed categorise chunk unresolved and never sends the rest", async () => {
    const originalFetch = globalThis.fetch;
    const requests: string[] = [];
    globalThis.fetch = (async (path: string | URL | Request) => {
      requests.push(String(path));
      return new Response(JSON.stringify({ error: { detail: "write failed" } }), {
        status: 500,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    let summary;
    try {
      summary = await api.categoriseTransactions(
        "plan-1",
        Array.from({ length: 101 }, (_, index) => ({ id: `txn-${index}`, category_id: "food" })),
      );
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(requests).toHaveLength(1);
    expect(summary).toMatchObject({ applied_count: 0, unresolved_count: 100, unattempted_count: 1 });
  });

  test("keeps the first chunk's rows applied when a later chunk fails", async () => {
    const originalFetch = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (async (_path: string | URL | Request, init?: RequestInit) => {
      calls += 1;
      if (calls === 1) {
        const body = JSON.parse(String(init?.body)) as { transactions: Array<{ id: string; category_id: string | null }> };
        return new Response(JSON.stringify({ data: { transaction_ids: [], transactions: body.transactions } }), {
          headers: { "content-type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ error: { detail: "write failed" } }), {
        status: 500,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    let summary;
    try {
      summary = await api.categoriseTransactions(
        "plan-1",
        Array.from({ length: 101 }, (_, index) => ({ id: `txn-${index}`, category_id: "food" })),
      );
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(calls).toBe(2);
    expect(summary).toMatchObject({ applied_count: 100, unresolved_count: 1, unattempted_count: 0 });
    expect(summary.outcomes[0]).toEqual({ id: "txn-0", status: "applied" });
    expect(summary.outcomes[100]).toMatchObject({ id: "txn-100", status: "unresolved" });
  });

  test("does not count a row the server normalised back to no category as applied", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (_path: string | URL | Request, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body)) as { transactions: Array<{ id: string; category_id: string | null }> };
      // The second row became a split parent on the server, so its category was dropped.
      const transactions = body.transactions.map((item) => (
        item.id === "txn-1" ? { id: item.id, category_id: null } : item
      ));
      return new Response(JSON.stringify({ data: { transaction_ids: [], transactions } }), {
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    let summary;
    try {
      summary = await api.categoriseTransactions("plan-1", [
        { id: "txn-0", category_id: "food" },
        { id: "txn-1", category_id: "food" },
      ]);
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(summary).toMatchObject({ applied_count: 1, conflict_count: 1, unresolved_count: 0 });
    expect(summary.outcomes).toEqual([
      { id: "txn-0", status: "applied" },
      { id: "txn-1", status: "conflict", detail: "The server did not apply this category" },
    ]);
  });

  test("treats a failed categorise chunk as unresolved even on 4xx", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () => new Response(
      JSON.stringify({ error: { detail: "one row was rejected" } }),
      { status: 400, headers: { "content-type": "application/json" } },
    )) as typeof fetch;
    let summary;
    try {
      summary = await api.categoriseTransactions("plan-1", [{ id: "a", category_id: "food" }, { id: "b", category_id: "food" }]);
    } finally {
      globalThis.fetch = originalFetch;
    }

    // The collection PATCH can commit an earlier row before a later
    // mutation-time rejection, so a 4xx is not proof that nothing was written.
    expect(summary).toMatchObject({ applied_count: 0, unresolved_count: 2, unattempted_count: 0 });
  });

  test("treats a 4xx rejection as unattempted because nothing was written", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () => new Response(
      JSON.stringify({ error: { detail: "bad request" } }),
      { status: 400, headers: { "content-type": "application/json" } },
    )) as typeof fetch;
    let summary;
    try {
      summary = await api.bulkDeleteTransactions("plan-1", [{ id: "a" }, { id: "b" }]);
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(summary).toMatchObject({ applied_count: 0, unresolved_count: 0, unattempted_count: 2 });
  });

  test("bulk cleared passes ordered outcomes through and stops when the server did", async () => {
    const originalFetch = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (async () => {
      calls += 1;
      const outcomes = Array.from({ length: 100 }, (_, index) => ({
        id: `t${index}`,
        status: index === 0 ? "applied" : index === 1 ? "unresolved" : "unattempted",
      }));
      return new Response(JSON.stringify({
        data: {
          outcomes,
          applied_count: 1,
          conflict_count: 0,
          already_removed_count: 0,
          unresolved_count: 1,
          unattempted_count: 98,
          server_knowledge: 5,
        },
      }), { headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    let summary;
    try {
      summary = await api.bulkClearedTransactions(
        "plan-1",
        Array.from({ length: 102 }, (_, index) => ({
          id: `t${index}`, expected_cleared: "uncleared" as const, cleared: "cleared" as const,
        })),
      );
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(calls).toBe(1);
    expect(summary).toMatchObject({ applied_count: 1, unresolved_count: 1, unattempted_count: 98 + 2 });
  });

  test("bulk delete posts the optional reject guard and chunks at 100", async () => {
    const originalFetch = globalThis.fetch;
    const requests: Array<{ path: string; init?: RequestInit }> = [];
    globalThis.fetch = (async (path: string | URL | Request, init?: RequestInit) => {
      requests.push({ path: String(path), init });
      const body = JSON.parse(String(init?.body)) as { transactions: Array<{ id: string }> };
      const outcomes = body.transactions.map((item) => ({ id: item.id, status: "applied" }));
      return new Response(JSON.stringify({
        data: {
          outcomes,
          applied_count: outcomes.length,
          conflict_count: 0,
          already_removed_count: 0,
          unresolved_count: 0,
          unattempted_count: 0,
          server_knowledge: 1,
        },
      }), { headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    let summary;
    try {
      summary = await api.bulkDeleteTransactions(
        "plan-1",
        Array.from({ length: 101 }, (_, index) => (
          index === 0 ? { id: `d${index}`, expected_approved: false } : { id: `d${index}` }
        )),
      );
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(summary).toMatchObject({ applied_count: 101 });
    expect(requests.map((entry) => entry.path)).toEqual([
      "/v1/plans/plan-1/transactions/delete",
      "/v1/plans/plan-1/transactions/delete",
    ]);
    const firstBody = JSON.parse(String(requests[0]?.init?.body));
    expect(firstBody.transactions[0]).toEqual({ id: "d0", expected_approved: false });
    expect(firstBody.transactions[1]).toEqual({ id: "d1" });
    expect(() => api.bulkDeleteTransactions("plan-1", [])).toThrow("must not be empty");
    expect(() => api.categoriseTransactions("plan-1", [])).toThrow("must not be empty");
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
