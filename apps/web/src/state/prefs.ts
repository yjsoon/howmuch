import type { Interval } from "../api/types";

/**
 * View preferences that survive across visits. The URL stays the source of
 * truth within a session; these only fill in when a param is absent.
 */
export interface ViewPrefs {
  accountIds?: string[];
  interval?: Interval;
  includeQuietSpending?: boolean;
  /**
   * The plan opened last. A hint only: the plans list decides what is actually
   * readable, so a stale value costs a discarded request and nothing more.
   */
  planId?: string;
  /**
   * Unix seconds at which this browser's session stops being accepted, as the
   * server last reported it. Unlike `planId` this is not a mere hint: the
   * cached first paint is gated on it, so an expired cookie cannot show the
   * previous user's ledger to whoever opens the browser next (#177).
   */
  sessionExpiresAt?: number;
}

const KEY = "howmuch.view-prefs.v1";
const INTERVALS: Interval[] = ["day", "week", "month", "year"];
/** At least one alphanumeric, so dot-only ids such as `..` cannot traverse. */
const ID = /^(?=.*[A-Za-z0-9])[A-Za-z0-9._:-]{1,128}$/;

function isId(value: unknown): value is string {
  return typeof value === "string" && ID.test(value);
}

export function parsePrefs(raw: unknown): ViewPrefs {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return {};
  }
  const value = raw as Record<string, unknown>;
  const accountIds = Array.isArray(value.accountIds) ? value.accountIds.filter(isId) : undefined;
  const interval = typeof value.interval === "string" && INTERVALS.includes(value.interval as Interval)
    ? (value.interval as Interval)
    : undefined;
  return {
    accountIds,
    interval,
    includeQuietSpending: typeof value.includeQuietSpending === "boolean" ? value.includeQuietSpending : undefined,
    planId: isId(value.planId) ? value.planId : undefined,
    sessionExpiresAt: typeof value.sessionExpiresAt === "number" && Number.isFinite(value.sessionExpiresAt)
      ? value.sessionExpiresAt
      : undefined,
  };
}

/**
 * Whether the session this browser last recorded is still live.
 *
 * Pure, so the boundary can be tested directly. A missing or unreadable expiry
 * is "no", never "probably": the caller uses this to decide whether cached
 * ledger data may be painted before the server has confirmed anything. Saying
 * no costs one round trip; saying yes wrongly shows one person's plan to
 * another.
 */
export function sessionLooksLive(expiresAt: number | undefined, now: number): boolean {
  if (typeof expiresAt !== "number" || !Number.isFinite(expiresAt)) {
    return false;
  }
  return now < expiresAt * 1_000;
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
