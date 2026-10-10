// Usage: bun capture.ts <repo-root> <db-path> <seed|read|prune|writes> <out.json>
// Drives the real HTTP handler of the checkout at <repo-root> over a file database.
import { Database } from "bun:sqlite";
import { writeFileSync } from "node:fs";

const [root, dbPath, mode, out] = process.argv.slice(2);
const { applyMigrations } = await import(`${root}/apps/api/src/db`);
const { createHandler } = await import(`${root}/apps/api/src/http`);
const { LedgerRepository } = await import(`${root}/apps/api/src/repository`);

const db = new Database(dbPath);
applyMigrations(db);
const handler = createHandler({ db, config: { dbPath, port: 0, apiToken: "test-token", defaultPlanId: "plan-ynab", transitionReadOnly: false } });
const nativeHandler = createHandler({ db, config: { dbPath, port: 0, apiToken: "test-token", defaultPlanId: "plan-native", transitionReadOnly: false } });
const call = (path: string, method = "GET", body?: unknown, key?: string) =>
  handler(new Request(`http://howmuch.test${path}`, {
    method,
    headers: { authorization: "Bearer test-token", "content-type": "application/json", ...(key ? { "idempotency-key": key } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  }));

const SCHEDULE_IDS = ["sched-monthly", "sched-split", "sched-deleted", "sched-ghost-refs", "sched-transfer", "sched-edited", "sched-removed"];

async function read() {
  const result: Record<string, unknown> = {};
  const list = await (await call("/v1/plans/plan-ynab/scheduled_transactions")).json();
  result.list = list.data.scheduled_transactions;
  result.subtransactions = (await (await call("/v1/plans/plan-ynab/scheduled_subtransactions")).json()).data.scheduled_subtransactions;
  const singles: Record<string, unknown> = {};
  for (const id of [...SCHEDULE_IDS, "created-local"]) {
    const response = await call(`/v1/plans/plan-ynab/scheduled_transactions/${id}`);
    singles[id] = { status: response.status, body: response.status === 200 ? (await response.json()).data.scheduled_transaction : null };
  }
  result.singles = singles;
  // The category guard: refused on the YNAB plan, allowed on a native one.
  const ynab = await call("/v1/plans/plan-ynab/category_groups", "POST", { category_group: { id: `guard-ynab-${mode}`, name: "Guard" } }, `guard-ynab-${mode}`);
  const native = await nativeHandler(new Request("http://howmuch.test/v1/plans/plan-native/category_groups", {
    method: "POST",
    headers: { authorization: "Bearer test-token", "content-type": "application/json", "idempotency-key": `guard-native-${mode}` },
    body: JSON.stringify({ category_group: { id: `guard-native-${mode}`, name: "Guard" } }),
  }));
  result.guard = { ynabPlanStatus: ynab.status, nativePlanStatus: native.status };
  return result;
}

if (mode === "seed") {
  const repo = new LedgerRepository(db, "plan-ynab");
  await repo.ensurePlan("plan-ynab");
  await repo.ensurePlan("plan-native");
  const P = "plan-ynab";
  await repo.upsertPlan(P, { id: P, name: "YNAB plan" });
  for (const account of [{ id: "cash", name: "Cash" }, { id: "card", name: "Card" }, { id: "savings", name: "Savings" }]) await repo.upsertAccount(P, account);
  await repo.upsertCategoryGroup(P, { id: "living", name: "Living" });
  await repo.upsertCategory(P, { id: "food", category_group_id: "living", name: "Food" });
  await repo.upsertCategory(P, { id: "rent", category_group_id: "living", name: "Rent" });
  await repo.upsertCategory(P, { id: "retired", category_group_id: "living", name: "Retired", deleted: true });
  await repo.upsertPayee(P, { id: "landlord", name: "Landlord" });
  await repo.upsertPayee(P, { id: "grocer", name: "Grocer" });
  const raw = (type: string, id: string, payload: unknown) => repo.upsertYnabRawObject(P, type, id, payload, 42);
  await raw("month", "2026-01-01", { month: "2026-01-01" });
  await raw("scheduled_transaction", "sched-monthly", { id: "sched-monthly", account_id: "cash", date_first: "2026-01-05", date_next: "2026-11-05", frequency: "monthly", amount: -2500000, payee_id: "landlord", category_id: "rent", memo: "rent", flag_color: "red", deleted: false, extra_ynab_field: { keep: ["me"] } });
  await raw("scheduled_transaction", "sched-split", { id: "sched-split", account_id: "card", date_first: "2026-02-01", date_next: "2026-11-01", frequency: "everyOtherWeek", amount: -90000, payee_id: "grocer", category_id: null, memo: "split", deleted: false });
  await raw("scheduled_subtransaction", "sched-split\u001fa", { id: "a", scheduled_transaction_id: "sched-split", amount: -60000, category_id: "food", payee_id: "grocer", memo: "line a", deleted: false });
  await raw("scheduled_subtransaction", "sched-split\u001fb", { id: "b", scheduled_transaction_id: "sched-split", amount: -30000, category_id: "rent", memo: "line b", deleted: false });
  await raw("scheduled_subtransaction", "sched-split\u001fgone", { id: "gone", scheduled_transaction_id: "sched-split", amount: -1, category_id: "food", deleted: true });
  await raw("scheduled_transaction", "sched-deleted", { id: "sched-deleted", account_id: "cash", date_first: "2026-03-01", date_next: "2026-12-01", frequency: "yearly", amount: -100, deleted: true });
  await raw("scheduled_transaction", "sched-ghost-refs", { id: "sched-ghost-refs", account_id: "cash", date_first: "2026-04-01", date_next: "2026-12-24", frequency: "never", amount: -4200, payee_id: "no-such-payee", category_id: "retired", deleted: false });
  await raw("scheduled_transaction", "sched-transfer", { id: "sched-transfer", account_id: "cash", date_first: "2026-05-01", date_next: "2026-11-15", frequency: "twiceAMonth", amount: -100000, transfer_account_id: "savings", deleted: false });
  await raw("scheduled_transaction", "sched-edited", { id: "sched-edited", account_id: "cash", date_first: "2026-06-01", date_next: "2026-11-20", frequency: "weekly", amount: -700, payee_id: "grocer", category_id: "food", memo: "before edit", deleted: false });
  await raw("scheduled_transaction", "sched-removed", { id: "sched-removed", account_id: "cash", date_first: "2026-07-01", date_next: "2026-11-25", frequency: "monthly", amount: -800, deleted: false });
  await raw("transaction", "txn-1", { id: "txn-1", account_id: "cash", date: "2026-01-05", amount: -2500000, category_id: "rent", deleted: false });
  // User changes made before the migration: an overlay, a tombstone and a local schedule.
  const edit = await call("/v1/plans/plan-ynab/scheduled_transactions/sched-edited", "PATCH", { scheduled_transaction: { memo: "after edit", date_next: "2026-12-20" } }, "seed-edit");
  const remove = await call("/v1/plans/plan-ynab/scheduled_transactions/sched-removed", "DELETE", undefined, "seed-remove");
  const create = await call("/v1/plans/plan-ynab/scheduled_transactions", "POST", { scheduled_transaction: { id: "created-local", account_id: "cash", date_first: "2026-08-01", frequency: "monthly", amount: -3000, subtransactions: [{ amount: -1000, category_id: "food" }, { amount: -2000, category_id: "rent" }] } }, "seed-create");
  if (edit.status !== 200 || remove.status !== 200 || create.status !== 201) throw new Error(`seed writes failed: ${edit.status} ${remove.status} ${create.status}`);
  writeFileSync(out, JSON.stringify(await read(), null, 2));
} else if (mode === "read") {
  writeFileSync(out, JSON.stringify(await read(), null, 2));
} else if (mode === "prune") {
  // What #161 would later do: drop the mirror objects this fix stops depending on.
  const removed = db.run("DELETE FROM ynab_raw_objects WHERE object_type IN ('scheduled_transaction','scheduled_subtransaction','month','transaction','subtransaction')");
  console.log(`pruned mirror rows: ${removed.changes}`);
  writeFileSync(out, JSON.stringify(await read(), null, 2));
} else if (mode === "writes") {
  // After pruning: the app still writes schedules, and a re-import neither
  // overwrites the user's edit nor loses a new schedule.
  const repo = new LedgerRepository(db, "plan-ynab");
  const patch = await call("/v1/plans/plan-ynab/scheduled_transactions/sched-monthly", "PATCH", { scheduled_transaction: { memo: "edited after prune" } }, "post-prune-patch");
  const del = await call("/v1/plans/plan-ynab/scheduled_transactions/sched-transfer", "DELETE", undefined, "post-prune-delete");
  await repo.upsertYnabRawObject("plan-ynab", "scheduled_transaction", "sched-edited", { id: "sched-edited", account_id: "cash", date_first: "2026-06-01", date_next: "2026-11-20", frequency: "weekly", amount: -999, memo: "YNAB says otherwise", deleted: false }, 43);
  await repo.upsertYnabRawObject("plan-ynab", "scheduled_transaction", "sched-new-from-sync", { id: "sched-new-from-sync", account_id: "card", date_first: "2026-09-01", date_next: "2026-12-01", frequency: "monthly", amount: -1234, payee_id: "grocer", category_id: "food", deleted: false }, 43);
  await repo.upsertYnabRawObject("plan-ynab", "scheduled_subtransaction", "sched-new-from-sync\u001fx", { id: "x", scheduled_transaction_id: "sched-new-from-sync", amount: -1234, category_id: "food", deleted: false }, 43);
  const list = (await (await call("/v1/plans/plan-ynab/scheduled_transactions")).json()).data.scheduled_transactions;
  const pick = (id: string) => list.find((row: any) => row.id === id);
  writeFileSync(out, JSON.stringify({
    statuses: { patch: patch.status, delete: del.status },
    patchedMemo: pick("sched-monthly")?.memo,
    deletedStillListed: Boolean(pick("sched-transfer")),
    reimportKeptEdit: { memo: pick("sched-edited")?.memo, amount: pick("sched-edited")?.amount },
    newFromSync: { amount: pick("sched-new-from-sync")?.amount, lines: pick("sched-new-from-sync")?.subtransactions?.length },
  }, null, 2));
}
