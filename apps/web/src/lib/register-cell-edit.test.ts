import { describe, expect, test } from "bun:test";
import type { Payee, Subtransaction, Transaction } from "../api/types";
import {
  beginCellEdit,
  cellBeginHint,
  cellGestureHandlers,
  cellRowId,
  idleCellEdit,
  parseAmountEntry,
  planCellCommit,
  postedCell,
  reduceCellEdit,
  sameCell,
  splitCell,
  type CellEditAction,
  type CellEditContext,
  type CellGestureEvent,
  type RegisterCellRef,
} from "./register-cell-edit";

function txn(overrides: Partial<Transaction> = {}): Transaction {
  return {
    id: "txn-1",
    date: "2026-08-01",
    amount: -3400,
    memo: "coffee",
    cleared: "uncleared",
    approved: true,
    flag_color: null,
    flag_name: null,
    account_id: "acct",
    account_name: "Everyday",
    payee_id: "p-shop",
    payee_name: "Shop",
    category_id: "cat-dining",
    category_name: "Dining Out",
    transfer_account_id: null,
    transfer_transaction_id: null,
    deleted: false,
    ...overrides,
  };
}

function line(overrides: Partial<Subtransaction> = {}): Subtransaction {
  return {
    id: "line-1",
    amount: -2000,
    payee_id: "p-shop",
    payee_name: "Shop",
    category_id: "cat-dining",
    category_name: "Dining Out",
    memo: "lunch",
    transfer_account_id: null,
    transfer_transaction_id: null,
    deleted: false,
    ...overrides,
  };
}

function splitParent(lines: Subtransaction[], overrides: Partial<Transaction> = {}): Transaction {
  const amount = lines.reduce((sum, item) => sum + item.amount, 0);
  return txn({
    id: "txn-split",
    amount,
    category_id: null,
    category_name: null,
    subtransactions: lines,
    ...overrides,
  });
}

function payee(id: string, name: string, transferAccountId?: string): Payee {
  return { id, name, transfer_account_id: transferAccountId ?? null, deleted: false };
}

const unlocked: CellEditContext = { writeLocked: false, mutatingId: null };
const shop = payee("p-shop", "Shop");
const coffee = payee("p-coffee", "Coffee");
const transfer = payee("p-xfer", "Transfer : Rainy Day Saver", "acct-saver");
const payees = [shop, coffee, transfer];

function gestureEvent(detail = 1): CellGestureEvent & { prevented: boolean } {
  const event = {
    detail,
    prevented: false,
    preventDefault() {
      event.prevented = true;
    },
  };
  return event;
}

describe("sameCell and cellRowId", () => {
  test("matches posted id and field, not object identity", () => {
    const a = postedCell(txn(), "memo");
    const b = postedCell(txn({ memo: "other" }), "memo");
    expect(sameCell(a, b)).toBe(true);
    expect(sameCell(a, postedCell(txn(), "payee"))).toBe(false);
    expect(cellRowId(a)).toBe("txn-1");
  });

  test("matches split parent id, line id, and field", () => {
    const parent = splitParent([line(), line({ id: "line-2" })]);
    const a = splitCell(parent, "line-1", "memo");
    const b = splitCell(txn({ id: "txn-split" }), "line-1", "memo");
    expect(sameCell(a, b)).toBe(true);
    expect(sameCell(a, splitCell(parent, "line-2", "memo"))).toBe(false);
    expect(cellRowId(a)).toBe("txn-split");
  });
});

