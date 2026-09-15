import { describe, expect, test } from "bun:test";
import type { Transaction } from "../api/types";
import {
  applyDeepLinkedTransactionMutation,
  buildTransactionDeepLink,
  deepLinkedTransactionForRegister,
  deepLinkTargetsRow,
  mergeDeepLinkedTransaction,
  parseTransactionDeepLink,
} from "./transaction-deep-link";

const parent = (id: string, subtransactionIds: string[] = []): Transaction => ({
  id,
  date: "2024-01-02",
  amount: -12000,
  memo: null,
  cleared: "cleared",
  approved: true,
  flag_color: null,
  flag_name: null,
  account_id: "account-1",
  account_name: "Checking",
  payee_id: null,
  payee_name: "Older invoice",
  category_id: null,
  category_name: null,
  transfer_account_id: null,
  transfer_transaction_id: null,
  deleted: false,
  subtransactions: subtransactionIds.map((id) => ({
    id,
    amount: -6000,
    payee_id: null,
    category_id: "category-1",
    memo: null,
    deleted: false,
  })),
});

describe("transaction deep links", () => {
  test("parses parent and split targets", () => {
    expect(parseTransactionDeepLink(new URLSearchParams("plan=plan-1&transaction=txn-1"))).toEqual({
      kind: "valid",
      link: { planId: "plan-1", transactionId: "txn-1", subtransactionId: null },
    });
    expect(parseTransactionDeepLink(new URLSearchParams("plan=plan-1&transaction=txn-1&subtransaction=sub-2"))).toEqual({
      kind: "valid",
      link: { planId: "plan-1", transactionId: "txn-1", subtransactionId: "sub-2" },
    });
  });

  test("rejects incomplete, blank, oversized, and ambiguous IDs", () => {
    expect(parseTransactionDeepLink(new URLSearchParams("transaction=txn-1")).kind).toBe("invalid");
    expect(parseTransactionDeepLink(new URLSearchParams("plan=plan-1&transaction=%20txn-1")).kind).toBe("invalid");
    expect(parseTransactionDeepLink(new URLSearchParams(`plan=plan-1&transaction=${"x".repeat(257)}`)).kind).toBe("invalid");
    expect(parseTransactionDeepLink(new URLSearchParams("plan=plan-1&plan=plan-2&transaction=txn-1")).kind).toBe("invalid");
  });

  test("builds the canonical URL while preserving supported filters and unrelated parameters", () => {
    expect(buildTransactionDeepLink(
      { planId: "plan 1", transactionId: "txn/1", subtransactionId: "sub:2" },
      new URLSearchParams("range=all&accounts=acct-1&categories=cat-1&flow=outflow&plan=old&transaction=old"),
    )).toBe("/transactions?plan=plan+1&transaction=txn%2F1&subtransaction=sub%3A2&range=all&accounts=acct-1&categories=cat-1&flow=outflow");
  });

  test("merges an older or filtered direct result without duplication", () => {
    const direct = parent("txn-old");
    expect(mergeDeepLinkedTransaction([parent("txn-current")], direct).map((row) => row.id))
      .toEqual(["txn-old", "txn-current"]);
    expect(mergeDeepLinkedTransaction([parent("txn-current"), parent("txn-old")], direct))
      .toEqual([parent("txn-current"), direct]);
  });

  test("accepts only the requested split belonging to the resolved parent", () => {
    const transaction = parent("txn-1", ["sub-1", "sub-2"]);
    expect(deepLinkTargetsRow({ planId: "plan-1", transactionId: "txn-1", subtransactionId: "sub-2" }, transaction)).toBeTrue();
    expect(deepLinkTargetsRow({ planId: "plan-1", transactionId: "txn-1", subtransactionId: "other" }, transaction)).toBeFalse();
    expect(deepLinkTargetsRow({ planId: "plan-1", transactionId: "other", subtransactionId: null }, transaction)).toBeFalse();
  });

  test("hides deleted direct results for parent and split targets and projects local approval", () => {
    const deleted = { ...parent("txn-1", ["sub-1"]), deleted: true };
    for (const subtransactionId of [null, "sub-1"]) {
      expect(deepLinkTargetsRow({ planId: "plan-1", transactionId: "txn-1", subtransactionId }, deleted)).toBeTrue();
      expect(deepLinkedTransactionForRegister(deleted, false)).toBeNull();
    }
    expect(deepLinkedTransactionForRegister({ ...parent("txn-1"), approved: false }, true)?.approved).toBeTrue();
  });

  test("settles confirmed mutations into the retained direct result", () => {
    const transaction = { ...parent("txn-1"), approved: false };
    const resolution = { key: "plan-1:txn-1:", transaction, loading: false, error: null };
    expect(applyDeepLinkedTransactionMutation(resolution, "txn-1", "approved").transaction?.approved).toBeTrue();
    expect(applyDeepLinkedTransactionMutation(resolution, "txn-1", "deleted").transaction).toBeNull();
    expect(applyDeepLinkedTransactionMutation(resolution, "other", "deleted")).toBe(resolution);
  });
});
