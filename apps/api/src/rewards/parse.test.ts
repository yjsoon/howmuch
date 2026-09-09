import { expect, test } from "bun:test";
import { parseCreditCardWrite } from "./parse";

const card = { id: "c", name: "Card", ynabAccountId: "a", type: "miles" };
const category = { id: "s", name: "Dining", flagColor: "red", rewardValue: 0, priority: 0, createdAt: "2026-01-01", updatedAt: "2026-01-01" };

test("modern writes preserve numeric category rates and nullable base/tier fields", () => {
  const input = { ...card, earningRate: null, minimumSpend: 0, maximumSpend: null,
    billingCycle: { type: "billing", dayOfMonth: 31 },
    rewardPeriod: { monthCount: 24, anchorDate: "2024-02-29", monthlyMinimumSpend: 0 },
    promotionalPeriod: { startDate: null, endDate: "2026-12-31" },
    subcategories: [category], spendingTiers: [{ id: "t", spendThreshold: 0, earningRate: null, subcategories: [{ subcategoryId: "s", rewardValue: 0 }] }] };
  expect(parseCreditCardWrite(input)).toMatchObject(input);
  expect(parseCreditCardWrite({ ...card, rewardPeriod: { monthCount: 2, anchorDate: "2026-01-31", monthlyMinimumSpend: 0 }, billingCycle: { type: "billing", dayOfMonth: 1 } }).rewardPeriod?.monthCount).toBe(2);
});

test("modern writes reject invalid bounds, calendar dates, and duplicate thresholds", () => {
  const invalid = [
    ...[1, 25, 2.5].map(monthCount => ({ rewardPeriod: { monthCount, anchorDate: "2026-01-01", monthlyMinimumSpend: 0 } })),
    ...[0, 32, 1.5].map(dayOfMonth => ({ billingCycle: { type: "billing", dayOfMonth } })),
    ...["2026-02-29", "2026-04-31", "2026-1-01"].map(anchorDate => ({ rewardPeriod: { monthCount: 3, anchorDate, monthlyMinimumSpend: 0 } })),
    { promotionalPeriod: { startDate: "2026-03-01", endDate: "2026-02-28" } },
    { promotionalPeriod: { endDate: "2026-02-30" } },
    { rewardPeriod: { monthCount: 3, anchorDate: "2026-01-01", monthlyMinimumSpend: -1 } },
    ...["earningRate", "minimumSpend", "maximumSpend", "earningBlockSize"].map(key => ({ [key]: -1 })),
    { subcategories: [{ ...category, rewardValue: -1 }] },
    { subcategories: [{ ...category, rewardValue: null }] },
    { subcategories: [{ ...category, maximumSpend: -1 }] },
    { spendingTiers: [{ id: "t", spendThreshold: -1 }] },
    { spendingTiers: [{ id: "t", spendThreshold: 10, earningRate: -1 }] },
    { spendingTiers: [{ id: "t", spendThreshold: 10, subcategories: [{ subcategoryId: "s", rewardValue: null }] }] },
    { spendingTiers: [{ id: "t", spendThreshold: 10 }, { id: "u", spendThreshold: 10 }] },
  ];
  for (const fields of invalid) expect(() => parseCreditCardWrite({ ...card, ...fields })).toThrow();
});
