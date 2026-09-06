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
if (!source.includes("RegisterView(scope: .unapproved)")) {
  failures.push("New destination RegisterView(scope: .unapproved) is missing.");
}
const shortcutTitles = [...memberSpan("private var ledgerShortcuts").matchAll(/title: "([^"]+)"/g)].map(
  (match) => match[1],
);
if (JSON.stringify(shortcutTitles) !== JSON.stringify(["New", "Scheduled", "All"])) {
  failures.push(`Shortcut titles must be New, Scheduled, All in that order (got ${shortcutTitles.join(", ")}).`);
}
if (shortcuts.includes('title: "All Transactions"')) {
  failures.push('All shortcut title must be the one-line label "All".');
}
if (shortcuts.includes('title: "Scheduled Transactions"')) {
  failures.push("Scheduled shortcut title must not use Scheduled Transactions; that wraps on a third-width tile.");
}
if (!source.includes('"1 upcoming transaction"')) {
  failures.push("Singular upcoming copy is missing.");
}
if (!source.includes("upcoming transactions")) {
  failures.push("Plural upcoming copy is missing.");
}
if (tile.includes("if let detail = status.detail")) {
  failures.push("Shortcut tiles must not render a subtitle from status.detail.");
}
if (!tile.includes("accessibilityValue(status.detail")) {
  failures.push("Scheduled count must stay on VoiceOver via accessibilityValue.");
}
if (!source.includes('"list.bullet.rectangle"')) {
  failures.push("All Transactions icon list.bullet.rectangle is missing.");
}
if (!source.includes('"calendar.badge.clock"')) {
  failures.push("Scheduled icon calendar.badge.clock is missing.");
}
if (!source.includes('"tray"')) {
  failures.push("New icon tray is missing.");
}
if (shortcuts.includes('"sparkles"')) {
  failures.push("New shortcut must not use sparkles; that is reserved for AI features.");
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

console.log("iOS accounts shortcuts: Grid New, Scheduled, All, one-line titles, no subtitle, restack before xxLarge, no chevron, scheduled copy in LedgerShortcutStatus.");
