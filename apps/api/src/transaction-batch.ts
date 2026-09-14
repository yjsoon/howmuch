import { ValidationError } from "./repository";
import {
  MAX_TRANSACTION_WRITE_BATCH,
  type ClearedState,
  type NonEmpty,
  type SubtransactionInput,
  type TransactionBatchUpdate,
  type TransactionClearedItem,
  type TransactionDeleteItem,
  type TransactionFieldPatch,
  type TransactionInput,
  type TransactionLookup,
} from "./types";

export function collectionPostIntent(body: unknown): "one" | "many" {
  if (!isPlainObject(body)) throw new ValidationError("transaction is required");
  const hasOne = Object.hasOwn(body, "transaction");
  const hasMany = Object.hasOwn(body, "transactions");
  if (hasOne && hasMany) throw new ValidationError("Provide transaction or transactions, not both");
  if (hasOne) {
    if (!isPlainObject(body.transaction)) throw new ValidationError("transaction is required");
    return "one";
  }
  if (hasMany) {
    if (!Array.isArray(body.transactions)) throw new ValidationError("transactions must be an array");
    return "many";
  }
  throw new ValidationError("transaction is required");
}

export function parseTransactionCreates(value: unknown): NonEmpty<TransactionInput> {
  return assertWriteBatch(value).map((item, index) => {
    if (!isPlainObject(item)) throw new ValidationError(`transactions[${index}] must be an object`);
    return parseTransactionInput(item, `transactions[${index}]`);
  }) as NonEmpty<TransactionInput>;
}

export function parseTransactionUpdates(body: unknown): NonEmpty<TransactionBatchUpdate> {
  if (!isPlainObject(body) || !Array.isArray(body.transactions)) {
    throw new ValidationError("transactions is required");
  }
  return assertWriteBatch(body.transactions).map((item, index) => {
    if (!isPlainObject(item)) throw new ValidationError(`transactions[${index}] must be an object`);
    return { lookup: parseLookup(item, index), patch: parseFieldPatch(item) };
  }) as NonEmpty<TransactionBatchUpdate>;
}

/**
 * A bulk cleared command: every item repeats the single-item body plus its id,
 * so each row keeps its own `expected_cleared` compare-and-set.
 */
export function parseTransactionClearedBulk(body: unknown): NonEmpty<TransactionClearedItem> {
  const items = assertBulkBody(body);
  const parsed = items.map((item, index) => {
    if (!isPlainObject(item)) throw new ValidationError(`transactions[${index}] must be an object`);
    const expected = item.expected_cleared;
    const cleared = item.cleared;
    if (!isToggleClearedState(expected) || !isToggleClearedState(cleared)) {
      throw new ValidationError(`transactions[${index}] expected_cleared and cleared must be uncleared or cleared`);
    }
    return {
      id: requiredString(item.id, `transactions[${index}] id`),
      expected_cleared: expected,
      cleared,
    };
  }) as NonEmpty<TransactionClearedItem>;
  assertUniqueIds(parsed);
  return parsed;
}

/** A bulk delete command; `expected_approved` is optional and never inferred. */
export function parseTransactionDeleteBulk(body: unknown): NonEmpty<TransactionDeleteItem> {
  const items = assertBulkBody(body);
  const parsed = items.map((item, index) => {
    if (!isPlainObject(item)) throw new ValidationError(`transactions[${index}] must be an object`);
    const expectedApproved = Object.hasOwn(item, "expected_approved")
      ? booleanValue(item.expected_approved, `transactions[${index}] expected_approved`)
      : undefined;
    return {
      id: requiredString(item.id, `transactions[${index}] id`),
      ...(expectedApproved === undefined ? {} : { expected_approved: expectedApproved }),
    };
  }) as NonEmpty<TransactionDeleteItem>;
  assertUniqueIds(parsed);
  return parsed;
}

function assertBulkBody(value: unknown): unknown[] {
  if (!isPlainObject(value) || !Array.isArray(value.transactions)) {
    throw new ValidationError("transactions is required");
  }
  return assertWriteBatch(value.transactions);
}

/**
 * A repeated id would be applied twice in one command: the second write would
 * report a conflict (cleared) or an already-removed row (delete) that reads
 * like real progress. Reject the whole command before it writes anything.
 */
function assertUniqueIds(items: readonly { id: string }[]): void {
  const seen = new Set<string>();
  for (const item of items) {
    if (seen.has(item.id)) throw new ValidationError(`Duplicate transaction id ${item.id} in batch`);
    seen.add(item.id);
  }
}

function isToggleClearedState(value: unknown): value is "uncleared" | "cleared" {
  return value === "uncleared" || value === "cleared";
}

function parseLookup(item: Record<string, unknown>, index: number): TransactionLookup {
  if (Object.hasOwn(item, "id")) {
    return { kind: "id", id: requiredString(item.id, `transactions[${index}] id`) };
  }
  if (Object.hasOwn(item, "import_id")) {
    return { kind: "import_id", importId: requiredString(item.import_id, `transactions[${index}] import_id`) };
  }
  throw new ValidationError(`transactions[${index}] requires id or import_id`);
}

