import { describe, expect, test } from "bun:test";
import type { Payee, Subtransaction, Transaction } from "../api/types";
import {
  beginRowEdit,
  idleRowEdit,
  parseAmountEntry,
  payeeListEntries,
  planRowCommit,
  focusForRowError,
  postingAccountId,
  reduceRowEdit,
  rowFieldWritable,
  rowGestureHandlers,
  rowId,
  sameRow,
  sessionRowGone,
  transferOptionLabel,
  writableFocus,
  type RegisterRowDraft,
  type RegisterRowEditAction,
  type RegisterRowFocus,
  type RegisterRowRef,
  type RowEditContext,
  type RowGestureEvent,
} from "./register-row-edit";

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

function posted(transaction: Transaction): RegisterRowRef {
  return { kind: "posted", transaction };
}

function splitLine(parent: Transaction, lineId: string): RegisterRowRef {
  return { kind: "split-line", parent, lineId };
}

const unlocked: RowEditContext = { writeLocked: false, mutatingId: null };
const shop = payee("p-shop", "Shop");
const coffee = payee("p-coffee", "Coffee");
const transfer = payee("p-xfer", "Transfer : Rainy Day Saver", "acct-saver");
const payees = [shop, coffee, transfer];

const shopDraft: RegisterRowDraft = {
  date: "2026-08-01",
  payeeName: "Shop",
  categoryId: "cat-dining",
  memo: "coffee",
  outflow: "3.40",
  inflow: "",
  flagColor: "",
};

function gestureEvent(detail = 1): RowGestureEvent & { prevented: boolean } {
  const event = {
    detail,
    prevented: false,
    preventDefault() {
      event.prevented = true;
    },
  };
  return event;
}

describe("sameRow and rowId", () => {
  test("matches posted id, not object identity", () => {
    const a = posted(txn());
    const b = posted(txn({ memo: "other" }));
    expect(sameRow(a, b)).toBe(true);
    expect(sameRow(a, posted(txn({ id: "other" })))).toBe(false);
    expect(rowId(a)).toBe("txn-1");
  });

  test("matches split parent id and line id", () => {
    const parent = splitParent([line(), line({ id: "line-2" })]);
    const a = splitLine(parent, "line-1");
    const b = splitLine(txn({ id: "txn-split" }), "line-1");
    expect(sameRow(a, b)).toBe(true);
    expect(sameRow(a, splitLine(parent, "line-2"))).toBe(false);
    expect(sameRow(a, posted(parent))).toBe(false);
    expect(rowId(a)).toBe("txn-split");
  });
});

