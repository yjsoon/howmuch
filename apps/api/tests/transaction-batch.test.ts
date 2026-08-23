import { describe, expect, test } from "bun:test";
import { collectionPostIntent, parseTransactionCreates, parseTransactionUpdates } from "../src/transaction-batch";
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
});
