import type { Payee, Subtransaction, Transaction, TransactionUpdateInput } from "../api/types";
import { formatMilliunitsInput, parseMilliunits } from "./money";
import { canonicalPayeeName, findTransferPayee, formatComposeAmount } from "./register-compose";

export type RegisterRowDraft = {
  readonly date: string;
  readonly payeeName: string;
  readonly categoryId: string;
  readonly memo: string;
  readonly outflow: string;
  readonly inflow: string;
  readonly flagColor: string;
};

export type RowEditAccount = {
  readonly id: string;
  readonly name: string;
  readonly closed?: boolean;
};

export type PayeeListEntry = {
  readonly id: string;
  readonly value: string;
  readonly label?: string;
};

export type RegisterRowRef =
  | { readonly kind: "posted"; readonly transaction: Transaction }
  | { readonly kind: "split-line"; readonly parent: Transaction; readonly lineId: string };

export type RegisterRowFocus =
  | "date"
  | "payee"
  | "category"
  | "memo"
  | "outflow"
  | "inflow";

export type RegisterRowEditSession =
  | { readonly status: "idle" }
  | {
      readonly status: "editing";
      readonly row: RegisterRowRef;
      readonly draft: RegisterRowDraft;
      readonly focus: RegisterRowFocus;
      readonly error: string | null;
    }
  | { readonly status: "committing"; readonly row: RegisterRowRef; readonly draft: RegisterRowDraft };

export type RegisterRowEditAction =
  | { readonly type: "begin"; readonly row: RegisterRowRef; readonly draft: RegisterRowDraft; readonly focus: RegisterRowFocus }
  | { readonly type: "patch"; readonly draft: Partial<Pick<RegisterRowDraft, "date" | "payeeName" | "categoryId" | "memo" | "flagColor">> }
  | { readonly type: "set-outflow"; readonly value: string }
  | { readonly type: "set-inflow"; readonly value: string }
  | { readonly type: "invalid"; readonly message: string; readonly focus?: RegisterRowFocus }
  | { readonly type: "committing" }
  | { readonly type: "committed" }
  | { readonly type: "failed"; readonly message: string; readonly focus?: RegisterRowFocus }
  | { readonly type: "cancel" };

export function idleRowEdit(): RegisterRowEditSession {
  return { status: "idle" };
}

export function rowId(row: RegisterRowRef): string {
  return row.kind === "posted" ? row.transaction.id : row.parent.id;
}

/** Stable, query-safe identity for a posted row or one exact split line. */
export function registerRowDomId(row: RegisterRowRef): string {
  return row.kind === "posted"
    ? `register-row-${encodeURIComponent(row.transaction.id)}`
    : `register-row-${encodeURIComponent(row.parent.id)}-${encodeURIComponent(row.lineId)}`;
}

export function sameRow(a: RegisterRowRef, b: RegisterRowRef): boolean {
  if (a.kind === "posted" && b.kind === "posted") {
    return a.transaction.id === b.transaction.id;
  }
  if (a.kind === "split-line" && b.kind === "split-line") {
    return a.parent.id === b.parent.id && a.lineId === b.lineId;
  }
  return false;
}

export function rowApproved(row: RegisterRowRef): boolean {
  return row.kind === "posted" ? row.transaction.approved : row.parent.approved;
}

