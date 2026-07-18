import { Client } from "pg";
import type { ApiConfig } from "../apps/api/src/config";
import { PostgresDatabase } from "../apps/api/src/postgres";
import { LedgerRepository } from "../apps/api/src/repository";
import { PostgresRepositoryDatabase } from "../apps/api/src/repository-db";
import { runScheduledYnabSync } from "../apps/api/src/scheduled-sync";

const connectionString = Bun.env.DATABASE_URL?.trim();
if (!connectionString) throw new Error("DATABASE_URL is required");

const planId = `scheduled-sync-${crypto.randomUUID()}`;
const config: ApiConfig = {
  dbPath: "",
  port: 0,
  defaultPlanId: planId,
  ynabToken: "test-token",
  ynabPlanId: planId,
  ynabMinSimilarity: 0.95,
};
const client = new Client({ connectionString });
await client.connect();
const database = new PostgresDatabase(client);
const repository = new LedgerRepository(new PostgresRepositoryDatabase(database), planId);
const originalFetch = globalThis.fetch;
const requested: string[] = [];
let failRequests = false;

globalThis.fetch = (async (input: RequestInfo | URL) => {
  const url = new URL(String(input));
  requested.push(`${url.pathname}${url.search}`);
  if (failRequests) return Response.json({ error: { detail: "simulated" } }, { status: 500 });
  const knowledge = 10;
  const isDelta = url.searchParams.get("last_knowledge_of_server") === String(knowledge);
  if (url.pathname.endsWith("/settings")) return Response.json({ data: { settings: {} } });
  if (url.pathname.endsWith("/accounts")) {
    return Response.json({ data: { accounts: isDelta ? [] : [{ id: "account-one", name: "Checking", balance: 1000 }], server_knowledge: knowledge } });
  }
  if (url.pathname.endsWith("/categories")) {
    return Response.json({ data: { category_groups: isDelta ? [] : [{ id: "group-one", name: "Everyday", categories: [{ id: "category-one", name: "Food" }] }], server_knowledge: knowledge } });
  }
  if (url.pathname.endsWith("/payees")) {
    return Response.json({ data: { payees: isDelta ? [] : [{ id: "payee-one", name: "Cafe" }], server_knowledge: knowledge } });
  }
  if (url.pathname.endsWith("/transactions")) {
    return Response.json({
      data: {
        transactions: isDelta ? [] : [{ id: "ynab-transaction-one", account_id: "account-one", date: "2026-07-18", amount: 1000, payee_id: "payee-one", category_id: "category-one", cleared: "cleared", approved: true, deleted: false }],
        server_knowledge: knowledge,
      },
    });
  }
  return Response.json({ data: { plan: { id: planId, name: "Scheduled Test" } } });
}) as typeof fetch;

try {
  const first = await runScheduledYnabSync({ db: database, repo: repository, config, scheduledTime: 1_000 });
  assertEqual(first.status, "completed", "initial run status");
  assertEqual(first.result?.server_knowledge, 10, "initial cursor");
  const firstRequestCount = requested.length;

  const duplicate = await runScheduledYnabSync({ db: database, repo: repository, config, scheduledTime: 1_000 });
  assertEqual(duplicate.status, "duplicate", "retry status");
  assertEqual(requested.length, firstRequestCount, "retry makes no YNAB requests");

  const delta = await runScheduledYnabSync({ db: database, repo: repository, config, scheduledTime: 3_601_000 });
  assertEqual(delta.status, "completed", "delta run status");
  assertEqual(delta.result?.imported_transactions, 0, "delta import count");
  assert(requested.some((path) => path.endsWith("/transactions?last_knowledge_of_server=10")), "delta cursor sent to YNAB");

  await database.run(
    "UPDATE ynab_sync_state SET lease_id = 'other-run', lease_until = CURRENT_TIMESTAMP + INTERVAL '10 minutes' WHERE plan_id = $1",
    [planId],
  );
  const leasedRequestCount = requested.length;
  const leased = await runScheduledYnabSync({ db: database, repo: repository, config, scheduledTime: 7_201_000 });
  assertEqual(leased.status, "leased", "overlap status");
  assertEqual(requested.length, leasedRequestCount, "overlap makes no YNAB requests");

  await database.run("UPDATE ynab_sync_state SET lease_id = NULL, lease_until = NULL WHERE plan_id = $1", [planId]);
  failRequests = true;
  let failed = false;
  try {
    await runScheduledYnabSync({ db: database, repo: repository, config, scheduledTime: 10_801_000 });
  } catch {
    failed = true;
  }
  assert(failed, "failed YNAB request propagates");
  const state = await database.get<{ lease_id: string | null; lease_until: Date | null }>(
    "SELECT lease_id, lease_until FROM ynab_sync_state WHERE plan_id = $1",
    [planId],
  );
  assertEqual(state?.lease_id, null, "failure releases lease id");
  assertEqual(state?.lease_until, null, "failure releases lease expiry");

  console.log(JSON.stringify({ ok: true, checked: ["initial-full-sync", "cursor-advance", "duplicate-retry", "incremental-delta", "overlap-lease", "failure-release"] }, null, 2));
} finally {
  globalThis.fetch = originalFetch;
  await client.query("DELETE FROM plans WHERE id = $1", [planId]);
  await client.end();
}

function assert(value: unknown, label: string): asserts value {
  if (!value) throw new Error(`Assertion failed: ${label}`);
}

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) throw new Error(`Assertion failed: ${label}; expected ${expected}, got ${actual}`);
}
