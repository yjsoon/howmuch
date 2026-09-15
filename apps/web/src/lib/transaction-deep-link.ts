import type { Transaction } from "../api/types";

export type TransactionDeepLink = {
  planId: string;
  transactionId: string;
  subtransactionId: string | null;
};

export type TransactionDeepLinkParseResult =
  | { kind: "none" }
  | { kind: "invalid"; message: string }
  | { kind: "valid"; link: TransactionDeepLink };

export type DeepLinkedTransactionResolution = {
  key: string;
  transaction: Transaction | null;
  loading: boolean;
  error: string | null;
};

export type DeepLinkedTransactionMutation = Transaction | "approved" | "deleted";

const DEEP_LINK_PARAMS = ["plan", "transaction", "subtransaction"] as const;
const MAX_ID_LENGTH = 256;

export function parseTransactionDeepLink(params: URLSearchParams): TransactionDeepLinkParseResult {
  const present = DEEP_LINK_PARAMS.some((name) => params.has(name));
  if (!present) return { kind: "none" };

  for (const name of DEEP_LINK_PARAMS) {
    if (params.getAll(name).length > 1) {
      return { kind: "invalid", message: `This transaction link has more than one ${name} value.` };
    }
  }

  const planId = validId(params.get("plan"));
  const transactionId = validId(params.get("transaction"));
  const rawSubtransactionId = params.get("subtransaction");
  const subtransactionId = rawSubtransactionId === null ? null : validId(rawSubtransactionId);
  if (!planId || !transactionId) {
    return { kind: "invalid", message: "This transaction link must include valid plan and transaction IDs." };
  }
  if (rawSubtransactionId !== null && !subtransactionId) {
    return { kind: "invalid", message: "This transaction link has an invalid subtransaction ID." };
  }
  return { kind: "valid", link: { planId, transactionId, subtransactionId } };
}

export function buildTransactionDeepLink(
  link: TransactionDeepLink,
  previous: URLSearchParams = new URLSearchParams(),
): string {
  const parsed = parseTransactionDeepLink(new URLSearchParams([
    ["plan", link.planId],
    ["transaction", link.transactionId],
    ...(link.subtransactionId === null ? [] : [["subtransaction", link.subtransactionId]]),
  ]));
  if (parsed.kind !== "valid") throw new Error(parsed.kind === "invalid" ? parsed.message : "Invalid transaction link");

  const params = new URLSearchParams();
  params.set("plan", link.planId);
  params.set("transaction", link.transactionId);
  if (link.subtransactionId) params.set("subtransaction", link.subtransactionId);
  for (const [name, value] of previous) {
    if (!DEEP_LINK_PARAMS.includes(name as (typeof DEEP_LINK_PARAMS)[number])) params.append(name, value);
  }
  return `/transactions?${params.toString()}`;
}

export function mergeDeepLinkedTransaction(
  transactions: readonly Transaction[],
  resolved: Transaction | null,
): Transaction[] {
  if (!resolved) return [...transactions];
  const index = transactions.findIndex((transaction) => transaction.id === resolved.id);
  if (index < 0) return [resolved, ...transactions];
  return transactions.map((transaction, current) => current === index ? resolved : transaction);
}

/** Apply register-only visibility state after the normal patch pipeline. */
export function deepLinkedTransactionForRegister(
  transaction: Transaction | undefined,
  locallyApproved: boolean,
): Transaction | null {
  if (!transaction || transaction.deleted) return null;
  return !transaction.approved && locallyApproved
    ? { ...transaction, approved: true }
    : transaction;
}

/** Keep a directly fetched row aligned with mutations after filter overlays reset. */
export function applyDeepLinkedTransactionMutation(
  resolution: DeepLinkedTransactionResolution,
  transactionId: string,
  mutation: DeepLinkedTransactionMutation,
): DeepLinkedTransactionResolution {
  if (resolution.transaction?.id !== transactionId) return resolution;
  if (mutation === "deleted") return { ...resolution, transaction: null };
  if (mutation === "approved") {
    return resolution.transaction.approved
      ? resolution
      : { ...resolution, transaction: { ...resolution.transaction, approved: true } };
  }
  return { ...resolution, transaction: mutation };
}

export function deepLinkTargetsRow(link: TransactionDeepLink, transaction: Transaction): boolean {
  if (transaction.id !== link.transactionId) return false;
  return link.subtransactionId === null
    || Boolean(transaction.subtransactions?.some((line) => line.id === link.subtransactionId));
}

function validId(value: string | null): string | null {
  if (value === null || value.length === 0 || value.length > MAX_ID_LENGTH || value.trim() !== value) return null;
  return value;
}