export function reduceRowEdit(
  session: RegisterRowEditSession,
  action: RegisterRowEditAction,
): RegisterRowEditSession {
  switch (action.type) {
    case "begin":
      if (session.status !== "idle") {
        return session;
      }
      return {
        status: "editing",
        row: action.row,
        draft: action.draft,
        focus: action.focus,
        error: null,
      };
    case "patch":
      if (session.status !== "editing") {
        return session;
      }
      return { ...session, draft: { ...session.draft, ...action.draft }, error: null };
    case "set-outflow":
      if (session.status !== "editing") {
        return session;
      }
      return {
        ...session,
        error: null,
        draft: {
          ...session.draft,
          outflow: action.value,
          inflow: action.value.trim() ? "" : session.draft.inflow,
        },
      };
    case "set-inflow":
      if (session.status !== "editing") {
        return session;
      }
      return {
        ...session,
        error: null,
        draft: {
          ...session.draft,
          inflow: action.value,
          outflow: action.value.trim() ? "" : session.draft.outflow,
        },
      };
    case "invalid":
      if (session.status !== "editing") {
        return session;
      }
      return { ...session, error: action.message, focus: action.focus ?? session.focus };
    case "committing":
      if (session.status !== "editing") {
        return session;
      }
      return { status: "committing", row: session.row, draft: session.draft };
    case "committed":
      if (session.status !== "committing") {
        return session;
      }
      return { status: "idle" };
    case "failed":
      if (session.status !== "committing") {
        return session;
      }
      return {
        status: "editing",
        row: session.row,
        draft: session.draft,
        focus: action.focus ?? writableFocus(session.row, defaultFocus(session.row), session.draft),
        error: action.message,
      };
    case "cancel":
      if (session.status !== "editing") {
        return session;
      }
      return { status: "idle" };
    default: {
      const _exhaustive: never = action;
      return _exhaustive;
    }
  }
}

export type RowEditContext = {
  readonly writeLocked: boolean;
  readonly mutatingId: string | null;
};

export type RowBeginRefusal = "locked" | "row-busy" | "missing-line" | "linked-mirror";

export type RowBeginDecision =
  | { readonly kind: "begin"; readonly action: Extract<RegisterRowEditAction, { type: "begin" }> }
  | { readonly kind: "refuse"; readonly reason: RowBeginRefusal };

const FOCUS_ORDER: readonly RegisterRowFocus[] = [
  "date",
  "payee",
  "category",
  "memo",
  "outflow",
  "inflow",
];

export function rowFieldWritable(
  row: RegisterRowRef,
  field: RegisterRowFocus,
  draft?: RegisterRowDraft,
  payees: readonly Payee[] = [],
): boolean {
  if (row.kind === "posted") {
    const splitParent = Boolean(row.transaction.subtransactions?.length);
    const savedTransfer = Boolean(row.transaction.transfer_account_id);
    if (field === "category" && (splitParent || categoryLocked(savedTransfer, row.transaction.payee_name ?? "", draft, payees))) {
      return false;
    }
    if ((field === "outflow" || field === "inflow") && splitParent) {
      return false;
    }
    return true;
  }
  if (field === "date") {
    return false;
  }
  const line = findLine(row.parent, row.lineId);
  if (!line) {
    return false;
  }
  if (field === "category" && categoryLocked(Boolean(line.transfer_account_id), line.payee_name ?? "", draft, payees)) {
    return false;
  }
  return true;
}

export function writableFocus(
  row: RegisterRowRef,
  requested: RegisterRowFocus,
  draft?: RegisterRowDraft,
  payees: readonly Payee[] = [],
): RegisterRowFocus {
  if (rowFieldWritable(row, requested, draft, payees)) {
    return requested;
  }
  for (const field of FOCUS_ORDER) {
    if (rowFieldWritable(row, field, draft, payees)) {
      return field;
    }
  }
  return requested;
}

export function focusForRowError(
  message: string,
  row: RegisterRowRef,
  draft: RegisterRowDraft,
  payees: readonly Payee[] = [],
): RegisterRowFocus {
  const text = message.toLowerCase();
  if (text.includes("date")) {
    return writableFocus(row, "date", draft, payees);
  }
  if (text.includes("payee") || text.includes("transfer") || text.includes("destination")) {
    return writableFocus(row, "payee", draft, payees);
  }
  if (text.includes("outflow") || text.includes("inflow") || text.includes("amount")) {
    return writableFocus(row, draft.outflow.trim() ? "outflow" : "inflow", draft, payees);
  }
  return writableFocus(row, defaultFocus(row), draft, payees);
}

export function sessionRowGone(
  session: RegisterRowEditSession,
  presentIds: ReadonlySet<string>,
): boolean {
  if (session.status !== "editing") {
    return false;
  }
  return !presentIds.has(rowId(session.row));
}

function draftIsTransfer(draft: RegisterRowDraft | undefined, payees: readonly Payee[]): boolean {
  return Boolean(draft && findTransferPayee(payees, draft.payeeName));
}