describe("reduceCellEdit", () => {
  const cell = postedCell(txn(), "memo");
  const begin: CellEditAction = { type: "begin", cell, draft: "coffee" };
  const editing = reduceCellEdit(idleCellEdit(), begin);

  test("idle begin opens editing with a cleared error", () => {
    expect(editing).toEqual({ status: "editing", cell, draft: "coffee", error: null });
  });

  test("editing draft updates the value and clears the error", () => {
    const withError = reduceCellEdit(editing, { type: "invalid", message: "Enter an amount." });
    expect(reduceCellEdit(withError, { type: "draft", value: "tea" })).toEqual({
      status: "editing",
      cell,
      draft: "tea",
      error: null,
    });
  });

  test("editing invalid sets the error", () => {
    expect(reduceCellEdit(editing, { type: "invalid", message: "Choose a date." })).toEqual({
      status: "editing",
      cell,
      draft: "coffee",
      error: "Choose a date.",
    });
  });

  test("editing committing keeps the draft", () => {
    expect(reduceCellEdit(editing, { type: "committing" })).toEqual({
      status: "committing",
      cell,
      draft: "coffee",
    });
  });

  test("editing cancel returns idle", () => {
    expect(reduceCellEdit(editing, { type: "cancel" })).toEqual({ status: "idle" });
  });

  test("committing committed returns idle", () => {
    const committing = reduceCellEdit(editing, { type: "committing" });
    expect(reduceCellEdit(committing, { type: "committed" })).toEqual({ status: "idle" });
  });

  test("committing failed returns editing with the error and kept draft", () => {
    const committing = reduceCellEdit(editing, { type: "committing" });
    expect(reduceCellEdit(committing, { type: "failed", message: "Server down" })).toEqual({
      status: "editing",
      cell,
      draft: "coffee",
      error: "Server down",
    });
  });

  test("ignores actions that do not apply to the current status", () => {
    const idle = idleCellEdit();
    expect(reduceCellEdit(idle, { type: "draft", value: "x" })).toBe(idle);
    expect(reduceCellEdit(idle, { type: "invalid", message: "no" })).toBe(idle);
    expect(reduceCellEdit(idle, { type: "committing" })).toBe(idle);
    expect(reduceCellEdit(idle, { type: "committed" })).toBe(idle);
    expect(reduceCellEdit(idle, { type: "failed", message: "no" })).toBe(idle);
    expect(reduceCellEdit(idle, { type: "cancel" })).toBe(idle);
    expect(reduceCellEdit(editing, begin)).toBe(editing);
    expect(reduceCellEdit(editing, { type: "committed" })).toBe(editing);
    expect(reduceCellEdit(editing, { type: "failed", message: "no" })).toBe(editing);
    const committing = reduceCellEdit(editing, { type: "committing" });
    expect(reduceCellEdit(committing, begin)).toBe(committing);
    expect(reduceCellEdit(committing, { type: "draft", value: "x" })).toBe(committing);
    expect(reduceCellEdit(committing, { type: "cancel" })).toBe(committing);
    expect(reduceCellEdit(committing, { type: "invalid", message: "no" })).toBe(committing);
  });
});

