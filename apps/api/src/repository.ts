import type { Database } from "bun:sqlite";
import { createId } from "./ids";
import { SqliteRepositoryDatabase, type RepositoryDatabase } from "./repository-db";
import type { ClearedState, TransactionFilters, TransactionInput } from "./types";

type Row = Record<string, any>;

export type TransactionWriteOptions = {
  /**
   * When true (the default for API writes), a payee that points at another
   * account creates the linked side of the transfer, YNAB-style. Importers
   * pass false because their data already carries both sides.
   */
  autoLink?: boolean;
};

export class LedgerRepository {
  /**
   * Transaction ids touched by the current write operation. The outermost
   * write stamps them all with one final server_knowledge so incremental
   * clients always receive every side of a transfer in the same delta.
   */
  private touchedTransactionIds: Set<string> | null = null;

  private readonly db: RepositoryDatabase;

  constructor(db: Database | RepositoryDatabase, private readonly defaultPlanId: string) {
    this.db = "run" in db ? new SqliteRepositoryDatabase(db) : db;
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
    await this.ensurePlan(planId);
    const row = await this.db.query("SELECT server_knowledge FROM plans WHERE id = ?").get(planId) as Row;
    return Number(row.server_knowledge);
  }

  async listPlans(): Promise<any[]> {
    return (await this.db.query("SELECT * FROM plans WHERE deleted = 0 ORDER BY name").all()).map(formatPlan);
  }

