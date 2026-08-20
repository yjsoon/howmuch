import { useEffect, useRef, useState } from "react";
import type {
  Account,
  AccountReconciliationPreview,
  AccountReconciliationResult,
  AgeOfMoneyReport,
  CategoryGroup,
  IncomeVsSpendingReport,
  NetWorthReport,
  Payee,
  Plan,
  PlanMonth,
  PlanSettings,
  QuickEntryInput,
  ReconciliationMismatchDetail,
  ScheduledTransaction,
  ScheduledTransactionInput,
  ScheduledOccurrenceResult,
  SpendingBreakdownReport,
  Transaction,
  TransactionUpdateInput,
} from "./types";

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code?: string,
    readonly detail?: unknown,
  ) {
    super(message);
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    ...init,
    credentials: "same-origin",
    headers: {
      "content-type": "application/json",
      ...init?.headers,
    },
  });
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    body = undefined;
  }
  if (!response.ok) {
    const detail = (body && typeof body === "object" && "error" in body ? (body as { error?: Record<string, unknown> }).error : undefined) as (ReconciliationMismatchDetail & { detail?: string }) | undefined;
    const message = detail?.detail ?? `${response.status} ${response.statusText}`;
    throw new ApiError(message, response.status, typeof detail?.name === "string" ? detail.name : undefined, detail);
  }
  return (body as { data: T }).data;
}

function query(params: Record<string, string | number | undefined>): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== "") {
      search.set(key, String(value));
    }
  }
  const text = search.toString();
  return text ? `?${text}` : "";
}

export interface ReportQuery {
  /** Always pass the loaded plan; otherwise the API falls back to its configured default plan. */
  plan_id?: string;
  from?: string;
  to?: string;
  account_ids?: string;
  category_ids?: string;
  interval?: string;
}

export interface AuthUser {
  id: string;
  username: string;
}

export interface AuthStatus {
  setup_required: boolean;
  bootstrap_required: boolean;
  user: AuthUser | null;
}

export interface TransactionPage {
  transactions: Transaction[];
  has_more: boolean;
  next_offset: number | null;
}

