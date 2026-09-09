import { afterEach, expect, setSystemTime, test } from "bun:test";
import officialExport from "../../../../fixtures/rewards-tracker-export.json";
import { buildRewardsReport } from "./build";
import { parseAppSettings, parseCreditCards } from "./parse";
import type { CreditCard, Transaction } from "./types";

const cards = parseCreditCards(officialExport.cards);
const settings = parseAppSettings(officialExport.settings);

afterEach(() => setSystemTime());

const cappedCard: CreditCard = {
  id: "capped", name: "Capped", issuer: "Bank", type: "miles",
  ynabAccountId: "acct-credit", featured: false, earningRate: 2, maximumSpend: 100,
};

function reportFor(transactions: Transaction[], overrides: Partial<Parameters<typeof buildRewardsReport>[0]> = {}) {
  setSystemTime(new Date("2026-06-15T04:00:00Z"));
  return buildRewardsReport({
    cards: [cappedCard], accountNames: {}, transactions, settings: { milesValuation: 0.02 },
    from: "2026-04-01", to: "2026-05-31", groupBy: "payee", accountIds: [], ...overrides,
  });
}

test("historical ranges reset caps at actual periods, not at the range start", () => {
  const transactions = [
    txn({ id: "apr-early", date: "2026-04-03", amount: -80000 }),
    txn({ id: "apr-late", date: "2026-04-20", amount: -60000 }),
    txn({ id: "may", date: "2026-05-02", amount: -130000 }),
  ];
  expect(reportFor(transactions).totals.miles).toBe(400);
  const cut = reportFor(transactions, { from: "2026-04-15" });
  expect(cut.totals).toEqual({ spend: 190, miles: 240, reward_dollars: 4.8, cashback: 0 });
  expect(cut.cards[0]!.calculation.counted_spend).toBe(120);
  expect(cut.transaction_rewards).toEqual({
    "apr-late": { reward: 40, reward_dollars: 0.8 }, may: { reward: 200, reward_dollars: 4 },
  });
  expect(cut.cards[0]!.calculation.periods?.map((p) => [p.start, p.end])).toEqual([
    ["2026-04-01", "2026-04-30"], ["2026-05-01", "2026-05-31"],
  ]);
});

test("no from evaluates each card's own current cycle at the cutoff", () => {
  const report = reportFor([
    txn({ id: "old", date: "2026-04-10", amount: -500000 }),
    txn({ id: "calendar", date: "2026-05-03", amount: -30000 }),
    txn({ id: "billing", date: "2026-04-20", amount: -70000, account_id: "billing" }),
  ], {
    from: null, to: "2026-05-10",
    cards: [cappedCard, { ...cappedCard, id: "billing", ynabAccountId: "billing", billingCycle: { type: "billing", dayOfMonth: 15 } }],
  });
  expect(report.totals.spend).toBe(100);
  expect(report.cards.map((c) => c.calculation.periods?.[0]?.start)).toEqual(["2026-05-01", "2026-04-15"]);
  expect(Object.keys(report.transaction_rewards ?? {}).sort()).toEqual(["billing", "calendar"]);
});

test("future cutoffs clamp to today and zero valuation keeps native rewards", () => {
  const report = reportFor([
    txn({ id: "today", date: "2026-06-15", amount: -40000 }),
    txn({ id: "future", date: "2026-06-16", amount: -90000 }),
  ], { from: null, to: "2027-01-01", settings: { milesValuation: 0 } });
  expect(report.as_of).toBe("2026-06-15");
  expect(report.totals).toEqual({ spend: 40, miles: 80, reward_dollars: 0, cashback: 0 });
  expect(report.transaction_rewards).toEqual({ today: { reward: 80, reward_dollars: 0 } });
});

test("Singapore midnight is today even when the server is on the preceding date", () => {
  setSystemTime(new Date("2026-05-31T16:30:00Z"));
  const report = buildRewardsReport({
    cards: [cappedCard], accountNames: {}, settings: {}, from: null, to: null,
    groupBy: "flag", accountIds: [], transactions: [
      txn({ id: "previous", date: "2026-05-31", amount: -100000 }),
      txn({ id: "today", date: "2026-06-01", amount: -40000 }),
      txn({ id: "tomorrow", date: "2026-06-02", amount: -100000 }),
    ],
  });
  expect(report.as_of).toBe("2026-06-01");
  expect(report.totals.miles).toBe(80);
  expect(report.cards[0]!.calculation.periods?.[0]?.start).toBe("2026-06-01");
});

test("legacy malformed period configuration fails validation before calculation", () => {
  for (const monthCount of [0, -1, 1, 2.5, 25, Infinity, NaN]) {
    expect(() => reportFor([], { cards: [{ ...cappedCard, rewardPeriod: { monthCount, anchorDate: "2026-01-01", monthlyMinimumSpend: 100 } }] })).toThrow("Invalid reward period");
  }
  expect(() => reportFor([], { cards: [{ ...cappedCard, rewardPeriod: { monthCount: 3, anchorDate: "2026-02-30", monthlyMinimumSpend: 100 } }] })).toThrow("Invalid reward period");
});

