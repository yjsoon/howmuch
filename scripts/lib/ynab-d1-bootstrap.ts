import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { mkdirSync } from "node:fs";

const COPY_TABLES = ["plans", "category_groups", "categories", "payees", "accounts", "import_sessions", "transactions", "subtransactions", "source_events", "import_rows", "ynab_raw_objects"] as const;
const EMPTY_TABLES = ["plans","category_groups","categories","payees","accounts","transactions","subtransactions","source_events","import_sessions","import_rows","ynab_raw_objects","plan_month_assignments","plan_month_category_targets","scheduled_transaction_edits","scheduled_subtransaction_edits","scheduled_transaction_snapshot_assertions","account_reconciliation_assertions","ynab_sync_state","sync_runs","sync_attempts","sync_transition_receipts","sync_renewal_receipts","audit_events","write_commands","write_assertions","users","auth_identities","sessions","personal_api_tokens","plan_memberships","password_credentials","auth_setup","login_rate_limits"];
const SOURCE_AUTH_TABLES = ["users", "auth_identities", "sessions", "personal_api_tokens", "plan_memberships", "password_credentials", "auth_setup", "login_rate_limits"];
// `wrangler d1 execute --file` is checkpointed through a Durable Object.
// Small statements keep each checkpoint well below its CPU budget even for
// wide transaction and raw-object rows; individual oversized rows still fail
// before a partial import file is written.
const MAX_STATEMENT_BYTES = 8 * 1024;
const MAX_IMPORT_BYTES = 5 * 1024 * 1024 * 1024;
const MAX_CHUNK_DATA_STATEMENTS = 400;
const MAX_CHUNK_BYTES = 2 * 1024 * 1024;
type Row = Record<string, string | number | null>;
type DataStatement = { sql: string; counts: Record<string, number> };

export type BootstrapManifest = {
  sha256: string; plan_id: string; import_session_id: string; server_knowledge: number;
  counts: Record<string, { active: number; deleted: number }>; sql_bytes: number;
};

export type BootstrapChunkManifest = BootstrapManifest & {
  format: "howmuch-d1-bootstrap-chunks-v1";
  chunks: Array<{
    file: string;
    sha256: string;
    statement_count: number;
    byte_count: number;
    checkpoint_counts: Record<string, number>;
    expected_cumulative_counts: Record<string, number>;
  }>;
  logical_data: {
    sha256: string;
    statement_count: number;
    byte_count: number;
    expected_cumulative_counts: Record<string, number>;
  };
};

export function generateYnabD1Bootstrap(inputPath: string, outputPath: string): BootstrapManifest {
  return generateBootstrap(inputPath, outputPath, "single") as BootstrapManifest;
}

/** Writes ordered, checkpointed SQL files that can be executed sequentially. */
export function generateYnabD1BootstrapChunks(inputPath: string, outputDirectory: string): BootstrapChunkManifest {
  return generateBootstrap(inputPath, outputDirectory, "chunks") as BootstrapChunkManifest;
}

