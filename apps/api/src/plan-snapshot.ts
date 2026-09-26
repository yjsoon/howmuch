/**
 * Pure core for whole-plan snapshots (`howmuch-plan-snapshot`, version 1).
 *
 * Export projects stored rows into the snapshot; import validates a snapshot
 * into database-ready rows and plans the SQL that inserts them. The
 * repositories only read, guard, and run the statements, so SQLite and D1
 * import exactly the same rows.
 *
 * Import is one atomic write. D1 bounds each bound value, so every table's
 * rows travel as JSON chunks of at most SNAPSHOT_CHUNK_BYTES, each expanded
 * in SQL by `json_each`. The number of statements grows with the snapshot's
 * size in bytes, never with a per-row statement, and they all run in the one
 * batch: a failure anywhere leaves the plan exactly as it was.
 */

import { createHash } from "node:crypto";
import { resolveAccountPresentation } from "./account-icon";
import { onBudgetForKind, parseAccountKind } from "./account-kind";
import { ENTITY_ID_PATTERN, type PlannedSql } from "./category-management";
import { scheduledTransactionMutation, ScheduledTransactionValidationError } from "./scheduled-transactions";

export const SNAPSHOT_FORMAT = "howmuch-plan-snapshot";
export const SNAPSHOT_VERSION = 1;
/** Largest accepted request body. Documented in docs/api-contract.md. */
export const MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024;
/** Upper bound for one JSON value bound into a statement. */
export const SNAPSHOT_CHUNK_BYTES = 512 * 1024;
/**
 * D1 refuses any single bound value over 2,000,000 bytes. A chunk is one
 * bound value, so no chunk may exceed this, even a lone row.
 */
export const MAX_BOUND_VALUE_BYTES = 1_900_000;
/** Longest memo a snapshot row (transaction, schedule, or either's line) may carry. */
export const MAX_MEMO_LENGTH = 2000;

export class SnapshotValidationError extends Error {}

export class PlanNotEmptyError extends Error {
  constructor(message = "Snapshots can only be imported into an empty plan") {
    super(message);
  }
}

/**
 * The plan holds data a snapshot would collide with. A freshly created plan
 * is only its `plans` row, so any live account, transaction, schedule, payee,
 * category or category group counts. Internal groups and categories (YNAB's
 * "Inflow" and "Uncategorised" bookkeeping) are the one exception.
 * Takes the plan id once per EXISTS; see `planNotEmptyValues`.
 */
export const PLAN_NOT_EMPTY_CONDITION = `(
  EXISTS (SELECT 1 FROM accounts WHERE plan_id = ? AND deleted = 0)
  OR EXISTS (SELECT 1 FROM transactions WHERE plan_id = ? AND deleted = 0)
  OR EXISTS (SELECT 1 FROM categories WHERE plan_id = ? AND deleted = 0 AND internal = 0)
  OR EXISTS (SELECT 1 FROM category_groups WHERE plan_id = ? AND deleted = 0 AND internal = 0)
  OR EXISTS (SELECT 1 FROM payees WHERE plan_id = ? AND deleted = 0)
  OR EXISTS (SELECT 1 FROM scheduled_transaction_edits WHERE plan_id = ? AND deleted = 0)
)`;

export function planNotEmptyValues(planId: string): string[] {
  return Array.from({ length: 6 }, () => planId);
}

type Row = Record<string, any>;

export type SnapshotCategoryGroup = { id: string; name: string; hidden: boolean; internal: boolean; deleted: boolean };
export type SnapshotCategory = SnapshotCategoryGroup & { category_group_id: string };
export type SnapshotPayee = { id: string; name: string; transfer_account_id: string | null; deleted: boolean };
export type SnapshotAccount = {
  id: string;
  name: string;
  icon: string | null;
  type: string;
  on_budget: boolean;
  closed: boolean;
  opening_balance: number;
  transfer_payee_id: string | null;
};
export type SnapshotSubtransaction = {
  id: string;
  amount: number;
  memo: string | null;
  payee_id: string | null;
  /** Free-text payee of a line with no payee row; null whenever `payee_id` is set. */
  payee_name: string | null;
  category_id: string | null;
  transfer_account_id: string | null;
  transfer_transaction_id: string | null;
};
export type SnapshotTransaction = {
  id: string;
  account_id: string;
  date: string;
  amount: number;
  memo: string | null;
  cleared: string;
  approved: boolean;
  flag_color: string | null;
  flag_name: string | null;
  payee_id: string | null;
  /** Free-text payee of a row with no payee row; null whenever `payee_id` is set. */
  payee_name: string | null;
  category_id: string | null;
  transfer_account_id: string | null;
  transfer_transaction_id: string | null;
  matched_transaction_id: string | null;
  import_id: string | null;
  import_payee_name: string | null;
  import_payee_name_original: string | null;
  subtransactions: SnapshotSubtransaction[];
};
export type SnapshotScheduledSubtransaction = {
  id: string;
  amount: number;
  memo: string | null;
  payee_id: string | null;
  category_id: string | null;
  transfer_account_id: string | null;
};
export type SnapshotScheduledTransaction = {
  id: string;
  account_id: string;
  date_first: string;
  date_next: string;
  frequency: string;
  amount: number;
  memo: string | null;
  flag_color: string | null;
  payee_id: string | null;
  category_id: string | null;
  transfer_account_id: string | null;
  subtransactions: SnapshotScheduledSubtransaction[];
};