describe("beginCellEdit", () => {
  test("seeds each posted field from the current value", () => {
    const row = txn();
    expect(beginCellEdit(postedCell(row, "date"), unlocked)).toEqual({
      kind: "begin",
      action: { type: "begin", cell: postedCell(row, "date"), draft: "2026-08-01" },
    });
    expect(beginCellEdit(postedCell(row, "payee"), unlocked)).toEqual({
      kind: "begin",
      action: { type: "begin", cell: postedCell(row, "payee"), draft: "Shop" },
    });
    expect(beginCellEdit(postedCell(row, "category"), unlocked)).toEqual({
      kind: "begin",
      action: { type: "begin", cell: postedCell(row, "category"), draft: "cat-dining" },
    });
    expect(beginCellEdit(postedCell(row, "memo"), unlocked)).toEqual({
      kind: "begin",
      action: { type: "begin", cell: postedCell(row, "memo"), draft: "coffee" },
    });
    expect(beginCellEdit(postedCell(row, "outflow"), unlocked)).toEqual({
      kind: "begin",
      action: { type: "begin", cell: postedCell(row, "outflow"), draft: "3.40" },
    });
  });

  test("seeds null payee, category, and memo as empty strings", () => {
    const row = txn({ payee_name: null, category_id: null, memo: null });
    expect(beginCellEdit(postedCell(row, "payee"), unlocked)).toMatchObject({
      kind: "begin",
      action: { draft: "" },
    });
    expect(beginCellEdit(postedCell(row, "category"), unlocked)).toMatchObject({
      kind: "begin",
      action: { draft: "" },
    });
    expect(beginCellEdit(postedCell(row, "memo"), unlocked)).toMatchObject({
      kind: "begin",
      action: { draft: "" },
    });
  });

  test("seeds an occupied inflow", () => {
    const row = txn({ amount: 5000 });
    expect(beginCellEdit(postedCell(row, "inflow"), unlocked)).toEqual({
      kind: "begin",
      action: { type: "begin", cell: postedCell(row, "inflow"), draft: "5.00" },
    });
  });

  test("refuses writeLocked", () => {
    expect(beginCellEdit(postedCell(txn(), "memo"), { writeLocked: true, mutatingId: null })).toEqual({
      kind: "refuse",
      reason: "locked",
    });
  });

  test("refuses when mutatingId is this row", () => {
    expect(beginCellEdit(postedCell(txn(), "memo"), { writeLocked: false, mutatingId: "txn-1" })).toEqual({
      kind: "refuse",
      reason: "row-busy",
    });
  });

  test("begins when mutatingId is another row", () => {
    expect(beginCellEdit(postedCell(txn(), "memo"), { writeLocked: false, mutatingId: "other" }).kind).toBe("begin");
  });

  test("refuses a transfer payee and category", () => {
    const row = txn({ transfer_account_id: "acct-saver", payee_name: "Transfer : Rainy Day Saver" });
    expect(beginCellEdit(postedCell(row, "payee"), unlocked)).toEqual({ kind: "refuse", reason: "transfer-payee" });
    expect(beginCellEdit(postedCell(row, "category"), unlocked)).toEqual({ kind: "refuse", reason: "transfer-category" });
    expect(beginCellEdit(postedCell(row, "memo"), unlocked).kind).toBe("begin");
  });

  test("refuses a split parent category and amount", () => {
    const parent = splitParent([line(), line({ id: "line-2", amount: -1400 })]);
    expect(beginCellEdit(postedCell(parent, "category"), unlocked)).toEqual({
      kind: "refuse",
      reason: "split-parent-category",
    });
    expect(beginCellEdit(postedCell(parent, "outflow"), unlocked)).toEqual({
      kind: "refuse",
      reason: "split-parent-amount",
    });
    expect(beginCellEdit(postedCell(parent, "inflow"), unlocked)).toEqual({
      kind: "refuse",
      reason: "split-parent-amount",
    });
    expect(beginCellEdit(postedCell(parent, "payee"), unlocked).kind).toBe("begin");
  });

  test("refuses a missing split line", () => {
    const parent = splitParent([line()]);
    expect(beginCellEdit(splitCell(parent, "gone", "memo"), unlocked)).toEqual({
      kind: "refuse",
      reason: "missing-line",
    });
  });

  test("refuses transfer payee and category on a split line", () => {
    const transferLine = line({
      id: "line-xfer",
      transfer_account_id: "acct-saver",
      payee_name: "Transfer : Rainy Day Saver",
      category_id: null,
    });
    const parent = splitParent([line(), transferLine]);
    expect(beginCellEdit(splitCell(parent, "line-xfer", "payee"), unlocked)).toEqual({
      kind: "refuse",
      reason: "transfer-payee",
    });
    expect(beginCellEdit(splitCell(parent, "line-xfer", "category"), unlocked)).toEqual({
      kind: "refuse",
      reason: "transfer-category",
    });
    expect(beginCellEdit(splitCell(parent, "line-xfer", "memo"), unlocked).kind).toBe("begin");
  });

  test("refuses the empty amount side and keeps the occupied side", () => {
    const outflow = txn({ amount: -3400 });
    const inflow = txn({ amount: 5000 });
    expect(beginCellEdit(postedCell(outflow, "inflow"), unlocked)).toEqual({
      kind: "refuse",
      reason: "empty-amount-side",
    });
    expect(beginCellEdit(postedCell(inflow, "outflow"), unlocked)).toEqual({
      kind: "refuse",
      reason: "empty-amount-side",
    });
    expect(beginCellEdit(postedCell(outflow, "outflow"), unlocked).kind).toBe("begin");
    expect(beginCellEdit(postedCell(inflow, "inflow"), unlocked).kind).toBe("begin");
  });

  test("refuses both amount sides when the amount is zero", () => {
    const zero = txn({ amount: 0 });
    expect(beginCellEdit(postedCell(zero, "outflow"), unlocked)).toEqual({
      kind: "refuse",
      reason: "empty-amount-side",
    });
    expect(beginCellEdit(postedCell(zero, "inflow"), unlocked)).toEqual({
      kind: "refuse",
      reason: "empty-amount-side",
    });
  });

  test("refuses the empty amount side on a split line", () => {
    const parent = splitParent([line({ amount: -2000 })]);
    expect(beginCellEdit(splitCell(parent, "line-1", "inflow"), unlocked)).toEqual({
      kind: "refuse",
      reason: "empty-amount-side",
    });
    expect(beginCellEdit(splitCell(parent, "line-1", "outflow"), unlocked).kind).toBe("begin");
  });

  test("puts British copy on every refusal reason", () => {
    expect(cellBeginHint("empty-amount-side")).toBe("Edit the amount in the other column.");
    expect(cellBeginHint("transfer-payee")).toBe("Transfers keep their linked account.");
    expect(cellBeginHint("split-parent-amount")).toBe("Change a split line instead.");
  });
});

