import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { applyMigrations } from "../src/db";
import { createHandler } from "../src/http";
import { importYnabExport, parseExportDate, parseMoneyToMilliunits } from "../src/importers/ynab-export";
import { LedgerRepository } from "../src/repository";

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
  test("does not create default plans on handler boot or plan list reads", async () => {
    const before = db.query("SELECT COUNT(*) AS count FROM plans").get() as { count: number };
    expect(before.count).toBe(0);

    const response = await request("/v1/plans");
    expect(response.status).toBe(200);
    const json = await response.json();
    expect(json.data.plans).toEqual([]);

    const after = db.query("SELECT COUNT(*) AS count FROM plans").get() as { count: number };
    expect(after.count).toBe(0);
  });

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

  test("treats repeated single-transaction import ids as idempotent", async () => {
    const body = {
      transaction: {
        account_id: "acct-1",
        date: "2026-06-10",
        amount: -12340,
        payee_name: "FairPrice",
        import_id: "openclaw-single-1",
      },
    };

    const first = await (await request("/v1/plans/plan-test/transactions", { method: "POST", body })).json();
    const secondResponse = await request("/v1/plans/plan-test/transactions", { method: "POST", body });
    const second = await secondResponse.json();

    expect(secondResponse.status).toBe(200);
    expect(second.data.transaction.id).toBe(first.data.transaction.id);
    expect(second.data.duplicate_import_ids).toEqual(["openclaw-single-1"]);

    const listed = await (await request("/v1/plans/plan-test/transactions")).json();
    expect(listed.data.transactions).toHaveLength(1);
  });

  test("returns YNAB-shaped errors", async () => {
    const response = await handler(new Request("http://howmuch.test/v1/user"));
    const body = await response.json();

    expect(response.status).toBe(401);
    expect(body.error).toEqual({
      id: "401",
      name: "not_authorized",
      detail: "Invalid bearer token",
    });
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

  test("preserves split subtransactions when patching other fields", async () => {
    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: {
          account_id: "acct-1",
          date: "2026-06-10",
          amount: -15000,
          payee_name: "Supermarket",
          memo: "weekly shop",
          subtransactions: [
            { amount: -10000, category_id: "cat-groceries", memo: "groceries" },
            { amount: -5000, category_id: "cat-household", memo: "household" },
          ],
        },
      },
    })).json();

    const transactionId = created.data.transaction.id;
    expect(created.data.transaction.subtransactions).toHaveLength(2);

    const patched = await (await request(`/v1/budgets/plan-test/transactions/${transactionId}`, {
      method: "PATCH",
      body: {
        transaction: {
          memo: "updated memo",
          flag_color: "blue",
        },
      },
    })).json();

    expect(patched.data.transaction.memo).toBe("updated memo");
    expect(patched.data.transaction.flag_color).toBe("blue");
    expect(patched.data.transaction.subtransactions).toHaveLength(2);
    expect(patched.data.transaction.subtransactions.map((sub: any) => sub.memo).sort()).toEqual([
      "groceries",
      "household",
    ]);
  });

  test("supports category reads and incremental transaction sync", async () => {
    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: {
          account_id: "acct-1",
          date: "2026-06-10",
          amount: -12340,
          payee_name: "Hawker Centre",
          category_id: "cat-food",
          memo: "initial",
        },
      },
    })).json();

    const transactionId = created.data.transaction.id;
    const initialKnowledge = created.data.server_knowledge;

    const categoryTransactions = await (await request("/v1/plans/plan-test/categories/cat-food/transactions")).json();
    expect(categoryTransactions.data.transactions).toHaveLength(1);
    expect(categoryTransactions.data.transactions[0].id).toBe(transactionId);

    const noChanges = await (
      await request(`/v1/plans/plan-test/transactions?last_knowledge_of_server=${initialKnowledge}`)
    ).json();
    expect(noChanges.data.transactions).toHaveLength(0);

    const patched = await (await request(`/v1/plans/plan-test/transactions/${transactionId}`, {
      method: "PATCH",
      body: {
        transaction: {
          memo: "updated",
        },
      },
    })).json();

    const changedSinceInitial = await (
      await request(`/v1/plans/plan-test/transactions?last_knowledge_of_server=${initialKnowledge}`)
    ).json();
    expect(changedSinceInitial.data.transactions).toHaveLength(1);
    expect(changedSinceInitial.data.transactions[0].memo).toBe("updated");

    const patchKnowledge = patched.data.server_knowledge;
    await request(`/v1/plans/plan-test/transactions/${transactionId}`, { method: "DELETE" });

    const deletedSincePatch = await (
      await request(`/v1/plans/plan-test/transactions?last_knowledge_of_server=${patchKnowledge}`)
    ).json();
    expect(deletedSincePatch.data.transactions).toHaveLength(1);
    expect(deletedSincePatch.data.transactions[0].deleted).toBe(true);
  });

  test("creates and updates accounts for ledger management", async () => {
    const createResponse = await request("/v1/plans/plan-test/accounts", {
      method: "POST",
      body: { account: { name: "Everyday", type: "checking", opening_balance: 250000 } },
    });
    expect(createResponse.status).toBe(201);
    const created = await createResponse.json();
    const accountId = created.data.account.id;
    expect(created.data.account.name).toBe("Everyday");
    expect(created.data.account.balance).toBe(250000);

    const renamed = await (await request(`/v1/plans/plan-test/accounts/${accountId}`, {
      method: "PATCH",
      body: { account: { name: "Everyday Checking", closed: true } },
    })).json();
    expect(renamed.data.account.name).toBe("Everyday Checking");
    expect(renamed.data.account.closed).toBe(true);

    const reopened = await (await request(`/v1/plans/plan-test/accounts/${accountId}`, {
      method: "PATCH",
      body: { account: { closed: false, opening_balance: 100000 } },
    })).json();
    expect(reopened.data.account.closed).toBe(false);
    expect(reopened.data.account.balance).toBe(100000);

    const missing = await request("/v1/plans/plan-test/accounts/acct-missing", {
      method: "PATCH",
      body: { account: { name: "Ghost" } },
    });
    expect(missing.status).toBe(404);

    const nameless = await request("/v1/plans/plan-test/accounts", {
      method: "POST",
      body: { account: { type: "savings" } },
    });
    expect(nameless.status).toBe(400);
  });

  test("manages category groups and categories with reassignment", async () => {
    const groupResponse = await request("/v1/plans/plan-test/category_groups", {
      method: "POST",
      body: { category_group: { name: "Everyday" } },
    });
    expect(groupResponse.status).toBe(201);
    const groupId = (await groupResponse.json()).data.category_group.id;

    const categoryResponse = await request("/v1/plans/plan-test/categories", {
      method: "POST",
      body: { category: { name: "Groceries", category_group_id: groupId } },
    });
    expect(categoryResponse.status).toBe(201);
    const groceriesId = (await categoryResponse.json()).data.category.id;

    const diningId = (await (await request("/v1/plans/plan-test/categories", {
      method: "POST",
      body: { category: { name: "Dining", category_group_id: groupId } },
    })).json()).data.category.id;

    const transactionId = await createTransaction({
      account_id: "acct-1",
      date: "2026-06-10",
      amount: -12340,
      payee_name: "FairPrice",
      category_id: groceriesId,
    });

    const renamed = await (await request(`/v1/plans/plan-test/categories/${groceriesId}`, {
      method: "PATCH",
      body: { category: { name: "Food Shop" } },
    })).json();
    expect(renamed.data.category.name).toBe("Food Shop");

    const renamedGroup = await (await request(`/v1/plans/plan-test/category_groups/${groupId}`, {
      method: "PATCH",
      body: { category_group: { name: "Daily Life" } },
    })).json();
    expect(renamedGroup.data.category_group.name).toBe("Daily Life");

    const deleteResponse = await (await request(
      `/v1/plans/plan-test/categories/${groceriesId}?reassign_to=${diningId}`,
      { method: "DELETE" },
    )).json();
    expect(deleteResponse.data.category.reassigned_transactions).toBe(1);

    const transaction = await (await request(`/v1/plans/plan-test/transactions/${transactionId}`)).json();
    expect(transaction.data.transaction.category_id).toBe(diningId);
    expect(transaction.data.transaction.category_name).toBe("Dining");

    const groups = await (await request("/v1/plans/plan-test/categories")).json();
    const group = groups.data.category_groups.find((entry: any) => entry.id === groupId);
    expect(group.name).toBe("Daily Life");
    expect(group.categories.map((category: any) => category.name)).toEqual(["Dining"]);

    const groupDelete = await (await request(`/v1/plans/plan-test/category_groups/${groupId}`, {
      method: "DELETE",
    })).json();
    expect(groupDelete.data.category_group.deleted).toBe(true);
    expect(groupDelete.data.category_group.reassigned_transactions).toBe(1);

    const uncategorised = await (await request(`/v1/plans/plan-test/transactions/${transactionId}`)).json();
    expect(uncategorised.data.transaction.category_id).toBeNull();
  });

  test("renames payees and rejects duplicate payee names", async () => {
    const payeeId = await createPayee("Coffe Shop");
    await createPayee("Bakery");

    const renamed = await (await request(`/v1/plans/plan-test/payees/${payeeId}`, {
      method: "PATCH",
      body: { payee: { name: "Coffee Shop" } },
    })).json();
    expect(renamed.data.payee.name).toBe("Coffee Shop");

    const conflict = await request(`/v1/plans/plan-test/payees/${payeeId}`, {
      method: "PATCH",
      body: { payee: { name: "bakery" } },
    });
    expect(conflict.status).toBe(400);
  });

  test("imports transactions with duplicate detection", async () => {
    const firstImport = await (await request("/v1/plans/plan-test/transactions/import", {
      method: "POST",
      body: {
        transactions: [
          {
            account_id: "acct-1",
            date: "2026-06-10",
            amount: -12340,
            payee_name: "Merchant",
            import_id: "openclaw-1",
          },
          {
            account_id: "acct-1",
            date: "2026-06-10",
            amount: -12340,
            payee_name: "Merchant",
            import_id: "openclaw-1",
          },
        ],
      },
    })).json();

    expect(firstImport.data.transaction_ids).toHaveLength(1);
    expect(firstImport.data.duplicate_import_ids).toEqual(["openclaw-1"]);
    expect(firstImport.data.duplicate_transaction_ids).toHaveLength(1);

    const fuzzyDuplicate = await (await request("/v1/plans/plan-test/transactions/import", {
      method: "POST",
      body: {
        transactions: [
          {
            account_id: "acct-1",
            date: "2026-06-10",
            amount: -12340,
            payee_name: "Merchant",
          },
        ],
      },
    })).json();

    expect(fuzzyDuplicate.data.transaction_ids).toHaveLength(0);
    expect(fuzzyDuplicate.data.duplicate_transaction_ids).toHaveLength(1);
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

  test("imports CSV rows with row-level accounts and duplicate counts", async () => {
    const importResponse = await request("/api/import/csv?plan_id=plan-test", {
      method: "POST",
      body: {
        rows: [
          { account_id: "acct-1", date: "2026-06-01", payee: "Cafe", outflow: "12.34" },
          { account_id: "acct-1", date: "2026-06-01", payee: "Cafe", outflow: "12.34" },
        ],
      },
    });
    expect(importResponse.status).toBe(201);

    const imported = await importResponse.json();
    expect(imported.data.imported).toBe(1);
    expect(imported.data.duplicate).toBe(1);
    expect(imported.data.failed).toBe(0);
  });

  test("updates account opening balances on reseed", async () => {
    await createAccount("acct-reseeded", { name: "Reseeded", opening_balance: 0 });
    await createAccount("acct-reseeded", { name: "Reseeded", opening_balance: 38000000 });

    const netWorth = await (
      await request("/api/reports/net-worth?plan_id=plan-test&from=2026-06-01&to=2026-06-30")
    ).json();

    expect(netWorth.data.periods[0].net_worth).toBe(38000000);
  });

  test("supports report filters, closed-account toggles, and age-of-money period filling", async () => {
    await createAccount("acct-open", { name: "Main", opening_balance: 0 });
    await createAccount("acct-closed", { name: "Archived", closed: true, opening_balance: 10000 });

    const salaryPayeeId = await createPayee("Salary");
    const coffeePayeeId = await createPayee("Coffee");
    const rentPayeeId = await createPayee("Rent");
    const giftPayeeId = await createPayee("Gift");

    await createTransaction({
      account_id: "acct-open",
      date: "2026-06-01",
      amount: 100000,
      payee_id: salaryPayeeId,
    });
    await createTransaction({
      account_id: "acct-open",
      date: "2026-06-10",
      amount: -20000,
      payee_id: coffeePayeeId,
      category_id: "cat-food",
    });
    await createTransaction({
      account_id: "acct-open",
      date: "2026-06-15",
      amount: -30000,
      payee_id: rentPayeeId,
      category_id: "cat-home",
    });
    await createTransaction({
      account_id: "acct-closed",
      date: "2026-06-20",
      amount: 50000,
      payee_id: giftPayeeId,
    });

    const spendingBreakdown = await (
      await request(
        `/api/reports/spending-breakdown?plan_id=plan-test&from=2026-06-01&to=2026-07-31&payee_ids=${coffeePayeeId}&top_payees_limit=1`,
      )
    ).json();
    expect(spendingBreakdown.data.total).toBe(20000);
    expect(spendingBreakdown.data.top_payees).toHaveLength(1);
    expect(spendingBreakdown.data.top_payees[0].payee_name).toBe("Coffee");

    const netWorthOpenOnly = await (
      await request(
        "/api/reports/net-worth?plan_id=plan-test&from=2026-06-01&to=2026-07-31&interval=month&include_closed_accounts=false",
      )
    ).json();
    expect(netWorthOpenOnly.data.periods[0].net_worth).toBe(50000);
    expect(netWorthOpenOnly.data.periods[1].delta).toBe(0);

    const netWorthAllAccounts = await (
      await request(
        "/api/reports/net-worth?plan_id=plan-test&from=2026-06-01&to=2026-07-31&interval=month&include_closed_accounts=true",
      )
    ).json();
    expect(netWorthAllAccounts.data.periods[0].net_worth).toBe(110000);

    const ageOfMoney = await (
      await request("/api/reports/age-of-money?plan_id=plan-test&from=2026-06-01&to=2026-07-31&interval=month")
    ).json();
    expect(ageOfMoney.data.periods).toHaveLength(2);
    expect(ageOfMoney.data.periods[0].age_of_money_days).toBe(12);
    expect(ageOfMoney.data.periods[1].age_of_money_days).toBeNull();
    expect(ageOfMoney.data.periods[1].spent).toBe(0);
  });

  test("imports YNAB plan metadata, preserves deleted transactions, and requests full history by default", async () => {
    const originalFetch = globalThis.fetch;
    const calls: string[] = [];

    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      calls.push(url);

      if (url.endsWith("/budgets/plan-test")) {
        return jsonResponse({
          data: {
            plan: {
              id: "plan-test",
              name: "Imported Plan",
              first_month: "2024-01",
              last_month: "2026-12",
            },
          },
        });
      }
      if (url.endsWith("/budgets/plan-test/settings")) {
        return jsonResponse({
          data: {
            settings: {
              date_format: { format: "YYYY-MM-DD" },
              currency_format: { iso_code: "USD", currency_symbol: "$", decimal_digits: 2 },
              display: { flag_names: { blue: "Follow up" } },
            },
          },
        });
      }
      if (url.endsWith("/budgets/plan-test/accounts")) {
        return jsonResponse({ data: { accounts: [] } });
      }
      if (url.endsWith("/budgets/plan-test/categories")) {
        return jsonResponse({ data: { category_groups: [] } });
      }
      if (url.endsWith("/budgets/plan-test/payees")) {
        return jsonResponse({ data: { payees: [] } });
      }
      if (url.endsWith("/budgets/plan-test/transactions?since_date=1900-01-01")) {
        return jsonResponse({
          data: {
            transactions: [
              {
                id: "txn-deleted",
                account_id: "acct-deleted",
                date: "2024-01-01",
                amount: -1200,
                payee_id: null,
                payee_name: "Deleted Merchant",
                category_id: null,
                memo: "old import",
                cleared: "cleared",
                approved: true,
                flag_color: null,
                flag_name: null,
                transfer_account_id: null,
                transfer_transaction_id: null,
                matched_transaction_id: null,
                import_id: "deleted-import-id",
                import_payee_name: null,
                import_payee_name_original: null,
                deleted: true,
                subtransactions: [],
              },
            ],
          },
        });
      }

      return new Response("not found", { status: 404 });
    }) as typeof fetch;

    try {
      const importResponse = await request("/api/import/ynab?plan_id=plan-test", {
        method: "POST",
        body: {
          token: "ynab-token",
          base_url: "https://ynab.example/v1",
        },
      });

      expect(importResponse.status).toBe(201);
      expect(calls).toContain("https://ynab.example/v1/budgets/plan-test/settings");
      expect(calls).toContain("https://ynab.example/v1/budgets/plan-test/transactions?since_date=1900-01-01");

      const plans = await (await request("/v1/plans")).json();
      expect(plans.data.plans[0].name).toBe("Imported Plan");

      const settings = await (await request("/v1/plans/plan-test/settings")).json();
      expect(settings.data.settings.date_format.format).toBe("YYYY-MM-DD");
      expect(settings.data.settings.display.flag_names.blue).toBe("Follow up");

      const transactions = await (await request("/v1/plans/plan-test/transactions?last_knowledge_of_server=0")).json();
      expect(transactions.data.transactions).toHaveLength(1);
      expect(transactions.data.transactions[0].id).toBe("txn-deleted");
      expect(transactions.data.transactions[0].deleted).toBe(true);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("imports official YNAB web export CSV rows idempotently", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    const planCsv = `"Month","Category Group/Category","Category Group","Category","Assigned","Activity","Available"
"June 2026","Everyday: Groceries","Everyday","Groceries","$10.00","-$12.34","-$2.34"
`;
    const registerCsv = `"Account","Flag","Date","Payee","Category Group/Category","Category Group","Category","Memo","Outflow","Inflow","Cleared"
"Current","Red","10/06/2026","Cafe","Everyday: Groceries","Everyday","Groceries","breakfast","$12.34","","Cleared"
"Current","Red","10/06/2026","Cafe","Everyday: Groceries","Everyday","Groceries","breakfast","$12.34","","Cleared"
"Current","","12/06/2026","Transfer to Savings","","","","","$500.00","","Cleared"
"Savings","","13/06/2026","Transfer from Current","","","","","","$500.00","Cleared"
"Current","","15/06/2026","Transfer : External Account","","","","","$50.00","","Cleared"
"Current","","14/06/2026","Mystery Merchant","","","","needs category","$7.00","","Cleared"
"Current","","11/06/2026","Salary","","","","","", "$1,000.00","Uncleared"
`;

    const result = importYnabExport(repo, {
      planId: "plan-test",
      planName: "Actual Budget",
      registerCsv,
      planCsv,
      dateFormat: "dmy",
    });
    expect(result.imported).toBe(7);
    expect(result.duplicate).toBe(0);
    expect(result.failed).toBe(0);
    expect(result.transfer_pairs).toBe(1);
    expect(result.transfer_payees).toBe(1);

    const transactions = repo.listTransactions("plan-test", { includeDeleted: true });
    expect(transactions).toHaveLength(7);
    const cafeTransactions = transactions.filter((transaction) => transaction.payee_name === "Cafe");
    expect(cafeTransactions).toHaveLength(2);
    expect(cafeTransactions[0].amount).toBe(-12340);
    expect(cafeTransactions[0].date).toBe("2026-06-10");
    expect(cafeTransactions[0].category_name).toBe("Groceries");
    expect(cafeTransactions[0].flag_name).toBe("Red");
    expect(transactions.find((transaction) => transaction.payee_name === "Salary")?.amount).toBe(1000000);
    expect(transactions.find((transaction) => transaction.payee_name === "Transfer to Savings")?.transfer_transaction_id).toBeTruthy();
    expect(transactions.find((transaction) => transaction.payee_name === "Transfer from Current")?.transfer_transaction_id).toBeTruthy();
    expect(transactions.find((transaction) => transaction.payee_name === "Transfer : External Account")?.transfer_account_id).toBeTruthy();

    const report = await (await request("/api/reports/spending-breakdown?plan_id=plan-test")).json();
    expect(report.data.groups.find((group: any) => group.category_name === "Groceries")?.amount).toBe(24680);
    expect(report.data.groups.find((group: any) => group.category_name === "Uncategorised")?.amount).toBe(7000);

    const duplicateResult = importYnabExport(repo, {
      planId: "plan-test",
      planName: "Actual Budget",
      registerCsv,
      planCsv,
      dateFormat: "dmy",
    });
    expect(duplicateResult.imported).toBe(0);
    expect(duplicateResult.duplicate).toBe(7);
  });

  test("parses YNAB web export dates and money formats", () => {
    expect(parseExportDate("10/06/2026", "dmy")).toBe("2026-06-10");
    expect(parseExportDate("06/10/2026", "mdy")).toBe("2026-06-10");
    expect(parseExportDate("2026-06-10", "ymd")).toBe("2026-06-10");
    expect(parseMoneyToMilliunits("$1,234.56")).toBe(1234560);
    expect(parseMoneyToMilliunits("−$1,234.56")).toBe(-1234560);
    expect(parseMoneyToMilliunits("($1,234.56)")).toBe(-1234560);
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

async function createAccount(id: string, account: Record<string, unknown>): Promise<void> {
  const response = await request("/v1/plans/plan-test/accounts", {
    method: "POST",
    body: {
      account: {
        id,
        ...account,
      },
    },
  });
  expect(response.status).toBe(201);
}

async function createPayee(name: string): Promise<string> {
  const response = await request("/v1/plans/plan-test/payees", {
    method: "POST",
    body: {
      payee: {
        name,
      },
    },
  });
  expect(response.status).toBe(201);
  const json = await response.json();
  return json.data.payee.id;
}

async function createTransaction(transaction: Record<string, unknown>): Promise<string> {
  const response = await request("/v1/plans/plan-test/transactions", {
    method: "POST",
    body: {
      transaction,
    },
  });
  expect(response.status).toBe(201);
  const json = await response.json();
  return json.data.transaction.id;
}

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: {
      "content-type": "application/json",
    },
  });
}
