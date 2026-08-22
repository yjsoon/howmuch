import type { Interval } from "../api/types";

/**
 * View preferences that survive across visits. The URL stays the source of
 * truth within a session; these only fill in when a param is absent.
 */
export interface ViewPrefs {
  accountIds?: string[];
  interval?: Interval;
  includeQuietSpending?: boolean;
}

const KEY = "howmuch.view-prefs.v1";
const INTERVALS: Interval[] = ["day", "week", "month", "year"];
const ACCOUNT_ID = /^[A-Za-z0-9._:-]{1,128}$/;

function isAccountId(value: unknown): value is string {
  return typeof value === "string" && ACCOUNT_ID.test(value);
}

export function parsePrefs(raw: unknown): ViewPrefs {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return {};
  }
  const value = raw as Record<string, unknown>;
  const accountIds = Array.isArray(value.accountIds) ? value.accountIds.filter(isAccountId) : undefined;
  const interval = typeof value.interval === "string" && INTERVALS.includes(value.interval as Interval)
    ? (value.interval as Interval)
    : undefined;
  return {
    accountIds,
    interval,
    includeQuietSpending: typeof value.includeQuietSpending === "boolean" ? value.includeQuietSpending : undefined,
  };
}

export function loadPrefs(): ViewPrefs {
  try {
    return parsePrefs(JSON.parse(localStorage.getItem(KEY) ?? "{}"));
  } catch {
    return {};
  }
}

export function savePrefs(patch: Partial<ViewPrefs>): void {
  try {
    localStorage.setItem(KEY, JSON.stringify({ ...loadPrefs(), ...patch }));
  } catch {
    // Storage may be unavailable (private mode); remembering is best-effort.
  }
}
