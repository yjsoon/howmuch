import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { applyMigrations } from "../src/db";
import { createHandler } from "../src/http";
import { importYnabExport, parseExportDate, parseMoneyToMilliunits } from "../src/importers/ynab-export";
import { LedgerRepository } from "../src/repository";
import { nextScheduledOccurrence, scheduledOccurrencesThrough } from "../src/scheduled-transactions";

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
      transitionReadOnly: false,
    },
  });
});

afterEach(() => {
  db.close();
});

describe("YNAB-compatible API", () => {
  test("reads mirrored scheduled transactions, payee locations, and month-filtered money movements", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertYnabRawObject("plan-test", "scheduled_transaction", "scheduled-1", { id: "scheduled-1", date_next: "2026-07-01" });
    await repo.upsertYnabRawObject("plan-test", "scheduled_subtransaction", "scheduled-1\u001fsub-1", { id: "sub-1", scheduled_transaction_id: "scheduled-1", amount: -100 });
    await repo.upsertYnabRawObject("plan-test", "payee_location", "location-1", { id: "location-1", payee_id: "payee-1", latitude: "1.2" });
    await repo.upsertYnabRawObject("plan-test", "money_movement", "movement-1", { id: "movement-1", month: "2026-06-01", amount: 100 });

    const scheduled = await (await request("/v1/plans/plan-test/scheduled_transactions")).json();
    expect(scheduled.data.scheduled_transactions).toEqual([{ id: "scheduled-1", date_next: "2026-07-01", subtransactions: [{ id: "sub-1", scheduled_transaction_id: "scheduled-1", amount: -100 }] }]);
    const locations = await (await request("/v1/plans/plan-test/payee_locations")).json();
    expect(locations.data.payee_locations).toEqual([{ id: "location-1", payee_id: "payee-1", latitude: "1.2" }]);
    const movements = await (await request("/v1/plans/plan-test/months/2026-06/money_movements")).json();
    expect(movements.data.money_movements).toEqual([{ id: "movement-1", month: "2026-06-01", amount: 100 }]);
  });

  test("creates, overlays, and deletes schedules without mutating imported YNAB rows", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertAccount("plan-test", { id: "cash", name: "Cash" });
    await repo.upsertCategoryGroup("plan-test", { id: "living", name: "Living" });
    await repo.upsertCategory("plan-test", { id: "food", category_group_id: "living", name: "Food" });
    await repo.upsertPayee("plan-test", { id: "merchant", name: "Merchant" });
    const source = { id: "source-schedule", account_id: "cash", account_name: "Cash", date_first: "2026-08-01", date_next: "2026-09-01", frequency: "monthly", amount: -1000, payee_id: "merchant", category_id: "food", memo: "source", source_marker: "preserve-me", deleted: false };
    await repo.upsertYnabRawObject("plan-test", "scheduled_transaction", source.id, source);
    const rawBefore = db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='scheduled_transaction' AND object_id=?").get(source.id);

    const updated = await request(`/v1/plans/plan-test/scheduled_transactions/${source.id}`, {
      method: "PATCH", headers: { "idempotency-key": "schedule-update-1" },
      body: { scheduled_transaction: { date_next: "2026-10-01", memo: "local edit" } },
    });
    expect(updated.status).toBe(200);
    expect((await updated.json()).data.scheduled_transaction).toMatchObject({
      id: source.id, date_next: "2026-10-01", memo: "local edit", source_marker: "preserve-me", deleted: false,
    });
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='scheduled_transaction' AND object_id=?").get(source.id)).toEqual(rawBefore);
    expect(db.query("SELECT origin FROM scheduled_transaction_edits WHERE id=?").get(source.id)).toEqual({ origin: "ynab-overlay" });

    const createBody = { scheduled_transaction: {
      account_id: "cash", date_first: "2026-08-15", frequency: "monthly", amount: -3000, memo: "split",
      subtransactions: [
        { amount: -1000, category_id: "food", memo: "first" },
        { amount: -2000, category_id: "food", memo: "second" },
      ],
    } };
    const firstCreate = await request("/v1/plans/plan-test/scheduled_transactions", { method: "POST", headers: { "idempotency-key": "schedule-create-1" }, body: createBody });
    const replayedCreate = await request("/v1/plans/plan-test/scheduled_transactions", { method: "POST", headers: { "idempotency-key": "schedule-create-1" }, body: createBody });
    expect(firstCreate.status).toBe(201);
    expect(replayedCreate.status).toBe(201);
    const created = (await firstCreate.json()).data.scheduled_transaction;
    expect((await replayedCreate.json()).data.scheduled_transaction).toEqual(created);
    expect(created).toMatchObject({ account_id: "cash", date_first: "2026-08-15", date_next: "2026-08-15", frequency: "monthly", amount: -3000, deleted: false });
    expect(created.subtransactions).toHaveLength(2);
    expect(db.query("SELECT COUNT(*) count FROM audit_events WHERE action='scheduled_transaction.create'").get()).toEqual({ count: 1 });

    const all = await (await request("/v1/plans/plan-test/scheduled_transactions")).json();
    expect(all.data.scheduled_transactions.map((transaction: any) => transaction.id).sort()).toEqual([created.id, source.id].sort());
    const subs = await (await request("/v1/plans/plan-test/scheduled_subtransactions")).json();
    expect(subs.data.scheduled_subtransactions).toEqual(created.subtransactions);

    const deleted = await request(`/v1/plans/plan-test/scheduled_transactions/${source.id}`, { method: "DELETE", headers: { "idempotency-key": "schedule-delete-1" } });
    expect(deleted.status).toBe(200);
    expect((await deleted.json()).data.scheduled_transaction).toMatchObject({ id: source.id, deleted: true });
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='scheduled_transaction' AND object_id=?").get(source.id)).toEqual(rawBefore);
    const remaining = await (await request("/v1/plans/plan-test/scheduled_transactions")).json();
    expect(remaining.data.scheduled_transactions.map((transaction: any) => transaction.id)).toEqual([created.id]);
  });

  test("serialises concurrent local SQLite schedule patches without dropping fields", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertAccount("plan-test", { id: "cash", name: "Cash" });
    await repo.upsertYnabRawObject("plan-test", "scheduled_transaction", "sqlite-race", {
      id: "sqlite-race", account_id: "cash", date_first: "2026-08-01", date_next: "2026-09-01",
      frequency: "monthly", amount: -1000, memo: "before", deleted: false,
    });

    await Promise.all([
      repo.updateScheduledTransaction("plan-test", "sqlite-race", { memo: "memo changed" }, { operationId: "sqlite-schedule-memo" }),
      repo.updateScheduledTransaction("plan-test", "sqlite-race", { amount: -2000 }, { operationId: "sqlite-schedule-amount" }),
    ]);

    expect(await repo.getScheduledTransaction("plan-test", "sqlite-race")).toMatchObject({
      memo: "memo changed", amount: -2000, date_next: "2026-09-01",
    });
  });

  test("validates scheduled writes and protects them with auth, membership, and idempotency keys", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertAccount("plan-test", { id: "cash", name: "Cash" });
    const base = { account_id: "cash", date_first: "2026-08-01", frequency: "monthly", amount: -1000 };

    expect((await handler(new Request("http://howmuch.test/v1/plans/plan-test/scheduled_transactions", {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ scheduled_transaction: base }),
    }))).status).toBe(401);
    expect((await request("/v1/plans/plan-test/scheduled_transactions", { method: "POST", headers: { "idempotency-key": "short" }, body: { scheduled_transaction: base } })).status).toBe(400);
    expect((await request("/v1/plans/plan-test/scheduled_transactions", { method: "POST", body: { scheduled_transaction: { ...base, account_id: "missing" } } })).status).toBe(400);
    expect((await request("/v1/plans/plan-test/scheduled_transactions", { method: "POST", body: { scheduled_transaction: { ...base, date_first: "2026-02-30" } } })).status).toBe(400);
    expect((await request("/v1/plans/plan-test/scheduled_transactions", { method: "POST", body: { scheduled_transaction: { ...base, frequency: "whenever" } } })).status).toBe(400);
    expect((await request("/v1/plans/plan-test/scheduled_transactions", { method: "POST", body: { scheduled_transaction: { ...base, date_next: "2026-07-31" } } })).status).toBe(400);
    expect((await request("/v1/plans/plan-test/scheduled_transactions", { method: "POST", body: { scheduled_transaction: { ...base, subtransactions: [{ amount: -500 }, { amount: -400 }] } } })).status).toBe(400);

    const created = await request("/v1/plans/plan-test/scheduled_transactions", { method: "POST", headers: { "idempotency-key": "same-key-different-payload" }, body: { scheduled_transaction: base } });
    expect(created.status).toBe(201);
    const conflict = await request("/v1/plans/plan-test/scheduled_transactions", { method: "POST", headers: { "idempotency-key": "same-key-different-payload" }, body: { scheduled_transaction: { ...base, amount: -2000 } } });
    expect(conflict.status).toBe(409);
    expect((await conflict.json()).error.detail).toBe("idempotency-key reuse");
  });

  test("reconciles only eligible cleared account rows with exact retry receipts", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertAccount("plan-test", { id: "bank", name: "Bank", opening_balance: 1000 });
    await repo.upsertAccount("plan-test", { id: "other", name: "Other" });
    await repo.upsertAccount("plan-test", { id: "fresh", name: "Fresh" });
    await repo.createTransaction("plan-test", { id: "prior", account_id: "bank", date: "2026-07-01", amount: 100, cleared: "reconciled" });
    await repo.createTransaction("plan-test", { id: "eligible", account_id: "bank", date: "2026-08-20", amount: -200, cleared: "cleared" });
    await repo.createTransaction("plan-test", { id: "future", account_id: "bank", date: "2026-09-01", amount: -300, cleared: "cleared" });
    await repo.createTransaction("plan-test", { id: "uncleared", account_id: "bank", date: "2026-08-10", amount: -400, cleared: "uncleared" });
    await repo.createTransaction("plan-test", { id: "deleted", account_id: "bank", date: "2026-08-10", amount: -500, cleared: "cleared" });
    await repo.deleteTransaction("plan-test", "deleted");
    await repo.createTransaction("plan-test", { id: "other-row", account_id: "other", date: "2026-08-10", amount: 700, cleared: "cleared" });
    await repo.createTransaction("plan-test", { id: "imported-old", account_id: "other", date: "2026-06-01", amount: 50, cleared: "reconciled" });
    await repo.createTransaction("plan-test", { id: "imported-new", account_id: "other", date: "2026-08-15", amount: 25, cleared: "reconciled" });
    const route = "/v1/plans/plan-test/accounts/bank/reconcile";

    expect((await handler(new Request(`http://howmuch.test${route}`, {
      method: "POST", headers: { "content-type": "application/json", "idempotency-key": "reconcile-no-auth" },
      body: JSON.stringify({ statement_date: "2026-08-31", statement_balance: 900 }),
    }))).status).toBe(401);
    expect((await handler(new Request("http://howmuch.test/v1/plans/plan-test/accounts/bank/reconciliation?statement_date=2026-08-31"))).status).toBe(401);
    expect((await request("/v1/plans/plan-test/accounts/bank/reconciliation")).status).toBe(400);
    const preview = await request("/v1/plans/plan-test/accounts/bank/reconciliation?statement_date=2026-08-31");
    expect(preview.status).toBe(200);
    expect((await preview.json()).data).toMatchObject({
      account: { id: "bank" }, statement_date: "2026-08-31",
      current_reconciled_balance: 1100, projected_reconciled_balance: 900,
      candidate_transaction_ids: ["eligible"], candidate_transaction_count: 1,
    });
    expect(db.query("SELECT cleared FROM transactions WHERE id='eligible'").get()).toEqual({ cleared: "cleared" });
    expect((await request(route, { method: "POST", body: { statement_date: "2026-08-31", statement_balance: 900 } })).status).toBe(400);
    expect((await request(route, { method: "POST", headers: { "idempotency-key": "reconcile-invalid-date" }, body: { statement_date: "2026-02-30", statement_balance: 900 } })).status).toBe(400);
    expect((await request(route, { method: "POST", headers: { "idempotency-key": "reconcile-invalid-value" }, body: { statement_date: "2026-08-31", statement_balance: 9.5 } })).status).toBe(400);

    const mismatch = await request(route, {
      method: "POST", headers: { "idempotency-key": "reconcile-mismatch" },
      body: { statement_date: "2026-08-31", statement_balance: 950 },
    });
    expect(mismatch.status).toBe(409);
    expect((await mismatch.json()).error).toMatchObject({
      name: "reconciliation_mismatch", current_reconciled_balance: 1100,
      projected_reconciled_balance: 900, statement_balance: 950, difference: 50,
    });
    expect(db.query("SELECT cleared FROM transactions WHERE id='eligible'").get()).toEqual({ cleared: "cleared" });

    const knowledgeBefore = (db.query("SELECT server_knowledge FROM plans WHERE id='plan-test'").get() as { server_knowledge: number }).server_knowledge;
    const first = await request(route, {
      method: "POST", headers: { "idempotency-key": "reconcile-bank-august" },
      body: { statement_date: "2026-08-31", statement_balance: 900 },
    });
    expect(first.status).toBe(200);
    const firstData = (await first.json()).data;
    expect(firstData).toMatchObject({
      account: { id: "bank" }, reconciled_transaction_ids: ["eligible"], reconciled_transaction_count: 1,
      statement_date: "2026-08-31", statement_balance: 900,
      prior_reconciled_balance: 1100, final_reconciled_balance: 900,
      replayed: false, server_knowledge: knowledgeBefore + 1,
    });
    expect(db.query("SELECT id,cleared FROM transactions WHERE id IN ('eligible','future','uncleared','deleted','other-row') ORDER BY id").all()).toEqual([
      { id: "deleted", cleared: "cleared" },
      { id: "eligible", cleared: "reconciled" },
      { id: "future", cleared: "cleared" },
      { id: "other-row", cleared: "cleared" },
      { id: "uncleared", cleared: "uncleared" },
    ]);
    const staleToggle = await request("/v1/plans/plan-test/transactions/eligible/cleared", {
      method: "PATCH", body: { expected_cleared: "cleared", cleared: "uncleared" },
    });
    expect(staleToggle.status).toBe(409);
    expect((await staleToggle.json()).error.name).toBe("transaction_state_conflict");
    expect((await request("/v1/plans/plan-test/transactions/eligible", {
      method: "PATCH", body: { transaction: { cleared: "uncleared" } },
    })).status).toBe(409);
    expect(db.query("SELECT cleared FROM transactions WHERE id='eligible'").get()).toEqual({ cleared: "reconciled" });

    const replay = await request(route, {
      method: "POST", headers: { "idempotency-key": "reconcile-bank-august" },
      body: { statement_date: "2026-08-31", statement_balance: 900 },
    });
    expect(replay.status).toBe(200);
    expect((await replay.json()).data).toMatchObject({ ...firstData, replayed: true });
    expect(db.query("SELECT server_knowledge FROM plans WHERE id='plan-test'").get()).toEqual({ server_knowledge: knowledgeBefore + 1 });
    expect(db.query("SELECT COUNT(*) count FROM audit_events WHERE action='account.reconcile'").get()).toEqual({ count: 1 });
    expect((await request(route, {
      method: "POST", headers: { "idempotency-key": "reconcile-bank-august" },
      body: { statement_date: "2026-08-31", statement_balance: 901 },
    })).status).toBe(409);
    expect((await (await request("/v1/plans/plan-test/accounts/bank/reconciliation?statement_date=2026-08-31")).json()).data).toMatchObject({
      current_reconciled_balance: 900, projected_reconciled_balance: 900,
      candidate_transaction_ids: [], candidate_transaction_count: 0,
    });
    const listed = await (await request("/v1/plans/plan-test/accounts")).json();
    const byId = Object.fromEntries(listed.data.accounts.map((account: { id: string }) => [account.id, account]));
    expect(byId.bank.last_reconciled_date).toBe("2026-08-31");
    expect(byId.other.last_reconciled_date).toBe("2026-08-15");
    expect(byId.fresh.last_reconciled_date).toBeNull();
    expect((await (await request("/v1/plans/plan-test/accounts/bank")).json()).data.account.last_reconciled_date).toBe("2026-08-31");
  });

  test("rejects a stale SQLite reconciliation snapshot before any workflow mutation", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertAccount("plan-test", { id: "race-account", name: "Before" });
    await repo.createTransaction("plan-test", {
      id: "race-cleared", account_id: "race-account", date: "2026-08-01", amount: -100, cleared: "cleared",
    });
    db.run("UPDATE transactions SET cleared='uncleared' WHERE id='race-cleared'");
    const staleBatch = db.transaction(() => {
      db.run(
        `INSERT INTO account_reconciliation_assertions
          (command_id,plan_id,account_id,statement_date,prior_reconciled_balance_milli,projected_reconciled_balance_milli,candidate_ids_json)
         VALUES ('stale-local-reconcile','plan-test','race-account','2026-08-31',0,-100,'[\"race-cleared\"]')`,
      );
      db.run("UPDATE accounts SET name='After' WHERE id='race-account'");
    });

    expect(staleBatch).toThrow("stale account reconciliation");
    expect(db.query("SELECT name FROM accounts WHERE id='race-account'").get()).toEqual({ name: "Before" });
    expect(db.query("SELECT COUNT(*) count FROM account_reconciliation_assertions WHERE command_id='stale-local-reconcile'").get()).toEqual({ count: 0 });
  });

  test("serializes generic SQLite edits with reconciliation", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertAccount("plan-test", { id: "edit-race-account", name: "Edit race" });
    await repo.createTransaction("plan-test", {
      id: "edit-race-row", account_id: "edit-race-account", date: "2026-08-01", amount: -100, cleared: "cleared",
    });

    await Promise.all([
      repo.updateTransaction("plan-test", "edit-race-row", { memo: "kept" }),
      repo.reconcileAccount("plan-test", "edit-race-account", "2026-08-31", -100, { operationId: "edit-race-reconcile" }),
    ]);

    expect(db.query("SELECT memo,cleared FROM transactions WHERE id='edit-race-row'").get()).toEqual({ memo: "kept", cleared: "reconciled" });
  });

  test("materialises one occurrence early, advances from the anchored date, and replays without duplicates", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertAccount("plan-test", { id: "wallet", name: "Wallet", type: "cash" });
    await repo.upsertAccount("plan-test", { id: "bank", name: "Bank", type: "checking" });
    await repo.createScheduledTransaction("plan-test", {
      id: "cash-transfer", account_id: "wallet", date_first: "2026-01-31", date_next: "2026-01-31",
      frequency: "monthly", amount: -1000, transfer_account_id: "bank",
    });

    const route = "/v1/plans/plan-test/scheduled_transactions/cash-transfer/materialize";
    const body = { occurrence_date: "2026-01-31", date: "2026-01-20" };
    expect((await request(route, { method: "POST", body })).status).toBe(400);
    const first = await request(route, { method: "POST", headers: { "idempotency-key": "enter-cash-transfer" }, body });
    expect(first.status).toBe(200);
    const result = (await first.json()).data;
    expect(result).toMatchObject({ occurrence_date: "2026-01-31", entered_date: "2026-01-20", completed: false, replayed: false });
    expect(result.transaction).toMatchObject({ account_id: "wallet", date: "2026-01-20", cleared: "cleared", approved: false, transfer_account_id: "bank" });
    expect(result.scheduled_transaction.date_next).toBe("2026-02-28");
    const mirror = db.query("SELECT account_id,cleared,approved,amount_milli FROM transactions WHERE transfer_transaction_id=?").get(result.transaction.id);
    expect(mirror).toEqual({ account_id: "bank", cleared: "uncleared", approved: 0, amount_milli: 1000 });

    const replay = await request(route, { method: "POST", headers: { "idempotency-key": "enter-cash-transfer" }, body });
    expect(replay.status).toBe(200);
    expect((await replay.json()).data).toMatchObject({ transaction: { id: result.transaction.id }, replayed: true, scheduled_transaction: { date_next: "2026-02-28" } });
    expect(db.query("SELECT COUNT(*) count FROM transactions").get()).toEqual({ count: 2 });

    const february = await request(route, {
      method: "POST", headers: { "idempotency-key": "enter-cash-transfer-feb" },
      body: { occurrence_date: "2026-02-28", date: "2026-02-28" },
    });
    expect((await february.json()).data.scheduled_transaction.date_next).toBe("2026-03-31");
  });

  test("materialises split transfer lines with an explicit target and no payee", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertAccount("plan-test", { id: "bank", name: "Bank", type: "checking" });
    await repo.upsertAccount("plan-test", { id: "wallet", name: "Wallet", type: "cash" });
    await repo.upsertCategoryGroup("plan-test", { id: "living", name: "Living" });
    await repo.upsertCategory("plan-test", { id: "food", category_group_id: "living", name: "Food" });
    await repo.createScheduledTransaction("plan-test", {
      id: "split-transfer", account_id: "bank", date_first: "2026-08-24", frequency: "never", amount: -3000,
      subtransactions: [
        { amount: -1000, category_id: "food" },
        { amount: -2000, transfer_account_id: "wallet" },
      ],
    });
    const response = await request("/v1/plans/plan-test/scheduled_transactions/split-transfer/materialize", {
      method: "POST", headers: { "idempotency-key": "enter-split-transfer" },
      body: { occurrence_date: "2026-08-24", date: "2026-08-20" },
    });
    expect(response.status).toBe(200);
    const result = (await response.json()).data;
    expect(result).toMatchObject({ completed: true, scheduled_transaction: { id: "split-transfer", deleted: true } });
    expect(result.transaction.subtransactions).toEqual(expect.arrayContaining([
      expect.objectContaining({ amount: -1000, category_id: "food" }),
      expect.objectContaining({ amount: -2000, transfer_account_id: "wallet" }),
    ]));
    const mirror = db.query("SELECT account_id,cleared,approved,amount_milli FROM transactions WHERE account_id='wallet'").get();
    expect(mirror).toEqual({ account_id: "wallet", cleared: "cleared", approved: 0, amount_milli: 2000 });
    expect((await request("/v1/plans/plan-test/scheduled_transactions/split-transfer")).status).toBe(404);
  });

  test("expands missed dates with YNAB month anchors and twice-monthly cadence", () => {
    expect(scheduledOccurrencesThrough("2024-01-31", "2024-01-31", "monthly", "2024-04-30")).toEqual({
      dates: ["2024-01-31", "2024-02-29", "2024-03-31", "2024-04-30"], nextDate: "2024-05-31",
    });
    expect(nextScheduledOccurrence("2026-01-05", "2026-01-05", "twiceAMonth")).toBe("2026-01-20");
    expect(nextScheduledOccurrence("2026-01-05", "2026-01-20", "twiceAMonth")).toBe("2026-02-05");
  });

  test("never overwrites a schedule edited after its deterministic occurrence was posted", async () => {
    let race = true;
    class RacingRepository extends LedgerRepository {
      override async createTransaction(planId: string, input: any, options: any = {}) {
        const transaction = await super.createTransaction(planId, input, options);
        if (race) {
          race = false;
          await super.updateScheduledTransaction(planId, "racing", { date_next: "2026-09-15", memo: "user edit" }, { operationId: "concurrent-user-edit" });
        }
        return transaction;
      }
    }
    const repo = new RacingRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertAccount("plan-test", { id: "bank", name: "Bank" });
    await repo.createScheduledTransaction("plan-test", {
      id: "racing", account_id: "bank", date_first: "2026-08-24", date_next: "2026-08-24", frequency: "monthly", amount: -100,
    });

    await expect(repo.materializeScheduledOccurrence("plan-test", "racing", "2026-08-24", "2026-08-24")).rejects.toThrow("stale scheduled occurrence");
    expect(await repo.getScheduledTransaction("plan-test", "racing")).toMatchObject({ date_next: "2026-09-15", memo: "user edit" });
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 1 });
    const retry = await repo.materializeScheduledOccurrence("plan-test", "racing", "2026-08-24", "2026-08-24");
    expect(retry).toMatchObject({ replayed: true, scheduled_transaction: { date_next: "2026-09-15", memo: "user edit" } });
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 1 });
  });

  test("overlays a local category assignment without mutating the YNAB month mirror", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertCategoryGroup("plan-test", { id: "group-food", name: "Food" });
    await repo.upsertCategory("plan-test", { id: "category-food", category_group_id: "group-food", name: "Groceries" });
    const sourceMonth = { month: "2026-06-01", budgeted: 5000, to_be_budgeted: 4000, activity: -1200, categories: [] };
    const sourceCategory = { id: "category-food", category_group_id: "group-food", name: "Groceries", budgeted: 5000, activity: -1200, balance: 3800, deleted: false };
    await repo.upsertYnabRawObject("plan-test", "month", "2026-06-01", sourceMonth);
    await repo.upsertYnabRawObject("plan-test", "month_category", "2026-06-01\u001fcategory-food", sourceCategory);
    await repo.upsertYnabRawObject("plan-test", "transaction", "source-spend", { id: "source-spend", date: "2026-06-05", amount: -1200, category_id: "category-food", deleted: false });
    await repo.createTransaction("plan-test", {
      id: "source-spend", account_id: "cash", date: "2026-06-05", amount: -1200, category_id: "category-food",
      source_kind: "ynab-import", external_ynab_id: "source-spend",
    });
    const rawBefore = db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='month_category' AND object_id='2026-06-01\u001fcategory-food'").get() as { payload_json: string };

    const assigned = await request("/v1/plans/plan-test/months/2026-06/categories/category-food", {
      method: "PATCH",
      body: { category: { budgeted: 7000 } },
    });
    expect(assigned.status).toBe(200);
    const assignedMonth = (await assigned.json()).data.month;
    expect(assignedMonth).toMatchObject({ budgeted: 7000, to_be_budgeted: 2000 });
    expect(assignedMonth.categories).toEqual([expect.objectContaining({
      id: "category-food", budgeted: 7000, balance: 5800, source_budgeted: 5000, assignment_source: "howmuch-local",
    })]);
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='month_category' AND object_id='2026-06-01\u001fcategory-food'").get()).toEqual(rawBefore);
    expect(db.query("SELECT budgeted_milli,source FROM plan_month_assignments").get()).toEqual({ budgeted_milli: 7000, source: "howmuch-local" });

    // A later source sync changes the raw baseline but retains the local
    // decision and recalculates availability/Ready to assign from that base.
    await repo.upsertYnabRawObject("plan-test", "month", "2026-06-01", { ...sourceMonth, budgeted: 6000, to_be_budgeted: 3000 });
    await repo.upsertYnabRawObject("plan-test", "month_category", "2026-06-01\u001fcategory-food", { ...sourceCategory, budgeted: 6000, balance: 4800 });
    const afterSync = await (await request("/v1/plans/plan-test/months/2026-06")).json();
    expect(afterSync.data.month).toMatchObject({ budgeted: 7000, to_be_budgeted: 2000 });
    expect(afterSync.data.month.categories).toEqual([expect.objectContaining({ id: "category-food", budgeted: 7000, balance: 5800, source_budgeted: 6000 })]);

    // A new local transaction immediately changes the effective Plan activity
    // and Available amount, while both imported source rows stay untouched.
    await repo.createTransaction("plan-test", { id: "new-spend", account_id: "cash", date: "2026-06-10", amount: -800, category_id: "category-food" });
    const afterLocalSpend = await (await request("/v1/plans/plan-test/months/2026-06")).json();
    expect(afterLocalSpend.data.month).toMatchObject({ activity: -2000 });
    expect(afterLocalSpend.data.month.categories).toEqual([expect.objectContaining({ id: "category-food", activity: -2000, balance: 5000 })]);
    await repo.deleteTransaction("plan-test", "new-spend");
    const afterDelete = await (await request("/v1/plans/plan-test/months/2026-06")).json();
    expect(afterDelete.data.month).toMatchObject({ activity: -1200 });
    expect(afterDelete.data.month.categories).toEqual([expect.objectContaining({ id: "category-food", activity: -1200, balance: 5800 })]);
  });

  test("carries local assignment deltas into a later month's Available amount", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertCategoryGroup("plan-test", { id: "group-food", name: "Food" });
    await repo.upsertCategory("plan-test", { id: "category-food", category_group_id: "group-food", name: "Groceries" });
    for (const month of ["2026-06-01", "2026-07-01"]) {
      await repo.upsertYnabRawObject("plan-test", "month", month, { month, budgeted: 5000, to_be_budgeted: 4000, activity: 0, categories: [] });
      await repo.upsertYnabRawObject("plan-test", "month_category", `${month}\u001fcategory-food`, {
        id: "category-food", category_group_id: "group-food", name: "Groceries", budgeted: 5000, activity: 0, balance: 5000, deleted: false,
      });
    }

    const assigned = await request("/v1/plans/plan-test/months/2026-06/categories/category-food", {
      method: "PATCH",
      body: { category: { budgeted: 7000 } },
    });
    expect(assigned.status).toBe(200);
    const july = await (await request("/v1/plans/plan-test/months/2026-07")).json();
    expect(july.data.month).toMatchObject({ budgeted: 5000, to_be_budgeted: 4000 });
    expect(july.data.month.categories).toEqual([expect.objectContaining({ id: "category-food", budgeted: 5000, balance: 7000 })]);
  });

  test("overlays, clears, and restores a local target without changing the YNAB mirror", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertCategoryGroup("plan-test", { id: "group-food", name: "Food" });
    await repo.upsertCategory("plan-test", { id: "category-food", category_group_id: "group-food", name: "Groceries" });
    const source = { id: "category-food", category_group_id: "group-food", name: "Groceries", budgeted: 0, activity: 0, balance: 1200, goal_type: "NEED", goal_target: 5000, goal_target_month: "2026-07-01", deleted: false };
    await repo.upsertYnabRawObject("plan-test", "month", "2026-06-01", { month: "2026-06-01", budgeted: 0, to_be_budgeted: 0, activity: 0 });
    await repo.upsertYnabRawObject("plan-test", "month_category", "2026-06-01\u001fcategory-food", source);
    const rawBefore = db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='month_category'").get();

    const updated = await request("/v1/plans/plan-test/months/2026-06/categories/category-food", {
      method: "PATCH", body: { category: { target: { goal_type: "TB", goal_target: 9000, goal_target_month: "2026-12" } } },
    });
    expect(updated.status).toBe(200);
    expect((await updated.json()).data.category).toMatchObject({ goal_type: "TB", goal_target: 9000, goal_target_month: "2026-12-01", target_source: "howmuch-local" });
    expect(db.query("SELECT goal_type,goal_target_milli,goal_target_month FROM plan_month_category_targets").get()).toEqual({ goal_type: "TB", goal_target_milli: 9000, goal_target_month: "2026-12-01" });
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='month_category'").get()).toEqual(rawBefore);

    const omittedTarget = await request("/v1/plans/plan-test/months/2026-06/categories/category-food", { method: "PATCH", body: { category: {} } });
    expect(omittedTarget.status).toBe(400);
    expect((await omittedTarget.json()).error.detail).toBe("budgeted must be integer milliunits");

    const cleared = await request("/v1/plans/plan-test/months/2026-06/categories/category-food", { method: "PATCH", body: { category: { target: null } } });
    expect(cleared.status).toBe(200);
    expect((await cleared.json()).data.category).toMatchObject({ goal_type: null, goal_target: null, target_source: "howmuch-local" });

    const restored = await request("/v1/plans/plan-test/months/2026-06/categories/category-food", { method: "PATCH", body: { category: { restore_target: true } } });
    expect(restored.status).toBe(200);
    expect((await restored.json()).data.category).toMatchObject({ goal_type: "NEED", goal_target: 5000, goal_target_month: "2026-07-01" });
    expect(db.query("SELECT COUNT(*) AS count FROM plan_month_category_targets").get()).toEqual({ count: 0 });
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='month_category'").get()).toEqual(rawBefore);
  });

  test("keeps YNAB activity rounding while applying local deltas to the imported Uncategorized category", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertCategoryGroup("plan-test", { id: "group-food", name: "Food" });
    await repo.upsertCategory("plan-test", { id: "meals", category_group_id: "group-food", name: "Meals" });
    await repo.upsertCategory("plan-test", { id: "ynab-uncategorized", category_group_id: "group-food", name: "Uncategorized", internal: true });
    await repo.upsertYnabRawObject("plan-test", "month", "2026-08-01", {
      month: "2026-08-01", budgeted: 0, to_be_budgeted: 0, activity: -2004,
    });
    await repo.upsertYnabRawObject("plan-test", "month_category", "2026-08-01\u001fmeals", {
      id: "meals", category_group_id: "group-food", name: "Meals", budgeted: 0, activity: -1004, balance: -1004, deleted: false,
    });
    await repo.upsertYnabRawObject("plan-test", "month_category", "2026-08-01\u001fynab-uncategorized", {
      id: "ynab-uncategorized", category_group_id: "group-food", name: "Uncategorized", budgeted: 0, activity: -1000, balance: -1000, deleted: false,
    });
    for (const transaction of [
      { id: "source-meals", amount: -1000, category_id: "meals" },
      { id: "source-uncategorized", amount: -1000, category_id: null },
    ]) {
      await repo.upsertYnabRawObject("plan-test", "transaction", transaction.id, { ...transaction, date: "2026-08-05", deleted: false });
      await repo.createTransaction("plan-test", {
        ...transaction, account_id: "cash", date: "2026-08-05", source_kind: "ynab-import", external_ynab_id: transaction.id,
      });
    }

    // YNAB's -1004 Meals activity intentionally differs from its source
    // transaction sum. A read with no local change must return it exactly.
    const baseline = await repo.getMonth("plan-test", "2026-08");
    expect(baseline).toMatchObject({ activity: -2004 });
    expect(baseline.categories).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "meals", activity: -1004 }),
      expect.objectContaining({ id: "ynab-uncategorized", activity: -1000 }),
    ]));

    await repo.createTransaction("plan-test", { id: "local-uncategorized", account_id: "cash", date: "2026-08-10", amount: -200 });
    const afterLocalEntry = await repo.getMonth("plan-test", "2026-08");
    expect(afterLocalEntry).toMatchObject({ activity: -2204 });
    expect(afterLocalEntry.categories).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "meals", activity: -1004, balance: -1004 }),
      expect.objectContaining({ id: "ynab-uncategorized", activity: -1200, balance: -1200 }),
    ]));
  });

  test("rejects invalid plan assignments without creating an overlay", async () => {
    const response = await request("/v1/plans/plan-test/months/not-a-month/categories/missing", {
      method: "PATCH",
      body: { category: { budgeted: 1.25 } },
    });
    expect(response.status).toBe(400);
    expect(db.query("SELECT COUNT(*) AS count FROM plan_month_assignments").get()).toEqual({ count: 0 });
  });

  test("requires a source month, owned category, exact PATCH body, and authentication", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    await repo.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await repo.upsertCategoryGroup("plan-test", { id: "group-food", name: "Food" });
    await repo.upsertCategory("plan-test", { id: "category-food", category_group_id: "group-food", name: "Groceries" });
    await repo.upsertYnabRawObject("plan-test", "month_category", "2026-06-01\u001fcategory-food", { id: "category-food", budgeted: 5000, balance: 5000, deleted: false });

    const missingMonth = await request("/v1/plans/plan-test/months/2026-06/categories/category-food", {
      method: "PATCH", body: { category: { budgeted: 7000 } },
    });
    expect(missingMonth.status).toBe(404);
    const wrongBody = await request("/v1/plans/plan-test/months/2026-06/categories/category-food", {
      method: "PUT", body: { budgeted: 7000 },
    });
    expect(wrongBody.status).toBe(404);
    const malformedBody = await request("/v1/plans/plan-test/months/2026-06/categories/category-food", {
      method: "PATCH", body: { budgeted: 7000 },
    });
    expect(malformedBody.status).toBe(400);
    const unauthorised = await handler(new Request("http://howmuch.test/v1/plans/plan-test/months/2026-06/categories/category-food", {
      method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify({ category: { budgeted: 7000 } }),
    }));
    expect(unauthorised.status).toBe(401);
    expect(db.query("SELECT COUNT(*) AS count FROM plan_month_assignments").get()).toEqual({ count: 0 });
  });

  test("rejects invalid or unauthenticated target writes without an overlay", async () => {
    const invalid = await request("/v1/plans/plan-test/months/2026-06/categories/missing", {
      method: "PATCH", body: { category: { target: { goal_type: "TB", goal_target: 1.25 } } },
    });
    expect(invalid.status).toBe(400);
    const unauthorised = await handler(new Request("http://howmuch.test/v1/plans/plan-test/months/2026-06/categories/missing", {
      method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify({ category: { target: { goal_type: "TB", goal_target: 1000 } } }),
    }));
    expect(unauthorised.status).toBe(401);
    expect(db.query("SELECT COUNT(*) AS count FROM plan_month_category_targets").get()).toEqual({ count: 0 });
  });

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

  test("paginates every transaction list newest-first with bounded offsets", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    for (const transaction of [
      { id: "page-a", date: "2026-06-01" },
      { id: "page-b", date: "2026-06-02" },
      { id: "page-c", date: "2026-06-03" },
      { id: "page-d", date: "2026-06-03" },
    ]) {
      await repo.createTransaction("plan-test", { ...transaction, account_id: "acct-1", amount: -100 });
    }

    const first = await (await request("/v1/plans/plan-test/transactions?limit=2")).json();
    expect(first.data.transactions.map((transaction: { id: string }) => transaction.id)).toEqual(["page-d", "page-c"]);
    expect(first.data.has_more).toBeTrue();
    expect(first.data.next_offset).toBe(2);

    const second = await (await request("/v1/plans/plan-test/transactions?limit=2&offset=2")).json();
    expect(second.data.transactions.map((transaction: { id: string }) => transaction.id)).toEqual(["page-b", "page-a"]);
    expect(second.data.has_more).toBeFalse();
    expect(second.data.next_offset).toBeNull();

    const scoped = await (await request("/v1/plans/plan-test/accounts/acct-1/transactions?limit=1")).json();
    expect(scoped.data.transactions).toHaveLength(1);
    expect(scoped.data.has_more).toBeTrue();

    const invalid = await request("/v1/plans/plan-test/transactions?limit=251");
    expect(invalid.status).toBe(400);
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

  test("creates two same-day captures that differ only by import id", async () => {
    const shared = {
      account_id: "acct-1",
      date: "2026-06-10",
      amount: -4500,
      payee_name: "Coffee",
    };

    const first = await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: { transaction: { ...shared, import_id: "capture-1" } },
    });
    const second = await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: { transaction: { ...shared, import_id: "capture-2" } },
    });
    const firstJson = await first.json();
    const secondJson = await second.json();

    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(secondJson.data.transaction.id).not.toBe(firstJson.data.transaction.id);

    const listed = await (await request("/v1/plans/plan-test/transactions")).json();
    expect(listed.data.transactions).toHaveLength(2);
  });

  test("collapses overlapping creates that share one import id", async () => {
    const body = {
      transaction: {
        account_id: "acct-1",
        date: "2026-06-10",
        amount: -4500,
        payee_name: "Coffee",
        import_id: "capture-race",
      },
    };

    const responses = await Promise.all([
      request("/v1/plans/plan-test/transactions", { method: "POST", body }),
      request("/v1/plans/plan-test/transactions", { method: "POST", body }),
    ]);
    const payloads = await Promise.all(responses.map((response) => response.json()));
    const ids = payloads.map((payload) => payload.data.transaction.id);

    expect(ids[0]).toBe(ids[1]);
    const listed = await (await request("/v1/plans/plan-test/transactions")).json();
    expect(listed.data.transactions).toHaveLength(1);
    expect(listed.data.transactions[0].amount).toBe(-4500);
    expect(db.query("SELECT name FROM sqlite_master WHERE name='idx_transactions_live_import_id'").get()).toEqual({
      name: "idx_transactions_live_import_id",
    });
    expect(db.query("SELECT name FROM pragma_index_info('idx_transactions_live_import_id') ORDER BY seqno").all()).toEqual([
      { name: "plan_id" },
      { name: "account_id" },
      { name: "import_id" },
    ]);
  });

  test("keeps the same import id on two accounts", async () => {
    const shared = {
      date: "2026-06-10",
      amount: -9990,
      payee_name: "Same day charge",
      import_id: "YNAB:-9990:2026-06-10:1",
    };

    const first = await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: { transaction: { ...shared, account_id: "acct-1" } },
    });
    const second = await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: { transaction: { ...shared, account_id: "acct-2" } },
    });
    const firstJson = await first.json();
    const secondJson = await second.json();

    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(secondJson.data.transaction.id).not.toBe(firstJson.data.transaction.id);

    const listed = await (await request("/v1/plans/plan-test/transactions")).json();
    expect(listed.data.transactions).toHaveLength(2);
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

  test("serializes SQLite transaction deletion with an account move", async () => {
    const firstRepository = new LedgerRepository(db, "plan-test");
    const secondRepository = new LedgerRepository(db, "plan-test");
    await firstRepository.upsertPlan("plan-test", { id: "plan-test", name: "Plan" });
    await firstRepository.upsertAccount("plan-test", { id: "delete-race-a", name: "Delete race A" });
    await firstRepository.upsertAccount("plan-test", { id: "delete-race-b", name: "Delete race B" });
    await firstRepository.createTransaction("plan-test", {
      id: "delete-race-row", account_id: "delete-race-a", date: "2026-06-14", amount: -16000,
    });

    await Promise.all([
      firstRepository.updateTransaction("plan-test", "delete-race-row", { account_id: "delete-race-b" }),
      secondRepository.deleteTransaction("plan-test", "delete-race-row"),
    ]);

    expect(db.query("SELECT account_id,deleted FROM transactions WHERE id='delete-race-row'").get()).toEqual({
      account_id: "delete-race-b",
      deleted: 1,
    });
    expect(db.query("SELECT id,balance_milli FROM accounts WHERE id IN ('delete-race-a','delete-race-b') ORDER BY id").all()).toEqual([
      { id: "delete-race-a", balance_milli: 0 },
      { id: "delete-race-b", balance_milli: 0 },
    ]);
  });

  test("returns YNAB-shaped errors", async () => {
    const response = await handler(new Request("http://howmuch.test/v1/user"));
    const body = await response.json();

    expect(response.status).toBe(401);
    expect(body.error).toEqual({
      id: "401",
      name: "not_authorized",
      detail: "Invalid credentials",
    });
  });

  test("transition mode locks only authenticated financial writes after CSRF", async () => {
    const transitionHandler = createHandler({
      db,
      config: {
        dbPath: ":memory:",
        port: 0,
        apiToken: "test-token",
        defaultPlanId: "plan-test",
        transitionReadOnly: true,
      },
    });
    const transitionRequest = (path: string, method: string, body: unknown = {}) => transitionHandler(
      new Request(`https://howmuch.test${path}`, {
        method,
        headers: { authorization: "Bearer test-token", "content-type": "application/json" },
        body: JSON.stringify(body),
      }),
    );
    const lockedRoutes: Array<[string, string]> = [
      ["/v1/plans/plan-test/accounts", "POST"],
      ["/v1/plans/plan-test/accounts/account-1/reconcile", "POST"],
      ["/v1/plans/plan-test/payees", "POST"],
      ["/v1/plans/plan-test/transactions", "POST"],
      ["/v1/plans/plan-test/transactions", "PATCH"],
      ["/v1/plans/plan-test/transactions/import", "POST"],
      ["/v1/plans/plan-test/transactions/transaction-1", "PUT"],
      ["/v1/plans/plan-test/transactions/transaction-1", "PATCH"],
      ["/v1/budgets/plan-test/transactions/transaction-1", "DELETE"],
      ["/v1/plans/plan-test/scheduled_transactions", "POST"],
      ["/v1/plans/plan-test/scheduled_transactions/materialize", "POST"],
      ["/v1/plans/plan-test/scheduled_transactions/scheduled-1", "PUT"],
      ["/v1/plans/plan-test/scheduled_transactions/scheduled-1", "PATCH"],
      ["/v1/plans/plan-test/scheduled_transactions/scheduled-1", "DELETE"],
      ["/v1/plans/plan-test/scheduled_transactions/scheduled-1/materialize", "POST"],
      ["/v1/plans/plan-test/months/2026-08/categories/category-1", "PATCH"],
      ["/api/mobile/quick-entry", "POST"],
      ["/api/import/csv", "POST"],
      ["/api/import/ynab", "POST"],
      ["/api/import/rewards-tracker", "POST"],
    ];

    for (const [path, method] of lockedRoutes) {
      const response = await transitionRequest(path, method);
      expect(response.status, `${method} ${path}`).toBe(423);
      expect((await response.json()).error).toEqual({
        id: "423",
        name: "transition_read_only",
        detail: "Financial changes are temporarily locked while YNAB is the source of truth",
      });
    }

    const unauthenticated = await transitionHandler(new Request("https://howmuch.test/v1/plans/plan-test/transactions", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    }));
    expect(unauthenticated.status).toBe(401);

    expect((await transitionRequest("/v1/plans", "GET")).status).toBe(200);
    expect((await transitionRequest("/v1/plans/plan-test/transactions", "GET")).status).toBe(200);
    expect((await transitionRequest("/api/mobile/not-a-route", "POST")).status).toBe(404);
    expect((await transitionRequest("/v1/plans/plan-test/accounts/account-1", "PATCH", { account: { icon: "🐷" } })).status).not.toBe(423);

    const setup = await transitionHandler(new Request("https://howmuch.test/api/auth/setup", {
      method: "POST",
      headers: { authorization: "Bearer test-token", origin: "https://howmuch.test", "content-type": "application/json" },
      body: JSON.stringify({ username: "transition-owner", password: "transition-owner-password" }),
    }));
    expect(setup.status).toBe(200);
    const cookie = setup.headers.get("set-cookie")!.split(";", 1)[0];
    const csrfFirst = await transitionHandler(new Request("https://howmuch.test/v1/plans/plan-test/accounts", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: "{}",
    }));
    expect(csrfFirst.status).toBe(403);
    const lockedAfterCsrf = await transitionHandler(new Request("https://howmuch.test/v1/plans/plan-test/accounts", {
      method: "POST",
      headers: { cookie, origin: "https://howmuch.test", "content-type": "application/json" },
      body: "{}",
    }));
    expect(lockedAfterCsrf.status).toBe(423);
    expect((await transitionHandler(new Request("https://howmuch.test/api/auth/status", { headers: { cookie } }))).status).toBe(200);
    expect((await transitionHandler(new Request("https://howmuch.test/api/auth/logout", {
      method: "POST",
      headers: { cookie, origin: "https://howmuch.test" },
    }))).status).toBe(200);
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
    expect(created.data.transaction.approved).toBe(false);
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

  test("rejects a new linked split-transfer side without a 500", async () => {
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
    expect(created.data.transaction.approved).toBe(false);

    const rejected = await request(`/v1/plans/plan-test/transactions/${mirrorId}?expected_approved=false`, {
      method: "DELETE",
    });
    expect(rejected.status).toBe(200);
    expect((await rejected.json()).data.transaction).toMatchObject({ id: mirrorId, deleted: true, approved: false });

    const parent = await (await request(`/v1/plans/plan-test/transactions/${created.data.transaction.id}`)).json();
    expect(parent.data.transaction.deleted).toBe(false);
    expect(parent.data.transaction.subtransactions.find((sub: any) => sub.id === transferLine.id)).toMatchObject({
      id: transferLine.id,
      transfer_account_id: null,
      transfer_transaction_id: null,
    });
  });

  test("deletes unapproved rows when expected_approved is accidentally encoded into the path", async () => {
    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: { transaction: { account_id: "acct-1", date: "2026-08-30", amount: -16560, payee_name: "fp*Food Panda" } },
    })).json();
    const transactionId = created.data.transaction.id;
    expect(created.data.transaction.approved).toBe(false);

    const mangled = await request(
      `/v1/plans/plan-test/transactions/${transactionId}%3Fexpected_approved=false`,
      { method: "DELETE" },
    );
    expect(mangled.status).toBe(200);
    expect((await mangled.json()).data.transaction).toMatchObject({
      id: transactionId,
      deleted: true,
      approved: false,
      payee_name: "fp*Food Panda",
    });
  });

  test("rejects only transactions that are still unapproved", async () => {
    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: { transaction: { account_id: "acct-1", date: "2026-06-10", amount: -5000 } },
    })).json();
    const transactionId = created.data.transaction.id;

    await request(`/v1/plans/plan-test/transactions/${transactionId}`, {
      method: "PATCH",
      body: { transaction: { approved: true } },
    });
    const staleRejection = await request(`/v1/plans/plan-test/transactions/${transactionId}?expected_approved=false`, {
      method: "DELETE",
    });

    expect(staleRejection.status).toBe(409);
    expect((await staleRejection.json()).error.name).toBe("transaction_state_conflict");
    expect((await (await request(`/v1/plans/plan-test/transactions/${transactionId}`)).json()).data.transaction).toMatchObject({
      id: transactionId,
      approved: true,
      deleted: false,
    });
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

  test("updates multiple transactions on the collection PATCH used by YNAB", async () => {
    const firstId = await createTransaction({
      account_id: "acct-1",
      date: "2026-06-10",
      amount: -1000,
      memo: "TODO: one",
      import_id: "bulk-import-1",
    });
    const secondId = await createTransaction({
      account_id: "acct-1",
      date: "2026-06-11",
      amount: -2000,
      memo: "TODO: two",
    });
    const knowledgeBefore = (db.query("SELECT server_knowledge FROM plans WHERE id = 'plan-test'").get() as { server_knowledge: number }).server_knowledge;

    const response = await request("/v1/plans/plan-test/transactions", {
      method: "PATCH",
      body: {
        transactions: [
          { id: firstId, memo: "CLAIMED: one", flag_color: "green" },
          { id: secondId, memo: "CLAIMED: two", approved: true },
        ],
      },
    });
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.data.transaction_ids).toEqual([firstId, secondId]);
    expect(body.data.transactions.map((transaction: { id: string }) => transaction.id)).toEqual([firstId, secondId]);
    expect(body.data.transactions[0]).toMatchObject({ memo: "CLAIMED: one", flag_color: "green" });
    expect(body.data.transactions[1]).toMatchObject({ memo: "CLAIMED: two", approved: true });
    expect(body.data.server_knowledge).toBe(knowledgeBefore + 1);

    const alias = await request("/v1/budgets/plan-test/transactions", {
      method: "PATCH",
      body: { transactions: [{ import_id: "bulk-import-1", account_id: "acct-1", memo: "CLAIMED: import" }] },
    });
    expect(alias.status).toBe(200);
    expect((await alias.json()).data.transactions[0].memo).toBe("CLAIMED: import");
  });

  test("collection PATCH preserves an earlier transfer edit when both legs are included", async () => {
    const checking = await createAccountViaApi({ name: "Batch checking", type: "checking" });
    const savings = await createAccountViaApi({ name: "Batch savings", type: "savings" });
    const created = await (await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: { transaction: {
        account_id: checking.id,
        date: "2026-06-10",
        amount: -50000,
        payee_id: savings.transfer_payee_id,
      } },
    })).json();
    const outflow = created.data.transaction;

    const response = await request("/v1/plans/plan-test/transactions", {
      method: "PATCH",
      body: { transactions: [
        { id: outflow.id, amount: -75000, date: "2026-06-12", memo: "topped up" },
        { id: outflow.transfer_transaction_id, flag_color: "green" },
      ] },
    });
    expect(response.status).toBe(200);
    const transactions = (await response.json()).data.transactions;
    expect(transactions[0]).toMatchObject({ amount: -75000, date: "2026-06-12", memo: "topped up" });
    expect(transactions[1]).toMatchObject({ amount: 75000, date: "2026-06-12", memo: "topped up", flag_color: "green" });
  });

  test("rejects invalid collection PATCH bodies without changing other rows", async () => {
    const keptId = await createTransaction({ account_id: "acct-1", date: "2026-06-10", amount: -1000, memo: "keep" });
    const knowledge = (db.query("SELECT server_knowledge FROM plans WHERE id = 'plan-test'").get() as { server_knowledge: number }).server_knowledge;

    const tooMany = await request("/v1/plans/plan-test/transactions", {
      method: "PATCH",
      body: { transactions: Array.from({ length: 101 }, (_, index) => ({ id: `missing-${index}`, memo: "x" })) },
    });
    expect(tooMany.status).toBe(400);
    expect((await tooMany.json()).error.name).toBe("bad_request");

    const empty = await request("/v1/plans/plan-test/transactions", {
      method: "PATCH",
      body: { transactions: [] },
    });
    expect(empty.status).toBe(400);

    const missing = await request("/v1/plans/plan-test/transactions", {
      method: "PATCH",
      body: { transactions: [{ id: "missing-txn", memo: "changed" }, { id: keptId, memo: "changed" }] },
    });
    expect(missing.status).toBe(404);

    const stored = db.query("SELECT memo FROM transactions WHERE id = ?").get(keptId);
    expect(stored).toEqual({ memo: "keep" });
    expect(db.query("SELECT server_knowledge FROM plans WHERE id = 'plan-test'").get()).toEqual({ server_knowledge: knowledge });

    const bothKeys = await request("/v1/plans/plan-test/transactions", {
      method: "PATCH",
      body: { transactions: [{ id: keptId, import_id: "nope", memo: "id-wins" }] },
    });
    expect(bothKeys.status).toBe(200);
    expect((await bothKeys.json()).data.transactions[0].memo).toBe("id-wins");
    expect(db.query("SELECT import_id FROM transactions WHERE id = ?").get(keptId)).toEqual({ import_id: null });

    const duplicate = await request("/v1/plans/plan-test/transactions", {
      method: "PATCH",
      body: { transactions: [{ id: keptId, memo: "once" }, { id: keptId, memo: "twice" }] },
    });
    expect(duplicate.status).toBe(400);
    expect(db.query("SELECT memo FROM transactions WHERE id = ?").get(keptId)).toEqual({ memo: "id-wins" });

    await createTransaction({
      account_id: "acct-1",
      date: "2026-06-10",
      amount: -100,
      import_id: "shared-import",
    });
    await createTransaction({
      account_id: "acct-2",
      date: "2026-06-10",
      amount: -200,
      import_id: "shared-import",
    });
    const ambiguous = await request("/v1/plans/plan-test/transactions", {
      method: "PATCH",
      body: { transactions: [{ import_id: "shared-import", memo: "which" }] },
    });
    expect(ambiguous.status).toBe(400);
    expect((await ambiguous.json()).error.detail).toBe("import_id matches more than one transaction");

    const tombstone = await request("/v1/plans/plan-test/transactions", {
      method: "PATCH",
      body: { transactions: [{ id: keptId, deleted: true, memo: "still-live" }] },
    });
    expect(tombstone.status).toBe(200);
    expect((await tombstone.json()).data.transactions[0]).toMatchObject({ id: keptId, deleted: false, memo: "still-live" });
    expect(db.query("SELECT deleted, memo FROM transactions WHERE id = ?").get(keptId)).toEqual({ deleted: 0, memo: "still-live" });
  });

  test("creates multiple transactions on the collection POST used by YNAB", async () => {
    const response = await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transactions: [
          { id: "bulk-named", account_id: "acct-1", date: "2026-06-10", amount: -1100, payee_name: "One", import_id: "bulk-create-1" },
          { account_id: "acct-1", date: "2026-06-11", amount: -2200, payee_name: "Two" },
        ],
      },
    });
    expect(response.status).toBe(201);
    const body = await response.json();
    expect(body.data.transaction_ids).toEqual(["bulk-named", body.data.transaction_ids[1]]);
    expect(body.data.transactions[0].id).toBe("bulk-named");
    expect(body.data.transactions).toHaveLength(2);
    expect(body.data.transactions.map((transaction: { payee_name: string }) => transaction.payee_name)).toEqual(["One", "Two"]);
    expect(body.data.duplicate_import_ids).toEqual([]);

    const replay = await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transactions: [
          { account_id: "acct-1", date: "2026-06-10", amount: -1100, payee_name: "One", import_id: "bulk-create-1" },
          { account_id: "acct-1", date: "2026-06-12", amount: -3300, payee_name: "Three" },
        ],
      },
    });
    expect(replay.status).toBe(201);
    const replayed = await replay.json();
    expect(replayed.data.duplicate_import_ids).toEqual(["bulk-create-1"]);
    expect(replayed.data.transaction_ids).toHaveLength(2);
    expect(replayed.data.transactions).toHaveLength(2);
    expect(replayed.data.transactions[1].payee_name).toBe("Three");

    const bothKeys = await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transaction: { account_id: "acct-1", date: "2026-06-13", amount: -1 },
        transactions: [{ account_id: "acct-1", date: "2026-06-13", amount: -1 }],
      },
    });
    expect(bothKeys.status).toBe(400);

    const createdDeleted = await request("/v1/plans/plan-test/transactions", {
      method: "POST",
      body: {
        transactions: [{ account_id: "acct-1", date: "2026-06-14", amount: -1, payee_name: "Gone", deleted: true }],
      },
    });
    expect(createdDeleted.status).toBe(201);
    const createdDeletedBody = await createdDeleted.json();
    expect(createdDeletedBody.data.transactions[0]).toMatchObject({ payee_name: "Gone", deleted: true });
    expect(createdDeletedBody.data.transaction_ids).toHaveLength(1);
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

