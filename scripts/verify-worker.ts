import { Client } from "pg";

const baseUrl = required("HOWMUCH_BASE_URL").replace(/\/$/, "");
const token = required("HOWMUCH_API_TOKEN");
const connectionString = required("DATABASE_URL");
const realPlanId = required("HOWMUCH_DEFAULT_PLAN_ID");
const planId = `worker-smoke-${crypto.randomUUID()}`;
const client = new Client({ connectionString });

await client.connect();

try {
  const web = await fetch(`${baseUrl}/`);
  assertEqual(web.status, 200, "web root status");
  assert((web.headers.get("content-type") ?? "").includes("text/html"), "web root serves HTML");

  assertEqual((await fetch(`${baseUrl}/health`)).status, 401, "unauthorised health status");
  assertEqual((await request("/health")).status, 200, "authorised health status");
  assertEqual((await request("/v1/user")).status, 200, "user status");

  for (const report of ["spending-breakdown", "income-vs-spending", "net-worth", "age-of-money"]) {
    const response = await request(`/api/reports/${report}?plan_id=${encodeURIComponent(realPlanId)}`);
    assertEqual(response.status, 200, `${report} real-ledger status`);
    assert((await json(response)).data, `${report} real-ledger payload`);
  }

  const checking = await createAccount("Worker smoke checking");
  const savings = await createAccount("Worker smoke savings");

  const transfer = await json(await request(`/v1/plans/${planId}/transactions`, {
    method: "POST",
    body: {
      transaction: {
        id: "transfer-one",
        account_id: checking.id,
        date: "2026-07-18",
        amount: -50000,
        payee_id: savings.transfer_payee_id,
      },
    },
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
          { id: "split-purchase", amount: -10000, payee_name: "Worker smoke cafe" },
          { id: "split-transfer", amount: -20000, payee_id: savings.transfer_payee_id },
        ],
      },
    },
  }));
  assertEqual(split.data.transaction.subtransactions.length, 2, "split line count");
  assert(split.data.transaction.subtransactions[1].transfer_transaction_id, "split transfer creates linked transaction");

  const importedOne = await json(await request(`/v1/plans/${planId}/transactions`, {
    method: "POST",
    body: {
      transaction: {
        account_id: checking.id,
        date: "2026-07-18",
        amount: -7000,
        payee_name: "Worker smoke shop",
        import_id: "worker-smoke:one",
      },
    },
  }));
  const importedTwo = await json(await request(`/v1/plans/${planId}/transactions`, {
    method: "POST",
    body: {
      transaction: {
        account_id: checking.id,
        date: "2026-07-18",
        amount: -7000,
        payee_name: "Worker smoke shop",
        import_id: "worker-smoke:one",
      },
    },
  }));
  assertEqual(importedTwo.data.transaction.id, importedOne.data.transaction.id, "import id is idempotent");

  const csv = await json(await request("/api/import/csv", {
    method: "POST",
    body: {
      plan_id: planId,
      account_id: checking.id,
      rows: [{ date: "2026-07-17", payee: "Worker smoke market", outflow: "12.34", import_id: "worker-smoke:csv" }],
    },
  }));
  assertEqual(csv.data.imported, 1, "CSV import count");

  const quickEntry = await json(await request("/api/mobile/quick-entry", {
    method: "POST",
    body: {
      plan_id: planId,
      client_id: "worker-smoke-offline-client",
      account_id: checking.id,
      date: "2026-07-18",
      amount_milli: -1234,
      payee_name: "Worker smoke offline capture",
    },
  }));
  assertEqual(quickEntry.data.transaction.id, "worker-smoke-offline-client", "offline client id is preserved");

  for (const report of ["spending-breakdown", "income-vs-spending", "net-worth", "age-of-money"]) {
    const response = await request(`/api/reports/${report}?plan_id=${encodeURIComponent(planId)}`);
    assertEqual(response.status, 200, `${report} synthetic-ledger status`);
    assert((await json(response)).data, `${report} synthetic-ledger payload`);
  }

  const listed = await json(await request(`/v1/plans/${planId}/transactions`));
  const transactionIds = listed.data.transactions.map((transaction: any) => transaction.id).sort();
  assertEqual(listed.data.transactions.length, 7, `transaction count including linked transfer sides (${transactionIds.join(", ")})`);

  const accounts = await json(await request(`/v1/plans/${planId}/accounts`));
  const checkingAfter = accounts.data.accounts.find((account: any) => account.id === checking.id);
  const savingsAfter = accounts.data.accounts.find((account: any) => account.id === savings.id);
  assertEqual(checkingAfter.balance, -100574, "checking balance");
  assertEqual(savingsAfter.balance, 70000, "savings balance");

  const deleted = await json(await request(`/v1/plans/${planId}/transactions/transfer-one`, { method: "DELETE" }));
  assertEqual(deleted.data.transaction.deleted, true, "delete marks source transfer deleted");
  const delta = await json(await request(`/v1/plans/${planId}/transactions?last_knowledge_of_server=1`));
  assert(
    delta.data.transactions.some(
      (transaction: any) => transaction.id === transfer.data.transaction.transfer_transaction_id && transaction.deleted,
    ),
    "incremental delta includes deleted linked side",
  );

  console.log(JSON.stringify({
    ok: true,
    base_url: baseUrl,
    checked: [
      "static-web",
      "auth",
      "real-reports",
      "transfers",
      "splits",
      "idempotency",
      "csv",
      "offline-entry",
      "synthetic-reports",
      "balances",
      "incremental-delete",
      "database-cleanup",
    ],
  }, null, 2));
} finally {
  await client.query("DELETE FROM import_sessions WHERE plan_id = $1", [planId]);
  await client.query("DELETE FROM plans WHERE id = $1", [planId]);
  await client.end();
}

async function createAccount(name: string): Promise<any> {
  const response = await request(`/v1/plans/${planId}/accounts`, {
    method: "POST",
    body: { account: { name } },
  });
  const payload = await json(response);
  assertEqual(response.status, 201, `create ${name} account status`);
  return payload.data.account;
}

function request(path: string, init: { method?: string; body?: unknown } = {}): Promise<Response> {
  return fetch(`${baseUrl}${path}`, {
    method: init.method ?? "GET",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
}

async function json(response: Response): Promise<any> {
  const payload = await response.json();
  if (!response.ok) throw new Error(`${response.status}: ${JSON.stringify(payload)}`);
  return payload;
}

function required(name: string): string {
  const value = Bun.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function assert(value: unknown, label: string): asserts value {
  if (!value) throw new Error(`Assertion failed: ${label}`);
}

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) throw new Error(`Assertion failed: ${label}; expected ${expected}, got ${actual}`);
}
