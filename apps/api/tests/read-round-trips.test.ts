import { Database } from "bun:sqlite";
import { afterEach, expect, test } from "bun:test";
import { AsyncReportService } from "../src/async-reports";
import { D1AuthStore } from "../src/auth-store";
import { D1LedgerRepository } from "../src/d1-ledger-repository";
import { createHandler } from "../src/http";
import { newSession, passwordCredential } from "../src/password-auth";
import { LedgerRepository } from "../src/repository";
import type { LedgerStore } from "../src/storage";
import { CountingD1Database, fakeD1Binding } from "./helpers/counting-d1";

const PLAN_ID = "p";

/**
 * Round trips a GET route is allowed to make. These are ceilings, not exact
 * values: #170 batches the remaining statements and should only lower them.
 * Two of every count are the session lookup shared by all authenticated
 * requests.
 *
 * The transactions route is one trip cheaper here than in production:
 * `formatTransactions` fetches subtransactions 90 transactions at a time, so a
 * full `limit=100` register page costs two of those batches where this
 * single-transaction fixture costs one.
 */
const BUDGET: Record<string, number> = {
  "GET /v1/plans": 3,
  "GET /v1/plans/:id": 3,
  "GET /v1/plans/:id/settings": 3,
  "GET /v1/plans/:id/accounts": 4,
  "GET /v1/plans/:id/account_preferences": 3,
  "GET /v1/plans/:id/categories": 5,
  "GET /v1/plans/:id/payees": 4,
  "GET /v1/plans/:id/transactions?limit=10": 6,
  "GET /v1/plans/:id/scheduled_transactions": 7,
  "GET /v1/plans/:id/months/:month": 11,
  "GET /api/reports/spending-breakdown": 4,
};

const ROUTES: Array<{ name: string; path: string }> = [
  { name: "GET /v1/plans", path: "/v1/plans" },
  { name: "GET /v1/plans/:id", path: `/v1/plans/${PLAN_ID}` },
  { name: "GET /v1/plans/:id/settings", path: `/v1/plans/${PLAN_ID}/settings` },
  { name: "GET /v1/plans/:id/accounts", path: `/v1/plans/${PLAN_ID}/accounts` },
  { name: "GET /v1/plans/:id/account_preferences", path: `/v1/plans/${PLAN_ID}/account_preferences` },
  { name: "GET /v1/plans/:id/categories", path: `/v1/plans/${PLAN_ID}/categories` },
  { name: "GET /v1/plans/:id/payees", path: `/v1/plans/${PLAN_ID}/payees` },
  { name: "GET /v1/plans/:id/transactions?limit=10", path: `/v1/plans/${PLAN_ID}/transactions?limit=10` },
  { name: "GET /v1/plans/:id/scheduled_transactions", path: `/v1/plans/${PLAN_ID}/scheduled_transactions` },
  { name: "GET /v1/plans/:id/months/:month", path: `/v1/plans/${PLAN_ID}/months/2026-01` },
  { name: "GET /api/reports/spending-breakdown", path: `/api/reports/spending-breakdown?plan_id=${PLAN_ID}` },
];

const databases: Database[] = [];
afterEach(() => { for (const db of databases.splice(0)) db.close(); });

async function harness(makeRepo: (db: CountingD1Database) => LedgerStore) {
  const sqlite = new Database(":memory:", { strict: true });
  databases.push(sqlite);
  const migrations = new Bun.Glob("*.sql");
  const directory = new URL("../d1-migrations/", import.meta.url).pathname;
  for (const file of [...migrations.scanSync(directory)].sort()) {
    sqlite.exec(await Bun.file(`${directory}${file}`).text());
  }

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
  ] as const) {
    db.run(
      "INSERT INTO ynab_raw_objects (plan_id, object_type, object_id, payload_json) VALUES (?, ?, ?, ?)",
      [PLAN_ID, type, id, JSON.stringify(payload)],
    );
  }
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
    // The two repositories share their read paths today. If #170 batches only
    // the D1 side, drop this equality and keep the per-route ceilings.
    expect(`${route.name} d1=${d1Counts[route.name]} base=${baseCounts[route.name]}`)
      .toBe(`${route.name} d1=${baseCounts[route.name]} base=${baseCounts[route.name]}`);
    expect(d1Counts[route.name]).toBeLessThanOrEqual(BUDGET[route.name]!);
  }
});
