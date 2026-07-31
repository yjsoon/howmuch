import { useEffect, useRef, useState } from "react";
import type {
  Account,
  AgeOfMoneyReport,
  CategoryGroup,
  IncomeVsSpendingReport,
  NetWorthReport,
  Payee,
  Plan,
  PlanSettings,
  QuickEntryInput,
  SpendingBreakdownReport,
  Transaction,
} from "./types";

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
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

export interface AuthUser {
  id: string;
  username: string;
}

export interface AuthStatus {
  setup_required: boolean;
  user: AuthUser | null;
}

export const api = {
  authStatus: () => request<AuthStatus>("/api/auth/status"),
  setup: (username: string, password: string, bootstrapToken: string) =>
    request<{ user: AuthUser }>("/api/auth/setup", {
      method: "POST",
      headers: { authorization: `Bearer ${bootstrapToken}` },
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
  transactions: (planId: string, params: { since_date?: string; until_date?: string }) =>
    request<{ transactions: Transaction[] }>(
      `/v1/plans/${planId}/transactions${query(params)}`,
    ).then((d) => d.transactions),
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
