import type { Account, AccountPreferences } from "../api/types";

export type AccountGroup = { id: string; label: string; accounts: Account[] };

const CASH_TYPES = new Set(["checking", "savings", "cash"]);
const CREDIT_TYPES = new Set(["creditCard", "lineOfCredit"]);

export function accountGroups(accounts: Account[], preferences: AccountPreferences | null): AccountGroup[] {
  const open = accounts.filter((account) => !account.closed);
  if (!preferences) {
    return [
      { id: "budget", label: "Budget", accounts: open.filter((account) => account.on_budget) },
      { id: "tracking", label: "Tracking", accounts: open.filter((account) => !account.on_budget) },
    ].filter(hasAccounts);
  }

  const byId = new Map(accounts.map((account) => [account.id, account]));
  const favourites = preferences.favourite_account_ids
    .map((id) => byId.get(id))
    .filter((account): account is Account => Boolean(account && !account.closed));
  const custom = preferences.custom_account_groups.map((group) => ({
    id: group.id,
    label: group.name,
    accounts: group.account_ids.map((id) => byId.get(id)).filter((account): account is Account => Boolean(account)),
  }));
  const builtIn: AccountGroup[] = [
    { id: "cash", label: "Cash", accounts: open.filter((account) => CASH_TYPES.has(account.type ?? "")) },
    { id: "credit", label: "Credit", accounts: open.filter((account) => CREDIT_TYPES.has(account.type ?? "")) },
    { id: "tracking", label: "Tracking", accounts: open.filter((account) => !CASH_TYPES.has(account.type ?? "") && !CREDIT_TYPES.has(account.type ?? "")) },
    { id: "closed", label: "Closed", accounts: accounts.filter((account) => account.closed) },
  ];
  return [
    { id: "favourites", label: "Favourites", accounts: favourites },
    ...custom,
    ...builtIn,
  ].filter(hasAccounts).map((group) => ({
    ...group,
    accounts: orderedAccounts(group.accounts, group.id, preferences),
  }));
}

function orderedAccounts(accounts: Account[], groupId: string, preferences: AccountPreferences): Account[] {
  const sort = preferences.account_group_sorts[groupId] ?? "manual";
  if (sort === "alphabetical") return [...accounts].sort(accountNameOrder);
  const order = preferences.account_order_by_group[groupId] ?? preferences.account_order;
  const rank = new Map(order.map((id, index) => [id, index]));
  return [...accounts].sort((first, second) => {
    const firstRank = rank.get(first.id);
    const secondRank = rank.get(second.id);
    if (firstRank != null && secondRank != null && firstRank !== secondRank) return firstRank - secondRank;
    if (firstRank != null) return -1;
    if (secondRank != null) return 1;
    return accountNameOrder(first, second);
  });
}

function accountNameOrder(first: Account, second: Account): number {
  return first.name.localeCompare(second.name, undefined, { numeric: true, sensitivity: "base" }) || first.id.localeCompare(second.id);
}

function hasAccounts(group: AccountGroup): boolean {
  return group.accounts.length > 0;
}
