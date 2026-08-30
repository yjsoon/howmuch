import type { Payee, Subtransaction, Transaction, TransactionUpdateInput } from "../api/types";
import { formatMilliunitsInput, parseMilliunits } from "./money";
import { canonicalPayeeName, findTransferPayee, formatComposeAmount } from "./register-compose";

export type PostedCellField = "date" | "payee" | "category" | "memo" | "outflow" | "inflow";
export type SplitCellField = "payee" | "category" | "memo" | "outflow" | "inflow";

export type RegisterCellRef =
  | { readonly kind: "posted"; readonly transaction: Transaction; readonly field: PostedCellField }
  | {
      readonly kind: "split-line";
      readonly parent: Transaction;
      readonly lineId: string;
      readonly field: SplitCellField;
    };

export function postedCell(transaction: Transaction, field: PostedCellField): RegisterCellRef {
  return { kind: "posted", transaction, field };
}

export function splitCell(parent: Transaction, lineId: string, field: SplitCellField): RegisterCellRef {
  return { kind: "split-line", parent, lineId, field };
}

export function cellRowId(cell: RegisterCellRef): string {
  return cell.kind === "posted" ? cell.transaction.id : cell.parent.id;
}

export function sameCell(a: RegisterCellRef, b: RegisterCellRef): boolean {
  if (a.kind === "posted" && b.kind === "posted") {
    return a.transaction.id === b.transaction.id && a.field === b.field;
  }
  if (a.kind === "split-line" && b.kind === "split-line") {
    return a.parent.id === b.parent.id && a.lineId === b.lineId && a.field === b.field;
  }
  return false;
}

export type CellEditSession =
  | { readonly status: "idle" }
  | {
      readonly status: "editing";
      readonly cell: RegisterCellRef;
      readonly draft: string;
      readonly error: string | null;
    }
  | { readonly status: "committing"; readonly cell: RegisterCellRef; readonly draft: string };

export type CellEditAction =
  | { readonly type: "begin"; readonly cell: RegisterCellRef; readonly draft: string }
  | { readonly type: "draft"; readonly value: string }
  | { readonly type: "invalid"; readonly message: string }
  | { readonly type: "committing" }
  | { readonly type: "committed" }
  | { readonly type: "failed"; readonly message: string }
  | { readonly type: "cancel" };

export function idleCellEdit(): CellEditSession {
  return { status: "idle" };
}

