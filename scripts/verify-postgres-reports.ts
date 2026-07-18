import { Database } from "bun:sqlite";
import { Client } from "pg";
import { resolve } from "node:path";
import { PostgresDatabase } from "../apps/api/src/postgres";
import { PostgresReportService } from "../apps/api/src/postgres-reports";
import { ReportService } from "../apps/api/src/reports";

const options = parseArgs(Bun.argv.slice(2));
const connectionString = Bun.env.DATABASE_URL?.trim();
if (!connectionString) throw new Error("DATABASE_URL is required");

const baseline = options.baselinePath ? await Bun.file(resolve(options.baselinePath)).json() : undefined;
const planId = options.planId ?? (typeof baseline?.plan?.id === "string" ? baseline.plan.id : undefined);
if (!planId) throw new Error("--plan-id is required unless --baseline contains plan.id");
const sqlite = options.baselinePath ? undefined : new Database(resolve(options.sqlitePath), { readonly: true, strict: true });
const client = new Client({ connectionString });
await client.connect();

try {
  const sqliteReports = sqlite ? new ReportService(sqlite) : undefined;
  const postgresReports = new PostgresReportService(new PostgresDatabase(client));
  const reportCases = [
    ["spending_breakdown", () => sqliteReports?.spendingBreakdown(planId), () => postgresReports.spendingBreakdown(planId)],
    ["income_vs_spending", () => sqliteReports?.incomeVsSpending(planId), () => postgresReports.incomeVsSpending(planId)],
    ["net_worth", () => sqliteReports?.netWorth(planId), () => postgresReports.netWorth(planId)],
    ["age_of_money", () => sqliteReports?.ageOfMoney(planId), () => postgresReports.ageOfMoney(planId)],
  ] as const;

  const results: Record<string, { expected_sha256: string; postgres_sha256: string; matches: boolean }> = {};
  for (const [name, readSqlite, readPostgres] of reportCases) {
    const expectedHash = baseline ? baselineHash(baseline, name) : hash(readSqlite());
    const postgresResult = await readPostgres();
    const postgresHash = hash(postgresResult);
    results[name] = { expected_sha256: expectedHash, postgres_sha256: postgresHash, matches: expectedHash === postgresHash };
    console.error(`${expectedHash === postgresHash ? "ok" : "MISMATCH"} ${name}`);
  }

  const matches = Object.values(results).every((result) => result.matches);
  console.log(JSON.stringify({ plan_id: planId, expected_source: options.baselinePath ?? options.sqlitePath, reports: results, matches }, null, 2));
  if (!matches) process.exitCode = 1;
} finally {
  sqlite?.close();
  await client.end();
}

function baselineHash(baseline: any, name: string): string {
  const value = baseline?.reports?.[name]?.sha256;
  if (typeof value !== "string" || !value) throw new Error(`Baseline is missing reports.${name}.sha256`);
  return value;
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
  const result: { sqlitePath: string; baselinePath?: string; planId?: string } = {
    sqlitePath: "data/howmuch-real.sqlite",
  };
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    const value = args[index + 1];
    if (flag === "--sqlite" && value) result.sqlitePath = value;
    else if (flag === "--plan-id" && value) result.planId = value;
    else if (flag === "--baseline" && value) result.baselinePath = value;
    else if (flag === "--help") {
      console.log("Usage: DATABASE_URL=... bun run verify:postgres-reports [--baseline PATH | --sqlite PATH --plan-id ID]");
      process.exit(0);
    }
    else throw new Error(`Unknown or incomplete argument: ${flag}`);
    index += 1;
  }
  return result;
}
