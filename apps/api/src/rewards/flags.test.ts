import { expect, test } from "bun:test";
import { UNFLAGGED_FLAG, YNAB_FLAG_COLORS } from "./flags";
import { normaliseFlagColor } from "./engine/utils/subcategories";

test("reward subcategory colours are the ledger flag tags", () => {
  expect(YNAB_FLAG_COLORS.map((flag) => flag.value)).toEqual([
    "red",
    "orange",
    "yellow",
    "green",
    "blue",
    "purple",
  ]);
  expect(normaliseFlagColor(null)).toBe(UNFLAGGED_FLAG.value);
  expect(normaliseFlagColor(undefined)).toBe("unflagged");
  expect(normaliseFlagColor("")).toBe("unflagged");
  expect(normaliseFlagColor("red")).toBe("red");
  expect(normaliseFlagColor("RED")).toBe("red");
  expect(normaliseFlagColor("pink")).toBe("unflagged");
});
