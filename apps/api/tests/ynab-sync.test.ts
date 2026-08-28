import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, setSystemTime, test } from "bun:test";
import { DEFAULT_YNAB_SYNC_INTERVAL_MS, loadConfig, MIN_YNAB_SYNC_INTERVAL_MS } from "../src/config";
import { applyMigrations } from "../src/db";
import { importYnabFromApi, ynabSimilarity } from "../src/importers/ynab";
import { LedgerRepository } from "../src/repository";
import { startYnabSync } from "../src/sync";

let db: Database;
let repo: LedgerRepository;
const originalFetch = globalThis.fetch;

const silentLogger = { log() {}, warn() {}, error() {} };

beforeEach(() => {
  db = new Database(":memory:");
  applyMigrations(db);
  repo = new LedgerRepository(db, "plan-test");
});

afterEach(() => {
  globalThis.fetch = originalFetch;
  setSystemTime();
  db.close();
});

function ynabTransaction(id: string, overrides: Record<string, unknown> = {}) {
  return {
    id,
    account_id: "acct-1",
    date: "2026-06-01",
    amount: -1000,
    payee_id: null,
    payee_name: "Merchant",
    category_id: null,
    memo: null,
    cleared: "cleared",
    approved: true,
    flag_color: null,
    flag_name: null,
    transfer_account_id: null,
    transfer_transaction_id: null,
    matched_transaction_id: null,
    import_id: null,
    import_payee_name: null,
    import_payee_name_original: null,
    deleted: false,
    subtransactions: [],
    ...overrides,
  };
}

function stubYnabApi(
  transactions: unknown[],
  options: { plans?: unknown[]; accounts?: unknown[]; payees?: unknown[]; onFetch?: (url: string) => void; rateLimitHeader?: string } = {},
) {
  const headers = options.rateLimitHeader ? { "x-rate-limit": options.rateLimitHeader } : undefined;
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = String(input);
    options.onFetch?.(url);
    if (url.endsWith("/plans")) {
      return jsonResponse({ data: { plans: options.plans ?? [{ id: "plan-test", name: "Test Plan" }] } }, headers);
    }
    if (url.endsWith("/plans/plan-test")) {
      return jsonResponse({ data: { plan: { id: "plan-test", name: "Test Plan" } } }, headers);
    }
    if (url.endsWith("/plans/plan-test/settings")) {
      return jsonResponse({ data: { settings: {} } }, headers);
    }
    if (url.endsWith("/plans/plan-test/accounts")) {
      return jsonResponse(
        { data: { accounts: options.accounts ?? [{ id: "acct-1", name: "Checking", type: "checking", on_budget: true }] } },
        headers,
      );
    }
    if (url.endsWith("/plans/plan-test/categories")) {
      return jsonResponse({ data: { category_groups: [] } }, headers);
    }
    if (url.endsWith("/plans/plan-test/payees")) {
      return jsonResponse({ data: { payees: options.payees ?? [] } }, headers);
    }
    if (url.includes("/plans/plan-test/transactions")) {
      return jsonResponse({ data: { transactions } }, headers);
    }
    return new Response("not found", { status: 404 });
  }) as typeof fetch;
}

function jsonResponse(body: unknown, extraHeaders?: Record<string, string>): Response {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json", ...extraHeaders },
  });
}

async function seedLedgerFromYnab(transactions: unknown[]): Promise<void> {
  stubYnabApi(transactions);
  await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test" });
}

