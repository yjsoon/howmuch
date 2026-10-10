// E2E: the archive carries the signed-in user's account organisation and Rewards cards.
import { chromium } from "playwright";
import { readFileSync, appendFileSync } from "node:fs";
const [web, out] = process.argv.slice(2);
const browser = await chromium.launch();
const context = await browser.newContext({ acceptDownloads: true });
const page = await context.newPage();
await page.goto(web);
await page.getByLabel("Username").fill("verifier");
await page.getByLabel("Password").fill("howmuch-verify-15");
await page.getByRole("button", { name: "Sign in" }).click();
await page.getByRole("heading", { name: "Ledger" }).waitFor({ timeout: 30000 });
const seeded = await page.evaluate(async () => {
  const call = async (path, init) => { const r = await fetch(path, { ...init, headers: { "content-type": "application/json" } }); return { status: r.status, body: await r.json() }; };
  const account = (await call("/v1/plans/local-plan/accounts")).body.data.accounts.find((a) => !a.deleted && !a.closed);
  const prefs = await call("/v1/plans/local-plan/account_preferences", { method: "PUT", body: JSON.stringify({ account_preferences: {
    favourite_account_ids: [account.id], account_order: [], account_order_by_group: {}, account_group_sorts: {}, custom_account_groups: [] }, expected_revision: 0 }) });
  const card = await call("/api/rewards/cards?plan_id=local-plan", { method: "POST", body: JSON.stringify({ card: { name: "E2E cashback", issuer: "Test", type: "cashback", ynabAccountId: account.id, earningRate: 1 } }) });
  return { account: account.id, prefs: prefs.status, card: card.status, cardId: card.body.data?.card?.id };
});
await page.goto(`${web}/settings`);
const [download] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "Download archive (JSON)" }).click()]);
const path = `${out}/with-preferences-and-rewards-${download.suggestedFilename()}`;
await download.saveAs(path);
await browser.close();
const archive = JSON.parse(readFileSync(path, "utf8"));
const okPrefs = JSON.stringify(archive.account_preferences?.favourite_account_ids) === JSON.stringify([seeded.account]);
const okCard = archive.rewards.cards.length === 1 && archive.rewards.cards[0].id === seeded.cardId && archive.rewards.cards[0].name === "E2E cashback";
const line = `extras: PUT account_preferences -> ${seeded.prefs}, POST rewards card -> ${seeded.card}; downloaded archive carries favourite_account_ids=[${archive.account_preferences?.favourite_account_ids}] (${okPrefs ? "ok" : "FAIL"}) and rewards card ${archive.rewards.cards[0]?.name} (${okCard ? "ok" : "FAIL"})`;
console.log(line);
appendFileSync(`${out}/api-checks.log`, line + "\n");
if (!okPrefs || !okCard) process.exit(1);
