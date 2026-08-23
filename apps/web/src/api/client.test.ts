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
});
