import { describe, expect, test } from "bun:test";
import { shouldHandleUnauthorized } from "./client";

describe("shouldHandleUnauthorized", () => {
  test("ignores auth-route failures and stale epochs after a new session starts", () => {
    expect(shouldHandleUnauthorized("/api/auth/login", 1, 1)).toBe(false);
    expect(shouldHandleUnauthorized("/v1/plans", 1, 1)).toBe(true);
    expect(shouldHandleUnauthorized("/v1/plans", 1, 2)).toBe(false);
  });
});
