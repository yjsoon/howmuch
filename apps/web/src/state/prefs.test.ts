import { describe, expect, test } from "bun:test";
import { parsePrefs } from "./prefs";

describe("parsePrefs", () => {
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