export const api = {
  authStatus: () => request<AuthStatus>("/api/auth/status"),
  setup: (username: string, password: string, bootstrapToken: string) =>
    request<{ user: AuthUser }>("/api/auth/setup", {
      method: "POST",
      headers: bootstrapToken ? { authorization: `Bearer ${bootstrapToken}` } : undefined,
      body: JSON.stringify({ username, password }),
    }).then((data) => data.user),
  login: (username: string, password: string) =>
    request<{ user: AuthUser }>("/api/auth/login", {
      method: "POST",
      body: JSON.stringify({ username, password }),
    }).then((data) => data.user),
  logout: () => request<{ ok: true }>("/api/auth/logout", { method: "POST", body: "{}" }),
  plans: () => request<{ plans: Plan[] }>("/v1/plans").then((d) => d.plans),
  settings: (planId: string) =>
    request<{ settings: PlanSettings }>(`/v1/plans/${planId}/settings`).then((d) => d.settings),
  accounts: (planId: string) =>
    request<{ accounts: Account[] }>(`/v1/plans/${planId}/accounts`).then((d) => d.accounts),
  categories: (planId: string) =>
    request<{ category_groups: CategoryGroup[] }>(`/v1/plans/${planId}/categories`).then(
      (d) => d.category_groups,
    ),
  payees: (planId: string) =>
    request<{ payees: Payee[] }>(`/v1/plans/${planId}/payees`).then((d) => d.payees),
  scheduledTransactions: (planId: string) =>
    request<{ scheduled_transactions: ScheduledTransaction[] }>(`/v1/plans/${planId}/scheduled_transactions`).then(
      (d) => d.scheduled_transactions,
    ),
  createScheduledTransaction: (planId: string, scheduledTransaction: ScheduledTransactionInput, idempotencyKey: string) =>
    request<{ scheduled_transaction: ScheduledTransaction }>(
      `/v1/plans/${planId}/scheduled_transactions`,
      { method: "POST", headers: { "idempotency-key": idempotencyKey }, body: JSON.stringify({ scheduled_transaction: scheduledTransaction }) },
    ).then((data) => data.scheduled_transaction),
  updateScheduledTransaction: (planId: string, scheduledTransactionId: string, scheduledTransaction: ScheduledTransactionInput, idempotencyKey: string) =>
    request<{ scheduled_transaction: ScheduledTransaction }>(
      `/v1/plans/${planId}/scheduled_transactions/${encodeURIComponent(scheduledTransactionId)}`,
      { method: "PATCH", headers: { "idempotency-key": idempotencyKey }, body: JSON.stringify({ scheduled_transaction: scheduledTransaction }) },
    ).then((data) => data.scheduled_transaction),
  deleteScheduledTransaction: (planId: string, scheduledTransactionId: string, idempotencyKey: string) =>
    request<{ scheduled_transaction: ScheduledTransaction }>(
      `/v1/plans/${planId}/scheduled_transactions/${encodeURIComponent(scheduledTransactionId)}`,
      { method: "DELETE", headers: { "idempotency-key": idempotencyKey } },
    ).then((data) => data.scheduled_transaction),
  materializeScheduledTransaction: (planId: string, scheduledTransactionId: string, occurrenceDate: string, date: string, idempotencyKey: string) =>
    request<ScheduledOccurrenceResult>(
      `/v1/plans/${planId}/scheduled_transactions/${encodeURIComponent(scheduledTransactionId)}/materialize`,
      { method: "POST", headers: { "idempotency-key": idempotencyKey }, body: JSON.stringify({ occurrence_date: occurrenceDate, date }) },
    ),
  accountReconciliation: (planId: string, accountId: string, statementDate: string) =>
    request<AccountReconciliationPreview>(
      `/v1/plans/${planId}/accounts/${encodeURIComponent(accountId)}/reconciliation${query({ statement_date: statementDate })}`,
    ),
  reconcileAccount: (planId: string, accountId: string, statementDate: string, statementBalance: number, idempotencyKey: string) =>
    request<AccountReconciliationResult>(
      `/v1/plans/${planId}/accounts/${encodeURIComponent(accountId)}/reconcile`,
      {
        method: "POST",
        headers: { "idempotency-key": idempotencyKey },
        body: JSON.stringify({ statement_date: statementDate, statement_balance: statementBalance }),
      },
    ),
  month: (planId: string, month: string) =>
    request<{ month: PlanMonth }>(`/v1/plans/${planId}/months/${encodeURIComponent(month)}`).then(
      (d) => d.month,
    ),
  setMonthCategoryAssignment: (planId: string, month: string, categoryId: string, budgeted: number) =>
    request<{ month: PlanMonth }>(
      `/v1/plans/${planId}/months/${encodeURIComponent(month)}/categories/${encodeURIComponent(categoryId)}`,
      { method: "PATCH", body: JSON.stringify({ category: { budgeted } }) },
    ).then((d) => d.month),
  setMonthCategoryTarget: (planId: string, month: string, categoryId: string, target: { goal_type: string; goal_target: number; goal_target_month?: string | null } | null) =>
    request<{ month: PlanMonth }>(
      `/v1/plans/${planId}/months/${encodeURIComponent(month)}/categories/${encodeURIComponent(categoryId)}`,
      { method: "PATCH", body: JSON.stringify({ category: { target } }) },
    ).then((d) => d.month),
  restoreMonthCategoryTarget: (planId: string, month: string, categoryId: string) =>
    request<{ month: PlanMonth }>(
      `/v1/plans/${planId}/months/${encodeURIComponent(month)}/categories/${encodeURIComponent(categoryId)}`,
      { method: "PATCH", body: JSON.stringify({ category: { restore_target: true } }) },
    ).then((d) => d.month),
  transactions: (planId: string, params: { since_date?: string; until_date?: string; limit?: number; offset?: number }) =>
    request<TransactionPage>(
      `/v1/plans/${planId}/transactions${query(params)}`,
    ),
  accountTransactions: (planId: string, accountId: string, params: { since_date?: string; until_date?: string; limit?: number; offset?: number }) =>
    request<TransactionPage>(
      `/v1/plans/${planId}/accounts/${encodeURIComponent(accountId)}/transactions${query(params)}`,
    ),
  updateTransaction: (planId: string, transactionId: string, transaction: TransactionUpdateInput) =>
    request<{ transaction: Transaction }>(
      `/v1/plans/${planId}/transactions/${encodeURIComponent(transactionId)}`,
      { method: "PATCH", body: JSON.stringify({ transaction }) },
    ).then((data) => data.transaction),
  deleteTransaction: (planId: string, transactionId: string) =>
    request<{ transaction: Transaction }>(
      `/v1/plans/${planId}/transactions/${encodeURIComponent(transactionId)}`,
      { method: "DELETE" },
    ).then((data) => data.transaction),
  spendingBreakdown: (params: ReportQuery) =>
    request<SpendingBreakdownReport>(`/api/reports/spending-breakdown${query({ ...params })}`),
  incomeVsSpending: (params: ReportQuery) =>
    request<IncomeVsSpendingReport>(`/api/reports/income-vs-spending${query({ ...params })}`),
  netWorth: (params: ReportQuery) =>
    request<NetWorthReport>(`/api/reports/net-worth${query({ ...params })}`),
  ageOfMoney: (params: ReportQuery) =>
    request<AgeOfMoneyReport>(`/api/reports/age-of-money${query({ ...params })}`),
  quickEntry: (input: QuickEntryInput) =>
    request<{ transaction: Transaction }>("/api/mobile/quick-entry", {
      method: "POST",
      body: JSON.stringify(input),
    }).then((d) => d.transaction),
};

export interface ApiState<T> {
  data: T | null;
  loading: boolean;
  error: string | null;
}

/**
 * Fetches whenever `key` changes; stale responses are discarded so rapid
 * filter changes never paint out of order.
 */
export function useApi<T>(key: string, fetcher: () => Promise<T>): ApiState<T> {
  const [state, setState] = useState<ApiState<T>>({ data: null, loading: true, error: null });
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;

  useEffect(() => {
    let cancelled = false;
    setState((previous) => ({ ...previous, loading: true, error: null }));
    fetcherRef
      .current()
      .then((data) => {
        if (!cancelled) {
          setState({ data, loading: false, error: null });
        }
      })
      .catch((error: Error) => {
        if (!cancelled) {
          setState({ data: null, loading: false, error: error.message });
        }
      });
    return () => {
      cancelled = true;
    };
  }, [key]);

  return state;
}
