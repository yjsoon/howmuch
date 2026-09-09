import { describe, expect, test } from "bun:test";
import type { CreditCard } from "../api/types";
import { creditCardWrite, draftFromCard } from "../pages/RewardCardEdit";

const card: CreditCard = {
  id: "card", name: "Card", issuer: "Bank", type: "cashback", ynabAccountId: "account", featured: true,
  subcategoriesEnabled: false, earningRate: 0, maximumSpend: null,
  subcategories: [{ id: "flag", name: "Food", flagColor: "red", rewardValue: 2, priority: 1,
    active: false, createdAt: "2026-01-01", updatedAt: "2026-01-01", maximumSpend: null }],
  spendingTiers: [{ id: "tier", spendThreshold: 500, earningRate: null, maximumSpend: 0,
    subcategories: [{ subcategoryId: "flag", rewardValue: 0, maximumSpend: null }] }],
};

describe("reward card serialization", () => {
  test("no-op save retains disabled rules and null versus zero overrides", () => {
    const result = creditCardWrite(draftFromCard(card), { clearMissing: true });
    expect(result).toHaveProperty("card");
    if (!("card" in result)) throw new Error(result.error);
    expect(result.card.subcategoriesEnabled).toBe(false);
    expect(result.card.subcategories?.[0]).toMatchObject(card.subcategories![0]);
    expect(result.card.spendingTiers).toEqual(card.spendingTiers);
    expect(result.card.earningRate).toBe(0);
    expect(result.card.maximumSpend).toBeNull();
  });

  test("unrelated edits preserve signed finite flag priorities", () => {
    const draft = draftFromCard({ ...card, subcategories: [{ ...card.subcategories![0]!, priority: -1.25 }] });
    draft.issuer = "Another bank";
    const result = creditCardWrite(draft);
    if (!("card" in result)) throw new Error(result.error);
    expect(result.card.subcategories?.[0]?.priority).toBe(-1.25);
    for (const priority of ["", "NaN", "Infinity", "-Infinity"]) {
      draft.flags[0]!.priority = priority;
      expect(creditCardWrite(draft)).toHaveProperty("error");
    }
  });

  test.each(["earningRate", "maximumSpend", "minimumSpend", "earningBlockSize"] as const)("rejects negative %s", (field) => {
    expect(creditCardWrite({ ...draftFromCard(card), [field]: "-0.1" })).toHaveProperty("error");
  });
  test.each(["1", "25", "2.5"])("rejects month count %s", (months) => {
    expect(creditCardWrite({ ...draftFromCard(card), rewardMonthCount: months,
      rewardAnchorDate: "2026-01-01", rewardMonthlyMinimum: "0" })).toHaveProperty("error");
  });
  test.each(["0", "32", "1.5"])("rejects billing day %s", (billingDay) => {
    expect(creditCardWrite({ ...draftFromCard(card), billingDay })).toHaveProperty("error");
  });
  test("rejects invalid dates and reversed promotion", () => {
    expect(creditCardWrite({ ...draftFromCard(card), promoEnd: "2026-02-30" })).toHaveProperty("error");
    expect(creditCardWrite({ ...draftFromCard(card), promoStart: "2026-03-02", promoEnd: "2026-03-01" })).toHaveProperty("error");
  });
  test("rejects numerically duplicate thresholds", () => {
    const draft = draftFromCard(card);
    draft.tiers.push({ ...draft.tiers[0]!, id: "second", spendThreshold: "500.00" });
    expect(creditCardWrite(draft)).toHaveProperty("error");
  });
  test.each([2, 24])("accepts month boundary %s and zero minimum", (monthCount) => {
    expect(creditCardWrite(draftFromCard({ ...card, billingCycle: { type: "billing", dayOfMonth: 31 },
      rewardPeriod: { monthCount, anchorDate: "2024-02-29", monthlyMinimumSpend: 0 } }))).toHaveProperty("card");
  });
});
