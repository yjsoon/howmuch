import type { Payee, QuickEntryInput } from "../api/types";
import { todayIso } from "./dates";
import { formatMilliunitsInput, parseMilliunits } from "./money";

export type RegisterComposeDraft = {
  clientId: string;
  date: string;
  accountId: string;
  payeeName: string;
  categoryId: string;
  memo: string;
  outflow: string;
  inflow: string;
};

export type RegisterComposeState =
  | { status: "closed" }
  | { status: "open"; draft: RegisterComposeDraft; saving: boolean; error: string | null };

export type RegisterComposeAction =
  | { type: "open"; accountId: string }
  | { type: "close" }
  | { type: "patch"; draft: Partial<Pick<RegisterComposeDraft, "date" | "accountId" | "payeeName" | "categoryId" | "memo">> }
  | { type: "set-outflow"; value: string }
  | { type: "set-inflow"; value: string }
  | { type: "saving" }
  | { type: "saved"; keepOpen: boolean }
  | { type: "failed"; error: string };

export type ComposePayload =
  | { ok: true; input: QuickEntryInput }
  | { ok: false; error: string };

export function emptyComposeDraft(accountId: string, date = todayIso()): RegisterComposeDraft {
  return {
    clientId: crypto.randomUUID(),
    date,
    accountId,
    payeeName: "",
    categoryId: "",
    memo: "",
    outflow: "",
    inflow: "",
  };
}

export function closedCompose(): RegisterComposeState {
  return { status: "closed" };
}

export function reduceCompose(state: RegisterComposeState, action: RegisterComposeAction): RegisterComposeState {
  switch (action.type) {
    case "open":
      if (state.status === "open") {
        return state.saving ? state : { ...state, error: null };
      }
      return { status: "open", draft: emptyComposeDraft(action.accountId), saving: false, error: null };
    case "close":
      return { status: "closed" };
    case "patch":
      if (state.status !== "open" || state.saving) {
        return state;
      }
      return { ...state, error: null, draft: { ...state.draft, ...action.draft } };
    case "set-outflow":
      if (state.status !== "open" || state.saving) {
        return state;
      }
      return {
        ...state,
        error: null,
        draft: { ...state.draft, outflow: action.value, inflow: action.value.trim() ? "" : state.draft.inflow },
      };
    case "set-inflow":
      if (state.status !== "open" || state.saving) {
        return state;
      }
      return {
        ...state,
        error: null,
        draft: { ...state.draft, inflow: action.value, outflow: action.value.trim() ? "" : state.draft.outflow },
      };
    case "saving":
      if (state.status !== "open") {
        return state;
      }
      return { ...state, saving: true, error: null };
    case "saved":
      if (state.status !== "open") {
        return state;
      }
      if (!action.keepOpen) {
        return { status: "closed" };
      }
      return {
        status: "open",
        draft: emptyComposeDraft(state.draft.accountId, state.draft.date),
        saving: false,
        error: null,
      };
    case "failed":
      if (state.status !== "open") {
        return state;
      }
      return { ...state, saving: false, error: action.error };
    default: {
      const _exhaustive: never = action;
      return _exhaustive;
    }
  }
}

function payeeKey(name: string): string {
  return name.trim().replace(/\s+/g, " ").toLowerCase();
}

export function findTransferPayee(payees: readonly Payee[], name: string): Payee | undefined {
  const key = payeeKey(name);
  if (!key) {
    return undefined;
  }
  return payees.find((payee) => !payee.deleted && payee.transfer_account_id && payeeKey(payee.name) === key);
}

export function canonicalPayeeName(payees: readonly Payee[], name: string): string {
  const key = payeeKey(name);
  if (!key) {
    return "";
  }
  const matched = payees.find((payee) => !payee.deleted && payeeKey(payee.name) === key);
  return matched?.name ?? name.trim().replace(/\s+/g, " ");
}

export function formatComposeAmount(value: string): string {
  const parsed = parseMilliunits(value);
  if (parsed === null || parsed <= 0) {
    return value.trim();
  }
  const formatted = formatMilliunitsInput(parsed);
  if (!formatted.includes(".")) {
    return `${formatted}.00`;
  }
  const [whole, fraction = ""] = formatted.split(".");
  return `${whole}.${fraction.padEnd(2, "0")}`;
}

export function composePayload(
  draft: RegisterComposeDraft,
  payees: readonly Payee[],
): ComposePayload {
  if (!draft.accountId) {
    return { ok: false, error: "Choose the posting account." };
  }
  if (!draft.date) {
    return { ok: false, error: "Choose a date." };
  }

  const outflow = draft.outflow.trim();
  const inflow = draft.inflow.trim();
  if (outflow && inflow) {
    return { ok: false, error: "Enter an outflow or an inflow, not both." };
  }
  const amountText = outflow || inflow;
  const magnitude = parseMilliunits(amountText);
  if (!amountText || magnitude === null || magnitude <= 0) {
    return { ok: false, error: "Enter an outflow or an inflow." };
  }

  const payeeName = canonicalPayeeName(payees, draft.payeeName);
  const transfer = findTransferPayee(payees, payeeName);
  if (!payeeName) {
    return { ok: false, error: "Enter a payee." };
  }

  const signedAmount = (outflow ? -1 : 1) * magnitude;
  return {
    ok: true,
    input: {
      client_id: draft.clientId,
      account_id: draft.accountId,
      date: draft.date,
      amount: formatMilliunitsInput(signedAmount),
      payee_id: transfer?.id ?? null,
      payee_name: transfer ? null : payeeName,
      category_id: transfer ? null : draft.categoryId || null,
      memo: draft.memo.trim() || null,
      flag_color: null,
    },
  };
}

export function resolvePostingAccountId(
  openAccountIds: readonly string[],
  requestedId: string,
  overrideId: string,
): string {
  if (overrideId && openAccountIds.includes(overrideId)) {
    return overrideId;
  }
  if (requestedId && openAccountIds.includes(requestedId)) {
    return requestedId;
  }
  return openAccountIds[0] ?? "";
}

export function addEntryHref(accountId?: string | null): string {
  return accountId ? `/add?account=${encodeURIComponent(accountId)}` : "/add";
}

export function dateInFilterRange(date: string, from?: string, to?: string): boolean {
  if (from && date < from) {
    return false;
  }
  if (to && date > to) {
    return false;
  }
  return true;
}