function categoryLocked(
  savedTransfer: boolean,
  savedPayeeName: string,
  draft: RegisterRowDraft | undefined,
  payees: readonly Payee[],
): boolean {
  if (draftIsTransfer(draft, payees)) {
    return true;
  }
  if (!savedTransfer) {
    return false;
  }
  if (!draft) {
    return true;
  }
  return canonicalPayeeName(payees, draft.payeeName) === canonicalPayeeName(payees, savedPayeeName);
}

export function postingAccountId(row: RegisterRowRef): string {
  return row.kind === "posted" ? row.transaction.account_id : row.parent.account_id;
}

export function transferOptionLabel(accountName: string): string {
  return `Transfer to ${accountName}`;
}

export function payeeListEntries(
  payees: readonly Payee[],
  accounts: readonly RowEditAccount[],
  accountId: string,
): readonly PayeeListEntry[] {
  const byId = new Map(accounts.map((account) => [account.id, account]));
  const entries: PayeeListEntry[] = [];
  for (const payee of payees) {
    if (payee.deleted) {
      continue;
    }
    if (!payee.transfer_account_id) {
      entries.push({ id: payee.id, value: payee.name });
      continue;
    }
    if (payee.transfer_account_id === accountId) {
      continue;
    }
    const account = byId.get(payee.transfer_account_id);
    if (!account || account.closed) {
      continue;
    }
    entries.push({
      id: payee.id,
      value: payee.name,
      label: transferOptionLabel(account.name),
    });
  }
  return entries;
}

export function beginRowEdit(
  row: RegisterRowRef,
  focus: RegisterRowFocus,
  context: RowEditContext,
): RowBeginDecision {
  if (context.writeLocked) {
    return { kind: "refuse", reason: "locked" };
  }
  if (context.mutatingId === rowId(row)) {
    return { kind: "refuse", reason: "row-busy" };
  }
  if (row.kind === "posted") {
    if (row.transaction.parent_transaction_id) {
      return { kind: "refuse", reason: "linked-mirror" };
    }
    const draft = postedDraft(row.transaction);
    return {
      kind: "begin",
      action: { type: "begin", row, draft, focus: writableFocus(row, focus, draft) },
    };
  }
  const line = findLine(row.parent, row.lineId);
  if (!line) {
    return { kind: "refuse", reason: "missing-line" };
  }
  const draft = splitDraft(row.parent, line);
  return {
    kind: "begin",
    action: { type: "begin", row, draft, focus: writableFocus(row, focus, draft) },
  };
}

function postedDraft(txn: Transaction): RegisterRowDraft {
  return {
    date: txn.date,
    payeeName: txn.payee_name ?? "",
    categoryId: txn.category_id ?? "",
    memo: txn.memo ?? "",
    flagColor: txn.flag_color ?? "",
    ...amountDraft(txn.amount),
  };
}

function splitDraft(parent: Transaction, line: Subtransaction): RegisterRowDraft {
  return {
    date: parent.date,
    payeeName: line.payee_name ?? "",
    categoryId: line.category_id ?? "",
    memo: line.memo ?? "",
    flagColor: parent.flag_color ?? "",
    ...amountDraft(line.amount),
  };
}

function amountDraft(amount: number): Pick<RegisterRowDraft, "outflow" | "inflow"> {
  const formatted = formatComposeAmount(formatMilliunitsInput(Math.abs(amount)));
  if (amount < 0) {
    return { outflow: formatted, inflow: "" };
  }
  if (amount > 0) {
    return { outflow: "", inflow: formatted };
  }
  return { outflow: "", inflow: "" };
}

function defaultFocus(row: RegisterRowRef): RegisterRowFocus {
  return row.kind === "posted" ? "date" : "payee";
}

function findLine(parent: Transaction, lineId: string): Subtransaction | undefined {
  return parent.subtransactions?.find((sub) => sub.id === lineId);
}

export type RowCommitPlan =
  | {
      readonly kind: "patch";
      readonly transactionId: string;
      readonly input: TransactionUpdateInput;
    }
  | { readonly kind: "unchanged" }
  | { readonly kind: "invalid"; readonly message: string };

