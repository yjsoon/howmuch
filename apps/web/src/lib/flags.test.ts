import { expect, test } from "bun:test";
import { FLAG_COLOURS, flagTitle, isFlagColour, ledgerFlagFromReward, rewardFlagFromLedger } from "./flags";

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

test("reward flags are the ledger colour tags, with None as unflagged", () => {
  expect(FLAG_COLOURS).toEqual(["red", "orange", "yellow", "green", "blue", "purple"]);
  expect(rewardFlagFromLedger("")).toBe("unflagged");
  expect(rewardFlagFromLedger(null)).toBe("unflagged");
  expect(rewardFlagFromLedger("red")).toBe("red");
  expect(rewardFlagFromLedger("pink")).toBe("unflagged");
  expect(ledgerFlagFromReward("unflagged")).toBe("");
  expect(ledgerFlagFromReward("blue")).toBe("blue");
});
