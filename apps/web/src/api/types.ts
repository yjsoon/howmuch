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
  icon: string;
  type: string | null;
  on_budget: boolean;
  closed: boolean;
  balance: number;
  cleared_balance: number;
  uncleared_balance: number;
  last_reconciled_date: string | null;
  transfer_payee_id: string | null;
  deleted: boolean;
}

export type AccountGroupSort = "manual" | "alphabetical" | "mostUsedLast30Days";

export interface CustomAccountGroup {
  id: string;
  name: string;
  account_ids: string[];
}

export interface AccountPreferences {
  favourite_account_ids: string[];
  account_order: string[];
  account_order_by_group: Record<string, string[]>;
  account_group_sorts: Record<string, AccountGroupSort>;
  custom_account_groups: CustomAccountGroup[];
}

export interface AccountPreferencesSnapshot {
  account_preferences: AccountPreferences | null;
  account_preferences_revision: number;
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
  parent_transaction_id?: string | null;
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
  transfer_account_id?: string | null;
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

export type RewardCardType = "cashback" | "miles";

export type RewardFlagColour = "red" | "orange" | "yellow" | "green" | "blue" | "purple" | "unflagged";

export interface CardSubcategory {
  id: string;
  name: string;
  flagColor: RewardFlagColour;
  rewardValue: number;
  milesBlockSize?: number | null;
  minimumSpend?: number | null;
  maximumSpend?: number | null;
  priority: number;
  active: boolean;
  excludeFromRewards?: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface SpendingTierSubcategory {
  subcategoryId: string;
  rewardValue: number;
  maximumSpend?: number | null;
}

export interface CardSpendingTier {
  id: string;
  spendThreshold: number;
  earningRate?: number | null;
  maximumSpend?: number | null;
  subcategories?: SpendingTierSubcategory[];
}

export interface CreditCard {
  id: string;
  name: string;
  issuer: string;
  type: RewardCardType;
  ynabAccountId: string;
  billingCycle?: { type: "calendar" | "billing"; dayOfMonth?: number };
  rewardPeriod?: { monthCount: number; anchorDate: string; monthlyMinimumSpend: number };
  promotionalPeriod?: { startDate?: string | null; endDate: string; description?: string };
  featured: boolean;
  earningRate?: number | null;
  earningBlockSize?: number | null;
  minimumSpend?: number | null;
  maximumSpend?: number | null;
  subcategoriesEnabled?: boolean;
  subcategories?: CardSubcategory[];
  spendingTiers?: CardSpendingTier[];
  flagNames?: Record<string, string>;
}

export interface RewardsReport {
  from: string | null;
  to: string | null;
  as_of?: string;
  period?: string;
  transaction_rewards?: Record<string, { reward: number; reward_dollars: number }>;
  group_by: "flag" | "payee" | "category" | "memo";
  miles_valuation: number;
  totals: {
    spend: number;
    reward_dollars: number;
    cashback: number;
    miles: number;
  };
  cards: Array<{
    card: {
      id: string;
      name: string;
      issuer: string;
      type: "cashback" | "miles";
      ynabAccountId: string;
      featured: boolean;
    };
    account_id: string;
    account_name: string;
    calculation: {
      period: string;
      periods?: Array<{ start: string; end: string; calculation: Omit<RewardsReport["cards"][number]["calculation"], "periods"> }>;
      qualification_status?: "not_required" | "met" | "pending" | "failed";
      monthly_qualifications?: Array<{ start: string; end: string; spend: number; minimumSpend: number; status: "met" | "pending" | "failed" }>;
      monthly_minimum_spend?: number | null;
      active_spending_tier_id?: string | null;
      has_next_spending_tier?: boolean;
      next_spending_tier_id?: string | null;
      next_spending_tier_threshold?: number | null;
      should_stop_using?: boolean;
      total_spend: number;
      counted_spend: number;
      eligible_spend: number;
      reward_earned: number;
      reward_earned_dollars: number;
      reward_type: "cashback" | "miles";
      minimum_spend: number | null;
      minimum_spend_met: boolean;
      minimum_spend_progress: number | null;
      maximum_spend: number | null;
      maximum_spend_exceeded: boolean;
      maximum_spend_progress: number | null;
      flags: Array<{
        subcategoryId: string;
        name: string;
        flagColor: string;
        totalSpend: number;
        eligibleSpend: number;
        rewardEarned: number;
        rewardEarnedDollars?: number;
        rewardRate?: number;
      }>;
    };
  }>;
  groups: Array<{
    key: string;
    label: string;
    flag_color: string | null;
    spend: number;
    reward: number;
    reward_dollars: number;
    transaction_count: number;
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