describe("reduceRowEdit", () => {
  const row = posted(txn());
  const begin: RegisterRowEditAction = { type: "begin", row, draft: shopDraft, focus: "memo" };
  const editing = reduceRowEdit(idleRowEdit(), begin);

  test("idle begin opens editing with a cleared error", () => {
    expect(editing).toEqual({
      status: "editing",
      row,
      draft: shopDraft,
      focus: "memo",
      error: null,
    });
  });

  test("editing patch updates fields and clears the error", () => {
    const withError = reduceRowEdit(editing, { type: "invalid", message: "Enter an outflow or an inflow." });
    expect(reduceRowEdit(withError, { type: "patch", draft: { memo: "tea" } })).toEqual({
      status: "editing",
      row,
      draft: { ...shopDraft, memo: "tea" },
      focus: "memo",
      error: null,
    });
  });

  test("set-outflow clears inflow when the value is non-empty", () => {
    const both = reduceRowEdit(editing, { type: "patch", draft: { memo: "coffee" } });
    const withInflow = reduceRowEdit(both, { type: "set-inflow", value: "5.00" });
    expect(withInflow).toMatchObject({ draft: { inflow: "5.00", outflow: "" }, error: null });
    expect(reduceRowEdit(withInflow, { type: "set-outflow", value: "1.25" })).toMatchObject({
      draft: { outflow: "1.25", inflow: "" },
      error: null,
    });
  });

  test("empty set-outflow keeps the other column", () => {
    const withInflow = reduceRowEdit(editing, { type: "set-inflow", value: "5.00" });
    expect(reduceRowEdit(withInflow, { type: "set-outflow", value: "  " })).toMatchObject({
      draft: { outflow: "  ", inflow: "5.00" },
    });
  });

  test("editing invalid sets the error", () => {
    expect(reduceRowEdit(editing, { type: "invalid", message: "Choose a date." })).toEqual({
      status: "editing",
      row,
      draft: shopDraft,
      focus: "memo",
      error: "Choose a date.",
    });
  });

  test("editing committing keeps the draft", () => {
    expect(reduceRowEdit(editing, { type: "committing" })).toEqual({
      status: "committing",
      row,
      draft: shopDraft,
    });
  });

  test("editing cancel returns idle", () => {
    expect(reduceRowEdit(editing, { type: "cancel" })).toEqual({ status: "idle" });
  });

  test("committing committed returns idle", () => {
    const committing = reduceRowEdit(editing, { type: "committing" });
    expect(reduceRowEdit(committing, { type: "committed" })).toEqual({ status: "idle" });
  });

  test("committing failed returns editing with the error and kept draft", () => {
    const committing = reduceRowEdit(editing, { type: "committing" });
    expect(reduceRowEdit(committing, { type: "failed", message: "Server down" })).toEqual({
      status: "editing",
      row,
      draft: shopDraft,
      focus: "date",
      error: "Server down",
    });
  });

  test("begin is idle-only", () => {
    const idle = idleRowEdit();
    expect(reduceRowEdit(editing, begin)).toBe(editing);
    const committing = reduceRowEdit(editing, { type: "committing" });
    expect(reduceRowEdit(committing, begin)).toBe(committing);
    expect(reduceRowEdit(idle, begin)).toEqual(editing);
  });

  test("ignores actions that do not apply to the current status", () => {
    const idle = idleRowEdit();
    expect(reduceRowEdit(idle, { type: "patch", draft: { memo: "x" } })).toBe(idle);
    expect(reduceRowEdit(idle, { type: "set-outflow", value: "1" })).toBe(idle);
    expect(reduceRowEdit(idle, { type: "set-inflow", value: "1" })).toBe(idle);
    expect(reduceRowEdit(idle, { type: "invalid", message: "no" })).toBe(idle);
    expect(reduceRowEdit(idle, { type: "committing" })).toBe(idle);
    expect(reduceRowEdit(idle, { type: "committed" })).toBe(idle);
    expect(reduceRowEdit(idle, { type: "failed", message: "no" })).toBe(idle);
    expect(reduceRowEdit(idle, { type: "cancel" })).toBe(idle);
    expect(reduceRowEdit(editing, { type: "committed" })).toBe(editing);
    expect(reduceRowEdit(editing, { type: "failed", message: "no" })).toBe(editing);
    const committing = reduceRowEdit(editing, { type: "committing" });
    expect(reduceRowEdit(committing, { type: "patch", draft: { memo: "x" } })).toBe(committing);
    expect(reduceRowEdit(committing, { type: "cancel" })).toBe(committing);
    expect(reduceRowEdit(committing, { type: "invalid", message: "no" })).toBe(committing);
  });
});

