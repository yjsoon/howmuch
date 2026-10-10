// E2E: Export everything from web Settings, then restore the archive into a fresh stack.
import { chromium } from "playwright";
import { writeFileSync, readFileSync } from "node:fs";
const [web, out] = process.argv.slice(2);
const log = [];
const note = (line) => { log.push(line); console.log(line); };
const browser = await chromium.launch();
const context = await browser.newContext({ acceptDownloads: true, viewport: { width: 1280, height: 1000 } });
const page = await context.newPage();
await page.goto(web);
await page.getByLabel("Username").fill("verifier");
await page.getByLabel("Password").fill("howmuch-verify-15");
await page.getByLabel("Setup token").fill("howmuch-verify-bootstrap");
await page.getByRole("button", { name: "Create account" }).click();
await page.getByRole("heading", { name: "Ledger" }).waitFor({ timeout: 30000 });
note("step 1: owner created, Ledger shown");

// Synthetic hostile rows through the real API, as the signed-in owner.
const seeded = await page.evaluate(async () => {
  const call = async (path, init) => {
    const r = await fetch(path, { ...init, headers: { "content-type": "application/json", ...(init?.headers ?? {}) } });
    return { status: r.status, body: await r.json() };
  };
  const accounts = (await call("/v1/plans/local-plan/accounts")).body.data.accounts.filter((a) => !a.deleted && !a.closed);
  const cats = (await call("/v1/plans/local-plan/categories")).body.data.category_groups.flatMap((g) => g.categories).filter((c) => !c.deleted);
  const account = accounts[0];
  const body = { transactions: [
    { account_id: account.id, date: "2026-10-01", amount: -4500, payee_name: "=HYPERLINK(\"http://example.invalid\")", memo: "Lunch, \"team\"\nsecond line", category_id: cats[0].id },
    { account_id: account.id, date: "2026-10-02", amount: -30000, payee_name: "Market", subtransactions: [
      { amount: -10000, category_id: cats[0].id, memo: "veg" }, { amount: -20000, category_id: cats[1].id, memo: "fish" } ] },
  ] };
  const created = await call("/v1/plans/local-plan/transactions", { method: "POST", body: JSON.stringify(body) });
  return { status: created.status, account: account.name, ids: (created.body.data?.transactions ?? []).map((t) => t.id) };
});
note(`step 2: seeded hostile memo/payee and a split via POST /v1/plans/local-plan/transactions -> ${seeded.status}, ids ${seeded.ids.join(", ")}`);

await page.goto(`${web}/settings`);
await page.getByRole("heading", { name: "Settings" }).waitFor();
const section = page.locator("section", { has: page.locator("#settings-export-heading") });
await section.waitFor();
await section.screenshot({ path: `${out}/settings-export-section.png` });
await page.screenshot({ path: `${out}/settings-page.png`, fullPage: true });
note("step 3: Settings shows the 'Export everything' section");

const [archiveDownload] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "Download archive (JSON)" }).click()]);
const archivePath = `${out}/${archiveDownload.suggestedFilename()}`;
await archiveDownload.saveAs(archivePath);
await page.getByRole("status").filter({ hasText: "Saved halation-export-" }).waitFor();
note(`step 4: archive downloaded as ${archiveDownload.suggestedFilename()}`);

const [csvDownload] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "Download transactions (CSV)" }).click()]);
const csvPath = `${out}/${csvDownload.suggestedFilename()}`;
await csvDownload.saveAs(csvPath);
await page.getByRole("status").filter({ hasText: "Saved halation-transactions-" }).waitFor();
await section.screenshot({ path: `${out}/settings-export-saved.png` });
note(`step 5: CSV downloaded as ${csvDownload.suggestedFilename()}`);

await browser.close();
writeFileSync(`${out}/browser-steps.log`, log.join("\n") + "\n");
console.log(JSON.stringify({ archivePath, csvPath, seeded }));
