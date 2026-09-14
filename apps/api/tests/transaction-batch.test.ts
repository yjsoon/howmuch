import { describe, expect, test } from "bun:test";
import {
  collectionPostIntent,
  parseTransactionClearedBulk,
  parseTransactionCreates,
  parseTransactionDeleteBulk,
  parseTransactionUpdates,
} from "../src/transaction-batch";
import { MAX_TRANSACTION_WRITE_BATCH } from "../src/types";

describe("transaction collection parse", () => {
  test("accepts one or many POST bodies and rejects both", () => {
    expect(collectionPostIntent({ transaction: { account_id: "a" } })).toBe("one");
    expect(collectionPostIntent({ transactions: [{ account_id: "a" }] })).toBe("many");
    expect(() => collectionPostIntent({ transaction: {}, transactions: [] })).toThrow("not both");
    expect(() => collectionPostIntent({})).toThrow("transaction is required");
  });

  test("caps and looks up collection PATCH items", () => {
    const edits = parseTransactionUpdates({
      transactions: [
        { id: "txn-1", import_id: "ignored", memo: "keep-id" },
        { import_id: "imp-1", approved: true },
      ],
    });
    expect(edits[0]).toEqual({ lookup: { kind: "id", id: "txn-1" }, patch: { memo: "keep-id" } });
    expect(edits[1]).toEqual({ lookup: { kind: "import_id", importId: "imp-1" }, patch: { approved: true } });
    expect(() => parseTransactionUpdates({
      transactions: [{ id: 123, import_id: "must-not-fallback", memo: "wrong-row" }],
    })).toThrow("transactions[0] id must be a non-empty string");
    expect(parseTransactionUpdates({
      transactions: [{ id: "txn-1", deleted: true, memo: "still-live" }],
    })).toEqual([{ lookup: { kind: "id", id: "txn-1" }, patch: { memo: "still-live" } }]);
    expect(() => parseTransactionUpdates({ transactions: [] })).toThrow("empty");
    expect(() => parseTransactionUpdates({
      transactions: Array.from({ length: MAX_TRANSACTION_WRITE_BATCH + 1 }, (_, index) => ({ id: `t${index}` })),
    })).toThrow(`${MAX_TRANSACTION_WRITE_BATCH}`);
    expect(parseTransactionCreates([{ id: "txn-custom", account_id: "a", date: "2026-01-01", amount: -1 }])).toEqual([
      { id: "txn-custom", account_id: "a", date: "2026-01-01", amount: -1 },
    ]);
    expect(() => parseTransactionCreates(
      Array.from({ length: MAX_TRANSACTION_WRITE_BATCH + 1 }, () => ({ account_id: "a", date: "2026-01-01", amount: -1 })),
    )).toThrow(`${MAX_TRANSACTION_WRITE_BATCH}`);
  });

  test("parses bulk cleared items with their own compare-and-set", () => {
    expect(parseTransactionClearedBulk({
      transactions: [
        { id: "t1", expected_cleared: "uncleared", cleared: "cleared" },
        { id: "t2", expected_cleared: "cleared", cleared: "uncleared" },
      ],
    })).toEqual([
      { id: "t1", expected_cleared: "uncleared", cleared: "cleared" },
      { id: "t2", expected_cleared: "cleared", cleared: "uncleared" },
    ]);
    expect(() => parseTransactionClearedBulk({
      transactions: [{ id: "t1", expected_cleared: "reconciled", cleared: "cleared" }],
    })).toThrow("uncleared or cleared");
    expect(() => parseTransactionClearedBulk({
      transactions: [{ expected_cleared: "uncleared", cleared: "cleared" }],
    })).toThrow("id must be a non-empty string");
    expect(() => parseTransactionClearedBulk({ transactions: [] })).toThrow("empty");
    expect(() => parseTransactionClearedBulk({
      transactions: Array.from({ length: MAX_TRANSACTION_WRITE_BATCH + 1 }, (_, index) => ({
        id: `t${index}`, expected_cleared: "uncleared", cleared: "cleared",
      })),
    })).toThrow(`${MAX_TRANSACTION_WRITE_BATCH}`);
    expect(() => parseTransactionClearedBulk({})).toThrow("transactions is required");
    expect(() => parseTransactionClearedBulk({
      transactions: [
        { id: "t1", expected_cleared: "uncleared", cleared: "cleared" },
        { id: "t1", expected_cleared: "cleared", cleared: "uncleared" },
      ],
    })).toThrow("Duplicate transaction id t1 in batch");
  });

  test("parses bulk delete items with an optional explicit approval guard", () => {
    expect(parseTransactionDeleteBulk({
      transactions: [{ id: "t1" }, { id: "t2", expected_approved: false }, { id: "t3", expected_approved: true }],
    })).toEqual([
      { id: "t1" },
      { id: "t2", expected_approved: false },
      { id: "t3", expected_approved: true },
    ]);
    expect(() => parseTransactionDeleteBulk({
      transactions: [{ id: "t1", expected_approved: "false" }],
    })).toThrow("must be true or false");
    expect(() => parseTransactionDeleteBulk({
      transactions: [{ id: "t1", expected_approved: null }],
    })).toThrow("must be true or false");
    expect(() => parseTransactionDeleteBulk({ transactions: [] })).toThrow("empty");
    expect(() => parseTransactionDeleteBulk({
      transactions: Array.from({ length: MAX_TRANSACTION_WRITE_BATCH + 1 }, (_, index) => ({ id: `t${index}` })),
    })).toThrow(`${MAX_TRANSACTION_WRITE_BATCH}`);
    expect(() => parseTransactionDeleteBulk({
      transactions: [{ id: "t1" }, { id: "t1", expected_approved: false }],
    })).toThrow("Duplicate transaction id t1 in batch");
  });
});