describe("beginRowEdit", () => {
  test("seeds every posted draft field from the current value", () => {
    const row = posted(txn());
    expect(beginRowEdit(row, "category", unlocked)).toEqual({
      kind: "begin",
      action: { type: "begin", row, draft: shopDraft, focus: "category" },
    });
  });

  test("seeds null payee, category, and memo as empty strings", () => {
    const row = posted(txn({ payee_name: null, category_id: null, memo: null }));
    expect(beginRowEdit(row, "payee", unlocked)).toMatchObject({
      kind: "begin",
      action: { draft: { payeeName: "", categoryId: "", memo: "" } },
    });
  });

  test("seeds an occupied inflow and leaves outflow empty", () => {
    const row = posted(txn({ amount: 5000 }));
    expect(beginRowEdit(row, "inflow", unlocked)).toMatchObject({
      kind: "begin",
      action: { draft: { outflow: "", inflow: "5.00" } },
    });
  });

  test("seeds both amount columns empty when the amount is zero", () => {
    const row = posted(txn({ amount: 0 }));
    expect(beginRowEdit(row, "outflow", unlocked)).toMatchObject({
      kind: "begin",
      action: { draft: { outflow: "", inflow: "" } },
    });
  });

  test("refuses writeLocked", () => {
    expect(beginRowEdit(posted(txn()), "memo", { writeLocked: true, mutatingId: null })).toEqual({
      kind: "refuse",
      reason: "locked",
    });
  });

  test("refuses when mutatingId is this row", () => {
    expect(beginRowEdit(posted(txn()), "memo", { writeLocked: false, mutatingId: "txn-1" })).toEqual({
      kind: "refuse",
      reason: "row-busy",
    });
  });

  test("begins when mutatingId is another row", () => {
    expect(beginRowEdit(posted(txn()), "memo", { writeLocked: false, mutatingId: "other" }).kind).toBe("begin");
  });

  test("begins a transfer posted row and still seeds payee and category", () => {
    const row = posted(txn({
      transfer_account_id: "acct-saver",
      payee_name: "Transfer : Rainy Day Saver",
      category_id: null,
    }));
    const decision = beginRowEdit(row, "payee", unlocked);
    expect(decision.kind).toBe("begin");
    expect(decision).toMatchObject({
      action: { draft: { payeeName: "Transfer : Rainy Day Saver", categoryId: "" } },
    });
    expect(beginRowEdit(row, "category", unlocked).kind).toBe("begin");
  });

  test("begins a split parent including category and amount focus", () => {
    const parent = splitParent([line(), line({ id: "line-2", amount: -1400 })]);
    const row = posted(parent);
    expect(beginRowEdit(row, "category", unlocked).kind).toBe("begin");
    expect(beginRowEdit(row, "outflow", unlocked).kind).toBe("begin");
    expect(beginRowEdit(row, "payee", unlocked)).toMatchObject({
      kind: "begin",
      action: { draft: { payeeName: "Shop", categoryId: "", outflow: "3.40", inflow: "" } },
    });
  });

  test("refuses a linked split-mirror posted row", () => {
    expect(beginRowEdit(posted(txn({ parent_transaction_id: "txn-split" })), "memo", unlocked)).toEqual({
      kind: "refuse",
      reason: "linked-mirror",
    });
  });

  test("keeps payee focus on a saved transfer and snaps category onto date", () => {
    const row = posted(txn({
      transfer_account_id: "acct-saver",
      payee_name: "Transfer : Rainy Day Saver",
      category_id: null,
    }));
    expect(beginRowEdit(row, "payee", unlocked)).toMatchObject({
      action: { focus: "payee" },
    });
    expect(beginRowEdit(row, "category", unlocked)).toMatchObject({
      action: { focus: "date" },
    });
  });

  test("refuses a missing split line", () => {
    const parent = splitParent([line()]);
    expect(beginRowEdit(splitLine(parent, "gone"), "memo", unlocked)).toEqual({
      kind: "refuse",
      reason: "missing-line",
    });
  });

  test("begins a transfer split line", () => {
    const transferLine = line({
      id: "line-xfer",
      transfer_account_id: "acct-saver",
      payee_name: "Transfer : Rainy Day Saver",
      category_id: null,
    });
    const parent = splitParent([line(), transferLine]);
    const row = splitLine(parent, "line-xfer");
    expect(beginRowEdit(row, "payee", unlocked).kind).toBe("begin");
    expect(beginRowEdit(row, "category", unlocked).kind).toBe("begin");
    expect(beginRowEdit(row, "memo", unlocked)).toMatchObject({
      kind: "begin",
      action: {
        draft: {
          date: "2026-08-01",
          payeeName: "Transfer : Rainy Day Saver",
          categoryId: "",
          memo: "lunch",
          outflow: "2.00",
          inflow: "",
          flagColor: "",
        },
        focus: "memo",
      },
    });
  });

  test("seeds flag colour from the posted row and from the parent on a split line", () => {
    expect(beginRowEdit(posted(txn({ flag_color: "red" })), "memo", unlocked)).toMatchObject({
      action: { draft: { flagColor: "red" } },
    });
    const parent = splitParent([line()], { flag_color: "blue" });
    expect(beginRowEdit(splitLine(parent, "line-1"), "memo", unlocked)).toMatchObject({
      action: { draft: { flagColor: "blue" } },
    });
  });

  test("seeds a split line from the line values", () => {
    const parent = splitParent([line()]);
    expect(beginRowEdit(splitLine(parent, "line-1"), "outflow", unlocked)).toMatchObject({
      kind: "begin",
      action: {
        draft: {
          date: "2026-08-01",
          payeeName: "Shop",
          categoryId: "cat-dining",
          memo: "lunch",
          outflow: "2.00",
          inflow: "",
          flagColor: "",
        },
      },
    });
  });
});

