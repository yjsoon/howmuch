export type ClearedState = "cleared" | "uncleared" | "reconciled";

export type TransactionInput = {
  id?: string;
  account_id: string;
  date: string;
  amount: number;
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
  includeDeleted?: boolean;
};

export type ReportFilters = {
  from?: string | null;
  to?: string | null;
  accountIds?: string[];
  categoryIds?: string[];
  categoryGroupIds?: string[];
  payeeIds?: string[];
  includeTransfers?: boolean;
  interval?: "day" | "week" | "month" | "year";
};

