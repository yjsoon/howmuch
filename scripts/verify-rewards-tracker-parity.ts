/**
 * Differential check against the tracker WEB app's shared calculator.
 * Usage: bun scripts/verify-rewards-tracker-parity.ts /path/to/ynab-rewards-tracker
 * Reference: 60cd90ab8c44c4507515f56364ec00d0c97784d2 (MIT).
 * This reads synthetic data only; it does not contact either app or a provider.
 */
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { buildRewardsReport } from "../apps/api/src/rewards/build";
import type { CardSubcategory, CreditCard, Transaction } from "../apps/api/src/rewards/types";

const source = process.argv[2];
if (!source) throw new Error("Supply a local checkout of yjsoon/ynab-rewards-tracker (web shared source).");
const { SimpleRewardsCalculator: reference } = await import(pathToFileURL(resolve(
  source, "packages/app-core/src/rewards-engine/simple-calculator.ts",
)).href);

const base: CreditCard = {
  id: "parity", name: "Synthetic parity card", issuer: "Fixture", type: "cashback",
  ynabAccountId: "parity-account", featured: true, earningRate: 10,
  billingCycle: { type: "calendar" }, minimumSpend: null, maximumSpend: null,
};
function tx(id: string, amount: number, date = "2026-02-12", flag_color: string | null = null): Transaction {
  return { id, amount, date, flag_color, account_id: base.ynabAccountId, category_name: "Dining", payee_name: "Synthetic merchant" };
}
function category(id: string, flagColor: CardSubcategory["flagColor"], patch: Partial<CardSubcategory> = {}): CardSubcategory {
  return {
    id, name: id, flagColor, rewardValue: 10, priority: 1, active: true,
    createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", ...patch,
  };
}
const categories = [category("red", "red", { rewardValue: 8, maximumSpend: 75 }), category("default", "unflagged", { rewardValue: 2 })];
const cases: Array<{ name: string; card?: Partial<CreditCard>; transactions: Transaction[]; asOf?: string; valuation?: number }> = [
  { name: "calendar ignores prior cycle", card: { maximumSpend: 100 }, transactions: [tx("jan", -100000, "2026-01-15"), tx("feb", -100000)] },
  { name: "billing day 20 crosses calendar month", card: { billingCycle: { type: "billing", dayOfMonth: 20 }, maximumSpend: 125 }, transactions: [tx("excluded", -999000, "2026-01-19"), tx("first", -95000, "2026-01-20"), tx("last", -60000, "2026-02-15")] },
  { name: "billing day 31 clamps short month", asOf: "2026-03-02", card: { billingCycle: { type: "billing", dayOfMonth: 31 } }, transactions: [tx("before", -50000, "2026-02-27"), tx("boundary", -73000, "2026-02-28")] },
  { name: "cashback blocks and cap headroom", card: { earningBlockSize: 5, maximumSpend: 17 }, transactions: [tx("a", -12000), tx("b", -8000)] },
  { name: "miles blocks per transaction", card: { type: "miles", earningRate: 4, earningBlockSize: 5 }, transactions: [tx("a", -12000), tx("b", -4000), tx("c", -4000)] },
  { name: "minimum equality unlocks earlier spending", card: { minimumSpend: 100 }, transactions: [tx("a", -73000), tx("b", -27000)] },
  { name: "minimum below threshold stays locked", card: { minimumSpend: 100 }, transactions: [tx("a", -99999)] },
  { name: "categories share cap chronologically", card: { subcategoriesEnabled: true, subcategories: categories, maximumSpend: 100 }, transactions: [tx("first", -80000, "2026-02-01"), tx("later", -70000, "2026-02-02", "red")] },
  { name: "inactive coloured rule uses default", card: { subcategoriesEnabled: true, subcategories: [category("red", "red", { active: false }), category("default", "unflagged", { rewardValue: 3 })] }, transactions: [tx("red", -57000, "2026-02-10", "red")] },
  { name: "excluded versus zero-rate qualifying spend", card: { minimumSpend: 100, subcategoriesEnabled: true, subcategories: [category("red", "red", { excludeFromRewards: true }), category("blue", "blue", { rewardValue: 0 }), category("default", "unflagged")] }, transactions: [tx("excluded", -80000, "2026-02-10", "red"), tx("zero", -60000, "2026-02-11", "blue"), tx("earns", -45000)] },
  { name: "tier next cap before rate unlock", card: { maximumSpend: 50, spendingTiers: [{ id: "next", spendThreshold: 150, earningRate: 20, maximumSpend: 200 }] }, transactions: [tx("a", -120000)] },
  { name: "tier rates retroactive and category overrides", card: { subcategoriesEnabled: true, subcategories: categories, spendingTiers: [{ id: "next", spendThreshold: 150, earningRate: 20, maximumSpend: 200, subcategories: [{ subcategoryId: "red", rewardValue: 15, maximumSpend: 100 }] }] }, transactions: [tx("a", -90000, "2026-02-10", "red"), tx("b", -80000)] },
  { name: "promotional window supersedes calendar", card: { promotionalPeriod: { startDate: "2026-01-10", endDate: "2026-03-15" }, maximumSpend: 120 }, transactions: [tx("before", -90000, "2026-01-09"), tx("during", -90000, "2026-01-11"), tx("later", -70000)] },
  { name: "future anchor not retroactive", card: { rewardPeriod: { monthCount: 3, anchorDate: "2026-03-01", monthlyMinimumSpend: 100 } }, transactions: [tx("jan", -99000, "2026-01-10"), tx("feb", -65000)] },
  { name: "multi-month completed monthly failure", card: { rewardPeriod: { monthCount: 3, anchorDate: "2026-01-01", monthlyMinimumSpend: 90 } }, transactions: [tx("jan", -80000, "2026-01-15"), tx("feb", -130000)] },
  { name: "refund nets monthly qualification", card: { rewardPeriod: { monthCount: 3, anchorDate: "2026-01-01", monthlyMinimumSpend: 90 } }, transactions: [tx("jan", -100000, "2026-01-15"), tx("refund", 20000, "2026-01-20"), tx("feb", -130000)] },
  { name: "transfer credit does not count as refund", card: { rewardPeriod: { monthCount: 3, anchorDate: "2026-01-01", monthlyMinimumSpend: 90 } }, transactions: [tx("jan", -100000, "2026-01-15"), { ...tx("payment", 100000, "2026-01-20"), transfer_account_id: "bank" }, tx("feb", -100000)] },
  { name: "zero miles valuation preserved", card: { type: "miles", earningRate: 4 }, valuation: 0, transactions: [tx("a", -33000)] },
  { name: "as-of omits later transactions", transactions: [tx("before", -45000), tx("after", -900000, "2026-02-17"), tx("future", -1000000, "2099-01-01")] },
];