describe("planRowCommit", () => {
  test("returns unchanged when every writable field matches", () => {
    const row = posted(txn());
    expect(planRowCommit(row, shopDraft, payees)).toEqual({ kind: "unchanged" });
    expect(planRowCommit(row, { ...shopDraft, payeeName: "  shop  ", memo: " coffee " }, payees)).toEqual({
      kind: "unchanged",
    });
  });

  test("patches only the fields that changed", () => {
    const row = posted(txn());
    expect(planRowCommit(row, { ...shopDraft, date: "2026-08-15" }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { date: "2026-08-15" },
    });
    expect(planRowCommit(row, { ...shopDraft, memo: "  tea  " }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { memo: "tea" },
    });
    expect(planRowCommit(row, { ...shopDraft, memo: "   " }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { memo: null },
    });
    expect(planRowCommit(row, { ...shopDraft, categoryId: "" }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { category_id: null },
    });
    expect(planRowCommit(row, { ...shopDraft, payeeName: "Coffee" }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { payee_id: "p-coffee", payee_name: "Coffee" },
    });
  });

  test("rejects an empty date", () => {
    expect(planRowCommit(posted(txn()), { ...shopDraft, date: "" }, payees)).toEqual({
      kind: "invalid",
      message: "Choose a date.",
    });
  });

  test("rejects both amount columns", () => {
    expect(planRowCommit(posted(txn()), { ...shopDraft, outflow: "1", inflow: "2" }, payees)).toEqual({
      kind: "invalid",
      message: "Enter an outflow or an inflow, not both.",
    });
  });

  test("rejects an empty amount when the row may edit amount", () => {
    expect(planRowCommit(posted(txn()), { ...shopDraft, outflow: "", inflow: "" }, payees)).toEqual({
      kind: "invalid",
      message: "Enter an outflow or an inflow.",
    });
    expect(planRowCommit(posted(txn()), { ...shopDraft, outflow: "nope" }, payees)).toEqual({
      kind: "invalid",
      message: "Enter an outflow or an inflow.",
    });
  });

  test("keeps amount sign from the filled column, allows zero, and parses an expression", () => {
    expect(planRowCommit(posted(txn({ amount: -3400 })), { ...shopDraft, outflow: "5" }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { amount: -5000 },
    });
    expect(planRowCommit(posted(txn({ amount: 5000 })), {
      ...shopDraft,
      outflow: "",
      inflow: "1.25",
    }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { amount: 1250 },
    });
    expect(planRowCommit(posted(txn({ amount: -3400 })), { ...shopDraft, outflow: "0" }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { amount: 0 },
    });
    expect(planRowCommit(posted(txn()), { ...shopDraft, outflow: "3.40+1.60" }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { amount: -5000 },
    });
  });

  test("plans a transfer payee on a posted row and clears category", () => {
    expect(planRowCommit(posted(txn()), { ...shopDraft, payeeName: "Transfer : Rainy Day Saver" }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { payee_id: "p-xfer", payee_name: "Transfer : Rainy Day Saver", category_id: null },
    });
  });

  test("rejects a self-transfer payee", () => {
    const self = payee("p-self", "Transfer : Everyday", "acct");
    expect(planRowCommit(posted(txn()), { ...shopDraft, payeeName: "Transfer : Everyday" }, [...payees, self])).toEqual({
      kind: "invalid",
      message: "Transfer to the same account is not allowed.",
    });
  });

  test("rejects a transfer payee on a split parent", () => {
    const parent = splitParent([line(), line({ id: "line-2", amount: -1400 })]);
    expect(planRowCommit(posted(parent), {
      date: "2026-08-01",
      payeeName: "Transfer : Rainy Day Saver",
      categoryId: "",
      memo: "coffee",
      outflow: "3.40",
      inflow: "",
      flagColor: "",
    }, payees)).toEqual({
      kind: "invalid",
      message: "A split cannot itself be a transfer.",
    });
  });

  test("plans a regular payee on an existing transfer posted row", () => {
    const row = posted(txn({
      transfer_account_id: "acct-saver",
      payee_id: "p-xfer",
      payee_name: "Transfer : Rainy Day Saver",
      category_id: null,
    }));
    expect(planRowCommit(row, { ...shopDraft, payeeName: "Coffee" }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { payee_id: "p-coffee", payee_name: "Coffee", category_id: "cat-dining", transfer_account_id: null },
    });
  });

  test("rejects retargeting an existing transfer to a different transfer payee", () => {
    const other = payee("p-travel", "Transfer : Travel Card", "acct-travel");
    const row = posted(txn({
      transfer_account_id: "acct-saver",
      payee_id: "p-xfer",
      payee_name: "Transfer : Rainy Day Saver",
      category_id: null,
    }));
    expect(planRowCommit(row, { ...shopDraft, payeeName: "Transfer : Travel Card", categoryId: "" }, [...payees, other])).toEqual({
      kind: "invalid",
      message: "This transfer already has a destination. Choose a regular payee, or cancel.",
    });
  });

  test("does not patch payee or category on a transfer posted row when the draft stays a transfer", () => {
    const row = posted(txn({
      transfer_account_id: "acct-saver",
      payee_id: "p-xfer",
      payee_name: "Transfer : Rainy Day Saver",
      category_id: null,
    }));
    const draft: RegisterRowDraft = {
      date: "2026-08-15",
      payeeName: "Transfer : Rainy Day Saver",
      categoryId: "cat-dining",
      memo: "moved",
      outflow: "3.40",
      inflow: "",
      flagColor: "",
    };
    expect(planRowCommit(row, draft, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { date: "2026-08-15", memo: "moved" },
    });
  });

  test("omits an unchanged flag", () => {
    expect(planRowCommit(posted(txn()), shopDraft, payees)).toEqual({ kind: "unchanged" });
    expect(planRowCommit(posted(txn({ flag_color: "red" })), { ...shopDraft, flagColor: "red" }, payees)).toEqual({
      kind: "unchanged",
    });
  });

  test("plans a red flag", () => {
    expect(planRowCommit(posted(txn()), { ...shopDraft, flagColor: "red" }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { flag_color: "red" },
    });
  });

  test("clears a red flag", () => {
    expect(planRowCommit(posted(txn({ flag_color: "red" })), shopDraft, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { flag_color: null },
    });
  });

  test("never includes flag_color on a split-line commit", () => {
    const parent = splitParent([line()], { flag_color: "red" });
    const plan = planRowCommit(splitLine(parent, "line-1"), {
      date: "2026-08-01",
      payeeName: "Shop",
      categoryId: "cat-dining",
      memo: "updated",
      outflow: "2.00",
      inflow: "",
      flagColor: "",
    }, payees);
    expect(plan).toMatchObject({
      kind: "patch",
      input: {
        subtransactions: [{ id: "line-1", memo: "updated" }],
      },
    });
    expect(plan.kind === "patch" && "flag_color" in plan.input).toBe(false);
  });

  test("does not patch category or amount on a split parent", () => {
    const parent = splitParent([line(), line({ id: "line-2", amount: -1400 })]);
    const row = posted(parent);
    expect(planRowCommit(row, {
      date: "2026-08-01",
      payeeName: "Shop",
      categoryId: "cat-other",
      memo: "coffee",
      outflow: "9.99",
      inflow: "1.00",
      flagColor: "",
    }, payees)).toEqual({ kind: "unchanged" });
    expect(planRowCommit(row, {
      date: "2026-08-15",
      payeeName: "Coffee",
      categoryId: "cat-other",
      memo: "updated",
      outflow: "9.99",
      inflow: "",
      flagColor: "",
    }, payees)).toEqual({
      kind: "patch",
      transactionId: "txn-split",
      input: { date: "2026-08-15", payee_id: "p-coffee", payee_name: "Coffee", memo: "updated" },
    });
  });

  test("adds approved true when requested and the row is not already approved", () => {
    const unapproved = posted(txn({ approved: false }));
    expect(planRowCommit(unapproved, shopDraft, payees, { approve: true })).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { approved: true },
    });
    expect(planRowCommit(unapproved, { ...shopDraft, memo: "tea" }, payees, { approve: true })).toEqual({
      kind: "patch",
      transactionId: "txn-1",
      input: { memo: "tea", approved: true },
    });
    expect(planRowCommit(posted(txn()), shopDraft, payees, { approve: true })).toEqual({ kind: "unchanged" });
  });

  test("rebuilds every split line when one memo changes", () => {
    const first = line();
    const second = line({ id: "line-2", amount: -1400, payee_name: "Coffee", payee_id: "p-coffee", memo: null });
    const parent = splitParent([first, second]);
    expect(planRowCommit(splitLine(parent, "line-1"), {
      date: "2026-08-01",
      payeeName: "Shop",
      categoryId: "cat-dining",
      memo: "updated",
      outflow: "2.00",
      inflow: "",
      flagColor: "",
    }, payees)).toEqual({
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
    expect(planRowCommit(splitLine(parent, "line-2"), {
      date: "2026-08-01",
      payeeName: "",
      categoryId: "",
      memo: "",
      outflow: "3.00",
      inflow: "",
      flagColor: "",
    }, payees)).toEqual({
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

  test("passes transfer fields through on a split-line rebuild and ignores category while the draft is a transfer", () => {
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
    const plan = planRowCommit(splitLine(parent, "line-xfer"), {
      date: "2026-08-01",
      payeeName: "Transfer : Rainy Day Saver",
      categoryId: "cat-dining",
      memo: "moved",
      outflow: "1.40",
      inflow: "",
      flagColor: "",
    }, payees);
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
            payee_name: "Transfer : Rainy Day Saver",
            category_id: null,
          },
        ],
      },
    });
  });

  test("sets transfer_account_id on a split line that becomes a transfer", () => {
    const parent = splitParent([line(), line({ id: "line-2", amount: -1400 })]);
    expect(planRowCommit(splitLine(parent, "line-1"), {
      date: "2026-08-01",
      payeeName: "Transfer : Rainy Day Saver",
      categoryId: "cat-dining",
      memo: "lunch",
      outflow: "2.00",
      inflow: "",
      flagColor: "",
    }, payees)).toMatchObject({
      kind: "patch",
      input: {
        subtransactions: [
          {
            id: "line-1",
            payee_id: "p-xfer",
            payee_name: "Transfer : Rainy Day Saver",
            category_id: null,
            transfer_account_id: "acct-saver",
          },
          { id: "line-2" },
        ],
      },
    });
  });
});