export type PlanSnapshot = {
  format: typeof SNAPSHOT_FORMAT;
  version: typeof SNAPSHOT_VERSION;
  category_groups: SnapshotCategoryGroup[];
  categories: SnapshotCategory[];
  payees: SnapshotPayee[];
  accounts: SnapshotAccount[];
  transactions: SnapshotTransaction[];
  scheduled_transactions: SnapshotScheduledTransaction[];
};

export type SnapshotCounts = {
  category_groups: number;
  categories: number;
  payees: number;
  accounts: number;
  transactions: number;
  subtransactions: number;
  scheduled_transactions: number;
};

/** Database-ready rows, keyed by column name, in insertion order. */
export type SnapshotRows = {
  category_groups: Row[];
  categories: Row[];
  payees: Row[];
  accounts: Row[];
  transactions: Row[];
  subtransactions: Row[];
  scheduled_transactions: Row[];
  scheduled_subtransactions: Row[];
  counts: SnapshotCounts;
};

const TOP_LEVEL_KEYS = new Set([
  "format", "version", "exported_at",
  "category_groups", "categories", "payees", "accounts", "transactions", "scheduled_transactions",
]);
const CLEARED = new Set(["cleared", "uncleared", "reconciled"]);

/**
 * Validates a snapshot and turns it into rows for `planId`.
 *
 * Every reference must resolve inside the snapshot, so a valid snapshot can
 * never point at another plan's data or leave a dangling id. Tombstoned
 * transactions and schedules are skipped; tombstoned groups, categories and
 * payees are kept because live transactions may still name them.
 */
