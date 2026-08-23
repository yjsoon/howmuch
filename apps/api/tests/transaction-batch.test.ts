import { describe, expect, test } from "bun:test";
import {
  parseTransactionCollectionPatch,
  parseTransactionCollectionPost,
  parseTransactionInput,
} from "../src/transaction-batch";
import { MAX_TRANSACTION_WRITE_BATCH } from "../src/types";

describe("transaction collection parse", () => {
  test("accepts one or many POST bodies and rejects both", () => {
    expect(parseTransactionCollectionPost({ transaction: { account_id: "a" } }).mode).toBe("single");
    expect(parseTransactionCollectionPost({ transactions: [{ account_id: "a" }] }).mode).toBe("many");
    expect(() => parseTransactionCollectionPost({ transaction: {}, transactions: [] })).toThrow("exactly one");
    expect(() => parseTransactionCollectionPost({})).toThrow("exactly one");
  });

  test("caps and looks up collection PATCH items", () => {
    const edits = parseTransactionCollectionPatch({
      transactions: [
        { id: "txn-1", memo: "keep-id" },
        { import_id: "imp-1", account_id: "a", approved: true },
      ],
    });
    expect(edits[0]).toEqual({ lookup: { kind: "id", id: "txn-1" }, patch: { memo: "keep-id" } });
    expect(edits[1]).toEqual({
      lookup: { kind: "import_id", importId: "imp-1", accountId: "a" },
      patch: { account_id: "a", approved: true },
    });
    expect(() => parseTransactionCollectionPatch({
      transactions: [{ id: "txn-1", import_id: "imp-1" }],
    })).toThrow("exactly one");
    expect(() => parseTransactionCollectionPatch({ transactions: [] })).toThrow("between");
    expect(() => parseTransactionCollectionPatch({
      transactions: Array.from({ length: MAX_TRANSACTION_WRITE_BATCH + 1 }, (_, index) => ({ id: `t${index}` })),
    })).toThrow(`${MAX_TRANSACTION_WRITE_BATCH}`);
    expect(parseTransactionInput({ id: "txn-custom", account_id: "a", date: "2026-01-01", amount: -1 })).toEqual({
      id: "txn-custom",
      account_id: "a",
      date: "2026-01-01",
      amount: -1,
    });
  });
});
