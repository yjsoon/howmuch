import { useCallback, useMemo } from "react";
import { useSearchParams } from "react-router-dom";
import type { Interval } from "../api/types";
import type { ReportQuery } from "../api/client";
import { monthRange } from "../lib/dates";
import { usePlan } from "./plan";
import { loadPrefs, savePrefs } from "./prefs";

export interface Filters {
  from?: string;
  to?: string;
  accountIds: string[];
  categoryIds: string[];
  interval: Interval;
}

export interface FilterOptions {
  /** Range shown when the URL carries no explicit dates. Defaults to the current month. */
  defaultRange?: () => { from?: string; to?: string };
}

const INTERVALS: Interval[] = ["day", "week", "month", "year"];

function parseList(value: string | null): string[] {
  return value ? value.split(",").filter(Boolean) : [];
}

export function filtersFromSearch(
  params: URLSearchParams,
  options: { defaultRange: () => { from?: string; to?: string }; prefs?: ReturnType<typeof loadPrefs> },
): Filters {
  const prefs = options.prefs ?? {};
  const explicitFrom = params.get("from") ?? undefined;
  const explicitTo = params.get("to") ?? undefined;
  const range =
    explicitFrom || explicitTo
      ? { from: explicitFrom, to: explicitTo }
      : params.get("range") === "all"
        ? {}
        : options.defaultRange();

  const accountsParam = params.get("accounts");
  const accountIds =
    accountsParam === null ? (prefs.accountIds ?? []) : accountsParam === "all" ? [] : parseList(accountsParam);

  const interval = (params.get("interval") ?? prefs.interval) as Interval | null;

  return {
    from: range.from,
    to: range.to,
    accountIds,
    categoryIds: parseList(params.get("categories")),
    interval: interval && INTERVALS.includes(interval) ? interval : "month",
  };
}

export function applyFilterPatch(previous: URLSearchParams, patch: Partial<Filters>): URLSearchParams {
  const next = new URLSearchParams(previous);
  if ("from" in patch) {
    writeParam(next, "from", patch.from);
  }
  if ("to" in patch) {
    writeParam(next, "to", patch.to);
  }
  if ("from" in patch || "to" in patch) {
    // Both cleared means an explicit "all time", not "use the default".
    writeParam(next, "range", next.get("from") || next.get("to") ? undefined : "all");
  }
  if ("accountIds" in patch && patch.accountIds !== undefined) {
    writeParam(next, "accounts", patch.accountIds.join(",") || "all");
  }
  if ("categoryIds" in patch && patch.categoryIds !== undefined) {
    writeParam(next, "categories", patch.categoryIds.join(",") || undefined);
  }
  if (patch.interval) {
    writeParam(next, "interval", patch.interval);
  }
  return next;
}

/**
 * Explicit choices live in the URL search string so report views are linkable
 * and carry across tabs. When a param is absent, each report falls back to its
 * own sensible default range, and accounts/interval fall back to the
 * remembered preferences from the last visit. `range=all` and `accounts=all`
 * mark a deliberate "everything" so it is distinguishable from "no choice".
 */
export function useFilters(options?: FilterOptions): {
  filters: Filters;
  setFilters: (patch: Partial<Filters>) => void;
  reportQuery: ReportQuery;
} {
  const [params, setParams] = useSearchParams();
  const { planId } = usePlan();
  const defaultRange = options?.defaultRange ?? monthRange;

  const filters = useMemo<Filters>(
    () => filtersFromSearch(params, { defaultRange, prefs: loadPrefs() }),
    [params, defaultRange],
  );

  const setFilters = useCallback(
    (patch: Partial<Filters>) => {
      if ("accountIds" in patch && patch.accountIds !== undefined) {
        savePrefs({ accountIds: patch.accountIds });
      }
      if (patch.interval) {
        savePrefs({ interval: patch.interval });
      }
      setParams((previous) => applyFilterPatch(previous, patch), { replace: true });
    },
    [setParams],
  );

  const reportQuery = useMemo<ReportQuery>(
    () => ({
      plan_id: planId,
      from: filters.from,
      to: filters.to,
      account_ids: filters.accountIds.join(",") || undefined,
      category_ids: filters.categoryIds.join(",") || undefined,
      interval: filters.interval,
    }),
    [filters, planId],
  );

  return { filters, setFilters, reportQuery };
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
  if (!filters.from && !filters.to) params.set("range", "all");
  params.set("accounts", filters.accountIds.join(",") || "all");
  if (categoryId) {
    params.set("categories", categoryId);
    params.set("flow", "outflow");
  } else if (filters.categoryIds.length) params.set("categories", filters.categoryIds.join(","));
  return `/transactions?${params.toString()}`;
}