export function planRowCommit(
  row: RegisterRowRef,
  draft: RegisterRowDraft,
  payees: readonly Payee[],
  options?: { approve?: boolean },
): RowCommitPlan {
  if (row.kind === "posted") {
    return planPostedCommit(row, draft, payees, options);
  }
  return planSplitCommit(row, draft, payees, options);
}

function planPostedCommit(
  row: Extract<RegisterRowRef, { kind: "posted" }>,
  draft: RegisterRowDraft,
  payees: readonly Payee[],
  options?: { approve?: boolean },
): RowCommitPlan {
  const txn = row.transaction;
  const input: TransactionUpdateInput = {};

  if (rowFieldWritable(row, "date", draft, payees)) {
    const date = draft.date.trim();
    if (!date) {
      return { kind: "invalid", message: "Choose a date." };
    }
    if (date !== txn.date) {
      input.date = date;
    }
  }

  if (rowFieldWritable(row, "payee", draft, payees)) {
    const payee = planPayeeChange(draft.payeeName, txn.payee_id, txn.payee_name ?? "", payees, {
      accountId: txn.account_id,
      splitParent: Boolean(txn.subtransactions?.length),
      currentTransferAccountId: txn.transfer_account_id ?? null,
      splitLine: false,
    });
    if (payee.kind === "invalid") {
      return payee;
    }
    if (payee.kind === "changed") {
      Object.assign(input, payee.input);
    }
  }

  if (rowFieldWritable(row, "category", draft, payees)) {
    const categoryId = draft.categoryId || null;
    if (categoryId !== (txn.category_id ?? null)) {
      input.category_id = categoryId;
    }
  }

  if (rowFieldWritable(row, "memo", draft, payees)) {
    const memo = draft.memo.trim() || null;
    if (memo !== (txn.memo ?? null)) {
      input.memo = memo;
    }
  }

  const flagColor = draft.flagColor || null;
  if (flagColor !== (txn.flag_color ?? null)) {
    input.flag_color = flagColor;
  }

  if (rowFieldWritable(row, "outflow", draft, payees) || rowFieldWritable(row, "inflow", draft, payees)) {
    const amount = planAmountChange(draft, txn.amount);
    if (amount.kind === "invalid") {
      return amount;
    }
    if (amount.kind === "changed") {
      input.amount = amount.amount;
    }
  }

  if (options?.approve && !txn.approved) {
    input.approved = true;
  }

  return Object.keys(input).length === 0
    ? { kind: "unchanged" }
    : { kind: "patch", transactionId: txn.id, input };
}

function planSplitCommit(
  row: Extract<RegisterRowRef, { kind: "split-line" }>,
  draft: RegisterRowDraft,
  payees: readonly Payee[],
  options?: { approve?: boolean },
): RowCommitPlan {
  const parent = row.parent;
  const lines = parent.subtransactions;
  if (!lines) {
    return { kind: "invalid", message: "This split line is no longer here." };
  }
  const line = lines.find((sub) => sub.id === row.lineId);
  if (!line) {
    return { kind: "invalid", message: "This split line is no longer here." };
  }

  const patch: Partial<SplitLineInput> = {};

  if (rowFieldWritable(row, "payee", draft, payees)) {
    const payee = planPayeeChange(draft.payeeName, line.payee_id, line.payee_name ?? "", payees, {
      accountId: parent.account_id,
      splitParent: false,
      currentTransferAccountId: line.transfer_account_id ?? null,
      splitLine: true,
    });
    if (payee.kind === "invalid") {
      return payee;
    }
    if (payee.kind === "changed") {
      Object.assign(patch, payee.input);
    }
  }

  if (rowFieldWritable(row, "category", draft, payees)) {
    const categoryId = draft.categoryId || null;
    if (categoryId !== (line.category_id ?? null)) {
      patch.category_id = categoryId;
    }
  }

  if (rowFieldWritable(row, "memo", draft, payees)) {
    const memo = draft.memo.trim() || null;
    if (memo !== (line.memo ?? null)) {
      patch.memo = memo;
    }
  }

  let moveParentAmount = false;
  if (rowFieldWritable(row, "outflow", draft, payees) || rowFieldWritable(row, "inflow", draft, payees)) {
    const amount = planAmountChange(draft, line.amount);
    if (amount.kind === "invalid") {
      return amount;
    }
    if (amount.kind === "changed") {
      patch.amount = amount.amount;
      moveParentAmount = true;
    }
  }

  const rebuilt = Object.keys(patch).length === 0
    ? null
    : rebuildSplitPatch(parent, row.lineId, patch, moveParentAmount);
  if (rebuilt && rebuilt.kind !== "patch") {
    return rebuilt;
  }

  const input: TransactionUpdateInput = rebuilt?.kind === "patch" ? { ...rebuilt.input } : {};
  if (options?.approve && !parent.approved) {
    input.approved = true;
  }

  return Object.keys(input).length === 0
    ? { kind: "unchanged" }
    : { kind: "patch", transactionId: parent.id, input };
}

