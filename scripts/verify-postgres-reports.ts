import { Database } from "bun:sqlite";
import { Client } from "pg";
import { resolve } from "node:path";
import { PostgresDatabase } from "../apps/api/src/postgres";
import { PostgresReportService } from "../apps/api/src/postgres-reports";
import { ReportService } from "../apps/api/src/reports";

const options = parseArgs(Bun.argv.slice(2));
const connectionString = Bun.env.DATABASE_URL?.trim();
if (!connectionString) throw new Error("DATABASE_URL is required");

const sqlite = new Database(resolve(options.sqlitePath), { readonly: true, strict: true });
const client = new Client({ connectionString });
await client.connect();

try {
  const sqliteReports = new ReportService(sqlite);
  const postgresReports = new PostgresReportService(new PostgresDatabase(client));
  const reportCases = [
    ["spending_breakdown", () => sqliteReports.spendingBreakdown(options.planId), () => postgresReports.spendingBreakdown(options.planId)],
    ["income_vs_spending", () => sqliteReports.incomeVsSpending(options.planId), () => postgresReports.incomeVsSpending(options.planId)],
    ["net_worth", () => sqliteReports.netWorth(options.planId), () => postgresReports.netWorth(options.planId)],
    ["age_of_money", () => sqliteReports.ageOfMoney(options.planId), () => postgresReports.ageOfMoney(options.planId)],
  ] as const;

  const results: Record<string, { sqlite_sha256: string; postgres_sha256: string; matches: boolean }> = {};
  for (const [name, readSqlite, readPostgres] of reportCases) {
    const sqliteResult = readSqlite();
    const postgresResult = await readPostgres();
    const sqliteHash = hash(sqliteResult);
    const postgresHash = hash(postgresResult);
    results[name] = { sqlite_sha256: sqliteHash, postgres_sha256: postgresHash, matches: sqliteHash === postgresHash };
    console.error(`${sqliteHash === postgresHash ? "ok" : "MISMATCH"} ${name}`);
  }

  const matches = Object.values(results).every((result) => result.matches);
  console.log(JSON.stringify({ plan_id: options.planId, reports: results, matches }, null, 2));
  if (!matches) process.exitCode = 1;
} finally {
  sqlite.close();
  await client.end();
}

function hash(value: unknown): string {
  const hasher = new Bun.CryptoHasher("sha256");
  hasher.update(JSON.stringify(normalise(value)));
  return hasher.digest("hex");
}

function normalise(value: unknown): unknown {
  if (typeof value === "bigint") return Number(value);
  if (Array.isArray(value)) return value.map(normalise);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, item]) => [key, normalise(item)]),
    );
  }
  return value;
}

function parseArgs(args: string[]) {
  const result = { sqlitePath: "data/howmuch-real.sqlite", planId: "" };
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    const value = args[index + 1];
    if (flag === "--sqlite" && value) result.sqlitePath = value;
    else if (flag === "--plan-id" && value) result.planId = value;
    else throw new Error(`Unknown or incomplete argument: ${flag}`);
    index += 1;
  }
  if (!result.planId) throw new Error("--plan-id is required");
  return result;
}
