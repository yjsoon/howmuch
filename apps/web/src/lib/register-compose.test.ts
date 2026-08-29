import { describe, expect, test } from "bun:test";
import type { Payee } from "../api/types";
import {
  addEntryHref,
  canonicalPayeeName,
  closedCompose,
  composePayload,
  dateInFilterRange,
  emptyComposeDraft,
  findTransferPayee,
  formatComposeAmount,
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

  test("keeps the draft when Add is pressed again", () => {
    let state = openDraft("acct-everyday");
    if (state.status === "open") {
      state = reduceCompose(state, { type: "patch", draft: { payeeName: "Toast Box", accountId: "acct-saver" } });
    }
    state = reduceCompose(state, { type: "open", accountId: "acct-everyday" });
    expect(state.status === "open" && state.draft.payeeName).toBe("Toast Box");
    expect(state.status === "open" && state.draft.accountId).toBe("acct-saver");
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
      clientId: "client-1",
      payeeName: "Toast Box",
      categoryId: "cat-dining",
      memo: "lunch",
      outflow: "6.80",
    };
    const result = composePayload(draft, [payee("p1", "Toast Box")]);
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
    );
    expect(income.ok && income.input.amount).toBe("10");
    expect(income.ok && income.input.account_id).toBe("acct-everyday");

    const transfer = composePayload(
      { ...emptyComposeDraft("acct-everyday", "2026-08-29"), payeeName: "Transfer : Rainy Day Saver", outflow: "25" },
      [payee("p-xfer", "Transfer : Rainy Day Saver", "acct-saver")],
    );
    expect(transfer.ok && transfer.input.payee_id).toBe("p-xfer");
    expect(transfer.ok && transfer.input.payee_name).toBeNull();
    expect(transfer.ok && transfer.input.category_id).toBeNull();
  });

  test("rejects a missing account, both amounts, and an empty payee", () => {
    expect(composePayload(emptyComposeDraft(""), [])).toEqual({
      ok: false,
      error: "Choose the posting account.",
    });
    expect(composePayload(
      { ...emptyComposeDraft("acct-everyday"), outflow: "1", inflow: "2", payeeName: "X" },
      [],
    )).toEqual({
      ok: false,
      error: "Enter an outflow or an inflow, not both.",
    });
    expect(composePayload(
      { ...emptyComposeDraft("acct-everyday"), outflow: "1" },
      [],
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

  test("save-and-add-another keeps the date and account and remints the client id", () => {
    let state = openDraft("acct-credit");
    const firstId = state.status === "open" ? state.draft.clientId : "";
    state = reduceCompose(state, { type: "patch", draft: { date: "2026-08-01", payeeName: "Toast Box" } });
    state = reduceCompose(state, { type: "saving" });
    state = reduceCompose(state, { type: "saved", keepOpen: true });
    expect(state.status === "open" && state.draft.accountId).toBe("acct-credit");
    expect(state.status === "open" && state.draft.date).toBe("2026-08-01");
    expect(state.status === "open" && state.draft.payeeName).toBe("");
    expect(state.status === "open" && state.draft.clientId).not.toBe(firstId);
    expect(state.saving).toBe(false);
  });

  test("dateInFilterRange treats an open end as unbounded", () => {
    expect(dateInFilterRange("2026-08-29", "2026-08-01", "2026-08-31")).toBe(true);
    expect(dateInFilterRange("2026-07-01", "2026-08-01", "2026-08-31")).toBe(false);
    expect(dateInFilterRange("2026-03-01", undefined, undefined)).toBe(true);
  });

  test("a failed save keeps the same client id for retry", () => {
    let state = openDraft("acct-credit");
    const firstId = state.status === "open" ? state.draft.clientId : "";
    state = reduceCompose(state, { type: "saving" });
    state = reduceCompose(state, { type: "failed", error: "network" });
    expect(state.status === "open" && state.draft.clientId).toBe(firstId);
    expect(state.status === "open" && state.error).toBe("network");
  });

  test("matches transfer payees without caring about case or extra spaces", () => {
    const transferPayee = payee("p-xfer", "Transfer : Rainy Day Saver", "acct-saver");
    expect(findTransferPayee([transferPayee], "transfer : rainy day saver")?.id).toBe("p-xfer");
    expect(canonicalPayeeName([transferPayee], "  TRANSFER :  Rainy Day Saver ")).toBe("Transfer : Rainy Day Saver");
    const result = composePayload(
      { ...emptyComposeDraft("acct-everyday", "2026-08-29"), payeeName: "transfer : rainy day saver", outflow: "25" },
      [transferPayee],
    );
    expect(result.ok && result.input.payee_id).toBe("p-xfer");
  });

  test("formats a compose amount to two decimals", () => {
    expect(formatComposeAmount("4.2")).toBe("4.20");
    expect(formatComposeAmount("10")).toBe("10.00");
    expect(formatComposeAmount("nope")).toBe("nope");
  });

  test("a late save does not reopen a cancelled row", () => {
    let state = openDraft("acct-credit");
    state = reduceCompose(state, { type: "saving" });
    state = reduceCompose(state, { type: "close" });
    state = reduceCompose(state, { type: "saved", keepOpen: true });
    expect(state.status).toBe("closed");
  });
});
