import { Database } from "bun:sqlite";
import { afterEach, expect, test } from "bun:test";
import { AsyncReportService } from "../src/async-reports";
import { D1AuthStore } from "../src/auth-store";
import { D1LedgerRepository } from "../src/d1-ledger-repository";
import { createHandler } from "../src/http";
import { newSession, passwordCredential } from "../src/password-auth";
import { LedgerRepository } from "../src/repository";
import type { RepositoryDatabase } from "../src/repository-db";
import type { LedgerStore } from "../src/storage";
import { REMATERIALISE_ALL_PLANS } from "../src/ynab-month-activity";
import { CountingD1Database, fakeD1Binding } from "./helpers/counting-d1";

const PLAN_ID = "p";

/**
 * Round trips a GET route is allowed to make. These are ceilings, not exact
 * values. One of every count is the single-statement session lookup shared by
 * all authenticated requests; #170 batched each route's remaining statements
 * into one more.
 *
 * The two routes still above two trips are owned by work elsewhere:
 * `months/:month` by #174, which has now removed its raw-object scan but not
 * batched what remains, and the report service by #180.
 */
const BUDGET: Record<string, number> = {
  "GET /v1/plans": 2,
  "GET /v1/plans/:id": 2,
  "GET /v1/plans/:id/settings": 2,
  "GET /v1/plans/:id/accounts": 2,
  "GET /v1/plans/:id/account_preferences": 2,
  "GET /v1/plans/:id/accounts/usage": 2,
  "GET /v1/plans/:id/categories": 2,
  "GET /v1/plans/:id/payees": 2,
  "GET /v1/plans/:id/transactions?limit=10": 2,
  "GET /v1/plans/:id/transactions?q=": 3,
  "GET /v1/plans/:id/transactions/unapproved_count": 2,
  "GET /v1/plans/:id/scheduled_transactions": 2,
  // #174 replaced the whole-plan raw-object scan with one read of
  // `ynab_source_month_activity`, and enriched the fixture below with a source
  // transaction so this route measures the production shape rather than the
  // "no source objects at all" branch. On that fixture the old scan costs 11
  // (it also read every subtransaction) and the materialised read costs 10.
  // What #174 bought is the 29 MB of JSON that no longer crosses the wire, not
  // the trip count; the remaining trips are unbatched reads, not scans.
  "GET /v1/plans/:id/months/:month": 10,
  "GET /api/reports/spending-breakdown": 3,
};

const ROUTES: Array<{ name: string; path: string }> = [
  { name: "GET /v1/plans", path: "/v1/plans" },
  { name: "GET /v1/plans/:id", path: `/v1/plans/${PLAN_ID}` },
  { name: "GET /v1/plans/:id/settings", path: `/v1/plans/${PLAN_ID}/settings` },
  { name: "GET /v1/plans/:id/accounts", path: `/v1/plans/${PLAN_ID}/accounts` },
  { name: "GET /v1/plans/:id/account_preferences", path: `/v1/plans/${PLAN_ID}/account_preferences` },
  // The window ends on the seeded row's date so the grouped count is not empty.
  { name: "GET /v1/plans/:id/accounts/usage", path: `/v1/plans/${PLAN_ID}/accounts/usage?days=30&until=2026-01-31` },
  { name: "GET /v1/plans/:id/categories", path: `/v1/plans/${PLAN_ID}/categories` },
  { name: "GET /v1/plans/:id/payees", path: `/v1/plans/${PLAN_ID}/payees` },
  { name: "GET /v1/plans/:id/transactions?limit=10", path: `/v1/plans/${PLAN_ID}/transactions?limit=10` },
  // A searched register reads the plan's currency format before it can build
  // the SQL, so it costs one trip more than the plain page.
  { name: "GET /v1/plans/:id/transactions?q=", path: `/v1/plans/${PLAN_ID}/transactions?limit=10&q=Shop` },
  // The "New" badge: one batch of [knowledge, COUNT], no rows.
  { name: "GET /v1/plans/:id/transactions/unapproved_count", path: `/v1/plans/${PLAN_ID}/transactions/unapproved_count` },
  { name: "GET /v1/plans/:id/scheduled_transactions", path: `/v1/plans/${PLAN_ID}/scheduled_transactions` },
  { name: "GET /v1/plans/:id/months/:month", path: `/v1/plans/${PLAN_ID}/months/2026-01` },
  { name: "GET /api/reports/spending-breakdown", path: `/api/reports/spending-breakdown?plan_id=${PLAN_ID}` },
];

const databases: Database[] = [];
afterEach(() => { for (const db of databases.splice(0)) db.close(); });