describe("planCellCommit", () => {
  test("returns unchanged when the draft matches the current value", () => {
    const row = txn();
    expect(planCellCommit(postedCell(row, "date"), "2026-08-01", payees)).toEqual({ kind: "unchanged" });
    expect(planCellCommit(postedCell(row, "payee"), "  shop  ", payees)).toEqual({ kind: "unchanged" });
    expect(planCellCommit(postedCell(row, "category"), "cat-dining", payees)).toEqual({ kind: "unchanged" });
    expect(planCellCommit(postedCell(row, "memo"), " coffee ", payees)).toEqual({ kind: "unchanged" });
    expect(planCellCommit(postedCell(row, "outflow"), "3.40", payees)).toEqual({ kind: "unchanged" });
  });

  test("patches date, memo, category, and payee as one field", () => {
    const row = txn();
    expect(planCellCommit(postedCell(row, "date"), "2026-08-15", payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { date: "2026-08-15" },
    });
    expect(planCellCommit(postedCell(row, "memo"), "  tea  ", payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { memo: "tea" },
    });
    expect(planCellCommit(postedCell(row, "memo"), "   ", payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { memo: null },
    });
    expect(planCellCommit(postedCell(row, "category"), "", payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { category_id: null },
    });
    expect(planCellCommit(postedCell(row, "payee"), "Coffee", payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { payee_id: "p-coffee", payee_name: "Coffee" },
    });
  });

  test("rejects an empty date", () => {
    expect(planCellCommit(postedCell(txn(), "date"), "", payees)).toEqual({
      kind: "invalid",
      message: "Choose a date.",
    });
  });

  test("keeps amount sign from the occupied column and allows zero", () => {
    expect(planCellCommit(postedCell(txn({ amount: -3400 }), "outflow"), "5", payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { amount: -5000 },
    });
    expect(planCellCommit(postedCell(txn({ amount: 5000 }), "inflow"), "1.25", payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { amount: 1250 },
    });
    expect(planCellCommit(postedCell(txn({ amount: -3400 }), "outflow"), "0", payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { amount: 0 },
    });
  });

  test("rejects an unparseable amount", () => {
    expect(planCellCommit(postedCell(txn(), "outflow"), "nope", payees)).toEqual({
      kind: "invalid",
      message: "Enter an amount.",
    });
  });

  test("rejects a transfer payee name", () => {
    expect(planCellCommit(postedCell(txn(), "payee"), "transfer : rainy day saver", payees)).toEqual({
      kind: "invalid",
      message: "Create a transfer from compose, not by renaming a payee.",
    });
  });

  test("rebuilds every split line when one memo changes", () => {
    const first = line();
    const second = line({ id: "line-2", amount: -1400, payee_name: "Coffee", payee_id: "p-coffee", memo: null });
    const parent = splitParent([first, second]);
    expect(planCellCommit(splitCell(parent, "line-1", "memo"), "updated", payees)).toEqual({
      kind: "patch",
      transactionId: "txn-split",
      input: {
        subtransactions: [
          {
            id: "line-1",
            amount: -2000,
            payee_id: "p-shop",
            payee_name: "Shop",
            category_id: "cat-dining",
            memo: "updated",
            transfer_account_id: null,
            transfer_transaction_id: null,
          },
          {
            id: "line-2",
            amount: -1400,
            payee_id: "p-coffee",
            payee_name: "Coffee",
            category_id: "cat-dining",
            memo: null,
            transfer_account_id: null,
            transfer_transaction_id: null,
          },
        ],
      },
    });
  });

  test("moves the parent amount when a split line amount changes", () => {
    const first = line({ amount: -2000 });
    const second = line({ id: "line-2", amount: -1400, payee_id: null, payee_name: null, memo: null, category_id: null });
    const parent = splitParent([first, second]);
    expect(planCellCommit(splitCell(parent, "line-2", "outflow"), "3.00", payees)).toEqual({
      kind: "patch",
      transactionId: "txn-split",
      input: {
        amount: -5000,
        subtransactions: [
          {
            id: "line-1",
            amount: -2000,
            payee_id: "p-shop",
            payee_name: "Shop",
            category_id: "cat-dining",
            memo: "lunch",
            transfer_account_id: null,
            transfer_transaction_id: null,
          },
          {
            id: "line-2",
            amount: -3000,
            payee_id: null,
            payee_name: null,
            category_id: null,
            memo: null,
            transfer_account_id: null,
            transfer_transaction_id: null,
          },
        ],
      },
    });
  });

  test("passes transfer fields through on a split-line rebuild", () => {
    const transferLine = line({
      id: "line-xfer",
      amount: -1400,
      transfer_account_id: "acct-saver",
      transfer_transaction_id: "txn-mirror",
      payee_id: "p-xfer",
      payee_name: "Transfer : Rainy Day Saver",
      category_id: null,
      memo: "keep",
    });
    const parent = splitParent([line(), transferLine]);
    const plan = planCellCommit(splitCell(parent, "line-xfer", "memo"), "moved", payees);
    expect(plan).toMatchObject({
      kind: "patch",
      input: {
        subtransactions: [
          { id: "line-1" },
          {
            id: "line-xfer",
            memo: "moved",
            transfer_account_id: "acct-saver",
            transfer_transaction_id: "txn-mirror",
            payee_id: "p-xfer",
          },
        ],
      },
    });
  });
});

