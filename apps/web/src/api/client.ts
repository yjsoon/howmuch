import { useEffect, useRef, useState } from "react";
import { CATEGORY_SUGGESTION_BATCH, type CategorySuggestion, type CategorySuggestionRequestItem } from "../lib/category-suggestions";
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

export type TransactionBulkStatus = "applied" | "conflict" | "already_removed" | "unresolved" | "unattempted";

export interface TransactionBulkOutcome {
  id: string;
  status: TransactionBulkStatus;
  detail?: string;
}

/** The server's ordered per-item result for one bulk command chunk. */
export interface TransactionBulkResult {
  outcomes: TransactionBulkOutcome[];
  applied_count: number;
  conflict_count: number;
  already_removed_count: number;
  unresolved_count: number;
  unattempted_count: number;
  server_knowledge: number;
}

/** Ordered outcomes across every chunk a bulk command actually reached. */
export interface TransactionBulkSummary {
  outcomes: TransactionBulkOutcome[];
  applied_count: number;
  conflict_count: number;
  already_removed_count: number;
  unresolved_count: number;
  unattempted_count: number;
}

export interface TransactionCategoryBulkItem {
  id: string;
  category_id: string | null;
}

export interface TransactionClearedBulkItem {
  id: string;
  expected_cleared: "uncleared" | "cleared";
  cleared: "uncleared" | "cleared";
}

export interface TransactionDeleteBulkItem {
  id: string;
  expected_approved?: boolean;
}

function countBulkOutcomes(outcomes: readonly TransactionBulkOutcome[]): TransactionBulkSummary {
  const summary: TransactionBulkSummary = {
    outcomes: [...outcomes],
    applied_count: 0,
    conflict_count: 0,
    already_removed_count: 0,
    unresolved_count: 0,
    unattempted_count: 0,
  };
  for (const outcome of outcomes) {
    switch (outcome.status) {
      case "applied": summary.applied_count += 1; break;
      case "conflict": summary.conflict_count += 1; break;
      case "already_removed": summary.already_removed_count += 1; break;
      case "unresolved": summary.unresolved_count += 1; break;
      case "unattempted": summary.unattempted_count += 1; break;
    }
  }
  return summary;
}

/**
 * Classifies a chunk that never produced per-item outcomes.
 *
 * The default is deliberately conservative: `unresolved`, because a chunk can
 * commit earlier rows and then fail. A caller may narrow this to `unattempted`
 * only when the endpoint and status demonstrably guarantee the server rejected
 * the whole request before writing anything.
 */
type BulkFailureClassifier = (cause: unknown) => TransactionBulkStatus;

const conservativeBulkFailure: BulkFailureClassifier = () => "unresolved";

/**
 * Runs a bulk command in bounded chunks and keeps its outcome honest.
 *
 * A chunk that the server answered is reported item by item. A chunk that
 * failed is classified by `classifyFailure`. Once a chunk stops early, the
 * chunks behind it are never sent and are reported as `unattempted`; nothing is
 * replayed.
 */
async function runBulkChunks<Item extends { id: string }>(
  items: readonly Item[],
  send: (chunk: readonly Item[]) => Promise<readonly TransactionBulkOutcome[]>,
  classifyFailure: BulkFailureClassifier = conservativeBulkFailure,
): Promise<TransactionBulkSummary> {
  const outcomes: TransactionBulkOutcome[] = [];
  for (let offset = 0; offset < items.length; offset += TRANSACTION_WRITE_BATCH) {
    const chunk = items.slice(offset, offset + TRANSACTION_WRITE_BATCH);
    let chunkOutcomes: readonly TransactionBulkOutcome[];
    try {
      chunkOutcomes = await send(chunk);
    } catch (cause) {
      const detail = cause instanceof Error ? cause.message : String(cause);
      const status = classifyFailure(cause);
      for (const item of chunk) outcomes.push({ id: item.id, status, detail });
      for (const item of items.slice(offset + chunk.length)) outcomes.push({ id: item.id, status: "unattempted" });
      break;
    }
    outcomes.push(...chunkOutcomes);
    if (chunkOutcomes.some((outcome) => outcome.status === "unresolved" || outcome.status === "unattempted")) {
      for (const item of items.slice(offset + chunk.length)) outcomes.push({ id: item.id, status: "unattempted" });
      break;
    }
  }
  return countBulkOutcomes(outcomes);
}

