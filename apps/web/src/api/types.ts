export type Interval = "day" | "week" | "month" | "year";

export interface Plan {
  id: string;
  name: string;
}

export interface CurrencyFormat {
  iso_code?: string;
  decimal_digits?: number;
  decimal_separator?: string;
  group_separator?: string;
  currency_symbol?: string;
  symbol_first?: boolean;
  display_symbol?: boolean;
}

export interface PlanSettings {
  date_format?: { format?: string };
  currency_format?: CurrencyFormat;
  display?: { flag_names?: Record<string, string> };
}

export interface Account {
  id: string;
  name: string;
  type: string | null;
  on_budget: boolean;
  closed: boolean;
  balance: number;
  cleared_balance: number;
  uncleared_balance: number;
  transfer_payee_id: string | null;
  deleted: boolean;
}

export interface CategoryGroup {
  id: string;
  name: string;
  hidden?: boolean;
  deleted?: boolean;
  categories: Category[];
}

export interface Category {
  id: string;
  category_group_id: string;
  name: string;
  hidden?: boolean;
  deleted?: boolean;
}

/** Monthly envelope data imported from YNAB, with local assignments overlaid. All amounts are milliunits. */
export interface PlanMonthCategory {
  id: string;
  name: string;
  category_group_id: string;
  hidden?: boolean;
  original_category_group_id?: string | null;
  note?: string | null;
  budgeted?: number | null;
  source_budgeted?: number | null;
  assignment_source?: string | null;
  activity?: number | null;
  balance?: number | null;
  goal_type?: string | null;
  goal_day?: number | null;
  goal_cadence?: number | null;
  goal_cadence_frequency?: number | null;
  goal_creation_month?: string | null;
  goal_target?: number | null;
  goal_target_month?: string | null;
  goal_percentage_complete?: number | null;
  goal_months_to_budget?: number | null;
  goal_under_funded?: number | null;
  goal_overall_funded?: number | null;
  goal_overall_left?: number | null;
  goal_needed_for_spending?: number | null;
  goal_needs_whole_amount?: boolean | null;
  target_source?: string | null;
  deleted?: boolean;
}

export interface PlanMonth {
  month: string;
  note?: string | null;
  income?: number | null;
  budgeted?: number | null;
  activity?: number | null;
  to_be_budgeted?: number | null;
  age_of_money?: number | null;
  deleted?: boolean;
  categories: PlanMonthCategory[];
}

export interface Payee {
  id: string;
  name: string;
  transfer_account_id?: string | null;
  deleted?: boolean;
}

/** A read-only future transaction imported from YNAB, in integer milliunits. */
export interface ScheduledSubtransaction {
  id: string;
  scheduled_transaction_id?: string;
  amount: number;
  payee_id?: string | null;
  payee_name?: string | null;
  category_id?: string | null;
  category_name?: string | null;
  memo?: string | null;
  transfer_account_id?: string | null;
}

export interface ScheduledTransaction {
  id: string;
  date_first?: string | null;
  date_next?: string | null;
  frequency?: string | null;
  amount?: number | null;
  payee_id?: string | null;
  payee_name?: string | null;
  category_id?: string | null;
  category_name?: string | null;
  account_id?: string | null;
  account_name?: string | null;
  transfer_account_id?: string | null;
  memo?: string | null;
  flag_color?: string | null;
  deleted?: boolean;
  subtransactions?: ScheduledSubtransaction[];
}

/** Writable scheduled-transaction shape. Amounts are integer milliunits. */
export interface ScheduledTransactionInput {
  id?: string;
  account_id: string;
  date_first: string;
  date_next?: string | null;
  frequency: string;
  amount: number;
  payee_id?: string | null;
  category_id?: string | null;
  transfer_account_id?: string | null;
  memo?: string | null;
  flag_color?: string | null;
  subtransactions?: Array<{
    id?: string;
    amount: number;
    payee_id?: string | null;
    category_id?: string | null;
    transfer_account_id?: string | null;
    memo?: string | null;
  }>;
}

