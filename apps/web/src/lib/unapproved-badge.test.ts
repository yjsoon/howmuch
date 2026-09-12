import { describe, expect, test } from "bun:test";
import { resolvedSinceCount, showsUnapprovedBadge, unapprovedBadgeCount } from "./unapproved-badge";

describe("resolvedSinceCount", () => {
  test("counts only what was resolved after the count was taken", () => {
    expect(resolvedSinceCount(new Set(["a", "b", "c"]), new Set(["a"]))).toBe(2);
  });

  test("is zero when a refetched count already reflects every local approval", () => {
    expect(resolvedSinceCount(new Set(["a", "b"]), new Set(["a", "b"]))).toBe(0);
  });

  test("ignores a snapshot id that is no longer resolved", () => {
    expect(resolvedSinceCount(new Set(["b"]), new Set(["a"]))).toBe(1);
  });

  test("is zero before anything has been approved", () => {
    expect(resolvedSinceCount(new Set(), new Set())).toBe(0);
  });
});

describe("unapprovedBadgeCount", () => {
  test("is null while the first count is in flight, so nothing is rendered", () => {
    expect(unapprovedBadgeCount(null, null, 0)).toBeNull();
  });

  test("uses the server count when the queue has not been loaded", () => {
    expect(unapprovedBadgeCount(null, 12, 0)).toBe(12);
  });

  test("decrements optimistically for approvals the count predates", () => {
    expect(unapprovedBadgeCount(null, 12, 3)).toBe(9);
  });

  test("never shows a negative badge when more was resolved than counted", () => {
    expect(unapprovedBadgeCount(null, 2, 5)).toBe(0);
  });

  test("prefers the row-exact queue count once the approval flow has loaded it", () => {
    // The rows are the truth: they already exclude locally approved lines, so
    // the optimistic adjustment must not be applied a second time.
    expect(unapprovedBadgeCount(4, 12, 3)).toBe(4);
  });

  test("trusts an empty loaded queue over a stale non-zero count", () => {
    expect(unapprovedBadgeCount(0, 7, 0)).toBe(0);
  });
});

describe("showsUnapprovedBadge", () => {
  test("hides a zero badge in the normal register", () => {
    expect(showsUnapprovedBadge(0, false)).toBe(false);
  });

  test("hides the badge while the first count is still unknown", () => {
    expect(showsUnapprovedBadge(null, false)).toBe(false);
  });

  test("shows a non-zero badge", () => {
    expect(showsUnapprovedBadge(3, false)).toBe(true);
  });

  test("keeps the pill visible while the approval flow is open, as the way out", () => {
    expect(showsUnapprovedBadge(0, true)).toBe(true);
    expect(showsUnapprovedBadge(null, true)).toBe(true);
  });
});