export function parsePlanSnapshot(value: unknown, planId: string): SnapshotRows {
  const snapshot = object(value, "snapshot");
  for (const key of Object.keys(snapshot)) {
    if (!TOP_LEVEL_KEYS.has(key)) throw new SnapshotValidationError(`snapshot.${key} is not part of ${SNAPSHOT_FORMAT} version ${SNAPSHOT_VERSION}`);
  }
  if (snapshot.format !== SNAPSHOT_FORMAT) throw new SnapshotValidationError(`snapshot.format must be "${SNAPSHOT_FORMAT}"`);
  if (snapshot.version !== SNAPSHOT_VERSION) throw new SnapshotValidationError(`snapshot.version must be ${SNAPSHOT_VERSION}`);

  const groups = new Map<string, Row>();
  for (const [index, item] of list(snapshot.category_groups, "category_groups").entries()) {
    const path = `category_groups[${index}]`;
    const input = object(item, path);
    const id = unique(groups, id_(input.id, `${path}.id`), path);
    groups.set(id, {
      id,
      name: name(input.name, `${path}.name`),
      hidden: flag(input.hidden, `${path}.hidden`),
      internal: flag(input.internal, `${path}.internal`),
      deleted: flag(input.deleted, `${path}.deleted`),
    });
  }

  const categories = new Map<string, Row>();
  for (const [index, item] of list(snapshot.categories, "categories").entries()) {
    const path = `categories[${index}]`;
    const input = object(item, path);
    const id = unique(categories, id_(input.id, `${path}.id`), path);
    const groupId = id_(input.category_group_id, `${path}.category_group_id`);
    if (!groups.has(groupId)) throw new SnapshotValidationError(`${path}.category_group_id does not match a category group in the snapshot`);
    categories.set(id, {
      id,
      category_group_id: groupId,
      name: name(input.name, `${path}.name`),
      hidden: flag(input.hidden, `${path}.hidden`),
      internal: flag(input.internal, `${path}.internal`),
      deleted: flag(input.deleted, `${path}.deleted`),
    });
  }

  const rawAccounts = list(snapshot.accounts, "accounts").map((item, index) => object(item, `accounts[${index}]`));
  const accountIds = new Set<string>();
  for (const [index, input] of rawAccounts.entries()) {
    const path = `accounts[${index}]`;
    if (input.deleted === true) throw new SnapshotValidationError(`${path}: deleted accounts are not part of a snapshot`);
    const id = id_(input.id, `${path}.id`);
    if (accountIds.has(id)) throw new SnapshotValidationError(`${path}.id is duplicated`);
    accountIds.add(id);
  }

  const payees = new Map<string, Row>();
  const liveTransferPayee = new Map<string, string>();
  for (const [index, item] of list(snapshot.payees, "payees").entries()) {
    const path = `payees[${index}]`;
    const input = object(item, path);
    const id = unique(payees, id_(input.id, `${path}.id`), path);
    const deleted = flag(input.deleted, `${path}.deleted`);
    let transferAccountId = nullableId(input.transfer_account_id, `${path}.transfer_account_id`);
    if (transferAccountId && !accountIds.has(transferAccountId)) {
      if (!deleted) throw new SnapshotValidationError(`${path}.transfer_account_id does not match an account in the snapshot`);
      // A tombstoned transfer payee may outlive its account; drop the dangling link.
      transferAccountId = null;
    }
    if (transferAccountId && !deleted) {
      if (liveTransferPayee.has(transferAccountId)) throw new SnapshotValidationError(`${path}: account ${transferAccountId} already has a transfer payee`);
      liveTransferPayee.set(transferAccountId, id);
    }
    payees.set(id, { id, name: name(input.name, `${path}.name`), transfer_account_id: transferAccountId, deleted });
  }

  const accounts = new Map<string, Row>();
  for (const [index, input] of rawAccounts.entries()) {
    const path = `accounts[${index}]`;
    const id = String(input.id);
    const type = input.type === undefined || input.type === null ? "checking" : text(input.type, `${path}.type`, 64);
    const kind = parseAccountKind(type);
    const presentation = resolveAccountPresentation({
      name: name(input.name, `${path}.name`),
      icon: input.icon == null ? undefined : text(input.icon, `${path}.icon`, 32),
      type,
    });
    let transferPayeeId = nullableId(input.transfer_payee_id, `${path}.transfer_payee_id`);
    const linked = liveTransferPayee.get(id) ?? null;
    if (transferPayeeId) {
      if (linked !== transferPayeeId) throw new SnapshotValidationError(`${path}.transfer_payee_id must be a live payee whose transfer_account_id is this account`);
    } else if (linked) {
      transferPayeeId = linked;
    } else {
      // Every account owns a "Transfer : <name>" payee; provision one the
      // snapshot left out, with an id stable for this plan and account.
      transferPayeeId = `payee_transfer_${digest(`${planId}:${id}`).slice(0, 20)}`;
      if (payees.has(transferPayeeId)) throw new SnapshotValidationError(`${path}: generated transfer payee id collides with payee ${transferPayeeId}`);
      payees.set(transferPayeeId, { id: transferPayeeId, name: `Transfer : ${presentation.name}`, transfer_account_id: id, deleted: 0 });
      liveTransferPayee.set(id, transferPayeeId);
    }
    accounts.set(id, {
      id,
      name: presentation.name,
      icon: presentation.icon,
      type,
      on_budget: input.on_budget === undefined || input.on_budget === null
        ? (kind ? (onBudgetForKind(kind) ? 1 : 0) : 1)
        : flag(input.on_budget, `${path}.on_budget`),
      closed: flag(input.closed, `${path}.closed`),
      opening_balance_milli: input.opening_balance == null ? 0 : milliunits(input.opening_balance, `${path}.opening_balance`),
      transfer_payee_id: transferPayeeId,
    });
  }

  // Transactions: collect ids first so transfer links can point either way.
  const rawTransactions = list(snapshot.transactions, "transactions")
    .map((item, index) => ({ input: object(item, `transactions[${index}]`), path: `transactions[${index}]` }))
    .filter(({ input }) => input.deleted !== true);
  const transactionIds = new Set<string>();
  const subtransactionIds = new Set<string>();
  for (const { input, path } of rawTransactions) {
    const id = id_(input.id, `${path}.id`);
    if (transactionIds.has(id)) throw new SnapshotValidationError(`${path}.id is duplicated`);
    transactionIds.add(id);
    for (const [subIndex, sub] of list(input.subtransactions ?? [], `${path}.subtransactions`).entries()) {
      const subPath = `${path}.subtransactions[${subIndex}]`;
      const subInput = object(sub, subPath);
      if (subInput.deleted === true) continue;
      const subId = id_(subInput.id, `${subPath}.id`);
      if (subtransactionIds.has(subId)) throw new SnapshotValidationError(`${subPath}.id is duplicated`);
      subtransactionIds.add(subId);
    }
  }
  for (const id of subtransactionIds) {
    if (transactionIds.has(id)) throw new SnapshotValidationError(`id ${id} is used by both a transaction and a subtransaction`);
  }

  const payeeRef = (value: unknown, path: string) => reference(value, path, payees, "payee");
  const categoryRef = (value: unknown, path: string) => reference(value, path, categories, "category");
  const accountRef = (value: unknown, path: string) => reference(value, path, accounts, "account");
  const transferLink = (value: unknown, path: string) => {
    const id = nullableId(value, path);
    if (id && !transactionIds.has(id) && !subtransactionIds.has(id)) {
      throw new SnapshotValidationError(`${path} does not match a transaction or subtransaction in the snapshot`);
    }
    return id;
  };

  const transactions: Row[] = [];
  const subtransactions: Row[] = [];
  const paths = new Map<string, string>();
  const importIds = new Set<string>();
  for (const { input, path } of rawTransactions) {
    const accountId = accountRef(input.account_id, `${path}.account_id`);
    if (!accountId) throw new SnapshotValidationError(`${path}.account_id is required`);
    const amount = milliunits(input.amount, `${path}.amount`);
    const payeeId = payeeRef(input.payee_id, `${path}.payee_id`);
    const categoryId = categoryRef(input.category_id, `${path}.category_id`);
    const importId = nullableText(input.import_id, `${path}.import_id`, 200);
    if (importId) {
      const key = `${accountId}\u001f${importId}`;
      if (importIds.has(key)) throw new SnapshotValidationError(`${path}.import_id is duplicated on account ${accountId}`);
      importIds.add(key);
    }
    const cleared = input.cleared == null ? "uncleared" : String(input.cleared);
    if (!CLEARED.has(cleared)) throw new SnapshotValidationError(`${path}.cleared must be cleared, uncleared, or reconciled`);
    const liveSubs = list(input.subtransactions ?? [], `${path}.subtransactions`)
      .map((sub, subIndex) => ({ sub: object(sub, `${path}.subtransactions[${subIndex}]`), subPath: `${path}.subtransactions[${subIndex}]` }))
      .filter(({ sub }) => sub.deleted !== true);
    if (liveSubs.length > 0) {
      if (categoryId) throw new SnapshotValidationError(`${path}: a split transaction cannot have its own category_id`);
      const total = liveSubs.reduce((sum, { sub, subPath }) => sum + milliunits(sub.amount, `${subPath}.amount`), 0);
      if (total !== amount) throw new SnapshotValidationError(`${path}: subtransactions total ${total}, transaction amount is ${amount}`);
    }
    const id = String(input.id);
    paths.set(id, path);
    transactions.push({
      id,
      account_id: accountId,
      date: isoDate(input.date, `${path}.date`),
      amount_milli: amount,
      memo: nullableText(input.memo, `${path}.memo`, MAX_MEMO_LENGTH),
      cleared,
      approved: flag(input.approved, `${path}.approved`),
      flag_color: nullableText(input.flag_color, `${path}.flag_color`, 32),
      flag_name: nullableText(input.flag_name, `${path}.flag_name`, 200),
      payee_id: payeeId,
      payee_name_snapshot: payeeId ? payees.get(payeeId)!.name : nullableText(input.payee_name, `${path}.payee_name`, 500),
      category_id: categoryId,
      category_name_snapshot: categoryId ? categories.get(categoryId)!.name : null,
      transfer_account_id: accountRef(input.transfer_account_id, `${path}.transfer_account_id`),
      transfer_transaction_id: transferLink(input.transfer_transaction_id, `${path}.transfer_transaction_id`),
      matched_transaction_id: nullableText(input.matched_transaction_id, `${path}.matched_transaction_id`, 128),
      import_id: importId,
      import_payee_name: nullableText(input.import_payee_name, `${path}.import_payee_name`, 500),
      import_payee_name_original: nullableText(input.import_payee_name_original, `${path}.import_payee_name_original`, 500),
    });
    for (const { sub, subPath } of liveSubs) {
      const subPayee = payeeRef(sub.payee_id, `${subPath}.payee_id`);
      const subCategory = categoryRef(sub.category_id, `${subPath}.category_id`);
      paths.set(String(sub.id), subPath);
      subtransactions.push({
        id: String(sub.id),
        transaction_id: id,
        amount_milli: milliunits(sub.amount, `${subPath}.amount`),
        memo: nullableText(sub.memo, `${subPath}.memo`, MAX_MEMO_LENGTH),
        payee_id: subPayee,
        payee_name_snapshot: subPayee ? payees.get(subPayee)!.name : nullableText(sub.payee_name, `${subPath}.payee_name`, 500),
        category_id: subCategory,
        category_name_snapshot: subCategory ? categories.get(subCategory)!.name : null,
        transfer_account_id: accountRef(sub.transfer_account_id, `${subPath}.transfer_account_id`),
        transfer_transaction_id: transferLink(sub.transfer_transaction_id, `${subPath}.transfer_transaction_id`),
      });
    }
  }

  validateTransferGraph(transactions, subtransactions, paths);

  // Schedules reference only live rows: the D1 ownership triggers demand it.
  const livePayee = (id: string | null, path: string) => {
    if (id && payees.get(id)!.deleted) throw new SnapshotValidationError(`${path} names a deleted payee`);
    return id;
  };
  const liveCategory = (id: string | null, path: string) => {
    if (id && categories.get(id)!.deleted) throw new SnapshotValidationError(`${path} names a deleted category`);
    return id;
  };
  const scheduled: Row[] = [];
  const scheduledSubs: Row[] = [];
  const scheduleIds = new Set<string>();
  const scheduleSubIds = new Set<string>();
  for (const [index, item] of list(snapshot.scheduled_transactions, "scheduled_transactions").entries()) {
    const path = `scheduled_transactions[${index}]`;
    const input = object(item, path);
    if (input.deleted === true) continue;
    const id = id_(input.id, `${path}.id`);
    if (scheduleIds.has(id)) throw new SnapshotValidationError(`${path}.id is duplicated`);
    scheduleIds.add(id);
    const subsInput = list(input.subtransactions ?? [], `${path}.subtransactions`)
      .map((sub, subIndex) => ({ sub: object(sub, `${path}.subtransactions[${subIndex}]`), subPath: `${path}.subtransactions[${subIndex}]` }))
      .filter(({ sub }) => sub.deleted !== true);
    for (const { sub, subPath } of subsInput) {
      const subId = id_(sub.id, `${subPath}.id`);
      if (scheduleSubIds.has(subId)) throw new SnapshotValidationError(`${subPath}.id is duplicated`);
      scheduleSubIds.add(subId);
      nullableText(sub.memo, `${subPath}.memo`, MAX_MEMO_LENGTH);
    }
    // The schedule rules do not bound free text; the snapshot does, with the
    // same limits as its transactions.
    nullableText(input.memo, `${path}.memo`, MAX_MEMO_LENGTH);
    nullableText(input.flag_color, `${path}.flag_color`, 32);
    let schedule;
    try {
      // Optional fields are passed only when set, so the stored payload has
      // the same shape an ordinary schedule create would have produced.
      schedule = scheduledTransactionMutation(id, {
        account_id: input.account_id,
        date_first: input.date_first,
        date_next: input.date_next ?? input.date_first,
        frequency: input.frequency,
        amount: input.amount,
        ...present(input, ["payee_id", "category_id", "transfer_account_id", "memo", "flag_color"]),
        subtransactions: subsInput.map(({ sub }) => ({
          id: sub.id,
          amount: sub.amount,
          ...present(sub, ["payee_id", "category_id", "transfer_account_id", "memo"]),
        })),
      }, null, []);
    } catch (error) {
      if (error instanceof ScheduledTransactionValidationError) throw new SnapshotValidationError(`${path}: ${error.message}`);
      throw error;
    }
    const accountId = accountRef(schedule.account_id, `${path}.account_id`)!;
    schedule.account_name = accounts.get(accountId)!.name;
    const payeeId = livePayee(payeeRef(schedule.payee_id, `${path}.payee_id`), `${path}.payee_id`);
    if (payeeId) schedule.payee_name = payees.get(payeeId)!.name;
    const categoryId = liveCategory(categoryRef(schedule.category_id, `${path}.category_id`), `${path}.category_id`);
    if (categoryId) schedule.category_name = categories.get(categoryId)!.name;
    accountRef(schedule.transfer_account_id, `${path}.transfer_account_id`);
    for (const [subIndex, sub] of schedule.subtransactions.entries()) {
      const subPath = `${path}.subtransactions[${subIndex}]`;
      const subPayee = livePayee(payeeRef(sub.payee_id, `${subPath}.payee_id`), `${subPath}.payee_id`);
      if (subPayee) sub.payee_name = payees.get(subPayee)!.name;
      const subCategory = liveCategory(categoryRef(sub.category_id, `${subPath}.category_id`), `${subPath}.category_id`);
      if (subCategory) sub.category_name = categories.get(subCategory)!.name;
      accountRef(sub.transfer_account_id, `${subPath}.transfer_account_id`);
    }
    const { subtransactions: subs, ...parent } = schedule;
    scheduled.push({
      id,
      origin: "howmuch-local",
      payload_json: JSON.stringify(parent),
      account_id: schedule.account_id,
      date_first: schedule.date_first,
      date_next: schedule.date_next,
      frequency: schedule.frequency,
      amount_milli: schedule.amount,
      payee_id: schedule.payee_id ?? null,
      category_id: schedule.category_id ?? null,
      transfer_account_id: schedule.transfer_account_id ?? null,
    });
    for (const sub of subs) {
      scheduledSubs.push({
        id: sub.id,
        scheduled_transaction_id: id,
        payload_json: JSON.stringify(sub),
        amount_milli: sub.amount,
        payee_id: sub.payee_id ?? null,
        category_id: sub.category_id ?? null,
        transfer_account_id: sub.transfer_account_id ?? null,
      });
    }
  }

  const rows = {
    category_groups: [...groups.values()],
    categories: [...categories.values()],
    payees: [...payees.values()],
    accounts: [...accounts.values()],
    transactions,
    subtransactions,
    scheduled_transactions: scheduled,
    scheduled_subtransactions: scheduledSubs,
  };
  return {
    ...rows,
    counts: {
      category_groups: rows.category_groups.length,
      categories: rows.categories.length,
      payees: rows.payees.length,
      accounts: rows.accounts.length,
      transactions: rows.transactions.length,
      subtransactions: rows.subtransactions.length,
      scheduled_transactions: rows.scheduled_transactions.length,
    },
  };
}

