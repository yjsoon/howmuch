import { ValidationError } from "./repository";
import {
  MAX_TRANSACTION_WRITE_BATCH,
  type ClearedState,
  type SubtransactionInput,
  type TransactionBatchUpdate,
  type TransactionInput,
  type TransactionLookup,
} from "./types";

export type TransactionCollectionPost =
  | { readonly mode: "single"; readonly input: unknown }
  | { readonly mode: "many"; readonly inputs: unknown[] };

export function parseTransactionCollectionPost(body: unknown): TransactionCollectionPost {
  const wrapper = parseObject(body, "request body");
  const hasSingle = Object.hasOwn(wrapper, "transaction");
  const hasMany = Object.hasOwn(wrapper, "transactions");
  if (hasSingle === hasMany) {
    throw new ValidationError("Provide exactly one of transaction or transactions");
  }
  if (hasSingle) {
    return { mode: "single", input: wrapper.transaction };
  }
  if (!Array.isArray(wrapper.transactions)) {
    throw new ValidationError("transactions must be an array");
  }
  assertWriteBatchSize(wrapper.transactions.length);
  return { mode: "many", inputs: wrapper.transactions };
}

export function parseTransactionCollectionPatch(body: unknown): TransactionBatchUpdate[] {
  const wrapper = parseObject(body, "request body");
  if (!Array.isArray(wrapper.transactions)) {
    throw new ValidationError("transactions must be an array");
  }
  assertWriteBatchSize(wrapper.transactions.length);
  return wrapper.transactions.map(parseTransactionBatchUpdate);
}

export function parseTransactionLookup(value: unknown): TransactionLookup {
  const item = parseObject(value, "transaction");
  const hasId = Object.hasOwn(item, "id");
  const hasImportId = Object.hasOwn(item, "import_id");
  if (hasId === hasImportId) {
    throw new ValidationError("Each transaction must contain exactly one of id or import_id");
  }
  if (hasId) {
    return { kind: "id", id: requiredString(item.id, "id") };
  }
  const accountId = item.account_id === undefined
    ? undefined
    : requiredString(item.account_id, "account_id");
  return {
    kind: "import_id",
    importId: requiredString(item.import_id, "import_id"),
    ...(accountId === undefined ? {} : { accountId }),
  };
}

export function parseTransactionInput(value: unknown): TransactionInput {
  const patch = parseTransactionFields(parseObject(value, "transaction"));
  if (!patch.account_id) {
    throw new ValidationError("account_id is required");
  }
  if (!patch.date) {
    throw new ValidationError("date must be an ISO date (YYYY-MM-DD)");
  }
  if (patch.amount === undefined) {
    throw new ValidationError("amount must be integer milliunits");
  }
  return {
    ...patch,
    account_id: patch.account_id,
    date: patch.date,
    amount: patch.amount,
  };
}

export function assertWriteBatchSize(count: number): void {
  if (count < 1 || count > MAX_TRANSACTION_WRITE_BATCH) {
    throw new ValidationError(`transactions must contain between 1 and ${MAX_TRANSACTION_WRITE_BATCH} items`);
  }
}

function parseTransactionBatchUpdate(value: unknown): TransactionBatchUpdate {
  const item = parseObject(value, "transaction");
  const lookup = parseTransactionLookup(item);
  const patchInput = { ...item };
  delete patchInput.id;
  delete patchInput.import_id;
  return { lookup, patch: parseTransactionFields(patchInput) };
}