test("report dates reject malformed and reversed ranges rather than silently changing the period", () => {
  for (const date of ["2026-02-30", "2026-2-01", "invalid"]) {
    expect(() => reportFor([], { from: null, to: date })).toThrow("valid YYYY-MM-DD");
    expect(() => reportFor([], { from: date })).toThrow("valid YYYY-MM-DD");
  }
  expect(() => reportFor([], { from: "2026-05-02", to: "2026-05-01" })).toThrow("from must not follow to");
});

test("promotion pools cap across calendar months", () => {
  const report = reportFor([
    txn({ id: "apr", date: "2026-04-20", amount: -80000 }),
    txn({ id: "may", date: "2026-05-03", amount: -70000 }),
  ], { from: "2026-05-01", cards: [{ ...cappedCard, promotionalPeriod: { startDate: "2026-04-15", endDate: "2026-05-31" } }] });
  expect(report.totals.miles).toBe(40);
  expect(report.cards[0]!.calculation.periods?.[0]?.start).toBe("2026-04-15");
});

test("a range crossing a promotion attributes each transaction once even when calendar windows overlap", () => {
  const report = reportFor([
    txn({ id: "before", date: "2026-04-10", amount: -30000 }),
    txn({ id: "promo", date: "2026-04-20", amount: -40000 }),
    txn({ id: "after", date: "2026-04-28", amount: -50000 }),
  ], { from: "2026-04-01", to: "2026-04-30", cards: [{ ...cappedCard, maximumSpend: null, promotionalPeriod: { startDate: "2026-04-15", endDate: "2026-04-25" } }] });
  expect(report.cards[0]!.calculation).toMatchObject({ total_spend: 120, counted_spend: 120, eligible_spend: 120, reward_earned: 240 });
});

test("anchored monthly qualification includes earlier purchases and merchant refunds", () => {
  const card = { ...cappedCard, rewardPeriod: { anchorDate: "2026-04-15", monthCount: 3, monthlyMinimumSpend: 100 } };
  const transactions = [
    txn({ id: "apr", date: "2026-04-20", amount: -120000 }),
    txn({ id: "refund", date: "2026-05-02", amount: 30000 }),
    txn({ id: "may", date: "2026-05-20", amount: -150000 }),
  ];
  const report = reportFor(transactions, { cards: [card], from: "2026-05-15" });
  expect(report.totals.miles).toBe(0);
  expect(report.cards[0]!.calculation.qualification_status).toBe("failed");
  expect(report.cards[0]!.calculation.monthly_qualifications?.[0]).toEqual({
    start: "2026-04-15", end: "2026-05-14", spend: 90, minimumSpend: 100, status: "failed",
  });
  const pending = reportFor(transactions, { cards: [card], from: null, to: "2026-05-10" });
  expect(pending.cards[0]!.calculation.qualification_status).toBe("pending");
});

test("historical attribution uses the tier reached by full history, including earlier minimum spend", () => {
  const report = reportFor([
    txn({ id: "earlier", date: "2026-05-03", amount: -80000 }),
    txn({ id: "later", date: "2026-05-20", amount: -70000 }),
  ], { from: "2026-05-15", cards: [{
    ...cappedCard, minimumSpend: 100, maximumSpend: 200,
    spendingTiers: [{ id: "higher", spendThreshold: 150, earningRate: 4, maximumSpend: 300 }, { id: "next", spendThreshold: 250, earningRate: 6, maximumSpend: 400 }],
  }] });
  expect(report.totals.miles).toBe(280);
  expect(report.cards[0]!.calculation).toMatchObject({
    counted_spend: 70, eligible_spend: 70, minimum_spend_met: true,
    active_spending_tier_id: "higher", has_next_spending_tier: true,
    next_spending_tier_id: "next", next_spending_tier_threshold: 250, should_stop_using: false,
  });
});

test("historical periods before an anchor do not acquire later monthly qualification rules", () => {
  const report = reportFor([txn({ id: "before-anchor", date: "2026-03-20", amount: -60000 })], {
    from: "2026-03-01", cards: [{ ...cappedCard, rewardPeriod: { monthCount: 3, anchorDate: "2026-04-15", monthlyMinimumSpend: 100 } }],
  });
  expect(report.totals.miles).toBe(120);
  expect(report.cards[0]!.calculation.periods?.[0]?.calculation.qualification_status).toBe("not_required");
});