type TablePlan = { table: string; columns: Array<[column: string, expression?: string]> };

/**
 * Column lists per table, in dependency order: payees precede accounts
 * because D1's account trigger requires the transfer payee to exist first.
 * A column without an expression is read from the row's JSON field of the
 * same name; `?` expressions bind the plan id.
 */
const TABLES: Array<[keyof Omit<SnapshotRows, "counts">, TablePlan]> = [
  ["category_groups", { table: "category_groups", columns: [["id"], ["plan_id", "?"], ["name"], ["hidden"], ["internal"], ["external_ynab_id", "$.id"], ["deleted"]] }],
  ["categories", { table: "categories", columns: [["id"], ["plan_id", "?"], ["category_group_id"], ["name"], ["hidden"], ["internal"], ["external_ynab_id", "$.id"], ["deleted"]] }],
  ["payees", { table: "payees", columns: [["id"], ["plan_id", "?"], ["name"], ["transfer_account_id"], ["external_ynab_id", "$.id"], ["deleted"]] }],
  ["accounts", { table: "accounts", columns: [["id"], ["plan_id", "?"], ["name"], ["icon"], ["type"], ["on_budget"], ["closed"], ["opening_balance_milli"], ["transfer_payee_id"], ["external_ynab_id", "$.id"]] }],
  ["transactions", { table: "transactions", columns: [
    ["id"], ["plan_id", "?"], ["account_id"], ["date"], ["amount_milli"], ["memo"], ["cleared"], ["approved"], ["flag_color"], ["flag_name"],
    ["payee_id"], ["payee_name_snapshot"], ["category_id"], ["category_name_snapshot"], ["transfer_account_id"], ["transfer_transaction_id"],
    ["matched_transaction_id"], ["import_id"], ["import_payee_name"], ["import_payee_name_original"], ["source_kind", "'snapshot-import'"], ["external_ynab_id", "$.id"],
  ] }],
  ["subtransactions", { table: "subtransactions", columns: [
    ["id"], ["transaction_id"], ["amount_milli"], ["memo"], ["payee_id"], ["payee_name_snapshot"], ["category_id"], ["category_name_snapshot"],
    ["transfer_account_id"], ["transfer_transaction_id"], ["external_ynab_id", "$.id"],
  ] }],
  ["scheduled_transactions", { table: "scheduled_transaction_edits", columns: [
    ["plan_id", "?"], ["id"], ["origin"], ["payload_json"], ["account_id"], ["date_first"], ["date_next"], ["frequency"], ["amount_milli"],
    ["payee_id"], ["category_id"], ["transfer_account_id"],
  ] }],
  ["scheduled_subtransactions", { table: "scheduled_subtransaction_edits", columns: [
    ["plan_id", "?"], ["id"], ["scheduled_transaction_id"], ["payload_json"], ["amount_milli"], ["payee_id"], ["category_id"], ["transfer_account_id"],
  ] }],
];

