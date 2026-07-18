import { Database } from "bun:sqlite";
import { stat } from "node:fs/promises";
import { resolve } from "node:path";
import { ReportService } from "../apps/api/src/reports";

const TABLES = [
  "schema_migrations",
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

type Row = Record<string, unknown>;

const options = parseArgs(Bun.argv.slice(2));
const dbPath = resolve(options.dbPath);
const db = new Database(dbPath, { readonly: true, strict: true });

try {
  const planRows = db.query("SELECT id, name FROM plans ORDER BY id").all() as Array<{ id: string; name: string }>;
  const planId = options.planId ?? (planRows.length === 1 ? planRows[0].id : undefined);
  if (!planId) {
    throw new Error(
      planRows.length === 0
        ? "The database has no plans"
        : `The database has ${planRows.length} plans; pass --plan-id explicitly`,
    );
  }

  const manifest = await buildManifest(db, dbPath, planId);
  const output = `${JSON.stringify(manifest, null, 2)}\n`;

  if (options.comparePath) {
    const expected = await Bun.file(resolve(options.comparePath)).json();
    const differences = compareManifests(expected, manifest);
    if (differences.length > 0) {
      console.error(`Baseline mismatch (${differences.length} differences):`);
      for (const difference of differences) console.error(`- ${difference}`);
      process.exitCode = 1;
    } else {
      console.error("Baseline matches.");
    }
  }

  if (options.outputPath) {
    await Bun.write(resolve(options.outputPath), output);
    console.error(`Wrote ${resolve(options.outputPath)}`);
  } else {
    process.stdout.write(output);
  }
} finally {
  db.close();
}

async function buildManifest(db: Database, dbPath: string, planId: string) {
  const reports = new ReportService(db);
  const [spending, income, netWorth, ageOfMoney] = [
    reports.spendingBreakdown(planId),
    reports.incomeVsSpending(planId),
    reports.netWorth(planId),
    reports.ageOfMoney(planId),
  ];

  const tables = Object.fromEntries(
    TABLES.filter((table) => tableExists(db, table)).map((table) => {
      const rows = db.query(`SELECT * FROM ${table} ORDER BY ${primaryOrder(db, table)}`).all() as Row[];
      return [table, { rows: rows.length, sha256: hashValue(rows) }];
    }),
  );

  const ledger = db
    .query(
      `SELECT
         COUNT(*) AS transactions,
         SUM(CASE WHEN deleted = 0 THEN 1 ELSE 0 END) AS active_transactions,
         SUM(CASE WHEN deleted = 1 THEN 1 ELSE 0 END) AS deleted_transactions,
         COALESCE(SUM(CASE WHEN deleted = 0 THEN amount_milli ELSE 0 END), 0) AS active_amount_milli,
         MIN(CASE WHEN deleted = 0 THEN date END) AS first_date,
         MAX(CASE WHEN deleted = 0 THEN date END) AS last_date,
         MIN(server_knowledge) AS min_server_knowledge,
         MAX(server_knowledge) AS max_server_knowledge
       FROM transactions WHERE plan_id = ?`,
    )
    .get(planId) as Row;
  const accounts = db
    .query(
      `SELECT
         COUNT(*) AS accounts,
         SUM(CASE WHEN deleted = 0 THEN 1 ELSE 0 END) AS active_accounts,
         COALESCE(SUM(CASE WHEN deleted = 0 THEN balance_milli ELSE 0 END), 0) AS cached_balance_milli,
         COALESCE(SUM(CASE WHEN deleted = 0 THEN cleared_balance_milli ELSE 0 END), 0) AS cached_cleared_balance_milli,
         COALESCE(SUM(CASE WHEN deleted = 0 THEN uncleared_balance_milli ELSE 0 END), 0) AS cached_uncleared_balance_milli
       FROM accounts WHERE plan_id = ?`,
    )
    .get(planId) as Row;
  const plan = db.query("SELECT * FROM plans WHERE id = ?").get(planId) as Row;

  return {
    format: 1,
    source: {
      engine: "sqlite",
      bytes: (await stat(dbPath)).size,
    },
    plan: {
      id: plan.id,
      name: plan.name,
      server_knowledge: numberValue(plan.server_knowledge),
    },
    ledger: numbers(ledger),
    accounts: numbers(accounts),
    tables,
    reports: {
      spending_breakdown: {
        total: spending.total,
        groups: spending.groups.length,
        sha256: hashValue(spending),
      },
      income_vs_spending: {
        periods: income.periods.length,
        income: sum(income.periods, "income"),
        spending: sum(income.periods, "spending"),
        net: sum(income.periods, "net"),
        sha256: hashValue(income),
      },
      net_worth: {
        periods: netWorth.periods.length,
        final: netWorth.periods.at(-1)?.net_worth ?? 0,
        sha256: hashValue(netWorth),
      },
      age_of_money: {
        periods: ageOfMoney.periods.length,
        final_days: ageOfMoney.periods.at(-1)?.age_of_money_days ?? null,
        sha256: hashValue(ageOfMoney),
      },
    },
  };
}

function tableExists(db: Database, table: string): boolean {
  return Boolean(db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(table));
}

function primaryOrder(db: Database, table: string): string {
  const columns = db.query(`PRAGMA table_info(${table})`).all() as Array<{ name: string; pk: number }>;
  const primary = columns.filter((column) => column.pk > 0).sort((a, b) => a.pk - b.pk);
  return (primary.length > 0 ? primary : columns).map((column) => `"${column.name}"`).join(", ");
}

function hashValue(value: unknown): string {
  const hasher = new Bun.CryptoHasher("sha256");
  hasher.update(JSON.stringify(normalise(value)));
  return hasher.digest("hex");
}

function normalise(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(normalise);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Row)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, item]) => [key, normalise(item)]),
    );
  }
  return value;
}

