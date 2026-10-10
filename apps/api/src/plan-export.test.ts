import { expect, test } from "bun:test";
import type { PlanSnapshot } from "./plan-snapshot";
import { transactionsCsv } from "./plan-export";

// The transactions CSV is opened in spreadsheets, and its text comes from bank
// imports, shared receipts and typed memos. The E2E export uses the demo
// ledger, which has none of these, so these cases cover what it misses:
// - a comma, quote or line break in a name or memo shifts every later column;
// - a cell starting with = + - @ runs as a formula when the file is opened;
// - a split writes its parent amount and its lines, double-counting spending;
// - a small negative amount loses its sign, or a sub-cent amount is rounded;
// - a deleted category or payee still named by a live row comes out blank;
// - Excel reads UTF-8 without a byte-order mark as the local code page.

/** RFC 4180 reader, written independently of the exporter. */
function readCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (quoted) {
      if (char === "\"" && text[index + 1] === "\"") { field += "\""; index += 1; }
      else if (char === "\"") quoted = false;
      else field += char;
    } else if (char === "\"") quoted = true;
    else if (char === ",") { row.push(field); field = ""; }
    else if (char === "\r" && text[index + 1] === "\n") { row.push(field); rows.push(row); row = []; field = ""; index += 1; }
    else field += char;
  }
  if (field !== "" || row.length > 0) { row.push(field); rows.push(row); }
  return rows;
}

const transaction = {
  memo: null, cleared: "uncleared", approved: true, flag_color: null, flag_name: null, payee_id: null, payee_name: null,
  category_id: null, transfer_account_id: null, transfer_transaction_id: null, matched_transaction_id: null,
  import_id: null, import_payee_name: null, import_payee_name_original: null, subtransactions: [],
};

const snapshot: PlanSnapshot = {
  format: "howmuch-plan-snapshot",
  version: 1,
  category_groups: [{ id: "g", name: "Living", hidden: false, internal: false, deleted: false }],
  categories: [
    { id: "c-food", category_group_id: "g", name: "Food", hidden: false, internal: false, deleted: false },
    { id: "c-old", category_group_id: "g", name: "Old", hidden: false, internal: false, deleted: true },
  ],
  payees: [
    { id: "p-evil", name: "=HYPERLINK(\"http://x\")", transfer_account_id: null, deleted: false },
    { id: "p-gone", name: "Café Nero", transfer_account_id: null, deleted: true },
  ],
  accounts: [{ id: "a", name: "Everyday, joint", icon: null, type: "checking", on_budget: true, closed: false, opening_balance: 0, transfer_payee_id: null }],
  transactions: [
    { ...transaction, id: "t-memo", account_id: "a", date: "2026-01-02", amount: -500, payee_id: "p-evil", category_id: "c-food", memo: "Lunch, \"team\"\nsecond line" },
    { ...transaction, id: "t-old", account_id: "a", date: "2026-01-03", amount: 1005, payee_id: "p-gone", category_id: "c-old", memo: "-refund" },
    {
      ...transaction, id: "t-split", account_id: "a", date: "2026-01-04", amount: -30000, payee_name: "@market",
      subtransactions: [
        { id: "s1", amount: -10000, memo: "veg", payee_id: null, payee_name: null, category_id: "c-food", transfer_account_id: null, transfer_transaction_id: null },
        { id: "s2", amount: -20000, memo: null, payee_id: null, payee_name: null, category_id: "c-old", transfer_account_id: null, transfer_transaction_id: null },
      ],
    },
  ],
  scheduled_transactions: [],
};

test("transactions CSV survives hostile text, splits and small amounts", () => {
  const text = transactionsCsv(snapshot, { decimalDigits: 2 });
  expect(text.startsWith("﻿")).toBe(true);
  const [header, ...rows] = readCsv(text.slice(1));
  const column = (name: string) => header.indexOf(name);
  for (const name of ["Date", "Account", "Payee", "Category group", "Category", "Memo", "Amount", "Transaction ID", "Split of"]) {
    expect(column(name)).toBeGreaterThanOrEqual(0);
  }
  expect(rows.every((row) => row.length === header.length)).toBe(true);
  const byId = new Map(rows.map((row) => [row[column("Transaction ID")], row]));

  const memo = byId.get("t-memo")!;
  expect(memo[column("Account")]).toBe("Everyday, joint");
  expect(memo[column("Memo")]).toBe("Lunch, \"team\"\nsecond line");
  expect(memo[column("Payee")]).toBe("'=HYPERLINK(\"http://x\")");
  expect(memo[column("Amount")]).toBe("-0.50");

  const old = byId.get("t-old")!;
  expect(old[column("Payee")]).toBe("Café Nero");
  expect(old[column("Category")]).toBe("Old");
  expect(old[column("Category group")]).toBe("Living");
  expect(old[column("Memo")]).toBe("'-refund");
  expect(old[column("Amount")]).toBe("1.005");

  expect(byId.has("t-split")).toBe(false);
  const lines = rows.filter((row) => row[column("Split of")] === "t-split");
  expect(lines.map((row) => row[column("Amount")]).sort()).toEqual(["-10.00", "-20.00"]);
  expect(lines.every((row) => row[column("Payee")] === "'@market" && row[column("Date")] === "2026-01-04")).toBe(true);
});
