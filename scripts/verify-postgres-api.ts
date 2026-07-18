import { Client } from "pg";
import { loadConfig } from "../apps/api/src/config";
import { createHandler } from "../apps/api/src/http";
import { PostgresDatabase } from "../apps/api/src/postgres";
import { PostgresReportService } from "../apps/api/src/postgres-reports";
import { LedgerRepository } from "../apps/api/src/repository";
import { PostgresRepositoryDatabase } from "../apps/api/src/repository-db";

const connectionString = Bun.env.DATABASE_URL?.trim();
if (!connectionString) throw new Error("DATABASE_URL is required");

const planId = `postgres-smoke-${crypto.randomUUID()}`;
const token = `smoke-${crypto.randomUUID()}`;
const client = new Client({ connectionString });
await client.connect();
const database = new PostgresDatabase(client);
const repository = new LedgerRepository(new PostgresRepositoryDatabase(database), planId);
const handler = createHandler({
  repo: repository,
  reports: new PostgresReportService(database),
  config: loadConfig({ HOWMUCH_DEFAULT_PLAN_ID: planId, HOWMUCH_API_TOKEN: token }),
});

try {
  assertEqual((await handler(new Request("http://test/health"))).status, 401, "unauthorised health status");
  assertEqual((await request("/health")).status, 200, "authorised health status");

  const checking = await createAccount("Checking");
  const savings = await createAccount("Savings");
  await repository.upsertCategoryGroup(planId, { id: "group-everyday", name: "Everyday" });
  await repository.upsertCategory(planId, { id: "category-food", name: "Food" }, "group-everyday");

  const transfer = await json(await request(`/v1/plans/${planId}/transactions`, {
    method: "POST",
    body: { transaction: { id: "transfer-one", account_id: checking.id, date: "2026-07-18", amount: -50000, payee_id: savings.transfer_payee_id } },
  }));
  assert(transfer.data.transaction.transfer_transaction_id, "transfer creates linked transaction");

  const split = await json(await request(`/v1/plans/${planId}/transactions`, {
    method: "POST",
    body: {
      transaction: {
        id: "split-one",
        account_id: checking.id,
        date: "2026-07-18",
        amount: -30000,
        subtransactions: [
          { id: "split-food", amount: -10000, category_id: "category-food", payee_name: "Cafe" },
          { id: "split-transfer", amount: -20000, payee_id: savings.transfer_payee_id },
        ],
      },
    },
  }));
  assertEqual(split.data.transaction.subtransactions.length, 2, "split line count");
  assert(split.data.transaction.subtransactions[1].transfer_transaction_id, "split transfer creates linked transaction");

  const duplicateOne = await json(await request(`/v1/plans/${planId}/transactions`, {
    method: "POST",
    body: { transaction: { account_id: checking.id, date: "2026-07-18", amount: -7000, payee_name: "Shop", import_id: "bank:one" } },
  }));
  const duplicateTwo = await json(await request(`/v1/plans/${planId}/transactions`, {
    method: "POST",
    body: { transaction: { account_id: checking.id, date: "2026-07-18", amount: -7000, payee_name: "Shop", import_id: "bank:one" } },
  }));
  assertEqual(duplicateTwo.data.transaction.id, duplicateOne.data.transaction.id, "import id is idempotent");

  const csv = await json(await request("/api/import/csv", {
    method: "POST",
    body: {
      plan_id: planId,
      account_id: checking.id,
      rows: [{ date: "2026-07-17", payee: "Market", outflow: "12.34", category_id: "category-food", import_id: "csv:one" }],
    },
  }));
  assertEqual(csv.data.imported, 1, "CSV import count");

  const quickEntry = await json(await request("/api/mobile/quick-entry", {
    method: "POST",
    body: { plan_id: planId, client_id: "offline-client-one", account_id: checking.id, date: "2026-07-18", amount_milli: -1234, payee_name: "Offline capture" },
  }));
  assertEqual(quickEntry.data.transaction.id, "offline-client-one", "offline client id is preserved");

  for (const report of ["spending-breakdown", "income-vs-spending", "net-worth", "age-of-money"]) {
    const response = await request(`/api/reports/${report}?plan_id=${planId}`);
    assertEqual(response.status, 200, `${report} status`);
    assert((await json(response)).data, `${report} payload`);
  }

  const listed = await json(await request(`/v1/plans/${planId}/transactions`));
  assertEqual(listed.data.transactions.length, 7, "transaction count including linked transfer sides");
  const accounts = await json(await request(`/v1/plans/${planId}/accounts`));
  const checkingAfter = accounts.data.accounts.find((account: any) => account.id === checking.id);
  const savingsAfter = accounts.data.accounts.find((account: any) => account.id === savings.id);
  assertEqual(checkingAfter.balance, -100574, "checking balance");
  assertEqual(savingsAfter.balance, 70000, "savings balance");

  const deleted = await json(await request(`/v1/plans/${planId}/transactions/transfer-one`, { method: "DELETE" }));
  assertEqual(deleted.data.transaction.deleted, true, "delete marks source transfer deleted");
  const delta = await json(await request(`/v1/plans/${planId}/transactions?last_knowledge_of_server=1`));
  assert(delta.data.transactions.some((transaction: any) => transaction.id === transfer.data.transaction.transfer_transaction_id && transaction.deleted), "incremental delta includes deleted linked side");

  console.log(JSON.stringify({ ok: true, plan_id: planId, checked: ["auth", "transfers", "splits", "idempotency", "csv", "offline-entry", "reports", "balances", "incremental-delete"] }, null, 2));
} finally {
  await client.query("DELETE FROM plans WHERE id = $1", [planId]);
  await client.end();
}

async function createAccount(name: string): Promise<any> {
  const response = await request(`/v1/plans/${planId}/accounts`, { method: "POST", body: { account: { name } } });
  const payload = await json(response);
  assertEqual(response.status, 201, `create ${name} account status`);
  return payload.data.account;
}

function request(path: string, init: { method?: string; body?: unknown } = {}): Promise<Response> {
  return handler(new Request(`http://test${path}`, {
    method: init.method ?? "GET",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  }));
}

async function json(response: Response): Promise<any> {
  const payload = await response.json();
  if (!response.ok) throw new Error(`${response.status}: ${JSON.stringify(payload)}`);
  return payload;
}

function assert(value: unknown, label: string): asserts value {
  if (!value) throw new Error(`Assertion failed: ${label}`);
}

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) throw new Error(`Assertion failed: ${label}; expected ${expected}, got ${actual}`);
}
