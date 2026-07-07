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

export interface Payee {
  id: string;
  name: string;
  transfer_account_id?: string | null;
  deleted?: boolean;
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
