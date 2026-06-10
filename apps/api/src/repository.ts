import type { Database } from "bun:sqlite";
import { createId } from "./ids";
import type { ClearedState, TransactionFilters, TransactionInput } from "./types";

type Row = Record<string, any>;

export class LedgerRepository {
  constructor(
    private readonly db: Database,
    private readonly defaultPlanId: string,
  ) {}

  getDefaultPlanId(): string {
    return this.defaultPlanId;
  }

  ensurePlan(planId = this.defaultPlanId, name = "HowMuch"): void {
    this.db
      .query(
        `INSERT INTO plans (id, name, external_ynab_id, first_month, last_month)
         VALUES (?, ?, ?, strftime('%Y-%m', 'now'), strftime('%Y-%m', 'now'))
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(planId, name, planId);
  }

  touchPlan(planId: string): number {
    this.ensurePlan(planId);
    const row = this.db
      .query(
        `UPDATE plans
         SET server_knowledge = server_knowledge + 1, updated_at = CURRENT_TIMESTAMP
         WHERE id = ?
         RETURNING server_knowledge`,
      )
      .get(planId) as Row;
    return Number(row.server_knowledge);
  }

  getServerKnowledge(planId: string): number {
    this.ensurePlan(planId);
    const row = this.db.query("SELECT server_knowledge FROM plans WHERE id = ?").get(planId) as Row;
    return Number(row.server_knowledge);
  }

  listPlans(): any[] {
    this.ensurePlan();
    return this.db.query("SELECT * FROM plans WHERE deleted = 0 ORDER BY name").all().map(formatPlan);
  }

  getPlan(planId: string): any {
    this.ensurePlan(planId);
    const row = this.db.query("SELECT * FROM plans WHERE id = ?").get(planId) as Row;
    return formatPlan(row);
  }

  upsertPlan(planId: string, plan: any, settings?: any): void {
    this.ensurePlan(planId, plan.name ?? "HowMuch");
    const existing = this.db.query("SELECT * FROM plans WHERE id = ?").get(planId) as Row;

    this.db
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

  getSettings(planId: string): any {
    this.ensurePlan(planId);
    const row = this.db.query("SELECT * FROM plans WHERE id = ?").get(planId) as Row;
    return {
      date_format: JSON.parse(row.date_format_json),
      currency_format: JSON.parse(row.currency_format_json),
      display: {
        flag_names: JSON.parse(row.flag_names_json),
      },
    };
  }

  ensureAccount(planId: string, accountId: string, name?: string): void {
    this.ensurePlan(planId);
    this.db
      .query(
        `INSERT INTO accounts (id, plan_id, name, external_ynab_id)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(accountId, planId, name ?? `Imported account ${accountId.slice(0, 8)}`, accountId);
  }

  upsertAccount(planId: string, account: any): void {
    this.ensurePlan(planId);
    this.db
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
           transfer_payee_id = excluded.transfer_payee_id,
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
  }

  listAccounts(planId: string): any[] {
    this.ensurePlan(planId);
    return this.db
      .query("SELECT * FROM accounts WHERE plan_id = ? AND deleted = 0 ORDER BY closed, name")
      .all(planId)
      .map(formatAccount);
  }

  getAccount(planId: string, accountId: string): any {
    this.ensureAccount(planId, accountId);
    const row = this.db.query("SELECT * FROM accounts WHERE id = ? AND plan_id = ?").get(accountId, planId) as Row;
    return formatAccount(row);
  }

  createPayee(planId: string, name: string, id = createId("payee")): any {
    this.ensurePlan(planId);
    const existing = this.db
      .query("SELECT * FROM payees WHERE plan_id = ? AND lower(name) = lower(?) AND deleted = 0")
      .get(planId, name) as Row | null;

    if (existing) {
      return formatPayee(existing);
    }

    this.db
      .query("INSERT INTO payees (id, plan_id, name, external_ynab_id) VALUES (?, ?, ?, ?)")
      .run(id, planId, name, id);
    this.touchPlan(planId);
    return formatPayee(this.db.query("SELECT * FROM payees WHERE id = ?").get(id) as Row);
  }

  ensurePayee(planId: string, payeeId: string, name?: string): void {
    this.ensurePlan(planId);
    this.db
      .query(
        `INSERT INTO payees (id, plan_id, name, external_ynab_id)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(payeeId, planId, name ?? `Imported payee ${payeeId.slice(0, 8)}`, payeeId);
  }

  upsertPayee(planId: string, payee: any): void {
    this.ensurePlan(planId);
    this.db
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

  listPayees(planId: string): any[] {
    this.ensurePlan(planId);
    return this.db
      .query("SELECT * FROM payees WHERE plan_id = ? AND deleted = 0 ORDER BY name")
      .all(planId)
      .map(formatPayee);
  }

  ensureCategory(planId: string, categoryId: string, name?: string, groupId?: string | null): void {
    this.ensurePlan(planId);
    const resolvedGroupId = groupId ?? "uncategorized-group";
    this.db
      .query(
        `INSERT INTO category_groups (id, plan_id, name)
         VALUES (?, ?, ?)
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(resolvedGroupId, planId, resolvedGroupId === "uncategorized-group" ? "Uncategorised" : "Imported");

    this.db
      .query(
        `INSERT INTO categories (id, plan_id, category_group_id, name, external_ynab_id)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(id) DO NOTHING`,
      )
      .run(categoryId, planId, resolvedGroupId, name ?? `Imported category ${categoryId.slice(0, 8)}`, categoryId);
  }

  upsertCategoryGroup(planId: string, group: any): void {
    this.ensurePlan(planId);
    this.db
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

  upsertCategory(planId: string, category: any, groupId?: string | null): void {
    this.ensureCategory(planId, category.id, category.name, groupId);
    this.db
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

  listCategoryGroups(planId: string): any[] {
    this.ensurePlan(planId);
    const groups = this.db
      .query("SELECT * FROM category_groups WHERE plan_id = ? AND deleted = 0 ORDER BY name")
      .all(planId) as Row[];
    const categories = this.db
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

  createTransaction(planId: string, input: TransactionInput): any {
    this.ensurePlan(planId);
    const transactionId = input.id ?? createId("txn");

    this.db.transaction(() => {
      this.ensureAccount(planId, input.account_id);
      const refs = this.resolveTransactionRefs(planId, input);
      this.db
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
          refs.payeeId,
          refs.payeeName,
          refs.categoryId,
          refs.categoryName,
          input.transfer_account_id ?? null,
          input.transfer_transaction_id ?? null,
          input.matched_transaction_id ?? null,
          input.import_id ?? null,
          input.import_payee_name ?? null,
          input.import_payee_name_original ?? null,
          input.source_kind ?? null,
          input.source_ref ?? null,
          input.external_ynab_id ?? input.id ?? null,
          bool(input.deleted),
        );

      this.db.query("DELETE FROM subtransactions WHERE transaction_id = ?").run(transactionId);
      for (const sub of input.subtransactions ?? []) {
        const subRefs = this.resolveTransactionRefs(planId, {
          account_id: input.account_id,
          date: input.date,
          amount: sub.amount,
          payee_id: sub.payee_id,
          payee_name: sub.payee_name,
          category_id: sub.category_id,
          memo: sub.memo,
        });
        this.db
          .query(
            `INSERT INTO subtransactions (
               id, transaction_id, amount_milli, memo, payee_id, payee_name_snapshot,
               category_id, category_name_snapshot, transfer_account_id,
               transfer_transaction_id, external_ynab_id, deleted, updated_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, CURRENT_TIMESTAMP)`,
          )
          .run(
            sub.id ?? createId("sub"),
            transactionId,
            sub.amount,
            sub.memo ?? null,
            subRefs.payeeId,
            subRefs.payeeName,
            subRefs.categoryId,
            subRefs.categoryName,
            sub.transfer_account_id ?? null,
            sub.transfer_transaction_id ?? null,
            sub.external_ynab_id ?? sub.id ?? null,
          );
      }

      if (input.source_kind || input.source_ref) {
        this.db
          .query(
            `INSERT INTO source_events (id, plan_id, transaction_id, source_kind, source_ref, payload_json)
             VALUES (?, ?, ?, ?, ?, ?)`,
          )
          .run(createId("src"), planId, transactionId, input.source_kind ?? "api", input.source_ref ?? null, JSON.stringify(input));
      }

      this.recalculateAccount(input.account_id);
      const serverKnowledge = this.touchPlan(planId);
      this.db
        .query("UPDATE transactions SET server_knowledge = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?")
        .run(serverKnowledge, transactionId);
    })();

    return this.getTransaction(planId, transactionId, bool(input.deleted));
  }

  updateTransaction(planId: string, transactionId: string, patch: Partial<TransactionInput>): any {
    const existing = this.getTransactionRow(planId, transactionId);
    if (!existing) {
      throw new NotFoundError("Transaction not found");
    }
    const existingTransaction = this.getTransaction(planId, transactionId);

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

    const updated = this.createTransaction(planId, next);
    if (existing.account_id !== next.account_id) {
      this.recalculateAccount(existing.account_id);
    }
    return updated;
  }

  deleteTransaction(planId: string, transactionId: string): any {
    const existing = this.getTransactionRow(planId, transactionId);
    if (!existing) {
      throw new NotFoundError("Transaction not found");
    }

    this.db
      .query("UPDATE transactions SET deleted = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND plan_id = ?")
      .run(transactionId, planId);
    this.recalculateAccount(existing.account_id);
    const serverKnowledge = this.touchPlan(planId);
    this.db
      .query("UPDATE transactions SET server_knowledge = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND plan_id = ?")
      .run(serverKnowledge, transactionId, planId);
    return this.getTransaction(planId, transactionId, true);
  }

  importTransactions(planId: string, inputs: TransactionInput[]): {
    transaction_ids: string[];
    duplicate_import_ids: string[];
    duplicate_transaction_ids: string[];
    server_knowledge: number;
  } {
    const transactionIds: string[] = [];
    const duplicateImportIds = new Set<string>();
    const duplicateTransactionIds = new Set<string>();

    for (const input of inputs) {
      const duplicate = this.findDuplicateTransaction(planId, input);
      if (duplicate) {
        if (input.import_id) {
          duplicateImportIds.add(input.import_id);
        }
        duplicateTransactionIds.add(duplicate.id);
        continue;
      }

      const created = this.createTransaction(planId, input);
      transactionIds.push(created.id);
    }

    return {
      transaction_ids: transactionIds,
      duplicate_import_ids: [...duplicateImportIds],
      duplicate_transaction_ids: [...duplicateTransactionIds],
      server_knowledge: this.getServerKnowledge(planId),
    };
  }

  listTransactions(planId: string, filters: TransactionFilters = {}): any[] {
    this.ensurePlan(planId);
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

    const rows = this.db
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

    return rows.map((row) => this.formatTransaction(row));
  }

  getTransaction(planId: string, transactionId: string, includeDeleted = false): any {
    const row = this.getTransactionRow(planId, transactionId, includeDeleted);
    if (!row) {
      throw new NotFoundError("Transaction not found");
    }
    return this.formatTransaction(row);
  }

  getMonth(planId: string, month: string): any {
    this.ensurePlan(planId);
    const start = month.length === 7 ? `${month}-01` : month;
    const categoryRows = this.db
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
             AND t.transfer_transaction_id IS NULL
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

  createImportSession(planId: string | null, source: string): string {
    const id = createId("imp");
    if (planId) {
      this.ensurePlan(planId);
    }
    this.db
      .query("INSERT INTO import_sessions (id, plan_id, source) VALUES (?, ?, ?)")
      .run(id, planId, source);
    return id;
  }

  finishImportSession(id: string, status: string, summary: unknown): void {
    this.db
      .query("UPDATE import_sessions SET status = ?, finished_at = CURRENT_TIMESTAMP, summary_json = ? WHERE id = ?")
      .run(status, JSON.stringify(summary), id);
  }

  recordImportRow(sessionId: string, rowIndex: number, status: string, payload: unknown, error?: string, transactionId?: string): void {
    this.db
      .query(
        `INSERT INTO import_rows (id, import_session_id, row_index, status, payload_json, error, transaction_id)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(createId("row"), sessionId, rowIndex, status, JSON.stringify(payload), error ?? null, transactionId ?? null);
  }

  private resolveTransactionRefs(planId: string, input: TransactionInput): {
    payeeId: string | null;
    payeeName: string | null;
    categoryId: string | null;
    categoryName: string | null;
  } {
    let payeeId = input.payee_id ?? null;
    let payeeName = input.payee_name ?? null;
    if (payeeId) {
      this.ensurePayee(planId, payeeId, payeeName ?? undefined);
      const row = this.db.query("SELECT name FROM payees WHERE id = ?").get(payeeId) as Row;
      payeeName = row?.name ?? payeeName;
    } else if (payeeName) {
      payeeId = this.createPayee(planId, payeeName).id;
    }

    let categoryName: string | null = null;
    const categoryId = input.category_id ?? null;
    if (categoryId) {
      this.ensureCategory(planId, categoryId);
      const row = this.db.query("SELECT name FROM categories WHERE id = ?").get(categoryId) as Row;
      categoryName = row?.name ?? null;
    }

    return { payeeId, payeeName, categoryId, categoryName };
  }

  findDuplicateTransaction(planId: string, input: TransactionInput): any | null {
    if (input.import_id) {
      const importMatch = this.db
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
        .get(planId, input.import_id) as Row | null;

      if (importMatch) {
        return this.formatTransaction(importMatch);
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

    const row = this.db
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

    return row ? this.formatTransaction(row) : null;
  }

  private getTransactionRow(planId: string, transactionId: string, includeDeleted = false): Row | null {
    const clauses = ["t.plan_id = ?", "t.id = ?"];
    if (!includeDeleted) {
      clauses.push("t.deleted = 0");
    }
    return this.db
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

  private formatTransaction(row: Row): any {
    const subtransactions = this.db
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
      category_name: row.category_name ?? row.category_name_snapshot,
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

  private recalculateAccount(accountId: string): void {
    const row = this.db
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

    this.db
      .query(
        `UPDATE accounts
         SET balance_milli = ?, cleared_balance_milli = ?, uncleared_balance_milli = ?, updated_at = CURRENT_TIMESTAMP
         WHERE id = ?`,
      )
      .run(Number(row.balance ?? 0), Number(row.cleared ?? 0), Number(row.uncleared ?? 0), accountId);
  }
}

export class NotFoundError extends Error {}

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
