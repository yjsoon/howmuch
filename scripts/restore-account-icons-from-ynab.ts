import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { planIconRestoreFromYnab, sqlForIconRestore } from "./lib/restore-account-icons-from-ynab";

const YNAB_BASE = Bun.env.YNAB_BASE_URL ?? "https://api.ynab.com/v1";
const WORKER_DIR = join(import.meta.dir, "..", "apps", "worker");

type Target = "preview" | "production";

const options = parseArgs(Bun.argv.slice(2));
if (options.help) {
  console.log("Usage: bun scripts/restore-account-icons-from-ynab.ts [--env preview|production] [--dry-run]");
  console.log("Reads YNAB account names (GET only) and writes HowMuch accounts.icon. Never writes to YNAB.");
  process.exit(0);
}

const token = Bun.env.YNAB_API_KEY ?? Bun.env.YNAB_TOKEN;
const budgetId = Bun.env.YNAB_BUDGET_ID;
if (!token || !budgetId) {
  console.error("YNAB_API_KEY and YNAB_BUDGET_ID are required.");
  process.exit(1);
}

await assertCloudflareAccount();
const ynabAccounts = await fetchYnabAccounts(token, budgetId);
console.log(`YNAB GET accounts: ${ynabAccounts.length} (read-only)`);

for (const target of options.targets) {
  const howmuch = await listHowMuchAccounts(target);
  const plan = planIconRestoreFromYnab(ynabAccounts, howmuch);
  console.log(JSON.stringify({ target, ...counts(plan) }));
  if (options.dryRun || plan.updates.length === 0) continue;
  await applySql(target, sqlForIconRestore(plan.updates));
  const after = await countNonDefaultIcons(target);
  console.log(JSON.stringify({ target, applied: plan.updates.length, ...after }));
}

function counts(plan: ReturnType<typeof planIconRestoreFromYnab>) {
  const { updates: _updates, ...rest } = plan;
  return { ...rest, updates: plan.updates.length };
}

function parseArgs(argv: string[]) {
  const targets: Target[] = [];
  let dryRun = false;
  let help = false;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") help = true;
    else if (arg === "--dry-run") dryRun = true;
    else if (arg === "--env") {
      const value = argv[index + 1];
      index += 1;
      if (value !== "preview" && value !== "production") {
        throw new Error("--env must be preview or production");
      }
      targets.push(value);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return { targets: targets.length ? targets : ["preview", "production"] as Target[], dryRun, help };
}

async function assertCloudflareAccount() {
  const expectedAccountId = Bun.env.CLOUDFLARE_ACCOUNT_ID;
  if (!expectedAccountId) {
    throw new Error("CLOUDFLARE_ACCOUNT_ID is required so this script cannot target the wrong account");
  }
  const whoami = await wranglerJson(["whoami", "--json"]);
  const ids = (whoami.accounts ?? []).map((account: { id?: string }) => account.id);
  if (!whoami.loggedIn || !ids.includes(expectedAccountId)) {
    throw new Error("Wrangler is not authenticated to the configured Cloudflare account");
  }
  const bookmark = await wranglerJson(["d1", "time-travel", "info", "DB", "--json"], WORKER_DIR);
  if (!bookmark?.bookmark) {
    throw new Error("D1 Time Travel bookmark missing; refusing to write");
  }
}

async function fetchYnabAccounts(authToken: string, planId: string): Promise<Array<{ id: string; name: string; deleted?: boolean }>> {
  const paths = [`/budgets/${planId}/accounts`, `/plans/${planId}/accounts`];
  for (const path of paths) {
    const response = await fetch(`${YNAB_BASE}${path}`, {
      headers: { Authorization: `Bearer ${authToken}` },
    });
    if (response.status === 404) continue;
    if (!response.ok) {
      throw new Error(`YNAB GET ${path} failed: ${response.status}`);
    }
    const body = await response.json() as { data?: { accounts?: Array<{ id: string; name: string; deleted?: boolean }> } };
    return body.data?.accounts ?? [];
  }
  throw new Error("YNAB GET accounts returned 404 for both /budgets and /plans");
}

async function listHowMuchAccounts(target: Target) {
  const rows = await d1Query(target, "SELECT id, external_ynab_id, icon, type FROM accounts WHERE deleted = 0");
  return rows.map((row) => ({
    id: String(row.id),
    external_ynab_id: row.external_ynab_id == null ? null : String(row.external_ynab_id),
    icon: row.icon == null ? null : String(row.icon),
  }));
}

async function countNonDefaultIcons(target: Target) {
  const rows = await d1Query(target, `
    SELECT
      SUM(CASE WHEN deleted = 0 THEN 1 ELSE 0 END) AS live_accounts,
      SUM(CASE WHEN deleted = 0 AND icon IS NOT NULL AND trim(icon) <> ''
        AND icon NOT IN ('🏦','💰','💵','💳','📈','📉','🏠','🚗','🎓','🏥','📄') THEN 1 ELSE 0 END) AS custom_or_lifted
    FROM accounts
  `);
  return rows[0] ?? {};
}

async function applySql(target: Target, sql: string) {
  const dir = await mkdtemp(join(tmpdir(), "howmuch-icon-restore-"));
  const file = join(dir, "restore.sql");
  await writeFile(file, sql, "utf8");
  await wrangler(["d1", "execute", "DB", "--remote", "--yes", "--file", file, ...targetFlags(target)], WORKER_DIR);
}

async function d1Query(target: Target, sql: string) {
  const payload = await wranglerJson(["d1", "execute", "DB", "--remote", "--json", "--command", sql, ...targetFlags(target)], WORKER_DIR);
  const batch = Array.isArray(payload) ? payload[0] : payload;
  return (batch?.results ?? batch?.result?.[0]?.results ?? []) as Array<Record<string, unknown>>;
}

function targetFlags(target: Target): string[] {
  return target === "preview" ? ["--env", "preview"] : [];
}

async function wrangler(args: string[], cwd?: string) {
  const result = Bun.spawnSync({
    cmd: ["bunx", "wrangler", ...args],
    cwd,
    stdout: "pipe",
    stderr: "pipe",
    env: process.env,
  });
  if (result.exitCode !== 0) {
    const err = new TextDecoder().decode(result.stderr);
    throw new Error(err.split("\n").filter((line) => !/bookmark|token|secret/i.test(line) || /error/i.test(line)).slice(0, 20).join("\n") || `wrangler ${args[0]} failed`);
  }
  return new TextDecoder().decode(result.stdout);
}

async function wranglerJson(args: string[], cwd?: string) {
  const stdout = await wrangler(args, cwd);
  const start = stdout.indexOf("{") === -1 ? stdout.indexOf("[") : Math.min(
    ...[stdout.indexOf("{"), stdout.indexOf("[")].filter((index) => index >= 0),
  );
  return JSON.parse(stdout.slice(start >= 0 ? start : 0));
}
