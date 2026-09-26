import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function memberSpan(source: string, marker: string, file: string): string {
  const start = source.indexOf(marker);
  if (start < 0) {
    throw new Error(`Could not find ${marker} in ${file}`);
  }
  const brace = source.indexOf("{", start + marker.length);
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

const iosModel = readFileSync(join(root, "apps/ios/HowMuch/AppModel.swift"), "utf8");
const iosToggle = memberSpan(iosModel, "func toggleTransactionCleared(_ transaction: Transaction)", "AppModel.swift");
const iosAwait = iosToggle.indexOf("await apiClient.updateTransactionCleared");
if (iosAwait < 0) {
  failures.push("iOS toggleTransactionCleared must still PATCH via apiClient.updateTransactionCleared.");
} else {
  const overlay = iosToggle.indexOf("clearedToggleOverlays[transaction.id]");
  if (overlay < 0 || overlay > iosAwait) {
    failures.push(
      "iOS toggleTransactionCleared must record the flipped cleared overlay before awaiting the PATCH.",
    );
  }
}
if (iosToggle.includes("isSubmitting = true")) {
  failures.push("iOS toggleTransactionCleared must not take the global isSubmitting lock; that freezes every status icon.");
}
const iosOverlay = memberSpan(iosModel, "func overlaying(_ rows: [Transaction]) -> [Transaction]", "AppModel.swift");
if (
  !iosOverlay.includes("overlayingClearedToggles(on: overlayingPendingEdits(on: rows))")
  || !iosModel.includes("overlaying(serverTransactions)")
) {
  failures.push(
    "iOS must overlay in-flight cleared flips on top of serverTransactions so refreshLedger cannot snap the icon back.",
  );
}
const iosRefresh = memberSpan(iosModel, "func refreshLedger(quiet: Bool = false)", "AppModel.swift");
if (!iosRefresh.includes("reconcileClearedToggleOverlays(")) {
  failures.push("iOS must reconcile cleared overlays after a ledger fetch so a stale snapshot cannot stick forever.");
}

const iosRow = readFileSync(join(root, "apps/ios/HowMuch/Views/RegisterView.swift"), "utf8");
const rowStart = iosRow.indexOf("struct TransactionRow: View {");
if (rowStart < 0) {
  failures.push("Could not find TransactionRow.");
} else {
  const row = iosRow.slice(rowStart);
  if (row.includes("Button(action: onChangeStatus)")) {
    failures.push("TransactionRow statusControl must stay an onTapGesture so trailing swipe-to-delete still works.");
  }
}

const webPage = readFileSync(join(root, "apps/web/src/pages/Transactions.tsx"), "utf8");
const webToggle = memberSpan(
  webPage,
  "const toggleCleared = async (transaction: Transaction, options: { refresh?: boolean } = {}): Promise<boolean> =>",
  "Transactions.tsx",
);
const webAwait = webToggle.indexOf("await api.updateTransactionCleared");
if (webAwait < 0) {
  failures.push("Web toggleCleared must still PATCH via api.updateTransactionCleared.");
} else {
  const overlay = webToggle.indexOf("setClearedOverlays");
  const replacements = webToggle.indexOf("setReplacements");
  if (overlay < 0 || overlay > webAwait) {
    failures.push(
      "Web toggleCleared must record the flipped cleared overlay before awaiting the PATCH.",
    );
  }
  if (replacements < 0 || replacements > webAwait) {
    failures.push(
      "Web toggleCleared must overlay the flipped cleared state with setReplacements before awaiting the PATCH.",
    );
  }
}
if (!webPage.includes("applyClearedOverlays(")) {
  failures.push("Web must apply cleared overlays when rendering register rows so a list refetch cannot snap the icon back.");
}
if (!webPage.includes("retainInFlightPatches(")) {
  failures.push("Web must keep in-flight cleared replacements when refreshGeneration wipes other patches.");
}
if (webPage.includes("setReplacements(new Map())")) {
  failures.push("Web must not wipe every register replacement on refresh while a cleared PATCH is in flight.");
}

if (failures.length) {
  console.error("Cleared status toggle is still waiting on the network:");
  for (const failure of failures) console.error(`  ${failure}`);
  process.exit(1);
}

console.log("Cleared status toggle: iOS and web overlay the flipped icon before the PATCH.");