type PayeeChangeInput = Pick<TransactionUpdateInput, "payee_id" | "payee_name" | "category_id"> & {
  transfer_account_id?: string | null;
  transfer_transaction_id?: string | null;
};

type PayeeChangeContext = {
  readonly accountId: string;
  readonly splitParent: boolean;
  readonly currentTransferAccountId: string | null;
  readonly splitLine: boolean;
};

function planPayeeChange(
  draft: string,
  originalId: string | null,
  originalName: string,
  payees: readonly Payee[],
  context: PayeeChangeContext,
):
  | { readonly kind: "same" }
  | { readonly kind: "changed"; readonly input: PayeeChangeInput }
  | { readonly kind: "invalid"; readonly message: string } {
  const name = canonicalPayeeName(payees, draft);
  const currentName = canonicalPayeeName(payees, originalName);
  if (name === currentName) {
    return { kind: "same" };
  }
  const transfer = findTransferPayee(payees, name);
  if (transfer) {
    if (transfer.transfer_account_id === context.accountId) {
      return { kind: "invalid", message: "Transfer to the same account is not allowed." };
    }
    if (context.splitParent) {
      return { kind: "invalid", message: "A split cannot itself be a transfer." };
    }
    if (context.currentTransferAccountId && context.currentTransferAccountId !== transfer.transfer_account_id) {
      return { kind: "invalid", message: "This transfer already has a destination. Choose a regular payee, or cancel." };
    }
    const input: PayeeChangeInput = {
      payee_id: transfer.id,
      payee_name: transfer.name,
      category_id: null,
    };
    if (context.splitLine) {
      input.transfer_account_id = transfer.transfer_account_id ?? null;
    }
    return { kind: "changed", input };
  }
  const input: PayeeChangeInput = payeeInput(name, originalId, originalName, payees);
  if (context.currentTransferAccountId) {
    input.transfer_account_id = null;
    if (context.splitLine) {
      input.transfer_transaction_id = null;
    }
  }
  return { kind: "changed", input };
}

function planAmountChange(
  draft: RegisterRowDraft,
  current: number,
):
  | { readonly kind: "same" }
  | { readonly kind: "changed"; readonly amount: number }
  | { readonly kind: "invalid"; readonly message: string } {
  const outflow = draft.outflow.trim();
  const inflow = draft.inflow.trim();
  if (outflow && inflow) {
    return { kind: "invalid", message: "Enter an outflow or an inflow, not both." };
  }
  if (!outflow && !inflow) {
    if (current === 0) {
      return { kind: "same" };
    }
    return { kind: "invalid", message: "Enter an outflow or an inflow." };
  }
  const field = outflow ? "outflow" : "inflow";
  const parsed = parseAmountEntry(outflow || inflow);
  if (parsed === null) {
    return { kind: "invalid", message: "Enter an outflow or an inflow." };
  }
  const amount = signedAmount(parsed, field);
  return amount === current ? { kind: "same" } : { kind: "changed", amount };
}

function signedAmount(magnitude: number, field: "outflow" | "inflow"): number {
  if (magnitude === 0) {
    return 0;
  }
  return field === "outflow" ? -magnitude : magnitude;
}