/** The authoritative result of entering one scheduled occurrence into the ledger. */
export interface ScheduledOccurrenceResult {
  transaction: Transaction;
  scheduled_transaction: ScheduledTransaction;
  occurrence_date: string;
  entered_date: string;
  completed: boolean;
  replayed: boolean;
}

export interface AccountReconciliationResult {
  account: Account;
  reconciled_transaction_ids: string[];
  reconciled_transaction_count: number;
  statement_date: string;
  statement_balance: number;
  prior_reconciled_balance: number;
  final_reconciled_balance: number;
  replayed: boolean;
  server_knowledge: number;
}

/** A non-mutating projection used to review an account reconciliation. */
export interface AccountReconciliationPreview {
  account: Account;
  statement_date: string;
  current_reconciled_balance: number;
  projected_reconciled_balance: number;
  candidate_transaction_ids: string[];
  candidate_transaction_count: number;
  server_knowledge: number;
}

export interface ReconciliationMismatchDetail {
  name: "reconciliation_mismatch";
  current_reconciled_balance: number;
  projected_reconciled_balance: number;
  statement_balance: number;
  difference: number;
}

export interface Subtransaction {
  id: string;
  amount: number;
  payee_id: string | null;
  payee_name?: string | null;
  category_id: string | null;
  category_name?: string | null;
  memo: string | null;
  transfer_account_id?: string | null;
  transfer_transaction_id?: string | null;
  deleted: boolean;
}

export interface Transaction {
  id: string;
  date: string;
  amount: number;
  memo: string | null;
  cleared: string;
  approved: boolean;
  flag_color: string | null;
  flag_name: string | null;
  account_id: string;
  account_name: string | null;
  payee_id: string | null;
  payee_name: string | null;
  category_id: string | null;
  category_name: string | null;
  transfer_account_id: string | null;
  transfer_transaction_id: string | null;
  deleted: boolean;
  subtransactions?: Subtransaction[];
}

/**
 * The editable subset of a ledger transaction. Amounts are integer
 * milliunits, matching the V1 ledger API.
 */
export interface TransactionUpdateInput {
  date?: string;
  amount?: number;
  memo?: string | null;
  cleared?: "cleared" | "uncleared" | "reconciled";
  approved?: boolean;
  flag_color?: string | null;
  flag_name?: string | null;
  payee_id?: string | null;
  payee_name?: string | null;
  category_id?: string | null;
  subtransactions?: Array<{
    id: string;
    amount: number;
    payee_id?: string | null;
    payee_name?: string | null;
    category_id?: string | null;
    memo?: string | null;
    transfer_account_id?: string | null;
    transfer_transaction_id?: string | null;
  }>;
}

export interface SpendingBreakdownReport {
  total: number;
  groups: Array<{
    category_id: string;
    category_name: string;
    category_group_id: string;
    category_group_name: string;
    amount: number;
    share: number;
    transaction_count: number;
  }>;
}

export interface IncomeVsSpendingReport {
  interval: Interval;
  periods: Array<{
    period: string;
    income: number;
    spending: number;
    net: number;
    cumulative_net: number;
  }>;
}

export interface NetWorthReport {
  periods: Array<{
    period: string;
    end_date: string;
    net_worth: number;
    accounts: Array<{
      account_id: string;
      account_name: string;
      balance: number;
    }>;
  }>;
}

export interface AgeOfMoneyReport {
  interval: Interval;
  periods: Array<{
    period: string;
    age_of_money_days: number | null;
    spent: number;
    unmatched_spending: number;
  }>;
}

export interface QuickEntrySplitLine {
  amount: string;
  category_id: string | null;
  memo?: string | null;
}

export interface QuickEntryInput {
  client_id: string;
  account_id: string;
  date: string;
  amount: string;
  payee_id?: string | null;
  payee_name?: string | null;
  category_id: string | null;
  memo: string | null;
  flag_color: string | null;
  subtransactions?: QuickEntrySplitLine[];
}
