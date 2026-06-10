import { copyFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { basename, dirname, extname, join } from "node:path";
import { openDatabase } from "../apps/api/src/db";
import { importYnabExport } from "../apps/api/src/importers/ynab-export";
import { LedgerRepository } from "../apps/api/src/repository";

type CliOptions = {
  dbPath: string;
  zipPath?: string;
  registerPath?: string;
  planPath?: string;
  planId: string;
  planName?: string;
  dateFormat: "dmy" | "mdy" | "ymd";
  noBackup: boolean;
  help: boolean;
};

const options = parseArgs(Bun.argv.slice(2));

if (options.help) {
  printHelp();
  process.exit(0);
}

const backupPath = options.noBackup ? null : maybeBackupDatabase(options.dbPath);
const input = options.zipPath ? readYnabExportZip(options.zipPath) : readYnabExportFiles(options);
const db = openDatabase(options.dbPath);
const repo = new LedgerRepository(db, options.planId);

try {
  const result = importYnabExport(repo, {
    planId: options.planId,
    planName: options.planName ?? input.planName,
    registerCsv: input.registerCsv,
    planCsv: input.planCsv,
    dateFormat: options.dateFormat,
  });
  const summary = queryImportSummary(db, options.planId);

  console.log(`Imported YNAB web export "${options.planName ?? input.planName ?? options.planId}"`);
  console.log(`Database: ${options.dbPath}`);
  if (backupPath) {
    console.log(`Backup: ${backupPath}`);
  }
  console.log(`Import session: ${result.import_session_id}`);
  console.log(`Imported transactions: ${result.imported}`);
  console.log(`Duplicate transactions: ${result.duplicate}`);
  console.log(`Failed rows: ${result.failed}`);
  console.log(`Accounts: ${summary.accounts}`);
  console.log(`Payees: ${summary.payees}`);
  console.log(`Category groups: ${summary.category_groups}`);
  console.log(`Categories: ${summary.categories}`);
  console.log(`Transactions: ${summary.transactions_active} active, ${summary.transactions_deleted} deleted`);
  console.log(`Date range: ${summary.first_date ?? "n/a"} to ${summary.last_date ?? "n/a"}`);
} finally {
  db.close();
}

function parseArgs(args: string[]): CliOptions {
  const options: CliOptions = {
    dbPath: Bun.env.HOWMUCH_DB_PATH ?? "data/howmuch.sqlite",
    planId: Bun.env.HOWMUCH_DEFAULT_PLAN_ID ?? "ynab-web-export",
    dateFormat: "dmy",
    noBackup: false,
    help: false,
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    const [flag, inlineValue] = arg.split("=", 2);
    const value = inlineValue ?? args[index + 1];

    if (flag === "--zip") {
      options.zipPath = readValue(flag, value);
      if (inlineValue === undefined) index += 1;
      continue;
    }
    if (flag === "--register") {
      options.registerPath = readValue(flag, value);
      if (inlineValue === undefined) index += 1;
      continue;
    }
    if (flag === "--plan") {
      options.planPath = readValue(flag, value);
      if (inlineValue === undefined) index += 1;
      continue;
    }
    if (flag === "--db") {
      options.dbPath = readValue(flag, value);
      if (inlineValue === undefined) index += 1;
      continue;
    }
    if (flag === "--plan-id") {
      options.planId = readValue(flag, value);
      if (inlineValue === undefined) index += 1;
      continue;
    }
    if (flag === "--plan-name") {
      options.planName = readValue(flag, value);
      if (inlineValue === undefined) index += 1;
      continue;
    }
    if (flag === "--date-format") {
      const dateFormat = readValue(flag, value);
      if (!["dmy", "mdy", "ymd"].includes(dateFormat)) {
        throw new Error("--date-format must be one of dmy, mdy, or ymd");
      }
      options.dateFormat = dateFormat as CliOptions["dateFormat"];
      if (inlineValue === undefined) index += 1;
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

  if (options.help) {
    return options;
  }

  if (!options.zipPath && !options.registerPath) {
    throw new Error("Pass --zip <ynab-export.zip> or --register <Register.csv>.");
  }
  if (options.zipPath && (options.registerPath || options.planPath)) {
    throw new Error("Use either --zip or --register/--plan, not both.");
  }

  return options;
}

function readValue(flag: string, value?: string): string {
  if (!value) {
    throw new Error(`Missing value for ${flag}`);
  }
  return value;
}

function readYnabExportFiles(options: CliOptions): { registerCsv: string; planCsv?: string; planName?: string } {
  if (!options.registerPath) {
    throw new Error("--register is required when --zip is not used.");
  }
  return {
    registerCsv: readFileSync(options.registerPath, "utf8"),
    planCsv: options.planPath ? readFileSync(options.planPath, "utf8") : undefined,
    planName: inferPlanName(options.registerPath),
  };
}

function readYnabExportZip(zipPath: string): { registerCsv: string; planCsv?: string; planName?: string } {
  const entries = unzip(["-Z1", zipPath]).split(/\r?\n/).filter(Boolean);
  const registerEntry = entries.find((entry) => /Register\.(csv|tsv)$/i.test(entry));
  const planEntry = entries.find((entry) => /Plan\.(csv|tsv)$/i.test(entry));

  if (!registerEntry) {
    throw new Error("Could not find a Register.csv or Register.tsv file in the YNAB export zip.");
  }

  return {
    registerCsv: unzip(["-p", zipPath, registerEntry]),
    planCsv: planEntry ? unzip(["-p", zipPath, planEntry]) : undefined,
    planName: inferPlanName(registerEntry),
  };
}

function unzip(args: string[]): string {
  const result = Bun.spawnSync(["unzip", ...args], {
    stdout: "pipe",
    stderr: "pipe",
  });
  if (!result.success) {
    throw new Error(`unzip failed: ${result.stderr.toString().trim()}`);
  }
  return result.stdout.toString();
}

function inferPlanName(path: string): string | undefined {
  const file = basename(path);
  const match = file.match(/^(.+?)\s+as of\s+/i);
  return match?.[1];
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
  const categoryGroups = singleNumber(
    db,
    "SELECT COUNT(*) AS value FROM category_groups WHERE plan_id = ? AND deleted = 0",
    planId,
  );
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

  return {
    accounts,
    payees,
    category_groups: categoryGroups,
    categories,
    transactions_active: transactionsActive,
    transactions_deleted: transactionsDeleted,
    first_date: range.first_date,
    last_date: range.last_date,
  };
}

function singleNumber(db: ReturnType<typeof openDatabase>, sql: string, ...params: unknown[]): number {
  const row = db.query(sql).get(...params) as { value: number } | null;
  return Number(row?.value ?? 0);
}

function printHelp(): void {
  console.log(`Import a YNAB web export zip or CSV pair into a local HowMuch SQLite database.

Usage:
  bun run import:ynab-export -- --zip "/path/to/YNAB Export - Plan as of YYYY-MM-DD HH-MM.zip" --db data/howmuch-real.sqlite
  bun run import:ynab-export -- --register Register.csv --plan Plan.csv --db data/howmuch-real.sqlite

Options:
  --zip <path>           YNAB web export zip containing Register.csv and Plan.csv
  --register <path>      Register CSV/TSV path when not importing a zip
  --plan <path>          Optional Plan CSV/TSV path when not importing a zip
  --db <path>            SQLite database path (default HOWMUCH_DB_PATH or data/howmuch.sqlite)
  --plan-id <id>         Local HowMuch plan id (default HOWMUCH_DEFAULT_PLAN_ID or ynab-web-export)
  --plan-name <name>     Local HowMuch plan name
  --date-format <fmt>    Date parser for non-ISO dates: dmy, mdy, or ymd (default dmy)
  --no-backup            Skip backup when the database file already exists
  --help                 Show this help
`);
}
