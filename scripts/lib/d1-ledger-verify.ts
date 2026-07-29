import { Database } from "bun:sqlite";
import { IMPORT_TABLES, canonicalRow, logicalSourceHash, sqlIdentifier } from "./d1-ledger-import";
import { ReportService } from "../../apps/api/src/reports";
type Row = Record<string, unknown>;
export type Verification = { logical_source_sha256: string; tables: Record<string, { rows: number; sha256: string; columns: string[] }>; checks: Record<string, unknown>; report_hashes: Record<string, string>; migration_run?: { id: string; source_sha256: string; expected_chunk_count: number; actual_chunk_count: number; run_count: number; status: string } };
const hash = (value: unknown) => { const h = new Bun.CryptoHasher("sha256"); h.update(JSON.stringify(value)); return h.digest("hex"); };
const query = (db: Database, sql: string) => db.query(sql).all() as Row[];

/** Builds a bounded-memory, read-only reconciliation manifest. Destination
 * exports use the same function, so only columns common to both are compared. */
export function buildVerification(db: Database): Verification {
  const tables: Verification["tables"] = {};
  for (const table of IMPORT_TABLES) {
    if (!db.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(table)) continue;
    const columns = (db.query(`PRAGMA table_info(${sqlIdentifier(table)})`).all() as { name: string; pk: number }[]).filter(c => c.name !== "ledger_sequence").map(c => c.name);
    const pk = (db.query(`PRAGMA table_info(${sqlIdentifier(table)})`).all() as { name: string; pk: number }[]).filter(c=>c.pk).sort((a,b)=>a.pk-b.pk).map(c=>sqlIdentifier(c.name));
    const hasher = new Bun.CryptoHasher("sha256"); let rows = 0;
    for (const row of db.query(`SELECT ${columns.map(sqlIdentifier)} FROM ${sqlIdentifier(table)} ORDER BY ${pk.length ? pk.join(",") : "rowid"}`).iterate() as Iterable<Row>) { hasher.update(`${canonicalRow(row, columns)}\n`); rows++; }
    tables[table] = { rows, sha256: hasher.digest("hex"), columns };
  }
  const checks: Record<string, unknown> = {
    monetary_by_plan_account: query(db, `SELECT plan_id,account_id,COUNT(*) rows,COALESCE(SUM(amount_milli),0) amount_milli FROM transactions GROUP BY plan_id,account_id ORDER BY plan_id,account_id`),
    active_monetary_by_plan_account: query(db, `SELECT plan_id,account_id,COUNT(*) rows,COALESCE(SUM(amount_milli),0) amount_milli FROM transactions WHERE deleted=0 GROUP BY plan_id,account_id ORDER BY plan_id,account_id`),
    balance_mismatches: query(db, `SELECT a.id,a.balance_milli,a.cleared_balance_milli,a.uncleared_balance_milli,a.opening_balance_milli+COALESCE(SUM(CASE WHEN t.deleted=0 THEN t.amount_milli ELSE 0 END),0) derived_balance,a.opening_balance_milli+COALESCE(SUM(CASE WHEN t.deleted=0 AND t.cleared IN ('cleared','reconciled') THEN t.amount_milli ELSE 0 END),0) derived_cleared,COALESCE(SUM(CASE WHEN t.deleted=0 AND t.cleared='uncleared' THEN t.amount_milli ELSE 0 END),0) derived_uncleared FROM accounts a LEFT JOIN transactions t ON t.account_id=a.id GROUP BY a.id HAVING a.balance_milli<>derived_balance OR a.cleared_balance_milli<>derived_cleared OR a.uncleared_balance_milli<>derived_uncleared ORDER BY a.id`),
    split_sum_mismatches: query(db, `SELECT t.id,t.amount_milli,COALESCE(SUM(CASE WHEN s.deleted=0 THEN s.amount_milli ELSE 0 END),0) split_sum FROM transactions t JOIN subtransactions s ON s.transaction_id=t.id WHERE t.deleted=0 GROUP BY t.id HAVING t.amount_milli<>split_sum ORDER BY t.id`),
    transfer_mismatches: query(db, `SELECT t.id FROM transactions t LEFT JOIN transactions r ON r.id=t.transfer_transaction_id WHERE t.transfer_transaction_id IS NOT NULL AND (r.id IS NULL OR r.plan_id<>t.plan_id OR r.transfer_transaction_id<>t.id OR r.transfer_account_id<>t.account_id OR t.transfer_account_id<>r.account_id OR r.amount_milli<>-t.amount_milli OR r.deleted<>t.deleted) ORDER BY t.id`),
    transaction_orphans: query(db, `SELECT t.id FROM transactions t LEFT JOIN plans p ON p.id=t.plan_id LEFT JOIN accounts a ON a.id=t.account_id AND a.plan_id=t.plan_id LEFT JOIN payees py ON py.id=t.payee_id AND py.plan_id=t.plan_id LEFT JOIN categories c ON c.id=t.category_id AND c.plan_id=t.plan_id WHERE p.id IS NULL OR a.id IS NULL OR (t.payee_id IS NOT NULL AND py.id IS NULL) OR (t.category_id IS NOT NULL AND c.id IS NULL) ORDER BY t.id`),
    subtransaction_orphans: query(db, `SELECT s.id FROM subtransactions s LEFT JOIN transactions t ON t.id=s.transaction_id WHERE t.id IS NULL ORDER BY s.id`),
    server_knowledge_mismatches: hasColumn(db,"transactions","server_knowledge") ? query(db, `SELECT t.id,t.server_knowledge,p.server_knowledge plan_server_knowledge FROM transactions t JOIN plans p ON p.id=t.plan_id WHERE t.server_knowledge<1 OR t.server_knowledge>p.server_knowledge ORDER BY t.id`) : [],
    transaction_sequence_duplicates: hasColumn(db,"transactions","ledger_sequence") ? query(db, `SELECT ledger_sequence,COUNT(*) count FROM transactions GROUP BY ledger_sequence HAVING ledger_sequence IS NULL OR count<>1 ORDER BY ledger_sequence`) : [],
    subtransaction_sequence_duplicates: hasColumn(db,"subtransactions","ledger_sequence") ? query(db, `SELECT ledger_sequence,COUNT(*) count FROM subtransactions GROUP BY ledger_sequence HAVING ledger_sequence IS NULL OR count<>1 ORDER BY ledger_sequence`) : [],
    transaction_sequence_gaps: hasColumn(db,"transactions","ledger_sequence") ? query(db, `SELECT COUNT(*) count,MIN(ledger_sequence) minimum,MAX(ledger_sequence) maximum FROM transactions HAVING count>0 AND (minimum<>1 OR maximum<>count)`) : [],
    subtransaction_sequence_gaps: hasColumn(db,"subtransactions","ledger_sequence") ? query(db, `SELECT COUNT(*) count,MIN(ledger_sequence) minimum,MAX(ledger_sequence) maximum FROM subtransactions HAVING count>0 AND (minimum<>1 OR maximum<>count)`) : [],
  };
  const reports = new ReportService(db);
  const reportHashes: Record<string, string> = {};
  for (const plan of query(db, "SELECT id FROM plans WHERE deleted=0 ORDER BY id")) {
    const planId = String(plan.id);
    const bounds = db.query("SELECT MIN(date) first_date,MAX(date) last_date FROM transactions WHERE plan_id=? AND deleted=0").get(planId) as { first_date: string | null; last_date: string | null };
    if (!bounds.first_date || !bounds.last_date) continue;
    const filters = { from: bounds.first_date, to: bounds.last_date, interval: "month" as const };
    reportHashes[`${planId}:spending_breakdown`] = hash(reports.spendingBreakdown(planId, { ...filters, topPayeesLimit: 25 }));
    reportHashes[`${planId}:income_vs_spending`] = hash(reports.incomeVsSpending(planId, filters));
    reportHashes[`${planId}:net_worth`] = hash(reports.netWorth(planId, { ...filters, includeClosedAccounts: true }));
    reportHashes[`${planId}:age_of_money`] = hash(reports.ageOfMoney(planId, filters));
  }
  const migrationRun = db.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='migration_runs'").get()
    ? db.query(`SELECT mr.id,mr.source_sha256,mr.expected_chunk_count,COUNT(mc.chunk_number) actual_chunk_count,(SELECT COUNT(*) FROM migration_runs) run_count,mr.status FROM migration_runs mr LEFT JOIN migration_chunks mc ON mc.run_id=mr.id GROUP BY mr.id`).get() as Verification["migration_run"]
    : undefined;
  return { logical_source_sha256: logicalSourceHash(db), tables, checks, report_hashes: reportHashes, migration_run: migrationRun };
}
function hasColumn(db: Database, table: string, column: string) { return (db.query(`PRAGMA table_info(${sqlIdentifier(table)})`).all() as {name:string}[]).some(c=>c.name===column); }
export function compareVerification(source: Verification, target: Verification): string[] {
  const differences: string[] = [];
  if(source.logical_source_sha256!==target.logical_source_sha256) differences.push("logical source hash mismatch");
  for (const table of unionKeys(source.tables,target.tables)) { const a=source.tables[table],b=target.tables[table]; if(!a||!b||JSON.stringify(a.columns)!==JSON.stringify(b.columns)||a.rows!==b.rows||a.sha256!==b.sha256) differences.push(`table ${table} schema/count/hash mismatch`); }
  for (const key of unionKeys(source.checks,target.checks)) if(JSON.stringify(source.checks[key])!==JSON.stringify(target.checks[key])) differences.push(`check ${key} mismatch`);
  for (const key of unionKeys(source.report_hashes,target.report_hashes)) if(source.report_hashes[key]!==target.report_hashes[key]) differences.push(`filtered report ${key} hash mismatch`);
  const run=target.migration_run;
  if(!run||Number(run.run_count)!==1||run.status!=="complete"||run.source_sha256!==source.logical_source_sha256||Number(run.expected_chunk_count)!==Number(run.actual_chunk_count)) differences.push("destination migration provenance is incomplete or belongs to another source snapshot");
  return differences;
}
function unionKeys(first:Record<string,unknown>,second:Record<string,unknown>){return [...new Set([...Object.keys(first),...Object.keys(second)])].sort();}
