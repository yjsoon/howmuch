import { describe, expect, test } from "bun:test";
import { parsePrefs, sessionLooksLive } from "./prefs";

describe("parsePrefs", () => {
  test("keeps a well-formed remembered plan and rejects anything else", () => {
    expect(parsePrefs({ planId: "plan-a" }).planId).toBe("plan-a");
    expect(parsePrefs({ planId: "../../etc/passwd" }).planId).toBeUndefined();
    expect(parsePrefs({ planId: ".." }).planId).toBeUndefined();
    expect(parsePrefs({ planId: "." }).planId).toBeUndefined();
    expect(parsePrefs({ planId: "..." }).planId).toBeUndefined();
    expect(parsePrefs({ accountIds: [".", "..", "acc-1"] }).accountIds).toEqual(["acc-1"]);
    expect(parsePrefs({ planId: 42 }).planId).toBeUndefined();
  });


  test("keeps only well-formed view preferences", () => {
    expect(parsePrefs({
      accountIds: ["acc-1", "<script>", 12],
      interval: "month",
      includeQuietSpending: true,
    })).toEqual({
      accountIds: ["acc-1"],
      interval: "month",
      includeQuietSpending: true,
    });
  });

  test("rejects poisoned or malformed storage payloads", () => {
    expect(parsePrefs(null)).toEqual({});
    expect(parsePrefs("nope")).toEqual({});
    expect(parsePrefs({ interval: "fortnight", includeQuietSpending: "yes" })).toEqual({});
  });

  test("keeps a numeric session expiry and discards anything else", () => {
    expect(parsePrefs({ sessionExpiresAt: 1_800_000_000 }).sessionExpiresAt).toBe(1_800_000_000);
    expect(parsePrefs({ sessionExpiresAt: "soon" }).sessionExpiresAt).toBeUndefined();
    expect(parsePrefs({ sessionExpiresAt: Number.NaN }).sessionExpiresAt).toBeUndefined();
    expect(parsePrefs({ sessionExpiresAt: Number.POSITIVE_INFINITY }).sessionExpiresAt).toBeUndefined();
  });
});

describe("sessionLooksLive", () => {
  const now = 1_800_000_000_000;

  test("is true while the recorded session has time left", () => {
    expect(sessionLooksLive(1_800_000_060, now)).toBe(true);
  });

  test("is false once the session has expired", () => {
    // The case this exists for: a cookie that lapsed while the tab was closed.
    // Nobody's ledger data may be painted on the strength of it.
    expect(sessionLooksLive(1_799_999_940, now)).toBe(false);
  });

  test("is false at the exact moment of expiry", () => {
    expect(sessionLooksLive(1_800_000_000, now)).toBe(false);
  });

  test("is false when no session was ever recorded", () => {
    expect(sessionLooksLive(undefined, now)).toBe(false);
  });

  test("is false for an unusable value rather than assuming the best", () => {
    expect(sessionLooksLive(Number.NaN, now)).toBe(false);
  });
});
