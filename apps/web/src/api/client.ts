import { useEffect, useRef, useState } from "react";
import type {
  Account,
  AccountPreferences,
  AccountPreferencesSnapshot,
  AccountReconciliationPreview,
  AccountReconciliationResult,
  AccountUsageSnapshot,
  AgeOfMoneyReport,
  CategoryGroup,
  CreditCard,
  IncomeVsSpendingReport,
  NetWorthReport,
  Payee,
  Plan,
  PlanSettings,
  QuickEntryInput,
  ReconciliationMismatchDetail,
  RewardsReport,
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

export const TRANSACTION_WRITE_BATCH = 100;

export class BulkApprovalError extends Error {
  constructor(
    message: string,
    readonly approvedCount: number,
    cause?: unknown,
  ) {
    super(message, { cause });
    this.name = "BulkApprovalError";
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

/** Per-call knobs that do not belong in `RequestInit`. */
export interface ApiRequestOptions {
  /**
   * Whether a 401 should end the session globally. Speculative bootstrap
   * requests set this to false: they may race ahead of the session check, so
   * their failures are decided by the caller instead of tearing down state.
   */
  handleUnauthorized?: boolean;
}

async function request<T>(path: string, init?: RequestInit, options?: ApiRequestOptions): Promise<T> {
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
    if (response.status === 401
      && options?.handleUnauthorized !== false
      && shouldHandleUnauthorized(path, startedEpoch)) {
      bumpRequestEpoch();
      onUnauthorized?.();
    }
    const detail = (body && typeof body === "object" && "error" in body ? (body as { error?: Record<string, unknown> }).error : undefined) as (ReconciliationMismatchDetail & { detail?: string }) | undefined;
    const message = detail?.detail ?? `${response.status} ${response.statusText}`;
    throw new ApiError(message, response.status, typeof detail?.name === "string" ? detail.name : undefined, detail);
  }
  if (!body || typeof body !== "object" || !("data" in body)) {
    throw new ApiError("Unexpected response from HowMuch", response.status);
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
  group?: string;
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

async function approveTransactionBatch(planId: string, transactionIds: readonly string[]): Promise<void> {
  if (transactionIds.length === 0) {
    throw new Error("Transaction approval batch must not be empty.");
  }
  if (transactionIds.length > TRANSACTION_WRITE_BATCH) {
    throw new Error(`Transaction approval batch cannot exceed ${TRANSACTION_WRITE_BATCH} items.`);
  }
  await request<unknown>(planUrl(planId, "transactions"), {
    method: "PATCH",
    body: JSON.stringify({
      transactions: transactionIds.map((id) => ({ id, approved: true })),
    }),
  });
}

export const api = {
  authStatus: (options?: ApiRequestOptions) => request<AuthStatus>("/api/auth/status", undefined, options),
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
  plans: (options?: ApiRequestOptions) =>
    request<{ plans: Plan[] }>("/v1/plans", undefined, options).then((d) => d.plans),
  settings: (planId: string, options?: ApiRequestOptions) =>
    request<{ settings: PlanSettings }>(planUrl(planId, "settings"), undefined, options).then((d) => d.settings),
  accounts: (planId: string, options?: ApiRequestOptions) =>
    request<{ accounts: Account[]; server_knowledge: number }>(planUrl(planId, "accounts"), undefined, options),
  updateAccountIcon: (planId: string, accountId: string, icon: string) =>
    request<{ account: Account; server_knowledge: number }>(planUrl(planId, "accounts", accountId), {
      method: "PATCH",
      body: JSON.stringify({ account: { icon } }),
    }).then((data) => data.account),
  accountUsage: (planId: string, params: { days: number; until: string }, options?: ApiRequestOptions) =>
    request<AccountUsageSnapshot>(
      `${planUrl(planId, "accounts", "usage")}${query(params)}`,
      undefined,
      options,
    ),
  accountPreferences: (planId: string, options?: ApiRequestOptions) =>
    request<AccountPreferencesSnapshot>(planUrl(planId, "account_preferences"), undefined, options)
      .catch((error) => {
        if (error instanceof ApiError && error.status === 404) return null;
        throw error;
      }),
  updateAccountPreferences: (planId: string, accountPreferences: AccountPreferences, expectedRevision: number) =>
    request<AccountPreferencesSnapshot>(planUrl(planId, "account_preferences"), {
      method: "PUT",
      body: JSON.stringify({ account_preferences: accountPreferences, expected_revision: expectedRevision }),
    }),
  categories: (planId: string, options?: ApiRequestOptions) =>
    request<{ category_groups: CategoryGroup[] }>(planUrl(planId, "categories"), undefined, options).then(
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
  transactions: (planId: string, params: { since_date?: string; until_date?: string; type?: "unapproved"; limit?: number; offset?: number; q?: string }) =>
    request<TransactionPage>(
      `${planUrl(planId, "transactions")}${query(params)}`,
    ),
  accountTransactions: (planId: string, accountId: string, params: { since_date?: string; until_date?: string; type?: "unapproved"; limit?: number; offset?: number; q?: string }) =>
    request<TransactionPage>(
      `${planUrl(planId, "accounts", accountId, "transactions")}${query(params)}`,
    ),
  updateTransaction: (planId: string, transactionId: string, transaction: TransactionUpdateInput) =>
    request<{ transaction: Transaction }>(
      planUrl(planId, "transactions", transactionId),
      { method: "PATCH", body: JSON.stringify({ transaction }) },
    ).then((data) => data.transaction),
  approveTransactions: async (planId: string, transactionIds: readonly string[]) => {
    if (transactionIds.length === 0) {
      throw new Error("Transactions to approve must not be empty.");
    }
    let approvedCount = 0;
    for (let offset = 0; offset < transactionIds.length; offset += TRANSACTION_WRITE_BATCH) {
      const chunk = transactionIds.slice(offset, offset + TRANSACTION_WRITE_BATCH);
      try {
        await approveTransactionBatch(planId, chunk);
        approvedCount += chunk.length;
      } catch (cause) {
        const message = cause instanceof Error ? cause.message : String(cause);
        throw new BulkApprovalError(message, approvedCount, cause);
      }
    }
    return { approvedCount };
  },
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
  rewards: (params: ReportQuery) =>
    request<RewardsReport>(`/api/reports/rewards${query({ ...params })}`),
  quickEntry: (input: QuickEntryInput) =>
    request<{ transaction: Transaction }>("/api/mobile/quick-entry", {
      method: "POST",
      body: JSON.stringify(input),
    }).then((d) => d.transaction),
  rewardsTrackerSnapshot: (planId: string) =>
    request<RewardsTrackerSnapshot>(`/api/import/rewards-tracker${query({ plan_id: planId })}`),
  importRewardsTracker: (planId: string, payload: unknown) =>
    request<RewardsTrackerImportResult>("/api/import/rewards-tracker", {
      method: "POST",
      body: JSON.stringify({ plan_id: planId, payload }),
    }),
  createRewardCard: (planId: string, card: CreditCard) =>
    request<{ card: CreditCard }>("/api/rewards/cards", {
      method: "POST",
      body: JSON.stringify({ plan_id: planId, card }),
    }).then((data) => data.card),
  updateRewardCard: (planId: string, cardId: string, card: Partial<CreditCard>) =>
    request<{ card: CreditCard }>(`/api/rewards/cards/${encodeURIComponent(cardId)}`, {
      method: "PATCH",
      body: JSON.stringify({ plan_id: planId, card }),
    }).then((data) => data.card),
  deleteRewardCard: (planId: string, cardId: string) =>
    request<{ card: CreditCard }>(`/api/rewards/cards/${encodeURIComponent(cardId)}`, {
      method: "DELETE",
      body: JSON.stringify({ plan_id: planId }),
    }).then((data) => data.card),
  updateRewardSettings: (planId: string, settings: { milesValuation: number }) =>
    request<{ settings: { milesValuation?: number } }>("/api/rewards/settings", {
      method: "PATCH",
      body: JSON.stringify({ plan_id: planId, milesValuation: settings.milesValuation }),
    }).then((data) => data.settings),
};

export type RewardsTrackerCard = CreditCard;

export type RewardsTrackerSnapshot = {
  snapshot: { cards?: RewardsTrackerCard[]; settings?: Record<string, unknown>; rules?: unknown[]; tagMappings?: unknown[]; themeGroups?: unknown[]; hiddenCards?: unknown[] } | null;
  cards: RewardsTrackerCard[];
  imported_at: string | null;
  updated_at: string | null;
};

export type RewardsTrackerImportResult = {
  import_session_id: string;
  cards: number;
  rules: number;
  tag_mappings: number;
  theme_groups: number;
  accounts_upserted: number;
  transactions_imported: number;
  transactions_updated: number;
  flag_names: number;
};

export interface ApiState<T> {
  data: T | null;
  loading: boolean;
  error: string | null;
}

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
