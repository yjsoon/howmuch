import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { applyMigrations } from "../src/db";
import { createHandler } from "../src/http";

let db: Database;
let handler: (request: Request) => Promise<Response>;

beforeEach(() => {
  db = new Database(":memory:");
  applyMigrations(db);
  handler = createHandler({
    db,
    config: {
      dbPath: ":memory:",
      port: 0,
      apiToken: "test-token",
      defaultPlanId: "plan-test",
    },
  });
});

afterEach(() => {
  db.close();
});

describe("YNAB-compatible API", () => {
  test("creates and lists OpenClaw-shaped transactions", async () => {
    const createResponse = await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: {
          account_id: "acct-1",
          date: "2026-06-10",
          amount: -12340,
          payee_name: "FairPrice",
          category_id: "cat-groceries",
          memo: "FairPrice Group",
          flag_color: "yellow",
        },
      },
    });

    expect(createResponse.status).toBe(201);
    const createJson = await createResponse.json();
    expect(createJson.data.transaction.amount).toBe(-12340);
    expect(createJson.data.transaction.payee_name).toBe("FairPrice");
    expect(createJson.data.transaction.flag_color).toBe("yellow");

    const listResponse = await request("/v1/budgets/plan-test/accounts/acct-1/transactions?since_date=2026-06-01");
    const listJson = await listResponse.json();
    expect(listJson.data.transactions).toHaveLength(1);
    expect(listJson.data.transactions[0].memo).toBe("FairPrice Group");
  });

  test("patches transaction flags and memos", async () => {
    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: {
          account_id: "acct-1",
          date: "2026-06-10",
          amount: -5000,
          payee_name: "Merchant",
          memo: "TODO: receipt",
        },
      },
    })).json();

    const transactionId = created.data.transaction.id;
    const patchResponse = await request(`/v1/plans/plan-test/transactions/${transactionId}`, {
      method: "PATCH",
      body: {
        transaction: {
          memo: "CLAIMED: receipt",
          flag_color: "green",
        },
      },
    });
    expect(patchResponse.status).toBe(200);
    const patched = await patchResponse.json();
    expect(patched.data.transaction.memo).toBe("CLAIMED: receipt");
    expect(patched.data.transaction.flag_color).toBe("green");
  });
});

describe("native reports and imports", () => {
  test("creates mobile quick-entry transactions from decimal amounts", async () => {
    const quickEntryResponse = await request("/api/mobile/quick-entry?plan_id=plan-test", {
      method: "POST",
      body: {
        account_id: "acct-1",
        date: "2026-06-10",
        amount: -12.34,
        payee_name: "Coffee Shop",
        memo: "mobile fallback",
      },
    });

    expect(quickEntryResponse.status).toBe(201);
    const quickEntry = await quickEntryResponse.json();
    expect(quickEntry.data.transaction.amount).toBe(-12340);
    expect(quickEntry.data.transaction.source_kind).toBeUndefined();
  });

  test("imports YNAB CSV-shaped rows and reports spending", async () => {
    const importResponse = await request("/api/import/csv?plan_id=plan-test", {
      method: "POST",
      body: {
        account_id: "acct-1",
        rows: [
          { date: "2026-06-01", payee: "Cafe", memo: "breakfast", outflow: "12.34", inflow: "" },
          { date: "2026-06-02", payee: "Salary", memo: "", outflow: "", inflow: "1000.00" },
        ],
      },
    });
    expect(importResponse.status).toBe(201);

    const reportResponse = await request("/api/reports/income-vs-spending?plan_id=plan-test&from=2026-06-01&to=2026-06-30");
    const report = await reportResponse.json();
    expect(report.data.periods).toHaveLength(1);
    expect(report.data.periods[0].income).toBe(1000000);
    expect(report.data.periods[0].spending).toBe(12340);

    const spendingResponse = await request("/api/reports/spending-breakdown?plan_id=plan-test&from=2026-06-01&to=2026-06-30");
    expect(spendingResponse.status).toBe(200);
    const spending = await spendingResponse.json();
    expect(spending.data.total).toBe(12340);
    expect(spending.data.groups[0].category_name).toBe("Uncategorised");
  });
});

function request(path: string, init: { method?: string; body?: unknown } = {}): Promise<Response> {
  return handler(
    new Request(`http://howmuch.test${path}`, {
      method: init.method ?? "GET",
      headers: {
        authorization: "Bearer test-token",
        "content-type": "application/json",
      },
      body: init.body ? JSON.stringify(init.body) : undefined,
    }),
  );
}
