import { useCallback, useMemo } from "react";
import { useSearchParams } from "react-router-dom";
import type { Interval } from "../api/types";
import type { ReportQuery } from "../api/client";

export interface Filters {
  from?: string;
  to?: string;
  accountIds: string[];
  categoryIds: string[];
  interval: Interval;
}

const INTERVALS: Interval[] = ["day", "week", "month", "year"];

function parseList(value: string | null): string[] {
  return value ? value.split(",").filter(Boolean) : [];
}

/**
 * Filters live in the URL search string so report views are linkable and the
 * chosen range carries across tabs.
 */
export function useFilters(): {
  filters: Filters;
  setFilters: (patch: Partial<Filters>) => void;
  reportQuery: ReportQuery;
} {
  const [params, setParams] = useSearchParams();

  const filters = useMemo<Filters>(() => {
    const interval = params.get("interval") as Interval | null;
    return {
      from: params.get("from") ?? undefined,
      to: params.get("to") ?? undefined,
      accountIds: parseList(params.get("accounts")),
      categoryIds: parseList(params.get("categories")),
      interval: interval && INTERVALS.includes(interval) ? interval : "month",
    };
  }, [params]);

  const setFilters = useCallback(
    (patch: Partial<Filters>) => {
      setParams(
        (previous) => {
          const next = new URLSearchParams(previous);
          const merged = { ...filtersFromParams(previous), ...patch };
          writeParam(next, "from", merged.from);
          writeParam(next, "to", merged.to);
          writeParam(next, "accounts", merged.accountIds.join(",") || undefined);
          writeParam(next, "categories", merged.categoryIds.join(",") || undefined);
          writeParam(next, "interval", merged.interval === "month" ? undefined : merged.interval);
          return next;
        },
        { replace: true },
      );
    },
    [setParams],
  );

  const reportQuery = useMemo<ReportQuery>(
    () => ({
      from: filters.from,
      to: filters.to,
      account_ids: filters.accountIds.join(",") || undefined,
      category_ids: filters.categoryIds.join(",") || undefined,
      interval: filters.interval,
    }),
    [filters],
  );

  return { filters, setFilters, reportQuery };
}

function filtersFromParams(params: URLSearchParams): Filters {
  const interval = params.get("interval") as Interval | null;
  return {
    from: params.get("from") ?? undefined,
    to: params.get("to") ?? undefined,
    accountIds: parseList(params.get("accounts")),
    categoryIds: parseList(params.get("categories")),
    interval: interval && INTERVALS.includes(interval) ? interval : "month",
  };
}

function writeParam(params: URLSearchParams, key: string, value: string | undefined): void {
  if (value) {
    params.set(key, value);
  } else {
    params.delete(key);
  }
}

/** Builds a /transactions link that carries the current range plus a category drill-down. */
export function transactionsLink(filters: Filters, categoryId?: string): string {
  const params = new URLSearchParams();
  if (filters.from) params.set("from", filters.from);
  if (filters.to) params.set("to", filters.to);
  if (filters.accountIds.length) params.set("accounts", filters.accountIds.join(","));
  if (categoryId) params.set("categories", categoryId);
  else if (filters.categoryIds.length) params.set("categories", filters.categoryIds.join(","));
  const text = params.toString();
  return `/transactions${text ? `?${text}` : ""}`;
}
