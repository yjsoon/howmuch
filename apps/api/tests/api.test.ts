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

  test("serializes concurrent local SQLite transaction writes", async () => {
    const responses = await Promise.all([
      request("/v1/plans/plan-test/transactions", {
        method: "POST",
        body: { transaction: { id: "concurrent-1", account_id: "acct-1", date: "2026-06-10", amount: -1000 } },
      }),
      request("/v1/plans/plan-test/transactions", {
        method: "POST",
        body: { transaction: { id: "concurrent-2", account_id: "acct-1", date: "2026-06-11", amount: -2000 } },
      }),
    ]);
    expect(responses.map((response) => response.status)).toEqual([201, 201]);
    expect(db.query("SELECT COUNT(*) AS count FROM transactions").get()).toEqual({ count: 2 });
    expect(db.query("SELECT balance_milli FROM accounts WHERE id = 'acct-1'").get()).toEqual({ balance_milli: -3000 });

    const firstRepository = new LedgerRepository(db, "plan-test");
    const secondRepository = new LedgerRepository(db, "plan-test");
    await Promise.all([
      firstRepository.createTransaction("plan-test", {
        id: "concurrent-3", account_id: "acct-1", date: "2026-06-12", amount: -4000,
      }),
      secondRepository.createTransaction("plan-test", {
        id: "concurrent-4", account_id: "acct-1", date: "2026-06-13", amount: -8000,
      }),
    ]);
    expect(db.query("SELECT COUNT(*) AS count FROM transactions").get()).toEqual({ count: 4 });
    expect(db.query("SELECT balance_milli FROM accounts WHERE id = 'acct-1'").get()).toEqual({ balance_milli: -15000 });
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

  test("rejects invalid transaction patches without mutating the ledger", async () => {
    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: { transaction: { account_id: "acct-1", date: "2026-06-10", amount: -5000 } },
    })).json();
    const transactionId = created.data.transaction.id;
    const knowledge = (db.query("SELECT server_knowledge FROM plans WHERE id = 'plan-test'").get() as { server_knowledge: number }).server_knowledge;
    const invalidPatches = [
      { date: "10/06/2026" },
      { amount: -1.5 },
      { cleared: "invalid" },
      { amount: -5000, subtransactions: [{ amount: -4000 }, { amount: -500 }] },
    ];

    for (const transaction of invalidPatches) {
      const response = await request(`/v1/plans/plan-test/transactions/${transactionId}`, {
        method: "PATCH",
        body: { transaction },
      });
      expect(response.status).toBe(400);
    }

    const stored = db.query("SELECT date, amount_milli, cleared FROM transactions WHERE id = ?").get(transactionId);
    expect(stored).toEqual({ date: "2026-06-10", amount_milli: -5000, cleared: "uncleared" });
    expect(db.query("SELECT server_knowledge FROM plans WHERE id = 'plan-test'").get()).toEqual({ server_knowledge: knowledge });
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

describe("transfers and splits", () => {
  test("provisions transfer payees and creates both sides of a transfer", async () => {
    const checking = await createAccountViaApi({ name: "Checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Savings", type: "savings" });
    expect(checking.transfer_payee_id).toBeTruthy();
    expect(savings.transfer_payee_id).toBeTruthy();

    const payees = await (await request("/v1/plans/plan-test/payees")).json();
    const savingsPayee = payees.data.payees.find((payee: any) => payee.id === savings.transfer_payee_id);
    expect(savingsPayee.name).toBe("Transfer : Savings");
    expect(savingsPayee.transfer_account_id).toBe(savings.id);

    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: {
          account_id: checking.id,
          date: "2026-06-10",
          amount: -50000,
          payee_id: savings.transfer_payee_id,
          category_id: "cat-groceries",
        },
      },
    })).json();

    const outflow = created.data.transaction;
    expect(outflow.transfer_account_id).toBe(savings.id);
    expect(outflow.transfer_transaction_id).toBeTruthy();
    expect(outflow.payee_name).toBe("Transfer : Savings");
    // Transfers between two budget accounts carry no category.
    expect(outflow.category_id).toBeNull();

    const inflow = await (
      await request(`/v1/plans/plan-test/transactions/${outflow.transfer_transaction_id}`)
    ).json();
    expect(inflow.data.transaction.account_id).toBe(savings.id);
    expect(inflow.data.transaction.amount).toBe(50000);
    expect(inflow.data.transaction.payee_name).toBe("Transfer : Checking");
    expect(inflow.data.transaction.transfer_account_id).toBe(checking.id);
    expect(inflow.data.transaction.transfer_transaction_id).toBe(outflow.id);

    const accounts = await (await request("/v1/plans/plan-test/accounts")).json();
    const balances = Object.fromEntries(accounts.data.accounts.map((account: any) => [account.name, account.balance]));
    expect(balances.Checking).toBe(-50000);
    expect(balances.Savings).toBe(50000);
  });

  test("syncs edits across a transfer and deletes both sides together", async () => {
    const checking = await createAccountViaApi({ name: "Checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Savings", type: "savings" });

    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: {
          account_id: checking.id,
          date: "2026-06-10",
          amount: -50000,
          payee_id: savings.transfer_payee_id,
        },
      },
    })).json();
    const outflow = created.data.transaction;

    const patched = await (await request(`/v1/plans/plan-test/transactions/${outflow.id}`, {
      method: "PATCH",
      body: { transaction: { amount: -75000, date: "2026-06-12", memo: "topped up" } },
    })).json();
    expect(patched.data.transaction.amount).toBe(-75000);

    const mirrored = await (
      await request(`/v1/plans/plan-test/transactions/${outflow.transfer_transaction_id}`)
    ).json();
    expect(mirrored.data.transaction.amount).toBe(75000);
    expect(mirrored.data.transaction.date).toBe("2026-06-12");
    expect(mirrored.data.transaction.memo).toBe("topped up");

    const deleteResponse = await request(`/v1/plans/plan-test/transactions/${outflow.id}`, { method: "DELETE" });
    expect(deleteResponse.status).toBe(200);
    const afterDelete = await (await request("/v1/plans/plan-test/transactions")).json();
    expect(afterDelete.data.transactions).toHaveLength(0);
  });

  test("breaks the transfer link when the payee becomes a regular payee", async () => {
    const checking = await createAccountViaApi({ name: "Checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Savings", type: "savings" });
    const merchantId = await createPayee("Merchant");

    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: {
          account_id: checking.id,
          date: "2026-06-10",
          amount: -50000,
          payee_id: savings.transfer_payee_id,
        },
      },
    })).json();
    const outflow = created.data.transaction;

    const patched = await (await request(`/v1/plans/plan-test/transactions/${outflow.id}`, {
      method: "PATCH",
      body: { transaction: { payee_id: merchantId } },
    })).json();
    expect(patched.data.transaction.transfer_account_id).toBeNull();
    expect(patched.data.transaction.transfer_transaction_id).toBeNull();
    expect(patched.data.transaction.payee_name).toBe("Merchant");

    const remaining = await (await request("/v1/plans/plan-test/transactions")).json();
    expect(remaining.data.transactions).toHaveLength(1);
    expect(remaining.data.transactions[0].id).toBe(outflow.id);
  });

  test("rejects split transactions whose lines do not sum to the total", async () => {
    const response = await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: {
          account_id: "acct-1",
          date: "2026-06-10",
          amount: -15000,
          payee_name: "Supermarket",
          subtransactions: [
            { amount: -10000, category_id: "cat-groceries" },
            { amount: -4000, category_id: "cat-household" },
          ],
        },
      },
    });
    expect(response.status).toBe(400);
    const body = await response.json();
    expect(body.error.name).toBe("bad_request");
  });

  test("labels split parents and supports transfer subtransactions", async () => {
    const checking = await createAccountViaApi({ name: "Checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Savings", type: "savings" });

    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: {
          account_id: checking.id,
          date: "2026-06-10",
          amount: -80000,
          payee_name: "Payday sorting",
          subtransactions: [
            { amount: -30000, category_id: "cat-groceries", memo: "groceries" },
            { amount: -50000, payee_id: savings.transfer_payee_id, memo: "stash" },
          ],
        },
      },
    })).json();

    const parent = created.data.transaction;
    expect(parent.category_id).toBeNull();
    expect(parent.category_name).toBe("Split");
    expect(parent.subtransactions).toHaveLength(2);

    const transferLine = parent.subtransactions.find((sub: any) => sub.transfer_account_id === savings.id);
    expect(transferLine).toBeTruthy();
    expect(transferLine.transfer_transaction_id).toBeTruthy();

    const mirrored = await (
      await request(`/v1/plans/plan-test/transactions/${transferLine.transfer_transaction_id}`)
    ).json();
    expect(mirrored.data.transaction.account_id).toBe(savings.id);
    expect(mirrored.data.transaction.amount).toBe(50000);
    expect(mirrored.data.transaction.transfer_transaction_id).toBe(transferLine.id);

    // Deleting the split takes the linked transfer side with it.
    await request(`/v1/plans/plan-test/transactions/${parent.id}`, { method: "DELETE" });
    const remaining = await (await request("/v1/plans/plan-test/transactions")).json();
    expect(remaining.data.transactions).toHaveLength(0);
  });

  test("re-posting a transfer with the same id stays idempotent", async () => {
    const checking = await createAccountViaApi({ name: "Checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Savings", type: "savings" });

    const body = {
      transaction: {
        id: "txn-client-retry",
        account_id: checking.id,
        date: "2026-06-10",
        amount: -50000,
        payee_id: savings.transfer_payee_id,
      },
    };
    const first = await (await request("/v1/plans/plan-test/transactions", { method: "POST", body })).json();
    const second = await (await request("/v1/plans/plan-test/transactions", { method: "POST", body })).json();

    expect(second.data.transaction.transfer_transaction_id).toBe(first.data.transaction.transfer_transaction_id);

    const listed = await (await request("/v1/plans/plan-test/transactions")).json();
    expect(listed.data.transactions).toHaveLength(2);

    const accounts = await (await request("/v1/plans/plan-test/accounts")).json();
    const balances = Object.fromEntries(accounts.data.accounts.map((account: any) => [account.name, account.balance]));
    expect(balances.Checking).toBe(-50000);
    expect(balances.Savings).toBe(50000);
  });

  test("cosmetic patches on a one-sided imported transfer do not mint a mirror", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    const checking = await createAccountViaApi({ name: "Checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Savings", type: "savings" });

    // A web-export import can leave a one-sided transfer: transfer payee and
    // target set, but no linked row because the pair fell outside the export.
    await repo.createTransaction(
      "plan-test",
      {
        id: "txn-one-sided",
        account_id: checking.id,
        date: "2026-06-10",
        amount: -50000,
        payee_id: savings.transfer_payee_id,
        transfer_account_id: savings.id,
      },
      { autoLink: false },
    );

    const patched = await (await request("/v1/plans/plan-test/transactions/txn-one-sided", {
      method: "PATCH",
      body: { transaction: { memo: "fixed a typo" } },
    })).json();
    expect(patched.data.transaction.memo).toBe("fixed a typo");
    expect(patched.data.transaction.transfer_transaction_id).toBeNull();

    const listed = await (await request("/v1/plans/plan-test/transactions")).json();
    expect(listed.data.transactions).toHaveLength(1);
  });

  test("locks the linked side of a split line to cosmetic edits", async () => {
    const checking = await createAccountViaApi({ name: "Checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Savings", type: "savings" });

    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: {
          account_id: checking.id,
          date: "2026-06-10",
          amount: -80000,
          payee_name: "Payday sorting",
          subtransactions: [
            { amount: -30000, category_id: "cat-groceries" },
            { amount: -50000, payee_id: savings.transfer_payee_id },
          ],
        },
      },
    })).json();
    const transferLine = created.data.transaction.subtransactions.find((sub: any) => sub.transfer_account_id);
    const mirrorId = transferLine.transfer_transaction_id;

    const amountPatch = await request(`/v1/plans/plan-test/transactions/${mirrorId}`, {
      method: "PATCH",
      body: { transaction: { amount: 60000 } },
    });
    expect(amountPatch.status).toBe(400);

    const memoPatch = await request(`/v1/plans/plan-test/transactions/${mirrorId}`, {
      method: "PATCH",
      body: { transaction: { memo: "stash note", cleared: "cleared" } },
    });
    expect(memoPatch.status).toBe(200);
    const memoPatched = await memoPatch.json();
    expect(memoPatched.data.transaction.amount).toBe(50000);
  });

  test("rejects split parents that are themselves transfers", async () => {
    const checking = await createAccountViaApi({ name: "Checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Savings", type: "savings" });

    const response = await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: {
          account_id: checking.id,
          date: "2026-06-10",
          amount: -80000,
          payee_id: savings.transfer_payee_id,
          subtransactions: [
            { amount: -30000, category_id: "cat-groceries" },
            { amount: -50000, category_id: "cat-household" },
          ],
        },
      },
    });
    expect(response.status).toBe(400);
  });

  test("keeps posted account balances transient for reseed flows", async () => {
    await createAccount("acct-snapshot", { name: "Snapshot", type: "checking", balance: 100000 });

    // The posted balance is a snapshot, not an opening balance: importing the
    // ledger's own starting-balance transaction must not double it.
    await createTransaction({
      account_id: "acct-snapshot",
      date: "2026-06-01",
      amount: 100000,
      payee_name: "Starting Balance",
    });

    const accounts = await (await request("/v1/plans/plan-test/accounts")).json();
    const snapshot = accounts.data.accounts.find((account: any) => account.name === "Snapshot");
    expect(snapshot.balance).toBe(100000);
  });

  test("delivers both transfer legs in the same incremental sync delta", async () => {
    const checking = await createAccountViaApi({ name: "Checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Savings", type: "savings" });
    const before = await (await request("/v1/plans/plan-test/transactions")).json();
    const knowledgeBefore = before.data.server_knowledge;

    await createTransaction({
      account_id: checking.id,
      date: "2026-06-10",
      amount: -50000,
      payee_id: savings.transfer_payee_id,
    });

    const delta = await (
      await request(`/v1/plans/plan-test/transactions?last_knowledge_of_server=${knowledgeBefore}`)
    ).json();
    expect(delta.data.transactions).toHaveLength(2);
    expect(delta.data.transactions.map((txn: any) => txn.amount).sort()).toEqual([-50000, 50000]);
    expect(delta.data.server_knowledge).toBe(knowledgeBefore + 1);
    const stampedRows = db.query("SELECT server_knowledge FROM transactions ORDER BY id").all() as Array<{
      server_knowledge: number;
    }>;
    expect(new Set(stampedRows.map((txn) => txn.server_knowledge))).toEqual(
      new Set([knowledgeBefore + 1]),
    );
  });

  test("records quick-entry transfers and splits", async () => {
    const checking = await createAccountViaApi({ name: "Checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Savings", type: "savings" });

    const transferResponse = await request("/api/mobile/quick-entry?plan_id=plan-test", {
      method: "POST",
      body: {
        client_id: "qe-transfer-1",
        account_id: checking.id,
        date: "2026-06-10",
        amount: "-250.00",
        payee_id: savings.transfer_payee_id,
      },
    });
    expect(transferResponse.status).toBe(201);
    const transfer = (await transferResponse.json()).data.transaction;
    expect(transfer.transfer_account_id).toBe(savings.id);
    expect(transfer.amount).toBe(-250000);

    const splitResponse = await request("/api/mobile/quick-entry?plan_id=plan-test", {
      method: "POST",
      body: {
        client_id: "qe-split-1",
        account_id: checking.id,
        date: "2026-06-11",
        amount: "-90.00",
        payee_name: "MegaMart",
        subtransactions: [
          { amount: "-60.00", category_id: "cat-groceries" },
          { amount: "-30.00", category_id: "cat-household" },
        ],
      },
    });
    expect(splitResponse.status).toBe(201);
    const split = (await splitResponse.json()).data.transaction;
    expect(split.category_name).toBe("Split");
    expect(split.subtransactions).toHaveLength(2);
  });

  test("counts categorised transfers in spending but hides bare transfer legs", async () => {
    const checking = await createAccountViaApi({ name: "Checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Savings", type: "savings" });
    const mortgage = await createAccountViaApi({ name: "Mortgage", type: "mortgage", on_budget: false });

    // On-budget to on-budget: no category, hidden from spending.
    await createTransaction({
      account_id: checking.id,
      date: "2026-06-10",
      amount: -50000,
      payee_id: savings.transfer_payee_id,
    });
    // On-budget to tracking with a category: counts as spending, like YNAB.
    await createTransaction({
      account_id: checking.id,
      date: "2026-06-11",
      amount: -30000,
      payee_id: mortgage.transfer_payee_id,
      category_id: "cat-home",
    });

    const spending = await (
      await request("/api/reports/spending-breakdown?plan_id=plan-test&from=2026-06-01&to=2026-06-30")
    ).json();
    expect(spending.data.total).toBe(30000);
    expect(spending.data.groups[0].category_id).toBe("cat-home");

    const withTransfers = await (
      await request(
        "/api/reports/spending-breakdown?plan_id=plan-test&from=2026-06-01&to=2026-06-30&include_transfers=true",
      )
    ).json();
    expect(withTransfers.data.total).toBe(80000);
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

  test("honours the mobile quick-entry plan id when it differs from the configured default", async () => {
    const alternatePlanId = "quick-entry-alternate-plan";
    const accountResponse = await request(`/v1/plans/${alternatePlanId}/accounts`, {
      method: "POST",
      body: { account: { name: "Alternate checking" } },
    });
    expect(accountResponse.status).toBe(201);
    const alternateAccount = (await accountResponse.json()).data.account;

    const response = await request("/api/mobile/quick-entry", {
      method: "POST",
      body: {
        plan_id: alternatePlanId,
        client_id: "alternate-offline-entry",
        account_id: alternateAccount.id,
        date: "2026-07-18",
        amount_milli: -4321,
        payee_name: "Alternate cafe",
      },
    });

    expect(response.status).toBe(201);
    expect((await response.json()).data.transaction.id).toBe("alternate-offline-entry");
    const alternateTransactions = (await (await request(`/v1/plans/${alternatePlanId}/transactions`)).json()).data.transactions;
    const defaultTransactions = (await (await request("/v1/plans/plan-test/transactions")).json()).data.transactions;
    expect(alternateTransactions.map((transaction: any) => transaction.id)).toContain("alternate-offline-entry");
    expect(defaultTransactions.map((transaction: any) => transaction.id)).not.toContain("alternate-offline-entry");
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

      if (url.endsWith("/plans/plan-test")) {
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
      if (url.endsWith("/plans/plan-test/settings")) {
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
      if (url.endsWith("/plans/plan-test/accounts")) {
        return jsonResponse({ data: { accounts: [] } });
      }
      if (url.endsWith("/plans/plan-test/categories")) {
        return jsonResponse({ data: { category_groups: [] } });
      }
      if (url.endsWith("/plans/plan-test/payees")) {
        return jsonResponse({ data: { payees: [] } });
      }
      if (url.endsWith("/plans/plan-test/transactions?since_date=1900-01-01")) {
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
      expect(calls).toContain("https://ynab.example/v1/plans/plan-test/settings");
      expect(calls).toContain("https://ynab.example/v1/plans/plan-test/transactions?since_date=1900-01-01");

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

    const result = await importYnabExport(repo, {
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

    const transactions = await repo.listTransactions("plan-test", { includeDeleted: true });
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

    const duplicateResult = await importYnabExport(repo, {
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

async function createAccountViaApi(account: Record<string, unknown>): Promise<any> {
  const response = await request("/v1/plans/plan-test/accounts", {
    method: "POST",
    body: { account },
  });
  expect(response.status).toBe(201);
  const json = await response.json();
  return json.data.account;
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
