import { Database } from "bun:sqlite";

export const IMPORT_TABLES = ["plans", "payees", "accounts", "category_groups", "categories", "transactions", "subtransactions", "source_events", "import_sessions", "import_rows"] as const;
export type Checkpoint = { source_sha256: string; table_name: string; chunk_number: number; row_count: number; chunk_sha256: string; first_stable_key: string; last_stable_key: string };
export type MigrationRun = { id: string; source_sha256: string; source_bytes: number; expected_chunk_count: number; status: "running" | "complete" };
type Row = Record<string, unknown>;
type Column = { name: string; pk: number };

export function sqlIdentifier(value: string): string {
  if (!/^[a-z_][a-z0-9_]*$/i.test(value)) throw new Error(`Unsafe identifier: ${value}`);
  return `"${value}"`;
}
export function sqlLiteral(value: unknown): string {
  if (value === null || value === undefined) return "NULL";
  if (typeof value === "number" || typeof value === "bigint") {
    if (!Number.isFinite(Number(value))) throw new Error("Non-finite SQL number");
    return String(value);
  }
  if (value instanceof Uint8Array) return `X'${Buffer.from(value).toString("hex")}'`;
  return `'${String(value).replaceAll("'", "''")}'`;
}
export function canonicalRow(row: Row, columns: string[]): string {
  return JSON.stringify(columns.map((name) => canonicalValue(row[name])));
}
export function hashLines(lines: string[]): string {
  const h = new Bun.CryptoHasher("sha256");
  for (const line of lines) h.update(`${line}\n`);
  return h.digest("hex");
}
export function logicalSourceHash(db: Database): string {
  const hasher = new Bun.CryptoHasher("sha256");
  for (const table of IMPORT_TABLES) {
    if (!db.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(table)) {
      hasher.update(`missing:${table}\n`);
      continue;
    }
    const info = db.query(`PRAGMA table_info(${sqlIdentifier(table)})`).all() as Array<Column & { type: string; notnull: number; dflt_value: unknown }>;
    const columns = info.map((column) => column.name).filter((name) => name !== "ledger_sequence");
    const primary = info.filter((column) => column.pk).sort((a, b) => a.pk - b.pk).map((column) => column.name);
    const order = table === "transactions" || table === "subtransactions" ? "rowid" : (primary.length ? primary.map(sqlIdentifier).join(",") : "rowid");
    hasher.update(`table:${table}:${JSON.stringify(info.filter((column) => column.name !== "ledger_sequence").map((column) => [column.name, column.type, column.notnull, column.dflt_value, column.pk]))}\n`);
    for (const row of db.query(`SELECT ${columns.map(sqlIdentifier).join(",")} FROM ${sqlIdentifier(table)} ORDER BY ${order}`).iterate() as Iterable<Row>) {
      hasher.update(`${canonicalRow(row, columns)}\n`);
    }
  }
  return hasher.digest("hex");
}

function canonicalValue(value: unknown): string {
  if (value === null || value === undefined) return "null";
  if (typeof value === "bigint") return `integer:${value}`;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("Non-finite SQLite number");
    return `${Number.isInteger(value) ? "integer" : "real"}:${Object.is(value, -0) ? "-0" : String(value)}`;
  }
  if (typeof value === "string") return `text:${value}`;
  if (value instanceof Uint8Array) return `blob:${Buffer.from(value).toString("hex")}`;
  throw new Error(`Unsupported SQLite value: ${Object.prototype.toString.call(value)}`);
}
export function assertInactiveTarget(name?: string, id?: string, confirmation?: string): void {
  if (!name || !id) throw new Error("--database-name and --database-id are both required for --execute");
  if (!/^[0-9a-f]{8}-[0-9a-f-]{27,}$/i.test(id)) throw new Error("--database-id must be an explicit D1 UUID");
  if (!/inactive/i.test(name) || /^(howmuch|production|prod)$/i.test(name)) throw new Error("Target name must clearly contain INACTIVE and must not be a production-like name");
  const expected = `INACTIVE ${name} ${id}`;
  if (confirmation !== expected) throw new Error(`Confirmation must exactly equal: ${expected}`);
}
export function reconcileCheckpoints(generated: Checkpoint[], existing: Checkpoint[]): Set<string> {
  const wanted = new Map(generated.map((c) => [`${c.table_name}:${c.chunk_number}`, c]));
  const done = new Set<string>();
  for (const actual of existing) {
    const key = `${actual.table_name}:${actual.chunk_number}`;
    const expected = wanted.get(key);
    if (!expected || JSON.stringify(expected) !== JSON.stringify(actual)) throw new Error(`Checkpoint disagreement at ${key}`);
    done.add(key);
  }
  return done;
}

