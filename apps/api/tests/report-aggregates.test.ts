import { Database } from "bun:sqlite";
import { afterEach, describe, expect, test } from "bun:test";
import { REBUILD_ACCOUNT_MONTH_BALANCES_SQL } from "../src/account-month-balances";
import { AsyncReportService } from "../src/async-reports";
import { D1Database } from "../src/d1";
import { D1LedgerRepository } from "../src/d1-ledger-repository";
import { D1ReportService } from "../src/d1-reports";
import { ReportService } from "../src/reports";
import { CountingD1Database, fakeD1Binding } from "./helpers/counting-d1";

const databases: Database[] = [];
afterEach(() => { for (const db of databases.splice(0)) db.close(); });

const PLAN = "p";

/** A database carrying the full D1 schema, including the aggregate migration. */
async function schema(): Promise<Database> {
  const db = new Database(":memory:", { strict: true });
  databases.push(db);
  const directory = new URL("../d1-migrations/", import.meta.url).pathname;
  for (const file of [...new Bun.Glob("*.sql").scanSync({ cwd: directory, absolute: true })].sort()) {
    db.exec(await Bun.file(file).text());
  }
  return db;
}

/**
 * A synthetic ledger written entirely through the repository write paths, so
 * the aggregate is maintained exactly the way a real request would maintain it:
 * several accounts, several months, a transfer pair, a split with a transfer
 * line, edits that move amount, date and account, deletes, an import, and a
 * materialised scheduled occurrence.
 */
async function syntheticLedger(): Promise<{ db: Database; repo: D1LedgerRepository }> {
  const db = await schema();
  db.run("INSERT INTO plans (id, name) VALUES ('p', 'Plan')");
  db.run(`INSERT INTO accounts (id, plan_id, name, opening_balance_milli) VALUES
    ('cash','p','Cash',100000),
    ('savings','p','Savings',250000),
    ('card','p','Card',0),
    ('old','p','Closed card',5000)`);
  db.run("UPDATE accounts SET closed=1 WHERE id='old'");
  db.run(`INSERT INTO payees (id, plan_id, name, transfer_account_id) VALUES
    ('to-cash','p','Transfer : Cash','cash'),
    ('to-savings','p','Transfer : Savings','savings'),
    ('to-card','p','Transfer : Card','card'),
    ('shop','p','Shop',NULL),
    ('employer','p','Employer',NULL)`);
  db.run(`UPDATE accounts SET transfer_payee_id = CASE id
      WHEN 'cash' THEN 'to-cash' WHEN 'savings' THEN 'to-savings' WHEN 'card' THEN 'to-card' END
    WHERE id IN ('cash','savings','card')`);
  db.run("INSERT INTO category_groups (id, plan_id, name) VALUES ('g','p','Everyday')");
  db.run("INSERT INTO categories (id, plan_id, category_group_id, name) VALUES ('c','p','g','Groceries')");

  const repo = new D1LedgerRepository(new D1Database(fakeD1Binding(db)), PLAN);

  await repo.createTransaction(PLAN, { id: "pay-jan", account_id: "cash", date: "2026-01-05", amount: 480000, payee_id: "employer", category_id: "c" });
  await repo.createTransaction(PLAN, { id: "shop-jan", account_id: "cash", date: "2026-01-18", amount: -32000, payee_id: "shop", category_id: "c" });
  await repo.createTransaction(PLAN, { id: "card-jan", account_id: "card", date: "2026-01-27", amount: -18000, payee_id: "shop", category_id: "c" });

  // A transfer: one write, two ledger rows in two accounts.
  await repo.createTransaction(PLAN, { id: "move-feb", account_id: "cash", date: "2026-02-03", amount: -150000, payee_id: "to-savings" });

  await repo.createTransaction(PLAN, { id: "pay-feb", account_id: "cash", date: "2026-02-05", amount: 480000, payee_id: "employer", category_id: "c" });
  await repo.createTransaction(PLAN, { id: "shop-feb", account_id: "cash", date: "2026-02-22", amount: -41000, payee_id: "shop", category_id: "c" });

  // A split whose second line is itself a transfer.
  await repo.createTransaction(PLAN, {
    id: "split-mar", account_id: "cash", date: "2026-03-04", amount: -60000,
    subtransactions: [
      { id: "split-line-plain", amount: -20000, category_id: "c" },
      { id: "split-line-transfer", amount: -40000, payee_id: "to-card" },
    ],
  });

  await repo.createTransaction(PLAN, { id: "pay-mar", account_id: "cash", date: "2026-03-05", amount: 480000, payee_id: "employer", category_id: "c" });
  await repo.createTransaction(PLAN, { id: "shop-mar", account_id: "cash", date: "2026-03-19", amount: -27500, payee_id: "shop", category_id: "c" });
  await repo.createTransaction(PLAN, { id: "old-mar", account_id: "old", date: "2026-03-20", amount: -1500, payee_id: "shop" });

  // Edits that move the amount, the date and the account.
  await repo.updateTransaction(PLAN, "shop-jan", { amount: -35500 });
  await repo.updateTransaction(PLAN, "shop-feb", { date: "2026-03-01" });
  await repo.updateTransaction(PLAN, "card-jan", { account_id: "cash" });

  // A transfer edit: moving the parent moves the mirror's date too.
  await repo.updateTransaction(PLAN, "move-feb", { date: "2026-02-14", amount: -155000 });

  // Deletes, including one that tears down a transfer pair.
  await repo.createTransaction(PLAN, { id: "typo-apr", account_id: "cash", date: "2026-04-02", amount: -9999, payee_id: "shop" });
  await repo.deleteTransaction(PLAN, "typo-apr");
  await repo.createTransaction(PLAN, { id: "move-apr", account_id: "savings", date: "2026-04-06", amount: -20000, payee_id: "to-cash" });
  await repo.deleteTransaction(PLAN, "move-apr");

  // An import.
  await repo.importTransactions(PLAN, [
    { id: "import-apr-1", account_id: "card", date: "2026-04-11", amount: -7250, import_id: "imp-1", payee_name: "Shop" },
    { id: "import-apr-2", account_id: "card", date: "2026-04-12", amount: -3125, import_id: "imp-2", payee_name: "Shop" },
  ]);

  // A materialised scheduled occurrence.
  const schedule = await repo.createScheduledTransaction(PLAN, {
    id: "rent", account_id: "cash", date_first: "2026-04-01", frequency: "monthly", amount: -120000, payee_id: "shop",
  });
  await repo.materializeScheduledTransactions(PLAN, "2026-05-31");
  expect(schedule.id).toBe("rent");

  return { db, repo };
}

