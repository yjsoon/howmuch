import { describe, expect, test } from "bun:test";
import type { Payee } from "../api/types";
import {
  addEntryHref,
  closedCompose,
  composePayload,
  emptyComposeDraft,
  reduceCompose,
  resolvePostingAccountId,
  type RegisterComposeState,
} from "./register-compose";

function payee(id: string, name: string, transferAccountId?: string): Payee {
  return { id, name, transfer_account_id: transferAccountId ?? null, deleted: false };
}

function openDraft(accountId = "acct-everyday"): RegisterComposeState {
  return reduceCompose(closedCompose(), { type: "open", accountId });
}

describe("register compose", () => {
  test("opens a blank draft on the posting account", () => {
    const state = openDraft("acct-credit");
    expect(state.status).toBe("open");
    if (state.status !== "open") {
      return;
    }
    expect(state.draft.accountId).toBe("acct-credit");
    expect(state.draft.payeeName).toBe("");
    expect(state.saving).toBe(false);
  });

  test("keeps the draft when Add is pressed again on the same account", () => {
    let state = openDraft("acct-everyday");
    if (state.status === "open") {
      state = reduceCompose(state, { type: "patch", draft: { payeeName: "Toast Box" } });
    }
    state = reduceCompose(state, { type: "open", accountId: "acct-everyday" });
    expect(state.status === "open" && state.draft.payeeName).toBe("Toast Box");
  });

  test("resets when the posting account changes", () => {
    let state = openDraft("acct-everyday");
    if (state.status === "open") {
      state = reduceCompose(state, { type: "patch", draft: { payeeName: "Toast Box" } });
    }
    state = reduceCompose(state, { type: "open", accountId: "acct-saver" });
    expect(state.status === "open" && state.draft.accountId).toBe("acct-saver");
    expect(state.status === "open" && state.draft.payeeName).toBe("");
  });

  test("typing an outflow clears the inflow", () => {
    let state = openDraft();
    state = reduceCompose(state, { type: "set-inflow", value: "12.00" });
    state = reduceCompose(state, { type: "set-outflow", value: "6.80" });
    expect(state.status === "open" && state.draft.outflow).toBe("6.80");
    expect(state.status === "open" && state.draft.inflow).toBe("");
  });

  test("builds a spend against the posting account", () => {
    const draft = {
      ...emptyComposeDraft("acct-everyday", "2026-08-29"),
      payeeName: "Toast Box",
      categoryId: "cat-dining",
      memo: "lunch",
      outflow: "6.80",
    };
    const result = composePayload(draft, [payee("p1", "Toast Box")], "client-1");
    expect(result).toEqual({
      ok: true,
      input: {
        client_id: "client-1",
        account_id: "acct-everyday",
        date: "2026-08-29",
        amount: "-6.8",
        payee_id: null,
        payee_name: "Toast Box",
        category_id: "cat-dining",
        memo: "lunch",
        flag_color: null,
      },
    });
  });

  test("builds an inflow and a transfer from the payee name", () => {
    const income = composePayload(
      { ...emptyComposeDraft("acct-everyday", "2026-08-29"), payeeName: "Payroll", inflow: "10" },
      [payee("p-pay", "Payroll")],
      "c-in",
    );
    expect(income.ok && income.input.amount).toBe("10");
    expect(income.ok && income.input.account_id).toBe("acct-everyday");

    const transfer = composePayload(
      { ...emptyComposeDraft("acct-everyday", "2026-08-29"), payeeName: "Transfer : Rainy Day Saver", outflow: "25" },
      [payee("p-xfer", "Transfer : Rainy Day Saver", "acct-saver")],
      "c-xfer",
    );
    expect(transfer.ok && transfer.input.payee_id).toBe("p-xfer");
    expect(transfer.ok && transfer.input.payee_name).toBeNull();
    expect(transfer.ok && transfer.input.category_id).toBeNull();
  });

  test("rejects a missing account, both amounts, and an empty payee", () => {
    expect(composePayload(emptyComposeDraft(""), [], "c")).toEqual({
      ok: false,
      error: "Choose the posting account.",
    });
    expect(composePayload(
      { ...emptyComposeDraft("acct-everyday"), outflow: "1", inflow: "2", payeeName: "X" },
      [],
      "c",
    )).toEqual({
      ok: false,
      error: "Enter an outflow or an inflow, not both.",
    });
    expect(composePayload(
      { ...emptyComposeDraft("acct-everyday"), outflow: "1" },
      [],
      "c",
    )).toEqual({
      ok: false,
      error: "Enter a payee.",
    });
  });

  test("prefers the requested account over the first open account", () => {
    expect(resolvePostingAccountId(["acct-everyday", "acct-credit"], "acct-credit", "")).toBe("acct-credit");
    expect(resolvePostingAccountId(["acct-everyday", "acct-credit"], "acct-credit", "acct-everyday")).toBe("acct-everyday");
    expect(resolvePostingAccountId(["acct-everyday"], "acct-missing", "")).toBe("acct-everyday");
    expect(resolvePostingAccountId([], "acct-credit", "")).toBe("");
  });

  test("builds the add-entry href with the account query", () => {
    expect(addEntryHref("acct-credit")).toBe("/add?account=acct-credit");
    expect(addEntryHref(null)).toBe("/add");
  });

  test("save-and-add-another keeps the date and account", () => {
    let state = openDraft("acct-credit");
    state = reduceCompose(state, { type: "patch", draft: { date: "2026-08-01", payeeName: "Toast Box" } });
    state = reduceCompose(state, { type: "saving" });
    state = reduceCompose(state, { type: "saved", keepOpen: true, accountId: "acct-credit" });
    expect(state.status === "open" && state.draft.accountId).toBe("acct-credit");
    expect(state.status === "open" && state.draft.date).toBe("2026-08-01");
    expect(state.status === "open" && state.draft.payeeName).toBe("");
    expect(state.saving).toBe(false);
  });
});
