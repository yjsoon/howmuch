export type ClearedState = "cleared" | "uncleared" | "reconciled";

export type AccountPreferences = {
  favourite_account_ids: string[];
  account_order: string[];
  account_order_by_group: Record<string, string[]>;
  account_group_sorts: Record<string, "manual" | "alphabetical" | "mostUsedLast30Days">;
  custom_account_groups: Array<{ id: string; name: string; account_ids: string[] }>;
};

export type AccountPreferencesSnapshot = {
  account_preferences: AccountPreferences | null;
  account_preferences_revision: number;
};

export type TransactionInput = {
  id?: string;
  account_id: string;
  date: string;
  amount: number;
  deleted?: boolean | null;
  payee_id?: string | null;
  payee_name?: string | null;
  category_id?: string | null;
  memo?: string | null;
  cleared?: ClearedState | null;
  approved?: boolean | null;
  flag_color?: string | null;
  flag_name?: string | null;
  transfer_account_id?: string | null;
  transfer_transaction_id?: string | null;
  matched_transaction_id?: string | null;
  import_id?: string | null;
  import_payee_name?: string | null;
  import_payee_name_original?: string | null;
  source_kind?: string | null;
  source_ref?: string | null;
  external_ynab_id?: string | null;
  subtransactions?: SubtransactionInput[];
};

export type SubtransactionInput = {
  id?: string;
  amount: number;
  payee_id?: string | null;
  payee_name?: string | null;
  category_id?: string | null;
  memo?: string | null;
  transfer_account_id?: string | null;
  transfer_transaction_id?: string | null;
  external_ynab_id?: string | null;
};

export type TransactionFilters = {
  sinceDate?: string | null;
  untilDate?: string | null;
  accountId?: string | null;
  payeeId?: string | null;
  categoryId?: string | null;
  month?: string | null;
  type?: string | null;
  lastKnowledgeOfServer?: number | null;
  includeDeleted?: boolean;
  limit?: number | null;
  offset?: number | null;
};

export const DEFAULT_TRANSACTION_PAGE_SIZE = 100;
export const MAX_TRANSACTION_PAGE_SIZE = 250;
export const MAX_TRANSACTION_WRITE_BATCH = 100;

export type NonEmpty<T> = [T, ...T[]];

export type TransactionLookup =
  | { readonly kind: "id"; readonly id: string }
  | { readonly kind: "import_id"; readonly importId: string };

export type TransactionFieldPatch = Omit<Partial<TransactionInput>, "id" | "import_id" | "deleted">;

export type TransactionBatchUpdate = {
  readonly lookup: TransactionLookup;
  readonly patch: TransactionFieldPatch;
};

export type TransactionBatchResult = {
  transaction_ids: string[];
  transactions: any[];
  duplicate_import_ids: string[];
  server_knowledge: number;
};

export type TransactionPage = {
  transactions: any[];
  has_more: boolean;
  next_offset: number | null;
};

/**
 * A HowMuch-owned monthly target. `null` removes the imported target from the
 * response projection; omitting a row restores the exact imported target.
 */
export type MonthCategoryTargetInput = {
  goal_type: "TB" | "TBD" | "MF" | "NEED" | "DEBT" | null;
  goal_target?: number | null;
  goal_target_month?: string | null;
};

export type ScheduledSubtransactionInput = {
  id?: string;
  amount: number;
  payee_id?: string | null;
  payee_name?: string | null;
  category_id?: string | null;
  category_name?: string | null;
  memo?: string | null;
  transfer_account_id?: string | null;
};

export type ScheduledTransactionInput = {
  id?: string;
  account_id: string;
  account_name?: string | null;
  date_first: string;
  date_next?: string | null;
  frequency: string;
  amount: number;
  payee_id?: string | null;
  payee_name?: string | null;
  category_id?: string | null;
  category_name?: string | null;
  transfer_account_id?: string | null;
  memo?: string | null;
  flag_color?: string | null;
  subtransactions?: ScheduledSubtransactionInput[];
};

export type ScheduledWriteOptions = {
  /** Stable per-client mutation key used by D1's immutable command receipt. */
  operationId?: string;
  /** Optional compare-and-set guard used while advancing a materialised occurrence. */
  expected?: {
    date_first: string;
    date_next: string;
    frequency: string;
  };
};

export type ScheduledOccurrenceResult = {
  transaction: any;
  scheduled_transaction: any;
  occurrence_date: string;
  entered_date: string;
  completed: boolean;
  replayed: boolean;
};

export type ScheduledMaterializationResult = {
  through_date: string;
  occurrences: ScheduledOccurrenceResult[];
  skipped_closed_schedule_ids: string[];
};

/** Count-only result for the private, bounded daily scheduler. */
export type ScheduledCronMaterializationResult = {
  through_date: string;
  occurrence_count: number;
  skipped_closed_schedule_count: number;
  failure_count: number;
  has_more: boolean;
};

export type AccountReconciliationOptions = {
  operationId: string;
};

export type AccountReconciliationPreview = {
  account: any;
  statement_date: string;
  current_reconciled_balance: number;
  projected_reconciled_balance: number;
  candidate_transaction_ids: string[];
  candidate_transaction_count: number;
  server_knowledge: number;
};

export type AccountReconciliationResult = {
  account: any;
  reconciled_transaction_ids: string[];
  reconciled_transaction_count: number;
  statement_date: string;
  statement_balance: number;
  prior_reconciled_balance: number;
  final_reconciled_balance: number;
  replayed: boolean;
  server_knowledge: number;
};

export type ReportFilters = {
  from?: string | null;
  to?: string | null;
  accountIds?: string[];
  categoryIds?: string[];
  categoryGroupIds?: string[];
  payeeIds?: string[];
  includeTransfers?: boolean;
  includeClosedAccounts?: boolean;
  interval?: "day" | "week" | "month" | "year";
  topPayeesLimit?: number;
  groupBy?: "flag" | "payee" | "category" | "memo";
};
