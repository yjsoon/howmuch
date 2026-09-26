import { expect, test } from "bun:test";
import {
  namesFromSubcategories,
  parseRewardFlagNames,
  snapshotFlagLabel,
} from "./reward-flag-names";

test("changing colour drops the previous snapshot name", () => {
  const names = parseRewardFlagNames({ red: "Dining", blue: "Online" });
  const snapshot = { flag_color: "red", flag_name: "Dining" };
  expect(snapshotFlagLabel(names, "red", snapshot)).toBe("Dining");
  expect(snapshotFlagLabel(names, "orange", snapshot)).toBeUndefined();
  expect(snapshotFlagLabel(names, "blue", snapshot)).toBe("Online");
  expect(snapshotFlagLabel(names, null, snapshot)).toBeUndefined();
});

test("subcategory names seed empty colour slots", () => {
  expect(namesFromSubcategories([
    { flagColor: "red", name: "Dining Out" },
    { flagColor: "red", name: "Later" },
  ])).toEqual({ red: "Dining Out" });
});
