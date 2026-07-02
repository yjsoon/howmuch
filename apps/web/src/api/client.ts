import { useEffect, useRef, useState } from "react";
import type {
  Account,
  AgeOfMoneyReport,
  Category,
  CategoryGroup,
  CsvImportRow,
  ImportResult,
  IncomeVsSpendingReport,
  NetWorthReport,
  Payee,
  Plan,
  PlanSettings,
  QuickEntryInput,
  SpendingBreakdownReport,
  Transaction,
  TransactionPatch,
  YnabImportResult,
} from "./types";

const TOKEN_KEY = "howmuch.api-token";

export function getApiToken(): string | null {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function setApiToken(token: string | null): void {
  try {
    if (token) {
      localStorage.setItem(TOKEN_KEY, token);
    } else {
      localStorage.removeItem(TOKEN_KEY);
    }
  } catch {
    // Private mode: token lives for the tab only.
  }
}

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const token = getApiToken();
  const response = await fetch(path, {
    ...init,
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...init?.headers,
    },
  });
  if (!response.ok) {
    let message = `${response.status} ${response.statusText}`;
    try {
      const body = await response.json();
      message = body?.error?.detail ?? body?.error?.message ?? message;
    } catch {
      // keep the status message
    }
    throw new ApiError(message, response.status);
  }
  const body = await response.json();
  return body.data as T;
}