export function reduceCellEdit(session: CellEditSession, action: CellEditAction): CellEditSession {
  switch (action.type) {
    case "begin":
      if (session.status !== "idle") {
        return session;
      }
      return { status: "editing", cell: action.cell, draft: action.draft, error: null };
    case "draft":
      if (session.status !== "editing") {
        return session;
      }
      return { ...session, draft: action.value, error: null };
    case "invalid":
      if (session.status !== "editing") {
        return session;
      }
      return { ...session, error: action.message };
    case "committing":
      if (session.status !== "editing") {
        return session;
      }
      return { status: "committing", cell: session.cell, draft: session.draft };
    case "committed":
      if (session.status !== "committing") {
        return session;
      }
      return { status: "idle" };
    case "failed":
      if (session.status !== "committing") {
        return session;
      }
      return { status: "editing", cell: session.cell, draft: session.draft, error: action.message };
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

export type CellEditContext = {
  readonly writeLocked: boolean;
  readonly mutatingId: string | null;
};

export type CellBeginRefusal =
  | "locked"
  | "row-busy"
  | "transfer-payee"
  | "transfer-category"
  | "split-parent-category"
  | "split-parent-amount"
  | "missing-line"
  | "empty-amount-side";

export const CELL_BEGIN_HINT = {
  locked: "Wait until the current change finishes.",
  "row-busy": "Wait until the current change finishes.",
  "transfer-payee": "Transfers keep their linked account.",
  "transfer-category": "Transfers do not have a category.",
  "split-parent-category": "Change a split line instead.",
  "split-parent-amount": "Change a split line instead.",
  "missing-line": "This split line is no longer here.",
  "empty-amount-side": "Edit the amount in the other column.",
} satisfies Record<CellBeginRefusal, string>;

export function cellBeginHint(reason: CellBeginRefusal): string {
  return CELL_BEGIN_HINT[reason];
}

export type CellBeginDecision =
  | { readonly kind: "begin"; readonly action: Extract<CellEditAction, { type: "begin" }> }
  | { readonly kind: "refuse"; readonly reason: CellBeginRefusal };

export function beginCellEdit(cell: RegisterCellRef, context: CellEditContext): CellBeginDecision {
  if (context.writeLocked) {
    return { kind: "refuse", reason: "locked" };
  }
  if (context.mutatingId === cellRowId(cell)) {
    return { kind: "refuse", reason: "row-busy" };
  }

  if (cell.kind === "posted") {
    return beginPosted(cell, cell.transaction);
  }
  const line = cell.parent.subtransactions?.find((sub) => sub.id === cell.lineId);
  if (!line) {
    return { kind: "refuse", reason: "missing-line" };
  }
  return beginSplitLine(cell, line);
}

function beginPosted(cell: Extract<RegisterCellRef, { kind: "posted" }>, txn: Transaction): CellBeginDecision {
  const field = cell.field;
  const isTransfer = Boolean(txn.transfer_account_id);
  const isSplitParent = Boolean(txn.subtransactions?.length);
  if (field === "payee" && isTransfer) {
    return { kind: "refuse", reason: "transfer-payee" };
  }
  if (field === "category" && isTransfer) {
    return { kind: "refuse", reason: "transfer-category" };
  }
  if (field === "category" && isSplitParent) {
    return { kind: "refuse", reason: "split-parent-category" };
  }
  if ((field === "outflow" || field === "inflow") && isSplitParent) {
    return { kind: "refuse", reason: "split-parent-amount" };
  }
  if ((field === "outflow" || field === "inflow") && !amountOccupies(txn.amount, field)) {
    return { kind: "refuse", reason: "empty-amount-side" };
  }
  return { kind: "begin", action: { type: "begin", cell, draft: postedDraft(txn, field) } };
}

function beginSplitLine(
  cell: Extract<RegisterCellRef, { kind: "split-line" }>,
  line: Subtransaction,
): CellBeginDecision {
  const field = cell.field;
  const isTransfer = Boolean(line.transfer_account_id);
  if (field === "payee" && isTransfer) {
    return { kind: "refuse", reason: "transfer-payee" };
  }
  if (field === "category" && isTransfer) {
    return { kind: "refuse", reason: "transfer-category" };
  }
  if ((field === "outflow" || field === "inflow") && !amountOccupies(line.amount, field)) {
    return { kind: "refuse", reason: "empty-amount-side" };
  }
  return { kind: "begin", action: { type: "begin", cell, draft: splitDraft(line, field) } };
}

function postedDraft(txn: Transaction, field: PostedCellField): string {
  switch (field) {
    case "date":
      return txn.date;
    case "payee":
      return txn.payee_name ?? "";
    case "category":
      return txn.category_id ?? "";
    case "memo":
      return txn.memo ?? "";
    case "outflow":
    case "inflow":
      return amountDraft(txn.amount);
    default: {
      const _exhaustive: never = field;
      return _exhaustive;
    }
  }
}

function splitDraft(line: Subtransaction, field: SplitCellField): string {
  switch (field) {
    case "payee":
      return line.payee_name ?? "";
    case "category":
      return line.category_id ?? "";
    case "memo":
      return line.memo ?? "";
    case "outflow":
    case "inflow":
      return amountDraft(line.amount);
    default: {
      const _exhaustive: never = field;
      return _exhaustive;
    }
  }
}

function amountOccupies(amount: number, field: "outflow" | "inflow"): boolean {
  return field === "outflow" ? amount < 0 : amount > 0;
}

function amountDraft(amount: number): string {
  return formatComposeAmount(formatMilliunitsInput(Math.abs(amount)));
}

export type CellCommitPlan =
  | {
      readonly kind: "patch";
      readonly transactionId: string;
      readonly input: TransactionUpdateInput;
    }
  | { readonly kind: "unchanged" }
  | { readonly kind: "invalid"; readonly message: string };

export function planCellCommit(
  cell: RegisterCellRef,
  draft: string,
  payees: readonly Payee[],
): CellCommitPlan {
  if (cell.kind === "posted") {
    return planPostedCommit(cell.transaction, cell.field, draft, payees);
  }
  return planSplitCommit(cell.parent, cell.lineId, cell.field, draft, payees);
}

function planPostedCommit(
  txn: Transaction,
  field: PostedCellField,
  draft: string,
  payees: readonly Payee[],
): CellCommitPlan {
  switch (field) {
    case "date": {
      const date = draft.trim();
      if (!date) {
        return { kind: "invalid", message: "Choose a date." };
      }
      return date === txn.date ? { kind: "unchanged" } : { kind: "patch", transactionId: txn.id, input: { date } };
    }
    case "payee":
      return planPayeeCommit(txn.id, draft, txn.payee_id, txn.payee_name ?? "", payees);
    case "category": {
      const categoryId = draft || null;
      return categoryId === (txn.category_id ?? null)
        ? { kind: "unchanged" }
        : { kind: "patch", transactionId: txn.id, input: { category_id: categoryId } };
    }
    case "memo": {
      const memo = draft.trim() || null;
      return memo === (txn.memo ?? null)
        ? { kind: "unchanged" }
        : { kind: "patch", transactionId: txn.id, input: { memo } };
    }
    case "outflow":
    case "inflow":
      return planAmountCommit(txn.id, draft, field, txn.amount);
    default: {
      const _exhaustive: never = field;
      return _exhaustive;
    }
  }
}

function planSplitCommit(
  parent: Transaction,
  lineId: string,
  field: SplitCellField,
  draft: string,
  payees: readonly Payee[],
): CellCommitPlan {
  const lines = parent.subtransactions;
  if (!lines) {
    return { kind: "invalid", message: "This split line is no longer here." };
  }
  const line = lines.find((sub) => sub.id === lineId);
  if (!line) {
    return { kind: "invalid", message: "This split line is no longer here." };
  }

  switch (field) {
    case "payee": {
      const payee = planPayeeCommit(parent.id, draft, line.payee_id, line.payee_name ?? "", payees);
      if (payee.kind !== "patch") {
        return payee;
      }
      return rebuildSplitPatch(parent, lineId, {
        payee_id: payee.input.payee_id,
        payee_name: payee.input.payee_name,
      });
    }
    case "category": {
      const categoryId = draft || null;
      if (categoryId === (line.category_id ?? null)) {
        return { kind: "unchanged" };
      }
      return rebuildSplitPatch(parent, lineId, { category_id: categoryId });
    }
    case "memo": {
      const memo = draft.trim() || null;
      if (memo === (line.memo ?? null)) {
        return { kind: "unchanged" };
      }
      return rebuildSplitPatch(parent, lineId, { memo });
    }
    case "outflow":
    case "inflow": {
      const parsed = parseAmountEntry(draft);
      if (parsed === null) {
        return { kind: "invalid", message: "Enter an amount." };
      }
      const amount = signedAmount(parsed, field);
      if (amount === line.amount) {
        return { kind: "unchanged" };
      }
      return rebuildSplitPatch(parent, lineId, { amount }, true);
    }
    default: {
      const _exhaustive: never = field;
      return _exhaustive;
    }
  }
}

function planPayeeCommit(
  transactionId: string,
  draft: string,
  originalId: string | null,
  originalName: string,
  payees: readonly Payee[],
): CellCommitPlan {
  const name = canonicalPayeeName(payees, draft);
  const currentName = canonicalPayeeName(payees, originalName);
  if (name === currentName) {
    return { kind: "unchanged" };
  }
  if (findTransferPayee(payees, name)) {
    return { kind: "invalid", message: "Create a transfer from compose, not by renaming a payee." };
  }
  return {
    kind: "patch",
    transactionId,
    input: payeeInput(name, originalId, originalName, payees),
  };
}

function planAmountCommit(
  transactionId: string,
  draft: string,
  field: "outflow" | "inflow",
  current: number,
): CellCommitPlan {
  const parsed = parseAmountEntry(draft);
  if (parsed === null) {
    return { kind: "invalid", message: "Enter an amount." };
  }
  const amount = signedAmount(parsed, field);
  return amount === current
    ? { kind: "unchanged" }
    : { kind: "patch", transactionId, input: { amount } };
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
): CellCommitPlan {
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

export type CellGestureEvent = {
  readonly detail: number;
  preventDefault(): void;
};

export type CellGestureHandlers = {
  onMouseDown(event: CellGestureEvent): void;
  onDoubleClick(event: CellGestureEvent): void;
};

export function cellGestureHandlers(
  cell: RegisterCellRef,
  context: CellEditContext,
  onBegin: (action: Extract<CellEditAction, { type: "begin" }>) => void,
): CellGestureHandlers {
  return {
    onMouseDown(event) {
      if (event.detail > 1) {
        event.preventDefault();
      }
    },
    onDoubleClick() {
      const decision = beginCellEdit(cell, context);
      if (decision.kind === "begin") {
        onBegin(decision.action);
      }
    },
  };
}