async function ledgerSqlite(): Promise<Database> {
  const sqlite = new Database(":memory:", { strict: true });
  databases.push(sqlite);
  const migrations = new Bun.Glob("*.sql");
  const directory = new URL("../d1-migrations/", import.meta.url).pathname;
  for (const file of [...migrations.scanSync(directory)].sort()) {
    sqlite.exec(await Bun.file(`${directory}${file}`).text());
  }
  return sqlite;
}

async function harness(makeRepo: (db: CountingD1Database) => LedgerStore) {
  const sqlite = await ledgerSqlite();

  const counting = new CountingD1Database(fakeD1Binding(sqlite));
  const session = newSession();
  const created = await new D1AuthStore(counting).setup({
    userId: "user-1",
    username: "reader",
    credential: await passwordCredential("correct-horse-battery-staple"),
    session,
    planId: PLAN_ID,
  });
  expect(created).toBeTrue();

  seedLedger(sqlite);

  const handler = createHandler({
    repo: makeRepo(counting),
    reports: new AsyncReportService(counting),
    auth: new D1AuthStore(counting),
    config: { dbPath: "", port: 0, apiToken: "api-token", defaultPlanId: PLAN_ID, transitionReadOnly: false },
  });

  return { counting, handler, token: session.token };
}

function seedLedger(db: Database): void {
  db.run("UPDATE plans SET name = 'Plan' WHERE id = ?", [PLAN_ID]);
  db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('acct', ?, 'Cash')", [PLAN_ID]);
  db.run("INSERT INTO category_groups (id, plan_id, name) VALUES ('group', ?, 'Living')", [PLAN_ID]);
  db.run("INSERT INTO categories (id, plan_id, category_group_id, name) VALUES ('cat', ?, 'group', 'Food')", [PLAN_ID]);
  db.run("INSERT INTO payees (id, plan_id, name) VALUES ('payee', ?, 'Shop')", [PLAN_ID]);
  db.run(
    `INSERT INTO transactions (id, plan_id, account_id, payee_id, category_id, date, amount_milli, cleared, updated_at)
     VALUES ('txn', ?, 'acct', 'payee', 'cat', '2026-01-05', -1000, 'cleared', '2026-01-05T00:00:00Z')`,
    [PLAN_ID],
  );
  db.run(
    "INSERT INTO account_preferences (user_id, plan_id, preferences_json, revision) VALUES ('user-1', ?, '{}', 1)",
    [PLAN_ID],
  );
  for (const [type, id, payload] of [
    ["scheduled_transaction", "sched", { id: "sched", date_next: "2026-02-01" }],
    ["month", "2026-01-01", { month: "2026-01-01", categories: [] }],
    // A source transaction mirroring the ledger row above, so the month route
    // exercises the production shape: an imported plan whose month activity
    // has a source baseline to compare against. Without it the route takes the
    // "no source objects at all" branch and measures nothing useful.
    ["transaction", "txn", { id: "txn", date: "2026-01-05", amount: -1000, category_id: "cat", deleted: false }],
  ] as const) {
    db.run(
      "INSERT INTO ynab_raw_objects (plan_id, object_type, object_id, payload_json) VALUES (?, ?, ?, ?)",
      [PLAN_ID, type, id, JSON.stringify(payload)],
    );
  }
  // Migration 0017 ran against an empty database above, so materialise what
  // the seed just wrote. Production is materialised once by the migration.
  db.run(REMATERIALISE_ALL_PLANS);
}

async function measure(variant: string, makeRepo: (db: CountingD1Database) => LedgerStore) {
  const { counting, handler, token } = await harness(makeRepo);
  const counts: Record<string, number> = {};
  for (const route of ROUTES) {
    counting.reset();
    const response = await handler(new Request(`https://howmuch.test${route.path}`, {
      headers: { authorization: `Bearer ${token}` },
    }));
    expect(`${variant} ${route.name} -> ${response.status}`).toBe(`${variant} ${route.name} -> 200`);
    expect(`${variant} ${route.name} wrote ${counting.mutations().length} statements`)
      .toBe(`${variant} ${route.name} wrote 0 statements`);
    counts[route.name] = counting.count;
  }
  return counts;
}