export function reconcileRun(expected: Omit<MigrationRun, "status">, existing: MigrationRun[]): MigrationRun | null {
  if (existing.length > 1) throw new Error("Inactive target contains multiple migration runs; use a clean D1 database");
  const actual = existing[0];
  if (!actual) return null;
  if (actual.id !== expected.id || actual.source_sha256 !== expected.source_sha256 || Number(actual.source_bytes) !== expected.source_bytes || Number(actual.expected_chunk_count) !== expected.expected_chunk_count) {
    throw new Error("Inactive target migration run belongs to different source bytes");
  }
  return { ...actual, source_bytes: Number(actual.source_bytes), expected_chunk_count: Number(actual.expected_chunk_count) };
}

export function generateChunks(db: Database, sourceSha: string, runId: string, options: { maxRows: number; maxBytes: number }, emit: (sql: string, checkpoint: Checkpoint) => void): Checkpoint[] {
  if (!Number.isSafeInteger(options.maxRows) || options.maxRows < 1) throw new Error("--max-rows must be a positive integer");
  if (!Number.isSafeInteger(options.maxBytes) || options.maxBytes < 1_000) throw new Error("--max-bytes must be an integer of at least 1000");
  if (options.maxBytes > 900_000) throw new Error("--max-bytes must not exceed the reviewed 900000-byte D1 request ceiling");
  const result: Checkpoint[] = [];
  for (const table of IMPORT_TABLES) {
    let sequence = 0;
    if (!db.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(table)) continue;
    const info = db.query(`PRAGMA table_info(${sqlIdentifier(table)})`).all() as Column[];
    const sourceColumns = info.map((c) => c.name).filter((name) => name !== "ledger_sequence");
    const columns = table === "transactions" || table === "subtransactions" ? [...sourceColumns, "ledger_sequence"] : sourceColumns;
    const primary = info.filter((c) => c.pk).sort((a, b) => a.pk - b.pk).map((c) => c.name);
    const stable = primary.length ? primary : ["rowid"];
    const query = `SELECT rowid AS __source_rowid, * FROM ${sqlIdentifier(table)} ORDER BY ${table === "transactions" || table === "subtransactions" ? "rowid" : stable.map(sqlIdentifier).join(",")}`;
    let rows: Row[] = [], lines: string[] = [], chunkNo = 0;
    const flush = () => {
      if (!rows.length) return;
      const keys = rows.map((r) => JSON.stringify(stable.map((k) => k === "rowid" ? r.__source_rowid : r[k])));
      const cp: Checkpoint = { source_sha256: sourceSha, table_name: table, chunk_number: chunkNo++, row_count: rows.length, chunk_sha256: hashLines(lines), first_stable_key: keys[0], last_stable_key: keys.at(-1)! };
      const insert = `INSERT INTO ${sqlIdentifier(table)} (${columns.map(sqlIdentifier).join(",")}) VALUES\n${rows.map((r) => `(${columns.map((c) => sqlLiteral(c === "ledger_sequence" ? ++sequence : r[c])).join(",")})`).join(",\n")};`;
      const receipt = `INSERT INTO migration_chunks (run_id,source_sha256,table_name,chunk_number,row_count,chunk_sha256,first_stable_key,last_stable_key) VALUES (${[runId, cp.source_sha256, cp.table_name, cp.chunk_number, cp.row_count, cp.chunk_sha256, cp.first_stable_key, cp.last_stable_key].map(sqlLiteral).join(",")});`;
      const sql = `${insert}\n${receipt}\n`;
      if (Buffer.byteLength(sql) > options.maxBytes) throw new Error(`${table} chunk exceeds --max-bytes; reduce --max-rows or increase --max-bytes`);
      // Wrangler sends every statement in one --file invocation as an atomic
      // D1 batch. Explicit SQL BEGIN/COMMIT is rejected by D1.
      emit(sql, cp); result.push(cp);
      rows = []; lines = [];
    };
    for (const row of db.query(query).iterate() as Iterable<Row>) {
      const line = canonicalRow(row, sourceColumns);
      const estimate = Buffer.byteLength(line) * 2 + 512;
      if (estimate > options.maxBytes) throw new Error(`${table} row exceeds --max-bytes`);
      if (rows.length && (rows.length >= options.maxRows || Buffer.byteLength(lines.join("\n")) + estimate > options.maxBytes)) flush();
      rows.push(row); lines.push(line);
    }
    flush();
  }
  return result;
}