  async getPlan(planId: string): Promise<any> {
    await this.ensurePlan(planId);
    const row = await this.db.query("SELECT * FROM plans WHERE id = ?").get(planId) as Row;
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
    await this.ensurePlan(planId);
    const row = await this.db.query("SELECT * FROM plans WHERE id = ?").get(planId) as Row;
    return {
      date_format: JSON.parse(row.date_format_json),
      currency_format: JSON.parse(row.currency_format_json),
      display: {
        flag_names: JSON.parse(row.flag_names_json),
      },
    };
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
    await this.db
      .query(
        `INSERT INTO accounts (
           id, plan_id, name, type, on_budget, closed, opening_balance_milli,
           balance_milli, cleared_balance_milli, uncleared_balance_milli,
           transfer_payee_id, direct_import_linked, direct_import_in_error,
           external_ynab_id, deleted, updated_at
         )
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
         ON CONFLICT(id) DO UPDATE SET
           name = excluded.name,
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
        account.name ?? `Account ${account.id}`,
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
  }

  async listAccounts(planId: string): Promise<any[]> {
    await this.ensurePlan(planId);
    return (await this.db
      .query("SELECT * FROM accounts WHERE plan_id = ? AND deleted = 0 ORDER BY closed, name")
      .all(planId)).map(formatAccount);
  }

  async getAccount(planId: string, accountId: string): Promise<any> {
    await this.ensureAccount(planId, accountId);
    const row = await this.db.query("SELECT * FROM accounts WHERE id = ? AND plan_id = ?").get(accountId, planId) as Row;
    return formatAccount(row);
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
  }

  async listPayees(planId: string): Promise<any[]> {
    await this.ensurePlan(planId);
    return (await this.db
      .query("SELECT * FROM payees WHERE plan_id = ? AND deleted = 0 ORDER BY name")
      .all(planId)).map(formatPayee);
  }

  async ensureCategory(planId: string, categoryId: string, name?: string, groupId?: string | null): Promise<void> {
    await this.ensurePlan(planId);
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
    await this.ensurePlan(planId);
    const groups = await this.db
      .query("SELECT * FROM category_groups WHERE plan_id = ? AND deleted = 0 ORDER BY name")
      .all(planId) as Row[];
    const categories = await this.db
      .query("SELECT * FROM categories WHERE plan_id = ? AND deleted = 0 ORDER BY name")
      .all(planId) as Row[];

    return groups.map((group) => ({
      id: group.id,
      name: group.name,
      hidden: toBoolean(group.hidden),
      deleted: toBoolean(group.deleted),
      categories: categories.filter((category) => category.category_group_id === group.id).map(formatCategory),
    }));
  }

  async createTransaction(planId: string, input: TransactionInput, options: TransactionWriteOptions = {}): Promise<any> {
    await this.ensurePlan(planId);
    const autoLink = options.autoLink ?? true;
    validateTransactionInput(input, autoLink);
    const transactionId = input.id ?? createId("txn");
    const ownsTouched = this.beginTouched();

    try {
      await this.db.transaction(async () => {
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
            sourceAccountId: input.account_id,
            accountId: subTransferAccountId ?? undefined,
          });
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
            });
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
          await this.softDeleteLinkedTransaction(planId, previous.transfer_transaction_id);
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
        });
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
          sourceAccountId: input.account_id,
          accountId: transferAccountId ?? undefined,
        });
      }

      await this.recalculateAccount(input.account_id);
      if (existingRow && existingRow.account_id !== input.account_id) {
        await this.recalculateAccount(existingRow.account_id);
      }
      this.markTouched(transactionId);
      if (ownsTouched) {
        await this.commitTouched(planId);
      }
      })();
    } finally {
      if (ownsTouched) {
        this.touchedTransactionIds = null;
      }
    }

    return this.getTransaction(planId, transactionId, bool(input.deleted) === 1);
  }

  async updateTransaction(planId: string, transactionId: string, patch: Partial<TransactionInput>): Promise<any> {
    const existing = await this.getTransactionRow(planId, transactionId);
    if (!existing) {
      throw new NotFoundError("Transaction not found");
    }
    const existingTransaction = await this.getTransaction(planId, transactionId);

    // The linked side of a split line cannot restate the transfer itself —
    // its amount/date/accounts live on the split. Cosmetic edits are fine.
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
      import_id: patch.import_id === undefined ? existing.import_id : patch.import_id,
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

    const ownsTouched = this.beginTouched();
    try {
      await this.db.transaction(async () => {
        // Transfer link management (YNAB): changing the payee can break or
        // move the linked side; every other edit keeps both sides in step
        // (createTransaction syncs a kept link itself).
        const linkedRow = existing.transfer_transaction_id
          ? await this.getTransactionRow(planId, existing.transfer_transaction_id)
          : null;
        if (linkedRow && patch.payee_id !== undefined) {
          const nextTarget = patch.payee_id ? await this.payeeTransferTarget(planId, patch.payee_id) : null;
          if (!nextTarget || nextTarget === next.account_id) {
            // No longer a transfer: the linked side goes away.
            await this.softDeleteLinkedTransaction(planId, linkedRow.id);
            next.transfer_account_id = null;
            next.transfer_transaction_id = null;
          } else {
            next.transfer_account_id = nextTarget;
          }
        }

        await this.createTransaction(planId, next);
        if (existing.account_id !== next.account_id) {
          await this.recalculateAccount(existing.account_id);
        }
        if (ownsTouched) {
          await this.commitTouched(planId);
        }
      })();
    } finally {
      if (ownsTouched) {
        this.touchedTransactionIds = null;
      }
    }
    return this.getTransaction(planId, transactionId);
  }

  async deleteTransaction(planId: string, transactionId: string): Promise<any> {
    const existing = await this.getTransactionRow(planId, transactionId);
    if (!existing) {
      throw new NotFoundError("Transaction not found");
    }

    await this.db.transaction(async () => {
      const removeIds = new Set<string>([transactionId]);
      const stampIds = new Set<string>([transactionId]);
      const accountIds = new Set<string>([existing.account_id]);

      // Deleting one side of a transfer deletes the other (YNAB behaviour)...
      if (existing.transfer_transaction_id) {
        const linked = await this.getTransactionRow(planId, existing.transfer_transaction_id);
        if (linked) {
          removeIds.add(linked.id);
          stampIds.add(linked.id);
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
            stampIds.add(sub.transaction_id);
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
          stampIds.add(linked.id);
          accountIds.add(linked.account_id);
        }
      }

      for (const id of removeIds) {
        await this.db
          .query("UPDATE transactions SET deleted = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND plan_id = ?")
          .run(id, planId);
      }
      for (const accountId of accountIds) {
        await this.recalculateAccount(accountId);
      }
      const serverKnowledge = await this.touchPlan(planId);
      for (const id of stampIds) {
        await this.db
          .query("UPDATE transactions SET server_knowledge = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND plan_id = ?")
          .run(serverKnowledge, id, planId);
      }
    })();

    return this.getTransaction(planId, transactionId, true);
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
    await this.ensurePlan(planId);
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

    const rows = await this.db
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
         ORDER BY t.date DESC, t.created_at DESC`,
      )
      .all(...params) as Row[];

    return this.formatTransactions(rows);
  }