/** What the aggregate would be if it were rebuilt from history right now. */
function rebuilt(db: Database): unknown[] {
  const snapshot = db.query("SELECT plan_id,account_id,month,net_change_milli FROM account_month_balances ORDER BY 1,2,3").all();
  for (const statement of REBUILD_ACCOUNT_MONTH_BALANCES_SQL) db.run(statement);
  const fresh = db.query("SELECT plan_id,account_id,month,net_change_milli FROM account_month_balances ORDER BY 1,2,3").all();
  for (const row of snapshot as any[]) {
    db.run(
      `INSERT INTO account_month_balances (plan_id,account_id,month,net_change_milli) VALUES ($1,$2,$3,$4)
       ON CONFLICT(plan_id,account_id,month) DO UPDATE SET net_change_milli=excluded.net_change_milli`,
      [row.plan_id, row.account_id, row.month, row.net_change_milli],
    );
  }
  return fresh;
}

describe("report aggregates", () => {
  test("triggers keep account_month_balances identical to a rebuild from history", async () => {
    const { db } = await syntheticLedger();
    const maintained = db
      .query("SELECT plan_id,account_id,month,net_change_milli FROM account_month_balances ORDER BY 1,2,3")
      .all();
    expect(maintained).toEqual(rebuilt(db) as any[]);
    expect(maintained.length).toBeGreaterThan(5);
  });

  test("aggregate-backed net worth matches the full-history report on a synthetic ledger", async () => {
    const { db } = await syntheticLedger();
    const expected = new ReportService(db);
    const actual = new D1ReportService(fakeD1Binding(db));

    // Guard against a vacuous pass: the fixture must produce a real ledger.
    const baseline = expected.netWorth(PLAN, { from: "2026-01-01", to: "2026-05-31" });
    expect(baseline.periods).toHaveLength(5);
    expect(baseline.periods.at(-1)!.net_worth).not.toBe(0);
    expect(new Set(baseline.periods.at(-1)!.accounts.map((a: { balance: number }) => a.balance)).size).toBeGreaterThan(2);

    const cases = [
      { from: "2026-01-01", to: "2026-05-31" },
      { from: "2026-01-01", to: "2026-05-31", interval: "month" },
      // A trailing partial month, which the aggregate alone cannot answer.
      { from: "2026-01-01", to: "2026-04-17" },
      { from: "2026-02-14", to: "2026-04-09", interval: "week" },
      { from: "2026-03-01", to: "2026-03-31", interval: "day" },
      { from: "2026-01-01", to: "2026-12-31", interval: "year" },
      { from: "2026-01-01", to: "2026-05-31", includeClosedAccounts: true },
      { from: "2026-01-01", to: "2026-05-31", accountIds: ["cash", "card"] },
      { from: "2026-01-01", to: "2026-05-31", accountIds: ["savings"], includeClosedAccounts: true },
      // A window that starts long after the ledger does.
      { from: "2026-04-01", to: "2026-05-31" },
      // An empty window before any history.
      { from: "2025-01-01", to: "2025-03-31" },
    ] as const;

    for (const filters of cases) {
      expect({ filters, report: await actual.netWorth(PLAN, filters) })
        .toEqual({ filters, report: expected.netWorth(PLAN, filters) });
    }
  });

  test("cached age of money matches the full-history report and survives a ledger change", async () => {
    const { db, repo } = await syntheticLedger();
    const expected = new ReportService(db);
    const actual = new D1ReportService(fakeD1Binding(db));
    const filters = { from: "2026-01-01", to: "2026-05-31", interval: "month" } as const;

    const first = await actual.ageOfMoney(PLAN, filters);
    expect(first).toEqual(expected.ageOfMoney(PLAN, filters));
    // Served from the knowledge-keyed cache this time.
    expect(await actual.ageOfMoney(PLAN, filters)).toEqual(first);
    expect(db.query("SELECT COUNT(*) AS rows FROM report_cache").get()).toEqual({ rows: 1 });

    await repo.createTransaction(PLAN, { id: "late-may", account_id: "cash", date: "2026-05-20", amount: -250000, payee_id: "shop" });
    const second = await actual.ageOfMoney(PLAN, filters);
    expect(second).toEqual(expected.ageOfMoney(PLAN, filters));
    expect(second).not.toEqual(first);
    // The superseded entry is pruned rather than accumulating per knowledge.
    expect(db.query("SELECT COUNT(*) AS rows FROM report_cache").get()).toEqual({ rows: 1 });
  });

  test("net worth and age of money issue no unbounded transactions scan", async () => {
    const { db } = await syntheticLedger();
    const counting = new CountingD1Database(fakeD1Binding(db));
    const countedReports = new AsyncReportService(counting);

    const filters = { from: "2026-01-01", to: "2026-04-17", interval: "month" } as const;
    counting.reset();
    await countedReports.netWorth(PLAN, filters);
    const netWorthReads = counting.roundTrips.map((trip) => trip.sql);
    expect(netWorthReads.some((sql) => /FROM account_month_balances/.test(sql))).toBeTrue();
    for (const sql of netWorthReads.filter((sql) => /FROM transactions/.test(sql))) {
      // The only permitted ledger reads are the indexed earliest-date probe and
      // a window bounded on both sides by a date.
      expect(/MIN\(date\)/.test(sql) || /date\s*>=/.test(sql)).toBeTrue();
    }
    expect(counting.mutations()).toEqual([]);

    counting.reset();
    await countedReports.ageOfMoney(PLAN, filters);
    expect(counting.roundTrips.some((trip) => /FROM transactions/.test(trip.sql))).toBeTrue();

    // Second call: validated cache hit, so the ledger is not touched at all.
    counting.reset();
    await countedReports.ageOfMoney(PLAN, filters);
    expect(counting.roundTrips.filter((trip) => /FROM transactions/.test(trip.sql))).toEqual([]);
    expect(counting.mutations()).toEqual([]);
  });

  test("net worth reads rows proportional to months times accounts", async () => {
    const { db } = await syntheticLedger();
    const counting = new CountingD1Database(fakeD1Binding(db));
    const reports = new AsyncReportService(counting);

    const ledgerRows = Number((db.query("SELECT COUNT(*) AS rows FROM transactions WHERE deleted=0").get() as any).rows);
    const aggregateRows = Number((db.query("SELECT COUNT(*) AS rows FROM account_month_balances").get() as any).rows);
    expect(aggregateRows).toBeLessThan(ledgerRows);

    // A month-aligned window reads the aggregate and nothing from the ledger
    // beyond the earliest-date probe.
    counting.reset();
    await reports.netWorth(PLAN, { from: "2026-01-01", to: "2026-05-31", interval: "month" });
    expect(counting.roundTrips.filter((trip) => /FROM transactions/.test(trip.sql))).toEqual([]);
  });
});
