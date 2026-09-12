import { describe, expect, test } from "bun:test";
import type { Account, AccountPreferences } from "../api/types";
import { accountGroups } from "./account-groups";
import { ACCOUNT_USAGE_DAYS, accountUsageCounts, localIsoDate } from "./account-usage";

interface FixtureRow {
  id: string;
  account_id: string;
  date: string;
  deleted: boolean;
}

const UNTIL = "2026-08-31";

/**
 * The counting the Shell used to do: page the live register over the window,
 * dedupe by transaction id, and add one per row to its account. Kept here as
 * the oracle the grouped endpoint has to agree with.
 */
function countByPaginating(rows: readonly FixtureRow[], since: string, until: string): Record<string, number> {
  const live = rows.filter((row) => !row.deleted);
  const counts: Record<string, number> = {};
  const seen = new Set<string>();
  const pageSize = 3;
  for (let offset = 0; offset < live.length; offset += pageSize) {
    for (const row of live.slice(offset, offset + pageSize)) {
      if (row.date >= since && row.date <= until && !seen.has(row.id)) {
        seen.add(row.id);
        counts[row.account_id] = (counts[row.account_id] ?? 0) + 1;
      }
    }
  }
  return counts;
}

/** What the server's grouped query returns for the same fixture. */
function groupedUsage(rows: readonly FixtureRow[], since: string, until: string): Array<{ account_id: string; count: number }> {
  const counts = new Map<string, number>();
  for (const row of rows) {
    if (row.deleted || row.date < since || row.date > until) continue;
    counts.set(row.account_id, (counts.get(row.account_id) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([account_id, count]) => ({ account_id, count }))
    .sort((first, second) => first.account_id.localeCompare(second.account_id));
}

/** The window the old loop computed in local time: `until` back `days - 1` days. */
function loopSince(until: string, days: number): string {
  const [year, month, day] = until.split("-").map(Number);
  const start = new Date(year!, month! - 1, day!);
  start.setDate(start.getDate() - (days - 1));
  return localIsoDate(start);
}

/** The window the endpoint computes, in UTC. */
function endpointSince(until: string, days: number): string {
  return new Date(Date.parse(`${until}T00:00:00Z`) - (days - 1) * 86_400_000).toISOString().slice(0, 10);
}

const account = (id: string, name: string): Account => ({
  id, name, icon: "🏦", type: "checking", on_budget: true, closed: false,
  balance: 0, cleared_balance: 0, uncleared_balance: 0,
  last_reconciled_date: null, transfer_payee_id: null, deleted: false,
});

const accounts: Account[] = [
  account("bank", "Bank"),
  account("card", "Card"),
  account("quiet", "Quiet"),
  account("tied", "Tied"),
];

const preferences: AccountPreferences = {
  favourite_account_ids: [],
  account_order: [],
  account_order_by_group: {},
  account_group_sorts: { "custom-usage": "mostUsedLast30Days" },
  custom_account_groups: [
    { id: "custom-usage", name: "Usage", account_ids: ["bank", "card", "quiet", "tied"] },
  ],
};

const rows: FixtureRow[] = [
  // Inside the window, including both its ends.
  { id: "t1", account_id: "bank", date: "2026-08-02", deleted: false },
  { id: "t2", account_id: "bank", date: "2026-08-15", deleted: false },
  { id: "t3", account_id: "bank", date: UNTIL, deleted: false },
  { id: "t4", account_id: "card", date: "2026-08-10", deleted: false },
  { id: "t5", account_id: "card", date: "2026-08-11", deleted: false },
  // "tied" matches "card" so the name tiebreak decides their order.
  { id: "t6", account_id: "tied", date: "2026-08-12", deleted: false },
  { id: "t7", account_id: "tied", date: "2026-08-13", deleted: false },
  // Outside the window or not live: none of these may be counted.
  { id: "t8", account_id: "quiet", date: "2026-08-01", deleted: false },
  { id: "t9", account_id: "quiet", date: "2026-09-01", deleted: false },
  { id: "t10", account_id: "quiet", date: "2026-08-20", deleted: true },
];

describe("accountUsageCounts", () => {
  test("matches the counts the old pagination loop produced", () => {
    const since = loopSince(UNTIL, ACCOUNT_USAGE_DAYS);
    expect(since).toBe("2026-08-02");
    expect(accountUsageCounts(groupedUsage(rows, since, UNTIL)))
      .toEqual(countByPaginating(rows, since, UNTIL));
  });

  test("sorts accounts in the same order as the old loop", () => {
    const since = loopSince(UNTIL, ACCOUNT_USAGE_DAYS);
    const order = (counts: Record<string, number>) =>
      accountGroups(accounts, preferences, counts)
        .find((group) => group.id === "custom-usage")!
        .accounts.map((entry) => entry.id);

    const fromEndpoint = order(accountUsageCounts(groupedUsage(rows, since, UNTIL)));
    expect(fromEndpoint).toEqual(order(countByPaginating(rows, since, UNTIL)));
    // Most used first, ties broken by name, and the unused account last.
    expect(fromEndpoint).toEqual(["bank", "card", "tied", "quiet"]);
  });

  test("reads a missing account as zero and adds up a repeated one", () => {
    expect(accountUsageCounts([])).toEqual({});
    expect(accountUsageCounts([{ account_id: "bank", count: 2 }, { account_id: "bank", count: 3 }]))
      .toEqual({ bank: 5 });
  });

  test("the endpoint window is the window the loop used", () => {
    for (const until of ["2026-08-31", "2026-03-29", "2026-10-25", "2026-01-01", "2026-03-01"]) {
      expect(`${until} -> ${endpointSince(until, ACCOUNT_USAGE_DAYS)}`)
        .toBe(`${until} -> ${loopSince(until, ACCOUNT_USAGE_DAYS)}`);
    }
  });
});
