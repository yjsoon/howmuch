import type { Transaction } from "../api/types";
import { categorisableRows } from "./register-bulk";

/** One request's worth; the server refuses larger batches. */
export const CATEGORY_SUGGESTION_BATCH = 25;
/** Keep a single review manageable and the Jev bill bounded. */
export const MAX_CATEGORY_SUGGESTIONS = 100;
/**
 * Below this, a suggestion is shown but not ticked for applying. A starting
 * point to tune against real corrections, not a validated threshold.
 */
export const SUGGESTION_PRESELECT_CONFIDENCE = 0.6;

export interface CategorySuggestionOption {
  category_id: string;
  category_name: string;
  group_name: string;
  probability: number;
}

export interface CategorySuggestion {
  key: string;
  suggestion: CategorySuggestionOption | null;
  confidence: number;
  alternatives: CategorySuggestionOption[];
}

export interface CategorySuggestionRequestItem {
  key: string;
  payee_id: string | null;
  payee_name: string | null;
  memo: string | null;
  amount: number;
  date: string;
  account_name: string | null;
}

export interface SuggestionReviewRow {
  transaction: Transaction;
  suggestion: CategorySuggestion | null;
  categoryId: string;
  include: boolean;
}

/** Rows Jev can usefully judge: categorisable, and with a payee or memo to read. */
export function suggestionTargets(rows: readonly Transaction[]): Transaction[] {
  return categorisableRows(rows)
    .filter((txn) => Boolean(txn.payee_name?.trim() || txn.memo?.trim()))
    .slice(0, MAX_CATEGORY_SUGGESTIONS);
}

export function suggestionRequestItems(rows: readonly Transaction[]): CategorySuggestionRequestItem[] {
  return rows.map((txn) => ({
    key: txn.id,
    payee_id: txn.payee_id,
    payee_name: txn.payee_name,
    memo: txn.memo,
    amount: txn.amount,
    date: txn.date,
    account_name: txn.account_name,
  }));
}

/**
 * A confident suggestion that changes the row is ticked; everything else is
 * shown for the user to decide. Nothing is applied until they confirm.
 */
export function reviewRows(rows: readonly Transaction[], suggestions: readonly CategorySuggestion[]): SuggestionReviewRow[] {
  const byKey = new Map(suggestions.map((suggestion) => [suggestion.key, suggestion]));
  return rows.map((transaction) => {
    const suggestion = byKey.get(transaction.id) ?? null;
    const categoryId = suggestion?.suggestion?.category_id ?? transaction.category_id ?? "";
    const include = Boolean(suggestion?.suggestion)
      && suggestion!.confidence >= SUGGESTION_PRESELECT_CONFIDENCE
      && categoryId !== (transaction.category_id ?? "");
    return { transaction, suggestion, categoryId, include };
  });
}

export function appliedReviewItems(rows: readonly SuggestionReviewRow[]): Array<{ id: string; category_id: string }> {
  return rows
    .filter((row) => row.include && row.categoryId && row.categoryId !== (row.transaction.category_id ?? ""))
    .map((row) => ({ id: row.transaction.id, category_id: row.categoryId }));
}
