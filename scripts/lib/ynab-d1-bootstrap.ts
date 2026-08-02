import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { mkdirSync } from "node:fs";

const COPY_TABLES = ["plans", "category_groups", "categories", "payees", "accounts", "import_sessions", "transactions", "subtransactions"] as const;
const EMPTY_TABLES = ["plans","category_groups","categories","payees","accounts","transactions","subtransactions","source_events","import_sessions","import_rows","ynab_sync_state","sync_runs","sync_attempts","sync_transition_receipts","sync_renewal_receipts","audit_events","write_commands","write_assertions","users","auth_identities","sessions","plan_memberships","password_credentials","auth_setup","login_rate_limits"];
const SOURCE_AUTH_TABLES = ["users", "auth_identities", "sessions", "plan_memberships", "password_credentials", "auth_setup", "login_rate_limits"];
const MAX_STATEMENT_BYTES = 80_000;
const MAX_IMPORT_BYTES = 5 * 1024 * 1024 * 1024;
type Row = Record<string, string | number | null>;

export type BootstrapManifest = {
  sha256: string; plan_id: string; import_session_id: string; server_knowledge: number;
  counts: Record<string, { active: number; deleted: number }>; sql_bytes: number;
};

export function generateYnabD1Bootstrap(inputPath: string, outputPath: string): BootstrapManifest {
  if (resolve(inputPath) === resolve(outputPath)) throw new Error("Input and output paths must differ");
  if (existsSync(outputPath) || existsSync(`${outputPath}.manifest.json`)) {
    throw new Error("Output SQL and manifest paths must not already exist");
  }
  const source = new Database(inputPath, { readonly: true, strict: true });
  try {
    if ((source.query("PRAGMA foreign_key_check").all() as unknown[]).length !== 0) {
      throw new Error("Source database has foreign-key violations");
    }
    for (const table of SOURCE_AUTH_TABLES) {
      if (scalar(source, `SELECT count(*) n FROM ${table}`) !== 0) {
        throw new Error("Source must not contain authentication or setup data");
      }
    }
    const planCount = scalar(source, "SELECT count(*) n FROM plans");
    const sessionCount = scalar(source, "SELECT count(*) n FROM import_sessions");
    if (planCount !== 1 || sessionCount !== 1) throw new Error("Source must contain exactly one plan and one import session");
    const plan = source.query("SELECT * FROM plans").get() as Row;
    const session = source.query("SELECT * FROM import_sessions").get() as Row;
    if (session.plan_id !== plan.id || session.source !== "ynab-api" || session.status !== "completed" || session.finished_at == null)
      throw new Error("Import session must be a finished ynab-api completed session for the only plan");
    let summary: any;
    try { summary = JSON.parse(String(session.summary_json)); } catch { throw new Error("Import summary is not valid JSON"); }
    const cursor = summary.server_knowledge;
    const transactionCount = scalar(source, "SELECT count(*) n FROM transactions");
    if (!positiveSafe(cursor) || !Number.isSafeInteger(summary.imported_transactions) || summary.imported_transactions !== transactionCount)
      throw new Error("Import summary transaction count/cursor does not match the ledger");
    const rowStats = source.query(`SELECT count(*) n, count(DISTINCT transaction_id) d FROM import_rows WHERE import_session_id=? AND status='imported' AND transaction_id IS NOT NULL`).get(session.id) as any;
    if (rowStats.n !== transactionCount || rowStats.d !== transactionCount || scalar(source, "SELECT count(*) n FROM import_rows") !== transactionCount)
      throw new Error("Successful import rows must map one-to-one to all transactions");
    const rowRange = source.query("SELECT min(row_index) minimum, max(row_index) maximum FROM import_rows WHERE import_session_id=?").get(session.id) as any;
    if (transactionCount > 0 && (rowRange.minimum !== 0 || rowRange.maximum !== transactionCount - 1)) {
      throw new Error("Import row indexes must be contiguous and zero-based");
    }
    const importedIds = source.query("SELECT transaction_id id FROM import_rows WHERE import_session_id=? ORDER BY row_index").all(session.id) as Array<{ id: string }>;
    const transactionIds = source.query("SELECT id FROM transactions ORDER BY rowid").all() as Array<{ id: string }>;
    if (hash(importedIds) !== hash(transactionIds)) {
      throw new Error("Import row order must match transaction insertion order");
    }
    const badSource = scalar(source, "SELECT count(*) n FROM transactions WHERE source_kind<>'ynab-import' OR source_ref IS NOT ?", [session.id]);
    if (badSource) throw new Error("Every transaction must reference the selected YNAB import session");
    const sourceEventCount = scalar(source, "SELECT count(*) n FROM source_events");
    const matchingSourceEvents = scalar(source, `SELECT count(*) n FROM transactions t
      WHERE EXISTS (
        SELECT 1 FROM source_events e
        WHERE e.transaction_id=t.id AND e.plan_id=t.plan_id
          AND e.source_kind='ynab-import' AND e.source_ref=?
      ) AND (SELECT count(*) FROM source_events e WHERE e.transaction_id=t.id)=1`, [session.id]);
    if (sourceEventCount !== transactionCount || matchingSourceEvents !== transactionCount) {
      throw new Error("Every transaction must have exactly one matching YNAB source event");
    }

    const rows = new Map<string, Row[]>();
    for (const table of COPY_TABLES) {
      const order = table === "transactions" || table === "subtransactions" ? "rowid" : "rowid";
      const tableRows = source.query(`SELECT * FROM ${table} ORDER BY ${order}`).all() as Row[];
      for (const row of tableRows) validateScalars(row, table);
      rows.set(table, tableRows);
    }
    (rows.get("transactions")!).forEach((r, i) => r.ledger_sequence = i + 1);
    (rows.get("subtransactions")!).forEach((r, i) => r.ledger_sequence = i + 1);

    const guard = `INSERT INTO write_state(singleton,write_version) SELECT 2,-1 WHERE ${EMPTY_TABLES.map(t => `EXISTS(SELECT 1 FROM ${t} LIMIT 1)`).join(" OR ")} OR NOT EXISTS(SELECT 1 FROM write_state WHERE singleton=1 AND write_version=0 AND last_command_id IS NULL) OR (SELECT count(*) FROM write_state)<>1;`;
    const statements = [guard];
    for (const table of COPY_TABLES) statements.push(...inserts(table, copyColumns(source, table), rows.get(table)!));
    statements.push(...inserts("ynab_sync_state", ["plan_id","server_knowledge","lease_id","lease_until","updated_at"], [{ plan_id: plan.id, server_knowledge: cursor, lease_id: null, lease_until: null, updated_at: plan.updated_at }]));
    statements.push(`UPDATE accounts SET balance_milli=opening_balance_milli+COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0),0), cleared_balance_milli=opening_balance_milli+COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0 AND cleared IN ('cleared','reconciled')),0), uncleared_balance_milli=COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0 AND cleared='uncleared'),0);`);
    const sql = statements.join("\n") + "\n";
    if (Buffer.byteLength(sql) > MAX_IMPORT_BYTES) throw new Error("Generated SQL exceeds Cloudflare D1's 5 GiB import limit");
    validateGenerated(source, sql, rows, String(plan.id), cursor);
    mkdirSync(dirname(outputPath), { recursive: true });
    writeFileSync(outputPath, sql, { flag: "wx" });
    const manifest: BootstrapManifest = { sha256: createHash("sha256").update(sql).digest("hex"), plan_id: String(plan.id), import_session_id: String(session.id), server_knowledge: cursor, counts: {}, sql_bytes: Buffer.byteLength(sql) };
    for (const table of COPY_TABLES) {
      const rs = rows.get(table)!; manifest.counts[table] = { active: rs.filter(r => !("deleted" in r) || r.deleted === 0).length, deleted: rs.filter(r => r.deleted === 1).length };
    }
    writeFileSync(`${outputPath}.manifest.json`, JSON.stringify(manifest, null, 2) + "\n", { flag: "wx" });
    return manifest;
  } finally { source.close(); }
}