function insertSql(plan: TablePlan): { sql: string; bindsPlan: boolean } {
  let bindsPlan = false;
  const expressions = plan.columns.map(([column, expression]) => {
    if (expression === "?") { bindsPlan = true; return "?"; }
    if (expression?.startsWith("$.")) return `json_extract(value, '${expression}')`;
    if (expression) return expression;
    return `json_extract(value, '$.${column}')`;
  });
  return {
    sql: `INSERT INTO ${plan.table} (${plan.columns.map(([column]) => column).join(", ")})
      SELECT ${expressions.join(", ")} FROM json_each(?) ORDER BY CAST(key AS INTEGER)`,
    bindsPlan,
  };
}

/**
 * Splits rows into JSON arrays no larger than `maxBytes`. A row over
 * `maxBytes` stands alone, but a row too large to bind at all is refused.
 */
export function chunkRows(rows: readonly Row[], maxBytes = SNAPSHOT_CHUNK_BYTES): string[] {
  const encoder = new TextEncoder();
  const chunks: string[] = [];
  let current: string[] = [];
  let size = 2;
  const limit = Math.min(maxBytes, MAX_BOUND_VALUE_BYTES);
  for (const row of rows) {
    const json = JSON.stringify(row);
    const bytes = encoder.encode(json).length + 1;
    if (bytes + 2 > MAX_BOUND_VALUE_BYTES) {
      throw new SnapshotValidationError(`row ${String(row.id ?? "")} is too large to store (${bytes} bytes)`);
    }
    if (current.length > 0 && size + bytes > limit) {
      chunks.push(`[${current.join(",")}]`);
      current = [];
      size = 2;
    }
    current.push(json);
    size += bytes;
  }
  if (current.length > 0) chunks.push(`[${current.join(",")}]`);
  return chunks;
}

