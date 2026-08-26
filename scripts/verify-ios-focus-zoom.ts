import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const fixture = join(root, "apps/web/scripts/ios-focus-zoom-fixture.html");
const chrome = process.env.CHROME_PATH ?? "google-chrome";
const userData = mkdtempSync(join(tmpdir(), "howmuch-ios-zoom-"));
const dumpPath = join(userData, "dump.html");

const result = spawnSync(
  "timeout",
  [
    "12",
    chrome,
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--no-first-run",
    "--virtual-time-budget=2000",
    `--user-data-dir=${userData}`,
    "--dump-dom",
    pathToFileURL(fixture).href,
  ],
  { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 },
);

const match = result.stdout.match(/<pre id="report">([\s\S]*?)<\/pre>/);
if (!match) {
  writeFileSync(dumpPath, `${result.stdout}\n${result.stderr}`);
  throw new Error(`Chrome dump had no #report (exit ${result.status}). Output written to ${dumpPath}\n${result.stderr}`);
}

const report = JSON.parse(match[1].replaceAll("&quot;", '"'));
if (!report.ok) {
  console.error("Form controls below 16px (iOS Safari zooms these on focus):");
  for (const failure of report.failures) {
    console.error(`  ${failure.name}: ${failure.fontSize}`);
  }
  process.exit(1);
}

console.log("All measured text-entry controls are at least 16px.");
for (const row of report.rows) {
  if (!row.skip) console.log(`  ${row.name}: ${row.fontSize}`);
}
