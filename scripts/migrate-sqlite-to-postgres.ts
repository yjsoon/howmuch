import { Database } from "bun:sqlite";
import { Client, type QueryResultRow } from "pg";
import { resolve } from "node:path";

const TABLES = [
  "plans",
  "accounts",
  "category_groups",
  "categories",
  "payees",
  "transactions",
  "subtransactions",
  "source_events",
  "import_sessions",
  "import_rows",
] as const;
const BATCH_SIZE = 250;

type Row = Record<string, unknown>;
type Column = { name: string; type: string; pk: number };

const options = parseArgs(Bun.argv.slice(2));
const connectionString = Bun.env.DATABASE_URL?.trim();
if (!connectionString) throw new Error("DATABASE_URL is required; it is never accepted as a command-line argument");

const sqlite = new Database(resolve(options.sqlitePath), { readonly: true, strict: true });
const postgres = new Client({ connectionString });
await postgres.connect();

try {
  await assertTargetSchema();
  if (!options.verifyOnly) await assertSafeTarget();

  const results: Record<string, { rows: number; source_sha256: string; target_sha256: string; matches: boolean }> = {};
  for (const table of TABLES) {
    if (!sqliteTableExists(table)) continue;
    const columns = sqlite.query(`PRAGMA table_info(${quoteIdentifier(table)})`).all() as Column[];
    const sourceRows = sqlite
      .query(`SELECT * FROM ${quoteIdentifier(table)} ORDER BY ${orderBy(columns)}`)
      .all() as Row[];

    if (!options.verifyOnly) {
      await postgres.query("BEGIN");
      try {
        const insertionRows = table === "transactions" || table === "subtransactions"
          ? (sqlite.query(`SELECT * FROM ${quoteIdentifier(table)} ORDER BY rowid`).all() as Row[])
          : sourceRows;
        for (let offset = 0; offset < insertionRows.length; offset += BATCH_SIZE) {
          await insertBatch(table, columns, insertionRows.slice(offset, offset + BATCH_SIZE));
        }
        await postgres.query("COMMIT");
      } catch (error) {
        await postgres.query("ROLLBACK");
        throw error;
      }
    }

    const selectedColumns = columns.map((column) => quoteIdentifier(column.name)).join(", ");
    const targetRows = (
      await postgres.query(`SELECT ${selectedColumns} FROM ${quoteIdentifier(table)} ORDER BY ${orderBy(columns)}`)
    ).rows as Row[];
    const sourceHash = hashRows(sourceRows, columns);
    const targetHash = hashRows(targetRows, columns);
    const matches = sourceRows.length === targetRows.length && sourceHash === targetHash;
    results[table] = {
      rows: sourceRows.length,
      source_sha256: sourceHash,
      target_sha256: targetHash,
      matches,
    };
    console.error(`${matches ? "ok" : "MISMATCH"} ${table}: ${sourceRows.length} rows`);
  }

  const mismatches = Object.entries(results).filter(([, result]) => !result.matches);
  console.log(JSON.stringify({ source: resolve(options.sqlitePath), tables: results, matches: mismatches.length === 0 }, null, 2));
  if (mismatches.length > 0) process.exitCode = 1;
} finally {
  sqlite.close();
  await postgres.end();
}

async function assertTargetSchema(): Promise<void> {
  const expected = new Set(TABLES);
  const existing = await postgres.query<{ table_name: string }>(
    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'",
  );
  for (const row of existing.rows) expected.delete(row.table_name as (typeof TABLES)[number]);
  if (expected.size > 0) {
    throw new Error(`Postgres schema is not migrated; missing tables: ${[...expected].join(", ")}`);
  }
}

async function assertSafeTarget(): Promise<void> {
  if (options.resume) return;
  for (const table of TABLES) {
    const result = await postgres.query(`SELECT 1 FROM ${quoteIdentifier(table)} LIMIT 1`);
    if (result.rowCount) {
      throw new Error(`Target table ${table} is not empty; use a fresh Neon branch or pass --resume after an interrupted copy`);
    }
  }
}

async function insertBatch(table: string, columns: Column[], rows: Row[]): Promise<void> {
  if (rows.length === 0) return;
  const values: unknown[] = [];
  const tuples = rows.map((row) => {
    const placeholders = columns.map((column) => {
      values.push(row[column.name]);
      return `$${values.length}`;
    });
    return `(${placeholders.join(", ")})`;
  });
  const names = columns.map((column) => quoteIdentifier(column.name)).join(", ");
  await postgres.query(
    `INSERT INTO ${quoteIdentifier(table)} (${names}) VALUES ${tuples.join(", ")} ON CONFLICT DO NOTHING`,
    values,
  );
}

function hashRows(rows: QueryResultRow[], columns: Column[]): string {
  const hasher = new Bun.CryptoHasher("sha256");
  hasher.update("[");
  rows.forEach((row, index) => {
    if (index > 0) hasher.update(",");
    hasher.update(JSON.stringify(columns.map((column) => normaliseValue(row[column.name], column.type))));
  });
  hasher.update("]");
  return hasher.digest("hex");
}

function normaliseValue(value: unknown, sqliteType: string): unknown {
  if (value === null || value === undefined) return null;
  if (sqliteType.toUpperCase().includes("INT")) return Number(value);
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "bigint") return Number(value);
  return value;
}

function sqliteTableExists(table: string): boolean {
  return Boolean(sqlite.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(table));
}

function orderBy(columns: Column[]): string {
  const primary = columns.filter((column) => column.pk > 0).sort((left, right) => left.pk - right.pk);
  return (primary.length > 0 ? primary : columns).map((column) => quoteIdentifier(column.name)).join(", ");
}

function quoteIdentifier(identifier: string): string {
  if (!/^[a-z_][a-z0-9_]*$/i.test(identifier)) throw new Error(`Unsafe SQL identifier: ${identifier}`);
  return `"${identifier}"`;
}

function parseArgs(args: string[]) {
  const result = { sqlitePath: "data/howmuch-real.sqlite", resume: false, verifyOnly: false };
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    if (flag === "--sqlite" && args[index + 1]) {
      result.sqlitePath = args[index + 1];
      index += 1;
    } else if (flag === "--resume") {
      result.resume = true;
    } else if (flag === "--verify-only") {
      result.verifyOnly = true;
    } else if (flag === "--help") {
      console.log("Usage: DATABASE_URL=... bun run migrate:neon [--sqlite PATH] [--resume | --verify-only]");
      process.exit(0);
    } else {
      throw new Error(`Unknown or incomplete argument: ${flag}`);
    }
  }
  return result;
}