function validateGenerated(source: Database, sql: string, expected: Map<string, Row[]>, planId: string, cursor: number) {
  const db = new Database(":memory:");
  try {
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0001_initial.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0002_password_auth.sql", import.meta.url), "utf8"));
    db.exec(sql);
    if ((db.query("PRAGMA foreign_key_check").all() as any[]).length) throw new Error("Generated database has foreign-key violations");
    for (const table of COPY_TABLES) {
      const cols = columns(db, table); const actual = db.query(`SELECT ${cols.join(",")} FROM ${table} ORDER BY rowid`).all();
      const wanted = expected.get(table)!.map(r => Object.fromEntries(cols.map(c => [c, r[c]])));
      if (hash(actual) !== hash(wanted)) throw new Error(`Generated ${table} parity validation failed`);
    }
    checkZero(db, "SELECT count(*) n FROM transactions t LEFT JOIN accounts a ON a.id=t.account_id LEFT JOIN payees p ON p.id=t.payee_id LEFT JOIN categories c ON c.id=t.category_id WHERE a.plan_id<>t.plan_id OR (p.id IS NOT NULL AND p.plan_id<>t.plan_id) OR (c.id IS NOT NULL AND c.plan_id<>t.plan_id)", "transaction ownership");
    checkZero(db, "SELECT count(*) n FROM categories c JOIN category_groups g ON g.id=c.category_group_id WHERE c.plan_id<>g.plan_id", "category ownership");
    checkZero(db, "SELECT count(*) n FROM accounts a WHERE a.deleted=0 AND (a.transfer_payee_id IS NULL OR NOT EXISTS(SELECT 1 FROM payees p WHERE p.id=a.transfer_payee_id AND p.transfer_account_id=a.id AND p.plan_id=a.plan_id AND p.deleted=0))", "account transfer payees");
    checkZero(db, "SELECT count(*) n FROM subtransactions s JOIN transactions t ON t.id=s.transaction_id LEFT JOIN payees p ON p.id=s.payee_id LEFT JOIN categories c ON c.id=s.category_id LEFT JOIN accounts a ON a.id=s.transfer_account_id WHERE (p.id IS NOT NULL AND p.plan_id<>t.plan_id) OR (c.id IS NOT NULL AND c.plan_id<>t.plan_id) OR (a.id IS NOT NULL AND a.plan_id<>t.plan_id)", "subtransaction ownership");
    checkZero(db, "SELECT count(*) n FROM transactions WHERE ledger_sequence IS NULL OR ledger_sequence<1", "transaction sequence");
    checkZero(db, "SELECT count(*) n FROM subtransactions WHERE ledger_sequence IS NULL OR ledger_sequence<1", "subtransaction sequence");
    for (const table of ["transactions","subtransactions"]) if (scalar(db, `SELECT count(*) n FROM ${table}`) !== scalar(db, `SELECT count(DISTINCT ledger_sequence) n FROM ${table}`) || scalar(db, `SELECT coalesce(max(ledger_sequence),0) n FROM ${table}`) !== scalar(db, `SELECT count(*) n FROM ${table}`)) throw new Error(`${table} sequences are not contiguous`);
    checkZero(db, "SELECT count(*) n FROM transactions WHERE (transfer_account_id IS NULL)<>(transfer_transaction_id IS NULL)", "transaction transfer field pairing");
    checkZero(db, "SELECT count(*) n FROM subtransactions WHERE (transfer_account_id IS NULL)<>(transfer_transaction_id IS NULL)", "split transfer field pairing");
    checkZero(db, `SELECT count(*) n FROM transactions t
      WHERE t.transfer_transaction_id IS NOT NULL AND NOT (
        EXISTS (
          SELECT 1 FROM transactions x
          WHERE x.id=t.transfer_transaction_id AND x.plan_id=t.plan_id
            AND x.transfer_transaction_id=t.id
            AND x.amount_milli=-t.amount_milli
            AND x.account_id=t.transfer_account_id
            AND x.transfer_account_id=t.account_id
        ) OR EXISTS (
          SELECT 1 FROM subtransactions s
          JOIN transactions p ON p.id=s.transaction_id
          WHERE s.id=t.transfer_transaction_id AND p.plan_id=t.plan_id
            AND s.transfer_transaction_id=t.id
            AND t.amount_milli=-s.amount_milli
            AND t.account_id=s.transfer_account_id
            AND t.transfer_account_id=p.account_id
        )
      )`, "transaction transfer graph");
    checkZero(db, `SELECT count(*) n FROM subtransactions s
      JOIN transactions p ON p.id=s.transaction_id
      WHERE s.transfer_transaction_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM transactions x
        WHERE x.id=s.transfer_transaction_id AND x.plan_id=p.plan_id
          AND x.transfer_transaction_id=s.id
          AND x.amount_milli=-s.amount_milli
          AND x.account_id=s.transfer_account_id
          AND x.transfer_account_id=p.account_id
      )`, "split transfer graph");
    checkZero(db, "SELECT count(*) n FROM transactions t WHERE EXISTS(SELECT 1 FROM subtransactions s WHERE s.transaction_id=t.id AND s.deleted=0) AND t.amount_milli<>(SELECT sum(amount_milli) FROM subtransactions s WHERE s.transaction_id=t.id AND s.deleted=0)", "split sums");
    checkZero(db, "SELECT count(*) n FROM transactions t WHERE t.category_id IS NOT NULL AND EXISTS(SELECT 1 FROM subtransactions s WHERE s.transaction_id=t.id AND s.deleted=0)", "split parent categories");
    checkZero(db, "SELECT count(*) n FROM accounts a WHERE balance_milli<>opening_balance_milli+COALESCE((SELECT sum(amount_milli) FROM transactions t WHERE t.account_id=a.id AND t.deleted=0),0) OR cleared_balance_milli<>opening_balance_milli+COALESCE((SELECT sum(amount_milli) FROM transactions t WHERE t.account_id=a.id AND t.deleted=0 AND t.cleared IN ('cleared','reconciled')),0) OR uncleared_balance_milli<>COALESCE((SELECT sum(amount_milli) FROM transactions t WHERE t.account_id=a.id AND t.deleted=0 AND t.cleared='uncleared'),0)", "balances");
    if (scalar(db, "SELECT server_knowledge n FROM plans") < scalar(db, "SELECT coalesce(max(server_knowledge),0) n FROM transactions")) throw new Error("Plan knowledge trails transaction knowledge");
    const sync = db.query("SELECT * FROM ynab_sync_state").get() as any;
    if (sync.plan_id !== planId || sync.server_knowledge !== cursor || sync.lease_id !== null || sync.lease_until !== null) throw new Error("Invalid sync cursor");
    if (scalar(db, "SELECT write_version n FROM write_state") !== 0 || scalar(db, "SELECT count(*) n FROM write_commands") || scalar(db, "SELECT count(*) n FROM write_assertions")) throw new Error("Bootstrap contaminated guarded-write state");
    // Exercise the canonical guarded-command state protocol after parity checks.
    db.exec(`INSERT INTO write_commands(id,expected_write_version,kind,plan_id,transaction_id,request_hash) VALUES('bootstrap-validation',0,'create','${planId.replaceAll("'","''")}','validation','validation'); UPDATE write_state SET write_version=1,last_command_id='bootstrap-validation' WHERE singleton=1; UPDATE write_commands SET status='applied',applied_at=CURRENT_TIMESTAMP WHERE id='bootstrap-validation';`);
    if (scalar(db, "SELECT write_version n FROM write_state") !== 1) throw new Error("Guarded command protocol validation failed");
  } finally { db.close(); }
}