describe("account icons", () => {
  test("splits a leading emoji from a created name and defaults the rest by type", async () => {
    const card = await createAccountViaApi({ name: "💳 OCBC 365", type: "creditCard" });
    const savings = await createAccountViaApi({ name: "Rainy Day", type: "savings" });
    const travel = await createAccountViaApi({ name: "Travel ✈️", type: "creditCard" });
    expect(card).toMatchObject({ name: "OCBC 365", icon: "💳", type: "creditCard" });
    expect(savings).toMatchObject({ name: "Rainy Day", icon: "💰", type: "savings" });
    expect(travel).toMatchObject({ name: "Travel ✈️", icon: "💳", type: "creditCard" });

    const listed = await (await request("/v1/plans/plan-test/accounts")).json();
    const byId = Object.fromEntries(listed.data.accounts.map((account: any) => [account.id, account]));
    expect(byId[card.id]).toMatchObject({ name: "OCBC 365", icon: "💳" });
    expect(byId[savings.id]).toMatchObject({ name: "Rainy Day", icon: "💰" });
  });

  test("lets a user change the icon without renaming the account", async () => {
    const account = await createAccountViaApi({ name: "Everyday", type: "checking" });
    expect(account.icon).toBe("🏦");

    const updated = await request(`/v1/plans/plan-test/accounts/${account.id}`, {
      method: "PATCH",
      body: { account: { icon: "🐷" } },
    });
    expect(updated.status).toBe(200);
    expect((await updated.json()).data.account).toMatchObject({ name: "Everyday", icon: "🐷" });

    const rejected = await request(`/v1/plans/plan-test/accounts/${account.id}`, {
      method: "PATCH",
      body: { account: { icon: "not-an-emoji" } },
    });
    expect(rejected.status).toBe(400);
  });

  test("lets a user rename an account without changing its icon", async () => {
    const account = await createAccountViaApi({ name: "Everyday", type: "checking" });
    const renamed = await request(`/v1/plans/plan-test/accounts/${account.id}`, {
      method: "PATCH",
      body: { account: { name: "Daily Spend" } },
    });
    expect(renamed.status).toBe(200);
    expect((await renamed.json()).data.account).toMatchObject({ name: "Daily Spend", icon: "🏦" });

    const payees = await (await request("/v1/plans/plan-test/payees")).json();
    const transfer = payees.data.payees.find((payee: any) => payee.id === account.transfer_payee_id);
    expect(transfer.name).toBe("Transfer : Daily Spend");
  });

  test("keeps a custom icon when a later upsert still carries an emoji on the name", async () => {
    const repo = new LedgerRepository(db, "plan-test");
    const account = await createAccountViaApi({ name: "💳 OCBC", type: "creditCard" });
    await request(`/v1/plans/plan-test/accounts/${account.id}`, {
      method: "PATCH",
      body: { account: { icon: "🐷" } },
    });
    await repo.upsertAccount("plan-test", { id: account.id, name: "💳 OCBC", type: "creditCard" });
    const listed = await (await request(`/v1/plans/plan-test/accounts/${account.id}`)).json();
    expect(listed.data.account).toMatchObject({ name: "OCBC", icon: "🐷" });
  });
});