describe("parseAmountEntry", () => {
  test("parses a plain decimal through parseMilliunits", () => {
    expect(parseAmountEntry("3.40")).toBe(3400);
    expect(parseAmountEntry("0")).toBe(0);
    expect(parseAmountEntry("1.135")).toBe(1135);
  });

  test("adds and subtracts in exact milliunits", () => {
    expect(parseAmountEntry("3.40+1.60")).toBe(5000);
    expect(parseAmountEntry("3.40 + 1.60")).toBe(5000);
    expect(parseAmountEntry("5-2")).toBe(3000);
  });

  test("divides and multiplies with half-away-from-zero milliunit rounding", () => {
    expect(parseAmountEntry("12/4")).toBe(3000);
    expect(parseAmountEntry("2*3")).toBe(6000);
    expect(parseAmountEntry("20/3")).toBe(6667);
  });

  test("honours multiplication precedence and parentheses", () => {
    expect(parseAmountEntry("1+2*3")).toBe(7000);
    expect(parseAmountEntry("(1+2)*3")).toBe(9000);
  });

  test("returns null for garbage or a negative result", () => {
    expect(parseAmountEntry("")).toBeNull();
    expect(parseAmountEntry("nope")).toBeNull();
    expect(parseAmountEntry("-1")).toBeNull();
    expect(parseAmountEntry("1-2")).toBeNull();
    expect(parseAmountEntry("1/0")).toBeNull();
  });
});

describe("cellGestureHandlers", () => {
  test("prevents default on a second mousedown", () => {
    const handlers = cellGestureHandlers(postedCell(txn(), "memo"), unlocked, () => {});
    const second = gestureEvent(2);
    handlers.onMouseDown(second);
    expect(second.prevented).toBeTrue();
    const first = gestureEvent(1);
    handlers.onMouseDown(first);
    expect(first.prevented).toBeFalse();
  });

  test("begins once on double-click", () => {
    const started: RegisterCellRef[] = [];
    const cell = postedCell(txn(), "memo");
    const handlers = cellGestureHandlers(cell, unlocked, (action) => {
      started.push(action.cell);
    });
    handlers.onDoubleClick(gestureEvent());
    expect(started).toEqual([cell]);
  });

  test("stays silent on a refused double-click", () => {
    const started: string[] = [];
    const cell = postedCell(txn({ transfer_account_id: "acct-saver" }), "payee");
    const handlers = cellGestureHandlers(cell, unlocked, () => {
      started.push("began");
    });
    handlers.onDoubleClick(gestureEvent());
    expect(started).toEqual([]);
  });

  test("stays silent on an empty amount side", () => {
    const started: string[] = [];
    const handlers = cellGestureHandlers(postedCell(txn(), "inflow"), unlocked, () => {
      started.push("began");
    });
    handlers.onDoubleClick(gestureEvent());
    expect(started).toEqual([]);
  });
});