/**
 * A dedicated bulk command parses its whole body before it writes anything, so
 * a 4xx really does mean nothing was written. The collection PATCH has no such
 * guarantee: it applies rows one at a time, so a later mutation-time rejection
 * can follow committed rows.
 */
const dedicatedCommandFailure: BulkFailureClassifier = (cause) =>
  cause instanceof ApiError && cause.status >= 400 && cause.status < 500 ? "unattempted" : "unresolved";

let onUnauthorized: (() => void) | null = null;
let onLocalWrite: (() => void) | null = null;
let requestEpoch = 0;

/** Register a handler for expired sessions on authenticated endpoints. */
export function setUnauthorizedHandler(handler: (() => void) | null): void {
  onUnauthorized = handler;
}

/**
 * Register a handler called after any write from this client, however it ends.
 *
 * It lives here rather than at the twenty-odd call sites so no write, present
 * or future, can slip past the client cache's invalidation. A write returns
 * the new `server_knowledge` but not everything that number now covers — a
 * transaction changes account balances the response does not carry — so the
 * cache is dropped rather than retagged.
 */
export function setLocalWriteHandler(handler: (() => void) | null): void {
  onLocalWrite = handler;
}

/** Whether a completed request should be treated as a write by the cache. */
export function isWriteRequest(method: string | undefined): boolean {
  const verb = (method ?? "GET").toUpperCase();
  return verb !== "GET" && verb !== "HEAD";
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
  /** A POST that reads only, such as a suggestion request: it must not invalidate cached data. */
  readOnly?: boolean;
}

async function request<T>(path: string, init?: RequestInit, options?: ApiRequestOptions): Promise<T> {
  const startedEpoch = requestEpoch;
  // A write that does not return 2xx may still have been applied: the server
  // can commit and then fail to answer, a proxy can drop the response, the
  // network can go away mid-flight. The cache cannot tell those apart from a
  // write that never landed, and only one of the two answers is safe, so every
  // completed write invalidates regardless of how it ended.
  const write = isWriteRequest(init?.method) && !options?.readOnly;
  try {
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
  } finally {
    if (write) {
      onLocalWrite?.();
    }
  }
}

/**
 * Announce a write made outside `request` — see `lib/reward-tools.ts`, which
 * calls `fetch` directly so it can carry its own abort and timeout handling.
 * Anything bypassing `request` must invalidate the cache through here.
 */
export function notifyLocalWrite(): void {
  onLocalWrite?.();
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
  /** Unix seconds; null when nothing here holds a browser session. */
  session_expires_at?: number | null;
}