let failures = 0;
function equal(name: string, field: string, actual: unknown, expected: unknown) {
  const matches = typeof actual === "number" && typeof expected === "number"
    ? Math.abs(actual - expected) < 1e-8
    : JSON.stringify(actual) === JSON.stringify(expected);
  if (!matches) {
    failures++;
    console.error(`${name}: ${field}: actual ${JSON.stringify(actual)}, reference ${JSON.stringify(expected)}`);
  }
}
for (const scenario of cases) {
  const card = { ...base, ...scenario.card };
  const asOf = scenario.asOf ?? "2026-02-15";
  const [year, month, day] = asOf.split("-").map(Number);
  const period = { ...reference.calculatePeriod(card, new Date(year!, month! - 1, day!)), asOf };
  const settings = { milesValuation: scenario.valuation ?? 0.02 };
  const expected = reference.calculateCardRewards(card, scenario.transactions, period, settings);
  const report = buildRewardsReport({ cards: [card], accountNames: {}, transactions: scenario.transactions, settings, from: null, to: asOf, groupBy: "flag", accountIds: [] });
  const actual = report.cards[0]!.calculation;
  for (const [local, upstream] of [
    ["total_spend", "totalSpend"], ["counted_spend", "countedSpend"], ["eligible_spend", "eligibleSpend"],
    ["reward_earned", "rewardEarned"], ["reward_earned_dollars", "rewardEarnedDollars"],
    ["minimum_spend_met", "minimumSpendMet"], ["maximum_spend_exceeded", "maximumSpendExceeded"],
  ] as const) equal(scenario.name, local, actual[local], expected[upstream]);
  const state = actual as unknown as Record<string, unknown>;
  if (expected.qualificationStatus !== undefined) {
    equal(scenario.name, "qualification_status", state.qualification_status, expected.qualificationStatus);
    equal(scenario.name, "monthly_qualifications", state.monthly_qualifications, expected.monthlyQualifications);
  }
  for (const flag of expected.subcategoryBreakdowns ?? []) {
    const row = actual.flags.find((entry) => entry.subcategoryId === flag.id);
    equal(scenario.name, `${flag.id}.countedSpend`, row?.countedSpend, flag.countedSpend);
    equal(scenario.name, `${flag.id}.rewardEarned`, row?.rewardEarned, flag.rewardEarned);
  }
  const attributed = (report as unknown as { transaction_rewards?: Record<string, { reward: number; reward_dollars: number }> }).transaction_rewards;
  for (const [id, row] of Object.entries(expected.transactionRewards) as Array<[string, { reward: number; rewardDollars: number }]>) {
    equal(scenario.name, `${id}.reward`, attributed?.[id]?.reward, row.reward);
    equal(scenario.name, `${id}.reward_dollars`, attributed?.[id]?.reward_dollars, row.rewardDollars);
  }
}
console.log(`${cases.length} synthetic web-reference scenarios; ${failures} mismatches`);
if (failures) process.exitCode = 1;