describe("YNAB similarity guard", () => {
  test("preserves a full-plan export losslessly, including months, schedules, locations, and movements", async () => {
    const fullPlan = {
      id: "plan-test", name: "Complete plan", first_month: "2026-01", last_month: "2026-12",
      accounts: [{ id: "acct-1", name: "Checking", type: "checking", on_budget: true, balance: 1250, transfer_payee_id: "transfer-1", note: "account note", deleted: false }],
      category_groups: [{ id: "group-1", name: "Everyday", hidden: false }],
      categories: [{ id: "category-1", category_group_id: "group-1", name: "Food", note: "category note", deleted: false }],
      payees: [{ id: "transfer-1", name: "Transfer: Checking", transfer_account_id: "acct-1", deleted: false }, { id: "payee-1", name: "Shop", deleted: false }],
      payee_locations: [{ id: "location-1", payee_id: "payee-1", latitude: "1.2", longitude: "3.4", deleted: false }],
      months: [{ month: "2026-06-01", note: "month note", income: 9000, budgeted: 5000, activity: -1200, to_be_budgeted: 4000, age_of_money: 21, deleted: false, categories: [{ id: "category-1", category_group_id: "group-1", name: "Food", budgeted: 5000, activity: -1200, balance: 3800, goal_type: "TB", goal_target: 10000, goal_target_month: "2026-07-01", deleted: false }] }],
      transactions: [{ ...ynabTransaction("transaction-1", { account_id: "acct-1", payee_id: "payee-1", category_id: "legacy-split-parent-category", amount: -1200, account_note: "discarded by ledger but raw", subtransactions: undefined }) }],
      subtransactions: [{ id: "sub-1", transaction_id: "transaction-1", amount: -1200, payee_id: "payee-1", category_id: "category-1", memo: "split note", deleted: false }],
      scheduled_transactions: [{ id: "scheduled-1", account_id: "acct-1", date_first: "2026-06-10", date_next: "2026-07-10", frequency: "monthly", amount: -500, payee_id: "payee-1", category_id: "category-1", deleted: false }],
      scheduled_subtransactions: [{ id: "scheduled-sub-1", scheduled_transaction_id: "scheduled-1", amount: -500, payee_id: "payee-1", category_id: "category-1", deleted: false }],
    };
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/settings")) return jsonResponse({ data: { settings: { date_format: { format: "YYYY-MM-DD" }, currency_format: { iso_code: "USD" }, display: { flag_names: { blue: "Follow up" } } } } });
      if (url.includes("/money_movements")) return jsonResponse({ data: { money_movements: [{ id: "movement-1", month: "2026-06-01", from_category_id: "category-1", to_category_id: "category-1", amount: 100, note: "move", deleted: false }] } });
      if (url.includes("/money_movement_groups")) return jsonResponse({ data: { money_movement_groups: [{ id: "movement-group-1", month: "2026-06-01", note: "group", deleted: false }] } });
      if (url.endsWith("/plans/plan-test")) return jsonResponse({ data: { plan: fullPlan, server_knowledge: 88 } });
      return new Response("not found", { status: 404 });
    }) as typeof fetch;

    const result = await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test" });
    expect(result.raw_objects).toMatchObject({ account: 1, month: 1, month_category: 1, scheduled_transaction: 1, scheduled_subtransaction: 1, payee_location: 1, money_movement: 1, money_movement_group: 1, transaction: 1, subtransaction: 1 });
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE plan_id='plan-test' AND object_type='account' AND object_id='acct-1'").get()).toEqual({ payload_json: JSON.stringify(fullPlan.accounts[0]) });
    expect(db.query("SELECT category_id FROM transactions WHERE id='transaction-1'").get()).toEqual({ category_id: null });
    expect(db.query("SELECT category_id FROM subtransactions WHERE id='sub-1'").get()).toEqual({ category_id: "category-1" });
    expect(db.query("SELECT id FROM categories WHERE plan_id='plan-test' ORDER BY id").all()).toEqual([{ id: "category-1" }]);
    expect(db.query("SELECT id FROM category_groups WHERE plan_id='plan-test' ORDER BY id").all()).toEqual([{ id: "group-1" }]);
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='transaction' AND object_id='transaction-1'").get()).toEqual({ payload_json: JSON.stringify(fullPlan.transactions[0]) });
    expect(await repo.getMonth("plan-test", "2026-06")).toEqual(fullPlan.months[0]);
    expect(await repo.listYnabRawObjects("plan-test", "scheduled_subtransaction")).toEqual(fullPlan.scheduled_subtransactions);
  });

  test("updates raw tombstones and full-list money movement data on a cursor delta", async () => {
    const deltaPlan = { id: "plan-test", name: "Test Plan", accounts: [], category_groups: [], categories: [], payees: [], payee_locations: [], months: [], transactions: [{ ...ynabTransaction("deleted-transaction", { account_id: "acct-1", deleted: true }) }], subtransactions: [], scheduled_transactions: [], scheduled_subtransactions: [] };
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.includes("/settings")) return jsonResponse({ data: { settings: {} } });
      if (url.includes("/money_movement_groups")) return jsonResponse({ data: { money_movement_groups: [{ id: "group-delta", month: "2026-06-01", deleted: true }] } });
      if (url.includes("/money_movements")) return jsonResponse({ data: { money_movements: [{ id: "movement-delta", month: "2026-06-01", deleted: true }] } });
      if (url.includes("/plans/plan-test?last_knowledge_of_server=7")) return jsonResponse({ data: { plan: deltaPlan, server_knowledge: 9 } });
      return new Response("not found", { status: 404 });
    }) as typeof fetch;
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Test Plan" });
    await repo.upsertPayee("plan-test", { id: "payee-1", name: "Payee" });
    await repo.upsertAccount("plan-test", { id: "acct-1", name: "Checking" });
    await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test", lastKnowledgeOfServer: 7 });
    expect(db.query("SELECT deleted FROM ynab_raw_objects WHERE object_type='transaction' AND object_id='deleted-transaction'").get()).toEqual({ deleted: 1 });
    expect(db.query("SELECT deleted FROM ynab_raw_objects WHERE object_type='money_movement' AND object_id='movement-delta'").get()).toEqual({ deleted: 1 });
    expect(db.query("SELECT deleted FROM ynab_raw_objects WHERE object_type='money_movement_group' AND object_id='group-delta'").get()).toEqual({ deleted: 1 });
  });

  test("imports reciprocal transfer payees before their accounts", async () => {
    stubYnabApi([], {
      accounts: [{
        id: "acct-transfer",
        name: "Savings",
        type: "savings",
        on_budget: true,
        transfer_payee_id: "payee-transfer",
      }],
      payees: [{
        id: "payee-transfer",
        name: "Transfer : Savings",
        transfer_account_id: "acct-transfer",
        deleted: false,
      }],
    });

    await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test" });

    expect(db.query("SELECT transfer_payee_id FROM accounts WHERE id='acct-transfer'").get()).toEqual({ transfer_payee_id: "payee-transfer" });
    expect(db.query("SELECT name,transfer_account_id FROM payees WHERE id='payee-transfer'").get()).toEqual({ name: "Transfer : Savings", transfer_account_id: "acct-transfer" });
    expect(db.query("PRAGMA foreign_key_check").all()).toEqual([]);
  });

  test("imports duplicate-name YNAB payees as distinct IDs with their transactions", async () => {
    stubYnabApi([
      ynabTransaction("transaction-a", { payee_id: "payee-a", payee_name: "Same merchant" }),
      ynabTransaction("transaction-b", { payee_id: "payee-b", payee_name: "Same merchant" }),
    ], {
      payees: [
        { id: "payee-a", name: "Same merchant", deleted: false },
        { id: "payee-b", name: "Same merchant", deleted: false },
      ],
    });

    await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test" });

    expect(db.query("SELECT id,name,external_ynab_id FROM payees WHERE id IN ('payee-a','payee-b') ORDER BY id").all()).toEqual([
      { id: "payee-a", name: "Same merchant", external_ynab_id: "payee-a" },
      { id: "payee-b", name: "Same merchant", external_ynab_id: "payee-b" },
    ]);
    expect(db.query("SELECT id,payee_id,payee_name_snapshot FROM transactions WHERE id IN ('transaction-a','transaction-b') ORDER BY id").all()).toEqual([
      { id: "transaction-a", payee_id: "payee-a", payee_name_snapshot: "Same merchant" },
      { id: "transaction-b", payee_id: "payee-b", payee_name_snapshot: "Same merchant" },
    ]);
  });

  test("adopts a HowMuch-local row instead of inserting a second copy", async () => {
    await repo.ensureAccount("plan-test", "acct-1", "Checking");
    const local = await repo.createTransaction("plan-test", {
      account_id: "acct-1",
      date: "2026-06-01",
      amount: -94960,
      payee_name: "Genki Sushi",
      cleared: "uncleared",
      approved: false,
    });

    stubYnabApi([
      ynabTransaction("ynab-genki", {
        account_id: "acct-1",
        amount: -94960,
        payee_name: "Genki Sushi",
        approved: false,
        cleared: "uncleared",
      }),
    ]);

    await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test" });

    const rows = db
      .query("SELECT id, external_ynab_id, source_kind, deleted FROM transactions WHERE plan_id='plan-test' AND deleted=0 ORDER BY id")
      .all() as Array<{ id: string; external_ynab_id: string | null; source_kind: string | null; deleted: number }>;
    expect(rows).toEqual([
      { id: local.id, external_ynab_id: "ynab-genki", source_kind: "ynab-import", deleted: 0 },
    ]);
  });

  test("adopts a local transfer when YNAB uses a different payee name", async () => {
    await repo.ensureAccount("plan-test", "acct-1", "Checking");
    await repo.ensureAccount("plan-test", "acct-2", "Work Refundables");
    const workPayee = db
      .query("SELECT id FROM payees WHERE plan_id='plan-test' AND transfer_account_id='acct-2' AND deleted=0")
      .get() as { id: string };
    const local = await repo.createTransaction("plan-test", {
      account_id: "acct-1",
      date: "2026-06-01",
      amount: -36000,
      payee_id: workPayee.id,
      cleared: "uncleared",
      approved: false,
    });

    stubYnabApi([
      ynabTransaction("ynab-out", {
        account_id: "acct-1",
        amount: -36000,
        payee_name: "Transfer : Work Refundables",
        transfer_account_id: "acct-2",
        transfer_transaction_id: "ynab-in",
        approved: false,
        cleared: "uncleared",
      }),
      ynabTransaction("ynab-in", {
        account_id: "acct-2",
        amount: 36000,
        payee_name: "Transfer : Checking",
        transfer_account_id: "acct-1",
        transfer_transaction_id: "ynab-out",
        approved: false,
        cleared: "uncleared",
      }),
    ], {
      accounts: [
        { id: "acct-1", name: "Checking", type: "checking", on_budget: true },
        { id: "acct-2", name: "Work Refundables", type: "checking", on_budget: true },
      ],
    });

    await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test" });

    const rows = db
      .query("SELECT id, account_id, amount_milli, external_ynab_id FROM transactions WHERE plan_id='plan-test' AND deleted=0 ORDER BY amount_milli")
      .all() as Array<{ id: string; account_id: string; amount_milli: number; external_ynab_id: string | null }>;
    expect(rows).toHaveLength(2);
    expect(rows.map((row) => row.id).sort()).toEqual([local.id, local.transfer_transaction_id].sort());
    expect(rows.find((row) => row.account_id === "acct-1")?.external_ynab_id).toBe("ynab-out");
    expect(rows.find((row) => row.account_id === "acct-2")?.external_ynab_id).toBe("ynab-in");
  });

  test("keeps local split lines when YNAB adopts the parent", async () => {
    await repo.ensureAccount("plan-test", "acct-1", "Checking");
    await repo.ensureCategory("plan-test", "cat-food", "Food");
    await repo.ensureCategory("plan-test", "cat-fun", "Fun");
    const local = await repo.createTransaction("plan-test", {
      account_id: "acct-1",
      date: "2026-06-01",
      amount: -1000,
      payee_name: "Split shop",
      subtransactions: [
        { amount: -600, category_id: "cat-food" },
        { amount: -400, category_id: "cat-fun" },
      ],
    });

    stubYnabApi([
      ynabTransaction("ynab-split-parent", {
        account_id: "acct-1",
        amount: -1000,
        payee_name: "Split shop",
      }),
    ]);

    await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test" });

    expect(db.query("SELECT external_ynab_id FROM transactions WHERE id=?").get(local.id)).toEqual({
      external_ynab_id: "ynab-split-parent",
    });
    const adopted = await repo.getTransaction("plan-test", local.id);
    expect(adopted.subtransactions.map((sub: { amount: number; category_id: string }) => [sub.amount, sub.category_id])).toEqual([
      [-600, "cat-food"],
      [-400, "cat-fun"],
    ]);
  });

  test("applies YNAB split lines when the adopted local row has none", async () => {
    await repo.ensureAccount("plan-test", "acct-1", "Checking");
    const local = await repo.createTransaction("plan-test", {
      account_id: "acct-1",
      date: "2026-06-01",
      amount: -1000,
      payee_name: "Later split",
    });

    stubYnabApi([
      ynabTransaction("ynab-later-split", {
        account_id: "acct-1",
        amount: -1000,
        payee_name: "Later split",
        category_id: "ignored-parent",
        subtransactions: [
          { id: "sub-a", transaction_id: "ynab-later-split", amount: -700, category_id: "cat-a" },
          { id: "sub-b", transaction_id: "ynab-later-split", amount: -300, category_id: "cat-b" },
        ],
      }),
    ]);

    await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test" });

    const adopted = await repo.getTransaction("plan-test", local.id);
    expect(adopted.subtransactions.map((sub: { amount: number }) => sub.amount).sort()).toEqual([-700, -300].sort());
    expect(adopted.category_id).toBeNull();
  });

  test("keeps a YNAB transfer link when the adopted local row is not a transfer", async () => {
    await repo.ensureAccount("plan-test", "acct-1", "Checking");
    await repo.ensureAccount("plan-test", "acct-2", "Savings");
    const local = await repo.createTransaction("plan-test", {
      account_id: "acct-1",
      date: "2026-06-01",
      amount: -25000,
      payee_name: "Moved",
    });

    stubYnabApi([
      ynabTransaction("ynab-out", {
        account_id: "acct-1",
        amount: -25000,
        payee_name: "Transfer : Savings",
        transfer_account_id: "acct-2",
        transfer_transaction_id: "ynab-in",
      }),
      ynabTransaction("ynab-in", {
        account_id: "acct-2",
        amount: 25000,
        payee_name: "Transfer : Checking",
        transfer_account_id: "acct-1",
        transfer_transaction_id: "ynab-out",
      }),
    ], {
      accounts: [
        { id: "acct-1", name: "Checking", type: "checking", on_budget: true },
        { id: "acct-2", name: "Savings", type: "checking", on_budget: true },
      ],
    });

    await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test" });

    const adopted = await repo.getTransaction("plan-test", local.id);
    expect(adopted.transfer_account_id).toBe("acct-2");
    expect(adopted.transfer_transaction_id).not.toBe("ynab-out");
    const counterpart = await repo.getTransaction("plan-test", adopted.transfer_transaction_id);
    expect(counterpart.account_id).toBe("acct-2");
    expect(counterpart.transfer_transaction_id).toBe(local.id);
  });

  test("does not adopt a local row from an unmatched YNAB tombstone", async () => {
    await repo.ensureAccount("plan-test", "acct-1", "Checking");
    const local = await repo.createTransaction("plan-test", {
      account_id: "acct-1",
      date: "2026-06-01",
      amount: -1000,
      payee_name: "Keep me",
    });

    stubYnabApi([
      ynabTransaction("ynab-gone", {
        account_id: "acct-1",
        amount: -1000,
        payee_name: "Gone in YNAB",
        deleted: true,
      }),
    ]);

    await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test" });

    expect(db.query("SELECT deleted, external_ynab_id FROM transactions WHERE id=?").get(local.id)).toEqual({
      deleted: 0,
      external_ynab_id: local.id,
    });
    expect(db.query("SELECT id FROM transactions WHERE id='ynab-gone'").get()).toBeNull();
  });

  test("first sync into an empty ledger is never blocked", async () => {
    stubYnabApi([ynabTransaction("txn-1"), ynabTransaction("txn-2")]);

    const result = await importYnabFromApi(repo, {
      token: "ynab-token",
      planId: "plan-test",
      minSimilarity: 0.95,
    });

    expect(result.skipped).toBeUndefined();
    expect(result.imported_transactions).toBe(2);
  });

  test("skips the import when fetched data is less than 95% similar", async () => {
    const seeded = Array.from({ length: 20 }, (_, i) => ynabTransaction(`txn-${i}`));
    await seedLedgerFromYnab(seeded);

    // 20 existing, only 17 still present: 17 / 23 union ≈ 74% similar.
    const divergent = [
      ...seeded.slice(0, 17),
      ynabTransaction("other-1"),
      ynabTransaction("other-2"),
      ynabTransaction("other-3"),
    ];
    stubYnabApi(divergent);

    const result = await importYnabFromApi(repo, {
      token: "ynab-token",
      planId: "plan-test",
      minSimilarity: 0.95,
    });

    expect(result.skipped).toBe(true);
    expect(result.similarity).toBeLessThan(0.95);
    expect(result.imported_transactions).toBe(0);

    const stored = db
      .query("SELECT COUNT(*) AS count FROM transactions WHERE plan_id = 'plan-test'")
      .get() as { count: number };
    expect(stored.count).toBe(20);

    const session = db
      .query("SELECT status FROM import_sessions WHERE id = ?")
      .get(result.import_session_id) as { status: string };
    expect(session.status).toBe("skipped");
  });

  test("imports when data stays at least 95% similar", async () => {
    const seeded = Array.from({ length: 40 }, (_, i) => ynabTransaction(`txn-${i}`));
    await seedLedgerFromYnab(seeded);

    // 40 unchanged plus one new transaction: 40 / 41 ≈ 98% similar.
    stubYnabApi([...seeded, ynabTransaction("txn-new")]);

    const result = await importYnabFromApi(repo, {
      token: "ynab-token",
      planId: "plan-test",
      minSimilarity: 0.95,
    });

    expect(result.skipped).toBeUndefined();
    expect(result.imported_transactions).toBe(41);
  });

  test("similarity compares id, date, and amount", () => {
    const existing = [
      { external_ynab_id: "a", date: "2026-06-01", amount_milli: -1000 },
      { external_ynab_id: "b", date: "2026-06-02", amount_milli: -2000 },
    ];
    expect(
      ynabSimilarity(existing, [
        { id: "a", date: "2026-06-01", amount: -1000 },
        { id: "b", date: "2026-06-02", amount: -2000 },
      ]),
    ).toBe(1);
    // Same ids but rewritten amounts count as fully different data.
    expect(
      ynabSimilarity(existing, [
        { id: "a", date: "2026-06-01", amount: -9999 },
        { id: "b", date: "2026-06-02", amount: -9999 },
      ]),
    ).toBe(0);
    expect(ynabSimilarity([], [])).toBe(1);
  });
});

