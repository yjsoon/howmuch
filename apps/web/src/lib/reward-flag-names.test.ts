import { expect, test } from "bun:test";
import { ledgerFlagNames, namedFlagLabel, namesFromSubcategories, parseRewardFlagNames } from "./reward-flag-names";

test("parseRewardFlagNames keeps the ledger colours", () => {
  expect(parseRewardFlagNames({ red: "Dining", blue: " Online ", pink: "x" })).toEqual({
    red: "Dining",
    blue: "Online",
  });
});

test("named flags use the account colour name before the transaction snapshot", () => {
  const names = parseRewardFlagNames({ red: "Dining", blue: "Online", unflagged: "Other" });
  expect(namedFlagLabel(names, "red", "Red")).toBe("Dining");
  expect(namedFlagLabel(names, "blue")).toBe("Online");
  expect(namedFlagLabel(names, "green", "Holiday")).toBe("Holiday");
  expect(namedFlagLabel(names, null)).toBe("Other");
  expect(ledgerFlagNames(names)).toEqual({ red: "Dining", blue: "Online", "": "Other" });
});

test("subcategory names seed empty colour slots", () => {
  expect(namesFromSubcategories([
    { flagColor: "red", name: "Dining Out" },
    { flagColor: "red", name: "Later" },
  ])).toEqual({ red: "Dining Out" });
});
