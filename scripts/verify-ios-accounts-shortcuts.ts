import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(join(root, "apps/ios/HowMuch/Views/AccountsView.swift"), "utf8");

function memberSpan(marker: string): string {
  const start = source.indexOf(marker);
  if (start < 0) {
    throw new Error(`Could not find ${marker} in AccountsView.swift`);
  }
  const brace = source.indexOf("{", start);
  if (brace < 0) {
    throw new Error(`Could not find opening brace after ${marker}`);
  }
  let depth = 0;
  for (let i = brace; i < source.length; i++) {
    const ch = source[i];
    if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`Unbalanced braces after ${marker}`);
}

const shortcuts = [
  memberSpan("private var ledgerShortcuts"),
  memberSpan("private enum LedgerShortcutStatus"),
  memberSpan("private struct LedgerShortcutTile"),
].join("\n");
const tile = memberSpan("private struct LedgerShortcutTile");

const failures: string[] = [];
if (!source.includes("static func scheduled(phase:") || !source.includes("LedgerShortcutStatus.scheduled(")) {
  failures.push("LedgerShortcutStatus.scheduled is missing; scheduled copy must have a single home.");
}
if (!source.includes("RegisterView(scope: .all)")) {
  failures.push("All Transactions destination RegisterView(scope: .all) is missing.");
}
if (!source.includes("ScheduledTransactionsView()")) {
  failures.push("Scheduled destination ScheduledTransactionsView() is missing.");
}
if (!source.includes('"1 upcoming transaction"')) {
  failures.push("Singular upcoming copy is missing.");
}
if (!source.includes("upcoming transactions")) {
  failures.push("Plural upcoming copy is missing.");
}
if (!source.includes('"list.bullet.rectangle"')) {
  failures.push("All Transactions icon list.bullet.rectangle is missing.");
}
if (!source.includes('"calendar.badge.clock"')) {
  failures.push("Scheduled icon calendar.badge.clock is missing.");
}
if (shortcuts.includes("chevron.right")) {
  failures.push("Shortcut tiles must not include chevron.right.");
}
if (tile.includes("lineLimit")) {
  failures.push("LedgerShortcutTile must not use lineLimit.");
}
if (!source.includes("usesColumnShortcuts") && !source.includes("dynamicTypeSize < .xxLarge")) {
  failures.push("Column restack must use usesColumnShortcuts or dynamicTypeSize < .xxLarge.");
}
if (!source.includes("GridRow")) {
  failures.push("Shortcut pair must use Grid (GridRow is missing).");
}

if (failures.length) {
  console.error("iOS accounts shortcuts are blocked:");
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}

console.log("iOS accounts shortcuts: Grid pair, restack before xxLarge, no chevron, scheduled copy in LedgerShortcutStatus.");
