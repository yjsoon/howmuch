import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { Transaction } from "../api/types";
import { idleRowEdit } from "../lib/register-row-edit";
import { RegisterEditableRow, type RowEditSurface } from "./RegisterEditableRow";

const transaction: Transaction = {
  id: "txn 1",
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
  payee_name: "Invoice",
  category_id: null,
  category_name: null,
  transfer_account_id: null,
  transfer_transaction_id: null,
  deleted: false,
  subtransactions: [{
    id: "split/1",
    amount: -12000,
    payee_id: null,
    category_id: "category-1",
    category_name: "Business",
    memo: "Line",
    deleted: false,
  }],
};

const surface: RowEditSurface = {
  session: idleRowEdit(),
  context: { writeLocked: false, mutatingId: null },
  payees: [],
  accounts: [],
  groups: { primary: [], quiet: [] },
  begin: () => {},
  dispatch: () => {},
  commit: () => {},
  cancel: () => {},
};

describe("RegisterEditableRow deep-link target", () => {
  test("marks a parent row with its deterministic focusable identity and highlight hook", () => {
    const html = renderToStaticMarkup(
      createElement("table", null, createElement("tbody", null, createElement(RegisterEditableRow, {
        row: { kind: "posted", transaction },
        surface,
        leading: null,
        account: "Checking",
        status: null,
        targeted: true,
      }))),
    );
    expect(html).toContain('id="register-row-txn%201"');
    expect(html).toContain('class="register-row-targeted"');
    expect(html).toContain('tabindex="0"');
    expect(html).toContain('aria-current="true"');
    expect(html).toContain('data-deep-link-target="true"');
  });

  test("targets one split line independently of its parent", () => {
    const html = renderToStaticMarkup(
      createElement("table", null, createElement("tbody", null, createElement(RegisterEditableRow, {
        row: { kind: "split-line", parent: transaction, lineId: "split/1" },
        surface,
        leading: null,
        account: null,
        status: null,
        targeted: true,
      }))),
    );
    expect(html).toContain('id="register-row-txn%201-split%2F1"');
    expect(html).toContain('class="split-line-row register-row-targeted"');
  });
});
