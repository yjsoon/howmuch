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

if (!register.includes("Upcoming") && !register.includes("upcoming")) {
  failures.push("RegisterView has no Upcoming partition; future-dated rows render as ordinary current sections.");
}

if (register.includes("MoneyCodec.displayString(for: account.balance")
  && !register.includes("asOfToday")
  && !register.includes("currentBalance")) {
  failures.push("Account register headline still displays account.balance, which includes future-dated rows.");
}

if (!current.includes("asOfTodayBalance") || !current.includes("partitionDates")) {
  failures.push("RegisterCurrent.swift is missing the as-of-today balance or Upcoming date split.");
}

if (!pbxproj.includes("RegisterCurrent.swift")) {
  failures.push("RegisterCurrent.swift is not in the Xcode target.");
}

if (failures.length) {
  console.error("iOS future-dated register is blocked:");
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}

console.log("iOS future-dated register: focused-account horizon, Upcoming partition, as-of-today headline.");
