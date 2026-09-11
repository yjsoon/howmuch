/**
 * Checks that `ynab_source_month_activity` (#174) says exactly what the old
 * whole-plan raw-object scan said.
 *
 * The month view used to rebuild its source baseline on every request by
 * loading every raw YNAB transaction and subtransaction object in the plan and
 * parsing them in the Worker. Migration 020 / 0017 materialises that baseline
 * once. This script recomputes it the old way, in TypeScript, straight from
 * `ynab_raw_objects`, and compares it row by row with the table.
 *
 *   bun scripts/verify-month-activity-parity.ts --db data/howmuch-real.sqlite
 *
 * Output is aggregate counts only — never a category, a payee, a memo or an
 * amount — so it is safe to paste into an issue or a PR.
 *
 * The comparison deliberately stops before the uncategorised mapping. Both
 * paths store a line with no category under the sentinel `''` and resolve it
 * to the plan's imported "Uncategorized" category at read time, from the month
 * snapshot, because that category can differ per month. Resolution is shared,
 * so it is not what parity is about; `apps/api/tests/ynab-month-activity.test.ts`
 * covers it at the repository level.
 */
import { Database } from "bun:sqlite";

/** `plan_id  month  category_id` (category_id `''` = no category on the source line). */
export type ActivityKey = string;

export type ParityCounts = {
  plans: number;
  months: number;
  /** Distinct (plan, month, category) cells present on either side. */
  rows: number;
  mismatches: number;
  /** Cells the scan produced and the table does not have. */
  missing: number;
  /** Cells the table has and the scan did not produce. */
  extra: number;
  /** Cells both sides have with different amounts. */
  different: number;
};

const UNIT = "";

/** `integerMilliunits` from `repository.ts`, which the old scan used. */
function integerMilliunits(value: unknown): number {
  const number = value == null ? 0 : Number(value);
  if (!Number.isSafeInteger(number)) throw new Error("amount must be integer milliunits");
  return number;
}

/**
 * The pre-materialisation baseline, recomputed from the raw mirror.
 *
 * This is a transcription of the loop that `monthCategoryActivityDeltas` ran
 * per month, generalised to every month at once. Every rule is deliberate:
 * deleted objects are skipped by payload (not by the table column), a
 * transaction needs a string `date`, live subtransaction lines replace the
 * parent line entirely, a subtransaction with no `transaction_id` is ignored,
 * and a line whose payload carries a present-but-empty `category_id` is
 * dropped, as `if (!categoryID) continue` used to drop it.
 */
export function scanSourceMonthActivity(db: Database): Map<ActivityKey, number> {
  const subsByTransaction = new Map<string, any[]>();
  for (const row of db.query("SELECT plan_id, payload_json FROM ynab_raw_objects WHERE object_type = 'subtransaction'").all() as any[]) {
    const subtransaction = JSON.parse(String(row.payload_json));
    if (subtransaction.deleted || !subtransaction.transaction_id) continue;
    const key = `${row.plan_id}${UNIT}${String(subtransaction.transaction_id)}`;
    const entries = subsByTransaction.get(key) ?? [];
    entries.push(subtransaction);
    subsByTransaction.set(key, entries);
  }

  const activity = new Map<ActivityKey, number>();
  for (const row of db.query("SELECT plan_id, object_id, payload_json FROM ynab_raw_objects WHERE object_type = 'transaction'").all() as any[]) {
    const transaction = JSON.parse(String(row.payload_json));
    if (transaction.deleted || typeof transaction.date !== "string") continue;
    const month = `${transaction.date.slice(0, 7)}-01`;
    const transactionID = String(transaction.id ?? row.object_id);
    const subtransactions = subsByTransaction.get(`${row.plan_id}${UNIT}${transactionID}`) ?? [];
    const lines = subtransactions.length > 0
      ? subtransactions.map((subtransaction) => ({ categoryID: subtransaction.category_id, amount: subtransaction.amount }))
      : [{ categoryID: transaction.category_id, amount: transaction.amount }];
    for (const line of lines) {
      const categoryID = line.categoryID == null ? "" : String(line.categoryID);
      // A null category becomes the sentinel; a present-but-empty one is dropped.
      if (line.categoryID != null && categoryID === "") continue;
      const key = `${row.plan_id}${UNIT}${month}${UNIT}${categoryID}`;
      activity.set(key, (activity.get(key) ?? 0) + integerMilliunits(line.amount));
    }
  }
  return activity;
}

/** The materialised table, in the same shape. */
export function materialisedMonthActivity(db: Database): Map<ActivityKey, number> {
  const activity = new Map<ActivityKey, number>();
  for (const row of db.query("SELECT plan_id, month, category_id, activity FROM ynab_source_month_activity").all() as any[]) {
    activity.set(`${row.plan_id}${UNIT}${row.month}${UNIT}${row.category_id}`, Number(row.activity));
  }
  return activity;
}

/** Compares both sides and returns counts. Never returns a key or an amount. */
export function compareMonthActivity(db: Database): ParityCounts {
  const scanned = scanSourceMonthActivity(db);
  const materialised = materialisedMonthActivity(db);
  const keys = new Set([...scanned.keys(), ...materialised.keys()]);

  const plans = new Set<string>();
  const months = new Set<string>();
  let missing = 0;
  let extra = 0;
  let different = 0;
  for (const key of keys) {
    const [planId, month] = key.split(UNIT);
    plans.add(planId!);
    months.add(`${planId}${UNIT}${month}`);
    const left = scanned.get(key);
    const right = materialised.get(key);
    if (left === undefined) extra += 1;
    else if (right === undefined) missing += 1;
    else if (left !== right) different += 1;
  }

  return {
    plans: plans.size,
    months: months.size,
    rows: keys.size,
    mismatches: missing + extra + different,
    missing,
    extra,
    different,
  };
}

function parseDbPath(argv: string[]): string {
  const index = argv.indexOf("--db");
  const path = index >= 0 ? argv[index + 1] : undefined;
  if (!path) throw new Error("usage: bun scripts/verify-month-activity-parity.ts --db <sqlite file>");
  return path;
}

if (import.meta.main) {
  const db = new Database(parseDbPath(Bun.argv.slice(2)), { readonly: true });
  try {
    const counts = compareMonthActivity(db);
    console.log(JSON.stringify({ event: "month_activity_parity", ...counts }));
    if (counts.mismatches > 0) process.exit(1);
  } finally {
    db.close();
  }
}
