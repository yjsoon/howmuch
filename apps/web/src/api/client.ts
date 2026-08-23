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

let onUnauthorized: (() => void) | null = null;
let requestEpoch = 0;

/** Register a handler for expired sessions on authenticated endpoints. */
export function setUnauthorizedHandler(handler: (() => void) | null): void {
  onUnauthorized = handler;
}

/** Invalidate in-flight 401s from a previous session after login or reload. */
export function bumpRequestEpoch(): number {
  requestEpoch += 1;
  return requestEpoch;
}

export function shouldHandleUnauthorized(path: string, startedEpoch: number, currentEpoch = requestEpoch): boolean {
  const requiresSession = path === "/api/auth/personal-tokens"
    || path.startsWith("/api/auth/personal-tokens/");
  return (!path.startsWith("/api/auth/") || requiresSession) && startedEpoch === currentEpoch;
}

function planUrl(planId: string, ...segments: string[]): string {
  return `/v1/plans/${[planId, ...segments].map(encodeURIComponent).join("/")}`;
}

function requestHeaders(init?: RequestInit): Headers {
  const headers = new Headers(init?.headers);
  if (init?.body != null && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }
  return headers;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const startedEpoch = requestEpoch;
  const response = await fetch(path, {
    ...init,
    credentials: "same-origin",
    headers: requestHeaders(init),
  });
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    body = undefined;
  }
  if (!response.ok) {
    if (response.status === 401 && shouldHandleUnauthorized(path, startedEpoch)) {
      bumpRequestEpoch();
      onUnauthorized?.();
    }
    const detail = (body && typeof body === "object" && "error" in body ? (body as { error?: Record<string, unknown> }).error : undefined) as (ReconciliationMismatchDetail & { detail?: string }) | undefined;
    const message = detail?.detail ?? `${response.status} ${response.statusText}`;
    throw new ApiError(message, response.status, typeof detail?.name === "string" ? detail.name : undefined, detail);
  }
  if (!body || typeof body !== "object" || !("data" in body)) {
    throw new ApiError("Unexpected response from the HowMuch API", response.status);
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

export interface PersonalApiToken {
  id: string;
  name: string;
  created_at: number;
  revoked_at: number | null;
}

export interface CreatedPersonalApiToken {
  token: PersonalApiToken;
  value: string;
}

export interface TransactionPage {
  transactions: Transaction[];
  has_more: boolean;
  next_offset: number | null;
  server_knowledge: number;
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
  personalApiTokens: () =>
    request<{ tokens: PersonalApiToken[] }>("/api/auth/personal-tokens").then((data) => data.tokens),
  createPersonalApiToken: (name: string) =>
    request<CreatedPersonalApiToken>("/api/auth/personal-tokens", {
      method: "POST",
      body: JSON.stringify({ name }),
    }),
  revokePersonalApiToken: (id: string) =>
    request<{ token: PersonalApiToken }>(`/api/auth/personal-tokens/${encodeURIComponent(id)}`, {
      method: "DELETE",
    }).then((data) => data.token),
  plans: () => request<{ plans: Plan[] }>("/v1/plans").then((d) => d.plans),
  settings: (planId: string) =>
    request<{ settings: PlanSettings }>(planUrl(planId, "settings")).then((d) => d.settings),
  accounts: (planId: string) =>
    request<{ accounts: Account[] }>(planUrl(planId, "accounts")).then((d) => d.accounts),
  categories: (planId: string) =>
    request<{ category_groups: CategoryGroup[] }>(planUrl(planId, "categories")).then(
      (d) => d.category_groups,
    ),
  payees: (planId: string) =>
    request<{ payees: Payee[] }>(planUrl(planId, "payees")).then((d) => d.payees),
  scheduledTransactions: (planId: string) =>
    request<{ scheduled_transactions: ScheduledTransaction[] }>(planUrl(planId, "scheduled_transactions")).then(
      (d) => d.scheduled_transactions,
    ),
  createScheduledTransaction: (planId: string, scheduledTransaction: ScheduledTransactionInput, idempotencyKey: string) =>
    request<{ scheduled_transaction: ScheduledTransaction }>(
      planUrl(planId, "scheduled_transactions"),
      { method: "POST", headers: { "idempotency-key": idempotencyKey }, body: JSON.stringify({ scheduled_transaction: scheduledTransaction }) },
    ).then((data) => data.scheduled_transaction),
  updateScheduledTransaction: (planId: string, scheduledTransactionId: string, scheduledTransaction: ScheduledTransactionInput, idempotencyKey: string) =>
    request<{ scheduled_transaction: ScheduledTransaction }>(
      planUrl(planId, "scheduled_transactions", scheduledTransactionId),
      { method: "PATCH", headers: { "idempotency-key": idempotencyKey }, body: JSON.stringify({ scheduled_transaction: scheduledTransaction }) },
    ).then((data) => data.scheduled_transaction),
  deleteScheduledTransaction: (planId: string, scheduledTransactionId: string, idempotencyKey: string) =>
    request<{ scheduled_transaction: ScheduledTransaction }>(
      planUrl(planId, "scheduled_transactions", scheduledTransactionId),
      { method: "DELETE", headers: { "idempotency-key": idempotencyKey } },
    ).then((data) => data.scheduled_transaction),
  materializeScheduledTransaction: (planId: string, scheduledTransactionId: string, occurrenceDate: string, date: string, idempotencyKey: string) =>
    request<ScheduledOccurrenceResult>(
      planUrl(planId, "scheduled_transactions", scheduledTransactionId, "materialize"),
      { method: "POST", headers: { "idempotency-key": idempotencyKey }, body: JSON.stringify({ occurrence_date: occurrenceDate, date }) },
    ),
  accountReconciliation: (planId: string, accountId: string, statementDate: string) =>
    request<AccountReconciliationPreview>(
      `${planUrl(planId, "accounts", accountId, "reconciliation")}${query({ statement_date: statementDate })}`,
    ),
  reconcileAccount: (planId: string, accountId: string, statementDate: string, statementBalance: number, idempotencyKey: string) =>
    request<AccountReconciliationResult>(
      planUrl(planId, "accounts", accountId, "reconcile"),
      {
        method: "POST",
        headers: { "idempotency-key": idempotencyKey },
        body: JSON.stringify({ statement_date: statementDate, statement_balance: statementBalance }),
      },
    ),
  month: (planId: string, month: string) =>
    request<{ month: PlanMonth }>(planUrl(planId, "months", month)).then(
      (d) => d.month,
    ),
  setMonthCategoryAssignment: (planId: string, month: string, categoryId: string, budgeted: number) =>
    request<{ month: PlanMonth }>(
      planUrl(planId, "months", month, "categories", categoryId),
      { method: "PATCH", body: JSON.stringify({ category: { budgeted } }) },
    ).then((d) => d.month),
  setMonthCategoryTarget: (planId: string, month: string, categoryId: string, target: { goal_type: string; goal_target: number; goal_target_month?: string | null } | null) =>
    request<{ month: PlanMonth }>(
      planUrl(planId, "months", month, "categories", categoryId),
      { method: "PATCH", body: JSON.stringify({ category: { target } }) },
    ).then((d) => d.month),
  restoreMonthCategoryTarget: (planId: string, month: string, categoryId: string) =>
    request<{ month: PlanMonth }>(
      planUrl(planId, "months", month, "categories", categoryId),
      { method: "PATCH", body: JSON.stringify({ category: { restore_target: true } }) },
    ).then((d) => d.month),
  transactions: (planId: string, params: { since_date?: string; until_date?: string; type?: "unapproved"; limit?: number; offset?: number }) =>
    request<TransactionPage>(
      `${planUrl(planId, "transactions")}${query(params)}`,
    ),
  accountTransactions: (planId: string, accountId: string, params: { since_date?: string; until_date?: string; type?: "unapproved"; limit?: number; offset?: number }) =>
    request<TransactionPage>(
      `${planUrl(planId, "accounts", accountId, "transactions")}${query(params)}`,
    ),
  updateTransaction: (planId: string, transactionId: string, transaction: TransactionUpdateInput) =>
    request<{ transaction: Transaction }>(
      planUrl(planId, "transactions", transactionId),
      { method: "PATCH", body: JSON.stringify({ transaction }) },
    ).then((data) => data.transaction),
  updateTransactionCleared: (
    planId: string,
    transactionId: string,
    expectedCleared: "uncleared" | "cleared",
    cleared: "uncleared" | "cleared",
  ) =>
    request<{ transaction: Transaction }>(
      planUrl(planId, "transactions", transactionId, "cleared"),
      { method: "PATCH", body: JSON.stringify({ expected_cleared: expectedCleared, cleared }) },
    ).then((data) => data.transaction),
  deleteTransaction: (planId: string, transactionId: string, expectedApproved?: boolean) =>
    request<{ transaction: Transaction }>(
      `${planUrl(planId, "transactions", transactionId)}${query({ expected_approved: expectedApproved?.toString() })}`,
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
 * filter changes never paint out of order. Data from a previous key is not
 * returned, so month/report mutations cannot target a different window than
 * the figures on screen.
 */
export function useApi<T>(key: string, fetcher: () => Promise<T>): ApiState<T> {
  const [state, setState] = useState<ApiState<T> & { key: string }>({
    data: null,
    loading: true,
    error: null,
    key,
  });
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;

  useEffect(() => {
    let cancelled = false;
    setState((previous) => ({ ...previous, loading: true, error: null }));
    fetcherRef
      .current()
      .then((data) => {
        if (!cancelled) {
          setState({ data, loading: false, error: null, key });
        }
      })
      .catch((error: Error) => {
        if (!cancelled) {
          setState({ data: null, loading: false, error: error.message, key });
        }
      });
    return () => {
      cancelled = true;
    };
  }, [key]);

  return {
    data: state.key === key ? state.data : null,
    loading: state.key !== key || state.loading,
    error: state.key === key ? state.error : null,
  };
}
