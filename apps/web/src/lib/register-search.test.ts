import { describe, expect, test } from "bun:test";
import { mergeSearchRows, parseRegisterQuery, searchStatusCopy, transactionMatchesQuery } from "./register-search";
import type { Transaction } from "../api/types";

function txn(id: string, date: string, payee: string, amount: number): Transaction {
  return {
    id,
    date,
    amount,
    memo: null,
    cleared: "cleared",
    approved: true,
    flag_color: null,
    flag_name: null,
    account_id: "acct",
    account_name: "Everyday Account",
    payee_id: null,
    payee_name: payee,
    category_id: null,
    category_name: "Groceries",
    transfer_account_id: null,
    transfer_transaction_id: null,
    deleted: false,
  };
}

describe("register search helpers", () => {
  test("matches displayed amounts and merges older hits", () => {
    const fairPrice = txn("fp", "2024-01-15", "FairPrice Finest", -142300);
    const scoot = txn("sc", "2026-08-01", "Scoot", -12000);
    expect(transactionMatchesQuery(parseRegisterQuery("142.30"), fairPrice)).toBe(true);
    expect(transactionMatchesQuery(parseRegisterQuery("12"), fairPrice)).toBe(false);
    const merged = mergeSearchRows([scoot], [fairPrice, scoot]);
    expect(merged.map((row) => row.id)).toEqual(["sc", "fp"]);
  });

  test("coverage copy names the load-older button", () => {
    expect(
      searchStatusCopy({ shown: 3, scheduled: 0, hasMore: true, loading: false, error: null }),
    ).toBe("Showing 3 matches so far. Load older matches to see more.");
    expect(
      searchStatusCopy({ shown: 1, scheduled: 0, hasMore: false, loading: false, error: null }).toLowerCase(),
    ).not.toContain("scroll");
  });
});
