import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function memberSpan(source: string, marker: string, file: string): string {
  const start = source.indexOf(marker);
  if (start < 0) {
    throw new Error(`Could not find ${marker} in ${file}`);
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
  throw new Error(`Unbalanced braces after ${marker} in ${file}`);
}

const failures: string[] = [];

const appModel = readFileSync(join(root, "apps/ios/HowMuch/AppModel.swift"), "utf8");
const refresh = memberSpan(appModel, "func refreshLedger(quiet: Bool = false)", "AppModel.swift");

if (
  /serverTransactions = sortedUniqueTransactions\(\s*page\.transactions\s*\)/.test(refresh)
  && !refresh.includes("page.transactions + serverTransactions")
) {
  failures.push(
    "refreshLedger still replaces serverTransactions with the first page. A quiet refresh after approve or save then drops already-loaded rows, the List shrinks, and iOS clamps scroll to the top.",
  );
}

if (!refresh.includes("page.transactions + serverTransactions")) {
  failures.push(
    "Quiet refreshLedger must merge the first page into serverTransactions so a focused account's already-loaded rows stay on screen.",
  );
}

const hasMoreReset = refresh.indexOf("hasMoreTransactions = false");
const quietPhase = refresh.indexOf("if !quiet");
if (hasMoreReset >= 0 && (quietPhase < 0 || hasMoreReset < quietPhase)) {
  failures.push(
    "refreshLedger still clears hasMoreTransactions before the quiet/non-quiet split, so a mutation refresh hides Load older and resets the cursor while the first page is in flight.",
  );
}

const rootView = readFileSync(join(root, "apps/ios/HowMuch/HowMuchApp.swift"), "utf8");
if (
  /\.overlay\(alignment: \.bottom\) \{[\s\S]*?\n    \}\n    \.animation\(\.snappy, value: model\.lastSaveMessage/.test(rootView)
) {
  failures.push(
    "RootView still attaches .animation(.snappy, value: lastSaveMessage) to the TabView after the toast overlay. Approve and save set the toast in the same turn as the register mutation, so that animation rebuilds the List and looks like a scroll jump.",
  );
}

if (!rootView.includes(".animation(.snappy, value: model.lastSaveMessage?.id)")) {
  failures.push("Toast appearance still needs a scoped .animation(.snappy, value: model.lastSaveMessage?.id) on the overlay content, not the TabView.");
}

const register = readFileSync(join(root, "apps/ios/HowMuch/Views/RegisterView.swift"), "utf8");
if (register.includes('displayMode: .automatic), prompt: "Search Transactions"')) {
  failures.push(
    "RegisterView searchable still uses displayMode: .automatic. Dismissing the editor sheet restores the search drawer and jumps the List to the top. Other HowMuch lists already use .always.",
  );
}
if (!register.includes('displayMode: .always), prompt: "Search Transactions"')) {
  failures.push("RegisterView searchable must use displayMode: .always so sheet dismiss cannot retarget the search drawer.");
}

if (failures.length) {
  console.error("iOS register scroll after approve/save is blocked:");
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}

console.log("iOS register scroll: quiet ledger merge, scoped toast animation, stable search drawer.");
