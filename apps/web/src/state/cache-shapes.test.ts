import { describe, expect, test } from "bun:test";
import {
  isCachedPayees,
  isCachedReference,
  isCachedRegisterPage,
  isCachedScheduled,
} from "./cache-shapes";

// Synthetic throughout: invented ids, invented names, invented amounts.

const reference = {
  settings: { currency_format: { iso_code: "SGD" } },
  categoryGroups: [{ id: "group-1", name: "Everyday", categories: [{ id: "category-1" }] }],
  accounts: [{ id: "account-1", name: "Test Account", balance: 1000 }],
  accountPreferences: { account_preferences: null, account_preferences_revision: 2 },
};

describe("isCachedReference", () => {
  test("accepts a complete reference set", () => {
    expect(isCachedReference(reference)).toBe(true);
  });

  test("accepts a set whose server has no account preferences", () => {
    expect(isCachedReference({ ...reference, accountPreferences: null })).toBe(true);
  });

  test("rejects a build that stored accounts under another name", () => {
    const { accounts, ...rest } = reference;
    expect(isCachedReference({ ...rest, account_list: accounts })).toBe(false);
  });

  test("rejects a category group with no categories array", () => {
    expect(isCachedReference({
      ...reference,
      categoryGroups: [{ id: "group-1", name: "Everyday" }],
    })).toBe(false);
  });

  test("rejects an account missing the balance the shell renders", () => {
    expect(isCachedReference({ ...reference, accounts: [{ id: "account-1", name: "Test Account" }] })).toBe(false);
  });

  test("rejects anything that is not an object", () => {
    expect(isCachedReference(null)).toBe(false);
    expect(isCachedReference([reference])).toBe(false);
    expect(isCachedReference("reference")).toBe(false);
  });
});

describe("isCachedPayees", () => {
  test("accepts a list of payees", () => {
    expect(isCachedPayees([{ id: "payee-1", name: "Synthetic Grocer" }])).toBe(true);
  });

  test("accepts an empty list", () => {
    expect(isCachedPayees([])).toBe(true);
  });

  test("rejects an entry with a blank id", () => {
    expect(isCachedPayees([{ id: "", name: "Synthetic Grocer" }])).toBe(false);
  });

  test("rejects a bare object", () => {
    expect(isCachedPayees({ payees: [] })).toBe(false);
  });
});

describe("isCachedScheduled", () => {
  test("accepts schedules identified only by id", () => {
    expect(isCachedScheduled([{ id: "scheduled-1", date_next: "2026-10-01" }])).toBe(true);
  });

  test("rejects a list holding something without an id", () => {
    expect(isCachedScheduled([{ date_next: "2026-10-01" }])).toBe(false);
  });
});

describe("isCachedRegisterPage", () => {
  const page = {
    listKey: "list-1",
    transactions: [{ id: "txn-1", date: "2026-01-01", amount: -1000, account_id: "account-1" }],
    hasMore: true,
    nextOffset: 250,
  };

  test("accepts a first page", () => {
    expect(isCachedRegisterPage(page)).toBe(true);
  });

  test("accepts a page that ended the register", () => {
    expect(isCachedRegisterPage({ ...page, hasMore: false, nextOffset: null })).toBe(true);
  });

  test("rejects a page with no list key, which could seed the wrong filters", () => {
    expect(isCachedRegisterPage({ ...page, listKey: "" })).toBe(false);
  });

  test("rejects a row missing the fields the register reads", () => {
    expect(isCachedRegisterPage({ ...page, transactions: [{ id: "txn-1", date: "2026-01-01" }] })).toBe(false);
  });
});
