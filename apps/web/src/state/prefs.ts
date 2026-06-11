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

export function loadPrefs(): ViewPrefs {
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? "{}") as ViewPrefs;
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