type SplitLineInput = NonNullable<TransactionUpdateInput["subtransactions"]>[number];

function rebuildSplitPatch(
  parent: Transaction,
  lineId: string,
  patch: Partial<SplitLineInput>,
  moveParentAmount = false,
): RowCommitPlan {
  const lines = parent.subtransactions;
  if (!lines) {
    return { kind: "invalid", message: "This split line is no longer here." };
  }
  const subtransactions = lines.map((line) => {
    const input = splitLineInput(line);
    return line.id === lineId ? { ...input, ...patch } : input;
  });
  const input: TransactionUpdateInput = { subtransactions };
  if (moveParentAmount) {
    input.amount = subtransactions.reduce((sum, line) => sum + line.amount, 0);
  }
  return { kind: "patch", transactionId: parent.id, input };
}

function splitLineInput(line: Subtransaction): SplitLineInput {
  return {
    id: line.id,
    amount: line.amount,
    payee_id: line.payee_id,
    payee_name: line.payee_name ?? null,
    category_id: line.category_id,
    memo: line.memo,
    transfer_account_id: line.transfer_account_id ?? null,
    transfer_transaction_id: line.transfer_transaction_id ?? null,
  };
}

export function payeeInput(
  name: string,
  originalId: string | null,
  originalName: string,
  payees: readonly Payee[],
): Pick<TransactionUpdateInput, "payee_id" | "payee_name"> {
  const trimmed = name.trim();
  if (!trimmed) {
    return { payee_id: null, payee_name: null };
  }
  if (trimmed === originalName && originalId) {
    return { payee_id: originalId, payee_name: trimmed };
  }
  const matched = payees.find((payee) => !payee.deleted && !payee.transfer_account_id && payee.name === trimmed);
  return { payee_id: matched?.id ?? null, payee_name: trimmed };
}

export function parseAmountEntry(text: string): number | null {
  const plain = parseMilliunits(text);
  if (plain !== null) {
    return plain < 0 ? null : plain;
  }
  const tokens = tokenizeAmount(text);
  if (!tokens) {
    return null;
  }
  const parsed = parseAmountExpr(tokens, 0);
  if (!parsed || parsed.next !== tokens.length) {
    return null;
  }
  return parsed.value < 0 ? null : parsed.value;
}

type AmountToken =
  | { readonly kind: "number"; readonly milliunits: number }
  | { readonly kind: "op"; readonly op: "+" | "-" | "*" | "/" }
  | { readonly kind: "lparen" }
  | { readonly kind: "rparen" };

const AMOUNT_NUMBER = /^(?:(\d+)(?:\.(\d{0,3}))?|\.(\d{1,3}))/;

function tokenizeAmount(text: string): AmountToken[] | null {
  const tokens: AmountToken[] = [];
  let index = 0;
  while (index < text.length) {
    const char = text[index];
    if (char === " " || char === "\t") {
      index += 1;
      continue;
    }
    if (char === "+" || char === "-" || char === "*" || char === "/") {
      tokens.push({ kind: "op", op: char });
      index += 1;
      continue;
    }
    if (char === "(") {
      tokens.push({ kind: "lparen" });
      index += 1;
      continue;
    }
    if (char === ")") {
      tokens.push({ kind: "rparen" });
      index += 1;
      continue;
    }
    const match = text.slice(index).match(AMOUNT_NUMBER);
    if (!match) {
      return null;
    }
    const milliunits = parseMilliunits(match[0]);
    if (milliunits === null) {
      return null;
    }
    tokens.push({ kind: "number", milliunits });
    index += match[0].length;
  }
  return tokens.length > 0 ? tokens : null;
}

function parseAmountExpr(
  tokens: readonly AmountToken[],
  start: number,
): { value: number; next: number } | null {
  const term = parseAmountTerm(tokens, start);
  if (!term) {
    return null;
  }
  let value = term.value;
  let index = term.next;
  while (index < tokens.length) {
    const token = tokens[index];
    if (token.kind !== "op" || (token.op !== "+" && token.op !== "-")) {
      break;
    }
    const next = parseAmountTerm(tokens, index + 1);
    if (!next) {
      return null;
    }
    value = token.op === "+" ? value + next.value : value - next.value;
    if (!Number.isSafeInteger(value)) {
      return null;
    }
    index = next.next;
  }
  return { value, next: index };
}

