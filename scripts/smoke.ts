import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createHandler } from "../apps/api/src/http";
import { openDatabase } from "../apps/api/src/db";
import { seedDemoLedger } from "./lib/demo-seed";

const tempDir = mkdtempSync(join(tmpdir(), "howmuch-smoke-"));
const dbPath = join(tempDir, "howmuch.sqlite");
const planId = "local-plan";
const token = "smoke-token";

seedDemoLedger({ dbPath, planId });

const db = openDatabase(dbPath);
const handler = createHandler({
  db,
  config: {
    dbPath,
    port: 8787,
    apiToken: token,
    defaultPlanId: planId,
  },
});
const headers = {
  authorization: `Bearer ${token}`,
};

try {
  await check("health", "/health", (body) => body.ok === true);
  await check("user", "/v1/user", (body) => body.data.user.id === "local-user");
  await check("plans", "/v1/plans", (body) => body.data.plans.some((plan: any) => plan.id === planId));
  await check("accounts", `/v1/plans/${planId}/accounts`, (body) => body.data.accounts.length >= 3);
  await check("categories", `/v1/plans/${planId}/categories`, (body) => body.data.category_groups.length >= 4);
  await check(
    "transactions",
    `/v1/plans/${planId}/transactions?since_date=2026-03-01&until_date=2026-05-31`,
    (body) => body.data.transactions.length >= 10,
  );
  await check(
    "spending report",
    `/api/reports/spending-breakdown?plan_id=${planId}&from=2026-03-01&to=2026-05-31`,
    (body) => body.data.total > 0 && body.data.groups.length >= 4,
  );
  await check(
    "net worth report",
    `/api/reports/net-worth?plan_id=${planId}&from=2026-03-01&to=2026-05-31`,
    (body) => body.data.periods.length >= 3,
  );

  const quickEntryResponse = await request(`/api/mobile/quick-entry?plan_id=${planId}`, {
    method: "POST",
    body: {
      client_id: "smoke-mobile-entry",
      account_id: "acct-everyday",
      date: "2026-05-30",
      amount: "-6.80",
      payee_name: "Toast Box",
      memo: "smoke quick entry",
    },
  });
  const quickEntryBody = await quickEntryResponse.json();
  assert(quickEntryResponse.ok, "quick entry failed");
  assert(quickEntryBody.data.transaction.amount === -6800, "quick entry amount mismatch");
  console.log("ok quick entry");
} finally {
  db.close();
}

async function check(
  label: string,
  path: string,
  predicate: (body: any) => boolean,
): Promise<void> {
  const response = await request(path);
  const body = await response.json();
  assert(response.ok, `${label} request failed with ${response.status}: ${JSON.stringify(body)}`);
  assert(predicate(body), `${label} response shape did not match expectations: ${JSON.stringify(body)}`);
  console.log(`ok ${label}`);
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}

function request(
  path: string,
  init: {
    method?: string;
    body?: unknown;
  } = {},
): Promise<Response> {
  return handler(
    new Request(`http://howmuch.test${path}`, {
      method: init.method ?? "GET",
      headers: init.body
        ? {
            ...headers,
            "content-type": "application/json",
          }
        : headers,
      body: init.body ? JSON.stringify(init.body) : undefined,
    }),
  );
}
