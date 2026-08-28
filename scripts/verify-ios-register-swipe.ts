import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(join(root, "apps/ios/HowMuch/Views/RegisterView.swift"), "utf8");

const rowStart = source.indexOf("struct TransactionRow: View {");
if (rowStart < 0) {
  throw new Error("Could not find TransactionRow in RegisterView.swift");
}
const row = source.slice(rowStart);

const failures: string[] = [];
if (row.includes("Button(action: onChangeStatus)")) {
  failures.push("TransactionRow statusControl uses Button, which steals the trailing swipe used to delete.");
}
if (row.includes(".onTapGesture(perform: onOpen)")) {
  failures.push("TransactionRow opens with onTapGesture, which fights List swipeActions. Use Button(action: onOpen).");
}
if (!row.includes("Button(action: onOpen)")) {
  failures.push("TransactionRow must open the editor with Button(action: onOpen) so swipeActions still work.");
}
if (!source.includes(".swipeActions(edge: .trailing")) {
  failures.push("Register row lost the trailing swipe delete action.");
}

if (failures.length) {
  console.error("iOS register swipe is blocked:");
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}

console.log("iOS register swipe: TransactionRow opens with a Button and status is not a trailing Button.");