function generateBootstrap(inputPath: string, outputPath: string, mode: "single" | "chunks"): BootstrapManifest | BootstrapChunkManifest {
  if (resolve(inputPath) === resolve(outputPath)) throw new Error("Input and output paths must differ");
  if (mode === "single" && (existsSync(outputPath) || existsSync(`${outputPath}.manifest.json`))) {
    throw new Error("Output SQL and manifest paths must not already exist");
  }
  if (mode === "chunks" && existsSync(outputPath)) {
    throw new Error("Output chunk directory must not already exist");
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
    // Assignments are a mutable HowMuch-local overlay, not YNAB provenance.
    // A clean initial migration must never transfer them implicitly.
    if (scalar(source, "SELECT count(*) n FROM plan_month_assignments") !== 0) {
      throw new Error("Source must not contain local plan month assignments");
    }
    if (scalar(source, "SELECT count(*) n FROM plan_month_category_targets") !== 0) {
      throw new Error("Source must not contain local plan month category targets");
    }
    // Reconciliation changes normalised cleared states, but this initial
    // bootstrap intentionally does not copy its audit/assertion receipts.
    // Refuse such a source rather than silently preserving balances while
    // dropping the reconciliation provenance and idempotency history.
    if (scalar(source, "SELECT count(*) n FROM account_reconciliation_assertions") !== 0
      || scalar(source, "SELECT count(*) n FROM audit_events WHERE action='account.reconcile'") !== 0) {
      throw new Error("Source must not contain account reconciliation history");
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
    const rawObjectCount = scalar(source, "SELECT count(*) n FROM ynab_raw_objects WHERE plan_id=?", [plan.id]);
    if (!rawObjectCount || scalar(source, "SELECT count(*) n FROM ynab_raw_objects WHERE plan_id=? AND object_type='plan'", [plan.id]) !== 1) {
      throw new Error("Source must contain a lossless YNAB raw-object mirror including its plan");
    }
    if (scalar(source, "SELECT count(*) n FROM ynab_raw_objects WHERE plan_id=? AND object_type='transaction'", [plan.id]) !== transactionCount) {
      throw new Error("YNAB raw transaction mirror count does not match the ledger");
    }
    if (summary.raw_objects != null) {
      if (typeof summary.raw_objects !== "object" || Array.isArray(summary.raw_objects)) throw new Error("Import raw-object summary is invalid");
      for (const [type, expected] of Object.entries(summary.raw_objects)) {
        if (!Number.isSafeInteger(expected) || expected < 0 || scalar(source, "SELECT count(*) n FROM ynab_raw_objects WHERE plan_id=? AND object_type=?", [plan.id, type]) !== expected) {
          throw new Error("Import raw-object summary does not match the mirror");
        }
      }
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

    const dataStatements: DataStatement[] = [];
    for (const table of COPY_TABLES) dataStatements.push(...inserts(table, copyColumns(source, table), rows.get(table)!));
    dataStatements.push(...inserts("ynab_sync_state", ["plan_id","server_knowledge","lease_id","lease_until","updated_at"], [{ plan_id: plan.id, server_knowledge: cursor, lease_id: null, lease_until: null, updated_at: plan.updated_at }]));
    dataStatements.push({
      sql: `UPDATE accounts SET balance_milli=opening_balance_milli+COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0),0), cleared_balance_milli=opening_balance_milli+COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0 AND cleared IN ('cleared','reconciled')),0), uncleared_balance_milli=COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0 AND cleared='uncleared'),0);`,
      counts: {},
    });
    const guard = checkpointGuard(emptyCounts());
    const statements = [...guard, ...dataStatements.map((statement) => statement.sql)];
    const sql = statements.join("\n") + "\n";
    if (Buffer.byteLength(sql) > MAX_IMPORT_BYTES) throw new Error("Generated SQL exceeds Cloudflare D1's 5 GiB import limit");
    validateGenerated(source, sql, rows, String(plan.id), cursor);
    const manifest: BootstrapManifest = { sha256: createHash("sha256").update(sql).digest("hex"), plan_id: String(plan.id), import_session_id: String(session.id), server_knowledge: cursor, counts: {}, sql_bytes: Buffer.byteLength(sql) };
    for (const table of COPY_TABLES) {
      const rs = rows.get(table)!; manifest.counts[table] = { active: rs.filter(r => !("deleted" in r) || r.deleted === 0).length, deleted: rs.filter(r => r.deleted === 1).length };
    }
    if (mode === "single") {
      mkdirSync(dirname(outputPath), { recursive: true });
      writeFileSync(outputPath, sql, { flag: "wx" });
      writeFileSync(`${outputPath}.manifest.json`, JSON.stringify(manifest, null, 2) + "\n", { flag: "wx" });
      return manifest;
    }

    const chunks = chunkStatements(dataStatements);
    validateChunked(source, chunks.map((chunk) => chunk.statements), rows, String(plan.id), cursor);
    const chunkManifest: BootstrapChunkManifest = {
      ...manifest,
      format: "howmuch-d1-bootstrap-chunks-v1",
      chunks: chunks.map((chunk, index) => ({
        file: chunkFileName(index),
        sha256: createHash("sha256").update(chunk.sql).digest("hex"),
        statement_count: chunk.dataStatements.length,
        byte_count: Buffer.byteLength(chunk.sql),
        checkpoint_counts: chunk.checkpointCounts,
        expected_cumulative_counts: chunk.expectedCounts,
      })),
      logical_data: {
        sha256: createHash("sha256").update(dataStatements.map((statement) => statement.sql).join("\n") + "\n").digest("hex"),
        statement_count: dataStatements.length,
        byte_count: Buffer.byteLength(dataStatements.map((statement) => statement.sql).join("\n") + "\n"),
        expected_cumulative_counts: chunks.at(-1)?.expectedCounts ?? emptyCounts(),
      },
    };
    mkdirSync(outputPath, { recursive: false });
    for (let index = 0; index < chunks.length; index++) {
      writeFileSync(resolve(outputPath, chunkFileName(index)), chunks[index].sql, { flag: "wx" });
    }
    writeFileSync(resolve(outputPath, "manifest.json"), JSON.stringify(chunkManifest, null, 2) + "\n", { flag: "wx" });
    return chunkManifest;
  } finally { source.close(); }
}

function validateGenerated(source: Database, sql: string, expected: Map<string, Row[]>, planId: string, cursor: number) {
  validateStatementGroups(source, [[sql]], expected, planId, cursor);
}

function validateChunked(source: Database, statementGroups: string[][], expected: Map<string, Row[]>, planId: string, cursor: number) {
  validateStatementGroups(source, statementGroups, expected, planId, cursor);
}

function validateStatementGroups(source: Database, statementGroups: string[][], expected: Map<string, Row[]>, planId: string, cursor: number) {
  const db = new Database(":memory:");
  try {
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0001_initial.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0002_password_auth.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0003_allow_duplicate_payee_names.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0004_ynab_raw_objects.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0005_plan_month_assignments.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0006_plan_month_category_targets.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0007_scheduled_transaction_edits.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0008_scheduled_transaction_snapshot_assertions.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0009_account_reconciliation_assertions.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0010_unique_live_import_id.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0011_personal_api_tokens.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0012_account_preferences.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0013_account_icons.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0014_account_icon_emoji_backfill.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0015_rewards_tracker.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0016_query_covering_indexes.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0017_ynab_source_month_activity.sql", import.meta.url), "utf8"));
    db.exec(readFileSync(new URL("../../apps/api/d1-migrations/0019_own_imported_ynab_schedules.sql", import.meta.url), "utf8"));
    for (const statements of statementGroups) db.exec(statements.join("\n"));
    if ((db.query("PRAGMA foreign_key_check").all() as any[]).length) throw new Error("Generated database has foreign-key violations");
    for (const table of COPY_TABLES) {
      const cols = columns(db, table); const actual = db.query(`SELECT ${cols.join(",")} FROM ${table} ORDER BY rowid`).all();
      const wanted = expected.get(table)!.map(r => Object.fromEntries(cols.map(c => [c, r[c]])));
      if (hash(actual) !== hash(wanted)) throw new Error(`Generated ${table} parity validation failed`);
    }
    checkZero(db, "SELECT count(*) n FROM transactions t LEFT JOIN accounts a ON a.id=t.account_id LEFT JOIN payees p ON p.id=t.payee_id LEFT JOIN categories c ON c.id=t.category_id WHERE a.plan_id<>t.plan_id OR (p.id IS NOT NULL AND p.plan_id<>t.plan_id) OR (c.id IS NOT NULL AND c.plan_id<>t.plan_id)", "transaction ownership");
    checkZero(db, "SELECT count(*) n FROM categories c JOIN category_groups g ON g.id=c.category_group_id WHERE c.plan_id<>g.plan_id", "category ownership");
    checkZero(db, "SELECT count(*) n FROM ynab_raw_objects r WHERE r.plan_id<>? OR r.object_type='' OR r.object_id='' OR json_valid(r.payload_json)=0", "YNAB raw-object ownership", [planId]);
    checkZero(db, "SELECT count(*) n FROM accounts a WHERE a.deleted=0 AND (a.transfer_payee_id IS NULL OR NOT EXISTS(SELECT 1 FROM payees p WHERE p.id=a.transfer_payee_id AND p.transfer_account_id=a.id AND p.plan_id=a.plan_id AND p.deleted=0))", "account transfer payees");
    checkZero(db, "SELECT count(*) n FROM subtransactions s JOIN transactions t ON t.id=s.transaction_id LEFT JOIN payees p ON p.id=s.payee_id LEFT JOIN categories c ON c.id=s.category_id LEFT JOIN accounts a ON a.id=s.transfer_account_id WHERE (p.id IS NOT NULL AND p.plan_id<>t.plan_id) OR (c.id IS NOT NULL AND c.plan_id<>t.plan_id) OR (a.id IS NOT NULL AND a.plan_id<>t.plan_id)", "subtransaction ownership");
    checkZero(db, "SELECT count(*) n FROM transactions WHERE ledger_sequence IS NULL OR ledger_sequence<1", "transaction sequence");
    checkZero(db, "SELECT count(*) n FROM subtransactions WHERE ledger_sequence IS NULL OR ledger_sequence<1", "subtransaction sequence");
    for (const table of ["transactions","subtransactions"]) if (scalar(db, `SELECT count(*) n FROM ${table}`) !== scalar(db, `SELECT count(DISTINCT ledger_sequence) n FROM ${table}`) || scalar(db, `SELECT coalesce(max(ledger_sequence),0) n FROM ${table}`) !== scalar(db, `SELECT count(*) n FROM ${table}`)) throw new Error(`${table} sequences are not contiguous`);
    // YNAB can retain a transfer account after the reciprocal transaction is
    // unavailable. Preserve that source-authenticated one-sided shape, but
    // never accept the unsafe inverse or a locally invented account link.
    checkZero(db, "SELECT count(*) n FROM transactions WHERE transfer_account_id IS NULL AND transfer_transaction_id IS NOT NULL", "transaction transfer field pairing");
    checkZero(db, "SELECT count(*) n FROM subtransactions WHERE transfer_account_id IS NULL AND transfer_transaction_id IS NOT NULL", "split transfer field pairing");
    checkZero(db, `SELECT count(*) n FROM transactions t
      WHERE t.transfer_account_id IS NOT NULL AND t.transfer_transaction_id IS NULL AND NOT (
        EXISTS (SELECT 1 FROM accounts a WHERE a.id=t.transfer_account_id AND a.plan_id=t.plan_id)
        AND EXISTS (
          SELECT 1 FROM ynab_raw_objects r
          WHERE r.plan_id=t.plan_id AND r.object_type='transaction' AND r.object_id=t.id
            AND json_valid(r.payload_json)=1
            AND json_extract(r.payload_json,'$.id') IS t.id
            AND json_extract(r.payload_json,'$.account_id') IS t.account_id
            AND json_extract(r.payload_json,'$.transfer_account_id') IS t.transfer_account_id
            AND json_extract(r.payload_json,'$.transfer_transaction_id') IS NULL
        )
      )`, "source-authenticated one-sided transaction transfer");
    checkZero(db, `SELECT count(*) n FROM subtransactions s
      JOIN transactions t ON t.id=s.transaction_id
      WHERE s.transfer_account_id IS NOT NULL AND s.transfer_transaction_id IS NULL AND NOT (
        EXISTS (SELECT 1 FROM accounts a WHERE a.id=s.transfer_account_id AND a.plan_id=t.plan_id)
        AND EXISTS (
          SELECT 1 FROM ynab_raw_objects r
          WHERE r.plan_id=t.plan_id AND r.object_type='subtransaction'
            AND r.object_id=t.id||char(31)||s.id
            AND json_valid(r.payload_json)=1
            AND json_extract(r.payload_json,'$.id') IS s.id
            AND json_extract(r.payload_json,'$.transaction_id') IS s.transaction_id
            AND json_extract(r.payload_json,'$.transfer_account_id') IS s.transfer_account_id
            AND json_extract(r.payload_json,'$.transfer_transaction_id') IS NULL
        )
      )`, "source-authenticated one-sided split transfer");
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
function inserts(table: string, cols: string[], rows: Row[]): DataStatement[] {
  const result: DataStatement[] = []; let values: string[] = [];
  for (const row of rows) {
    const value = `(${cols.map(c => literal(row[c])).join(",")})`;
    const prefix = `INSERT INTO ${table} (${cols.join(",")}) VALUES `;
    if (Buffer.byteLength(prefix + value + ";") > MAX_STATEMENT_BYTES) {
      throw new Error(`A single ${table} row exceeds the safe D1 statement size`);
    }
    if (values.length && Buffer.byteLength(prefix + values.join(",") + "," + value + ";") > MAX_STATEMENT_BYTES) {
      result.push({ sql: prefix + values.join(",") + ";", counts: { [table]: values.length } });
      values = [];
    }
    values.push(value);
  }
  if (values.length) result.push({ sql: `INSERT INTO ${table} (${cols.join(",")}) VALUES ${values.join(",")};`, counts: { [table]: values.length } });
  return result;
}

type BootstrapChunk = {
  sql: string;
  statements: string[];
  dataStatements: DataStatement[];
  checkpointCounts: Record<string, number>;
  expectedCounts: Record<string, number>;
};

function chunkStatements(dataStatements: DataStatement[]): BootstrapChunk[] {
  const chunks: BootstrapChunk[] = [];
  const cumulative = emptyCounts();
  let index = 0;
  while (index < dataStatements.length) {
    const expectedBefore = { ...cumulative };
    const guard = checkpointGuard(expectedBefore);
    const selected: DataStatement[] = [];
    let bytes = guard.reduce((total, statement) => total + Buffer.byteLength(statement) + 1, 0);
    while (index < dataStatements.length && selected.length < MAX_CHUNK_DATA_STATEMENTS) {
      const candidate = dataStatements[index];
      const candidateBytes = Buffer.byteLength(candidate.sql) + 1;
      if (selected.length > 0 && bytes + candidateBytes > MAX_CHUNK_BYTES) break;
      selected.push(candidate);
      bytes += candidateBytes;
      for (const [table, count] of Object.entries(candidate.counts)) cumulative[table] = (cumulative[table] ?? 0) + count;
      index += 1;
    }
    if (selected.length === 0) throw new Error("A bootstrap chunk exceeds the safe D1 chunk size");
    const statements = [...guard, ...selected.map((statement) => statement.sql)];
    const sql = statements.join("\n") + "\n";
    if (Buffer.byteLength(sql) > MAX_CHUNK_BYTES) throw new Error("A bootstrap chunk exceeds the safe D1 chunk size");
    chunks.push({ sql, statements, dataStatements: selected, checkpointCounts: expectedBefore, expectedCounts: { ...cumulative } });
  }
  return chunks;
}

function chunkFileName(index: number): string {
  return `chunk-${String(index + 1).padStart(4, "0")}.sql`;
}

function emptyCounts(): Record<string, number> {
  return Object.fromEntries([...COPY_TABLES, "ynab_sync_state"].map((table) => [table, 0]));
}

/**
 * A clean target makes this a no-op. Any mismatched checkpoint emits two
 * identical singleton rows in one statement; the second row violates the
 * existing primary key, so the file fails before its data statements run.
 */
function checkpointGuard(expectedCounts: Record<string, number>): string[] {
  const mismatches = [
    ...EMPTY_TABLES.map((table) => `(SELECT count(*) FROM ${table})<>${expectedCounts[table] ?? 0}`),
    "NOT EXISTS(SELECT 1 FROM write_state WHERE singleton=1 AND write_version=0 AND last_command_id IS NULL)",
    "(SELECT count(*) FROM write_state)<>1",
  ].join(" OR ");
  return [`INSERT INTO write_state(singleton,write_version) SELECT 1,0 WHERE ${mismatches} UNION ALL SELECT 1,0 WHERE ${mismatches};`];
}
function literal(value: unknown): string { if (value === null) return "NULL"; if (typeof value === "number") { if (!Number.isSafeInteger(value)) throw new Error("Unsafe integer in source"); return String(value); } if (typeof value !== "string" || value.includes("\0")) throw new Error("Unsupported or NUL-containing source value"); return `'${value.replaceAll("'", "''")}'`; }
function validateScalars(row: Row, table: string) { for (const [key, value] of Object.entries(row)) { if (typeof value === "number" && !Number.isSafeInteger(value)) throw new Error(`Unsafe integer in ${table}.${key}`); if (typeof value === "string" && value.includes("\0")) throw new Error(`NUL text in ${table}.${key}`); } }
function scalar(db: Database, sql: string, params: any[] = []): number { return Number((db.query(sql).get(...params) as any)?.n ?? 0); }
function positiveSafe(v: unknown): v is number { return typeof v === "number" && Number.isSafeInteger(v) && v > 0; }
function hash(value: unknown): string { return createHash("sha256").update(JSON.stringify(value)).digest("hex"); }
function checkZero(db: Database, sql: string, label: string, params: any[] = []) { if (scalar(db, sql, params)) throw new Error(`Generated database failed ${label} validation`); }
