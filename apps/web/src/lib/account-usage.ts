/**
 * The "Most used (30 days)" sort reads per-account transaction counts. The
 * server now counts them with one grouped query, so the client only has to
 * turn that list into the map the sort indexes by account id.
 */
export const ACCOUNT_USAGE_DAYS = 30;

export interface AccountUsageEntry {
  account_id: string;
  count: number;
}

/**
 * Folds the usage list into the count map `accountGroups` sorts by. Accounts
 * the server left out have no entry, which the sort already reads as zero, and
 * a repeated account id adds up rather than overwriting.
 */
export function accountUsageCounts(usage: readonly AccountUsageEntry[]): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const entry of usage) {
    if (!entry || typeof entry.account_id !== "string") continue;
    const count = Number(entry.count);
    if (!Number.isFinite(count)) continue;
    counts[entry.account_id] = (counts[entry.account_id] ?? 0) + count;
  }
  return counts;
}

/** The local calendar date a usage window ends on, in the viewer's time zone. */
export function localIsoDate(date: Date): string {
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}