/**
 * Every statement the import writes, for both backends. The caller adds its
 * own guards in front (the D1 in-batch preconditions, or SQLite's reads in
 * the same immediate transaction).
 */
export function snapshotImportStatements(
  planId: string,
  rows: SnapshotRows,
  auditId: string,
  requestHash: string,
  maxChunkBytes = SNAPSHOT_CHUNK_BYTES,
): PlannedSql[] {
  const statements: PlannedSql[] = [];
  for (const [key, plan] of TABLES) {
    const { sql, bindsPlan } = insertSql(plan);
    for (const chunk of chunkRows(rows[key], maxChunkBytes)) {
      statements.push({ sql, values: bindsPlan ? [planId, chunk] : [chunk] });
    }
  }
  statements.push(
    {
      sql: `UPDATE accounts SET
        balance_milli = opening_balance_milli + COALESCE((SELECT SUM(t.amount_milli) FROM transactions t WHERE t.account_id = accounts.id AND t.deleted = 0), 0),
        cleared_balance_milli = opening_balance_milli + COALESCE((SELECT SUM(t.amount_milli) FROM transactions t WHERE t.account_id = accounts.id AND t.deleted = 0 AND t.cleared IN ('cleared', 'reconciled')), 0),
        uncleared_balance_milli = COALESCE((SELECT SUM(t.amount_milli) FROM transactions t WHERE t.account_id = accounts.id AND t.deleted = 0 AND t.cleared = 'uncleared'), 0),
        updated_at = CURRENT_TIMESTAMP
        WHERE plan_id = ?`,
      values: [planId],
    },
    { sql: "UPDATE plans SET server_knowledge = server_knowledge + 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?", values: [planId] },
    // The plan was empty, so every transaction in it arrived with this import.
    { sql: "UPDATE transactions SET server_knowledge = (SELECT server_knowledge FROM plans WHERE id = ?) WHERE plan_id = ?", values: [planId, planId] },
    {
      sql: "INSERT INTO audit_events(id,plan_id,action,resource_type,resource_id,source,metadata_json) VALUES (?,?,'plan.snapshot.import','plan',?,'howmuch-local',?)",
      values: [auditId, planId, planId, JSON.stringify({ request_hash: requestHash, counts: rows.counts })],
    },
  );
  return statements;
}

