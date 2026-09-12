/**
 * Pure helpers for the `account_month_balances` aggregate.
 *
 * The table itself is maintained by triggers declared in migration
 * `021_account_month_balances.sql` (D1: `0018_account_month_balances.sql`), so
 * nothing here writes during a normal request.  What lives here is the month
 * arithmetic, the rebuild statements used by the migration, the parity script
 * and the drift test, and the pure net-worth fold that turns monthly rows into
 * report periods.
 */

export type MonthlyBalanceRow = { account_id: string; month: string; net_change_milli: number };

export type BoundaryMovement = { account_id: string; date: string; amount_milli: number };

export type NetWorthAccount = {
  id: string;
  name: string;
  closed: boolean;
  opening_balance_milli: number;
};

export type NetWorthPeriodInput = { label: string; end: string };

export type NetWorthAccountBalance = {
  account_id: string;
  account_name: string;
  closed: boolean;
  balance: number;
};

export type NetWorthPeriod = {
  period: string;
  end_date: string;
  net_worth: number;
  delta: number | null;
  accounts: NetWorthAccountBalance[];
};

/** Statements that rebuild the whole aggregate from live transaction history. */
export const REBUILD_ACCOUNT_MONTH_BALANCES_SQL = [
  "DELETE FROM account_month_balances",
  `INSERT INTO account_month_balances (plan_id, account_id, month, net_change_milli, updated_at)
   SELECT t.plan_id, t.account_id, substr(t.date, 1, 7), SUM(t.amount_milli), CURRENT_TIMESTAMP
   FROM transactions t
   WHERE t.deleted = 0
   GROUP BY t.plan_id, t.account_id, substr(t.date, 1, 7)`,
] as const;

/** The `YYYY-MM` bucket an ISO date belongs to. */
export function monthOf(date: string): string {
  return date.slice(0, 7);
}

/** First calendar day of a `YYYY-MM` bucket. */
export function monthStart(month: string): string {
  return `${month}-01`;
}

/** Last calendar day of a `YYYY-MM` bucket. */
export function monthEnd(month: string): string {
  const start = new Date(`${month}-01T00:00:00Z`);
  start.setUTCMonth(start.getUTCMonth() + 1, 0);
  return start.toISOString().slice(0, 10);
}

/** True when the date is the final calendar day of its own month. */
export function isMonthEnd(date: string): boolean {
  return date === monthEnd(monthOf(date));
}

/**
 * Fold monthly aggregates plus the movements of partially covered months into
 * net-worth periods.  Periods must be in ascending order, as `buildPeriods`
 * produces them.
 *
 * A period ending on a month boundary is answered entirely from the aggregate.
 * A period ending mid-month takes every complete month before it from the
 * aggregate and adds only that month's movements up to the period end, so the
 * caller never has to read the ledger before the first partial month.
 */
export function foldNetWorthPeriods(
  accounts: NetWorthAccount[],
  periods: NetWorthPeriodInput[],
  monthly: MonthlyBalanceRow[],
  boundary: BoundaryMovement[],
): NetWorthPeriod[] {
  const selected = new Set(accounts.map((account) => account.id));
  const months = [...new Set(monthly.map((row) => row.month))].sort();
  const monthIndex = new Map(months.map((month, index) => [month, index]));

  // Per account, the cumulative net change through each known month.
  const cumulative = new Map<string, number[]>();
  for (const account of accounts) cumulative.set(account.id, new Array(months.length).fill(0));
  for (const row of monthly) {
    if (!selected.has(row.account_id)) continue;
    const totals = cumulative.get(row.account_id)!;
    totals[monthIndex.get(row.month)!] += Number(row.net_change_milli);
  }
  for (const totals of cumulative.values()) {
    for (let index = 1; index < totals.length; index++) totals[index]! += totals[index - 1]!;
  }

  const partial = new Map<string, BoundaryMovement[]>();
  for (const movement of boundary) {
    if (!selected.has(movement.account_id)) continue;
    const existing = partial.get(movement.account_id);
    if (existing) existing.push(movement);
    else partial.set(movement.account_id, [movement]);
  }
  for (const movements of partial.values()) movements.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));

  let previousNetWorth: number | null = null;
  return periods.map((period) => {
    const month = monthOf(period.end);
    const complete = isMonthEnd(period.end);
    // Complete months are `<= month` when the period ends on a month boundary,
    // otherwise `< month` because `month` itself is only partly elapsed.
    const throughIndex = lastIndexAtOrBefore(months, complete ? month : previousMonth(month));

    const accountRows = accounts.map((account) => {
      let balance = Number(account.opening_balance_milli);
      if (throughIndex >= 0) balance += cumulative.get(account.id)![throughIndex]!;
      if (!complete) {
        for (const movement of partial.get(account.id) ?? []) {
          if (monthOf(movement.date) !== month) continue;
          if (movement.date > period.end) continue;
          balance += Number(movement.amount_milli);
        }
      }
      return { account_id: account.id, account_name: account.name, closed: account.closed, balance };
    });

    const netWorth = accountRows.reduce((sum, account) => sum + account.balance, 0);
    const delta = previousNetWorth == null ? null : netWorth - previousNetWorth;
    previousNetWorth = netWorth;
    return { period: period.label, end_date: period.end, net_worth: netWorth, delta, accounts: accountRows };
  });
}

/**
 * The distinct months that a set of period ends only partly covers, and the
 * latest date within them that any period asks about.  An empty list means the
 * aggregate answers every period on its own.
 */
export function boundaryWindow(periods: NetWorthPeriodInput[]): { months: string[]; from: string; to: string } | null {
  const partial = periods.filter((period) => !isMonthEnd(period.end));
  if (partial.length === 0) return null;
  const months = [...new Set(partial.map((period) => monthOf(period.end)))].sort();
  const ends = partial.map((period) => period.end).sort();
  return { months, from: monthStart(months[0]!), to: ends.at(-1)! };
}

function previousMonth(month: string): string {
  const cursor = new Date(`${month}-01T00:00:00Z`);
  cursor.setUTCMonth(cursor.getUTCMonth() - 1);
  return cursor.toISOString().slice(0, 7);
}

function lastIndexAtOrBefore(months: string[], target: string): number {
  let low = 0;
  let high = months.length - 1;
  let found = -1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    if (months[middle]! <= target) {
      found = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return found;
}