test.each([undefined, { type: "billing" as const, dayOfMonth: 20 }])("an anchor truncates the previous regime without retroactive qualification (%j)", (billingCycle) => {
  const card = { ...cappedCard, billingCycle, rewardPeriod: { monthCount: 3, anchorDate: "2026-04-15", monthlyMinimumSpend: 100 } };
  const before = txn({ id: "before", date: "2026-04-10", amount: -60000 });
  const early = reportFor([before], { cards: [card], from: "2026-04-01", to: "2026-04-10" });
  const later = reportFor([before], { cards: [card], from: "2026-04-01", to: "2026-05-10" });
  expect(early.totals.miles).toBe(120);
  expect(later.totals.miles).toBe(120);
  expect(later.cards[0]!.calculation.periods?.[0]).toMatchObject({
    end: "2026-04-14", calculation: { qualification_status: "not_required", total_spend: 60 },
  });
  const crossing = reportFor([before, txn({ id: "anchored", date: "2026-04-15", amount: -110000 })], {
    cards: [card], from: "2026-04-01", to: "2026-05-10",
  });
  expect(crossing.transaction_rewards).toEqual({ before: { reward: 120, reward_dollars: 2.4 }, anchored: { reward: 200, reward_dollars: 4 } });
  expect(crossing.cards[0]!.calculation.periods?.[0]?.calculation.total_spend).toBe(60);
  expect(crossing.cards[0]!.calculation.periods?.[1]?.calculation.monthly_qualifications?.[0]?.spend).toBe(110);
});

test("flag range totals retain full-period minimums and per-transaction blocks", () => {
  const flag = { id: "red", name: "Dining", flagColor: "red" as const, rewardValue: 4, milesBlockSize: 5, minimumSpend: 200, priority: 0, active: true, createdAt: "2026-01-01", updatedAt: "2026-01-01" };
  const report = reportFor([
    txn({ id: "earlier", date: "2026-05-03", amount: -83000, flag_color: "red" }),
    txn({ id: "red", date: "2026-05-20", amount: -28000, flag_color: "red" }),
    txn({ id: "blue", date: "2026-05-21", amount: -17000, flag_color: "blue" }),
  ], { from: "2026-05-15", cards: [{ ...cappedCard, maximumSpend: null, subcategoriesEnabled: true, subcategories: [flag, { ...flag, id: "blue", flagColor: "blue", rewardValue: 2, minimumSpend: null }] }] });
  expect(report.cards[0]!.calculation).toMatchObject({ total_spend: 45, counted_spend: 40, eligible_spend: 15, reward_earned: 30 });
  expect(report.cards[0]!.calculation.flags).toEqual([
    expect.objectContaining({ subcategoryId: "red", totalSpend: 28, countedSpend: 25, eligibleSpend: 0, rewardEarned: 0 }),
    expect.objectContaining({ subcategoryId: "blue", totalSpend: 17, countedSpend: 15, eligibleSpend: 15, eligibleSpendBeforeBlocks: 17, rewardEarned: 30 }),
  ]);
});

function txn(partial: Partial<Transaction> & Pick<Transaction, "id" | "amount">): Transaction {
  return {
    date: "2026-05-13",
    account_id: "acct-credit",
    payee_name: "Candlenut",
    category_name: "Dining Out",
    memo: "Birthday supper",
    approved: true,
    ...partial,
  };
}

test("builds per-card miles and groups flagged dining separately from unflagged spend", () => {
  const report = buildRewardsReport({
    cards,
    accountNames: { "acct-credit": "Travel Card" },
    settings,
    from: "2026-03-01",
    to: "2026-05-31",
    groupBy: "flag",
    accountIds: [],
    transactions: [
      txn({ id: "dining", amount: -86600, flag_color: "red", flag_name: "Dining" }),
      txn({ id: "online", amount: -228900, date: "2026-05-04", payee_name: "MUJI", category_name: "Shopping", memo: "Home bits", flag_color: "blue", flag_name: "Online" }),
      txn({ id: "flight", amount: -488900, date: "2026-04-12", payee_name: "Scoot", category_name: "Holiday", memo: "Taipei flights" }),
    ],
  });

  expect(report.cards).toHaveLength(1);
  expect(report.cards[0]!.card.name).toBe("Travel Card");
  expect(report.totals.spend).toBeGreaterThan(0);
  expect(report.groups.map((row) => row.label).sort()).toEqual(["Dining", "Online", "Unflagged"].sort());

  const byPayee = buildRewardsReport({
    cards,
    accountNames: { "acct-credit": "Travel Card" },
    settings,
    from: "2026-03-01",
    to: "2026-05-31",
    groupBy: "payee",
    accountIds: [],
    transactions: [
      txn({ id: "dining", amount: -86600, flag_color: "red", flag_name: "Dining" }),
      txn({ id: "online", amount: -228900, date: "2026-05-04", payee_name: "MUJI", category_name: "Shopping", memo: "Home bits", flag_color: "blue", flag_name: "Online" }),
    ],
  });
  expect(byPayee.groups.map((row) => row.label).sort()).toEqual(["Candlenut", "MUJI"]);
});

test("account filter hides cards whose HowMuch account is not selected", () => {
  const report = buildRewardsReport({
    cards,
    accountNames: { "acct-credit": "Travel Card" },
    settings,
    from: null,
    to: null,
    groupBy: "flag",
    accountIds: ["acct-everyday"],
    transactions: [txn({ id: "dining", amount: -86600, flag_color: "red" })],
  });
  expect(report.cards).toHaveLength(0);
  expect(report.groups).toHaveLength(0);
});
