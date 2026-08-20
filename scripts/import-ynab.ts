import { copyFileSync, existsSync, mkdirSync } from "node:fs";
import { basename, dirname, extname, join } from "node:path";
import { openDatabase } from "../apps/api/src/db";
import { importYnabFromApi, listYnabPlans, type YnabPlanSummary } from "../apps/api/src/importers/ynab";
import { LedgerRepository } from "../apps/api/src/repository";

type CliOptions = {
  planId?: string;
  planName?: string;
  dbPath: string;
  token?: string;
  baseUrl: string;
  sinceDate?: string;
  listPlans: boolean;
  noBackup: boolean;
  help: boolean;
};

const options = parseArgs(Bun.argv.slice(2));

if (options.help) {
  printHelp();
  process.exit(0);
}

const token = options.token ?? Bun.env.YNAB_TOKEN;

if (!token) {
  console.error("YNAB token missing. Set YNAB_TOKEN in your shell or pass --token as a one-off.");
  process.exit(1);
}

const plans = await listYnabPlans({
  token,
  baseUrl: options.baseUrl,
});

if (options.listPlans) {
  if (plans.length === 0) {
    console.log("No YNAB plans available for this token.");
    process.exit(0);
  }

  for (const plan of plans) {
    console.log([plan.id, plan.name, plan.last_modified_on ?? ""].join("\t"));
  }
  process.exit(0);
}

const selectedPlan = resolvePlan(plans, options.planId, options.planName);
const backupPath = options.noBackup ? null : maybeBackupDatabase(options.dbPath);
const db = openDatabase(options.dbPath);
const repo = new LedgerRepository(db, selectedPlan.id);

try {
  const result = await importYnabFromApi(repo, {
    token,
    planId: selectedPlan.id,
    baseUrl: options.baseUrl,
    sinceDate: options.sinceDate,
  });

  const summary = queryImportSummary(db, selectedPlan.id);
  console.log(`Imported YNAB plan "${selectedPlan.name}" (${selectedPlan.id})`);
  console.log(`Database: ${options.dbPath}`);
  if (backupPath) {
    console.log(`Backup: ${backupPath}`);
  }
  console.log(`Import session: ${result.import_session_id}`);
  console.log(`Imported transactions: ${result.imported_transactions}`);
  console.log(`YNAB raw objects: ${summary.raw_objects}`);
  console.log(`YNAB raw objects by type: ${formatCounts(summary.raw_object_types)}`);
  console.log(`YNAB server knowledge: ${result.server_knowledge ?? "n/a"}`);
  console.log(`Accounts: ${summary.accounts}`);
  console.log(`Payees: ${summary.payees}`);
  console.log(`Categories: ${summary.categories}`);
  console.log(`Transactions: ${summary.transactions_active} active, ${summary.transactions_deleted} deleted`);
  console.log(`Date range: ${summary.first_date ?? "n/a"} to ${summary.last_date ?? "n/a"}`);
  console.log(`Account balance mismatches: ${summary.balance_mismatches}`);
} finally {
  db.close();
}

function parseArgs(args: string[]): CliOptions {
  const options: CliOptions = {
    dbPath: Bun.env.HOWMUCH_DB_PATH ?? "data/howmuch.sqlite",
    token: undefined,
    baseUrl: Bun.env.YNAB_BASE_URL ?? "https://api.ynab.com/v1",
    sinceDate: undefined,
    listPlans: false,
    noBackup: false,
    help: false,
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    const [flag, inlineValue] = arg.split("=", 2);
    const value = inlineValue ?? args[index + 1];

    if (flag === "--plan-id") {
      options.planId = readValue(flag, value);
      if (inlineValue === undefined) {
        index += 1;
      }
      continue;
    }
    if (flag === "--plan-name") {
      options.planName = readValue(flag, value);
      if (inlineValue === undefined) {
        index += 1;
      }
      continue;
    }
    if (flag === "--db") {
      options.dbPath = readValue(flag, value);
      if (inlineValue === undefined) {
        index += 1;
      }
      continue;
    }
    if (flag === "--token") {
      options.token = readValue(flag, value);
      if (inlineValue === undefined) {
        index += 1;
      }
      continue;
    }
    if (flag === "--base-url") {
      options.baseUrl = readValue(flag, value);
      if (inlineValue === undefined) {
        index += 1;
      }
      continue;
    }
    if (flag === "--since-date") {
      options.sinceDate = readValue(flag, value);
      if (inlineValue === undefined) {
        index += 1;
      }
      continue;
    }
    if (flag === "--list-plans") {
      options.listPlans = true;
      continue;
    }
    if (flag === "--no-backup") {
      options.noBackup = true;
      continue;
    }
    if (flag === "--help" || flag === "-h") {
      options.help = true;
      continue;
    }

    throw new Error(`Unknown argument: ${arg}`);
  }

  return options;
}

function readValue(flag: string, value?: string): string {
  if (!value) {
    throw new Error(`Missing value for ${flag}`);
  }
  return value;
}

