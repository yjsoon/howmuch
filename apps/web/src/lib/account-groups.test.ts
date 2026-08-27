import { describe, expect, test } from "bun:test";
import type { Account, AccountPreferences } from "../api/types";
import { accountGroups, partitionAccountGroups } from "./account-groups";

const accounts: Account[] = [
  { id: "cash", name: "Wallet", icon: "💵", type: "cash", on_budget: true, closed: false, balance: 1000, cleared_balance: 1000, uncleared_balance: 0, transfer_payee_id: null, deleted: false },
  { id: "card", name: "Visa", icon: "💳", type: "creditCard", on_budget: true, closed: false, balance: -500, cleared_balance: -500, uncleared_balance: 0, transfer_payee_id: null, deleted: false },
  { id: "loan", name: "Loan", icon: "📉", type: "otherLiability", on_budget: false, closed: false, balance: -5000, cleared_balance: -5000, uncleared_balance: 0, transfer_payee_id: null, deleted: false },
];

const preferences: AccountPreferences = {
  favourite_account_ids: ["card", "cash"],
  account_order: [],
  account_order_by_group: {
    favourites: ["cash", "card"],
    "custom-daily": ["card", "cash"],
  },
  account_group_sorts: { favourites: "manual", "custom-daily": "manual", cash: "alphabetical" },
  custom_account_groups: [
    { id: "custom-daily", name: "Daily", account_ids: ["cash", "card"] },
  ],
};

describe("accountGroups", () => {
  test("projects mobile favourites, custom groups, built-ins, and manual order", () => {
    expect(accountGroups(accounts, preferences).map((group) => ({
      id: group.id,
      kind: group.kind,
      accountIds: group.accounts.map((account) => account.id),
    }))).toEqual([
      { id: "favourites", kind: "collection", accountIds: ["cash", "card"] },
      { id: "custom-daily", kind: "collection", accountIds: ["card", "cash"] },
      { id: "cash", kind: "index", accountIds: ["cash"] },
      { id: "credit", kind: "index", accountIds: ["card"] },
      { id: "tracking", kind: "index", accountIds: ["loan"] },
    ]);
    const partitioned = partitionAccountGroups(accountGroups(accounts, preferences));
    expect(partitioned.collections.map((group) => group.id)).toEqual(["favourites", "custom-daily"]);
    expect(partitioned.index.map((group) => group.id)).toEqual(["cash", "credit", "tracking"]);
  });

  test("uses mobile built-ins without synced preferences and keeps empty custom groups", () => {
    expect(accountGroups(accounts, null).map((group) => group.id)).toEqual(["cash", "credit", "tracking"]);
    expect(accountGroups(accounts, {
      ...preferences,
      favourite_account_ids: [],
      custom_account_groups: [{ id: "custom-empty", name: "Empty", account_ids: [] }],
    }).map((group) => group.id)).toEqual(["custom-empty", "cash", "credit", "tracking"]);
  });

  test("does not read inherited prototype values as group order or sort", () => {
    expect(() => accountGroups(accounts, {
      ...preferences,
      custom_account_groups: [{ id: "__proto__", name: "Broken", account_ids: ["cash"] }],
    })).not.toThrow();
  });

  test("uses 30-day account usage for the supported most-used sort", () => {
    expect(accountGroups(accounts, {
      ...preferences,
      account_group_sorts: { favourites: "mostUsedLast30Days" },
    }, { cash: 2, card: 8 }).find((group) => group.id === "favourites")?.accounts.map((account) => account.id))
      .toEqual(["card", "cash"]);
  });
});