function parseAmountTerm(
  tokens: readonly AmountToken[],
  start: number,
): { value: number; next: number } | null {
  const factor = parseAmountUnary(tokens, start);
  if (!factor) {
    return null;
  }
  let value = factor.value;
  let index = factor.next;
  while (index < tokens.length) {
    const token = tokens[index];
    if (token.kind !== "op" || (token.op !== "*" && token.op !== "/")) {
      break;
    }
    const next = parseAmountUnary(tokens, index + 1);
    if (!next) {
      return null;
    }
    const scaled = token.op === "*" ? scaleMilliunits(value, next.value, "mul") : scaleMilliunits(value, next.value, "div");
    if (scaled === null) {
      return null;
    }
    value = scaled;
    index = next.next;
  }
  return { value, next: index };
}

function parseAmountUnary(
  tokens: readonly AmountToken[],
  start: number,
): { value: number; next: number } | null {
  const token = tokens[start];
  if (!token) {
    return null;
  }
  if (token.kind === "op" && (token.op === "+" || token.op === "-")) {
    const inner = parseAmountUnary(tokens, start + 1);
    if (!inner) {
      return null;
    }
    const value = token.op === "-" ? -inner.value : inner.value;
    return Number.isSafeInteger(value) ? { value, next: inner.next } : null;
  }
  return parseAmountFactor(tokens, start);
}

function parseAmountFactor(
  tokens: readonly AmountToken[],
  start: number,
): { value: number; next: number } | null {
  const token = tokens[start];
  if (!token) {
    return null;
  }
  if (token.kind === "number") {
    return { value: token.milliunits, next: start + 1 };
  }
  if (token.kind !== "lparen") {
    return null;
  }
  const inner = parseAmountExpr(tokens, start + 1);
  if (!inner || tokens[inner.next]?.kind !== "rparen") {
    return null;
  }
  return { value: inner.value, next: inner.next + 1 };
}

function scaleMilliunits(left: number, right: number, mode: "mul" | "div"): number | null {
  if (mode === "div") {
    if (right === 0) {
      return null;
    }
    if (left !== 0 && Math.abs(left) > Number.MAX_SAFE_INTEGER / 1000) {
      return null;
    }
    return roundHalfAwayFromZero(left * 1000, right);
  }
  if (left !== 0 && Math.abs(right) > Number.MAX_SAFE_INTEGER / Math.abs(left)) {
    return null;
  }
  return roundHalfAwayFromZero(left * right, 1000);
}

function roundHalfAwayFromZero(numerator: number, denominator: number): number | null {
  if (denominator === 0) {
    return null;
  }
  const sign = numerator < 0 !== denominator < 0 ? -1 : 1;
  const absNum = Math.abs(numerator);
  const absDen = Math.abs(denominator);
  const quotient = Math.trunc(absNum / absDen);
  const remainder = absNum % absDen;
  const rounded = remainder * 2 >= absDen ? quotient + 1 : quotient;
  const value = sign * rounded;
  return Number.isSafeInteger(value) ? value : null;
}

export type RowGestureEvent = {
  readonly detail: number;
  preventDefault(): void;
};

export type RowGestureHandlers = {
  onMouseDown(event: RowGestureEvent): void;
  onDoubleClick(event: RowGestureEvent): void;
};

export function rowGestureHandlers(
  row: RegisterRowRef,
  focus: RegisterRowFocus,
  context: RowEditContext,
  onBegin: (action: Extract<RegisterRowEditAction, { type: "begin" }>) => void,
): RowGestureHandlers {
  return {
    onMouseDown(event) {
      if (event.detail > 1) {
        event.preventDefault();
      }
    },
    onDoubleClick() {
      const decision = beginRowEdit(row, focus, context);
      if (decision.kind === "begin") {
        onBegin(decision.action);
      }
    },
  };
}
