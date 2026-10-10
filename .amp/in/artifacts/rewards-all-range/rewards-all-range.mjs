// E2E for issue #278: Rewards > Historical range > All must stay in Historical
// range and cover all history. Drives the real web app against a disposable
// `control-howmuch launch` stack with synthetic data.
//
// Usage: node rewards-all-range.mjs <web_url> <repo_root> <out_dir> <db_path>
import { chromium } from "playwright";
import { DatabaseSync } from "node:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [webUrl, repoRoot, outDir, dbPath] = process.argv.slice(2);
mkdirSync(outDir, { recursive: true });
const results = [];
const check = (name, ok, observed) => {
  results.push({ name, ok, observed });
  console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${JSON.stringify(observed)}`);
};

const browser = await chromium.launch({ executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome" });
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
const page = await context.newPage();

// First-owner setup (skipped when the stack already has an owner).
await page.goto(webUrl);
await page.getByRole("heading", { name: /Set up Halation|Sign in to Halation/ }).waitFor();
if (await page.getByRole("heading", { name: "Set up Halation" }).isVisible()) {
  await page.getByLabel("Username").fill("verifier");
  await page.getByLabel("Password").fill("howmuch-verify-15");
  await page.getByLabel("Setup token").fill("howmuch-verify-bootstrap");
  await page.getByRole("button", { name: "Create account" }).click();
} else {
  await page.getByLabel("Username").fill("verifier");
  await page.getByLabel("Password").fill("howmuch-verify-15");
  await page.getByRole("button", { name: "Sign in" }).click();
}
await page.getByRole("navigation", { name: "Primary navigation" }).waitFor({ timeout: 30000 });

// Import the Rewards Tracker export through Settings > Rewards import.
await page.goto(`${webUrl}/import/rewards`);
await page.getByLabel("Rewards Tracker export").setInputFiles(join(repoRoot, "fixtures/rewards-tracker-export.json"));
await page.getByRole("button", { name: "Import export" }).click();
await page.getByText("Imported this session").waitFor();

// Expected values come from the ledger itself, not from the report code:
// every Travel Card spend, from its first date.
const db = new DatabaseSync(dbPath, { readOnly: true });
const expected = db.prepare(`SELECT MIN(t.date) AS first, ROUND(SUM(-t.amount_milli) / 1000.0, 2) AS spend
  FROM transactions t JOIN accounts a ON a.id = t.account_id
  WHERE t.deleted = 0 AND a.name = 'Travel Card' AND t.amount_milli < 0`).get();
db.close();
console.log("expected from ledger:", JSON.stringify(expected));

for (const viewport of [{ width: 1440, height: 1000 }, { width: 390, height: 844 }]) {
  const tag = `${viewport.width}`;
  await page.setViewportSize(viewport);
  await page.goto(`${webUrl}/rewards`);
  await page.getByRole("button", { name: "Card periods" }).waitFor();
  await page.getByRole("button", { name: "Historical range" }).click();
  await page.getByRole("group", { name: "Date range" }).waitFor();

  const reportResponse = page.waitForResponse((r) => r.url().includes("/api/reports/rewards") && !new URL(r.url()).searchParams.get("from"));
  await page.getByRole("group", { name: "Date range" }).getByRole("button", { name: "All", exact: true }).click();
  const report = await (await reportResponse).json();
  await page.waitForLoadState("networkidle");
  await page.screenshot({ path: join(outDir, `historical-all-${tag}.png`) });
  writeFileSync(join(outDir, `historical-all-${tag}.json`), JSON.stringify({
    request: (await reportResponse).url().replace(/^https?:\/\/[^/]+/, ""),
    period: report.data.period, as_of: report.data.as_of, totals: report.data.totals,
    cards: report.data.cards.map((row) => ({ id: row.card.id, period: row.calculation.period, total_spend: row.calculation.total_spend, reward_earned: row.calculation.reward_earned })),
    groups: report.data.groups.length,
  }, null, 2));

  check(`${tag}: Historical range stays pressed`, await page.getByRole("button", { name: "Historical range" }).getAttribute("aria-pressed") === "true",
    await page.getByRole("button", { name: "Historical range" }).getAttribute("aria-pressed"));
  const allButton = page.getByRole("group", { name: "Date range" }).getByRole("button", { name: "All", exact: true });
  const allPressed = await allButton.count() ? await allButton.getAttribute("aria-pressed") : "rail gone";
  check(`${tag}: All preset pressed`, allPressed === "true", allPressed);
  const scope = await page.locator(".rw-hero-scope").innerText();
  check(`${tag}: hero reads All time`, scope.startsWith("All time"), scope);
  check(`${tag}: URL keeps range mode`, new URL(page.url()).searchParams.get("mode") === "range", page.url().replace(webUrl, ""));
  check(`${tag}: report covers history from the first spend`, report.data.period === `${expected.first}:${report.data.as_of}`, report.data.period);
  check(`${tag}: qualifying spend equals every Travel Card spend`, Math.abs(report.data.totals.spend - expected.spend) < 0.005, { report: report.data.totals.spend, ledger: expected.spend });
  const figure = await page.locator(".rw-hero-figures").innerText();
  check(`${tag}: hero shows non-zero spend`, !/Qualifying spend\s*\$0\.00/i.test(figure), figure.replace(/\s+/g, " "));
}

// Card periods must still return to the card-period view.
await page.setViewportSize({ width: 1440, height: 1000 });
await page.getByRole("button", { name: "Card periods" }).click();
await page.locator(".rw-hero-scope", { hasText: /^Card periods as of/ }).waitFor({ timeout: 10000 }).catch(() => {});
const scope = await page.locator(".rw-hero-scope").innerText();
check("Card periods returns to card-period view", scope.startsWith("Card periods as of"), scope);
check("Card periods drops mode from URL", !new URL(page.url()).searchParams.has("mode"), page.url().replace(webUrl, ""));
await page.screenshot({ path: join(outDir, "card-periods-after.png") });

writeFileSync(join(outDir, "results.json"), JSON.stringify({ expected, results }, null, 2));
await browser.close();
process.exit(results.every((r) => r.ok) ? 0 : 1);