test("GET routes issue no writes and stay within their round-trip budget", async () => {
  const d1Counts = await measure("D1LedgerRepository", (db) => new D1LedgerRepository(db, PLAN_ID));
  const baseCounts = await measure("LedgerRepository", (db) => new LedgerRepository(db, PLAN_ID));

  console.log(JSON.stringify({ event: "read_round_trips", d1: d1Counts, base: baseCounts }));

  for (const route of ROUTES) {
    // Both repositories share their read paths, so a regression on either shows
    // up here rather than only in the D1 numbers.
    expect(`${route.name} d1=${d1Counts[route.name]} base=${baseCounts[route.name]}`)
      .toBe(`${route.name} d1=${baseCounts[route.name]} base=${baseCounts[route.name]}`);
    expect(d1Counts[route.name]).toBeLessThanOrEqual(BUDGET[route.name]!);
  }

  // The headline numbers from #170, asserted by name so a regression is legible
  // without decoding the table above.
  expect(d1Counts["GET /v1/plans/:id/transactions?limit=10"]).toBeLessThanOrEqual(3);
  expect(d1Counts["GET /v1/plans/:id/accounts"]).toBeLessThanOrEqual(2);
  // #182: the 30-day usage sort is one grouped query plus the session lookup,
  // where the web client used to paginate the register.
  expect(d1Counts["GET /v1/plans/:id/accounts/usage"]).toBeLessThanOrEqual(2);
  expect(d1Counts["GET /v1/plans/:id/categories"]).toBeLessThanOrEqual(2);
});

test("the D1 register page reads knowledge, rows and split lines in one batch", async () => {
  const { counting, handler, token } = await harness((db) => new D1LedgerRepository(db, PLAN_ID));
  counting.reset();

  const response = await handler(new Request(`https://howmuch.test/v1/plans/${PLAN_ID}/transactions?limit=10`, {
    headers: { authorization: `Bearer ${token}` },
  }));
  expect(response.status).toBe(200);

  const batches = counting.roundTrips.filter((trip) => trip.kind === "batch");
  expect(batches).toHaveLength(1);
  // One batch is one D1 transaction, so these three statements share a
  // snapshot. That is what replaced reading server_knowledge either side of the
  // page and retrying when the two disagreed.
  expect(batches[0]!.sql).toContain("SELECT server_knowledge FROM plans");
  expect(batches[0]!.sql).toContain("FROM transactions t");
  expect(batches[0]!.sql).toContain("FROM subtransactions st");
  // No knowledge read survives outside the batch, so nothing can observe a
  // different snapshot from the rows it labels.
  expect(counting.roundTrips.filter((trip) => trip.kind !== "batch" && /server_knowledge FROM plans/.test(trip.sql)))
    .toBeEmpty();
});

test("the SQLite register page comes from one batch, which nests without deadlocking", async () => {
  const sqlite = await ledgerSqlite();
  // No auth setup here, so stand up the plan and user seedLedger references.
  sqlite.run("INSERT INTO plans (id, name) VALUES (?, 'Plan')", [PLAN_ID]);
  sqlite.run("INSERT INTO users (id, display_name) VALUES ('user-1', 'reader')");
  seedLedger(sqlite);

  // A raw Database makes LedgerRepository wrap it in SqliteRepositoryDatabase,
  // the only path where batchRead's own BEGIN runs. The round-trip test above
  // only ever sees the D1 implementation.
  const repo = new LedgerRepository(sqlite, PLAN_ID);
  const expectedKnowledge = await repo.getServerKnowledge(PLAN_ID);
  const db = (repo as unknown as { db: RepositoryDatabase }).db;

  const batched: string[][] = [];
  const singles: string[] = [];
  const runBatch = db.batchRead.bind(db);
  const runQuery = db.query.bind(db);
  db.batchRead = (statements) => {
    batched.push(statements.map((statement) => statement.sql));
    return runBatch(statements);
  };
  db.query = (sql) => {
    singles.push(sql);
    return runQuery(sql);
  };

  const page = await repo.listTransactionsPage(PLAN_ID, { limit: 10 });

  expect(page.transactions).toHaveLength(1);
  expect(page.server_knowledge).toBe(expectedKnowledge);
  // The page and the knowledge value labelling it came from one batch call, so
  // no write could have landed between them.
  expect(batched).toHaveLength(1);
  expect(batched[0]!.filter((sql) => /server_knowledge FROM plans/.test(sql))).toHaveLength(1);
  expect(batched[0]!.filter((sql) => /FROM subtransactions st/.test(sql))).toHaveLength(1);
  expect(batched[0]).toHaveLength(3);
  expect(singles.filter((sql) => /server_knowledge FROM plans/.test(sql))).toBeEmpty();

  // Inside an open transaction the helper runs its statements inline. Queueing
  // behind transaction()'s serialiser instead would deadlock on the caller.
  const nested = await db.transaction(() => runBatch([
    { sql: "SELECT server_knowledge FROM plans WHERE id = ?", values: [PLAN_ID] },
  ]))();
  expect(Number(nested[0]![0]!.server_knowledge)).toBe(expectedKnowledge);
  expect(sqlite.inTransaction).toBeFalse();
});