/** Stored rows for export, read in one consistent batch by the repository. */
export type SnapshotSource = {
  categoryGroups: Row[];
  categories: Row[];
  payees: Row[];
  accounts: Row[];
  transactions: Row[];
  subtransactions: Row[];
  scheduledTransactions: Row[];
};

/** Projects stored rows into the snapshot format the importer reads. */
export function projectPlanSnapshot(source: SnapshotSource): PlanSnapshot {
  const subsByTransaction = new Map<string, SnapshotSubtransaction[]>();
  for (const sub of source.subtransactions) {
    const key = String(sub.transaction_id);
    const entry: SnapshotSubtransaction = {
      id: String(sub.id),
      amount: Number(sub.amount_milli),
      memo: sub.memo ?? null,
      payee_id: sub.payee_id ?? null,
      payee_name: freeTextPayee(sub),
      category_id: sub.category_id ?? null,
      transfer_account_id: sub.transfer_account_id ?? null,
      transfer_transaction_id: sub.transfer_transaction_id ?? null,
    };
    const existing = subsByTransaction.get(key);
    if (existing) existing.push(entry);
    else subsByTransaction.set(key, [entry]);
  }
  return {
    format: SNAPSHOT_FORMAT,
    version: SNAPSHOT_VERSION,
    category_groups: source.categoryGroups.map((row) => ({
      id: String(row.id), name: String(row.name), hidden: Boolean(row.hidden), internal: Boolean(row.internal), deleted: Boolean(row.deleted),
    })),
    categories: source.categories.map((row) => ({
      id: String(row.id), category_group_id: String(row.category_group_id), name: String(row.name),
      hidden: Boolean(row.hidden), internal: Boolean(row.internal), deleted: Boolean(row.deleted),
    })),
    payees: source.payees.map((row) => ({
      id: String(row.id), name: String(row.name), transfer_account_id: row.transfer_account_id ?? null, deleted: Boolean(row.deleted),
    })),
    accounts: source.accounts.map((row) => {
      const presentation = resolveAccountPresentation({ name: row.name, existingIcon: row.icon, type: row.type });
      return {
        id: String(row.id),
        name: presentation.name,
        icon: presentation.icon ?? null,
        type: String(row.type),
        on_budget: Boolean(row.on_budget),
        closed: Boolean(row.closed),
        opening_balance: Number(row.opening_balance_milli),
        transfer_payee_id: row.transfer_payee_id ?? null,
      };
    }),
    transactions: source.transactions.map((row) => ({
      id: String(row.id),
      account_id: String(row.account_id),
      date: String(row.date),
      amount: Number(row.amount_milli),
      memo: row.memo ?? null,
      cleared: String(row.cleared),
      approved: Boolean(row.approved),
      flag_color: row.flag_color ?? null,
      flag_name: row.flag_name ?? null,
      payee_id: row.payee_id ?? null,
      payee_name: freeTextPayee(row),
      category_id: row.category_id ?? null,
      transfer_account_id: row.transfer_account_id ?? null,
      transfer_transaction_id: row.transfer_transaction_id ?? null,
      matched_transaction_id: row.matched_transaction_id ?? null,
      import_id: row.import_id ?? null,
      import_payee_name: row.import_payee_name ?? null,
      import_payee_name_original: row.import_payee_name_original ?? null,
      subtransactions: subsByTransaction.get(String(row.id)) ?? [],
    })),
    scheduled_transactions: source.scheduledTransactions
      .filter((schedule) => !schedule.deleted)
      .map((schedule) => ({
        id: String(schedule.id),
        account_id: String(schedule.account_id),
        date_first: String(schedule.date_first),
        date_next: String(schedule.date_next ?? schedule.date_first),
        frequency: String(schedule.frequency),
        amount: Number(schedule.amount),
        memo: schedule.memo ?? null,
        flag_color: schedule.flag_color ?? null,
        payee_id: schedule.payee_id ?? null,
        category_id: schedule.category_id ?? null,
        transfer_account_id: schedule.transfer_account_id ?? null,
        subtransactions: (schedule.subtransactions ?? [])
          .filter((sub: Row) => !sub.deleted)
          .map((sub: Row) => ({
            id: String(sub.id),
            amount: Number(sub.amount),
            memo: sub.memo ?? null,
            payee_id: sub.payee_id ?? null,
            category_id: sub.category_id ?? null,
            transfer_account_id: sub.transfer_account_id ?? null,
          })),
      }))
      .sort((left, right) => left.id.localeCompare(right.id)),
  };
}