function numbers(row: Row): Row {
  return Object.fromEntries(Object.entries(row).map(([key, value]) => [key, numberValue(value)]));
}

function numberValue(value: unknown): unknown {
  return typeof value === "bigint" ? Number(value) : value;
}

function sum(rows: Row[], key: string): number {
  return rows.reduce((total, row) => total + Number(row[key] ?? 0), 0);
}

function compareManifests(expected: unknown, actual: unknown, path = "manifest"): string[] {
  if (Object.is(expected, actual)) return [];
  if (Array.isArray(expected) && Array.isArray(actual)) {
    const differences = expected.length === actual.length ? [] : [`${path}.length: expected ${expected.length}, got ${actual.length}`];
    for (let index = 0; index < Math.min(expected.length, actual.length); index += 1) {
      differences.push(...compareManifests(expected[index], actual[index], `${path}[${index}]`));
    }
    return differences;
  }
  if (expected && actual && typeof expected === "object" && typeof actual === "object") {
    const expectedRow = expected as Row;
    const actualRow = actual as Row;
    const keys = [...new Set([...Object.keys(expectedRow), ...Object.keys(actualRow)])].sort();
    return keys.flatMap((key) => compareManifests(expectedRow[key], actualRow[key], `${path}.${key}`));
  }
  return [`${path}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`];
}

function parseArgs(args: string[]) {
  const result: { dbPath: string; planId?: string; outputPath?: string; comparePath?: string } = {
    dbPath: "data/howmuch-real.sqlite",
  };
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    const value = args[index + 1];
    if (flag === "--db" && value) result.dbPath = value;
    else if (flag === "--plan-id" && value) result.planId = value;
    else if (flag === "--output" && value) result.outputPath = value;
    else if (flag === "--compare" && value) result.comparePath = value;
    else if (flag === "--help") {
      console.log("Usage: bun run baseline:sqlite [--db PATH] [--plan-id ID] [--output PATH] [--compare PATH]");
      process.exit(0);
    } else {
      throw new Error(`Unknown or incomplete argument: ${flag}`);
    }
    index += 1;
  }
  return result;
}
