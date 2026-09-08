import { expect, test } from "bun:test";
import { cardFlagNames, flagNameForColour, parseCardFlagNames } from "./flag-names";

test("parseCardFlagNames keeps named ledger colours", () => {
  expect(parseCardFlagNames({
    red: "Dining",
    blue: "  Online  ",
    pink: "Nope",
    orange: "",
  })).toEqual({ red: "Dining", blue: "Online" });
  expect(parseCardFlagNames(null)).toBeUndefined();
  expect(parseCardFlagNames({})).toBeUndefined();
});

test("cardFlagNames prefers explicit names over subcategory names", () => {
  const names = cardFlagNames({
    flagNames: { red: "Dining" },
    subcategories: [
      {
        id: "sub-1",
        name: "Dining Out",
        flagColor: "red",
        rewardValue: 4,
        priority: 1,
        active: true,
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z",
      },
      {
        id: "sub-2",
        name: "Online",
        flagColor: "blue",
        rewardValue: 3,
        priority: 2,
        active: true,
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z",
      },
    ],
  });
  expect(names).toEqual({ red: "Dining", blue: "Online" });
  expect(flagNameForColour(names, "red")).toBe("Dining");
  expect(flagNameForColour(names, null)).toBeNull();
});