function parseTransactionFields(value: Record<string, unknown>): Partial<TransactionInput> {
  const patch: Partial<TransactionInput> = {};
  if (Object.hasOwn(value, "id")) patch.id = requiredString(value.id, "id");
  if (Object.hasOwn(value, "account_id")) patch.account_id = requiredString(value.account_id, "account_id");
  if (Object.hasOwn(value, "date")) patch.date = requiredString(value.date, "date");
  if (Object.hasOwn(value, "amount")) patch.amount = integer(value.amount, "amount");
  if (Object.hasOwn(value, "deleted")) patch.deleted = nullableBoolean(value.deleted, "deleted");
  if (Object.hasOwn(value, "payee_id")) patch.payee_id = nullableString(value.payee_id, "payee_id");
  if (Object.hasOwn(value, "payee_name")) patch.payee_name = nullableString(value.payee_name, "payee_name");
  if (Object.hasOwn(value, "category_id")) patch.category_id = nullableString(value.category_id, "category_id");
  if (Object.hasOwn(value, "memo")) patch.memo = nullableString(value.memo, "memo");
  if (Object.hasOwn(value, "cleared")) patch.cleared = clearedState(value.cleared);
  if (Object.hasOwn(value, "approved")) patch.approved = nullableBoolean(value.approved, "approved");
  if (Object.hasOwn(value, "flag_color")) patch.flag_color = nullableString(value.flag_color, "flag_color");
  if (Object.hasOwn(value, "flag_name")) patch.flag_name = nullableString(value.flag_name, "flag_name");
  if (Object.hasOwn(value, "transfer_account_id")) patch.transfer_account_id = nullableString(value.transfer_account_id, "transfer_account_id");
  if (Object.hasOwn(value, "transfer_transaction_id")) patch.transfer_transaction_id = nullableString(value.transfer_transaction_id, "transfer_transaction_id");
  if (Object.hasOwn(value, "matched_transaction_id")) patch.matched_transaction_id = nullableString(value.matched_transaction_id, "matched_transaction_id");
  if (Object.hasOwn(value, "import_id")) patch.import_id = nullableString(value.import_id, "import_id");
  if (Object.hasOwn(value, "import_payee_name")) patch.import_payee_name = nullableString(value.import_payee_name, "import_payee_name");
  if (Object.hasOwn(value, "import_payee_name_original")) patch.import_payee_name_original = nullableString(value.import_payee_name_original, "import_payee_name_original");
  if (Object.hasOwn(value, "source_kind")) patch.source_kind = nullableString(value.source_kind, "source_kind");
  if (Object.hasOwn(value, "source_ref")) patch.source_ref = nullableString(value.source_ref, "source_ref");
  if (Object.hasOwn(value, "external_ynab_id")) patch.external_ynab_id = nullableString(value.external_ynab_id, "external_ynab_id");
  if (Object.hasOwn(value, "subtransactions")) {
    if (!Array.isArray(value.subtransactions)) {
      throw new ValidationError("subtransactions must be an array");
    }
    patch.subtransactions = value.subtransactions.map(parseSubtransactionInput);
  }
  return patch;
}

function parseSubtransactionInput(value: unknown): SubtransactionInput {
  const item = parseObject(value, "subtransaction");
  if (!Object.hasOwn(item, "amount")) {
    throw new ValidationError("subtransaction amount is required");
  }
  const subtransaction: SubtransactionInput = {
    amount: integer(item.amount, "subtransaction amount"),
  };
  if (Object.hasOwn(item, "id")) subtransaction.id = requiredString(item.id, "subtransaction id");
  if (Object.hasOwn(item, "payee_id")) subtransaction.payee_id = nullableString(item.payee_id, "subtransaction payee_id");
  if (Object.hasOwn(item, "payee_name")) subtransaction.payee_name = nullableString(item.payee_name, "subtransaction payee_name");
  if (Object.hasOwn(item, "category_id")) subtransaction.category_id = nullableString(item.category_id, "subtransaction category_id");
  if (Object.hasOwn(item, "memo")) subtransaction.memo = nullableString(item.memo, "subtransaction memo");
  if (Object.hasOwn(item, "transfer_account_id")) subtransaction.transfer_account_id = nullableString(item.transfer_account_id, "subtransaction transfer_account_id");
  if (Object.hasOwn(item, "transfer_transaction_id")) subtransaction.transfer_transaction_id = nullableString(item.transfer_transaction_id, "subtransaction transfer_transaction_id");
  if (Object.hasOwn(item, "external_ynab_id")) subtransaction.external_ynab_id = nullableString(item.external_ynab_id, "subtransaction external_ynab_id");
  return subtransaction;
}

function parseObject(value: unknown, label: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new ValidationError(`${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

function requiredString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new ValidationError(`${label} must be a non-empty string`);
  }
  return value;
}

function nullableString(value: unknown, label: string): string | null {
  if (value === null) return null;
  if (typeof value !== "string") {
    throw new ValidationError(`${label} must be a string or null`);
  }
  return value;
}

function nullableBoolean(value: unknown, label: string): boolean | null {
  if (value === null || typeof value === "boolean") return value;
  throw new ValidationError(`${label} must be a boolean or null`);
}

function integer(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value)) {
    throw new ValidationError(`${label} must be integer milliunits`);
  }
  return value as number;
}

function clearedState(value: unknown): ClearedState | null {
  if (value === null || value === "cleared" || value === "uncleared" || value === "reconciled") {
    return value;
  }
  throw new ValidationError("cleared must be one of cleared, uncleared, reconciled");
}