describe("account creation", () => {
  test("records a card opening balance as a liability and provisions a transfer payee", async () => {
    const card = await createAccountViaApi({
      name: "UOB Lady's Card",
      type: "creditCard",
      balance: -250000,
      icon: "💳",
      on_budget: true,
    });
    expect(card).toMatchObject({
      name: "UOB Lady's Card",
      type: "creditCard",
      balance: -250000,
      icon: "💳",
      on_budget: true,
    });
    expect(card.transfer_payee_id).toBeTruthy();

    const payees = await (await request("/v1/plans/plan-test/payees")).json();
    const transfer = payees.data.payees.find((payee: any) => payee.id === card.transfer_payee_id);
    expect(transfer).toMatchObject({
      name: "Transfer : UOB Lady's Card",
      transfer_account_id: card.id,
    });
  });

  test("places a tracking mortgage off-budget", async () => {
    const mortgage = await createAccountViaApi({
      name: "Home Loan",
      type: "mortgage",
      balance: -380000000,
      icon: "🏠",
      on_budget: false,
    });
    expect(mortgage).toMatchObject({
      name: "Home Loan",
      type: "mortgage",
      balance: -380000000,
      icon: "🏠",
      on_budget: false,
    });
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
      body: { transaction: { amount: -75000, date: "2026-06-12", memo: "topped up", approved: true } },
    })).json();
    expect(patched.data.transaction.amount).toBe(-75000);
    expect(patched.data.transaction.approved).toBe(true);

    const mirrored = await (
      await request(`/v1/plans/plan-test/transactions/${outflow.transfer_transaction_id}`)
    ).json();
    expect(mirrored.data.transaction.amount).toBe(75000);
    expect(mirrored.data.transaction.date).toBe("2026-06-12");
    expect(mirrored.data.transaction.memo).toBe("topped up");
    expect(mirrored.data.transaction.approved).toBe(true);

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

    const approved = await (await request(`/v1/plans/plan-test/transactions/${transferLine.transfer_transaction_id}`, {
      method: "PATCH",
      body: { transaction: { approved: true } },
    })).json();
    expect(approved.data.transaction.approved).toBeTrue();
    expect((await (await request(`/v1/plans/plan-test/transactions/${parent.id}`)).json()).data.transaction.approved).toBeTrue();

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

    const clearedPatch = await request(`/v1/plans/plan-test/transactions/${mirrorId}/cleared`, {
      method: "PATCH",
      body: { expected_cleared: "cleared", cleared: "uncleared" },
    });
    expect(clearedPatch.status).toBe(200);
    const clearedBody = await clearedPatch.json();
    expect(clearedBody.data.transaction.cleared).toBe("uncleared");
    expect(clearedBody.data.transaction.parent_transaction_id).toBe(created.data.transaction.id);
    expect((await request(`/v1/plans/plan-test/transactions/${mirrorId}/cleared`, {
      method: "PATCH",
      body: { expected_cleared: "cleared", cleared: "uncleared" },
    })).status).toBe(409);
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
    expect(transfer.approved).toBeTrue();

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
    expect(quickEntry.data.transaction.approved).toBeTrue();
    expect(quickEntry.data.transaction.source_kind).toBeUndefined();
  });

  test("rejects API-token access to non-default quick-entry plans", async () => {
    const alternatePlanId = "quick-entry-alternate-plan";
    const accountResponse = await request(`/v1/plans/${alternatePlanId}/accounts`, {
      method: "POST",
      body: { account: { name: "Alternate checking" } },
    });
    expect(accountResponse.status).toBe(404);
    const response = await request("/api/mobile/quick-entry", {
      method: "POST",
      body: {
        plan_id: alternatePlanId,
        client_id: "alternate-offline-entry",
        account_id: "alternate-account",
        date: "2026-07-18",
        amount_milli: -4321,
        payee_name: "Alternate cafe",
      },
    });

    expect(response.status).toBe(404);
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

  test("imports a Rewards Tracker export twice without duplicating cards or cached transactions", async () => {
    const payload = {
      ynab: { selectedBudgetId: "plan-test", selectedBudgetName: "Cutover", trackedAccountIds: ["acct-rewards"] },
      cards: [{
        id: "card-rewards",
        name: "Rewards Card",
        issuer: "UOB",
        type: "cashback",
        ynabAccountId: "acct-rewards",
        featured: true,
        earningRate: 1,
      }],
      rules: [],
      tagMappings: [{ id: "map-1", cardId: "card-rewards", ynabTag: "orange", rewardCategory: "Dining" }],
      calculations: [],
      themeGroups: [],
      settings: { currency: "SGD" },
      cachedData: {
        flagNames: { orange: "Dining" },
        dashboardTransactions: [{
          budgetId: "plan-test",
          sinceDate: "2026-03-01",
          fetchedAt: "2026-05-20T00:00:00.000Z",
          trackedAccountIds: ["acct-rewards"],
          isComplete: true,
          accounts: [{ id: "acct-rewards", name: "Rewards Card" }],
          transactions: [{
            id: "txn-rewards-1",
            date: "2026-05-12",
            amount: -2500000,
            account_id: "acct-rewards",
            payee_name: "Candlenut",
            flag_color: "orange",
            flag_name: "Dining",
            cleared: "cleared",
            approved: true,
          }],
        }],
      },
    };

    const first = await request("/api/import/rewards-tracker?plan_id=plan-test", { method: "POST", body: { payload } });
    expect(first.status).toBe(201);
    const firstBody = await first.json();
    expect(firstBody.data).toMatchObject({
      cards: 1,
      tag_mappings: 1,
      accounts_upserted: 1,
      transactions_imported: 1,
      transactions_updated: 0,
    });

    const second = await request("/api/import/rewards-tracker?plan_id=plan-test", { method: "POST", body: { payload } });
    expect(second.status).toBe(201);
    expect((await second.json()).data).toMatchObject({
      cards: 1,
      transactions_imported: 0,
      transactions_updated: 1,
    });

    const stored = await (await request("/api/import/rewards-tracker?plan_id=plan-test")).json();
    expect(stored.data.cards).toEqual([expect.objectContaining({ id: "card-rewards", ynabAccountId: "acct-rewards" })]);
    expect(db.query("SELECT COUNT(*) AS count FROM transactions WHERE plan_id='plan-test' AND deleted=0").get()).toEqual({ count: 1 });
    const register = await (await request("/v1/plans/plan-test/transactions?since_date=2026-05-01")).json();
    expect(register.data.transactions).toEqual([
      expect.objectContaining({ id: "txn-rewards-1", payee_name: "Candlenut", flag_color: "orange", amount: -2500000 }),
    ]);

    const rewards = await (await request("/api/reports/rewards?plan_id=plan-test&from=2026-05-01&to=2026-05-31&group=payee")).json();
    expect(rewards.data.cards).toEqual([
      expect.objectContaining({
        account_id: "acct-rewards",
        calculation: expect.objectContaining({
          total_spend: 2500,
          reward_type: "cashback",
        }),
      }),
    ]);
    expect(rewards.data.groups).toEqual([
      expect.objectContaining({ label: "Candlenut", spend: 2500 }),
    ]);
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

  test("imports YNAB plan metadata, skips unmatched deleted transactions, and requests full history by default", async () => {
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
      const importBody = await importResponse.json();
      expect(importBody.data.imported_transactions).toBe(0);
      expect(importBody.data.raw_objects.transaction).toBe(1);

      const plans = await (await request("/v1/plans")).json();
      expect(plans.data.plans[0].name).toBe("Imported Plan");

      const settings = await (await request("/v1/plans/plan-test/settings")).json();
      expect(settings.data.settings.date_format.format).toBe("YYYY-MM-DD");
      expect(settings.data.settings.display.flag_names.blue).toBe("Follow up");

      const transactions = await (await request("/v1/plans/plan-test/transactions?last_knowledge_of_server=0")).json();
      expect(transactions.data.transactions).toHaveLength(0);
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

describe("password authentication", () => {
  const password = ["ledger", "test", "passphrase", "2026"].join("-");
  const wrongPassword = ["incorrect", "test", "passphrase", "2026"].join("-");
  const authRequest = (path: string, body: unknown, headers: Record<string, string> = {}) => handler(
    new Request(`https://howmuch.test${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", origin: "https://howmuch.test", ...headers },
      body: JSON.stringify(body),
    }),
  );

  test("sets up exactly once without storing the password", async () => {
    const before = await handler(new Request("https://howmuch.test/api/auth/status"));
    expect((await before.json()).data).toEqual({
      setup_required: true,
      bootstrap_required: true,
      user: null,
    });

    const setup = await authRequest(
      "/api/auth/setup",
      { username: "Owner.Name", password },
      { authorization: "Bearer test-token" },
    );
    expect(setup.status).toBe(200);
    expect(setup.headers.get("set-cookie")).toContain("__Host-howmuch_session=");
    expect(setup.headers.get("set-cookie")).toContain("HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=");
    expect(JSON.stringify(db.query("SELECT * FROM password_credentials").get())).not.toContain(password);
    expect(db.query("SELECT COUNT(*) AS count FROM users").get()).toEqual({ count: 1 });
    expect(db.query("SELECT role FROM plan_memberships").get()).toEqual({ role: "owner" });

    const repeated = await authRequest(
      "/api/auth/setup",
      { username: "other", password },
      { authorization: "Bearer test-token" },
    );
    expect(repeated.status).toBe(409);
    expect(db.query("SELECT COUNT(*) AS count FROM users").get()).toEqual({ count: 1 });
  });

  test("allows tokenless local setup without an Authorization header", async () => {
    const localHandler = createHandler({
      db,
      config: {
        dbPath: ":memory:",
        port: 0,
        defaultPlanId: "plan-test",
        transitionReadOnly: false,
      },
    });
    const status = await localHandler(new Request("http://localhost:8787/api/auth/status"));
    expect((await status.json()).data.bootstrap_required).toBeFalse();
    const setup = await localHandler(new Request("http://localhost:8787/api/auth/setup", {
      method: "POST",
      headers: { "content-type": "application/json", origin: "http://localhost:8787" },
      body: JSON.stringify({ username: "owner", password }),
    }));
    expect(setup.status).toBe(200);
  });

  test("logs in with browser cookie and native token, then revokes logout", async () => {
    const setup = await authRequest(
      "/api/auth/setup",
      { username: "Owner.Name", password },
      { authorization: "Bearer test-token" },
    );
    const cookie = setup.headers.get("set-cookie")!.split(";", 1)[0];

    expect((await authRequest("/api/auth/login", { username: "owner.name", password: wrongPassword })).status).toBe(401);
    const login = await authRequest("/api/auth/login", { username: "OWNER.NAME", password });
    expect(login.status).toBe(200);

    const cookieRead = await handler(new Request("https://howmuch.test/v1/user", { headers: { cookie } }));
    expect(cookieRead.status).toBe(200);
    const badHeader = await handler(new Request("https://howmuch.test/v1/user", {
      headers: { cookie, authorization: "Bearer invalid" },
    }));
    expect(badHeader.status).toBe(401);

    const tokenResponse = await authRequest("/api/auth/token", { username: "owner.name", password });
    expect(tokenResponse.status).toBe(200);
    const token = (await tokenResponse.json()).data.token;
    expect(db.query("SELECT token_hash FROM sessions WHERE token_hash = ?").get(token)).toBeNull();
    expect((await handler(new Request("https://howmuch.test/v1/user", {
      headers: { authorization: `Bearer ${token}` },
    }))).status).toBe(200);
    expect((await handler(new Request("https://howmuch.test/api/auth/logout", {
      method: "POST",
      headers: { authorization: `Bearer ${token}` },
    }))).status).toBe(200);
    expect((await handler(new Request("https://howmuch.test/v1/user", {
      headers: { authorization: `Bearer ${token}` },
    }))).status).toBe(401);
  });

  test("syncs ordered account presentation preferences per user and plan", async () => {
    await authRequest(
      "/api/auth/setup",
      { username: "owner", password },
      { authorization: "Bearer test-token" },
    );
    const tokenResponse = await authRequest("/api/auth/token", { username: "owner", password });
    const token = (await tokenResponse.json()).data.token;
    const headers = { authorization: `Bearer ${token}`, "content-type": "application/json" };
    const path = "https://howmuch.test/v1/plans/plan-test/account_preferences";

    const empty = await handler(new Request(path, { headers }));
    expect(empty.status).toBe(200);
    expect((await empty.json()).data.account_preferences).toBeNull();

    const preferences = {
      favourite_account_ids: ["card", "cash"],
      account_order: ["cash", "card"],
      account_order_by_group: {
        favourites: ["card", "cash"],
        "custom-travel": ["cash", "card"],
      },
      account_group_sorts: { favourites: "manual", cash: "alphabetical" },
      custom_account_groups: [
        { id: "custom-travel", name: "Travel", account_ids: ["cash", "card"] },
      ],
    };
    const saved = await handler(new Request(path, {
      method: "PUT",
      headers,
      body: JSON.stringify({ account_preferences: preferences, expected_revision: 0 }),
    }));
    expect(saved.status).toBe(200);
    expect((await saved.json()).data).toEqual({ account_preferences: preferences, account_preferences_revision: 1 });

    const stale = await handler(new Request(path, {
      method: "PUT",
      headers,
      body: JSON.stringify({ account_preferences: { ...preferences, favourite_account_ids: [] }, expected_revision: 0 }),
    }));
    expect(stale.status).toBe(409);

    const reservedGroup = await handler(new Request(path, {
      method: "PUT",
      headers,
      body: JSON.stringify({
        account_preferences: {
          ...preferences,
          custom_account_groups: [{ id: "cash", name: "Custom cash", account_ids: [] }],
        },
        expected_revision: 1,
      }),
    }));
    expect(reservedGroup.status).toBe(400);

    const dangerousGroup = await handler(new Request(path, {
      method: "PUT",
      headers,
      body: JSON.stringify({
        account_preferences: {
          ...preferences,
          account_order_by_group: { constructor: [] },
          custom_account_groups: [{ id: "__proto__", name: "Broken", account_ids: [] }],
        },
        expected_revision: 1,
      }),
    }));
    expect(dangerousGroup.status).toBe(400);

    const accentDuplicateGroups = await handler(new Request(path, {
      method: "PUT",
      headers,
      body: JSON.stringify({
        account_preferences: {
          ...preferences,
          custom_account_groups: [
            { id: "custom-travel", name: "Travel", account_ids: [] },
            { id: "custom-travel-accent", name: "Trável", account_ids: [] },
          ],
        },
        expected_revision: 1,
      }),
    }));
    expect(accentDuplicateGroups.status).toBe(400);

    const accentReservedGroup = await handler(new Request(path, {
      method: "PUT",
      headers,
      body: JSON.stringify({
        account_preferences: {
          ...preferences,
          custom_account_groups: [{ id: "custom-cash", name: "Cásh", account_ids: [] }],
        },
        expected_revision: 1,
      }),
    }));
    expect(accentReservedGroup.status).toBe(400);

    const multibyteAccountIDs = Array.from({ length: 300 }, (_, index) => `${index}-`.padEnd(200, "界"));
    const oversized = await handler(new Request(path, {
      method: "PUT",
      headers,
      body: JSON.stringify({
        account_preferences: { ...preferences, favourite_account_ids: multibyteAccountIDs },
        expected_revision: 1,
      }),
    }));
    expect(oversized.status).toBe(400);

    const read = await handler(new Request(path, { headers }));
    expect((await read.json()).data).toEqual({ account_preferences: preferences, account_preferences_revision: 1 });
    expect(db.query("SELECT COUNT(*) count FROM account_preferences").get()).toEqual({ count: 1 });
  });

  test("creates, lists, authenticates, and revokes account-scoped API tokens", async () => {
    const setup = await authRequest(
      "/api/auth/setup",
      { username: "owner", password },
      { authorization: "bearer test-token" },
    );
    const cookie = setup.headers.get("set-cookie")!.split(";", 1)[0];

    const missingOrigin = await handler(new Request("https://howmuch.test/api/auth/personal-tokens", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({ name: "OpenClaw" }),
    }));
    expect(missingOrigin.status).toBe(403);

    const createdResponse = await handler(new Request("https://howmuch.test/api/auth/personal-tokens", {
      method: "POST",
      headers: { cookie, origin: "https://howmuch.test", "content-type": "application/json" },
      body: JSON.stringify({ name: "  OpenClaw  " }),
    }));
    expect(createdResponse.status).toBe(201);
    expect(createdResponse.headers.get("cache-control")).toBe("no-store");
    const createdBody = (await createdResponse.json()).data;
    const created = createdBody.token;
    expect(created).toMatchObject({ name: "OpenClaw" });
    expect(createdBody.value).toMatch(/^hm_pat_[A-Za-z0-9_-]{43}$/);
    expect(JSON.stringify(db.query("SELECT * FROM personal_api_tokens").get())).not.toContain(createdBody.value);

    const listResponse = await handler(new Request("https://howmuch.test/api/auth/personal-tokens", { headers: { cookie } }));
    expect(listResponse.status).toBe(200);
    const listed = (await listResponse.json()).data.tokens;
    expect(listed).toEqual([{
      id: created.id,
      name: "OpenClaw",
      created_at: created.created_at,
      revoked_at: null,
    }]);
    expect(JSON.stringify(listed)).not.toContain(createdBody.value);

    const bearerRead = await handler(new Request("https://howmuch.test/v1/user", {
      headers: { authorization: `bearer ${createdBody.value}` },
    }));
    expect(bearerRead.status).toBe(200);
    expect((await bearerRead.json()).data.user.username).toBe("owner");
    expect((await handler(new Request("https://howmuch.test/api/auth/personal-tokens", {
      headers: { authorization: `Bearer ${createdBody.value}` },
    }))).status).toBe(401);
    expect((await handler(new Request("https://howmuch.test/api/auth/personal-tokens", {
      headers: { authorization: "Bearer test-token" },
    }))).status).toBe(401);
    const nativeResponse = await authRequest("/api/auth/token", { username: "owner", password });
    const nativeToken = (await nativeResponse.json()).data.token;
    expect((await handler(new Request("https://howmuch.test/api/auth/personal-tokens", {
      headers: { authorization: `Bearer ${nativeToken}` },
    }))).status).toBe(401);

    const revoked = await handler(new Request(`https://howmuch.test/api/auth/personal-tokens/${created.id}`, {
      method: "DELETE",
      headers: { cookie, origin: "https://howmuch.test" },
    }));
    expect(revoked.status).toBe(200);
    expect((await handler(new Request("https://howmuch.test/v1/user", {
      headers: { authorization: `Bearer ${createdBody.value}` },
    }))).status).toBe(401);
    expect((await handler(new Request(`https://howmuch.test/api/auth/personal-tokens/${created.id}`, {
      method: "DELETE",
      headers: { cookie, origin: "https://howmuch.test" },
    }))).status).toBe(200);
    const afterRevoke = await handler(new Request("https://howmuch.test/api/auth/personal-tokens", { headers: { cookie } }));
    expect((await afterRevoke.json()).data.tokens[0].revoked_at).toBeNumber();
  });

  test("enforces cookie CSRF and membership roles before plan access", async () => {
    const setup = await authRequest(
      "/api/auth/setup",
      { username: "owner", password },
      { authorization: "Bearer test-token" },
    );
    const cookie = setup.headers.get("set-cookie")!.split(";", 1)[0];
    const user = db.query("SELECT id FROM users").get() as { id: string };
    db.run("INSERT INTO plans(id,name) VALUES ('viewer-plan','Viewer'),('private-plan','Private')");
    db.run("INSERT INTO plan_memberships(plan_id,user_id,role) VALUES ('viewer-plan',?,'viewer')", [user.id]);

    const plans = await handler(new Request("https://howmuch.test/v1/plans", { headers: { cookie } }));
    expect((await plans.json()).data.plans.map((plan: { id: string }) => plan.id).sort()).toEqual(["plan-test", "viewer-plan"]);

    const missingOrigin = await handler(new Request("https://howmuch.test/v1/plans/plan-test/accounts", {
      method: "POST",
      headers: { cookie, "content-type": "application/json" },
      body: JSON.stringify({ account: { name: "Cash" } }),
    }));
    expect(missingOrigin.status).toBe(403);

    const viewerWrite = await handler(new Request("https://howmuch.test/v1/plans/viewer-plan/accounts", {
      method: "POST",
      headers: { cookie, origin: "https://howmuch.test", "content-type": "application/json" },
      body: JSON.stringify({ account: { name: "Cash" } }),
    }));
    expect(viewerWrite.status).toBe(403);
    const viewerPreferences = await handler(new Request("https://howmuch.test/v1/plans/viewer-plan/account_preferences", {
      method: "PUT",
      headers: { cookie, origin: "https://howmuch.test", "content-type": "application/json" },
      body: JSON.stringify({
        account_preferences: {
          favourite_account_ids: [], account_order: [], account_order_by_group: {}, account_group_sorts: {}, custom_account_groups: [],
        },
        expected_revision: 0,
      }),
    }));
    expect(viewerPreferences.status).toBe(200);
    const viewerReconcile = await handler(new Request("https://howmuch.test/v1/plans/viewer-plan/accounts/cash/reconcile", {
      method: "POST",
      headers: { cookie, origin: "https://howmuch.test", "content-type": "application/json", "idempotency-key": "viewer-reconcile" },
      body: JSON.stringify({ statement_date: "2026-08-31", statement_balance: 0 }),
    }));
    expect(viewerReconcile.status).toBe(403);
    const viewerPreview = await handler(new Request("https://howmuch.test/v1/plans/viewer-plan/accounts/cash/reconciliation?statement_date=2026-08-31", {
      headers: { cookie },
    }));
    expect(viewerPreview.status).toBe(404);

    const privateRead = await handler(new Request("https://howmuch.test/v1/plans/private-plan", { headers: { cookie } }));
    expect(privateRead.status).toBe(404);
    const prototypePlan = await handler(new Request("https://howmuch.test/v1/plans/constructor", { headers: { cookie } }));
    expect(prototypePlan.status).toBe(404);
    const prototypeOverride = await handler(new Request("https://howmuch.test/api/mobile/quick-entry", {
      method: "POST",
      headers: { cookie, origin: "https://howmuch.test", "content-type": "application/json" },
      body: JSON.stringify({ plan_id: "__proto__", account_id: "cash", amount_milli: -100 }),
    }));
    expect(prototypeOverride.status).toBe(404);
    expect(db.query("SELECT id FROM plans WHERE id IN ('constructor','__proto__')").all()).toEqual([]);
    expect(db.query("SELECT COUNT(*) AS count FROM accounts WHERE plan_id IN ('viewer-plan','private-plan')").get()).toEqual({ count: 0 });
  });

  test("expires sessions and throttles malformed login attempts", async () => {
    await authRequest(
      "/api/auth/setup",
      { username: "owner", password },
      { authorization: "Bearer test-token" },
    );
    const tokenResponse = await authRequest("/api/auth/token", { username: "owner", password });
    const token = (await tokenResponse.json()).data.token;
    db.run("UPDATE sessions SET expires_at = unixepoch() - 1");
    expect((await handler(new Request("https://howmuch.test/v1/user", {
      headers: { authorization: `Bearer ${token}` },
    }))).status).toBe(401);

    for (let attempt = 1; attempt <= 10; attempt++) {
      const response = await authRequest("/api/auth/token", { username: "missing", password: "short" });
      expect(response.status).toBe(401);
    }
    const throttled = await authRequest("/api/auth/token", { username: "missing", password: "short" });
    expect(throttled.status).toBe(429);
    expect(throttled.headers.get("retry-after")).toBe("900");
  });
});

function request(path: string, init: { method?: string; body?: unknown; headers?: Record<string, string> } = {}): Promise<Response> {
  return handler(
    new Request(`http://howmuch.test${path}`, {
      method: init.method ?? "GET",
      headers: {
        authorization: "Bearer test-token",
        "content-type": "application/json",
        ...init.headers,
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
