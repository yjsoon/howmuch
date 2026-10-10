// Checks the downloaded archive and CSV against the live API, then restores
// the archive into a fresh, empty stack and compares the ledgers.
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { deepStrictEqual, strictEqual, ok } from "node:assert";
const [api, archivePath, csvPath, out, repo] = process.argv.slice(2);
const token = "howmuch-verify-bootstrap";
const lines: string[] = [];
const note = (line: string) => { lines.push(line); console.log(line); };
const get = async (base: string, path: string) => {
  const r = await fetch(base + path, { headers: { authorization: `Bearer ${token}` } });
  if (!r.ok) throw new Error(`${path} ${r.status} ${await r.text()}`);
  return r;
};
const data = async (base: string, path: string) => (await (await get(base, path)).json()).data;

const archive = JSON.parse(readFileSync(archivePath, "utf8"));
strictEqual(archive.format, "howmuch-export"); strictEqual(archive.version, 1);
deepStrictEqual(Object.keys(archive).sort(), ["account_preferences", "exported_at", "format", "plan", "rewards", "server_knowledge", "settings", "snapshot", "version"]);
const live = await data(api, "/v1/plans/local-plan/export_snapshot");
deepStrictEqual(archive.snapshot, live.snapshot);
note(`archive: format ${archive.format} v${archive.version}; snapshot equals GET export_snapshot (${archive.snapshot.accounts.length} accounts, ${archive.snapshot.transactions.length} transactions, ${archive.snapshot.scheduled_transactions.length} schedules, ${archive.snapshot.payees.length} payees, ${archive.snapshot.categories.length} categories)`);
deepStrictEqual(archive.settings, await data(api, "/v1/plans/local-plan/settings").then((d) => d.settings));
strictEqual(archive.plan.id, "local-plan");
const rewards = await data(api, "/api/import/rewards-tracker");
deepStrictEqual(archive.rewards.cards, rewards.cards);
note(`archive: settings equal GET settings; plan ${archive.plan.name}; rewards cards ${archive.rewards.cards.length} equal GET /api/import/rewards-tracker; account_preferences ${archive.account_preferences === null ? "null (none saved)" : "present"}`);
const text = JSON.stringify(archive);
for (const secret of ["howmuch-verify-15", "howmuch-verify-bootstrap", "password", "token_hash"]) ok(!text.includes(secret), `archive contains ${secret}`);
note("archive: contains no password, setup token or token hash");

const csv = readFileSync(csvPath, "utf8");
ok(csv.startsWith("﻿"));
const expectedRows = archive.snapshot.transactions.reduce((n: number, t: any) => n + Math.max(1, t.subtransactions.length), 0);
// Count records with a quote-aware scan.
let records = 0, quoted = false;
for (let i = 1; i < csv.length; i++) { const c = csv[i]; if (c === '"') quoted = !quoted; else if (!quoted && c === "\n") records++; }
strictEqual(records - 1, expectedRows);
ok(csv.includes('"\'=HYPERLINK(""http://example.invalid"")"'), "formula payee guarded");
ok(csv.includes('"Lunch, ""team""\nsecond line"'), "memo quoted");
const splitLines = csv.split("\r\n").filter((l) => /,-10\.00,|,-20\.00,/.test(l) && l.includes("Market"));
strictEqual(splitLines.length, 2);
ok(!csv.split("\r\n").some((l) => l.includes("Market") && l.includes(",-30.00,")), "split parent not double counted");
note(`csv: BOM present; ${expectedRows} data rows = transactions with splits expanded; formula payee prefixed with ' ; memo with comma, quotes and newline intact; split written as -10.00 and -20.00 lines, no -30.00 parent row`);

// Restore into a fresh stack.
const dir = mkdtempSync("/tmp/howmuch-verify/restore-");
const port = 40000 + Math.floor(Math.random() * 2000);
const server = Bun.spawn(["bun", "apps/api/src/server.ts"], { cwd: repo, env: { ...process.env, HOWMUCH_DB_PATH: `${dir}/restore.sqlite`, PORT: String(port), HOWMUCH_PORT: String(port), HOWMUCH_API_TOKEN: token, HOWMUCH_DEFAULT_PLAN_ID: "local-plan" }, stdout: "ignore", stderr: "ignore" });
const restore = `http://127.0.0.1:${port}`;
for (let i = 0; i < 50; i++) { try { if ((await fetch(restore + "/health")).ok) break; } catch {} await Bun.sleep(200); }
try {
  const posted = await fetch(restore + "/v1/plans/local-plan/import_snapshot", { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json", "idempotency-key": "e2e-restore-1" }, body: readFileSync(archivePath, "utf8") });
  const postedBody = await posted.json();
  strictEqual(posted.status, 201, JSON.stringify(postedBody));
  note(`restore: POST the archive file unchanged to a fresh stack's import_snapshot -> ${posted.status} ${JSON.stringify(postedBody.data.counts ?? postedBody.data)}`);
  const restored = await data(restore, "/v1/plans/local-plan/export_snapshot");
  deepStrictEqual(restored.snapshot, archive.snapshot);
  const balances = async (base: string) => Object.fromEntries((await data(base, "/v1/plans/local-plan/accounts")).accounts.filter((a: any) => !a.deleted).map((a: any) => [a.id, a.balance]));
  deepStrictEqual(await balances(restore), await balances(api));
  note("restore: restored export_snapshot deep-equals the archive snapshot; every account balance matches the original stack");
} finally { server.kill(); }
writeFileSync(`${out}/api-checks.log`, lines.join("\n") + "\n");
