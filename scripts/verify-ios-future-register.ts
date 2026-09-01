import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const horizon = readFileSync(join(root, "apps/ios/HowMuch/Support/RegisterHorizon.swift"), "utf8");
const current = readFileSync(join(root, "apps/ios/HowMuch/Support/RegisterCurrent.swift"), "utf8");
const appModel = readFileSync(join(root, "apps/ios/HowMuch/AppModel.swift"), "utf8");
const apiClient = readFileSync(join(root, "apps/ios/HowMuch/Services/APIClient.swift"), "utf8");
const register = readFileSync(join(root, "apps/ios/HowMuch/Views/RegisterView.swift"), "utf8");
const pbxproj = readFileSync(join(root, "apps/ios/HowMuch.xcodeproj/project.pbxproj"), "utf8");

const failures: string[] = [];

if (!horizon.includes("coverageOldestDate") || !horizon.includes("accountID")) {
  failures.push("RegisterHorizon fill coverage still ignores the focused account; a busy plan-wide first page can hide that account's last two months.");
}

if (appModel.includes("oldestLoadedDate: serverTransactions.map(\\ .date).min()")
  || appModel.includes("oldestLoadedDate: serverTransactions.map(\\.date).min()")) {
  failures.push("refreshLedger still measures the horizon against every loaded plan row instead of the focused account.");
}

if (!appModel.includes("fillFocusedAccountHorizon") || !apiClient.includes("/accounts/\\($0)/transactions")) {
  failures.push("Focused account fill still uses the plan-wide transactions cursor instead of the account-scoped page.");
}

if (!appModel.includes("accountID: nil") || !appModel.includes("await fillFocusedAccountHorizon(generation:")) {
  failures.push("refreshLedger skips the plan-wide two-month fill when an account is focused, dropping other accounts' loaded history.");
}

if (/defer \{\s*popHorizonFill\(\)\s*\}/.test(appModel)) {
  failures.push("refreshLedger defer pops the horizon fill without a generation guard, so a stale refresh can clear a newer fill.");
}

if (!appModel.includes("olderTransactionsError = error.localizedDescription")
  || !appModel.includes("retryIncompleteRegisterFill")
  || !register.includes("retryIncompleteRegisterFill")) {
  failures.push("Focused account fill still swallows fetch errors with no Try Again path.");
}

if (!appModel.includes("olderTransactionsError = nil\n\n    let horizon = RegisterHorizon.standard")
  && !appModel.includes("olderTransactionsError = nil\n    let horizon = RegisterHorizon.standard")) {
  failures.push("Focused account fill never clears a stale load error after a later successful fill.");
}

if (!register.includes("including posted scheduled") || !register.includes("showsScheduledBand")) {
  failures.push("RegisterView has no Scheduled partition; future-dated rows render as ordinary current sections.");
}

if (register.includes("toggleScheduledExpanded") || register.includes("scheduledDisclosureSection")) {
  failures.push("Recurring schedules still live in a separate collapsed disclosure instead of the Scheduled date list.");
}

if (!register.includes("visibleSchedules") || !register.includes("scheduledDateSections")) {
  failures.push("Posted futures and recurrences are not one Scheduled date list.");
}

if (!register.includes("dateNext > today") || !register.includes("region.rawValue")) {
  failures.push("Due-today schedules still share a date id with the current register and can split that day.");
}

if (!register.includes("Opens this scheduled transaction.") || !register.includes("allowsFullSwipe: false")) {
  failures.push("Schedule rows still have no editor hint or isolated swipe actions.");
}

if (register.includes("MoneyCodec.displayString(for: account.balance")
  && !register.includes("asOfToday")
  && !register.includes("currentBalance")) {
  failures.push("Account register headline still displays account.balance, which includes future-dated rows.");
}

if (!current.includes("asOfTodayBalance") || !current.includes("partitionDates")) {
  failures.push("RegisterCurrent.swift is missing the as-of-today balance or future-dated date split.");
}

if (!pbxproj.includes("RegisterCurrent.swift")) {
  failures.push("RegisterCurrent.swift is not in the Xcode target.");
}

if (failures.length) {
  console.error("iOS future-dated register is blocked:");
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}

console.log("iOS future-dated register: focused-account horizon, unified Scheduled list, as-of-today headline.");