  async getTransaction(planId: string, transactionId: string, includeDeleted = false): Promise<any> {
    const row = await this.getTransactionRow(planId, transactionId, includeDeleted);
    if (!row) {
      throw new NotFoundError("Transaction not found");
    }
    return this.formatTransaction(row);
  }

  async getMonth(planId: string, month: string): Promise<any> {
    await this.ensurePlan(planId);
    const start = month.length === 7 ? `${month}-01` : month;
    const categoryRows = await this.db
      .query(
        `WITH lines AS (
           SELECT
             t.date,
             COALESCE(st.category_id, t.category_id) AS category_id,
             COALESCE(st.amount_milli, t.amount_milli) AS amount_milli
           FROM transactions t
           LEFT JOIN subtransactions st ON st.transaction_id = t.id AND st.deleted = 0
           WHERE t.plan_id = ?
             AND t.deleted = 0
             AND t.date >= ?
             AND t.date < date(?, '+1 month')
         )
         SELECT
           c.id,
           c.name,
           c.category_group_id,
           SUM(lines.amount_milli) AS activity
         FROM categories c
         LEFT JOIN lines ON lines.category_id = c.id
         WHERE c.plan_id = ? AND c.deleted = 0
         GROUP BY c.id
         ORDER BY c.name`,
      )
      .all(planId, start, start, planId) as Row[];

    return {
      month: start,
      note: null,
      income: 0,
      budgeted: 0,
      activity: categoryRows.reduce((total, row) => total + Number(row.activity ?? 0), 0),
      to_be_budgeted: 0,
      age_of_money: null,
      deleted: false,
      categories: categoryRows.map((row) => ({
        id: row.id,
        name: row.name,
        category_group_id: row.category_group_id,
        activity: Number(row.activity ?? 0),
        budgeted: 0,
        balance: 0,
        deleted: false,
      })),
    };
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

  async listYnabTransactionFingerprints(planId: string): Promise<Array<{ external_ynab_id: string; date: string; amount_milli: number }>> {
    return await this.db
      .query(
        `SELECT external_ynab_id, date, amount_milli
         FROM transactions
         WHERE plan_id = ? AND source_kind = 'ynab-import' AND external_ynab_id IS NOT NULL`,
      )
      .all(planId) as Array<{ external_ynab_id: string; date: string; amount_milli: number }>;
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
      sourceAccountId: string;
      linkId: string;
    },
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
         VALUES (?, ?, ?, ?, ?, ?, 'uncleared', ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)`,
      )
      .run(
        id,
        planId,
        opts.accountId,
        opts.date,
        opts.amount,
        opts.memo,
        bool(opts.approved),
        payee?.id ?? null,
        payee?.name ?? null,
        opts.sourceAccountId,
        opts.linkId,
      );
    await this.recalculateAccount(opts.accountId);
    this.markTouched(id);
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
      sourceAccountId: string;
      accountId?: string;
    },
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
             payee_id = ?, payee_name_snapshot = ?, transfer_account_id = ?,
             updated_at = CURRENT_TIMESTAMP
         WHERE id = ? AND plan_id = ?`,
      )
      .run(
        nextAccountId,
        opts.date,
        opts.amount,
        opts.memo,
        payee?.id ?? linked.payee_id,
        payee?.name ?? linked.payee_name_snapshot,
        opts.sourceAccountId,
        linkedTransactionId,
        planId,
      );
    await this.recalculateAccount(linked.account_id);
    if (nextAccountId !== linked.account_id) {
      await this.recalculateAccount(nextAccountId);
    }
    this.markTouched(linkedTransactionId);
  }

  private async softDeleteLinkedTransaction(planId: string, linkedTransactionId: string): Promise<void> {
    const linked = await this.getTransactionRow(planId, linkedTransactionId);
    if (!linked) {
      return;
    }
    await this.db
      .query("UPDATE transactions SET deleted = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND plan_id = ?")
      .run(linkedTransactionId, planId);
    await this.recalculateAccount(linked.account_id);
    this.markTouched(linkedTransactionId);
  }

  /** Starts a touched-ids collection unless a caller already owns one. */
  private beginTouched(): boolean {
    if (this.touchedTransactionIds) {
      return false;
    }
    this.touchedTransactionIds = new Set();
    return true;
  }

  private markTouched(transactionId: string): void {
    this.touchedTransactionIds?.add(transactionId);
  }

  /** Stamps every touched row with a single fresh server_knowledge. */
  private async commitTouched(planId: string): Promise<void> {
    const touched = this.touchedTransactionIds;
    if (!touched?.size) {
      return;
    }
    const serverKnowledge = await this.touchPlan(planId);
    for (const id of touched) {
      await this.db
        .query("UPDATE transactions SET server_knowledge = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND plan_id = ?")
        .run(serverKnowledge, id, planId);
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

  async findDuplicateTransaction(planId: string, input: TransactionInput): Promise<any | null> {
    if (input.import_id) {
      const importMatch = await this.findTransactionByImportId(planId, input.import_id);
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

  async findTransactionByImportId(planId: string, importId: string): Promise<any | null> {
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
         WHERE t.plan_id = ? AND t.import_id = ? AND t.deleted = 0
         ORDER BY t.updated_at DESC
         LIMIT 1`,
      )
      .get(planId, importId) as Row | null;

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
           c.name AS category_name
         FROM transactions t
         JOIN accounts a ON a.id = t.account_id
         LEFT JOIN payees p ON p.id = t.payee_id
         LEFT JOIN categories c ON c.id = t.category_id
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
    const byTransaction = new Map<string, Row[]>();
    const batchSize = 500;
    for (let offset = 0; offset < rows.length; offset += batchSize) {
      const ids = rows.slice(offset, offset + batchSize).map((row) => row.id);
      const placeholders = ids.map(() => "?").join(", ");
      const subtransactions = await this.db
        .query(
          `SELECT
             st.*,
             p.name AS payee_name,
             c.name AS category_name
           FROM subtransactions st
           LEFT JOIN payees p ON p.id = st.payee_id
           LEFT JOIN categories c ON c.id = st.category_id
           WHERE st.transaction_id IN (${placeholders}) AND st.deleted = 0
           ORDER BY st.transaction_id, st.created_at, st.id`,
        )
        .all(...ids) as Row[];
      for (const subtransaction of subtransactions) {
        const existing = byTransaction.get(subtransaction.transaction_id) ?? [];
        existing.push(subtransaction);
        byTransaction.set(subtransaction.transaction_id, existing);
      }
    }
    return rows.map((row) => this.formatTransactionRow(row, byTransaction.get(row.id) ?? []));
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
      account_name: row.account_name,
      payee_id: row.payee_id,
      payee_name: row.payee_name ?? row.payee_name_snapshot,
      category_id: row.category_id,
      // Split parents report the YNAB-style synthetic category label.
      category_name: subtransactions.length > 0 ? "Split" : (row.category_name ?? row.category_name_snapshot),
      transfer_account_id: row.transfer_account_id,
      transfer_transaction_id: row.transfer_transaction_id,
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

export class NotFoundError extends Error {}

export class ValidationError extends Error {}

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

function formatAccount(row: Row): any {
  return {
    id: row.id,
    name: row.name,
    type: row.type,
    on_budget: toBoolean(row.on_budget),
    closed: toBoolean(row.closed),
    balance: Number(row.balance_milli),
    cleared_balance: Number(row.cleared_balance_milli),
    uncleared_balance: Number(row.uncleared_balance_milli),
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

function normaliseMonthStart(month: string): string {
  return month.length === 7 ? `${month}-01` : month;
}
