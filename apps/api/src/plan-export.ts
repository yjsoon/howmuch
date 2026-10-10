/**
 * "Export everything": one archive (`howmuch-export`, version 1) holding the
 * plan, its formats, the re-importable ledger snapshot, the caller's account
 * organisation and the Rewards configuration, plus a spreadsheet-friendly
 * CSV of every live transaction.
 *
 * The archive's `snapshot` is exactly what `export_snapshot` returns, and
 * `POST import_snapshot` reads the `snapshot` key of its body, so the archive
 * file itself can be posted to restore the ledger into an empty plan.
 */

import type { PlanSnapshot } from "./plan-snapshot";
import type { LedgerStore } from "./storage";

export const EXPORT_FORMAT = "howmuch-export";
export const EXPORT_VERSION = 1;

export type PlanExport = {
  format: typeof EXPORT_FORMAT;
  version: typeof EXPORT_VERSION;
  exported_at: string;
  plan: unknown;
  settings: unknown;
  server_knowledge: number;
  snapshot: PlanSnapshot;
  /** The caller's own account organisation; null for the shared API token or when never set. */
  account_preferences: unknown | null;
  rewards: {
    cards: unknown[];
    tracker_snapshot: unknown | null;
    imported_at: string | null;
    updated_at: string | null;
  };
};

export async function buildPlanExport(repo: LedgerStore, planId: string, userId: string | null, now = new Date()): Promise<PlanExport> {
  const [plan, settings, ledger, preferences, rewards] = await Promise.all([
    repo.getPlan(planId),
    repo.getSettings(planId),
    repo.exportPlanSnapshot(planId),
    userId ? repo.getAccountPreferences(planId, userId) : Promise.resolve(null),
    repo.getRewardsTrackerSnapshot(planId),
  ]);
  return {
    format: EXPORT_FORMAT,
    version: EXPORT_VERSION,
    exported_at: now.toISOString(),
    plan,
    settings,
    server_knowledge: ledger.server_knowledge,
    snapshot: ledger.snapshot,
    account_preferences: preferences?.account_preferences ?? null,
    rewards: {
      cards: rewards.cards,
      tracker_snapshot: rewards.snapshot,
      imported_at: rewards.imported_at,
      updated_at: rewards.updated_at,
    },
  };
}

const CSV_COLUMNS = [
  "Date", "Account", "Payee", "Category group", "Category", "Memo", "Amount",
  "Cleared", "Approved", "Flag", "Transfer account", "Transaction ID", "Split of",
];

/**
 * One row per live transaction, oldest first; a split becomes one row per
 * line (marked with its parent in "Split of") so amounts sum to the ledger.
 * Amounts are decimal in the plan currency, keeping sub-unit milliunits.
 */
export function transactionsCsv(snapshot: PlanSnapshot, options: { decimalDigits: number }): string {
  const accounts = new Map(snapshot.accounts.map((account) => [account.id, account.name]));
  const payees = new Map(snapshot.payees.map((payee) => [payee.id, payee.name]));
  const groups = new Map(snapshot.category_groups.map((group) => [group.id, group.name]));
  const categories = new Map(snapshot.categories.map((category) => [category.id, category]));
  const amount = (milli: number) => formatAmount(milli, options.decimalDigits);

  const rows: string[][] = [CSV_COLUMNS];
  const ordered = [...snapshot.transactions].sort((a, b) => a.date.localeCompare(b.date) || a.id.localeCompare(b.id));
  for (const parent of ordered) {
    const approved = parent.approved ? "yes" : "no";
    const flag = parent.flag_name ?? parent.flag_color ?? "";
    const payeeOf = (payeeId: string | null, payeeName: string | null) => (payeeId ? payees.get(payeeId) : payeeName) ?? "";
    const parentPayee = payeeOf(parent.payee_id, parent.payee_name);
    const line = (fields: {
      payee: string; categoryId: string | null; memo: string | null; milli: number;
      transferAccountId: string | null; id: string; splitOf: string;
    }) => {
      const category = fields.categoryId ? categories.get(fields.categoryId) : undefined;
      rows.push([
        parent.date,
        accounts.get(parent.account_id) ?? "",
        fields.payee,
        category ? groups.get(category.category_group_id) ?? "" : "",
        category?.name ?? "",
        fields.memo ?? "",
        amount(fields.milli),
        parent.cleared,
        approved,
        flag,
        fields.transferAccountId ? accounts.get(fields.transferAccountId) ?? "" : "",
        fields.id,
        fields.splitOf,
      ]);
    };
    if (parent.subtransactions.length === 0) {
      line({
        payee: parentPayee, categoryId: parent.category_id, memo: parent.memo, milli: parent.amount,
        transferAccountId: parent.transfer_account_id, id: parent.id, splitOf: "",
      });
      continue;
    }
    for (const sub of parent.subtransactions) {
      line({
        payee: sub.payee_id || sub.payee_name ? payeeOf(sub.payee_id, sub.payee_name) : parentPayee,
        categoryId: sub.category_id, memo: sub.memo ?? parent.memo, milli: sub.amount,
        transferAccountId: sub.transfer_account_id, id: sub.id, splitOf: parent.id,
      });
    }
  }
  // Amounts are numbers the exporter wrote, so only text columns are guarded.
  const amountColumn = CSV_COLUMNS.indexOf("Amount");
  return "﻿" + rows
    .map((row, rowIndex) => row.map((value, index) => csvField(value, rowIndex > 0 && index !== amountColumn)).join(","))
    .join("\r\n") + "\r\n";
}

function formatAmount(milli: number, decimalDigits: number): string {
  const digits = Math.min(Math.max(decimalDigits, 0), 3);
  // Keep milliunits the currency's digits cannot show rather than round them away.
  const shown = milli % 10 ** (3 - digits) === 0 ? digits : 3;
  const sign = milli < 0 ? "-" : "";
  const absolute = Math.abs(milli);
  const whole = Math.floor(absolute / 1000);
  const fraction = String(absolute % 1000).padStart(3, "0").slice(0, shown);
  return `${sign}${whole}${shown > 0 ? `.${fraction}` : ""}`;
}

/** Quotes per RFC 4180; text a spreadsheet would run as a formula gets a leading apostrophe. */
function csvField(value: string, isText: boolean): string {
  const safe = isText && /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
  return /[",\r\n]/.test(safe) ? `"${safe.replaceAll("\"", "\"\"")}"` : safe;
}
