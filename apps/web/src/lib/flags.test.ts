import { expect, test } from "bun:test";
import { FLAG_COLOURS, flagTitle, isFlagColour } from "./flags";

test("isFlagColour accepts the six YNAB colours", () => {
  for (const colour of FLAG_COLOURS) expect(isFlagColour(colour)).toBe(true);
  expect(isFlagColour("")).toBe(false);
  expect(isFlagColour("pink")).toBe(false);
  expect(isFlagColour(null)).toBe(false);
});

test("flagTitle prefers a custom name and otherwise capitalises the colour", () => {
  expect(flagTitle("blue", "Follow up")).toBe("Follow up");
  expect(flagTitle("blue", "  ")).toBe("Blue");
  expect(flagTitle("red")).toBe("Red");
});