function parseFieldPatch(item: Record<string, unknown>): TransactionFieldPatch {
  const patch = { ...item };
  delete patch.id;
  delete patch.import_id;
  delete patch.deleted;
  return parseKnownFields(patch);
}

function parseTransactionInput(item: Record<string, unknown>, label: string): TransactionInput {
  const patch = parseKnownFields(item);
  if (!patch.account_id) throw new ValidationError(`${label} account_id is required`);
  if (!patch.date) throw new ValidationError(`${label} date must be an ISO date (YYYY-MM-DD)`);
  if (patch.amount === undefined) throw new ValidationError(`${label} amount must be integer milliunits`);
  const importId = Object.hasOwn(item, "import_id") ? nullableString(item.import_id, "import_id") : undefined;
  const id = optionalString(item.id);
  return {
    ...patch,
    ...(id ? { id } : {}),
    account_id: patch.account_id,
    date: patch.date,
    amount: patch.amount,
    ...(importId === undefined ? {} : { import_id: importId }),
  };
}

function parseKnownFields(value: Record<string, unknown>): Partial<TransactionInput> {
  const patch: Partial<TransactionInput> = {};
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
  if (Object.hasOwn(value, "import_payee_name")) patch.import_payee_name = nullableString(value.import_payee_name, "import_payee_name");
  if (Object.hasOwn(value, "import_payee_name_original")) {
    patch.import_payee_name_original = nullableString(value.import_payee_name_original, "import_payee_name_original");
  }
  if (Object.hasOwn(value, "source_kind")) patch.source_kind = nullableString(value.source_kind, "source_kind");
  if (Object.hasOwn(value, "source_ref")) patch.source_ref = nullableString(value.source_ref, "source_ref");
  if (Object.hasOwn(value, "external_ynab_id")) patch.external_ynab_id = nullableString(value.external_ynab_id, "external_ynab_id");
  if (Object.hasOwn(value, "subtransactions")) {
    if (!Array.isArray(value.subtransactions)) throw new ValidationError("subtransactions must be an array");
    patch.subtransactions = value.subtransactions.map(parseSubtransaction);
  }
  return patch;
}

function parseSubtransaction(value: unknown): SubtransactionInput {
  if (!isPlainObject(value)) throw new ValidationError("subtransaction must be an object");
  if (!Object.hasOwn(value, "amount")) throw new ValidationError("subtransaction amount is required");
  const subtransaction: SubtransactionInput = { amount: integer(value.amount, "subtransaction amount") };
  if (Object.hasOwn(value, "id")) subtransaction.id = requiredString(value.id, "subtransaction id");
  if (Object.hasOwn(value, "payee_id")) subtransaction.payee_id = nullableString(value.payee_id, "subtransaction payee_id");
  if (Object.hasOwn(value, "payee_name")) subtransaction.payee_name = nullableString(value.payee_name, "subtransaction payee_name");
  if (Object.hasOwn(value, "category_id")) subtransaction.category_id = nullableString(value.category_id, "subtransaction category_id");
  if (Object.hasOwn(value, "memo")) subtransaction.memo = nullableString(value.memo, "subtransaction memo");
  if (Object.hasOwn(value, "transfer_account_id")) {
    subtransaction.transfer_account_id = nullableString(value.transfer_account_id, "subtransaction transfer_account_id");
  }
  if (Object.hasOwn(value, "transfer_transaction_id")) {
    subtransaction.transfer_transaction_id = nullableString(value.transfer_transaction_id, "subtransaction transfer_transaction_id");
  }
  if (Object.hasOwn(value, "external_ynab_id")) {
    subtransaction.external_ynab_id = nullableString(value.external_ynab_id, "subtransaction external_ynab_id");
  }
  return subtransaction;
}

function assertWriteBatch(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new ValidationError("transactions must be an array");
  if (value.length === 0) throw new ValidationError("transactions must not be empty");
  if (value.length > MAX_TRANSACTION_WRITE_BATCH) {
    throw new ValidationError(`transactions cannot exceed ${MAX_TRANSACTION_WRITE_BATCH} items`);
  }
  return value;
}

function optionalString(value: unknown): string | null {
  if (value == null) return null;
  if (typeof value !== "string" || value.length === 0) return null;
  return value;
}

function requiredString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0) throw new ValidationError(`${label} must be a non-empty string`);
  return value;
}

function nullableString(value: unknown, label: string): string | null {
  if (value === null) return null;
  return requiredString(value, label);
}

function nullableBoolean(value: unknown, label: string): boolean | null {
  if (value === null || typeof value === "boolean") return value;
  throw new ValidationError(`${label} must be a boolean or null`);
}

function booleanValue(value: unknown, label: string): boolean {
  if (typeof value !== "boolean") throw new ValidationError(`${label} must be true or false`);
  return value;
}

function integer(value: unknown, label: string): number {
  if (!Number.isSafeInteger(value)) throw new ValidationError(`${label} must be integer milliunits`);
  return value as number;
}

function clearedState(value: unknown): ClearedState | null {
  if (value === null || value === "cleared" || value === "uncleared" || value === "reconciled") return value;
  throw new ValidationError("cleared must be one of cleared, uncleared, reconciled");
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
