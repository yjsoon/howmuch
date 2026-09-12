/**
 * Compare the aggregate-backed net-worth and cached age-of-money reports with
 * the full-history reports, on a real SQLite export.
 *
 *   bun scripts/verify-report-parity.ts --db data/howmuch-real.sqlite
 *
 * The database is opened read-only and only aggregate counts are printed --
 * never a date, an account name, a payee, a memo or an amount -- so the output
 * is safe to paste into a pull request or an issue.
 */
import { Database } from "bun:sqlite";
import { AsyncReportService } from "../apps/api/src/async-reports";
import type { AsyncSqlDatabase, SqlValues } from "../apps/api/src/async-sql";
import { ReportService } from "../apps/api/src/reports";

type Row = Record<string, any>;

/** The asynchronous read surface, served straight from a local SQLite file. */
class LocalAsyncDatabase implements AsyncSqlDatabase {
  constructor(private readonly db: Database) {}
  async all<R = Row>(sql: string, values: SqlValues = []): Promise<R[]> {
    return this.db.query(sql).all(...(values as any[])) as R[];
  }
  async get<R = Row>(sql: string, values: SqlValues = []): Promise<R | null> {
    return (this.db.query(sql).get(...(values as any[])) as R | null) ?? null;
  }
  async run(sql: string, values: SqlValues = []): Promise<{ rowCount: number }> {
    return { rowCount: Number(this.db.query(sql).run(...(values as any[])).changes) };
  }
}

function parseArguments(argv: string[]): { dbPath: string } {
  const index = argv.indexOf("--db");
  if (index === -1 || !argv[index + 1]) {
    console.error("usage: bun scripts/verify-report-parity.ts --db <path-to-sqlite>");
    process.exit(2);
  }
  return { dbPath: argv[index + 1]! };
}

/** Count the leaf values that differ between two report payloads. */
function countMismatches(expected: unknown, actual: unknown): number {
  if (JSON.stringify(expected) === JSON.stringify(actual)) return 0;
  if (Array.isArray(expected) && Array.isArray(actual)) {
    let total = Math.abs(expected.length - actual.length);
    for (let index = 0; index < Math.min(expected.length, actual.length); index++) {
      total += countMismatches(expected[index], actual[index]);
    }
    return total;
  }
  if (expected && actual && typeof expected === "object" && typeof actual === "object") {
    const keys = new Set([...Object.keys(expected), ...Object.keys(actual)]);
    let total = 0;
    for (const key of keys) total += countMismatches((expected as Row)[key], (actual as Row)[key]);
    return total;
  }
  return 1;
}

const { dbPath } = parseArguments(Bun.argv);
const db = new Database(dbPath, { readonly: true, strict: true });
const legacy = new ReportService(db);
const modern = new AsyncReportService(new LocalAsyncDatabase(db));

const plans = db.query("SELECT id FROM plans ORDER BY id").all() as Row[];
const summary: Row[] = [];

for (const plan of plans) {
  const planId = String(plan.id);
  const accounts = Number((db.query("SELECT COUNT(*) AS n FROM accounts WHERE plan_id=? AND deleted=0").get(planId) as Row).n);
  const aggregateRows = Number(
    (db.query("SELECT COUNT(*) AS n FROM account_month_balances WHERE plan_id=?").get(planId) as Row).n,
  );
  const ledgerRows = Number(
    (db.query("SELECT COUNT(*) AS n FROM transactions WHERE plan_id=? AND deleted=0").get(planId) as Row).n,
  );

  // Aggregate drift: what the triggers hold versus a rebuild from history.
  const drift = Number(
    (db
      .query(
        `WITH held AS (
           SELECT plan_id, account_id, month, net_change_milli FROM account_month_balances
           WHERE plan_id = ?
         ), fresh AS (
           SELECT plan_id, account_id, substr(date,1,7) AS month, SUM(amount_milli) AS net_change_milli
           FROM transactions WHERE plan_id = ? AND deleted = 0
           GROUP BY plan_id, account_id, substr(date,1,7)
           HAVING SUM(amount_milli) <> 0
         )
         SELECT (SELECT COUNT(*) FROM (SELECT * FROM held EXCEPT SELECT * FROM fresh))
              + (SELECT COUNT(*) FROM (SELECT * FROM fresh EXCEPT SELECT * FROM held)) AS n`,
      )
      .get(planId, planId) as Row).n,
  );

  let months = 0;
  let mismatches = 0;
  for (const filters of [{}, { includeClosedAccounts: true }, { interval: "year" }] as const) {
    const expected = legacy.netWorth(planId, filters);
    const actual = await modern.netWorth(planId, filters);
    months += expected.periods.length;
    mismatches += countMismatches(expected, actual);
  }
  const expectedAge = legacy.ageOfMoney(planId, {});
  const actualAge = await modern.ageOfMoney(planId, {});
  const ageMismatches = countMismatches(expectedAge, actualAge);

  summary.push({
    plan_index: summary.length,
    accounts,
    ledger_rows: ledgerRows,
    aggregate_rows: aggregateRows,
    aggregate_drift_rows: drift,
    net_worth_periods_compared: months,
    net_worth_mismatches: mismatches,
    age_of_money_periods_compared: expectedAge.periods.length,
    age_of_money_mismatches: ageMismatches,
  });
}

console.log(JSON.stringify({ event: "report_parity", plans: plans.length, summary }, null, 2));

const failed = summary.some(
  (row) => row.net_worth_mismatches > 0 || row.age_of_money_mismatches > 0 || row.aggregate_drift_rows > 0,
);
db.close();
process.exit(failed ? 1 : 0);
