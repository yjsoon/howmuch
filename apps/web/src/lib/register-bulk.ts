import type { TransactionBulkSummary } from "../api/client";
import type { Transaction } from "../api/types";

/**
 * Rows the collection PATCH can categorise without a side effect. A split
 * parent carries its category on its lines, a transfer leg is owned by the
 * paired side, and a split-linked mirror belongs to its parent — the server
 * would drop or re-route a category sent for any of them, so they never enter
 * the bulk categorise request.
 */
export function categorisableRows(rows: readonly Transaction[]): Transaction[] {
  return rows.filter((txn) => !txn.transfer_account_id && !txn.parent_transaction_id && !(txn.subtransactions?.length));
}

/** Rows whose dedicated cleared toggle would actually change something. */
export function clearedTargets(
  rows: readonly Transaction[],
  cleared: "cleared" | "uncleared",
): Transaction[] {
  return rows.filter((txn) => txn.cleared !== "reconciled" && txn.cleared !== cleared);
}

/**
 * Ids a bulk command still owns: unresolved (may have landed) and never-sent.
 * `already_removed` is deliberately excluded — the row is gone, so there is
 * nothing left to retry.
 */
export function remainingWorkIds(summary: Pick<TransactionBulkSummary, "outcomes">): string[] {
  return summary.outcomes
    .filter((outcome) => outcome.status === "unresolved" || outcome.status === "unattempted")
    .map((outcome) => outcome.id);
}

/**
 * Whether every requested row reached a settled state. `already_removed` is
 * settled — the row is gone, and this command makes no claim about who removed
 * it — so it does not count as outstanding work. False means the server state is
 * the only trustworthy view, so the caller must refetch rather than patching
 * rows locally.
 */
export function bulkOutcomeIsComplete(summary: TransactionBulkSummary): boolean {
  return summary.unresolved_count === 0
    && summary.conflict_count === 0
    && summary.unattempted_count === 0;
}

/**
 * Copy for a bulk command that reports confirmed, already-removed, uncertain,
 * and skipped rows separately. It never claims a clean zero after an uncertain
 * request, and it never presents a row this command did not write as its work.
 */
export function bulkOutcomeToast(label: string, summary: TransactionBulkSummary): string {
  const confirmed = summary.applied_count;
  const alreadyRemoved = summary.already_removed_count;
  const uncertain = summary.unresolved_count;
  const skipped = summary.conflict_count + summary.unattempted_count;
  const sentences: string[] = [];
  if (confirmed > 0) {
    sentences.push(`${label} ${confirmed} transaction${confirmed === 1 ? "" : "s"}.`);
  }
  if (alreadyRemoved > 0) {
    sentences.push(`${alreadyRemoved} transaction${alreadyRemoved === 1 ? " was" : "s were"} already removed.`);
  }
  if (uncertain > 0) {
    sentences.push(`${uncertain} transaction${uncertain === 1 ? "" : "s"} may or may not have been updated.`);
  }
  if (skipped > 0) {
    sentences.push(skipped === 1
      ? "1 transaction was not updated."
      : `${skipped} transactions were not updated.`);
  }
  if (sentences.length === 0) {
    sentences.push(`${label} no transactions.`);
  }
  return sentences.join(" ");
}

export type BulkWriteKind = "categorise" | "cleared" | "delete";

/**
 * Whether a completed bulk register write can move the reconciliation preview.
 * Its candidate set is the live `cleared` rows in an account up to the statement
 * date, so clearing, unclearing, and deleting rows change it; a category change
 * does not.
 */
export function bulkWriteTouchesReconciliation(kind: BulkWriteKind): boolean {
  return kind === "cleared" || kind === "delete";
}

export type BulkDeleteFollowUp = {
  /** Rows still unsettled, to keep selected for a fresh confirmation. */
  readonly retryIds: readonly string[];
  readonly complete: boolean;
};

/**
 * How the register must treat a bulk delete's confirmation dialog afterwards.
 *
 * The dialog's rows are a snapshot taken before the command ran, so it is never
 * reused: a row it holds may have been removed, approved, or edited on the
 * server since. Every outcome closes it. Rows the command never settled stay
 * selected so a retry starts from a fresh selection and a new confirmation —
 * never an automatic replay of the old one.
 */
export function bulkDeleteFollowUp(summary: TransactionBulkSummary): BulkDeleteFollowUp {
  const complete = bulkOutcomeIsComplete(summary);
  return {
    retryIds: complete ? [] : remainingWorkIds(summary),
    complete,
  };
}
