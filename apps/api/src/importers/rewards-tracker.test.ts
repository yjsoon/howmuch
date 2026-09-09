import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, setSystemTime, test } from "bun:test";
import { applyMigrations } from "../db";
import { LedgerRepository, ValidationError } from "../repository";
import { buildRewardsReport } from "../rewards/build";
import { SimpleRewardsCalculator } from "../rewards/engine/simple-calculator";
import { parseCreditCards } from "../rewards/parse";
import { importRewardsTrackerExport, parseRewardsTrackerExport } from "./rewards-tracker";
import officialExport from "../../../../fixtures/rewards-tracker-export.json";
import fatExport from "../../../../fixtures/rewards-tracker-export-with-cache.json";

let db: Database;
let repo: LedgerRepository;

beforeEach(() => {
  db = new Database(":memory:");
  applyMigrations(db);
  repo = new LedgerRepository(db, "plan-test");
});

afterEach(() => {
  setSystemTime();
  db.close();
});

describe("parseRewardsTrackerExport", () => {
  test("migrates legacy points and absent rates without replacing modern null or zero", () => {
    const base = { id: "legacy", name: "Legacy", ynabAccountId: "a", type: "points" };
    const parsed = parseRewardsTrackerExport({ cards: [base, { ...base, id: "default" }, { ...base, id: "null", earningRate: null }, { ...base, id: "zero", earningRate: 0 }],
      rules: [{ cardId: "legacy", active: false, rewardValue: 9 }, { cardId: "legacy", active: true, rewardValue: 0, rewardType: "points" }, { cardId: "legacy", active: true, rewardValue: 5 }],
      settings: { pointsValuation: 0, milesValuation: null } });
    expect(parsed.portable.cards.map(c => [c.type, c.earningRate])).toEqual([["miles", 0], ["miles", 1], ["miles", null], ["miles", 0]]);
    expect(parsed.portable.rules[1]).toMatchObject({ rewardType: "miles" });
    expect(parsed.portable.settings).toEqual({ milesValuation: 0 });
    expect(parseRewardsTrackerExport({ cards: [], settings: { milesValuation: 0, pointsValuation: 0.02 } }).portable.settings).toEqual({ milesValuation: 0 });
    expect(parseRewardsTrackerExport({ cards: [base], rules: [{ cardId: "legacy", active: true, rewardValue: null }, { cardId: "legacy", active: true, rewardValue: 4 }] }).portable.cards[0].earningRate).toBe(1);
  });

  test("reads the official Settings export and strips secrets", () => {
    const parsed = parseRewardsTrackerExport({
      ...officialExport,
      ynab: { ...officialExport.ynab, pat: "secret-pat", howmuchToken: "secret-howmuch" },
      settings: { ...officialExport.settings, cloudSyncMnemonic: "one two three", statementFormatter: { apiKeys: { openai: "sk" } } },
    });

    expect(parsed.portable.cards).toHaveLength(1);
    expect(parsed.portable.cards[0]).toMatchObject({ id: "card-travel", ynabAccountId: "acct-credit" });
    expect(parsed.portable.tagMappings).toHaveLength(2);
    expect(parsed.portable.ynab.trackedAccountIds).toEqual(["acct-credit"]);
    expect(parsed.portable.settings.cloudSyncMnemonic).toBeUndefined();
    expect((parsed.portable.settings.statementFormatter as { apiKeys?: unknown } | undefined)?.apiKeys).toBeUndefined();
    expect(parsed.transactions).toEqual([]);
  });

  test("collects YNAB-shaped cache from a fat dump", () => {
    const parsed = parseRewardsTrackerExport(fatExport);
    expect(parsed.accounts).toEqual([
      expect.objectContaining({ id: "acct-rewards", name: "Rewards Card", type: "creditCard", fromCache: true }),
    ]);
    expect(parsed.transactions).toEqual([
      expect.objectContaining({ id: "txn-candlenut", amount: -8600000, flag_color: "orange" }),
    ]);
    expect(parsed.flagNames).toEqual({ orange: "Dining", green: "Groceries" });
  });

  test("rejects JSON that is not a Rewards Tracker export", () => {
    expect(() => parseRewardsTrackerExport({ budgets: [] })).toThrow(ValidationError);
    expect(() => parseRewardsTrackerExport(null)).toThrow(ValidationError);
  });
});

