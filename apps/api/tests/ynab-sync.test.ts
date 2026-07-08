import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
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

function stubYnabApi(transactions: unknown[], options: { plans?: unknown[]; onFetch?: (url: string) => void } = {}) {
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = String(input);
    options.onFetch?.(url);
    if (url.endsWith("/plans")) {
      return jsonResponse({ data: { plans: options.plans ?? [{ id: "plan-test", name: "Test Plan" }] } });
    }
    if (url.endsWith("/plans/plan-test")) {
      return jsonResponse({ data: { plan: { id: "plan-test", name: "Test Plan" } } });
    }
    if (url.endsWith("/plans/plan-test/settings")) {
      return jsonResponse({ data: { settings: {} } });
    }
    if (url.endsWith("/plans/plan-test/accounts")) {
      return jsonResponse({ data: { accounts: [{ id: "acct-1", name: "Checking", type: "checking", on_budget: true }] } });
    }
    if (url.endsWith("/plans/plan-test/categories")) {
      return jsonResponse({ data: { category_groups: [] } });
    }
    if (url.endsWith("/plans/plan-test/payees")) {
      return jsonResponse({ data: { payees: [] } });
    }
    if (url.includes("/plans/plan-test/transactions")) {
      return jsonResponse({ data: { transactions } });
    }
    return new Response("not found", { status: 404 });
  }) as typeof fetch;
}

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } });
}

async function seedLedgerFromYnab(transactions: unknown[]): Promise<void> {
  stubYnabApi(transactions);
  await importYnabFromApi(repo, { token: "ynab-token", planId: "plan-test" });
}

describe("YNAB similarity guard", () => {
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

function baseConfig(overrides: Record<string, unknown>) {
  return {
    dbPath: ":memory:",
    port: 0,
    defaultPlanId: "plan-test",
    ...overrides,
  } as any;
}