function query(params: Record<string, string | undefined>): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value) {
      search.set(key, value);
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

export const api = {
  plans: () => request<{ plans: Plan[] }>("/v1/plans").then((d) => d.plans),
  settings: (planId: string) =>
    request<{ settings: PlanSettings }>(`/v1/plans/${planId}/settings`).then((d) => d.settings),
  accounts: (planId: string) =>
    request<{ accounts: Account[] }>(`/v1/plans/${planId}/accounts`).then((d) => d.accounts),
  createAccount: (planId: string, account: { name: string; type: string; opening_balance: number; on_budget?: boolean }) =>
    request<{ account: Account }>(`/v1/plans/${planId}/accounts`, {
      method: "POST",
      body: JSON.stringify({ account }),
    }).then((d) => d.account),
  updateAccount: (planId: string, accountId: string, patch: Partial<{ name: string; type: string; closed: boolean; on_budget: boolean; opening_balance: number }>) =>
    request<{ account: Account }>(`/v1/plans/${planId}/accounts/${accountId}`, {
      method: "PATCH",
      body: JSON.stringify({ account: patch }),
    }).then((d) => d.account),
  categories: (planId: string) =>
    request<{ category_groups: CategoryGroup[] }>(`/v1/plans/${planId}/categories`).then(
      (d) => d.category_groups,
    ),
  createCategoryGroup: (planId: string, name: string) =>
    request<{ category_group: CategoryGroup }>(`/v1/plans/${planId}/category_groups`, {
      method: "POST",
      body: JSON.stringify({ category_group: { name } }),
    }).then((d) => d.category_group),
  updateCategoryGroup: (planId: string, groupId: string, patch: Partial<{ name: string; hidden: boolean }>) =>
    request<{ category_group: CategoryGroup }>(`/v1/plans/${planId}/category_groups/${groupId}`, {
      method: "PATCH",
      body: JSON.stringify({ category_group: patch }),
    }).then((d) => d.category_group),
  deleteCategoryGroup: (planId: string, groupId: string, reassignTo?: string) =>
    request<{ category_group: CategoryGroup }>(
      `/v1/plans/${planId}/category_groups/${groupId}${query({ reassign_to: reassignTo })}`,
      { method: "DELETE" },
    ).then((d) => d.category_group),
  createCategory: (planId: string, category: { name: string; category_group_id: string }) =>
    request<{ category: Category }>(`/v1/plans/${planId}/categories`, {
      method: "POST",
      body: JSON.stringify({ category }),
    }).then((d) => d.category),
  updateCategory: (planId: string, categoryId: string, patch: Partial<{ name: string; category_group_id: string; hidden: boolean }>) =>
    request<{ category: Category }>(`/v1/plans/${planId}/categories/${categoryId}`, {
      method: "PATCH",
      body: JSON.stringify({ category: patch }),
    }).then((d) => d.category),
  deleteCategory: (planId: string, categoryId: string, reassignTo?: string) =>
    request<{ category: Category }>(
      `/v1/plans/${planId}/categories/${categoryId}${query({ reassign_to: reassignTo })}`,
      { method: "DELETE" },
    ).then((d) => d.category),
  payees: (planId: string) =>
    request<{ payees: Payee[] }>(`/v1/plans/${planId}/payees`).then((d) => d.payees),
  updatePayee: (planId: string, payeeId: string, patch: { name: string }) =>
    request<{ payee: Payee }>(`/v1/plans/${planId}/payees/${payeeId}`, {
      method: "PATCH",
      body: JSON.stringify({ payee: patch }),
    }).then((d) => d.payee),
  transactions: (planId: string, params: { since_date?: string; until_date?: string }) =>
    request<{ transactions: Transaction[] }>(
      `/v1/plans/${planId}/transactions${query(params)}`,
    ).then((d) => d.transactions),
  createTransaction: (planId: string, transaction: TransactionPatch & { account_id: string; date: string; amount: number }) =>
    request<{ transaction: Transaction }>(`/v1/plans/${planId}/transactions`, {
      method: "POST",
      body: JSON.stringify({ transaction }),
    }).then((d) => d.transaction),
  updateTransaction: (planId: string, transactionId: string, patch: TransactionPatch) =>
    request<{ transaction: Transaction }>(`/v1/plans/${planId}/transactions/${transactionId}`, {
      method: "PATCH",
      body: JSON.stringify({ transaction: patch }),
    }).then((d) => d.transaction),
  deleteTransaction: (planId: string, transactionId: string) =>
    request<{ transaction: Transaction }>(`/v1/plans/${planId}/transactions/${transactionId}`, {
      method: "DELETE",
    }).then((d) => d.transaction),
  createTransfer: (
    planId: string,
    transfer: { from_account_id: string; to_account_id: string; amount_milli: number; date: string; memo?: string | null; cleared?: string },
  ) =>
    request<{ outflow: Transaction; inflow: Transaction }>(`/api/transfers${query({ plan_id: planId })}`, {
      method: "POST",
      body: JSON.stringify({ ...transfer, plan_id: planId }),
    }),
  bulkUpdateTransactions: (
    planId: string,
    transactionIds: string[],
    patch: { category_id?: string | null; cleared?: string; approved?: boolean; deleted?: boolean },
  ) =>
    request<{ updated: number; skipped: number }>(`/api/transactions/bulk${query({ plan_id: planId })}`, {
      method: "POST",
      body: JSON.stringify({ plan_id: planId, transaction_ids: transactionIds, patch }),
    }),
  approveTransactions: (planId: string, transactionIds?: string[]) =>
    request<{ approved: number }>(`/api/transactions/approve${query({ plan_id: planId })}`, {
      method: "POST",
      body: JSON.stringify({ plan_id: planId, transaction_ids: transactionIds }),
    }).then((d) => d.approved),
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
  listYnabPlans: (token: string) =>
    request<{ plans: Array<{ id: string; name: string; last_modified_on?: string }> }>(
      "/api/import/ynab/plans",
      { method: "POST", body: JSON.stringify({ token }) },
    ).then((d) => d.plans),
  importYnab: (planId: string, token: string) =>
    request<YnabImportResult>(`/api/import/ynab${query({ plan_id: planId })}`, {
      method: "POST",
      body: JSON.stringify({ token, plan_id: planId }),
    }),
  importCsv: (planId: string, accountId: string, rows: CsvImportRow[]) =>
    request<ImportResult>(`/api/import/csv${query({ plan_id: planId })}`, {
      method: "POST",
      body: JSON.stringify({ plan_id: planId, account_id: accountId, rows }),
    }),
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