describe("YNAB hourly sync", () => {
  test("does not start when no token is configured", async () => {
    let fetchCalls = 0;
    stubYnabApi([], { onFetch: () => (fetchCalls += 1) });

    for (const ynabToken of [undefined, "", "   "]) {
      const handle = startYnabSync(repo, baseConfig({ ynabToken }), silentLogger);
      expect(handle).toBeNull();
    }

    await Bun.sleep(50);
    expect(fetchCalls).toBe(0);
  });

  test("syncs immediately and again on each interval", async () => {
    let transactionFetches = 0;
    stubYnabApi([ynabTransaction("txn-1")], {
      onFetch: (url) => {
        if (url.includes("/transactions")) {
          transactionFetches += 1;
        }
      },
    });

    const handle = startYnabSync(
      repo,
      baseConfig({ ynabToken: "ynab-token", ynabPlanId: "plan-test", ynabSyncIntervalMs: 25 }),
      silentLogger,
    );
    expect(handle).not.toBeNull();

    try {
      await Bun.sleep(120);
      expect(transactionFetches).toBeGreaterThanOrEqual(2);

      const stored = db
        .query("SELECT COUNT(*) AS count FROM transactions WHERE plan_id = 'plan-test'")
        .get() as { count: number };
      expect(stored.count).toBe(1);
    } finally {
      handle?.stop();
    }

    const fetchesAfterStop = transactionFetches;
    await Bun.sleep(80);
    expect(transactionFetches).toBe(fetchesAfterStop);
  });

  test("discovers the plan when the token can only see one", async () => {
    stubYnabApi([ynabTransaction("txn-1")]);

    const handle = startYnabSync(repo, baseConfig({ ynabToken: "ynab-token" }), silentLogger);
    try {
      const result = await handle!.runNow();
      expect(result?.imported_transactions).toBe(1);
    } finally {
      handle?.stop();
    }
  });

  test("refuses to guess when multiple plans are visible", async () => {
    let errors = 0;
    stubYnabApi([ynabTransaction("txn-1")], {
      plans: [
        { id: "plan-a", name: "Plan A" },
        { id: "plan-b", name: "Plan B" },
      ],
    });

    const handle = startYnabSync(
      repo,
      baseConfig({ ynabToken: "ynab-token" }),
      { ...silentLogger, error: () => (errors += 1) },
    );
    try {
      const result = await handle!.runNow();
      expect(result).toBeNull();
      expect(errors).toBeGreaterThanOrEqual(1);

      const stored = db.query("SELECT COUNT(*) AS count FROM transactions").get() as { count: number };
      expect(stored.count).toBe(0);
    } finally {
      handle?.stop();
    }
  });

  test("applies the 95% guard on scheduled passes", async () => {
    const seeded = Array.from({ length: 20 }, (_, i) => ynabTransaction(`txn-${i}`));
    await seedLedgerFromYnab(seeded);

    stubYnabApi([ynabTransaction("foreign-1"), ynabTransaction("foreign-2")]);

    const handle = startYnabSync(
      repo,
      baseConfig({ ynabToken: "ynab-token", ynabPlanId: "plan-test" }),
      silentLogger,
    );
    try {
      const result = await handle!.runNow();
      expect(result === null || result.skipped === true).toBe(true);
      await Bun.sleep(20);

      const stored = db
        .query("SELECT COUNT(*) AS count FROM transactions WHERE plan_id = 'plan-test'")
        .get() as { count: number };
      expect(stored.count).toBe(20);
    } finally {
      handle?.stop();
    }
  });
});