function resolvePlan(plans: YnabPlanSummary[], planId?: string, planName?: string): YnabPlanSummary {
  if (planId) {
    const plan = plans.find((candidate) => candidate.id === planId);
    if (!plan) {
      throw new Error(`Plan ${planId} was not returned by the YNAB API token.`);
    }
    return plan;
  }

  if (planName) {
    const matches = plans.filter((candidate) => candidate.name.toLowerCase() === planName.toLowerCase());
    if (matches.length === 1) {
      return matches[0];
    }
    if (matches.length > 1) {
      throw new Error(`Plan name "${planName}" is ambiguous. Use --plan-id instead.`);
    }
    throw new Error(`Plan name "${planName}" was not returned by the YNAB API token.`);
  }

  if (plans.length === 1) {
    return plans[0];
  }

  if (plans.length === 0) {
    throw new Error("No YNAB plans available for this token.");
  }

  throw new Error("Multiple YNAB plans are available. Run with --list-plans, then pass --plan-id.");
}

function maybeBackupDatabase(dbPath: string): string | null {
  if (!existsSync(dbPath)) {
    return null;
  }

  const backupDir = join(dirname(dbPath), "backups");
  mkdirSync(backupDir, { recursive: true });
  const extension = extname(dbPath);
  const name = basename(dbPath, extension);
  const backupPath = join(backupDir, `${name}-${timestampForFileName()}.${extension ? extension.slice(1) : "sqlite"}`);
  copyFileSync(dbPath, backupPath);
  return backupPath;
}

function timestampForFileName(): string {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\..+$/, "").replace("T", "-");
}

function queryImportSummary(db: ReturnType<typeof openDatabase>, planId: string) {
  const accounts = singleNumber(db, "SELECT COUNT(*) AS value FROM accounts WHERE plan_id = ? AND deleted = 0", planId);
  const payees = singleNumber(db, "SELECT COUNT(*) AS value FROM payees WHERE plan_id = ? AND deleted = 0", planId);
  const categories = singleNumber(db, "SELECT COUNT(*) AS value FROM categories WHERE plan_id = ? AND deleted = 0", planId);
  const transactionsActive = singleNumber(
    db,
    "SELECT COUNT(*) AS value FROM transactions WHERE plan_id = ? AND deleted = 0",
    planId,
  );
  const transactionsDeleted = singleNumber(
    db,
    "SELECT COUNT(*) AS value FROM transactions WHERE plan_id = ? AND deleted = 1",
    planId,
  );
  const range = db
    .query("SELECT MIN(date) AS first_date, MAX(date) AS last_date FROM transactions WHERE plan_id = ?")
    .get(planId) as {
    first_date: string | null;
    last_date: string | null;
  };
  const balanceMismatches = singleNumber(
    db,
    `SELECT COUNT(*) AS value
     FROM accounts a
     LEFT JOIN (
       SELECT account_id, COALESCE(SUM(CASE WHEN deleted = 0 THEN amount_milli ELSE 0 END), 0) AS actual_balance
       FROM transactions
       WHERE plan_id = ?
       GROUP BY account_id
     ) balances ON balances.account_id = a.id
     WHERE a.plan_id = ?
       AND a.deleted = 0
       AND COALESCE(balances.actual_balance, 0) != COALESCE(a.balance_milli, 0)`,
    planId,
    planId,
  );
  const rawObjects = singleNumber(db, "SELECT COUNT(*) AS value FROM ynab_raw_objects WHERE plan_id = ?", planId);
  const rawObjectTypes = Object.fromEntries((db.query(
    "SELECT object_type, COUNT(*) AS value FROM ynab_raw_objects WHERE plan_id = ? GROUP BY object_type ORDER BY object_type",
  ).all(planId) as Array<{ object_type: string; value: number | bigint }>).map((row) => [row.object_type, Number(row.value)]));

  return {
    accounts,
    payees,
    categories,
    transactions_active: transactionsActive,
    transactions_deleted: transactionsDeleted,
    first_date: range.first_date,
    last_date: range.last_date,
    balance_mismatches: balanceMismatches,
    raw_objects: rawObjects,
    raw_object_types: rawObjectTypes,
  };
}

function singleNumber(db: ReturnType<typeof openDatabase>, sql: string, ...params: string[]): number {
  const row = db.query(sql).get(...params) as { value: number | bigint };
  return Number(row.value ?? 0);
}

function formatCounts(counts: Record<string, number>): string {
  const entries = Object.entries(counts);
  return entries.length ? entries.map(([type, count]) => `${type}=${count}`).join(", ") : "none";
}

function printHelp(): void {
  console.log(`Usage: bun run import:ynab [options]

Preferred auth:
  Set YNAB_TOKEN in your shell instead of passing --token.

Options:
  --list-plans           List YNAB plans available to the token, then exit
  --plan-id <id>         Import a specific YNAB plan
  --plan-name <name>     Import a single plan by exact name
  --db <path>            SQLite destination (default: data/howmuch.sqlite)
  --since-date <date>    Override the default full-history fetch start date
  --base-url <url>       Override the YNAB API base URL
  --no-backup            Skip the automatic SQLite backup
  --help                 Show this help
`);
}
