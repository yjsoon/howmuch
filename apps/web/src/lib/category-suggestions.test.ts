import { expect, test } from "bun:test";
import type { Transaction } from "../api/types";
import { appliedReviewItems, reviewRows, suggestionTargets, type CategorySuggestion } from "./category-suggestions";

const txn = (id: string, patch: Partial<Transaction> = {}): Transaction => ({
  id, date: "2026-09-01", amount: -10_000, memo: null, cleared: "uncleared", approved: false,
  flag_color: null, flag_name: null, account_id: "card", account_name: "Visa", payee_id: null,
  payee_name: "Shop", category_id: null, category_name: null, transfer_account_id: null,
  transfer_transaction_id: null, deleted: false, ...patch,
} as Transaction);

const suggest = (key: string, categoryId: string | null, confidence: number): CategorySuggestion => ({
  key,
  suggestion: categoryId ? { category_id: categoryId, category_name: categoryId, group_name: "G", probability: confidence } : null,
  confidence,
  alternatives: [],
});

test("only asks about categorisable rows with something to read", () => {
  const rows = [
    txn("plain"),
    txn("transfer", { transfer_account_id: "savings" }),
    txn("blank", { payee_name: null, memo: " " }),
    txn("memo-only", { payee_name: null, memo: "lunch" }),
  ];
  expect(suggestionTargets(rows).map((row) => row.id)).toEqual(["plain", "memo-only"]);
});

test("ticks confident changes only and applies ticked edits", () => {
  const rows = [txn("sure"), txn("unsure"), txn("none"), txn("same", { category_id: "food" })];
  const review = reviewRows(rows, [
    suggest("sure", "transport", 0.9),
    suggest("unsure", "food", 0.3),
    suggest("none", null, 0.7),
    suggest("same", "food", 0.95),
  ]);
  expect(review.map((row) => [row.transaction.id, row.categoryId, row.include])).toEqual([
    ["sure", "transport", true],
    ["unsure", "food", false],
    ["none", "", false],
    ["same", "food", false],
  ]);
  review[1] = { ...review[1], include: true };
  expect(appliedReviewItems(review)).toEqual([
    { id: "sure", category_id: "transport" },
    { id: "unsure", category_id: "food" },
  ]);
});
