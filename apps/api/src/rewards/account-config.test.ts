import { describe, expect, test } from "bun:test";
import fixture from "../../../../fixtures/rewards-account-config.json";
import { parseRewardsAccountConfig } from "./account-config";

describe("per-account rewards configuration contract", () => {
  test("accepts the Rewards Tracker fixture without changing its configuration", () => {
    expect(parseRewardsAccountConfig(fixture)).toEqual(fixture);
  });

  test("rejects malformed booleans, flag names and broken tier references instead of silently changing rules", () => {
    for (const patch of [
      { subcategoriesEnabled: "false" },
      { subcategories: [{ ...fixture.card.subcategories[0], active: "false" }] },
      { subcategories: [{ ...fixture.card.subcategories[0], excludeFromRewards: "false" }] },
      { flagNames: [] },
      { flagNames: { red: 42 } },
      { flagNames: { pink: "Invalid colour" } },
      { spendingTiers: [{ id: "tier", spendThreshold: 1, subcategories: [{ subcategoryId: "missing", rewardValue: 2 }] }] },
      { subcategories: [fixture.card.subcategories[0], fixture.card.subcategories[0]] },
      { spendingTiers: [{ id: "tier", spendThreshold: 1 }, { id: "tier", spendThreshold: 2 }] },
      { subcategories: [fixture.card.subcategories[0], { ...fixture.card.subcategories[0], id: "duplicate-colour" }] },
      { spendingTiers: [{ id: "tier", spendThreshold: 1, subcategories: [
        { subcategoryId: "synthetic-dining", rewardValue: 2 }, { subcategoryId: "synthetic-dining", rewardValue: 3 },
      ] }] },
    ]) {
      expect(() => parseRewardsAccountConfig({ ...fixture, card: { ...fixture.card, ...patch } })).toThrow();
    }
  });
});
