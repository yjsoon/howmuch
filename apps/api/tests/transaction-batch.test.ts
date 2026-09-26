import { describe, expect, test } from "bun:test";
import { parseTransactionDeleteBulk, parseTransactionUpdates } from "../src/transaction-batch";

describe("transaction collection ingress gaps not exercised by UI flows", () => {
  test("preserves null versus omitted approval and rejects non-boolean ingress", () => {
    expect(parseTransactionUpdates({ transactions: [
      { id: "null", approved: null },
      { id: "omitted", memo: "keep approval" },
      { id: "false", approved: false },
    ] })).toEqual([
      { lookup: { kind: "id", id: "null" }, patch: { approved: null } },
      { lookup: { kind: "id", id: "omitted" }, patch: { memo: "keep approval" } },
      { lookup: { kind: "id", id: "false" }, patch: { approved: false } },
    ]);
    for (const approved of [0, 1, "false", [], {}]) {
      expect(() => parseTransactionUpdates({ transactions: [{ id: "invalid", approved }] }))
        .toThrow("approved must be a boolean");
    }
  });

  test("rejects a malformed id instead of falling back to import_id", () => {
    expect(() => parseTransactionUpdates({
      transactions: [{ id: 123, import_id: "must-not-fallback", memo: "wrong-row" }],
    })).toThrow("transactions[0] id must be a non-empty string");
  });

  test("rejects malformed explicit approval guards rather than coercing or omitting them", () => {
    expect(() => parseTransactionDeleteBulk({
      transactions: [{ id: "t1", expected_approved: "false" }],
    })).toThrow("must be true or false");
    expect(() => parseTransactionDeleteBulk({
      transactions: [{ id: "t1", expected_approved: null }],
    })).toThrow("must be true or false");
  });
});
