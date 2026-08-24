import { describe, expect, test } from "bun:test";
import { api, shouldHandleUnauthorized } from "./client";

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