function columns(db: Database, table: string): string[] { return (db.query(`PRAGMA table_info(${table})`).all() as any[]).map(r => r.name); }
function copyColumns(db: Database, table: string): string[] {
  const sourceColumns = columns(db, table);
  return table === "transactions" || table === "subtransactions"
    ? [...sourceColumns, "ledger_sequence"]
    : sourceColumns;
}
function inserts(table: string, cols: string[], rows: Row[]): string[] {
  const result: string[] = []; let values: string[] = [];
  for (const row of rows) {
    const value = `(${cols.map(c => literal(row[c])).join(",")})`;
    const prefix = `INSERT INTO ${table} (${cols.join(",")}) VALUES `;
    if (Buffer.byteLength(prefix + value + ";") > MAX_STATEMENT_BYTES) {
      throw new Error(`A single ${table} row exceeds the safe D1 statement size`);
    }
    if (values.length && Buffer.byteLength(prefix + values.join(",") + "," + value + ";") > MAX_STATEMENT_BYTES) { result.push(prefix + values.join(",") + ";"); values = []; }
    values.push(value);
  }
  if (values.length) result.push(`INSERT INTO ${table} (${cols.join(",")}) VALUES ${values.join(",")};`);
  return result;
}
function literal(value: unknown): string { if (value === null) return "NULL"; if (typeof value === "number") { if (!Number.isSafeInteger(value)) throw new Error("Unsafe integer in source"); return String(value); } if (typeof value !== "string" || value.includes("\0")) throw new Error("Unsupported or NUL-containing source value"); return `'${value.replaceAll("'", "''")}'`; }
function validateScalars(row: Row, table: string) { for (const [key, value] of Object.entries(row)) { if (typeof value === "number" && !Number.isSafeInteger(value)) throw new Error(`Unsafe integer in ${table}.${key}`); if (typeof value === "string" && value.includes("\0")) throw new Error(`NUL text in ${table}.${key}`); } }
function scalar(db: Database, sql: string, params: any[] = []): number { return Number((db.query(sql).get(...params) as any)?.n ?? 0); }
function positiveSafe(v: unknown): v is number { return typeof v === "number" && Number.isSafeInteger(v) && v > 0; }
function hash(value: unknown): string { return createHash("sha256").update(JSON.stringify(value)).digest("hex"); }
function checkZero(db: Database, sql: string, label: string) { if (scalar(db, sql)) throw new Error(`Generated database failed ${label} validation`); }
