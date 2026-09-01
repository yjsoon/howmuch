import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { applyMigrations } from "../db";
import { LedgerRepository, ValidationError } from "../repository";
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
  db.close();
});

describe("parseRewardsTrackerExport", () => {
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
});
