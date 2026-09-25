import type { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { createId } from "./ids";
import { SqliteRepositoryDatabase, type RepositoryDatabase } from "./repository-db";
import {
  DEFAULT_TRANSACTION_PAGE_SIZE,
  MAX_TRANSACTION_PAGE_SIZE,
  type ClearedState,
  type TransactionFilters,
  type TransactionInput,
  type ScheduledTransactionInput,
  type ScheduledMaterializationResult,
  type ScheduledCronMaterializationResult,
  type ScheduledOccurrenceResult,
  type AccountReconciliationOptions,
  type AccountReconciliationPreview,
  type AccountReconciliationResult,
  type AccountPreferences,
  type AccountPreferencesSnapshot,
  type ScheduledWriteOptions,
  type TransactionPage,
  type UnapprovedCount,
  type TransactionBatchResult,
  type TransactionBatchUpdate,
  type TransactionBulkOutcome,
  type TransactionBulkResult,
  type TransactionBulkStatus,
  type TransactionClearedItem,
  type TransactionDeleteItem,
  type TransactionLookup,
} from "./types";
import {
  scheduledOccurrencesThrough,
  scheduledTransactionMutation,
  nextScheduledOccurrence,
  type EffectiveScheduledTransaction,
} from "./scheduled-transactions";
import { parseAccountIcon, resolveAccountPresentation, splitLegacyAccountName } from "./account-icon";
import { applyAccountUpdate, type AccountUpdatePatch } from "./account-kind";
import { parseRegisterQuery, transactionSearchSql } from "@howmuch/register-query";
import {
  CATEGORY_IN_USE_CONDITION,
  CategoryInUseError,
  EntityConflictError,
  YNAB_MONTH_PRESENT_SQL,
  YnabMirrorPlanError,
  categoryCommandStatements,
  categoryInUseValues,
  createCategoryCommand,
  createCategoryGroupCommand,
  deleteCategoryCommand,
  isUniqueViolation,
  updateCategoryCommand,
  updateCategoryGroupCommand,
  type CategoryCommand,
  type CategoryCreate,
  type CategoryGroupCreate,
  type CategoryGroupPatch,
  type CategoryGroupRow,
  type CategoryPatch,
  type CategoryRow,
} from "./category-management";
import { requestHash } from "./d1-guarded-command";

type Row = Record<string, any>;

export type CategoryWriteOptions = { operationId?: string };

/** Stable across retries when the client sends an Idempotency-Key but no id. */
function derivedEntityId(prefix: string, planId: string, operationId?: string): string {
  return operationId
    ? `${prefix}_${createHash("sha256").update(`${planId}:${operationId}`).digest("hex").slice(0, 24)}`
    : createId(prefix);
}

function categoryRequestHash(action: string, planId: string, resourceId: string, request: unknown): string {
  return requestHash({ action, planId, resourceId, request });
}

function displayAccountName(value: unknown): string | null {
  if (value == null) return null;
  return splitLegacyAccountName(String(value)).name;
}

type AccountReconciliationSnapshot = {
  account: Row;
  currentReconciledBalance: number;
  projectedReconciledBalance: number;
  candidateIds: string[];
};

export type TransactionWriteOptions = {
  /**
   * When true (the default for API writes), a payee that points at another
   * account creates the linked side of the transfer, YNAB-style. Importers
   * pass false because their data already carries both sides.
   */
  autoLink?: boolean;
  /** Stable operation receipt used for retry-safe transaction creation. */
  operationId?: string;
};

/** Operation-local effects accumulated while a transaction graph is written. */
type TransactionMutationPlan = {
  touchedTransactionIds: Set<string>;
  accountIdsToRecalculate: Set<string>;
};

function newTransactionMutationPlan(): TransactionMutationPlan {
  return { touchedTransactionIds: new Set(), accountIdsToRecalculate: new Set() };
}

/**
 * Safe text for an ambiguous per-row bulk failure. The real error may name
 * tables, bindings, or driver state, and the HTTP layer keeps those out of
 * response bodies; a 200 bulk body must not leak what a 500 would redact.
 */
const BULK_UNRESOLVED_DETAIL = "This row's write could not be confirmed";

function emptyRewardsTrackerSnapshot(cards: unknown[]): Record<string, unknown> {
  const trackedAccountIds = [...new Set(cards.flatMap((entry) => {
    const accountId = typeof entry === "object" && entry && !Array.isArray(entry)
      ? (entry as { ynabAccountId?: unknown }).ynabAccountId
      : undefined;
    return typeof accountId === "string" && accountId.trim() ? [accountId.trim()] : [];
  }))];
  return {
    ynab: { trackedAccountIds },
    cards,
    rules: [],
    tagMappings: [],
    calculations: [],
    themeGroups: [],
    hiddenCards: [],
    settings: {},
  };
}

function rewardsTrackerCardId(entry: unknown): string | null {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null;
  const id = (entry as { id?: unknown }).id;
  return typeof id === "string" && id.trim() ? id.trim() : null;
}

export class LedgerRepository {
  private readonly db: RepositoryDatabase;

  constructor(db: Database | RepositoryDatabase, private readonly defaultPlanId: string) {
    this.db = "inTransaction" in db ? new SqliteRepositoryDatabase(db as Database) : db;
  }

  getDefaultPlanId(): string {
    return this.defaultPlanId;
  }

  async ensurePlan(planId = this.defaultPlanId, name = "HowMuch"): Promise<void> {
    await this.db
      .query(
        `INSERT INTO plans (id, name, external_ynab_id, first_month, last_month)
         VALUES (?, ?, ?, strftime('%Y-%m', 'now'), strftime('%Y-%m', 'now'))
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(planId, name, planId);
  }

  async touchPlan(planId: string): Promise<number> {
    await this.ensurePlan(planId);
    const row = await this.db
      .query(
        `UPDATE plans
         SET server_knowledge = server_knowledge + 1, updated_at = CURRENT_TIMESTAMP
         WHERE id = ?
         RETURNING server_knowledge`,
      )
      .get(planId) as Row;
    return Number(row.server_knowledge);
  }

  async getServerKnowledge(planId: string): Promise<number> {
    const row = await this.db.query(SERVER_KNOWLEDGE_SQL).get(planId) as Row | null;
    if (!row) throw new PlanNotFoundError();
    return Number(row.server_knowledge);
  }

  async listPlans(): Promise<any[]> {
    return (await this.db.query("SELECT * FROM plans WHERE deleted = 0 ORDER BY name").all()).map(formatPlan);
  }

  async getPlan(planId: string): Promise<any> {
    const row = await this.db.query("SELECT * FROM plans WHERE id = ?").get(planId) as Row | null;
    if (!row) throw new PlanNotFoundError();
    return formatPlan(row);
  }

  async upsertPlan(planId: string, plan: any, settings?: any): Promise<void> {
    await this.ensurePlan(planId, plan.name ?? "HowMuch");
    const existing = await this.db.query("SELECT * FROM plans WHERE id = ?").get(planId) as Row;

    await this.db
      .query(
        `UPDATE plans
         SET name = ?,
             first_month = ?,
             last_month = ?,
             date_format_json = ?,
             currency_format_json = ?,
             flag_names_json = ?,
             external_ynab_id = ?,
             deleted = ?,
             updated_at = CURRENT_TIMESTAMP
         WHERE id = ?`,
      )
      .run(
        plan.name ?? existing.name,
        plan.first_month ?? existing.first_month,
        plan.last_month ?? existing.last_month,
        JSON.stringify(settings?.date_format ?? JSON.parse(existing.date_format_json)),
        JSON.stringify(settings?.currency_format ?? JSON.parse(existing.currency_format_json)),
        JSON.stringify(settings?.display?.flag_names ?? JSON.parse(existing.flag_names_json)),
        plan.id ?? existing.external_ynab_id ?? planId,
        bool(plan.deleted),
        planId,
      );
  }

  async getSettings(planId: string): Promise<any> {
    const row = await this.db.query("SELECT * FROM plans WHERE id = ?").get(planId) as Row | null;
    if (!row) throw new PlanNotFoundError();
    return {
      date_format: JSON.parse(row.date_format_json),
      currency_format: JSON.parse(row.currency_format_json),
      display: {
        flag_names: JSON.parse(row.flag_names_json),
      },
    };
  }

  async getAccountPreferences(planId: string, userId: string): Promise<AccountPreferencesSnapshot> {
    const row = await this.db
      .query("SELECT preferences_json, revision FROM account_preferences WHERE user_id = ? AND plan_id = ?")
      .get(userId, planId) as Row | null;
    return row
      ? { account_preferences: JSON.parse(String(row.preferences_json)) as AccountPreferences, account_preferences_revision: Number(row.revision) }
      : { account_preferences: null, account_preferences_revision: 0 };
  }

  async setAccountPreferences(
    planId: string,
    userId: string,
    preferences: AccountPreferences,
    expectedRevision: number,
  ): Promise<AccountPreferencesSnapshot> {
    const result = expectedRevision === 0
      ? await this.db.query(
        `INSERT INTO account_preferences (user_id, plan_id, preferences_json, revision, updated_at)
         VALUES (?, ?, ?, 1, unixepoch()) ON CONFLICT(user_id, plan_id) DO NOTHING`,
      ).run(userId, planId, JSON.stringify(preferences))
      : await this.db.query(
        `UPDATE account_preferences SET preferences_json = ?, revision = revision + 1, updated_at = unixepoch()
         WHERE user_id = ? AND plan_id = ? AND revision = ?`,
      ).run(JSON.stringify(preferences), userId, planId, expectedRevision);
    if (result.changes !== 1) {
      const current = await this.db
        .query("SELECT preferences_json, revision FROM account_preferences WHERE user_id = ? AND plan_id = ?")
        .get(userId, planId) as Row | null;
      if (!current
        || Number(current.revision) !== expectedRevision + 1
        || String(current.preferences_json) !== JSON.stringify(preferences)) {
        throw new AccountPreferencesConflictError();
      }
    }
    return { account_preferences: preferences, account_preferences_revision: expectedRevision + 1 };
  }

  async ensureAccount(planId: string, accountId: string, name?: string): Promise<void> {
    await this.ensurePlan(planId);
    await this.db
      .query(
        `INSERT INTO accounts (id, plan_id, name, external_ynab_id)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(accountId, planId, name ?? `Imported account ${accountId.slice(0, 8)}`, accountId);
    await this.ensureTransferPayee(planId, accountId);
  }

  async createAccount(planId: string, account: any): Promise<any> {
    const accountId = account.id ?? createId("acct");
    if (account.id) {
      // Pre-existing reseed shape: `balance` stays a transient snapshot that
      // transaction recalculation owns; only an explicit opening_balance
      // persists. Folding balance in here would double-count ledgers that
      // POST accounts and then import their starting-balance transactions.
      await this.upsertAccount(planId, account);
    } else {
      // YNAB's create-account body carries the starting balance in `balance`.
      const openingBalance = account.opening_balance ?? account.balance ?? 0;
      await this.upsertAccount(planId, {
        ...account,
        id: accountId,
        opening_balance: openingBalance,
        balance: account.balance ?? openingBalance,
        cleared_balance: account.cleared_balance ?? account.balance ?? openingBalance,
      });
    }
    await this.touchPlan(planId);
    return this.getAccount(planId, accountId);
  }

  /**
   * Every account owns a "Transfer : <name>" payee (YNAB parity) so clients
   * can record transfers by picking a payee. Provisions the payee when
   * missing and keeps its label in step with account renames.
   */
  async ensureTransferPayee(planId: string, accountId: string): Promise<{ id: string; name: string } | null> {
    const account = await this.db
      .query("SELECT * FROM accounts WHERE id = ? AND plan_id = ?")
      .get(accountId, planId) as Row | null;
    if (!account || toBoolean(account.deleted)) {
      return null;
    }

    let payee = await this.db
      .query("SELECT * FROM payees WHERE plan_id = ? AND transfer_account_id = ? AND deleted = 0")
      .get(planId, accountId) as Row | null;

    if (!payee && account.transfer_payee_id) {
      const byId = await this.db.query("SELECT * FROM payees WHERE id = ?").get(account.transfer_payee_id) as Row | null;
      if (!byId) {
        // Mid-import: the account references a payee that arrives later
        // (YNAB imports write accounts before payees). Leave it alone.
        return null;
      }
      if (byId.transfer_account_id == null) {
        await this.db
          .query("UPDATE payees SET transfer_account_id = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?")
          .run(accountId, byId.id);
        byId.transfer_account_id = accountId;
      }
      payee = byId;
    }

    const expectedName = `Transfer : ${account.name}`;
    if (!payee) {
      const payeeId = createId("payee");
      try {
        await this.db
          .query("INSERT INTO payees (id, plan_id, name, transfer_account_id, external_ynab_id) VALUES (?, ?, ?, ?, ?)")
          .run(payeeId, planId, expectedName, accountId, payeeId);
      } catch {
        // Duplicate account names collide on the payee name; disambiguate.
        await this.db
          .query("INSERT INTO payees (id, plan_id, name, transfer_account_id, external_ynab_id) VALUES (?, ?, ?, ?, ?)")
          .run(payeeId, planId, `${expectedName} (${accountId.slice(-4)})`, accountId, payeeId);
      }
      payee = await this.db.query("SELECT * FROM payees WHERE id = ?").get(payeeId) as Row;
    } else if (payee.name !== expectedName && String(payee.name ?? "").startsWith("Transfer : ")) {
      try {
        await this.db
          .query("UPDATE payees SET name = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?")
          .run(expectedName, payee.id);
        payee.name = expectedName;
      } catch {
        // Another payee already holds the name; keep the stale label.
      }
    }

    if (account.transfer_payee_id !== payee.id) {
      await this.db
        .query("UPDATE accounts SET transfer_payee_id = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?")
        .run(payee.id, accountId);
    }
    return { id: payee.id, name: payee.name };
  }

  async upsertAccount(planId: string, account: any): Promise<void> {
    await this.ensurePlan(planId);
    const existing = await this.db.query("SELECT icon FROM accounts WHERE id = ?").get(account.id) as Row | null;
    const presentation = resolveAccountPresentation({
      name: account.name ?? `Account ${account.id}`,
      icon: account.icon,
      type: account.type ?? "checking",
      existingIcon: existing?.icon,
    });
    await this.db
      .query(
        `INSERT INTO accounts (
           id, plan_id, name, icon, type, on_budget, closed, opening_balance_milli,
           balance_milli, cleared_balance_milli, uncleared_balance_milli,
           transfer_payee_id, direct_import_linked, direct_import_in_error,
           external_ynab_id, deleted, updated_at
         )
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
         ON CONFLICT(id) DO UPDATE SET
           name = excluded.name,
           icon = excluded.icon,
           type = excluded.type,
           on_budget = excluded.on_budget,
           closed = excluded.closed,
           opening_balance_milli = excluded.opening_balance_milli,
           balance_milli = excluded.balance_milli,
           cleared_balance_milli = excluded.cleared_balance_milli,
           uncleared_balance_milli = excluded.uncleared_balance_milli,
           transfer_payee_id = COALESCE(excluded.transfer_payee_id, accounts.transfer_payee_id),
           direct_import_linked = excluded.direct_import_linked,
           direct_import_in_error = excluded.direct_import_in_error,
           external_ynab_id = excluded.external_ynab_id,
           deleted = excluded.deleted,
           updated_at = CURRENT_TIMESTAMP`,
      )
      .run(
        account.id,
        planId,
        presentation.name,
        presentation.icon,
        account.type ?? "checking",
        bool(account.on_budget, true),
        bool(account.closed),
        account.opening_balance ?? 0,
        account.balance ?? 0,
        account.cleared_balance ?? account.balance ?? 0,
        account.uncleared_balance ?? 0,
        account.transfer_payee_id ?? null,
        bool(account.direct_import_linked),
        bool(account.direct_import_in_error),
        account.external_ynab_id ?? account.id,
        bool(account.deleted),
      );
    await this.ensureTransferPayee(planId, account.id);
    // An importer renaming, closing or deleting an account changes what every
    // client shows. Clients validate cached accounts against `server_knowledge`
    // (#175), so a delta import carrying only account changes has to move it.
    await this.touchPlan(planId);
  }

  async updateAccount(planId: string, accountId: string, patch: AccountUpdatePatch): Promise<any> {
    const nextIcon = patch.icon === undefined ? undefined : parseAccountIcon(patch.icon);
    if (nextIcon === null) throw new ValidationError("icon must be a single emoji");
    const nextName = patch.name === undefined ? undefined : String(patch.name).trim();
    if (patch.name !== undefined && !nextName) throw new ValidationError("account.name is required");
    if (nextIcon === undefined && nextName === undefined && patch.kind === undefined) {
      throw new ValidationError("account.icon, account.name, or account.type is required");
    }
    const row = await this.db
      .query("SELECT name, icon, type FROM accounts WHERE id = ? AND plan_id = ? AND deleted = 0")
      .get(accountId, planId) as Row | null;
    if (!row) throw new NotFoundError("Account not found");
    const fields = applyAccountUpdate(
      { name: String(row.name ?? ""), icon: row.icon, type: row.type },
      { ...(nextIcon !== undefined ? { icon: nextIcon } : {}), ...(nextName !== undefined ? { name: nextName } : {}), ...(patch.kind ? { kind: patch.kind } : {}) },
    );
    const assignments: string[] = [];
    const values: unknown[] = [];
    if (fields.name !== undefined) {
      assignments.push("name = ?");
      values.push(fields.name);
    }
    if (fields.icon !== undefined) {
      assignments.push("icon = ?");
      values.push(fields.icon);
    }
    if (fields.type !== undefined) {
      assignments.push("type = ?");
      values.push(fields.type);
      assignments.push("on_budget = ?");
      values.push(bool(fields.on_budget));
    }
    await this.db
      .query(`UPDATE accounts SET ${assignments.join(", ")}, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND plan_id = ?`)
      .run(...values, accountId, planId);
    if (fields.name !== undefined) {
      await this.ensureTransferPayee(planId, accountId);
    }
    await this.touchPlan(planId);
    return this.getAccount(planId, accountId);
  }

  async listAccounts(planId: string): Promise<any[]> {
    return (await this.db.query(LIST_ACCOUNTS_SQL).all(planId)).map(formatAccount);
  }

  /** Accounts and the knowledge value that labels them, in one round trip. */
  async listAccountsWithKnowledge(planId: string): Promise<{ accounts: any[]; server_knowledge: number }> {
    const [rows, knowledgeRows] = await this.db.batchRead([
      { sql: LIST_ACCOUNTS_SQL, values: [planId] },
      { sql: SERVER_KNOWLEDGE_SQL, values: [planId] },
    ]);
    return { accounts: (rows ?? []).map(formatAccount), server_knowledge: knowledgeFrom(knowledgeRows) };
  }

  /**
   * Per-account transaction counts over a closed date window, in one grouped
   * query plus the knowledge value that labels them.
   *
   * The counting semantics match the register list the web client used to
   * paginate for this: live rows of this plan whose `date` falls inside the
   * inclusive window. Each transfer leg counts in its own account, a split
   * parent counts once (its subtransactions live in another table and are not
   * counted), scheduled transactions are not counted, and rows dated after
   * `until` are excluded. The window is supplied by the caller, so the client
   * keeps ownership of what "today" means in its own time zone.
   */
  async accountUsage(
    planId: string,
    since: string,
    until: string,
  ): Promise<{ usage: Array<{ account_id: string; count: number }>; since: string; until: string; server_knowledge: number }> {
    const [rows, knowledgeRows] = await this.db.batchRead([
      { sql: ACCOUNT_USAGE_SQL, values: [planId, since, until] },
      { sql: SERVER_KNOWLEDGE_SQL, values: [planId] },
    ]);
    return {
      usage: (rows ?? []).map((row) => ({ account_id: String(row.account_id), count: Number(row.usage_count) })),
      since,
      until,
      server_knowledge: knowledgeFrom(knowledgeRows),
    };
  }

  async findAccount(planId: string, accountId: string): Promise<any | null> {
    const row = await this.db.query(`${ACCOUNT_SELECT_SQL} WHERE id = ? AND plan_id = ? AND deleted = 0`).get(accountId, planId) as Row | null;
    return row ? formatAccount(row) : null;
  }

  async findPayee(planId: string, payeeId: string): Promise<any | null> {
    const row = await this.db.query("SELECT * FROM payees WHERE id = ? AND plan_id = ? AND deleted = 0").get(payeeId, planId) as Row | null;
    return row ? formatPayee(row) : null;
  }

  private async liveAccounts(planId: string): Promise<Map<string, { id: string; closed: boolean; type: string }>> {
    const rows = await this.db.query("SELECT id, closed, type FROM accounts WHERE plan_id = ? AND deleted = 0").all(planId) as Row[];
    return new Map(rows.map((row) => [String(row.id), { id: String(row.id), closed: toBoolean(row.closed), type: String(row.type ?? "checking") }]));
  }

  private async liveAccount(planId: string, accountId: string): Promise<{ id: string; closed: boolean; type: string } | null> {
    const row = await this.db.query("SELECT id, closed, type FROM accounts WHERE id = ? AND plan_id = ? AND deleted = 0").get(accountId, planId) as Row | null;
    return row ? { id: String(row.id), closed: toBoolean(row.closed), type: String(row.type ?? "checking") } : null;
  }

  private async liveCategory(planId: string, categoryId: string): Promise<boolean> {
    return Boolean(await this.db.query("SELECT 1 FROM categories WHERE id = ? AND plan_id = ? AND deleted = 0").get(categoryId, planId));
  }

  async getAccount(planId: string, accountId: string): Promise<any> {
    await this.ensureAccount(planId, accountId);
    const row = await this.db.query(`${ACCOUNT_SELECT_SQL} WHERE id = ? AND plan_id = ?`).get(accountId, planId) as Row;
    return formatAccount(row);
  }

  async getAccountReconciliation(planId: string, accountId: string, statementDate: string): Promise<AccountReconciliationPreview> {
    const date = normaliseReconciliationDate(statementDate);
    const snapshot = await this.accountReconciliationSnapshot(planId, accountId, date);
    return {
      account: formatAccount(snapshot.account),
      statement_date: date,
      current_reconciled_balance: snapshot.currentReconciledBalance,
      projected_reconciled_balance: snapshot.projectedReconciledBalance,
      candidate_transaction_ids: snapshot.candidateIds,
      candidate_transaction_count: snapshot.candidateIds.length,
      server_knowledge: await this.getServerKnowledge(planId),
    };
  }

  async reconcileAccount(
    planId: string,
    accountId: string,
    statementDate: string,
    statementBalance: number,
    options: AccountReconciliationOptions,
  ): Promise<AccountReconciliationResult> {
    const date = normaliseReconciliationDate(statementDate);
    if (!Number.isSafeInteger(statementBalance)) throw new ValidationError("statement_balance must be integer milliunits");
    if (!accountId || typeof accountId !== "string") throw new ValidationError("account_id is required");
    if (!options?.operationId) throw new ValidationError("operationId is required");
    const requestHash = scheduleMutationFingerprint("account.reconcile", planId, accountId, { statement_date: date, statement_balance: statementBalance });
    const auditId = `audit_reconcile_${scheduleDigest(options.operationId).slice(0, 20)}`;
    let result: Omit<AccountReconciliationResult, "account" | "replayed" | "server_knowledge"> | null = null;
    let replayed = false;

    await this.db.transaction(async () => {
      const receipt = await this.db.query("SELECT action,plan_id,resource_id,metadata_json FROM audit_events WHERE id=?").get(auditId) as Row | null;
      if (receipt) {
        const metadata = JSON.parse(String(receipt.metadata_json));
        if (receipt.action !== "account.reconcile" || receipt.plan_id !== planId || receipt.resource_id !== accountId || metadata.request_hash !== requestHash) {
          throw new Error("idempotency-key reuse");
        }
        result = metadata.result;
        replayed = true;
        return;
      }
      const snapshot = await this.accountReconciliationSnapshot(planId, accountId, date);
      const prior = snapshot.currentReconciledBalance;
      const projected = snapshot.projectedReconciledBalance;
      if (projected !== statementBalance) throw new ReconciliationMismatchError(prior, projected, statementBalance);
      const ids = snapshot.candidateIds;
      await this.db.query(
        `INSERT INTO account_reconciliation_assertions
          (command_id,plan_id,account_id,statement_date,prior_reconciled_balance_milli,projected_reconciled_balance_milli,candidate_ids_json)
         VALUES (?,?,?,?,?,?,?)`,
      ).run(auditId, planId, accountId, date, prior, projected, JSON.stringify(ids));
      await this.db.query(
        "UPDATE transactions SET cleared='reconciled',updated_at=CURRENT_TIMESTAMP WHERE plan_id=? AND account_id=? AND deleted=0 AND cleared='cleared' AND date<=?",
      ).run(planId, accountId, date);
      await this.recalculateAccount(accountId);
      await this.db.query("UPDATE plans SET server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?").run(planId);
      for (const id of ids) {
        await this.db.query(
          "UPDATE transactions SET server_knowledge=(SELECT server_knowledge FROM plans WHERE id=?),updated_at=CURRENT_TIMESTAMP WHERE id=? AND plan_id=?",
        ).run(planId, id, planId);
      }
      result = {
        reconciled_transaction_ids: ids,
        reconciled_transaction_count: ids.length,
        statement_date: date,
        statement_balance: statementBalance,
        prior_reconciled_balance: prior,
        final_reconciled_balance: projected,
      };
      await this.db.query(
        "INSERT INTO audit_events(id,plan_id,action,resource_type,resource_id,source,metadata_json) VALUES (?,?,'account.reconcile','account',?,'howmuch-local',?)",
      ).run(auditId, planId, accountId, JSON.stringify({ request_hash: requestHash, result }));
    })();

    const completedResult = result as Omit<AccountReconciliationResult, "account" | "replayed" | "server_knowledge"> | null;
    if (!completedResult) throw new Error("Reconciliation result is missing");
    const reconciledAccount = await this.findAccount(planId, accountId);
    if (!reconciledAccount) throw new NotFoundError("Account not found");
    return {
      ...completedResult,
      account: reconciledAccount,
      replayed,
      server_knowledge: await this.getServerKnowledge(planId),
    };
  }

  private async accountReconciliationSnapshot(planId: string, accountId: string, statementDate: string): Promise<AccountReconciliationSnapshot> {
    const account = await this.db.query(`${ACCOUNT_SELECT_SQL} WHERE id=? AND plan_id=? AND deleted=0`).get(accountId, planId) as Row | null;
    if (!account) throw new NotFoundError("Account not found");
    const balances = await this.db.query(
      `SELECT
         ? + COALESCE(SUM(CASE WHEN deleted=0 AND cleared='reconciled' THEN amount_milli ELSE 0 END),0) current_reconciled,
         ? + COALESCE(SUM(CASE WHEN deleted=0 AND (cleared='reconciled' OR (cleared='cleared' AND date<=?)) THEN amount_milli ELSE 0 END),0) projected_reconciled
       FROM transactions WHERE plan_id=? AND account_id=?`,
    ).get(account.opening_balance_milli, account.opening_balance_milli, statementDate, planId, accountId) as Row;
    const candidates = await this.db.query(
      "SELECT id FROM transactions WHERE plan_id=? AND account_id=? AND deleted=0 AND cleared='cleared' AND date<=? ORDER BY id",
    ).all(planId, accountId, statementDate) as Row[];
    return {
      account,
      currentReconciledBalance: Number(balances.current_reconciled),
      projectedReconciledBalance: Number(balances.projected_reconciled),
      candidateIds: candidates.map((row) => String(row.id)),
    };
  }

  async createPayee(planId: string, name: string, id = createId("payee")): Promise<any> {
    await this.ensurePlan(planId);
    const existing = await this.db
      .query("SELECT * FROM payees WHERE plan_id = ? AND lower(name) = lower(?) AND deleted = 0")
      .get(planId, name) as Row | null;

    if (existing) {
      return formatPayee(existing);
    }

    await this.db
      .query("INSERT INTO payees (id, plan_id, name, external_ynab_id) VALUES (?, ?, ?, ?)")
      .run(id, planId, name, id);
    await this.touchPlan(planId);
    return formatPayee(await this.db.query("SELECT * FROM payees WHERE id = ?").get(id) as Row);
  }

  async ensurePayee(planId: string, payeeId: string, name?: string): Promise<void> {
    await this.ensurePlan(planId);
    await this.db
      .query(
        `INSERT INTO payees (id, plan_id, name, external_ynab_id)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(payeeId, planId, name ?? `Imported payee ${payeeId.slice(0, 8)}`, payeeId);
  }

  async upsertPayee(planId: string, payee: any): Promise<void> {
    await this.ensurePlan(planId);
    await this.db
      .query(
        `INSERT INTO payees (id, plan_id, name, transfer_account_id, external_ynab_id, deleted, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
         ON CONFLICT(id) DO UPDATE SET
           name = excluded.name,
           transfer_account_id = excluded.transfer_account_id,
           external_ynab_id = excluded.external_ynab_id,
           deleted = excluded.deleted,
           updated_at = CURRENT_TIMESTAMP`,
      )
      .run(
        payee.id,
        planId,
        payee.name ?? `Payee ${payee.id}`,
        payee.transfer_account_id ?? null,
        payee.external_ynab_id ?? payee.id,
        bool(payee.deleted),
      );
    // Same reason as `upsertAccount`: a renamed or deleted payee must not be
    // servable from a client cache that thinks knowledge has not moved.
    await this.touchPlan(planId);
  }

  async listPayees(planId: string): Promise<any[]> {
    return (await this.db.query(LIST_PAYEES_SQL).all(planId)).map(formatPayee);
  }

  /** Payees and the knowledge value that labels them, in one round trip. */
  async listPayeesWithKnowledge(planId: string): Promise<{ payees: any[]; server_knowledge: number }> {
    const [rows, knowledgeRows] = await this.db.batchRead([
      { sql: LIST_PAYEES_SQL, values: [planId] },
      { sql: SERVER_KNOWLEDGE_SQL, values: [planId] },
    ]);
    return { payees: (rows ?? []).map(formatPayee), server_knowledge: knowledgeFrom(knowledgeRows) };
  }

  async ensureCategory(planId: string, categoryId: string, name?: string, groupId?: string | null): Promise<void> {
    await this.ensurePlan(planId);

    // Transaction reference resolution commonly reaches an imported category
    // without its group ID.  Do not manufacture the fallback group before
    // discovering that the category is already present.
    const existing = await this.db
      .query("SELECT plan_id FROM categories WHERE id = ?")
      .get(categoryId) as Row | null;
    if (existing) {
      if (existing.plan_id !== planId) throw new ValidationError("Category belongs to a different plan");
      return;
    }

    const resolvedGroupId = groupId ?? "uncategorized-group";
    await this.db
      .query(
        `INSERT INTO category_groups (id, plan_id, name)
         VALUES (?, ?, ?)
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(resolvedGroupId, planId, resolvedGroupId === "uncategorized-group" ? "Uncategorised" : "Imported");

    await this.db
      .query(
        `INSERT INTO categories (id, plan_id, category_group_id, name, external_ynab_id)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(categoryId, planId, resolvedGroupId, name ?? `Imported category ${categoryId.slice(0, 8)}`, categoryId);
  }

  async upsertCategoryGroup(planId: string, group: any): Promise<void> {
    await this.ensurePlan(planId);
    await this.db
      .query(
        `INSERT INTO category_groups (id, plan_id, name, hidden, internal, external_ynab_id, deleted, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
         ON CONFLICT(id) DO UPDATE SET
           name = excluded.name,
           hidden = excluded.hidden,
           internal = excluded.internal,
           external_ynab_id = excluded.external_ynab_id,
           deleted = excluded.deleted,
           updated_at = CURRENT_TIMESTAMP`,
      )
      .run(
        group.id,
        planId,
        group.name ?? `Group ${group.id}`,
        bool(group.hidden),
        bool(group.internal),
        group.external_ynab_id ?? group.id,
        bool(group.deleted),
      );
  }

  async upsertCategory(planId: string, category: any, groupId?: string | null): Promise<void> {
    await this.ensureCategory(planId, category.id, category.name, groupId);
    await this.db
      .query(
        `UPDATE categories
         SET name = ?, category_group_id = ?, hidden = ?, internal = ?, external_ynab_id = ?, deleted = ?, updated_at = CURRENT_TIMESTAMP
         WHERE id = ? AND plan_id = ?`,
      )
      .run(
        category.name ?? `Category ${category.id}`,
        groupId ?? null,
        bool(category.hidden),
        bool(category.internal),
        category.external_ynab_id ?? category.id,
        bool(category.deleted),
        category.id,
        planId,
      );
  }

  async listCategoryGroups(planId: string): Promise<any[]> {
    const [groups, categories] = await Promise.all([
      this.db.query(LIST_CATEGORY_GROUPS_SQL).all(planId) as Promise<Row[]>,
      this.db.query(LIST_CATEGORIES_SQL).all(planId) as Promise<Row[]>,
    ]);
    return assembleCategoryGroups(groups, categories);
  }

  /** Groups, their categories and the knowledge value, in one round trip. */
  async listCategoryGroupsWithKnowledge(planId: string): Promise<{ category_groups: any[]; server_knowledge: number }> {
    const [groups, categories, knowledgeRows] = await this.db.batchRead([
      { sql: LIST_CATEGORY_GROUPS_SQL, values: [planId] },
      { sql: LIST_CATEGORIES_SQL, values: [planId] },
      { sql: SERVER_KNOWLEDGE_SQL, values: [planId] },
    ]);
    return {
      category_groups: assembleCategoryGroups(groups ?? [], categories ?? []),
      server_knowledge: knowledgeFrom(knowledgeRows),
    };
  }

  /** Plan-level gate: a native plan has no YNAB `month` raw object at all. */
  async isNativePlan(planId: string): Promise<boolean> {
    return !(await this.db.query(YNAB_MONTH_PRESENT_SQL).get(planId));
  }

  protected async requireNativePlan(planId: string): Promise<void> {
    if (!(await this.isNativePlan(planId))) throw new YnabMirrorPlanError();
  }

  async createCategoryGroup(planId: string, input: CategoryGroupCreate, options: CategoryWriteOptions = {}): Promise<any> {
    const id = input.id ?? derivedEntityId("category_group", planId, options.operationId);
    return this.applyCategoryCommand(planId, "category_group.create", id, input, options,
      () => this.planCreateCategoryGroup(planId, id, input), () => this.readCategoryGroupResponse(planId, id));
  }

  async updateCategoryGroup(planId: string, groupId: string, patch: CategoryGroupPatch, options: CategoryWriteOptions = {}): Promise<any> {
    return this.applyCategoryCommand(planId, "category_group.update", groupId, patch, options,
      () => this.planUpdateCategoryGroup(planId, groupId, patch), () => this.readCategoryGroupResponse(planId, groupId));
  }

  async createCategory(planId: string, input: CategoryCreate, options: CategoryWriteOptions = {}): Promise<any> {
    const id = input.id ?? derivedEntityId("category", planId, options.operationId);
    return this.applyCategoryCommand(planId, "category.create", id, input, options,
      () => this.planCreateCategory(planId, id, input), () => this.readCategoryResponse(planId, id));
  }

  async updateCategory(planId: string, categoryId: string, patch: CategoryPatch, options: CategoryWriteOptions = {}): Promise<any> {
    return this.applyCategoryCommand(planId, "category.update", categoryId, patch, options,
      () => this.planUpdateCategory(planId, categoryId, patch), () => this.readCategoryResponse(planId, categoryId));
  }

  /** Soft delete, refused while any live transaction or schedule names the category. */
  async deleteCategory(planId: string, categoryId: string, options: CategoryWriteOptions = {}): Promise<any> {
    return this.applyCategoryCommand(planId, "category.delete", categoryId, {}, options,
      () => this.planDeleteCategory(planId, categoryId), () => this.readCategoryResponse(planId, categoryId));
  }

  /**
   * SQLite runner: replay check, planning reads and the write share one
   * BEGIN IMMEDIATE, so the checks cannot go stale before the write lands.
   */
  protected async applyCategoryCommand(
    planId: string,
    action: CategoryCommand["action"],
    resourceId: string,
    request: unknown,
    options: CategoryWriteOptions,
    plan: () => Promise<CategoryCommand>,
    read: () => Promise<any>,
  ): Promise<any> {
    const hash = categoryRequestHash(action, planId, resourceId, request);
    return this.db.transaction(async () => {
      if (await this.replayedScheduleMutation(planId, resourceId, action, options.operationId, hash)) return read();
      const command = await plan();
      const auditId = options.operationId ? `audit_${scheduleDigest(options.operationId).slice(0, 24)}` : createId("audit");
      for (const planned of categoryCommandStatements(command, planId, auditId, hash)) {
        await this.db.query(planned.sql).run(...planned.values);
      }
      return read();
    })();
  }

  protected async planCreateCategoryGroup(planId: string, id: string, input: CategoryGroupCreate): Promise<CategoryCommand> {
    await this.requireNativePlan(planId);
    if (await this.db.query("SELECT 1 FROM category_groups WHERE id = ?").get(id)) {
      throw new EntityConflictError("Category group already exists");
    }
    return createCategoryGroupCommand(planId, id, input);
  }

  protected async planUpdateCategoryGroup(planId: string, groupId: string, patch: CategoryGroupPatch): Promise<CategoryCommand> {
    await this.requireNativePlan(planId);
    const current = await this.liveCategoryGroupRow(planId, groupId);
    if (!current) throw new NotFoundError("Category group not found");
    return updateCategoryGroupCommand(planId, current, patch);
  }

  protected async planCreateCategory(planId: string, id: string, input: CategoryCreate): Promise<CategoryCommand> {
    await this.requireNativePlan(planId);
    const group = await this.liveCategoryGroupRow(planId, input.category_group_id);
    if (!group) throw new ValidationError("Category group not found");
    if (await this.db.query("SELECT 1 FROM categories WHERE id = ?").get(id)) {
      throw new EntityConflictError("Category already exists");
    }
    return createCategoryCommand(planId, id, input, group);
  }

  protected async planUpdateCategory(planId: string, categoryId: string, patch: CategoryPatch): Promise<CategoryCommand> {
    await this.requireNativePlan(planId);
    const current = await this.db.query("SELECT * FROM categories WHERE id = ? AND plan_id = ? AND deleted = 0").get(categoryId, planId) as CategoryRow | null;
    if (!current) throw new NotFoundError("Category not found");
    const targetGroup = patch.category_group_id === undefined ? null : await this.liveCategoryGroupRow(planId, patch.category_group_id);
    if (patch.category_group_id !== undefined && !targetGroup) throw new ValidationError("Category group not found");
    return updateCategoryCommand(planId, current, patch, targetGroup);
  }

  protected async planDeleteCategory(planId: string, categoryId: string): Promise<CategoryCommand> {
    await this.requireNativePlan(planId);
    const current = await this.db.query("SELECT * FROM categories WHERE id = ? AND plan_id = ? AND deleted = 0").get(categoryId, planId) as CategoryRow | null;
    if (!current) throw new NotFoundError("Category not found");
    const inUse = await this.db.query(`SELECT ${CATEGORY_IN_USE_CONDITION} AS in_use`).get(...categoryInUseValues(planId, categoryId)) as Row | null;
    if (toBoolean(inUse?.in_use)) throw new CategoryInUseError();
    return deleteCategoryCommand(planId, current);
  }

  private async liveCategoryGroupRow(planId: string, groupId: string): Promise<CategoryGroupRow | null> {
    return await this.db.query("SELECT * FROM category_groups WHERE id = ? AND plan_id = ? AND deleted = 0").get(groupId, planId) as CategoryGroupRow | null;
  }

  protected async readCategoryGroupResponse(planId: string, groupId: string): Promise<any> {
    const [groups, categories] = await this.db.batchRead([
      { sql: "SELECT * FROM category_groups WHERE id = ? AND plan_id = ?", values: [groupId, planId] },
      { sql: "SELECT * FROM categories WHERE category_group_id = ? AND plan_id = ? AND deleted = 0 ORDER BY name", values: [groupId, planId] },
    ]);
    if (!groups?.length) throw new NotFoundError("Category group not found");
    return assembleCategoryGroups(groups, categories ?? [])[0];
  }

  protected async readCategoryResponse(planId: string, categoryId: string): Promise<any> {
    const row = await this.db.query("SELECT * FROM categories WHERE id = ? AND plan_id = ?").get(categoryId, planId) as Row | null;
    if (!row) throw new NotFoundError("Category not found");
    return formatCategory(row);
  }

  async createTransaction(planId: string, input: TransactionInput, options: TransactionWriteOptions = {}): Promise<any> {
    await this.ensurePlan(planId);
    const autoLink = options.autoLink ?? true;
    validateTransactionInput(input, autoLink);
    const transactionId = input.id ?? createId("txn");
    const requestHash = scheduleMutationFingerprint("transaction.create", planId, transactionId, { input, autoLink });
    const auditId = options.operationId ? `audit_txn_${scheduleDigest(options.operationId).slice(0, 20)}` : null;
    const plan = newTransactionMutationPlan();
    await this.db.transaction(async () => {
      if (auditId) {
        const receipt = await this.db.query("SELECT action,plan_id,resource_id,metadata_json FROM audit_events WHERE id=?").get(auditId) as Row | null;
        if (receipt) {
          const metadata = JSON.parse(String(receipt.metadata_json));
          if (receipt.action !== "transaction.create" || receipt.plan_id !== planId || receipt.resource_id !== transactionId || metadata.request_hash !== requestHash) {
            throw new Error("idempotency-key reuse");
          }
          return;
        }
        const collision = await this.db.query("SELECT 1 FROM transactions WHERE id=?").get(transactionId);
        if (collision) throw new ValidationError("Transaction already exists");
      }
      await this.executeTransactionWrite(planId, { ...input, id: transactionId }, autoLink, plan);
      await this.executeMutationPlan(planId, plan);
      if (auditId) {
        await this.db.query(
          "INSERT INTO audit_events(id,plan_id,action,resource_type,resource_id,source,metadata_json) VALUES (?,?,'transaction.create','transaction',?,'scheduled-materializer',?)",
        ).run(auditId, planId, transactionId, JSON.stringify({ request_hash: requestHash, operation_id: options.operationId }));
      }
    })();
    return this.getTransaction(planId, transactionId, bool(input.deleted) === 1);
  }

  /** Executes the transaction graph body inside the caller's single transaction. */
  private async executeTransactionWrite(
    planId: string,
    input: TransactionInput,
    autoLink: boolean,
    plan: TransactionMutationPlan,
  ): Promise<void> {
      const transactionId = input.id!;
      await this.ensureAccount(planId, input.account_id);
      // The upsert path must respect what the row already carries, or a
      // retried create would mint a second linked side and strand the first.
      const existingRow = await this.db
        .query("SELECT * FROM transactions WHERE id = ? AND plan_id = ?")
        .get(transactionId, planId) as Row | null;
      const refs = await this.resolveTransactionRefs(planId, input);

      let payeeId = refs.payeeId;
      let payeeName = refs.payeeName;
      let categoryId = refs.categoryId;
      let categoryName = refs.categoryName;
      let transferAccountId = input.transfer_account_id ?? null;
      const transferTransactionId =
        input.transfer_transaction_id !== undefined
          ? input.transfer_transaction_id
          : (existingRow?.transfer_transaction_id ?? null);
      if (transferTransactionId && !transferAccountId) {
        transferAccountId = existingRow?.transfer_account_id ?? null;
      }

      // A payee that points at another account marks a transfer. The linked
      // side is created below once this row exists; rows that already carry a
      // link keep it, and an unchanged payee on an unlinked row (one-sided
      // imports) must not start minting mirrors on unrelated edits.
      let createLinkedSide = false;
      let linkedCleared: ClearedState = "uncleared";
      if (autoLink && !transferTransactionId) {
        const targetAccountId = (payeeId ? await this.payeeTransferTarget(planId, payeeId) : null) ?? transferAccountId;
        const payeeUnchanged = existingRow != null && existingRow.payee_id === payeeId;
        if (targetAccountId && !payeeUnchanged) {
          if (input.subtransactions?.length) {
            throw new ValidationError(
              "A split transaction cannot itself be a transfer; use a transfer subtransaction instead",
            );
          }
          const target = await this.requireTransferTarget(planId, input.account_id, targetAccountId);
          transferAccountId = target.id;
          if (input.source_kind === "scheduled-transaction" && target.type === "cash") linkedCleared = "cleared";
          const targetPayee = await this.ensureTransferPayee(planId, target.id);
          if (targetPayee) {
            payeeId = targetPayee.id;
            payeeName = targetPayee.name;
          }
          createLinkedSide = true;
        }
      }
      if (autoLink && transferAccountId && await this.accountsBothOnBudget(planId, input.account_id, transferAccountId)) {
        // Transfers between two budget accounts carry no category in YNAB;
        // only transfers to tracking accounts count as categorised spending.
        categoryId = null;
        categoryName = null;
      }
      if (input.subtransactions?.length) {
        // Split parents carry no category of their own.
        categoryId = null;
        categoryName = null;
      }

      await this.db
        .query(
          `INSERT INTO transactions (
             id, plan_id, account_id, date, amount_milli, memo, cleared, approved,
             flag_color, flag_name, payee_id, payee_name_snapshot, category_id,
             category_name_snapshot, transfer_account_id, transfer_transaction_id,
             matched_transaction_id, import_id, import_payee_name, import_payee_name_original,
             source_kind, source_ref, external_ynab_id, deleted, updated_at
           )
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
           ON CONFLICT(id) DO UPDATE SET
             account_id = excluded.account_id,
             date = excluded.date,
             amount_milli = excluded.amount_milli,
             memo = excluded.memo,
             cleared = excluded.cleared,
             approved = excluded.approved,
             flag_color = excluded.flag_color,
             flag_name = excluded.flag_name,
             payee_id = excluded.payee_id,
             payee_name_snapshot = excluded.payee_name_snapshot,
             category_id = excluded.category_id,
             category_name_snapshot = excluded.category_name_snapshot,
             transfer_account_id = excluded.transfer_account_id,
             transfer_transaction_id = excluded.transfer_transaction_id,
             matched_transaction_id = excluded.matched_transaction_id,
             import_id = excluded.import_id,
             import_payee_name = excluded.import_payee_name,
             import_payee_name_original = excluded.import_payee_name_original,
             source_kind = excluded.source_kind,
             source_ref = excluded.source_ref,
             external_ynab_id = excluded.external_ynab_id,
             deleted = excluded.deleted,
             updated_at = CURRENT_TIMESTAMP`,
        )
        .run(
          transactionId,
          planId,
          input.account_id,
          input.date,
          input.amount,
          input.memo ?? null,
          input.cleared ?? "uncleared",
          bool(input.approved),
          input.flag_color ?? null,
          input.flag_name ?? null,
          payeeId,
          payeeName,
          categoryId,
          categoryName,
          transferAccountId,
          transferTransactionId,
          input.matched_transaction_id ?? null,
          input.import_id ?? null,
          input.import_payee_name ?? null,
          input.import_payee_name_original ?? null,
          input.source_kind ?? null,
          input.source_ref ?? null,
          input.external_ynab_id ?? input.id ?? null,
          bool(input.deleted),
        );

      const previousSubs = await this.db
        .query("SELECT id, transfer_transaction_id FROM subtransactions WHERE transaction_id = ?")
        .all(transactionId) as Row[];
      await this.db.query("DELETE FROM subtransactions WHERE transaction_id = ?").run(transactionId);
      const keptSubIds = new Set<string>();
      const keptLinkIds = new Set<string>();
      for (const sub of input.subtransactions ?? []) {
        const subId = sub.id ?? createId("sub");
        keptSubIds.add(subId);
        const subRefs = await this.resolveTransactionRefs(planId, {
          account_id: input.account_id,
          date: input.date,
          amount: sub.amount,
          payee_id: sub.payee_id,
          payee_name: sub.payee_name,
          category_id: sub.category_id,
          memo: sub.memo,
        });

        let subPayeeId = subRefs.payeeId;
        let subPayeeName = subRefs.payeeName;
        let subCategoryId = subRefs.categoryId;
        let subCategoryName = subRefs.categoryName;
        let subTransferAccountId = sub.transfer_account_id ?? null;
        let subTransferTransactionId = sub.transfer_transaction_id ?? null;

        if (autoLink && subTransferTransactionId) {
          if (subTransferAccountId === input.account_id) {
            throw new ValidationError("Transfer target must be a different account");
          }
          // The split line already owns a linked side: keep it in step.
          await this.syncLinkedTransaction(planId, subTransferTransactionId, {
            date: input.date,
            amount: -sub.amount,
            memo: sub.memo ?? null,
            approved: input.approved,
            sourceAccountId: input.account_id,
            accountId: subTransferAccountId ?? undefined,
          }, plan);
        } else if (autoLink) {
          const targetAccountId =
            (subPayeeId ? await this.payeeTransferTarget(planId, subPayeeId) : null) ?? subTransferAccountId;
          if (targetAccountId) {
            const target = await this.requireTransferTarget(planId, input.account_id, targetAccountId);
            subTransferAccountId = target.id;
            const targetPayee = await this.ensureTransferPayee(planId, target.id);
            if (targetPayee) {
              subPayeeId = targetPayee.id;
              subPayeeName = targetPayee.name;
            }
            if (await this.accountsBothOnBudget(planId, input.account_id, target.id)) {
              subCategoryId = null;
              subCategoryName = null;
            }
            subTransferTransactionId = await this.insertLinkedTransaction(planId, {
              accountId: target.id,
              date: input.date,
              amount: -sub.amount,
              memo: sub.memo ?? null,
              approved: input.approved,
              sourceAccountId: input.account_id,
              linkId: subId,
              cleared: input.source_kind === "scheduled-transaction" && target.type === "cash" ? "cleared" : "uncleared",
            }, plan);
          }
        }

        if (subTransferTransactionId) {
          keptLinkIds.add(subTransferTransactionId);
        }

        await this.db
          .query(
            `INSERT INTO subtransactions (
               id, transaction_id, amount_milli, memo, payee_id, payee_name_snapshot,
               category_id, category_name_snapshot, transfer_account_id,
               transfer_transaction_id, external_ynab_id, deleted, updated_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, CURRENT_TIMESTAMP)`,
          )
          .run(
            subId,
            transactionId,
            sub.amount,
            sub.memo ?? null,
            subPayeeId,
            subPayeeName,
            subCategoryId,
            subCategoryName,
            subTransferAccountId,
            subTransferTransactionId,
            sub.external_ynab_id ?? sub.id ?? null,
          );
      }

      // Split lines that disappeared take their linked sides with them — but
      // a line that was merely re-keyed keeps the linked side it still cites.
      for (const previous of previousSubs) {
        if (
          !keptSubIds.has(previous.id) &&
          previous.transfer_transaction_id &&
          !keptLinkIds.has(previous.transfer_transaction_id)
        ) {
          await this.softDeleteLinkedTransaction(planId, previous.transfer_transaction_id, plan);
        }
      }

      if (input.source_kind || input.source_ref) {
        await this.db
          .query(
            `INSERT INTO source_events (id, plan_id, transaction_id, source_kind, source_ref, payload_json)
             VALUES (?, ?, ?, ?, ?, ?)`,
          )
          .run(createId("src"), planId, transactionId, input.source_kind ?? "api", input.source_ref ?? null, JSON.stringify(input));
      }

      if (createLinkedSide && transferAccountId) {
        const linkedId = await this.insertLinkedTransaction(planId, {
          accountId: transferAccountId,
          date: input.date,
          amount: -input.amount,
          memo: input.memo ?? null,
          approved: input.approved,
          sourceAccountId: input.account_id,
          linkId: transactionId,
          cleared: linkedCleared,
        }, plan);
        await this.db
          .query("UPDATE transactions SET transfer_transaction_id = ? WHERE id = ?")
          .run(linkedId, transactionId);
      } else if (autoLink && transferTransactionId && !input.subtransactions?.length) {
        // A re-created or edited row that already owns a linked side keeps
        // that side in step instead of minting a new one.
        await this.syncLinkedTransaction(planId, transferTransactionId, {
          date: input.date,
          amount: -input.amount,
          memo: input.memo ?? null,
          approved: input.approved,
          sourceAccountId: input.account_id,
          accountId: transferAccountId ?? undefined,
        }, plan);
      }

      plan.accountIdsToRecalculate.add(input.account_id);
      if (existingRow && existingRow.account_id !== input.account_id) {
        plan.accountIdsToRecalculate.add(existingRow.account_id);
      }
      plan.touchedTransactionIds.add(transactionId);
  }

  async updateTransaction(planId: string, transactionId: string, patch: Partial<TransactionInput>): Promise<any> {
    await this.applyTransactionUpdate(planId, transactionId, patch);
    return this.getTransaction(planId, transactionId);
  }

  /**
   * The write half of a transaction update, without the response hydration.
   * Storage engines that can return the committed row themselves override this
   * so bulk callers do not pay a discarded per-item read.
   */
  protected async applyTransactionUpdate(planId: string, transactionId: string, patch: Partial<TransactionInput>): Promise<void> {
    const plan = newTransactionMutationPlan();
    if (patch.approved !== undefined && Object.keys(patch).length === 1) {
      let linkedSplit = false;
      await this.db.transaction(async () => {
        linkedSplit = await this.applyLinkedSplitApproval(planId, transactionId, patch.approved ?? false, plan);
        if (linkedSplit) await this.executeMutationPlan(planId, plan);
      })();
      if (linkedSplit) {
        return;
      }
    }
    await this.db.transaction(async () => {
      const prepared = await this.prepareTransactionUpdate(planId, transactionId, patch);
      await this.applyResolvedPatch(planId, prepared.existing, prepared.next, patch, plan);
      await this.executeMutationPlan(planId, plan);
    })();
  }

  async updateTransactionCleared(
    planId: string,
    transactionId: string,
    expectedCleared: "uncleared" | "cleared",
    cleared: "uncleared" | "cleared",
  ): Promise<any> {
    await this.applyTransactionCleared(planId, transactionId, expectedCleared, cleared);
    return this.getTransaction(planId, transactionId);
  }

  /** Write half of the dedicated cleared toggle; see `applyTransactionUpdate`. */
  protected async applyTransactionCleared(
    planId: string,
    transactionId: string,
    expectedCleared: "uncleared" | "cleared",
    cleared: "uncleared" | "cleared",
  ): Promise<void> {
    const plan = newTransactionMutationPlan();
    await this.db.transaction(async () => {
      const existing = await this.getTransactionRow(planId, transactionId);
      if (!existing) throw new NotFoundError("Transaction not found");
      if (existing.cleared !== expectedCleared) throw new TransactionStateConflictError();
      await this.db.query(
        "UPDATE transactions SET cleared=?,updated_at=CURRENT_TIMESTAMP WHERE id=? AND plan_id=? AND deleted=0 AND cleared=?",
      ).run(cleared, transactionId, planId, expectedCleared);
      plan.accountIdsToRecalculate.add(String(existing.account_id));
      plan.touchedTransactionIds.add(transactionId);
      await this.executeMutationPlan(planId, plan);
    })();
  }

  /**
   * Bounded bulk cleared. Each row keeps the dedicated single-item compare-and-set,
   * including the split/transfer side handling. Expected conflicts are per-item
   * outcomes and the loop continues; an ambiguous failure stops the command and
   * leaves the remaining rows unattempted rather than replaying them.
   */
  async updateTransactionsCleared(planId: string, items: TransactionClearedItem[]): Promise<TransactionBulkResult> {
    const { outcomes, serverKnowledge } = await this.runBulk(planId, items, (item) =>
      this.applyTransactionCleared(planId, item.id, item.expected_cleared, item.cleared));
    return this.summariseBulk(outcomes, serverKnowledge);
  }

  /**
   * Bounded bulk delete. Each row keeps the single-item optional
   * `expected_approved` guard and the transfer/split cascade.
   *
   * A row that is already gone is reported as `already_removed` and nothing
   * more. This command cannot prove it removed a row it never committed — the
   * transfer pair it cascaded to, an external deletion, and a row that never
   * existed all look the same from here — so it never claims that attribution
   * and never counts it as its own work. An earlier conflict that a later
   * sibling delete happens to cascade over stays a `conflict`: that item's own
   * command was rejected, and a sound cascade report would need the owning
   * command to return the ids it actually committed.
   */
  async deleteTransactions(planId: string, items: TransactionDeleteItem[]): Promise<TransactionBulkResult> {
    const { outcomes, serverKnowledge } = await this.runBulk(
      planId,
      items,
      (item) => this.applyTransactionDelete(planId, item.id, item.expected_approved),
    );
    return this.summariseBulk(outcomes, serverKnowledge);
  }

  private async runBulk<Item extends { id: string }>(
    planId: string,
    items: readonly Item[],
    apply: (item: Item) => Promise<void>,
  ): Promise<{ outcomes: TransactionBulkOutcome[]; serverKnowledge: number }> {
    const outcomes: TransactionBulkOutcome[] = [];
    let stopped = false;
    for (const item of items) {
      if (stopped) {
        outcomes.push({ id: item.id, status: "unattempted" });
        continue;
      }
      try {
        await apply(item);
        outcomes.push({ id: item.id, status: "applied" });
      } catch (error) {
        if (error instanceof TransactionStateConflictError) {
          outcomes.push({ id: item.id, status: "conflict", detail: error.message });
          continue;
        }
        if (error instanceof NotFoundError) {
          outcomes.push({ id: item.id, status: "already_removed", detail: error.message });
          continue;
        }
        // Anything else may carry infrastructure detail (SQL, binding values,
        // driver text). The HTTP layer deliberately keeps those out of the
        // response body and logs them instead; a 200 bulk body must not leak
        // what a 500 would redact.
        outcomes.push({ id: item.id, status: "unresolved", detail: BULK_UNRESOLVED_DETAIL });
        stopped = true;
      }
    }
    return { outcomes, serverKnowledge: await this.getServerKnowledge(planId) };
  }

  private summariseBulk(outcomes: TransactionBulkOutcome[], serverKnowledge: number): TransactionBulkResult {
    const count = (status: TransactionBulkStatus) => outcomes.filter((outcome) => outcome.status === status).length;
    return {
      outcomes,
      applied_count: count("applied"),
      conflict_count: count("conflict"),
      already_removed_count: count("already_removed"),
      unresolved_count: count("unresolved"),
      unattempted_count: count("unattempted"),
      server_knowledge: serverKnowledge,
    };
  }

  async updateTransactions(planId: string, edits: TransactionBatchUpdate[]): Promise<TransactionBatchResult> {
    const resolved: Array<{ id: string; patch: Partial<TransactionInput> }> = [];
    const seen = new Set<string>();
    for (const edit of edits) {
      const id = await this.resolveTransactionLookup(planId, edit.lookup);
      if (seen.has(id)) throw new ValidationError("Duplicate transaction in batch");
      seen.add(id);
      resolved.push({ id, patch: edit.patch });
    }
    const plan = newTransactionMutationPlan();
    await this.db.transaction(async () => {
      for (const item of resolved) {
        if (
          item.patch.approved !== undefined &&
          Object.keys(item.patch).length === 1 &&
          await this.applyLinkedSplitApproval(planId, item.id, item.patch.approved ?? false, plan)
        ) {
          continue;
        }
        const prepared = await this.prepareTransactionUpdate(planId, item.id, item.patch);
        await this.applyResolvedPatch(planId, prepared.existing, prepared.next, item.patch, plan);
      }
      await this.executeMutationPlan(planId, plan);
    })();
    return this.loadTransactionSaveResult(planId, resolved.map((item) => item.id), []);
  }

  private async applyLinkedSplitApproval(
    planId: string,
    transactionId: string,
    approved: boolean,
    plan: TransactionMutationPlan,
  ): Promise<boolean> {
    const linkedSub = await this.db
      .query(
        `SELECT s.transaction_id
         FROM transactions t
         JOIN subtransactions s ON s.id = t.transfer_transaction_id AND s.deleted = 0
         WHERE t.id = ? AND t.plan_id = ? AND t.deleted = 0`,
      )
      .get(transactionId, planId) as Row | null;
    if (!linkedSub) return false;
    const rows = await this.db
      .query(
        `SELECT id FROM transactions
         WHERE plan_id = ? AND deleted = 0 AND (
           id = ? OR id IN (
             SELECT transfer_transaction_id FROM subtransactions
             WHERE transaction_id = ? AND deleted = 0 AND transfer_transaction_id IS NOT NULL
           )
         )`,
      )
      .all(planId, linkedSub.transaction_id, linkedSub.transaction_id) as Row[];
    await this.db
      .query(
        `UPDATE transactions SET approved = ?, updated_at = CURRENT_TIMESTAMP
         WHERE plan_id = ? AND deleted = 0 AND (
           id = ? OR id IN (
             SELECT transfer_transaction_id FROM subtransactions
             WHERE transaction_id = ? AND deleted = 0 AND transfer_transaction_id IS NOT NULL
           )
         )`,
      )
      .run(bool(approved), planId, linkedSub.transaction_id, linkedSub.transaction_id);
    for (const row of rows) plan.touchedTransactionIds.add(row.id);
    return true;
  }

  async createTransactions(planId: string, inputs: TransactionInput[]): Promise<TransactionBatchResult> {
    const explicitIds = inputs.map((input) => input.id).filter((id): id is string => Boolean(id));
    if (new Set(explicitIds).size !== explicitIds.length) {
      throw new ValidationError("Duplicate transaction id in batch");
    }
    const transactionIds: string[] = [];
    const duplicateImportIds: string[] = [];
    const plan = newTransactionMutationPlan();
    await this.db.transaction(async () => {
      for (const input of inputs) {
        if (input.import_id && input.account_id) {
          const existing = await this.findTransactionByImportId(planId, input.import_id, input.account_id);
          if (existing) {
            duplicateImportIds.push(input.import_id);
            transactionIds.push(existing.id);
            continue;
          }
        }
        validateTransactionInput(input, true);
        const transactionId = input.id ?? createId("txn");
        await this.executeTransactionWrite(planId, { ...input, id: transactionId }, true, plan);
        transactionIds.push(transactionId);
      }
      await this.executeMutationPlan(planId, plan);
    })();
    return this.loadTransactionSaveResult(planId, transactionIds, duplicateImportIds);
  }

  async loadTransactionSaveResult(
    planId: string,
    transactionIds: string[],
    duplicateImportIds: string[],
  ): Promise<TransactionBatchResult> {
    const transactions = [];
    for (const id of transactionIds) {
      transactions.push(await this.getTransaction(planId, id, true));
    }
    return {
      transaction_ids: transactionIds,
      transactions,
      duplicate_import_ids: duplicateImportIds,
      server_knowledge: await this.getServerKnowledge(planId),
    };
  }

  protected async resolveTransactionLookup(planId: string, lookup: TransactionLookup): Promise<string> {
    if (lookup.kind === "id") {
      const row = await this.getTransactionRow(planId, lookup.id);
      if (!row) throw new NotFoundError("Transaction not found");
      return lookup.id;
    }
    const matches = await this.db
      .query("SELECT id FROM transactions WHERE plan_id = ? AND import_id = ? AND deleted = 0 ORDER BY id")
      .all(planId, lookup.importId) as Row[];
    if (matches.length === 0) throw new NotFoundError("Transaction not found");
    if (matches.length > 1) throw new ValidationError("import_id matches more than one transaction");
    return matches[0].id;
  }

  private async prepareTransactionUpdate(
    planId: string,
    transactionId: string,
    patch: Partial<TransactionInput>,
  ): Promise<{ existing: Row; next: TransactionInput }> {
    const existing = await this.getTransactionRow(planId, transactionId);
    if (!existing) {
      throw new NotFoundError("Transaction not found");
    }
    const existingTransaction = await this.getTransaction(planId, transactionId);

    if (existing.cleared === "reconciled" && patch.cleared !== undefined && patch.cleared !== "reconciled") {
      throw new TransactionStateConflictError("Reconciled transactions cannot be changed to another cleared state");
    }

    if (existing.transfer_transaction_id && !await this.getTransactionRow(planId, existing.transfer_transaction_id)) {
      const linkedSub = await this.db
        .query("SELECT id FROM subtransactions WHERE id = ? AND deleted = 0")
        .get(existing.transfer_transaction_id) as Row | null;
      if (linkedSub) {
        const lockedFields = ["amount", "date", "account_id", "payee_id", "subtransactions"].filter(
          (field) => (patch as Record<string, unknown>)[field] !== undefined,
        );
        if (lockedFields.length > 0) {
          throw new ValidationError(
            `This transaction is the linked side of a split line; edit the split to change ${lockedFields.join(", ")}`,
          );
        }
      }
    }

    const next: TransactionInput = {
      id: transactionId,
      account_id: patch.account_id ?? existing.account_id,
      date: patch.date ?? existing.date,
      amount: patch.amount ?? existing.amount_milli,
      payee_id: patch.payee_id === undefined ? existing.payee_id : patch.payee_id,
      payee_name: patch.payee_name === undefined ? existing.payee_name_snapshot : patch.payee_name,
      category_id: patch.category_id === undefined ? existing.category_id : patch.category_id,
      memo: patch.memo === undefined ? existing.memo : patch.memo,
      cleared: (patch.cleared === undefined ? existing.cleared : patch.cleared) as ClearedState,
      approved: patch.approved === undefined ? toBoolean(existing.approved) : patch.approved,
      flag_color: patch.flag_color === undefined ? existing.flag_color : patch.flag_color,
      flag_name: patch.flag_name === undefined ? existing.flag_name : patch.flag_name,
      transfer_account_id: patch.transfer_account_id === undefined ? existing.transfer_account_id : patch.transfer_account_id,
      transfer_transaction_id:
        patch.transfer_transaction_id === undefined ? existing.transfer_transaction_id : patch.transfer_transaction_id,
      matched_transaction_id:
        patch.matched_transaction_id === undefined ? existing.matched_transaction_id : patch.matched_transaction_id,
      import_id: existing.import_id,
      import_payee_name: patch.import_payee_name === undefined ? existing.import_payee_name : patch.import_payee_name,
      import_payee_name_original:
        patch.import_payee_name_original === undefined
          ? existing.import_payee_name_original
          : patch.import_payee_name_original,
      source_kind: patch.source_kind === undefined ? existing.source_kind : patch.source_kind,
      source_ref: patch.source_ref === undefined ? existing.source_ref : patch.source_ref,
      external_ynab_id: existing.external_ynab_id,
      subtransactions:
        patch.subtransactions === undefined
          ? existingTransaction.subtransactions.map((sub: any) => ({
              id: sub.id,
              amount: sub.amount,
              payee_id: sub.payee_id,
              payee_name: sub.payee_name,
              category_id: sub.category_id,
              memo: sub.memo,
              transfer_account_id: sub.transfer_account_id,
              transfer_transaction_id: sub.transfer_transaction_id,
            }))
          : patch.subtransactions,
    };

    validateTransactionInput(next, true);
    return { existing, next };
  }

  private async applyResolvedPatch(
    planId: string,
    existing: Row,
    next: TransactionInput,
    patch: Partial<TransactionInput>,
    plan: ReturnType<typeof newTransactionMutationPlan>,
  ): Promise<void> {
    const linkedRow = existing.transfer_transaction_id
      ? await this.getTransactionRow(planId, existing.transfer_transaction_id)
      : null;
    if (linkedRow && patch.payee_id !== undefined) {
      const nextTarget = patch.payee_id ? await this.payeeTransferTarget(planId, patch.payee_id) : null;
      if (!nextTarget || nextTarget === next.account_id) {
        await this.softDeleteLinkedTransaction(planId, linkedRow.id, plan);
        next.transfer_account_id = null;
        next.transfer_transaction_id = null;
      } else {
        next.transfer_account_id = nextTarget;
      }
    }

    await this.executeTransactionWrite(planId, next, true, plan);
    if (existing.account_id !== next.account_id) {
      plan.accountIdsToRecalculate.add(existing.account_id);
    }
  }

  async deleteTransaction(planId: string, transactionId: string, expectedApproved?: boolean): Promise<any> {
    await this.applyTransactionDelete(planId, transactionId, expectedApproved);
    return this.getTransaction(planId, transactionId, true);
  }

  /** Write half of the tombstone; see `applyTransactionUpdate`. */
  protected async applyTransactionDelete(planId: string, transactionId: string, expectedApproved?: boolean): Promise<void> {
    const plan = newTransactionMutationPlan();
    await this.db.transaction(async () => {
      const existing = await this.getTransactionRow(planId, transactionId);
      if (!existing) {
        throw new NotFoundError("Transaction not found");
      }
      if (expectedApproved !== undefined && Boolean(existing.approved) !== expectedApproved) {
        throw new TransactionStateConflictError("Transaction approval state changed");
      }

      const removeIds = new Set<string>([transactionId]);
      const accountIds = new Set<string>([existing.account_id]);

      // Deleting one side of a transfer deletes the other (YNAB behaviour)...
      if (existing.transfer_transaction_id) {
        const linked = await this.getTransactionRow(planId, existing.transfer_transaction_id);
        if (linked) {
          removeIds.add(linked.id);
          accountIds.add(linked.account_id);
        } else {
          // ...unless the link points at a split line on the other side:
          // that line stays and simply forgets the link.
          const sub = await this.db
            .query("SELECT id, transaction_id FROM subtransactions WHERE id = ?")
            .get(existing.transfer_transaction_id) as Row | null;
          if (sub) {
            await this.db
              .query(
                `UPDATE subtransactions
                 SET transfer_account_id = NULL, transfer_transaction_id = NULL, updated_at = CURRENT_TIMESTAMP
                 WHERE id = ?`,
              )
              .run(sub.id);
            plan.touchedTransactionIds.add(sub.transaction_id);
          }
        }
      }

      // Linked sides born from this row's own split lines go too.
      const subLinks = await this.db
        .query(
          "SELECT transfer_transaction_id FROM subtransactions WHERE transaction_id = ? AND deleted = 0 AND transfer_transaction_id IS NOT NULL",
        )
        .all(transactionId) as Row[];
      for (const link of subLinks) {
        const linked = await this.getTransactionRow(planId, link.transfer_transaction_id);
        if (linked) {
          removeIds.add(linked.id);
          accountIds.add(linked.account_id);
        }
      }

      for (const id of removeIds) {
        await this.db
          .query("UPDATE transactions SET deleted = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND plan_id = ?")
          .run(id, planId);
        plan.touchedTransactionIds.add(id);
      }
      for (const accountId of accountIds) {
        plan.accountIdsToRecalculate.add(accountId);
      }
      await this.executeMutationPlan(planId, plan);
    })();
  }

  async importTransactions(planId: string, inputs: TransactionInput[]): Promise<{
    transaction_ids: string[];
    duplicate_import_ids: string[];
    duplicate_transaction_ids: string[];
    server_knowledge: number;
  }> {
    const transactionIds: string[] = [];
    const duplicateImportIds = new Set<string>();
    const duplicateTransactionIds = new Set<string>();

    for (const input of inputs) {
      const duplicate = await this.findDuplicateTransaction(planId, input);
      if (duplicate) {
        if (input.import_id) {
          duplicateImportIds.add(input.import_id);
        }
        duplicateTransactionIds.add(duplicate.id);
        continue;
      }

      const created = await this.createTransaction(planId, input);
      transactionIds.push(created.id);
    }

    return {
      transaction_ids: transactionIds,
      duplicate_import_ids: [...duplicateImportIds],
      duplicate_transaction_ids: [...duplicateTransactionIds],
      server_knowledge: await this.getServerKnowledge(planId),
    };
  }

  async listTransactions(planId: string, filters: TransactionFilters = {}): Promise<any[]> {
    return (await this.queryTransactions(planId, filters)).transactions;
  }

  /**
   * Bounded, newest-first transaction page for HTTP clients. Keep the legacy
   * list method above for internal imports and callers that explicitly need a
   * complete local result.
   */
  async listTransactionsPage(planId: string, filters: TransactionFilters = {}): Promise<TransactionPage> {
    const limit = Math.min(
      Math.max(Math.floor(filters.limit ?? DEFAULT_TRANSACTION_PAGE_SIZE), 1),
      MAX_TRANSACTION_PAGE_SIZE,
    );
    const offset = Math.max(Math.floor(filters.offset ?? 0), 0);
    const built = await this.buildTransactionQuery(planId, filters, limit + 1, offset);
    if (!built.subtransactions) throw new Error("Paged transaction query must carry its subtransaction statement");

    // One round trip for the whole register page. D1 runs a batch as a single
    // transaction, so the knowledge value, the page and its split lines all
    // come from one snapshot: the page can never be labelled with a knowledge
    // value from a write it does not contain.
    const [knowledgeRows, rows, subtransactionRows] = await this.db.batchRead([
      { sql: SERVER_KNOWLEDGE_SQL, values: [planId] },
      { sql: built.sql, values: built.params },
      { sql: built.subtransactions.sql, values: built.subtransactions.params },
    ]);
    if (!knowledgeRows?.[0]) throw new PlanNotFoundError();

    const transactions = assembleTransactions(
      rows ?? [],
      subtransactionRows ?? [],
      (row, subtransactions) => this.formatTransactionRow(row, subtransactions),
    );
    const has_more = transactions.length > limit;
    return {
      transactions: has_more ? transactions.slice(0, limit) : transactions,
      has_more,
      next_offset: has_more ? offset + limit : null,
      server_knowledge: Number(knowledgeRows[0].server_knowledge),
    };
  }

  /**
   * Size of the unapproved queue, without its rows. The WHERE clause comes from
   * the same `transactionFilterClauses` the register page uses, so the badge can
   * never disagree with the queue the user then opens. Clients used to page the
   * whole queue just to render the "New" badge; this is the badge on its own.
   *
   * Counted in the same batch as the knowledge value, so the number and its
   * label come from one snapshot and one round trip. No covering index carries
   * `approved` today, so this still walks the plan's live rows -- but it walks
   * them once, server-side, instead of shipping every row to the client.
   */
  async countUnapprovedTransactions(planId: string, filters: TransactionFilters = {}): Promise<UnapprovedCount> {
    // `q` needs the plan's currency format, a round trip the count will not pay,
    // and `last_knowledge_of_server` would swap "live rows" for "rows changed
    // since", deleted ones included. Neither applies to a badge.
    const { clauses, params } = transactionFilterClauses(planId, {
      ...filters,
      type: "unapproved",
      q: null,
      lastKnowledgeOfServer: null,
    });
    const [knowledgeRows, countRows] = await this.db.batchRead([
      { sql: SERVER_KNOWLEDGE_SQL, values: [planId] },
      { sql: `SELECT COUNT(*) AS count FROM transactions t WHERE ${clauses.join(" AND ")}`, values: params },
    ]);
    if (!knowledgeRows?.[0]) throw new PlanNotFoundError();
    return {
      count: Number(countRows?.[0]?.count ?? 0),
      server_knowledge: Number(knowledgeRows[0].server_knowledge),
    };
  }

  private async queryTransactions(
    planId: string,
    filters: TransactionFilters,
    limit?: number,
    offset?: number,
  ): Promise<{ transactions: any[] }> {
    const built = await this.buildTransactionQuery(planId, filters, limit, offset);
    const rows = await this.db.query(built.sql).all(...built.params) as Row[];
    return { transactions: await this.formatTransactions(rows) };
  }

  /**
   * Builds the transaction list statement and, when the query is paged, a
   * matching statement for the split lines of exactly that page. The second
   * statement repeats the paged id subquery instead of binding the ids it
   * returns, so both can travel in one batch without a round trip in between
   * to learn the ids.
   */
  private async buildTransactionQuery(
    planId: string,
    filters: TransactionFilters,
    limit?: number,
    offset?: number,
  ): Promise<{ sql: string; params: any[]; subtransactions: { sql: string; params: any[] } | null }> {
    const { clauses, params } = transactionFilterClauses(planId, filters);
    let pageFrom = "FROM transactions t";
    if (filters.q) {
      const plan = await this.getPlan(planId);
      const query = parseRegisterQuery(filters.q, plan.currency_format);
      if (query) {
        const search = transactionSearchSql(query);
        clauses.push(search.sql);
        params.push(...search.params);
        pageFrom = `FROM transactions t
           JOIN accounts a ON a.id = t.account_id
           LEFT JOIN payees p ON p.id = t.payee_id
           LEFT JOIN categories c ON c.id = t.category_id`;
      }
    }

    const orderBy = "t.date DESC, t.created_at DESC, t.id DESC";
    const listed = `SELECT
           t.*,
           a.name AS account_name,
           p.name AS payee_name,
           c.name AS category_name,
           linked_sub.transaction_id AS parent_transaction_id
         FROM transactions t
         JOIN accounts a ON a.id = t.account_id
         LEFT JOIN payees p ON p.id = t.payee_id
         LEFT JOIN categories c ON c.id = t.category_id
         LEFT JOIN subtransactions linked_sub ON linked_sub.id = t.transfer_transaction_id AND linked_sub.deleted = 0`;

    if (limit == null) {
      return {
        sql: `${listed}
         WHERE ${clauses.join(" AND ")}
         ORDER BY ${orderBy}`,
        params,
        subtransactions: null,
      };
    }

    const pageIds = `SELECT t.id
           ${pageFrom}
           WHERE ${clauses.join(" AND ")}
           ORDER BY ${orderBy}
         LIMIT ? OFFSET ?`;
    const pageParams = [...params, limit, offset ?? 0];
    return {
      sql: `${listed}
         JOIN (
           ${pageIds}
         ) page ON page.id = t.id
         ORDER BY ${orderBy}`,
      params: pageParams,
      subtransactions: {
        sql: `${SUBTRANSACTION_SELECT_SQL}
           WHERE st.deleted = 0 AND st.transaction_id IN (
             ${pageIds}
           )
           ORDER BY st.transaction_id, st.created_at, st.id`,
        params: [...pageParams],
      },
    };
  }

  async getTransaction(planId: string, transactionId: string, includeDeleted = false): Promise<any> {
    const row = await this.getTransactionRow(planId, transactionId, includeDeleted);
    if (!row) {
      throw new NotFoundError("Transaction not found");
    }
    return this.formatTransaction(row);
  }

  async createImportSession(planId: string | null, source: string): Promise<string> {
    const id = createId("imp");
    if (planId) {
      await this.ensurePlan(planId);
    }
    await this.db
      .query("INSERT INTO import_sessions (id, plan_id, source) VALUES (?, ?, ?)")
      .run(id, planId, source);
    return id;
  }

  async finishImportSession(id: string, status: string, summary: unknown): Promise<void> {
    await this.db
      .query("UPDATE import_sessions SET status = ?, finished_at = CURRENT_TIMESTAMP, summary_json = ? WHERE id = ?")
      .run(status, JSON.stringify(summary), id);
  }

  /**
   * Stores an exact source object from YNAB.  The normalised ledger remains
   * the write model; this mirror keeps fields that HowMuch does not yet model
   * (targets, notes, scheduling metadata, locations, and future API fields).
   */
  async upsertYnabRawObject(
    planId: string,
    objectType: string,
    objectId: string,
    payload: unknown,
    serverKnowledge?: number,
  ): Promise<void> {
    await this.ensurePlan(planId);
    const json = JSON.stringify(payload);
    if (json === undefined) throw new ValidationError("YNAB raw object payload must be JSON serialisable");
    const deleted = Boolean((payload as Record<string, unknown> | null)?.deleted) ? 1 : 0;
    await this.db
      .query(
        `INSERT INTO ynab_raw_objects(plan_id, object_type, object_id, payload_json, deleted, server_knowledge, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
         ON CONFLICT(plan_id, object_type, object_id) DO UPDATE SET
           payload_json = excluded.payload_json,
           deleted = excluded.deleted,
           server_knowledge = excluded.server_knowledge,
           updated_at = CURRENT_TIMESTAMP`,
      )
      .run(planId, objectType, objectId, json, deleted, serverKnowledge ?? null);
  }

  async listYnabRawObjects(planId: string, objectType: string): Promise<any[]> {
    const rows = await this.db
      .query("SELECT payload_json FROM ynab_raw_objects WHERE plan_id = ? AND object_type = ? ORDER BY object_id")
      .all(planId, objectType) as Row[];
    return rows.map((row) => parseRawYnabObject(row.payload_json, objectType));
  }

  /** Effective schedules: immutable YNAB rows plus HowMuch-owned overlays. */
  async listScheduledTransactions(planId: string): Promise<any[]> {
    const rows = await Promise.all(SCHEDULED_SQL.map((sql) => this.db.query(sql).all(planId) as Promise<Row[]>));
    return assembleScheduledTransactions(rows[0]!, rows[1]!, rows[2]!, rows[3]!);
  }

  /**
   * Schedules and the knowledge value in one round trip, for the HTTP route.
   * The method above keeps its four separate statements because write paths
   * call it from inside an open transaction, where a batch cannot nest.
   */
  async listScheduledTransactionsWithKnowledge(
    planId: string,
  ): Promise<{ scheduled_transactions: any[]; server_knowledge: number }> {
    const values = [planId];
    const [rawParents, rawSubs, editRows, editSubRows, knowledgeRows] = await this.db.batchRead([
      ...SCHEDULED_SQL.map((sql) => ({ sql, values })),
      { sql: SERVER_KNOWLEDGE_SQL, values },
    ]);
    return {
      scheduled_transactions: assembleScheduledTransactions(rawParents ?? [], rawSubs ?? [], editRows ?? [], editSubRows ?? []),
      server_knowledge: knowledgeFrom(knowledgeRows),
    };
  }

  async listScheduledSubtransactions(planId: string): Promise<any[]> {
    return (await this.listScheduledTransactions(planId)).flatMap((transaction) => transaction.subtransactions ?? []);
  }

  async getScheduledTransaction(planId: string, scheduledTransactionId: string): Promise<any> {
    const record = await this.readScheduledTransaction(planId, scheduledTransactionId);
    return projectScheduledPayload(
      record.payloadJson,
      record.subtransactions.filter((subtransaction) => !subtransaction.deleted),
      record.payload.deleted,
    );
  }

  async createScheduledTransaction(
    planId: string,
    input: ScheduledTransactionInput,
    options: ScheduledWriteOptions = {},
  ): Promise<any> {
    await this.ensurePlan(planId);
    const id = input.id ?? (options.operationId ? `scheduled_${scheduleDigest(`${planId}:${options.operationId}`).slice(0, 24)}` : createId("scheduled"));
    const fingerprint = scheduleMutationFingerprint("create", planId, id, input);
    if (await this.replayedScheduleMutation(planId, id, "scheduled_transaction.create", options.operationId, fingerprint)) {
      return projectScheduledRead(await this.readScheduledTransaction(planId, id, true));
    }
    const collision = await this.db.query(
      `SELECT 1 FROM scheduled_transaction_edits WHERE plan_id=? AND id=?
       UNION ALL SELECT 1 FROM ynab_raw_objects WHERE plan_id=? AND object_type='scheduled_transaction' AND object_id=? LIMIT 1`,
    ).get(planId, id, planId, id);
    if (collision) throw new ValidationError("Scheduled transaction already exists");
    const transaction = scheduledTransactionMutation(id, input as Record<string, unknown>, null, [], options.operationId);
    await this.validateScheduledReferences(planId, transaction);
    await this.persistScheduledTransaction(planId, transaction, "howmuch-local", "scheduled_transaction.create", options.operationId, fingerprint);
    return projectScheduledRead(await this.readScheduledTransaction(planId, id, true));
  }

  async updateScheduledTransaction(
    planId: string,
    scheduledTransactionId: string,
    patch: Partial<ScheduledTransactionInput>,
    options: ScheduledWriteOptions = {},
  ): Promise<any> {
    // SQLite serialises this read/merge/write unit with BEGIN IMMEDIATE.  A
    // patch must merge against the most recent schedule, not a stale copy
    // read before another writer's transaction begins.
    return this.db.transaction(async () => {
      const fingerprint = scheduleMutationFingerprint("update", planId, scheduledTransactionId, patch);
      if (await this.replayedScheduleMutation(planId, scheduledTransactionId, "scheduled_transaction.update", options.operationId, fingerprint)) {
        return projectScheduledRead(await this.readScheduledTransaction(planId, scheduledTransactionId, true));
      }
      const current = await this.readScheduledTransaction(planId, scheduledTransactionId);
      assertExpectedSchedule(current.payload, options.expected);
      const transaction = scheduledTransactionMutation(
        scheduledTransactionId,
        patch as Record<string, unknown>,
        current.payload,
        current.subtransactions,
        options.operationId,
      );
      await this.validateScheduledReferences(planId, transaction);
      await this.persistScheduledTransaction(planId, transaction, current.origin, "scheduled_transaction.update", options.operationId, fingerprint, true);
      return projectScheduledRead(await this.readScheduledTransaction(planId, scheduledTransactionId, true));
    })();
  }

  async deleteScheduledTransaction(
    planId: string,
    scheduledTransactionId: string,
    options: ScheduledWriteOptions = {},
  ): Promise<any> {
    return this.db.transaction(async () => {
      const fingerprint = scheduleMutationFingerprint("delete", planId, scheduledTransactionId, {});
      if (await this.replayedScheduleMutation(planId, scheduledTransactionId, "scheduled_transaction.delete", options.operationId, fingerprint)) {
        return projectScheduledRead(await this.readScheduledTransaction(planId, scheduledTransactionId, true));
      }
      const current = await this.readScheduledTransaction(planId, scheduledTransactionId);
      assertExpectedSchedule(current.payload, options.expected);
      const transaction = {
        ...current.payload,
        deleted: true,
        subtransactions: current.subtransactions,
      } as unknown as EffectiveScheduledTransaction;
      await this.persistScheduledTransaction(planId, transaction, current.origin, "scheduled_transaction.delete", options.operationId, fingerprint, true);
      return projectScheduledRead(await this.readScheduledTransaction(planId, scheduledTransactionId, true));
    })();
  }

  /** Enters one named occurrence and advances the schedule from its fixed cadence. */
  async materializeScheduledOccurrence(
    planId: string,
    scheduledTransactionId: string,
    occurrenceDate: string,
    enteredDate: string,
    options: { allowClosedAccount?: boolean; requestOperationId?: string } = {},
  ): Promise<ScheduledOccurrenceResult> {
    scheduledOccurrencesThrough(occurrenceDate, occurrenceDate, "never", occurrenceDate, 1);
    scheduledOccurrencesThrough(enteredDate, enteredDate, "never", enteredDate, 1);
    const record = await this.readScheduledTransaction(planId, scheduledTransactionId, true);
    const schedule = projectScheduledRead(record) as EffectiveScheduledTransaction;
    const transactionId = scheduledOccurrenceTransactionId(planId, scheduledTransactionId, occurrenceDate);
    const existing = await this.readMaterializedOccurrence(planId, transactionId, scheduledTransactionId, occurrenceDate);
    const currentDate = String(schedule.date_next ?? "");

    if (schedule.deleted || currentDate > occurrenceDate) {
      if (!existing) throw new ValidationError("Scheduled occurrence is no longer current");
      return {
        transaction: existing.transaction,
        scheduled_transaction: schedule,
        occurrence_date: occurrenceDate,
        entered_date: existing.transaction.date,
        completed: Boolean(schedule.deleted),
        replayed: true,
      };
    }
    if (currentDate !== occurrenceDate) throw new ValidationError("occurrence_date must equal the schedule's current date_next");
    const scheduleSnapshot = scheduledOccurrenceSnapshotHash(schedule);
    if (existing && existing.snapshotHash !== scheduleSnapshot) throw new Error("stale scheduled occurrence");

    const input = await this.prepareScheduledOccurrence(planId, schedule, occurrenceDate, enteredDate, Boolean(options.allowClosedAccount), options.requestOperationId);
    const operationId = `scheduled_occurrence_${scheduleDigest(`${planId}:${scheduledTransactionId}:${occurrenceDate}`).slice(0, 32)}`;
    const transaction = await this.createTransaction(planId, input, { autoLink: true, operationId });
    const advanceId = `scheduled_advance_${scheduleDigest(`${planId}:${scheduledTransactionId}:${occurrenceDate}`).slice(0, 32)}`;
    let advanced: any;
    const expected = { date_first: schedule.date_first, date_next: occurrenceDate, frequency: schedule.frequency };
    if (schedule.frequency === "never") {
      advanced = await this.deleteScheduledTransaction(planId, scheduledTransactionId, { operationId: advanceId, expected });
    } else {
      const nextDate = nextScheduledOccurrence(schedule.date_first, occurrenceDate, schedule.frequency);
      if (!nextDate) throw new ValidationError("Recurring schedule did not produce a next date");
      advanced = await this.updateScheduledTransaction(planId, scheduledTransactionId, { date_next: nextDate }, { operationId: advanceId, expected });
    }
    return {
      transaction,
      scheduled_transaction: advanced,
      occurrence_date: occurrenceDate,
      entered_date: enteredDate,
      completed: schedule.frequency === "never",
      replayed: Boolean(existing),
    };
  }

  /** Bounded catch-up shared by the explicit owner action and daily Worker job. */
  async materializeScheduledTransactions(planId: string, throughDate: string, maximum = 5_000, requestOperationId?: string): Promise<ScheduledMaterializationResult> {
    scheduledOccurrencesThrough(throughDate, throughDate, "never", throughDate, 1);
    if (!Number.isSafeInteger(maximum) || maximum < 1 || maximum > 5_000) throw new ValidationError("maximum must be an integer from 1 to 5000");
    const schedules = await this.listScheduledTransactions(planId) as EffectiveScheduledTransaction[];
    const accounts = await this.liveAccounts(planId);
    const planned: Array<{ schedule: EffectiveScheduledTransaction; date: string }> = [];
    const skippedClosed = new Set<string>();

    for (const schedule of schedules) {
      const account = accounts.get(schedule.account_id);
      if (!account) throw new ValidationError(`Scheduled transaction ${schedule.id} account not found`);
      if (account.closed) {
        skippedClosed.add(schedule.id);
        continue;
      }
      if (typeof schedule.date_next !== "string") continue;
      const remaining = maximum - planned.length;
      if (remaining < 1) throw new ValidationError(`Materialisation exceeds the ${maximum}-occurrence safety limit`);
      const window = scheduledOccurrencesThrough(schedule.date_first, schedule.date_next, schedule.frequency, throughDate, remaining);
      for (const date of window.dates) {
        await this.prepareScheduledOccurrence(planId, schedule, date, date, false, requestOperationId ? `${requestOperationId}:${schedule.id}:${date}` : undefined);
        planned.push({ schedule, date });
      }
    }

    const occurrences: ScheduledOccurrenceResult[] = [];
    for (const item of planned) {
      occurrences.push(await this.materializeScheduledOccurrence(planId, item.schedule.id, item.date, item.date, {
        requestOperationId: requestOperationId ? `${requestOperationId}:${item.schedule.id}:${item.date}` : undefined,
      }));
    }
    return { through_date: throughDate, occurrences, skipped_closed_schedule_ids: [...skippedClosed].sort() };
  }

  /**
   * Private Worker catch-up with a deliberately small cap. Unlike the explicit
   * owner bulk action above, this makes one fair pass over every due schedule
   * before returning to the first schedule, and isolates a bad schedule so it
   * cannot block the rest of the plan.
   */
  async materializeScheduledTransactionsForCron(
    planId: string,
    throughDate: string,
    maximum = 25,
    requestOperationId?: string,
  ): Promise<ScheduledCronMaterializationResult> {
    scheduledOccurrencesThrough(throughDate, throughDate, "never", throughDate, 1);
    if (!Number.isSafeInteger(maximum) || maximum < 1 || maximum > 50) {
      throw new ValidationError("maximum must be an integer from 1 to 50");
    }

    let occurrenceCount = 0;
    const skippedClosed = new Set<string>();
    const failures = new Set<string>();

    while (occurrenceCount < maximum) {
      const schedules = await this.listScheduledTransactions(planId) as EffectiveScheduledTransaction[];
      let progressed = false;

      for (const listed of schedules) {
        if (occurrenceCount >= maximum) break;
        if (failures.has(listed.id)) continue;

        try {
          // Re-read immediately before each occurrence so an earlier write or
          // concurrent edit cannot make this round operate on stale schedule data.
          const schedule = await this.getScheduledTransaction(planId, listed.id) as EffectiveScheduledTransaction;
          if (typeof schedule.date_next !== "string" || schedule.date_next > throughDate) continue;

          const account = await this.liveAccount(planId, schedule.account_id);
          if (account?.closed) {
            skippedClosed.add(schedule.id);
            continue;
          }

          const occurrence = await this.materializeScheduledOccurrence(
            planId,
            schedule.id,
            schedule.date_next,
            schedule.date_next,
            {
              requestOperationId: requestOperationId
                ? scheduledCronOccurrenceOperationId(requestOperationId, schedule.id, schedule.date_next)
                : undefined,
            },
          );
          if (!occurrence.replayed) occurrenceCount += 1;
          progressed = true;
        } catch {
          // Keep a bad schedule for a later retry but let unrelated schedules
          // finish this bounded run. IDs and source data deliberately stay local.
          failures.add(listed.id);
        }
      }

      if (!progressed) break;
    }

    const remainingSchedules = await this.listScheduledTransactions(planId) as EffectiveScheduledTransaction[];
    const accounts = await this.liveAccounts(planId);
    const hasMore = remainingSchedules.some((schedule) => {
      if (typeof schedule.date_next !== "string" || schedule.date_next > throughDate) return false;
      return !accounts.get(schedule.account_id)?.closed;
    });

    return {
      through_date: throughDate,
      occurrence_count: occurrenceCount,
      skipped_closed_schedule_count: skippedClosed.size,
      failure_count: failures.size,
      has_more: hasMore,
    };
  }

  private async prepareScheduledOccurrence(
    planId: string,
    schedule: EffectiveScheduledTransaction,
    occurrenceDate: string,
    enteredDate: string,
    allowClosedAccount: boolean,
    requestOperationId?: string,
  ): Promise<TransactionInput> {
    const normalised = scheduledTransactionMutation(schedule.id, {}, schedule, schedule.subtransactions ?? []);
    const sourceAccount = await this.liveAccount(planId, normalised.account_id);
    if (!sourceAccount) throw new ValidationError("Scheduled transaction account not found");
    if (sourceAccount.closed && !allowClosedAccount) throw new ValidationError("Scheduled transactions in closed accounts do not occur automatically");
    const accounts = new Map<string, { id: string; closed: boolean; type: string }>([[sourceAccount.id, sourceAccount]]);
    const payees = new Map<string, any>();
    const categories = new Map<string, boolean>();
    const loadAccount = async (accountId: string) => {
      if (!accounts.has(accountId)) {
        const account = await this.liveAccount(planId, accountId);
        if (account) accounts.set(accountId, account);
        return account;
      }
      return accounts.get(accountId);
    };
    const loadPayee = async (payeeId: string) => {
      if (!payees.has(payeeId)) payees.set(payeeId, await this.findPayee(planId, payeeId));
      return payees.get(payeeId);
    };
    const categoryExists = async (categoryId: string) => {
      if (!categories.has(categoryId)) categories.set(categoryId, await this.liveCategory(planId, categoryId));
      return categories.get(categoryId) === true;
    };

    const prepareLine = async (value: Record<string, any>, label: string) => {
      const payee = value.payee_id == null ? null : await loadPayee(value.payee_id);
      if (value.payee_id != null && !payee) throw new ValidationError(`${label} payee not found`);
      if (value.category_id != null && !await categoryExists(value.category_id)) throw new ValidationError(`${label} category not found`);
      const explicitTarget = value.transfer_account_id ?? null;
      const payeeTarget = payee?.transfer_account_id ?? null;
      if (explicitTarget && payee && !payeeTarget) throw new ValidationError(`${label} cannot combine a regular payee with transfer_account_id`);
      if (explicitTarget && payeeTarget && payeeTarget !== explicitTarget) throw new ValidationError(`${label} transfer payee does not match transfer_account_id`);
      const transferAccountId = payeeTarget ?? explicitTarget;
      if (transferAccountId) {
        const target = await loadAccount(transferAccountId);
        if (!target) throw new ValidationError(`${label} transfer account not found`);
        if (target.id === normalised.account_id) throw new ValidationError(`${label} transfer target must be a different account`);
        if (target.closed && !allowClosedAccount) throw new ValidationError(`${label} transfer target account is closed`);
      }
      return { transferAccountId };
    };

    const parent = await prepareLine(normalised, "Scheduled transaction");
    if (parent.transferAccountId && normalised.subtransactions.length) throw new ValidationError("A split scheduled transaction cannot itself be a transfer");
    const subtransactions = [];
    for (const [index, subtransaction] of normalised.subtransactions.entries()) {
      const line = await prepareLine(subtransaction, `Scheduled subtransaction ${index + 1}`);
      subtransactions.push({
        id: scheduledOccurrenceSubtransactionId(planId, schedule.id, occurrenceDate, subtransaction.id),
        amount: subtransaction.amount,
        payee_id: subtransaction.payee_id ?? null,
        category_id: subtransaction.category_id ?? null,
        memo: subtransaction.memo ?? null,
        transfer_account_id: line.transferAccountId,
      });
    }
    return {
      id: scheduledOccurrenceTransactionId(planId, schedule.id, occurrenceDate),
      account_id: normalised.account_id,
      date: enteredDate,
      amount: normalised.amount,
      payee_id: normalised.payee_id ?? null,
      category_id: normalised.category_id ?? null,
      memo: normalised.memo ?? null,
      cleared: sourceAccount.type === "cash" ? "cleared" : "uncleared",
      approved: false,
      flag_color: normalised.flag_color ?? null,
      transfer_account_id: parent.transferAccountId,
      import_id: `scheduled:${schedule.id}:${occurrenceDate}`,
      source_kind: "scheduled-transaction",
      source_ref: `${schedule.id}:${occurrenceDate}:${scheduledOccurrenceSnapshotHash(schedule)}:${scheduleDigest(requestOperationId ?? "direct").slice(0, 16)}`,
      subtransactions,
    };
  }

  private async readMaterializedOccurrence(planId: string, transactionId: string, scheduleId: string, occurrenceDate: string): Promise<{ transaction: any; snapshotHash: string } | null> {
    const row = await this.db.query("SELECT source_kind,source_ref FROM transactions WHERE id=? AND plan_id=?").get(transactionId, planId) as Row | null;
    if (!row) return null;
    const prefix = `${scheduleId}:${occurrenceDate}:`;
    if (row.source_kind !== "scheduled-transaction" || typeof row.source_ref !== "string" || !row.source_ref.startsWith(prefix)) {
      throw new ValidationError("Scheduled occurrence transaction ID collision");
    }
    return { transaction: await this.getTransaction(planId, transactionId, true), snapshotHash: row.source_ref.slice(prefix.length).split(":", 1)[0] };
  }

  private async readScheduledTransaction(planId: string, id: string, includeDeleted = false): Promise<{ payload: Record<string, any>; subtransactions: Record<string, any>[]; origin: "howmuch-local" | "ynab-overlay" } & Record<string, any>> {
    const edit = await this.db.query("SELECT origin,payload_json,deleted FROM scheduled_transaction_edits WHERE plan_id=? AND id=?").get(planId, id) as Row | null;
    if (edit) {
      if (Boolean(edit.deleted) && !includeDeleted) throw new NotFoundError("Scheduled transaction not found");
      const subs = await this.db.query("SELECT payload_json FROM scheduled_subtransaction_edits WHERE plan_id=? AND scheduled_transaction_id=? ORDER BY id").all(planId, id) as Row[];
      const subtransactions = subs.map((row) => parseRawYnabObject(row.payload_json, "scheduled subtransaction"));
      const payload = { ...parseRawYnabObject(edit.payload_json, "scheduled transaction"), deleted: Boolean(edit.deleted) };
      return { ...payload, payload, payloadJson: String(edit.payload_json), subtransactions, origin: edit.origin as "howmuch-local" | "ynab-overlay" } as any;
    }
    const source = await this.db.query("SELECT payload_json,deleted FROM ynab_raw_objects WHERE plan_id=? AND object_type='scheduled_transaction' AND object_id=?").get(planId, id) as Row | null;
    if (!source || (Boolean(source.deleted) && !includeDeleted)) throw new NotFoundError("Scheduled transaction not found");
    const rows = await this.db.query("SELECT payload_json FROM ynab_raw_objects WHERE plan_id=? AND object_type='scheduled_subtransaction' ORDER BY object_id").all(planId) as Row[];
    const subtransactions = rows.map((row) => parseRawYnabObject(row.payload_json, "scheduled subtransaction")).filter((row) => row.scheduled_transaction_id === id);
    const payload = { ...parseRawYnabObject(source.payload_json, "scheduled transaction"), deleted: Boolean(source.deleted) };
    return { ...payload, payload, payloadJson: String(source.payload_json), subtransactions, origin: "ynab-overlay" };
  }

  private async validateScheduledReferences(planId: string, transaction: EffectiveScheduledTransaction): Promise<void> {
    const requireReference = async (table: "accounts" | "payees" | "categories", id: unknown, label: string) => {
      if (id == null) return;
      const row = await this.db.query(`SELECT name FROM ${table} WHERE id=? AND plan_id=? AND deleted=0`).get(id, planId) as Row | null;
      if (!row) throw new ValidationError(`${label} not found`);
      return row;
    };
    const account = await requireReference("accounts", transaction.account_id, "Account");
    transaction.account_name = account?.name ?? transaction.account_name ?? null;
    const payee = await requireReference("payees", transaction.payee_id, "Payee");
    if (payee) transaction.payee_name = payee.name;
    const category = await requireReference("categories", transaction.category_id, "Category");
    if (category) transaction.category_name = category.name;
    await requireReference("accounts", transaction.transfer_account_id, "Transfer account");
    for (const subtransaction of transaction.subtransactions) {
      const subPayee = await requireReference("payees", subtransaction.payee_id, "Subtransaction payee");
      if (subPayee) subtransaction.payee_name = subPayee.name;
      const subCategory = await requireReference("categories", subtransaction.category_id, "Subtransaction category");
      if (subCategory) subtransaction.category_name = subCategory.name;
      await requireReference("accounts", subtransaction.transfer_account_id, "Subtransaction transfer account");
    }
  }

  private async persistScheduledTransaction(
    planId: string,
    transaction: EffectiveScheduledTransaction,
    origin: "howmuch-local" | "ynab-overlay",
    action: string,
    operationId: string | undefined,
    requestHash: string,
    withinTransaction = false,
  ): Promise<void> {
    const { subtransactions, ...parent } = transaction;
    const auditId = operationId ? `audit_${scheduleDigest(operationId).slice(0, 24)}` : createId("audit");
    const persist = async () => {
      await this.db.query(
        `INSERT INTO scheduled_transaction_edits
          (plan_id,id,origin,payload_json,account_id,date_first,date_next,frequency,amount_milli,payee_id,category_id,transfer_account_id,deleted,updated_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP)
         ON CONFLICT(plan_id,id) DO UPDATE SET origin=excluded.origin,payload_json=excluded.payload_json,account_id=excluded.account_id,
           date_first=excluded.date_first,date_next=excluded.date_next,frequency=excluded.frequency,amount_milli=excluded.amount_milli,
           payee_id=excluded.payee_id,category_id=excluded.category_id,transfer_account_id=excluded.transfer_account_id,
           deleted=excluded.deleted,updated_at=CURRENT_TIMESTAMP`,
      ).run(planId, transaction.id, origin, JSON.stringify(parent), transaction.account_id, transaction.date_first, transaction.date_next, transaction.frequency, transaction.amount, transaction.payee_id ?? null, transaction.category_id ?? null, transaction.transfer_account_id ?? null, transaction.deleted ? 1 : 0);
      await this.db.query("DELETE FROM scheduled_subtransaction_edits WHERE plan_id=? AND scheduled_transaction_id=?").run(planId, transaction.id);
      for (const subtransaction of subtransactions) {
        await this.db.query(
          `INSERT INTO scheduled_subtransaction_edits
            (plan_id,id,scheduled_transaction_id,payload_json,amount_milli,payee_id,category_id,transfer_account_id)
           VALUES (?,?,?,?,?,?,?,?)`,
        ).run(planId, subtransaction.id, transaction.id, JSON.stringify(subtransaction), subtransaction.amount, subtransaction.payee_id ?? null, subtransaction.category_id ?? null, subtransaction.transfer_account_id ?? null);
      }
      await this.db.query("UPDATE plans SET server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?").run(planId);
      await this.db.query(
        "INSERT INTO audit_events(id,plan_id,action,resource_type,resource_id,source,metadata_json) VALUES (?,?,?,?,?,'howmuch-local',?)",
      ).run(auditId, planId, action, "scheduled_transaction", transaction.id, JSON.stringify({ request_hash: requestHash, origin, deleted: Boolean(transaction.deleted) }));
    };
    if (withinTransaction) return persist();
    await this.db.transaction(persist)();
  }

  private async replayedScheduleMutation(planId: string, id: string, action: string, operationId: string | undefined, requestHash: string): Promise<boolean> {
    if (!operationId) return false;
    const row = await this.db.query("SELECT action,plan_id,resource_id,metadata_json FROM audit_events WHERE id=?").get(`audit_${scheduleDigest(operationId).slice(0, 24)}`) as Row | null;
    if (!row) return false;
    const metadata = JSON.parse(String(row.metadata_json));
    if (row.action !== action || row.plan_id !== planId || row.resource_id !== id || metadata.request_hash !== requestHash) {
      throw new Error("idempotency-key reuse");
    }
    return true;
  }

  async listYnabTransactionFingerprints(planId: string): Promise<Array<{ external_ynab_id: string; date: string; amount_milli: number }>> {
    return await this.db
      .query(
        `SELECT external_ynab_id, date, amount_milli
         FROM transactions
         WHERE plan_id = ? AND source_kind = 'ynab-import' AND external_ynab_id IS NOT NULL`,
      )
      .all(planId) as Array<{ external_ynab_id: string; date: string; amount_milli: number }>;
  }

  async upsertRewardsTrackerSnapshot(planId: string, payload: unknown): Promise<void> {
    await this.ensurePlan(planId);
    const json = JSON.stringify(payload);
    if (json === undefined) throw new ValidationError("Rewards Tracker snapshot must be JSON serialisable");
    const cards = Array.isArray((payload as { cards?: unknown }).cards) ? (payload as { cards: unknown[] }).cards : [];
    await this.db
      .query(
        `INSERT INTO rewards_tracker_snapshots (plan_id, payload_json, source_kind, imported_at, updated_at)
         VALUES (?, ?, 'rewards-tracker-export', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
         ON CONFLICT(plan_id) DO UPDATE SET
           payload_json = excluded.payload_json,
           source_kind = excluded.source_kind,
           updated_at = CURRENT_TIMESTAMP`,
      )
      .run(planId, json);

    const keepIds: string[] = [];
    for (const entry of cards) {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
      const id = await this.writeRewardsTrackerCardRow(planId, entry as Record<string, unknown>);
      if (id) keepIds.push(id);
    }

    if (keepIds.length === 0) {
      await this.db.query("UPDATE rewards_tracker_cards SET deleted = 1, updated_at = CURRENT_TIMESTAMP WHERE plan_id = ?").run(planId);
    } else {
      const placeholders = keepIds.map(() => "?").join(", ");
      await this.db
        .query(
          `UPDATE rewards_tracker_cards
           SET deleted = 1, updated_at = CURRENT_TIMESTAMP
           WHERE plan_id = ? AND id NOT IN (${placeholders})`,
        )
        .run(planId, ...keepIds);
    }
  }

  async findLiveAccountId(planId: string, accountId: string): Promise<string | null> {
    const row = await this.db
      .query("SELECT id FROM accounts WHERE plan_id = ? AND id = ? AND deleted = 0")
      .get(planId, accountId) as Row | null;
    return row ? String(row.id) : null;
  }

  async importRewardsTrackerAccountCard(planId: string, card: object): Promise<void> {
    // Row-backed cards are authoritative for reports and exports. Do not rewrite
    // the archival snapshot: that would race with saves of global settings.
    const written = await this.writeRewardsTrackerCardRow(planId, card as Record<string, unknown>, true);
    if (!written) throw new ValidationError("The rewards card account mapping changed or conflicts with another card. Resolve the mapping and retry.");
  }

  async upsertRewardsTrackerCard(planId: string, card: object): Promise<void> {
    await this.ensurePlan(planId);
    const written = await this.writeRewardsTrackerCardRow(planId, card as Record<string, unknown>);
    if (!written) throw new ValidationError("Card needs id, name, and ynabAccountId");
    const current = await this.readRewardsTrackerSnapshotPayload(planId);
    const snapshot = current ?? emptyRewardsTrackerSnapshot([card]);
    const cards = Array.isArray(snapshot.cards) ? [...snapshot.cards] : [];
    const index = cards.findIndex((entry) => rewardsTrackerCardId(entry) === written);
    if (index >= 0) cards[index] = card;
    else cards.push(card);
    await this.writeRewardsTrackerSnapshotPayload(planId, current ? { ...snapshot, cards } : { ...snapshot, cards: [card] });
  }

  async deleteRewardsTrackerCard(planId: string, cardId: string): Promise<object | null> {
    const row = await this.db
      .query("SELECT payload_json FROM rewards_tracker_cards WHERE plan_id = ? AND id = ? AND deleted = 0")
      .get(planId, cardId) as Row | null;
    if (!row) return null;
    await this.db
      .query("UPDATE rewards_tracker_cards SET deleted = 1, updated_at = CURRENT_TIMESTAMP WHERE plan_id = ? AND id = ?")
      .run(planId, cardId);
    const current = await this.readRewardsTrackerSnapshotPayload(planId);
    if (current) {
      const cards = Array.isArray(current.cards)
        ? current.cards.filter((entry) => rewardsTrackerCardId(entry) !== cardId)
        : [];
      await this.writeRewardsTrackerSnapshotPayload(planId, { ...current, cards });
    }
    return JSON.parse(String(row.payload_json)) as object;
  }

  async patchRewardsTrackerSettings(planId: string, settings: object): Promise<object> {
    await this.ensurePlan(planId);
    const current = await this.readRewardsTrackerSnapshotPayload(planId);
    const snapshot = current ?? emptyRewardsTrackerSnapshot([]);
    await this.writeRewardsTrackerSnapshotPayload(planId, { ...snapshot, settings });
    return settings;
  }

  async getRewardsTrackerSnapshot(planId: string): Promise<{
    snapshot: unknown | null;
    cards: unknown[];
    imported_at: string | null;
    updated_at: string | null;
  }> {
    const row = await this.db
      .query("SELECT payload_json, imported_at, updated_at FROM rewards_tracker_snapshots WHERE plan_id = ?")
      .get(planId) as Row | null;
    const cards = await this.db
      .query(
        `SELECT payload_json FROM rewards_tracker_cards
         WHERE plan_id = ? AND deleted = 0
         ORDER BY name, id`,
      )
      .all(planId) as Array<{ payload_json: string }>;
    return {
      snapshot: row ? JSON.parse(String(row.payload_json)) : null,
      cards: cards.map((card) => JSON.parse(String(card.payload_json))),
      imported_at: row ? String(row.imported_at) : null,
      updated_at: row ? String(row.updated_at) : null,
    };
  }

  private async readRewardsTrackerSnapshotPayload(planId: string): Promise<Record<string, unknown> | null> {
    const row = await this.db
      .query("SELECT payload_json FROM rewards_tracker_snapshots WHERE plan_id = ?")
      .get(planId) as Row | null;
    if (!row) return null;
    const payload = JSON.parse(String(row.payload_json));
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) return {};
    return payload as Record<string, unknown>;
  }

  private async writeRewardsTrackerSnapshotPayload(planId: string, payload: Record<string, unknown>): Promise<void> {
    const json = JSON.stringify(payload);
    await this.db
      .query(
        `INSERT INTO rewards_tracker_snapshots (plan_id, payload_json, source_kind, imported_at, updated_at)
         VALUES (?, ?, 'rewards-tracker-export', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
         ON CONFLICT(plan_id) DO UPDATE SET
           payload_json = excluded.payload_json,
           updated_at = CURRENT_TIMESTAMP`,
      )
      .run(planId, json);
  }

  private async writeRewardsTrackerCardRow(planId: string, card: Record<string, unknown>, guardAccount = false): Promise<string | null> {
    const id = typeof card.id === "string" ? card.id.trim() : "";
    const name = typeof card.name === "string" ? card.name.trim() : "";
    const accountId = typeof card.ynabAccountId === "string" ? card.ynabAccountId.trim() : "";
    if (!id || !name || !accountId) return null;
    const result = await this.db
      .query(
        `INSERT INTO rewards_tracker_cards (
           plan_id, id, account_id, name, issuer, type, payload_json, deleted, updated_at
         ) SELECT ?, ?, ?, ?, ?, ?, ?, 0, CURRENT_TIMESTAMP
         WHERE ${guardAccount ? `NOT EXISTS (
           SELECT 1 FROM rewards_tracker_cards WHERE plan_id = ? AND account_id = ? AND id <> ? AND deleted = 0
         )` : "1"}
         ON CONFLICT(plan_id, id) DO UPDATE SET
           account_id = excluded.account_id,
           name = excluded.name,
           issuer = excluded.issuer,
           type = excluded.type,
           payload_json = excluded.payload_json,
           deleted = 0,
           updated_at = CURRENT_TIMESTAMP
         ${guardAccount ? "WHERE rewards_tracker_cards.account_id = excluded.account_id" : ""}`,
      )
      .run(
        planId,
        id,
        accountId,
        name,
        typeof card.issuer === "string" ? card.issuer : "",
        typeof card.type === "string" ? card.type : "cashback",
        JSON.stringify(card),
        ...(guardAccount ? [planId, accountId, id] : []),
      );
    return result.changes === 1 ? id : null;
  }

  async recordImportRow(sessionId: string, rowIndex: number, status: string, payload: unknown, error?: string, transactionId?: string): Promise<void> {
    await this.db
      .query(
        `INSERT INTO import_rows (id, import_session_id, row_index, status, payload_json, error, transaction_id)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(createId("row"), sessionId, rowIndex, status, JSON.stringify(payload), error ?? null, transactionId ?? null);
  }

  private async payeeTransferTarget(planId: string, payeeId: string): Promise<string | null> {
    const row = await this.db
      .query("SELECT transfer_account_id FROM payees WHERE id = ? AND plan_id = ? AND deleted = 0")
      .get(payeeId, planId) as Row | null;
    return row?.transfer_account_id ?? null;
  }

  private async requireTransferTarget(planId: string, sourceAccountId: string, targetAccountId: string): Promise<Row> {
    if (targetAccountId === sourceAccountId) {
      throw new ValidationError("Transfer target must be a different account");
    }
    const target = await this.db
      .query("SELECT * FROM accounts WHERE id = ? AND plan_id = ? AND deleted = 0")
      .get(targetAccountId, planId) as Row | null;
    if (!target) {
      throw new ValidationError("Transfer target account not found");
    }
    return target;
  }

  private async accountsBothOnBudget(planId: string, firstAccountId: string, secondAccountId: string): Promise<boolean> {
    const row = await this.db
      .query(
        `SELECT COUNT(*) AS on_budget_count FROM accounts
         WHERE plan_id = ? AND id IN (?, ?) AND on_budget = 1`,
      )
      .get(planId, firstAccountId, secondAccountId) as Row;
    return Number(row.on_budget_count) === 2;
  }

  /** Creates the other side of a transfer and returns its id. */
  private async insertLinkedTransaction(
    planId: string,
    opts: {
      accountId: string;
      date: string;
      amount: number;
      memo: string | null;
      approved?: boolean | null;
      cleared?: ClearedState;
      sourceAccountId: string;
      linkId: string;
    },
    plan: TransactionMutationPlan,
  ): Promise<string> {
    await this.ensureAccount(planId, opts.accountId);
    const payee = await this.ensureTransferPayee(planId, opts.sourceAccountId);
    const id = createId("txn");
    await this.db
      .query(
        `INSERT INTO transactions (
           id, plan_id, account_id, date, amount_milli, memo, cleared, approved,
           payee_id, payee_name_snapshot, transfer_account_id, transfer_transaction_id, updated_at
         )
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`,
      )
      .run(
        id,
        planId,
        opts.accountId,
        opts.date,
        opts.amount,
        opts.memo,
        opts.cleared ?? "uncleared",
        bool(opts.approved),
        payee?.id ?? null,
        payee?.name ?? null,
        opts.sourceAccountId,
        opts.linkId,
      );
    plan.accountIdsToRecalculate.add(opts.accountId);
    plan.touchedTransactionIds.add(id);
    return id;
  }

  /** Keeps the other side of a transfer in step after an edit. */
  private async syncLinkedTransaction(
    planId: string,
    linkedTransactionId: string,
    opts: {
      date: string;
      amount: number;
      memo: string | null;
      approved?: boolean | null;
      sourceAccountId: string;
      accountId?: string;
    },
    plan: TransactionMutationPlan,
  ): Promise<void> {
    const linked = await this.getTransactionRow(planId, linkedTransactionId);
    if (!linked) {
      return;
    }
    const nextAccountId = opts.accountId ?? linked.account_id;
    const payee = await this.ensureTransferPayee(planId, opts.sourceAccountId);
    await this.db
      .query(
        `UPDATE transactions
         SET account_id = ?, date = ?, amount_milli = ?, memo = ?,
             approved = ?, payee_id = ?, payee_name_snapshot = ?, transfer_account_id = ?,
             updated_at = CURRENT_TIMESTAMP
         WHERE id = ? AND plan_id = ?`,
      )
      .run(
        nextAccountId,
        opts.date,
        opts.amount,
        opts.memo,
        bool(opts.approved),
        payee?.id ?? linked.payee_id,
        payee?.name ?? linked.payee_name_snapshot,
        opts.sourceAccountId,
        linkedTransactionId,
        planId,
      );
    plan.accountIdsToRecalculate.add(linked.account_id);
    if (nextAccountId !== linked.account_id) {
      plan.accountIdsToRecalculate.add(nextAccountId);
    }
    plan.touchedTransactionIds.add(linkedTransactionId);
  }

  private async softDeleteLinkedTransaction(
    planId: string,
    linkedTransactionId: string,
    plan: TransactionMutationPlan,
  ): Promise<void> {
    const linked = await this.getTransactionRow(planId, linkedTransactionId);
    if (!linked) {
      return;
    }
    await this.db
      .query("UPDATE transactions SET deleted = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND plan_id = ?")
      .run(linkedTransactionId, planId);
    plan.accountIdsToRecalculate.add(linked.account_id);
    plan.touchedTransactionIds.add(linkedTransactionId);
  }

  /** Executes operation-local final mutations; each item can become a D1 batch statement. */
  private async executeMutationPlan(planId: string, plan: TransactionMutationPlan): Promise<void> {
    for (const accountId of plan.accountIdsToRecalculate) {
      await this.recalculateAccount(accountId);
    }
    if (!plan.touchedTransactionIds.size) {
      return;
    }
    await this.db
      .query(
        `UPDATE plans
         SET server_knowledge = server_knowledge + 1, updated_at = CURRENT_TIMESTAMP
         WHERE id = ?`,
      )
      .run(planId);
    for (const id of plan.touchedTransactionIds) {
      await this.db
        .query(
          `UPDATE transactions
           SET server_knowledge = (SELECT server_knowledge FROM plans WHERE id = ?), updated_at = CURRENT_TIMESTAMP
           WHERE id = ? AND plan_id = ?`,
        )
        .run(planId, id, planId);
    }
  }

  private async resolveTransactionRefs(planId: string, input: TransactionInput): Promise<{
    payeeId: string | null;
    payeeName: string | null;
    categoryId: string | null;
    categoryName: string | null;
  }> {
    let payeeId = input.payee_id ?? null;
    let payeeName = input.payee_name ?? null;
    if (payeeId) {
      await this.ensurePayee(planId, payeeId, payeeName ?? undefined);
      const row = await this.db.query("SELECT name FROM payees WHERE id = ?").get(payeeId) as Row;
      payeeName = row?.name ?? payeeName;
    } else if (payeeName) {
      payeeId = (await this.createPayee(planId, payeeName)).id;
    }

    let categoryName: string | null = null;
    const categoryId = input.category_id ?? null;
    if (categoryId) {
      await this.ensureCategory(planId, categoryId);
      const row = await this.db.query("SELECT name FROM categories WHERE id = ?").get(categoryId) as Row;
      categoryName = row?.name ?? null;
    }

    return { payeeId, payeeName, categoryId, categoryName };
  }

  async findYnabImportTarget(
    planId: string,
    input: { id: string; account_id: string; date: string; amount: number; import_id?: string | null; deleted?: boolean },
  ): Promise<any | null> {
    const byId = await this.getTransactionRow(planId, input.id, true);
    if (byId) {
      return this.formatTransaction(byId);
    }

    const byExternal = await this.db
      .query("SELECT id FROM transactions WHERE plan_id = ? AND deleted = 0 AND external_ynab_id = ? LIMIT 2")
      .all(planId, input.id) as Array<{ id: string }>;
    if (byExternal.length === 1) {
      return this.getTransaction(planId, byExternal[0].id);
    }

    if (input.import_id && input.account_id) {
      const byImport = await this.findTransactionByImportId(planId, input.import_id, input.account_id);
      if (byImport) {
        return byImport;
      }
    }

    // A YNAB tombstone must not claim an unrelated HowMuch-local row.
    if (input.deleted) {
      return null;
    }

    const locals = await this.db
      .query(
        `SELECT id FROM transactions
         WHERE plan_id = ? AND deleted = 0 AND account_id = ? AND date = ? AND amount_milli = ?
           AND (source_kind IS NULL OR source_kind NOT IN ('ynab-import', 'scheduled-transaction'))
         ORDER BY created_at, id
         LIMIT 2`,
      )
      .all(planId, input.account_id, input.date, input.amount) as Array<{ id: string }>;
    if (locals.length === 1) {
      return this.getTransaction(planId, locals[0].id);
    }
    return null;
  }

  async relinkYnabTransferTargets(planId: string): Promise<void> {
    const dangling = await this.db
      .query(
        `SELECT id, transfer_transaction_id
         FROM transactions
         WHERE plan_id = ? AND deleted = 0 AND transfer_transaction_id IS NOT NULL
           AND NOT EXISTS (
             SELECT 1 FROM transactions linked WHERE linked.id = transactions.transfer_transaction_id
           )`,
      )
      .all(planId) as Array<{ id: string; transfer_transaction_id: string }>;
    if (!dangling.length) {
      return;
    }

    const plan = newTransactionMutationPlan();
    for (const row of dangling) {
      const matches = await this.db
        .query("SELECT id FROM transactions WHERE plan_id = ? AND deleted = 0 AND external_ynab_id = ? LIMIT 2")
        .all(planId, row.transfer_transaction_id) as Array<{ id: string }>;
      if (matches.length !== 1) {
        continue;
      }
      await this.db
        .query("UPDATE transactions SET transfer_transaction_id = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND plan_id = ?")
        .run(matches[0].id, row.id, planId);
      plan.touchedTransactionIds.add(row.id);
    }
    await this.executeMutationPlan(planId, plan);
  }

  async findDuplicateTransaction(planId: string, input: TransactionInput): Promise<any | null> {
    if (input.import_id && input.account_id) {
      const importMatch = await this.findTransactionByImportId(planId, input.import_id, input.account_id);
      if (importMatch) {
        return importMatch;
      }
    }

    const clauses = ["t.plan_id = ?", "t.deleted = 0", "t.account_id = ?", "t.date = ?", "t.amount_milli = ?"];
    const params: any[] = [planId, input.account_id, input.date, input.amount];
    let hasStrongMatch = false;

    if (input.payee_id) {
      clauses.push("t.payee_id = ?");
      params.push(input.payee_id);
      hasStrongMatch = true;
    } else if (input.payee_name) {
      clauses.push("lower(COALESCE(p.name, t.payee_name_snapshot, '')) = lower(?)");
      params.push(input.payee_name);
      hasStrongMatch = true;
    } else if (input.memo) {
      clauses.push("COALESCE(t.memo, '') = ?");
      params.push(input.memo);
      hasStrongMatch = true;
    } else if (input.category_id) {
      clauses.push("t.category_id = ?");
      params.push(input.category_id);
      hasStrongMatch = true;
    }

    if (!hasStrongMatch) {
      return null;
    }

    const row = await this.db
      .query(
        `SELECT
           t.*,
           a.name AS account_name,
           p.name AS payee_name,
           c.name AS category_name
         FROM transactions t
         JOIN accounts a ON a.id = t.account_id
         LEFT JOIN payees p ON p.id = t.payee_id
         LEFT JOIN categories c ON c.id = t.category_id
         WHERE ${clauses.join(" AND ")}
         ORDER BY t.updated_at DESC
         LIMIT 1`,
      )
      .get(...params) as Row | null;

    return row ? await this.formatTransaction(row) : null;
  }

  async findTransactionByImportId(planId: string, importId: string, accountId: string): Promise<any | null> {
    const row = await this.db
      .query(
        `SELECT
           t.*,
           a.name AS account_name,
           p.name AS payee_name,
           c.name AS category_name
         FROM transactions t
         JOIN accounts a ON a.id = t.account_id
         LEFT JOIN payees p ON p.id = t.payee_id
         LEFT JOIN categories c ON c.id = t.category_id
         WHERE t.plan_id = ? AND t.account_id = ? AND t.import_id = ? AND t.deleted = 0
         ORDER BY t.updated_at DESC
         LIMIT 1`,
      )
      .get(planId, accountId, importId) as Row | null;

    return row ? await this.formatTransaction(row) : null;
  }

  private async getTransactionRow(planId: string, transactionId: string, includeDeleted = false): Promise<Row | null> {
    const clauses = ["t.plan_id = ?", "t.id = ?"];
    if (!includeDeleted) {
      clauses.push("t.deleted = 0");
    }
    return await this.db
      .query(
        `SELECT
           t.*,
           a.name AS account_name,
           p.name AS payee_name,
           c.name AS category_name,
           linked_sub.transaction_id AS parent_transaction_id
         FROM transactions t
         JOIN accounts a ON a.id = t.account_id
         LEFT JOIN payees p ON p.id = t.payee_id
         LEFT JOIN categories c ON c.id = t.category_id
         LEFT JOIN subtransactions linked_sub ON linked_sub.id = t.transfer_transaction_id AND linked_sub.deleted = 0
         WHERE ${clauses.join(" AND ")}
         LIMIT 1`,
      )
      .get(planId, transactionId) as Row | null;
  }

  private async formatTransaction(row: Row): Promise<any> {
    const subtransactions = await this.db
      .query(
        `SELECT
           st.*,
           p.name AS payee_name,
           c.name AS category_name
         FROM subtransactions st
         LEFT JOIN payees p ON p.id = st.payee_id
         LEFT JOIN categories c ON c.id = st.category_id
         WHERE st.transaction_id = ? AND st.deleted = 0
         ORDER BY st.created_at, st.id`,
      )
      .all(row.id) as Row[];

    return this.formatTransactionRow(row, subtransactions);
  }

  /** Loads split lines in bounded batches so a full ledger list is not N+1 queries. */
  private async formatTransactions(rows: Row[]): Promise<any[]> {
    if (rows.length === 0) return [];
    // D1 supports at most 100 bound parameters per statement. Leave room for
    // future predicates rather than relying on the exact limit.
    const batchSize = 90;
    const subtransactionRows: Row[] = [];
    for (let offset = 0; offset < rows.length; offset += batchSize) {
      const ids = rows.slice(offset, offset + batchSize).map((row) => row.id);
      const placeholders = ids.map(() => "?").join(", ");
      subtransactionRows.push(...await this.db
        .query(
          `${SUBTRANSACTION_SELECT_SQL}
           WHERE st.transaction_id IN (${placeholders}) AND st.deleted = 0
           ORDER BY st.transaction_id, st.created_at, st.id`,
        )
        .all(...ids) as Row[]);
    }
    return assembleTransactions(rows, subtransactionRows, (row, subtransactions) => this.formatTransactionRow(row, subtransactions));
  }

  private formatTransactionRow(row: Row, subtransactions: Row[]): any {
    return {
      id: row.id,
      date: row.date,
      amount: Number(row.amount_milli),
      memo: row.memo,
      cleared: row.cleared,
      approved: toBoolean(row.approved),
      flag_color: row.flag_color,
      flag_name: row.flag_name,
      account_id: row.account_id,
      account_name: displayAccountName(row.account_name),
      payee_id: row.payee_id,
      payee_name: row.payee_name ?? row.payee_name_snapshot,
      category_id: row.category_id,
      // Split parents report the YNAB-style synthetic category label.
      category_name: subtransactions.length > 0 ? "Split" : (row.category_name ?? row.category_name_snapshot),
      transfer_account_id: row.transfer_account_id,
      transfer_transaction_id: row.transfer_transaction_id,
      parent_transaction_id: row.parent_transaction_id ?? null,
      matched_transaction_id: row.matched_transaction_id,
      import_id: row.import_id,
      import_payee_name: row.import_payee_name,
      import_payee_name_original: row.import_payee_name_original,
      deleted: toBoolean(row.deleted),
      subtransactions: subtransactions.map((sub) => ({
        id: sub.id,
        transaction_id: row.id,
        amount: Number(sub.amount_milli),
        memo: sub.memo,
        payee_id: sub.payee_id,
        payee_name: sub.payee_name ?? sub.payee_name_snapshot,
        category_id: sub.category_id,
        category_name: sub.category_name ?? sub.category_name_snapshot,
        transfer_account_id: sub.transfer_account_id,
        transfer_transaction_id: sub.transfer_transaction_id,
        deleted: toBoolean(sub.deleted),
      })),
    };
  }

  private async recalculateAccount(accountId: string): Promise<void> {
    const row = await this.db
      .query(
        `SELECT
           a.opening_balance_milli +
             COALESCE(SUM(CASE WHEN t.deleted = 0 THEN t.amount_milli ELSE 0 END), 0) AS balance,
           a.opening_balance_milli +
             COALESCE(SUM(CASE WHEN t.deleted = 0 AND t.cleared IN ('cleared', 'reconciled') THEN t.amount_milli ELSE 0 END), 0) AS cleared,
           COALESCE(SUM(CASE WHEN t.deleted = 0 AND t.cleared = 'uncleared' THEN t.amount_milli ELSE 0 END), 0) AS uncleared
         FROM accounts a
         LEFT JOIN transactions t ON t.account_id = a.id
         WHERE a.id = ?
         GROUP BY a.id`,
      )
      .get(accountId) as Row | null;

    if (!row) {
      return;
    }

    await this.db
      .query(
        `UPDATE accounts
         SET balance_milli = ?, cleared_balance_milli = ?, uncleared_balance_milli = ?, updated_at = CURRENT_TIMESTAMP
         WHERE id = ?`,
      )
      .run(Number(row.balance ?? 0), Number(row.cleared ?? 0), Number(row.uncleared ?? 0), accountId);
  }
}

function groupScheduledSubtransactions(subtransactions: any[]): Map<string, any[]> {
  const grouped = new Map<string, any[]>();
  for (const subtransaction of subtransactions) {
    const parentId = String(subtransaction.scheduled_transaction_id ?? "");
    if (!parentId || subtransaction.deleted) continue;
    const rows = grouped.get(parentId) ?? [];
    rows.push(subtransaction);
    grouped.set(parentId, rows);
  }
  return grouped;
}

function projectScheduledPayload(payloadJson: string, subtransactions: any[], deleted?: unknown): any {
  const payload = parseRawYnabObject(payloadJson, "scheduled transaction");
  return {
    ...payload,
    deleted: Boolean(payload.deleted ?? deleted),
    subtransactions: subtransactions.map((subtransaction) => ({
      ...subtransaction,
      deleted: Boolean(subtransaction.deleted),
    })),
  };
}

function projectScheduledRead(transaction: { payload: Record<string, any>; subtransactions: Record<string, any>[] }): any {
  return {
    ...transaction.payload,
    deleted: Boolean(transaction.payload.deleted),
    subtransactions: transaction.subtransactions.map((subtransaction) => ({
      ...subtransaction,
      deleted: Boolean(subtransaction.deleted),
    })),
  };
}

function scheduleMutationFingerprint(action: string, planId: string, id: string, payload: unknown): string {
  return scheduleDigest(canonicalScheduleJson({ action, planId, id, payload }));
}

function scheduleDigest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function scheduledCronOccurrenceOperationId(runOperationId: string, scheduleId: string, occurrenceDate: string): string {
  return `cron_occurrence_${scheduleDigest(`${runOperationId}:${scheduleId}:${occurrenceDate}`).slice(0, 32)}`;
}

function scheduledOccurrenceTransactionId(planId: string, scheduleId: string, occurrenceDate: string): string {
  return `txn_scheduled_${scheduleDigest(`${planId}:${scheduleId}:${occurrenceDate}`).slice(0, 24)}`;
}

function scheduledOccurrenceSubtransactionId(planId: string, scheduleId: string, occurrenceDate: string, subtransactionId: string): string {
  return `sub_scheduled_${scheduleDigest(`${planId}:${scheduleId}:${occurrenceDate}:${subtransactionId}`).slice(0, 24)}`;
}

function scheduledOccurrenceSnapshotHash(schedule: EffectiveScheduledTransaction): string {
  const fields = [
    "id", "account_id", "date_first", "date_next", "frequency", "amount", "payee_id",
    "category_id", "transfer_account_id", "memo", "flag_color", "subtransactions",
  ];
  return scheduleDigest(canonicalScheduleJson(Object.fromEntries(fields.map((field) => [field, schedule[field] ?? null])))).slice(0, 24);
}

function assertExpectedSchedule(payload: Record<string, any>, expected: ScheduledWriteOptions["expected"]): void {
  if (!expected) return;
  if (payload.date_first !== expected.date_first || payload.date_next !== expected.date_next || payload.frequency !== expected.frequency) {
    throw new Error("stale scheduled occurrence");
  }
}

function canonicalScheduleJson(value: unknown): string {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalScheduleJson).join(",")}]`;
  return `{${Object.keys(value as Record<string, unknown>).filter((key) => (value as any)[key] !== undefined).sort().map((key) => `${JSON.stringify(key)}:${canonicalScheduleJson((value as any)[key])}`).join(",")}}`;
}

export class NotFoundError extends Error {}

/**
 * Reads no longer create the plan they are asked about, so a caller can name
 * one that does not exist. This inherits the 404 `resource_not_found` mapping
 * in `http.ts` while staying greppable.
 */
export class PlanNotFoundError extends NotFoundError {
  constructor(message = "Plan not found") {
    super(message);
  }
}

export class ValidationError extends Error {}

export class AccountPreferencesConflictError extends Error {}

export class TransactionStateConflictError extends Error {
  constructor(message = "Transaction cleared status changed; refresh and try again") {
    super(message);
  }
}

export class ReconciliationMismatchError extends Error {
  readonly difference: number;

  constructor(
    readonly currentReconciledBalance: number,
    readonly projectedReconciledBalance: number,
    readonly statementBalance: number,
  ) {
    super("Statement balance does not match the projected reconciled balance");
    this.difference = statementBalance - projectedReconciledBalance;
  }
}

function normaliseReconciliationDate(value: unknown): string {
  if (typeof value !== "string" || !/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/.test(value)) {
    throw new ValidationError("statement_date must be an ISO date (YYYY-MM-DD)");
  }
  const date = new Date(`${value}T00:00:00Z`);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== value) throw new ValidationError("statement_date must be a valid calendar date");
  return value;
}

const CLEARED_STATES = new Set(["cleared", "uncleared", "reconciled"]);

function validateTransactionInput(input: TransactionInput, strict: boolean): void {
  if (!input.account_id || typeof input.account_id !== "string") {
    throw new ValidationError("account_id is required");
  }
  if (!input.date || (strict && !/^\d{4}-\d{2}-\d{2}$/.test(String(input.date)))) {
    // Importers (strict=false) keep accepting the loose date spellings they
    // always stored verbatim; API writes must be ISO.
    throw new ValidationError("date must be an ISO date (YYYY-MM-DD)");
  }
  if (typeof input.amount !== "number" || !Number.isInteger(input.amount)) {
    throw new ValidationError("amount must be integer milliunits");
  }
  if (input.cleared != null && !CLEARED_STATES.has(input.cleared)) {
    throw new ValidationError("cleared must be one of cleared, uncleared, reconciled");
  }

  const subtransactions = input.subtransactions ?? [];
  if (strict && subtransactions.length > 0) {
    if (subtransactions.length < 2) {
      throw new ValidationError("split transactions need at least two subtransactions");
    }
    for (const sub of subtransactions) {
      if (typeof sub.amount !== "number" || !Number.isInteger(sub.amount)) {
        throw new ValidationError("subtransaction amounts must be integer milliunits");
      }
    }
    const total = subtransactions.reduce((sum, sub) => sum + sub.amount, 0);
    if (total !== input.amount) {
      throw new ValidationError(
        `subtransactions must sum to the transaction amount (lines total ${total}, transaction is ${input.amount})`,
      );
    }
  }
}

function formatPlan(row: Row): any {
  return {
    id: row.id,
    name: row.name,
    last_modified_on: row.updated_at,
    first_month: row.first_month,
    last_month: row.last_month,
    date_format: JSON.parse(row.date_format_json),
    currency_format: JSON.parse(row.currency_format_json),
    server_knowledge: Number(row.server_knowledge),
  };
}

/**
 * Every non-search WHERE clause a transaction query applies, in one place, so
 * the register page and the unapproved count can never drift apart. `q` is
 * deliberately excluded: it needs the plan's currency format, which costs a
 * round trip the count does not want to pay.
 */
function transactionFilterClauses(planId: string, filters: TransactionFilters): { clauses: string[]; params: any[] } {
    const clauses = ["t.plan_id = ?"];
    const params: any[] = [planId];

    if (!filters.includeDeleted && filters.lastKnowledgeOfServer == null) {
      clauses.push("t.deleted = 0");
    }
    if (filters.sinceDate) {
      clauses.push("t.date >= ?");
      params.push(filters.sinceDate);
    }
    if (filters.untilDate) {
      clauses.push("t.date <= ?");
      params.push(filters.untilDate);
    }
    if (filters.accountId) {
      clauses.push("t.account_id = ?");
      params.push(filters.accountId);
    }
    if (filters.payeeId) {
      clauses.push("t.payee_id = ?");
      params.push(filters.payeeId);
    }
    if (filters.categoryId) {
      clauses.push("t.category_id = ?");
      params.push(filters.categoryId);
    }
    if (filters.month) {
      const monthStart = normaliseMonthStart(filters.month);
      clauses.push("t.date >= ? AND t.date < date(?, '+1 month')");
      params.push(monthStart, monthStart);
    }
    if (filters.type === "uncategorized") {
      clauses.push("t.category_id IS NULL");
    }
    if (filters.type === "unapproved") {
      clauses.push("t.approved = 0");
    }
    if (filters.type === "approved") {
      clauses.push("t.approved = 1");
    }
    if (filters.lastKnowledgeOfServer != null) {
      clauses.push("t.server_knowledge > ?");
      params.push(filters.lastKnowledgeOfServer);
    }
  return { clauses, params };
}

const SERVER_KNOWLEDGE_SQL = "SELECT server_knowledge FROM plans WHERE id = ?";
// `deleted = 0` is written literally so the partial index
// `idx_transactions_plan_live_register` stays eligible for the window scan.
const ACCOUNT_USAGE_SQL = `SELECT account_id, COUNT(*) AS usage_count
     FROM transactions
     WHERE plan_id = ? AND deleted = 0 AND date >= ? AND date <= ?
     GROUP BY account_id
     ORDER BY account_id`;
const LIST_PAYEES_SQL = "SELECT id, name, transfer_account_id, deleted FROM payees WHERE plan_id = ? AND deleted = 0 ORDER BY name";
const LIST_CATEGORY_GROUPS_SQL = "SELECT * FROM category_groups WHERE plan_id = ? AND deleted = 0 ORDER BY name";
const LIST_CATEGORIES_SQL = "SELECT * FROM categories WHERE plan_id = ? AND deleted = 0 ORDER BY name";

/** The four row sets an effective schedule list is projected from, in order. */
const SCHEDULED_SQL = [
  "SELECT object_id,payload_json,deleted FROM ynab_raw_objects WHERE plan_id=? AND object_type='scheduled_transaction' ORDER BY object_id",
  "SELECT payload_json FROM ynab_raw_objects WHERE plan_id=? AND object_type='scheduled_subtransaction' ORDER BY object_id",
  "SELECT id,payload_json,deleted FROM scheduled_transaction_edits WHERE plan_id=? ORDER BY id",
  "SELECT scheduled_transaction_id,payload_json FROM scheduled_subtransaction_edits WHERE plan_id=? ORDER BY scheduled_transaction_id,id",
];

/** Reads the knowledge value out of a batched SELECT; a missing plan is a 404. */
function knowledgeFrom(rows: Row[] | undefined): number {
  const row = rows?.[0];
  if (!row) throw new PlanNotFoundError();
  return Number(row.server_knowledge);
}

/** Nests categories under their groups by a single pass over each list. */
function assembleCategoryGroups(groups: Row[], categories: Row[]): any[] {
  const byGroup = new Map<string, Row[]>();
  for (const category of categories) {
    const key = String(category.category_group_id);
    const existing = byGroup.get(key);
    if (existing) existing.push(category);
    else byGroup.set(key, [category]);
  }
  return groups.map((group) => ({
    id: group.id,
    name: group.name,
    hidden: toBoolean(group.hidden),
    deleted: toBoolean(group.deleted),
    categories: (byGroup.get(String(group.id)) ?? []).map(formatCategory),
  }));
}

/** Pure projection of the four schedule row sets into effective schedules. */
function assembleScheduledTransactions(rawParents: Row[], rawSubs: Row[], editRows: Row[], editSubRows: Row[]): any[] {
    const sourceSubs = groupScheduledSubtransactions(rawSubs.map((row) => parseRawYnabObject(row.payload_json, "scheduled subtransaction")));
    const editedSubs = groupScheduledSubtransactions(editSubRows.map((row) => parseRawYnabObject(row.payload_json, "scheduled subtransaction")));
    const edits = new Map(editRows.map((row) => [String(row.id), row]));
    const result: any[] = [];

    for (const row of rawParents) {
      const id = String(row.object_id);
      const edit = edits.get(id);
      edits.delete(id);
      if (edit) {
        if (!Boolean(edit.deleted)) result.push(projectScheduledPayload(edit.payload_json, editedSubs.get(id) ?? [], edit.deleted));
      } else if (!Boolean(row.deleted)) {
        result.push(projectScheduledPayload(row.payload_json, sourceSubs.get(id) ?? [], row.deleted));
      }
    }
    for (const [id, edit] of edits) {
      if (!Boolean(edit.deleted)) result.push(projectScheduledPayload(edit.payload_json, editedSubs.get(id) ?? [], edit.deleted));
    }
    return result.sort((left, right) => String(left.date_next ?? left.date_first ?? "9999-12-31").localeCompare(String(right.date_next ?? right.date_first ?? "9999-12-31")) || String(left.id).localeCompare(String(right.id)));
}


/** Split lines with their payee and category names; callers add the WHERE. */
const SUBTRANSACTION_SELECT_SQL = `SELECT
             st.*,
             p.name AS payee_name,
             c.name AS category_name
           FROM subtransactions st
           LEFT JOIN payees p ON p.id = st.payee_id
           LEFT JOIN categories c ON c.id = st.category_id`;

/**
 * Joins transaction rows to their split lines. Pure: both row sets are already
 * in hand, so the same assembly serves the batched page and the chunked
 * fetch the unpaged list still uses.
 */
function assembleTransactions(
  rows: Row[],
  subtransactionRows: Row[],
  format: (row: Row, subtransactions: Row[]) => any,
): any[] {
  const byTransaction = new Map<string, Row[]>();
  for (const subtransaction of subtransactionRows) {
    const key = String(subtransaction.transaction_id);
    const existing = byTransaction.get(key);
    if (existing) existing.push(subtransaction);
    else byTransaction.set(key, [subtransaction]);
  }
  return rows.map((row) => format(row, byTransaction.get(String(row.id)) ?? []));
}

const ACCOUNT_SELECT_SQL = `SELECT accounts.*, (
  SELECT COALESCE(
    (SELECT MAX(statement_date) FROM account_reconciliation_assertions
      WHERE plan_id = accounts.plan_id AND account_id = accounts.id),
    (SELECT MAX(date) FROM transactions
      WHERE plan_id = accounts.plan_id AND account_id = accounts.id
        AND deleted = 0 AND cleared = 'reconciled')
  )
) AS last_reconciled_date
FROM accounts`;

const LIST_ACCOUNTS_SQL = `${ACCOUNT_SELECT_SQL} WHERE plan_id = ? AND deleted = 0 ORDER BY closed, name`;

function formatAccount(row: Row): any {
  const presentation = resolveAccountPresentation({
    name: row.name,
    existingIcon: row.icon,
    type: row.type,
  });
  return {
    id: row.id,
    name: presentation.name,
    icon: presentation.icon,
    type: row.type,
    on_budget: toBoolean(row.on_budget),
    closed: toBoolean(row.closed),
    balance: Number(row.balance_milli),
    cleared_balance: Number(row.cleared_balance_milli),
    uncleared_balance: Number(row.uncleared_balance_milli),
    last_reconciled_date: row.last_reconciled_date ?? null,
    transfer_payee_id: row.transfer_payee_id,
    direct_import_linked: toBoolean(row.direct_import_linked),
    direct_import_in_error: toBoolean(row.direct_import_in_error),
    deleted: toBoolean(row.deleted),
  };
}

function formatPayee(row: Row): any {
  return {
    id: row.id,
    name: row.name,
    transfer_account_id: row.transfer_account_id,
    deleted: toBoolean(row.deleted),
  };
}

function formatCategory(row: Row): any {
  return {
    id: row.id,
    category_group_id: row.category_group_id,
    name: row.name,
    hidden: toBoolean(row.hidden),
    original_category_group_id: null,
    note: null,
    budgeted: 0,
    activity: 0,
    balance: 0,
    goal_type: null,
    goal_day: null,
    goal_cadence: null,
    goal_cadence_frequency: null,
    goal_creation_month: null,
    goal_target: 0,
    goal_target_month: null,
    goal_percentage_complete: null,
    deleted: toBoolean(row.deleted),
  };
}

function bool(value: unknown, fallback = false): number {
  if (value === undefined || value === null) {
    return fallback ? 1 : 0;
  }
  return value === true || value === 1 ? 1 : 0;
}

function toBoolean(value: unknown): boolean {
  return value === true || value === 1;
}

function parseRawYnabObject(value: unknown, label: string): any {
  try {
    return JSON.parse(String(value));
  } catch {
    // A corrupt mirror must not make a read route quietly return fabricated
    // data.  It is a database-integrity fault and should surface.
    throw new Error(`Stored YNAB ${label} is not valid JSON`);
  }
}

function normaliseMonthStart(month: string): string {
  return month.length === 7 ? `${month}-01` : month;
}
