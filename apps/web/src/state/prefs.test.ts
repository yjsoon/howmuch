import { describe, expect, test } from "bun:test";
import { parsePrefs } from "./prefs";

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
});