describe("YNAB rate limit safety", () => {
  test("loadConfig clamps the sync interval to the five-minute floor", () => {
    expect(loadConfig({}).ynabSyncIntervalMs).toBe(DEFAULT_YNAB_SYNC_INTERVAL_MS);
    expect(loadConfig({ HOWMUCH_YNAB_SYNC_INTERVAL_MS: "1000" }).ynabSyncIntervalMs).toBe(MIN_YNAB_SYNC_INTERVAL_MS);
    expect(loadConfig({ HOWMUCH_YNAB_SYNC_INTERVAL_MS: "7200000" }).ynabSyncIntervalMs).toBe(7200000);
  });

  test("enables transition read-only mode only for the literal value true", () => {
    expect(loadConfig({ HOWMUCH_TRANSITION_READ_ONLY: "true" }).transitionReadOnly).toBeTrue();
    for (const value of [undefined, "false", "TRUE", " true", "true "]) {
      expect(loadConfig({ HOWMUCH_TRANSITION_READ_ONLY: value }).transitionReadOnly).toBeFalse();
    }
  });

  test("pauses for an hour after YNAB returns 429, then resumes", async () => {
    let fetchCalls = 0;
    let warned = 0;
    globalThis.fetch = (async () => {
      fetchCalls += 1;
      return new Response("too many requests", { status: 429 });
    }) as typeof fetch;

    const handle = startYnabSync(
      repo,
      baseConfig({ ynabToken: "ynab-token", ynabPlanId: "plan-test" }),
      { ...silentLogger, warn: () => (warned += 1) },
    );
    try {
      await handle!.runNow();
      expect(fetchCalls).toBeGreaterThan(0);
      expect(warned).toBeGreaterThanOrEqual(1);

      // While paused, sync passes make no requests at all.
      const callsAfterLimit = fetchCalls;
      expect(await handle!.runNow()).toBeNull();
      expect(fetchCalls).toBe(callsAfterLimit);

      // Once the rolling hour has passed, syncing resumes.
      setSystemTime(new Date(Date.now() + 61 * 60 * 1000));
      stubYnabApi([ynabTransaction("txn-1")]);
      const result = await handle!.runNow();
      expect(result?.imported_transactions).toBe(1);
    } finally {
      handle?.stop();
    }
  });

  test("warns when the token is close to its hourly quota", async () => {
    const warnings: string[] = [];
    stubYnabApi([ynabTransaction("txn-1")], { rateLimitHeader: "190/200" });

    const handle = startYnabSync(
      repo,
      baseConfig({ ynabToken: "ynab-token", ynabPlanId: "plan-test" }),
      { ...silentLogger, warn: (message: string) => warnings.push(message) },
    );
    try {
      const result = await handle!.runNow();
      expect(result?.imported_transactions).toBe(1);
      expect(warnings.some((message) => message.includes("190/200"))).toBe(true);
      // Six parallel requests share the quota header but warn only once.
      expect(warnings.filter((message) => message.includes("190/200"))).toHaveLength(1);
    } finally {
      handle?.stop();
    }
  });

  test("does not warn while plenty of quota remains", async () => {
    const warnings: string[] = [];
    stubYnabApi([ynabTransaction("txn-1")], { rateLimitHeader: "12/200" });

    const handle = startYnabSync(
      repo,
      baseConfig({ ynabToken: "ynab-token", ynabPlanId: "plan-test" }),
      { ...silentLogger, warn: (message: string) => warnings.push(message) },
    );
    try {
      const result = await handle!.runNow();
      expect(result?.imported_transactions).toBe(1);
      expect(warnings).toHaveLength(0);
    } finally {
      handle?.stop();
    }
  });
});

function baseConfig(overrides: Record<string, unknown>) {
  return {
    dbPath: ":memory:",
    port: 0,
    defaultPlanId: "plan-test",
    transitionReadOnly: false,
    ...overrides,
  } as any;
}
