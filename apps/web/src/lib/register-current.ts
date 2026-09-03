export function isUpcomingRegisterDate(date: string, today: string): boolean {
  return date > today;
}

/** Omit `until_date` when the visible window includes today, so posted futures still load. */
export function registerFetchUntilDate(to: string | undefined, today: string): string | undefined {
  if (!to || to >= today) {
    return undefined;
  }
  return to;
}

export function dateInRegisterWindow(
  date: string,
  from: string | undefined,
  to: string | undefined,
  today: string,
): boolean {
  if (from && date < from) {
    return false;
  }
  const until = registerFetchUntilDate(to, today);
  if (until && date > until) {
    return false;
  }
  return true;
}

export function asOfTodayBalance(
  working: number,
  rows: Array<{ account_id: string; date: string; amount: number; deleted?: boolean }>,
  options: { accountId: string; today: string },
): number {
  const upcoming = rows.reduce((sum, row) => {
    if (row.deleted || row.account_id !== options.accountId) {
      return sum;
    }
    if (!isUpcomingRegisterDate(row.date, options.today)) {
      return sum;
    }
    return sum + row.amount;
  }, 0);
  return working - upcoming;
}

export function partitionRegisterDates(dates: string[], today: string): {
  upcoming: string[];
  current: string[];
} {
  const unique = [...new Set(dates)];
  return {
    upcoming: unique.filter((date) => isUpcomingRegisterDate(date, today)).sort((a, b) => (a < b ? 1 : a > b ? -1 : 0)),
    current: unique.filter((date) => !isUpcomingRegisterDate(date, today)).sort((a, b) => (a < b ? 1 : a > b ? -1 : 0)),
  };
}