/**
 * Transfer links must form the graph the server's own transfer writes build
 * (and `scripts/lib/ynab-d1-bootstrap.ts` checks): a linked row names its
 * counterpart's account in `transfer_account_id`, and the counterpart links
 * back, sits in that account, carries the negated amount, and names this
 * row's account as its own `transfer_account_id`. A split line's counterpart
 * is always a top-level transaction; a top-level transaction's counterpart is
 * a top-level transaction or a split line.
 */
function validateTransferGraph(transactions: Row[], subtransactions: Row[], paths: Map<string, string>): void {
  type Side = { row: Row; accountId: string; path: string; split: boolean };
  const sides = new Map<string, Side>();
  const parentAccount = new Map<string, string>();
  for (const row of transactions) {
    parentAccount.set(row.id, row.account_id);
    sides.set(row.id, { row, accountId: row.account_id, path: paths.get(row.id)!, split: false });
  }
  for (const row of subtransactions) {
    sides.set(row.id, { row, accountId: parentAccount.get(row.transaction_id)!, path: paths.get(row.id)!, split: true });
  }
  for (const side of sides.values()) {
    if (side.row.transfer_transaction_id && !side.row.transfer_account_id) {
      throw new SnapshotValidationError(`${side.path}.transfer_transaction_id is set, so transfer_account_id is required`);
    }
  }
  for (const side of sides.values()) {
    const counterpartId: string | null = side.row.transfer_transaction_id;
    if (!counterpartId) continue;
    const where = `${side.path}.transfer_transaction_id`;
    const other = sides.get(counterpartId)!;
    if (side.split && other.split) {
      throw new SnapshotValidationError(`${where}: a split line's transfer counterpart must be a transaction, not another split line`);
    }
    if (other.row.transfer_transaction_id !== side.row.id) {
      throw new SnapshotValidationError(`${where}: counterpart ${counterpartId} does not link back to ${side.row.id}`);
    }
    if (other.accountId !== side.row.transfer_account_id) {
      throw new SnapshotValidationError(`${where}: counterpart ${counterpartId} is in account ${other.accountId}, not transfer_account_id ${side.row.transfer_account_id}`);
    }
    if (other.row.amount_milli !== -side.row.amount_milli) {
      throw new SnapshotValidationError(`${where}: counterpart ${counterpartId} has amount ${other.row.amount_milli}; it must be ${-side.row.amount_milli}`);
    }
    if (other.row.transfer_account_id !== side.accountId) {
      throw new SnapshotValidationError(`${where}: counterpart ${counterpartId} must name account ${side.accountId} as its transfer_account_id`);
    }
  }
}

/**
 * A row's payee name travels only when no payee row carries it. With a
 * `payee_id` the import re-derives the name from that payee, as reads do.
 */
function freeTextPayee(row: Row): string | null {
  return row.payee_id ? null : (row.payee_name_snapshot ?? null);
}

function present(input: Row, keys: readonly string[]): Row {
  return Object.fromEntries(keys.filter((key) => input[key] !== undefined && input[key] !== null).map((key) => [key, input[key]]));
}

function object(value: unknown, path: string): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new SnapshotValidationError(`${path} must be an object`);
  return value as Row;
}

function list(value: unknown, path: string): unknown[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new SnapshotValidationError(`${path} must be an array`);
  return value;
}

function id_(value: unknown, path: string): string {
  if (typeof value !== "string" || !ENTITY_ID_PATTERN.test(value)) {
    throw new SnapshotValidationError(`${path} must be 1-128 letters, numbers, dots, underscores, colons, or hyphens`);
  }
  return value;
}

function nullableId(value: unknown, path: string): string | null {
  return value === undefined || value === null ? null : id_(value, path);
}

function unique(map: Map<string, unknown>, id: string, path: string): string {
  if (map.has(id)) throw new SnapshotValidationError(`${path}.id is duplicated`);
  return id;
}

function reference(value: unknown, path: string, rows: Map<string, unknown>, label: string): string | null {
  const id = nullableId(value, path);
  if (id && !rows.has(id)) throw new SnapshotValidationError(`${path} does not match a ${label} in the snapshot`);
  return id;
}

function text(value: unknown, path: string, max: number): string {
  if (typeof value !== "string" || value.length > max) throw new SnapshotValidationError(`${path} must be a string of at most ${max} characters`);
  return value;
}

function nullableText(value: unknown, path: string, max: number): string | null {
  return value === undefined || value === null ? null : text(value, path, max);
}

function name(value: unknown, path: string, max = 500): string {
  const result = text(value, path, max).trim();
  if (!result) throw new SnapshotValidationError(`${path} is required`);
  return result;
}

function flag(value: unknown, path: string): number {
  if (value === undefined || value === null) return 0;
  if (typeof value !== "boolean") throw new SnapshotValidationError(`${path} must be a boolean`);
  return value ? 1 : 0;
}

function milliunits(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) throw new SnapshotValidationError(`${path} must be integer milliunits`);
  return value;
}

function isoDate(value: unknown, path: string): string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new SnapshotValidationError(`${path} must be an ISO date (YYYY-MM-DD)`);
  const date = new Date(`${value}T00:00:00Z`);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== value) throw new SnapshotValidationError(`${path} must be a valid calendar date`);
  return value;
}

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