describe("payeeListEntries", () => {
  const everyday = { id: "acct", name: "Everyday Account" };
  const saver = { id: "acct-saver", name: "Rainy Day Saver" };
  const self = payee("p-self", "Transfer : Everyday Account", "acct");
  const listed = [shop, coffee, transfer, self];

  test("labels transfer options from account names and keeps payee.name as the value", () => {
    expect(transferOptionLabel("Rainy Day Saver")).toBe("Transfer to Rainy Day Saver");
    expect(payeeListEntries(listed, [everyday, saver], "acct")).toEqual([
      { id: "p-shop", value: "Shop" },
      { id: "p-coffee", value: "Coffee" },
      { id: "p-xfer", value: "Transfer : Rainy Day Saver", label: "Transfer to Rainy Day Saver" },
    ]);
  });

  test("omits the transfer payee for the posting account", () => {
    expect(payeeListEntries(listed, [everyday, saver], postingAccountId(posted(txn()))).map((entry) => entry.id))
      .not.toContain("p-self");
    expect(payeeListEntries(listed, [everyday, saver], "acct-saver").map((entry) => entry.value)).toEqual([
      "Shop",
      "Coffee",
      "Transfer : Everyday Account",
    ]);
  });

  test("omits a transfer whose account name is unknown", () => {
    expect(payeeListEntries([transfer], [everyday], "acct")).toEqual([]);
  });

  test("omits a transfer to a closed account", () => {
    expect(payeeListEntries(listed, [everyday, { ...saver, closed: true }], "acct")).toEqual([
      { id: "p-shop", value: "Shop" },
      { id: "p-coffee", value: "Coffee" },
    ]);
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

describe("rowGestureHandlers", () => {
  test("prevents default on a second mousedown", () => {
    const handlers = rowGestureHandlers(posted(txn()), "memo", unlocked, () => {});
    const second = gestureEvent(2);
    handlers.onMouseDown(second);
    expect(second.prevented).toBeTrue();
    const first = gestureEvent(1);
    handlers.onMouseDown(first);
    expect(first.prevented).toBeFalse();
  });

  test("begins once on double-click", () => {
    const started: { row: RegisterRowRef; focus: RegisterRowFocus }[] = [];
    const row = posted(txn());
    const handlers = rowGestureHandlers(row, "memo", unlocked, (action) => {
      started.push({ row: action.row, focus: action.focus });
    });
    handlers.onDoubleClick(gestureEvent());
    expect(started).toEqual([{ row, focus: "memo" }]);
  });

  test("begins a transfer posted row from the payee cell", () => {
    const started: RegisterRowFocus[] = [];
    const row = posted(txn({ transfer_account_id: "acct-saver" }));
    const handlers = rowGestureHandlers(row, "payee", unlocked, (action) => {
      started.push(action.focus);
    });
    handlers.onDoubleClick(gestureEvent());
    expect(started).toEqual(["payee"]);
  });

  test("stays silent on a refused double-click", () => {
    const started: string[] = [];
    const handlers = rowGestureHandlers(posted(txn()), "memo", { writeLocked: true, mutatingId: null }, () => {
      started.push("began");
    });
    handlers.onDoubleClick(gestureEvent());
    expect(started).toEqual([]);
  });
});

describe("rowFieldWritable and writableFocus", () => {
  test("keeps payee writable on a saved transfer and locks category", () => {
    const row = posted(txn({
      transfer_account_id: "acct-saver",
      payee_name: "Transfer : Rainy Day Saver",
      category_id: null,
    }));
    expect(rowFieldWritable(row, "payee")).toBeTrue();
    expect(rowFieldWritable(row, "category")).toBeFalse();
    expect(rowFieldWritable(row, "date")).toBeTrue();
    expect(writableFocus(row, "payee")).toBe("payee");
    expect(writableFocus(row, "category")).toBe("date");
  });

  test("keeps payee writable on a regular row so a transfer list pick can commit", () => {
    const row = posted(txn());
    expect(rowFieldWritable(row, "payee", { ...shopDraft, payeeName: "Transfer : Rainy Day Saver" }, payees)).toBeTrue();
    expect(rowFieldWritable(row, "category", { ...shopDraft, payeeName: "Transfer : Rainy Day Saver" }, payees)).toBeFalse();
    expect(writableFocus(row, "payee")).toBe("payee");
  });

  test("keeps payee writable on a saved transfer split line", () => {
    const transferLine = line({
      id: "line-xfer",
      transfer_account_id: "acct-saver",
      payee_name: "Transfer : Rainy Day Saver",
      category_id: null,
    });
    const row = splitLine(splitParent([line(), transferLine]), "line-xfer");
    expect(rowFieldWritable(row, "payee")).toBeTrue();
    expect(rowFieldWritable(row, "date")).toBeFalse();
    expect(writableFocus(row, "category")).toBe("payee");
  });
});

describe("focusForRowError", () => {
  test("points at the field named in the message", () => {
    const row = posted(txn());
    expect(focusForRowError("Choose a date.", row, shopDraft)).toBe("date");
    expect(focusForRowError("Enter an outflow or an inflow.", row, shopDraft)).toBe("outflow");
    expect(focusForRowError("Enter an outflow or an inflow.", row, { ...shopDraft, outflow: "", inflow: "1.00" })).toBe("inflow");
    expect(focusForRowError("This transfer already has a destination. Choose a regular payee, or cancel.", row, shopDraft)).toBe("payee");
  });
});

describe("sessionRowGone", () => {
  const editing = reduceRowEdit(idleRowEdit(), {
    type: "begin",
    row: posted(txn()),
    draft: shopDraft,
    focus: "memo",
  });

  test("is false while idle or committing", () => {
    expect(sessionRowGone(idleRowEdit(), new Set())).toBeFalse();
    const committing = reduceRowEdit(editing, { type: "committing" });
    expect(sessionRowGone(committing, new Set())).toBeFalse();
  });

  test("is true only when the editing row is missing", () => {
    expect(sessionRowGone(editing, new Set(["txn-1"]))).toBeFalse();
    expect(sessionRowGone(editing, new Set(["other"]))).toBeTrue();
  });
});