describe("importRewardsTrackerExport", () => {
  // Pinned app-core/src/storage/migrations.ts:55-66 migrates only absent
  // startDate to the previous calendar month; explicit null stays dynamic.
  test("legacy promotion migration pools April and May spend and survives portable reimport", async () => {
    setSystemTime(new Date("2026-05-15T04:00:00Z"));
    await importRewardsTrackerExport(repo, "plan-test", {
      cards: [{ id: "promo", name: "Miles", ynabAccountId: "a", type: "miles", earningRate: 2,
        maximumSpend: 100, promotionalPeriod: { endDate: "2026-06-30" } }],
      cachedData: { transactions: [
        { id: "apr", account_id: "a", date: "2026-04-20", amount: -80000 },
        { id: "may", account_id: "a", date: "2026-05-05", amount: -70000 },
      ] },
    });
    const exported = await repo.getRewardsTrackerSnapshot("plan-test");
    const report = buildRewardsReport({
      cards: parseCreditCards(exported.cards), transactions: await repo.listTransactions("plan-test", {}),
      accountNames: {}, settings: {}, from: null, to: "2026-05-10", groupBy: "payee", accountIds: [],
    });
    expect(report.totals.miles).toBe(200);
    expect(report.cards[0].calculation).toMatchObject({ maximum_spend_exceeded: true, should_stop_using: true });
    expect(exported.snapshot).toMatchObject({ cards: [{ promotionalPeriod: { startDate: "2026-04-01", endDate: "2026-06-30" } }] });
    setSystemTime(new Date("2026-06-15T04:00:00Z"));
    await importRewardsTrackerExport(repo, "plan-test", exported.snapshot);
    expect((await repo.getRewardsTrackerSnapshot("plan-test")).cards).toEqual(exported.cards);
  });

  test("promotion migration uses the SGT calendar across January and preserves explicit null", async () => {
    setSystemTime(new Date("2025-12-31T16:30:00Z")); // January 1 in Singapore.
    const card = { name: "Miles", ynabAccountId: "a", type: "miles", earningRate: 2 };
    await importRewardsTrackerExport(repo, "plan-test", { cards: [
      { ...card, id: "legacy", promotionalPeriod: { endDate: "2026-06-30" } },
      { ...card, id: "dynamic", promotionalPeriod: { startDate: null, endDate: "2026-06-30" } },
    ] });
    const { cards } = await repo.getRewardsTrackerSnapshot("plan-test");
    expect(cards.find((c) => c.id === "legacy")).toMatchObject({ promotionalPeriod: { startDate: "2025-12-01" } });
    expect(cards.find((c) => c.id === "dynamic")).toMatchObject({ promotionalPeriod: { startDate: null } });
  });

  test("round-trips a modern export with nullable base fields and numeric category overrides", async () => {
    const card = { id: "modern", name: "Miles", issuer: "Bank", type: "miles", ynabAccountId: "a", earningRate: null, maximumSpend: 0,
      rewardPeriod: { monthCount: 3, anchorDate: "2026-01-31", monthlyMinimumSpend: 0 },
      promotionalPeriod: { startDate: null, endDate: "2026-12-31" },
      subcategories: [{ id: "s", name: "Dining", flagColor: "red", rewardValue: 0, priority: 0, active: true, createdAt: "2026-01-01", updatedAt: "2026-01-01" }],
      spendingTiers: [{ id: "t", spendThreshold: 500, earningRate: null, maximumSpend: null, subcategories: [{ subcategoryId: "s", rewardValue: 4, maximumSpend: 0 }] }] };
    await importRewardsTrackerExport(repo, "plan-test", { cards: [card], settings: { milesValuation: 0 } });
    const snapshot = await repo.getRewardsTrackerSnapshot("plan-test");
    expect(snapshot.cards).toEqual([card]);
    expect(snapshot.snapshot).toMatchObject({ settings: { milesValuation: 0 } });
  });

  test("name-only cached refund and inflow metadata drive monthly qualification", async () => {
    const card = { id: "c", name: "Miles", ynabAccountId: "a", type: "miles", earningRate: 1,
      rewardPeriod: { monthCount: 3, anchorDate: "2026-01-01", monthlyMinimumSpend: 800 } };
    const base = { account_id: "a", date: "2026-01-10" };
    await importRewardsTrackerExport(repo, "plan-test", { cards: [card], cachedData: { transactions: [
      { ...base, id: "purchase", amount: -900000 },
      { ...base, id: "refund", amount: 200000, category_name: "Dining" },
      { ...base, id: "inflow", amount: 300000, category_name: "Inflow: Ready to Assign" },
      { ...base, id: "deleted", amount: -1000000, deleted: true },
    ] } });
    const transactions = await repo.listTransactions("plan-test", {});
    const calculation = SimpleRewardsCalculator.calculateCardRewards(parseCreditCards([card])[0], transactions, {
      start: "2026-01-01", end: "2026-03-31", label: "quarter", asOf: "2026-02-01",
    });
    expect(calculation.monthlyQualifications?.[0]).toMatchObject({ spend: 700, status: "failed" });
    expect(calculation.totalSpend).toBe(900);
  });

  test("name-only cache preserves matched identities and resolves only unique existing names", async () => {
    await repo.ensureCategory("plan-test", "native", "Native Dining");
    await repo.ensureCategory("plan-test", "unique", "Groceries");
    await repo.ensureCategory("plan-test", "ambiguous-1", "Dining");
    await repo.ensureCategory("plan-test", "ambiguous-2", "Dining");
    const base = { account_id: "a", date: "2026-01-10" };
    await repo.createTransaction("plan-test", { ...base, id: "matched", amount: 1000, category_id: "native" });
    const load = (transactions: object[], planId = "plan-test") => importRewardsTrackerExport(repo, planId, { cards: [], cachedData: { transactions } });
    await load([
      { ...base, id: "matched", amount: 1000, category_name: "Dining" },
      { ...base, id: "unique-txn", amount: 2000, category_name: "Groceries" },
      { ...base, id: "new-txn", amount: 3000, category_name: "Dining" },
    ]);
    expect(await repo.getTransaction("plan-test", "matched")).toMatchObject({ category_id: "native", category_name: "Native Dining" });
    expect((await repo.getTransaction("plan-test", "unique-txn")).category_id).toBe("unique");
    const generated = (await repo.getTransaction("plan-test", "new-txn")).category_id;
    expect(generated).toBeString();
    expect(["ambiguous-1", "ambiguous-2"]).not.toContain(generated);
    await load([{ ...base, id: "another-txn", amount: 4000, category_name: "Dining" }]);
    expect((await repo.getTransaction("plan-test", "another-txn")).category_id).toBe(generated);
    await load([{ ...base, account_id: "b", id: "other-plan-txn", amount: 5000, category_name: "Dining" }], "other-plan");
    expect((await repo.getTransaction("other-plan", "other-plan-txn")).category_id).not.toBe(generated);
    await load([{ ...base, id: "matched", amount: 1000, category_name: null }]);
    expect(await repo.getTransaction("plan-test", "matched")).toMatchObject({ category_id: null, category_name: null });
  });

  test("explicit null valuation clears the native value instead of behaving like omission", async () => {
    await repo.patchRewardsTrackerSettings("plan-test", { milesValuation: 0.05 });
    await importRewardsTrackerExport(repo, "plan-test", { cards: [], settings: { milesValuation: null } });
    expect((await repo.getRewardsTrackerSnapshot("plan-test")).snapshot).toMatchObject({ settings: { milesValuation: null } });
  });

  test("retains refund categories, preserves omissions, and clears explicit null metadata", async () => {
    const transaction = { id: "refund", account_id: "a", date: "2026-01-02", amount: 5000, category_id: "dining", category_name: "Dining", memo: "refund", flag_color: "red", flag_name: "Dining", payee_name: "Merchant", transfer_account_id: "other", transfer_transaction_id: "other-txn", cleared: "reconciled", approved: true };
    const load = (txn: object) => importRewardsTrackerExport(repo, "plan-test", { cards: [], cachedData: { transactions: [txn] } });
    await load(transaction);
    expect(await repo.getTransaction("plan-test", "refund")).toMatchObject({ category_id: "dining", category_name: "Dining" });
    const partial = { id: "refund", account_id: "a", date: "2026-01-02", amount: 0 };
    await load(partial);
    expect(await repo.getTransaction("plan-test", "refund")).toMatchObject({ amount: 0, memo: "refund", flag_color: "red", category_name: "Dining", cleared: "reconciled", approved: true });
    await load({ ...partial, category_id: null, category_name: null, memo: null, flag_color: null, flag_name: null, payee_name: null, transfer_account_id: null, transfer_transaction_id: null, cleared: null, approved: null });
    expect(await repo.getTransaction("plan-test", "refund")).toMatchObject({ category_id: null, category_name: null, memo: null, flag_color: null, flag_name: null, payee_name: null, transfer_account_id: null, transfer_transaction_id: null, cleared: "uncleared", approved: false });
  });

  test("imports tombstones without claiming an unrelated matching local row", async () => {
    const transaction = { account_id: "a", date: "2026-01-02", amount: -5000 };
    await repo.createTransaction("plan-test", { ...transaction, id: "local" });
    const load = (txn: object) => importRewardsTrackerExport(repo, "plan-test", { cards: [], cachedData: { transactions: [txn] } });
    await load({ ...transaction, id: "deleted-source", deleted: true });
    expect((await repo.getTransaction("plan-test", "local")).deleted).toBe(false);
    expect((await repo.getTransaction("plan-test", "deleted-source", true)).deleted).toBe(true);
    await load({ ...transaction, id: "local", deleted: true });
    expect((await repo.getTransaction("plan-test", "local", true)).deleted).toBe(true);
    await load({ ...transaction, id: "local" });
    expect((await repo.getTransaction("plan-test", "local", true)).deleted).toBe(true);
    await load({ ...transaction, id: "local", deleted: false });
    expect((await repo.getTransaction("plan-test", "local")).deleted).toBe(false);
  });

  test("upserts official export cards without inventing transactions", async () => {
    const first = await importRewardsTrackerExport(repo, "plan-test", officialExport);
    const second = await importRewardsTrackerExport(repo, "plan-test", officialExport);

    expect(first.cards).toBe(1);
    expect(first.accounts_upserted).toBe(1);
    expect(first.transactions_imported).toBe(0);
    expect(second.cards).toBe(1);
    expect(second.transactions_imported).toBe(0);
    expect(db.query("SELECT COUNT(*) AS count FROM rewards_tracker_cards WHERE plan_id='plan-test' AND deleted=0").get()).toEqual({ count: 1 });
    expect(db.query("SELECT COUNT(*) AS count FROM transactions WHERE plan_id='plan-test' AND deleted=0").get()).toEqual({ count: 0 });
    expect(db.query("SELECT name FROM accounts WHERE id='acct-credit'").get()).toEqual({ name: "Travel Card" });
  });

  test("does not zero an existing HowMuch account when the official export only names it", async () => {
    await repo.upsertAccount("plan-test", { id: "acct-credit", name: "Travel Card", type: "creditCard", opening_balance: -64000000, balance: -64000000 });
    await importRewardsTrackerExport(repo, "plan-test", officialExport);
    expect(db.query("SELECT balance_milli FROM accounts WHERE id='acct-credit'").get()).toEqual({ balance_milli: -64000000 });
  });

  test("does not zero an existing HowMuch account when a fat dump only names it", async () => {
    await repo.upsertAccount("plan-test", { id: "acct-credit", name: "Travel Card", type: "creditCard", opening_balance: -64000000, balance: -64000000 });
    await importRewardsTrackerExport(repo, "plan-test", {
      ...officialExport,
      cachedData: {
        dashboardTransactions: [
          {
            budgetId: "plan-test",
            accounts: [{ id: "acct-credit", name: "Travel Card" }],
            transactions: [],
          },
        ],
      },
    });
    expect(db.query("SELECT balance_milli FROM accounts WHERE id='acct-credit'").get()).toEqual({ balance_milli: -64000000 });
  });

  test("upserts cached YNAB-shaped transactions without duplicating on replay", async () => {
    const first = await importRewardsTrackerExport(repo, "plan-test", fatExport);
    const second = await importRewardsTrackerExport(repo, "plan-test", {
      ...fatExport,
      cards: [{ ...fatExport.cards[0], earningRate: 2 }],
    });

    expect(first.transactions_imported).toBe(1);
    expect(first.transactions_updated).toBe(0);
    expect(second.transactions_imported).toBe(0);
    expect(second.transactions_updated).toBe(1);
    expect(db.query("SELECT COUNT(*) AS count FROM transactions WHERE plan_id='plan-test' AND deleted=0").get()).toEqual({ count: 1 });
    expect(db.query("SELECT amount_milli, flag_color, payee_name_snapshot FROM transactions WHERE id='txn-candlenut'").get()).toEqual({
      amount_milli: -8600000,
      flag_color: "orange",
      payee_name_snapshot: "Candlenut",
    });
    const snapshot = await repo.getRewardsTrackerSnapshot("plan-test");
    expect((snapshot.cards[0] as { earningRate?: number }).earningRate).toBe(2);
    expect(db.query("SELECT flag_names_json FROM plans WHERE id='plan-test'").get()).toEqual({
      flag_names_json: JSON.stringify({ orange: "Dining", green: "Groceries" }),
    });
  });

  test("lets a finite export milesValuation replace a native value", async () => {
    await repo.patchRewardsTrackerSettings("plan-test", { milesValuation: 0.05 });
    await importRewardsTrackerExport(repo, "plan-test", officialExport);
    const snapshot = await repo.getRewardsTrackerSnapshot("plan-test");
    expect((snapshot.snapshot as { settings: { milesValuation: number } }).settings.milesValuation).toBe(0.015);
  });

  test("keeps the native milesValuation when the export omits it", async () => {
    await repo.patchRewardsTrackerSettings("plan-test", { milesValuation: 0.05 });
    await importRewardsTrackerExport(repo, "plan-test", {
      ...officialExport,
      settings: { currency: "SGD" },
    });
    const snapshot = await repo.getRewardsTrackerSnapshot("plan-test");
    expect((snapshot.snapshot as { settings: { milesValuation: number } }).settings.milesValuation).toBe(0.05);
  });
});