/** What the setup and login endpoints return for a cookie session. */
export interface AuthSession {
  user: AuthUser;
  session_expires_at?: number | null;
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

export interface UnapprovedCount {
  count: number;
  server_knowledge: number;
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
    request<AuthSession>("/api/auth/setup", {
      method: "POST",
      headers: bootstrapToken ? { authorization: `Bearer ${bootstrapToken}` } : undefined,
      body: JSON.stringify({ username, password }),
    }),
  login: (username: string, password: string) =>
    request<AuthSession>("/api/auth/login", {
      method: "POST",
      body: JSON.stringify({ username, password }),
    }),
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
  transaction: (planId: string, transactionId: string) =>
    request<{ transaction: Transaction }>(
      planUrl(planId, "transactions", transactionId),
    ).then((data) => data.transaction),
  accountTransactions: (planId: string, accountId: string, params: { since_date?: string; until_date?: string; type?: "unapproved"; limit?: number; offset?: number; q?: string }) =>
    request<TransactionPage>(
      `${planUrl(planId, "accounts", accountId, "transactions")}${query(params)}`,
    ),
  // The "New" badge without its rows. Costs one bounded query server-side, where
  // the queue itself costs a page walk, so the register never waits on it.
  unapprovedCount: (planId: string, params: { since_date?: string; until_date?: string }, accountId?: string | null) =>
    request<UnapprovedCount>(
      `${accountId
        ? planUrl(planId, "accounts", accountId, "transactions", "unapproved_count")
        : planUrl(planId, "transactions", "unapproved_count")}${query(params)}`,
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
  /**
   * Categorises eligible rows through the existing collection PATCH, in
   * bounded chunks.
   *
   * A 2xx is not enough: the server normalises a category away when the row is
   * (or has just become) a split parent or a transfer, so the response is read
   * back per row and only a returned category that matches the request counts
   * as applied. Anything else is a `conflict`, and a chunk that failed without
   * per-item outcomes is `unresolved` rather than guessed at.
   */
  categoriseTransactions: (planId: string, items: readonly TransactionCategoryBulkItem[]) => {
    if (items.length === 0) throw new Error("Transactions to categorise must not be empty.");
    return runBulkChunks(items, async (chunk) => {
      const result = await request<{ transactions: Array<{ id: string; category_id: string | null }> }>(
        planUrl(planId, "transactions"),
        {
          method: "PATCH",
          body: JSON.stringify({
            transactions: chunk.map((item) => ({ id: item.id, category_id: item.category_id })),
          }),
        },
      );
      const byId = new Map(result.transactions.map((transaction) => [transaction.id, transaction]));
      return chunk.map((item) => {
        const returned = byId.get(item.id);
        if (!returned) {
          return { id: item.id, status: "unresolved" as const, detail: "The server did not confirm this row" };
        }
        if ((returned.category_id ?? null) !== (item.category_id ?? null)) {
          return { id: item.id, status: "conflict" as const, detail: "The server did not apply this category" };
        }
        return { id: item.id, status: "applied" as const };
      });
    });
  },
  /**
   * Jev category suggestions for up to MAX_CATEGORY_SUGGESTIONS rows, sent in
   * server-sized batches. Read-only: applying them goes through
   * `categoriseTransactions`.
   */
  suggestCategories: async (planId: string, items: readonly CategorySuggestionRequestItem[]) => {
    const suggestions: CategorySuggestion[] = [];
    for (let start = 0; start < items.length; start += CATEGORY_SUGGESTION_BATCH) {
      const result = await request<{ suggestions: CategorySuggestion[] }>(
        `/api/tools/categorise${query({ plan_id: planId })}`,
        { method: "POST", body: JSON.stringify({ transactions: items.slice(start, start + CATEGORY_SUGGESTION_BATCH) }) },
        { readOnly: true },
      );
      suggestions.push(...result.suggestions);
    }
    return suggestions;
  },
  /** Bulk cleared with a per-row compare-and-set, in bounded chunks. */
  bulkClearedTransactions: (planId: string, items: readonly TransactionClearedBulkItem[]) => {
    if (items.length === 0) throw new Error("Transactions to update must not be empty.");
    return runBulkChunks(items, async (chunk) => {
      const result = await request<TransactionBulkResult>(planUrl(planId, "transactions", "cleared"), {
        method: "POST",
        body: JSON.stringify({
          transactions: chunk.map((item) => ({
            id: item.id,
            expected_cleared: item.expected_cleared,
            cleared: item.cleared,
          })),
        }),
      });
      return result.outcomes;
    }, dedicatedCommandFailure);
  },
  /** Bulk delete reusing the single-row guard and cascade, in bounded chunks. */
  bulkDeleteTransactions: (planId: string, items: readonly TransactionDeleteBulkItem[]) => {
    if (items.length === 0) throw new Error("Transactions to delete must not be empty.");
    return runBulkChunks(items, async (chunk) => {
      const result = await request<TransactionBulkResult>(planUrl(planId, "transactions", "delete"), {
        method: "POST",
        body: JSON.stringify({
          transactions: chunk.map((item) => ({
            id: item.id,
            ...(item.expected_approved === undefined ? {} : { expected_approved: item.expected_approved }),
          })),
        }),
      });
      return result.outcomes;
    }, dedicatedCommandFailure);
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
  exportRewardsAccountConfig: (planId: string, accountId: string) =>
    request<RewardsAccountConfig>(`/api/rewards/accounts/${encodeURIComponent(accountId)}/config${query({ plan_id: planId })}`),
  importRewardsAccountConfig: (planId: string, accountId: string, payload: unknown) =>
    request<{ card: CreditCard }>(`/api/rewards/accounts/${encodeURIComponent(accountId)}/config`, {
      method: "PUT",
      body: JSON.stringify({ plan_id: planId, payload }),
    }),
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

export type RewardsAccountConfig = {
  format: "rewards-account-config";
  version: 1;
  card: Omit<CreditCard, "id" | "ynabAccountId" | "featured">;
};

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
