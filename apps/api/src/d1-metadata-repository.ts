import { createHash } from "node:crypto";
import { createId } from "./ids";
import type { D1Database } from "./d1";
import type { D1WriteContext } from "./d1-transaction-repository";
import { D1GuardedCommandExecutor, statement } from "./d1-guarded-command";
import type { EffectiveScheduledTransaction } from "./scheduled-transactions";
import { resolveAccountPresentation } from "./account-icon";
import { onBudgetForKind, type AccountUpdatePatch } from "./account-kind";
import { ynabMirrorGuard, type PlannedSql } from "./category-management";

/** Exact effective-source snapshot required to merge a scheduled mutation. */
export type ScheduledMutationSnapshot = Readonly<{
  source: "edit" | "raw";
  payloadJson: string;
  subtransactionsJson: string;
  deleted: number;
}>;

export type AccountReconciliationSnapshot = Readonly<{
  priorReconciledBalance: number;
  projectedReconciledBalance: number;
  candidateIds: string[];
}>;

/** Versioned D1 writes used by metadata importers. Reads intentionally live elsewhere. */
export class D1MetadataRepository {
  private readonly commands: D1GuardedCommandExecutor;
  constructor(private readonly db: D1Database, maxStaleRetries = 3) { this.commands = new D1GuardedCommandExecutor(db, maxStaleRetries); }

  async ensurePlan(planId: string, name = "HowMuch", context?: D1WriteContext): Promise<void> {
    const payload = { planId, name };
    await this.run("metadata.plan.ensure", planId, planId, payload, context, [
      statement("INSERT INTO write_assertions(command_id,kind,target_id,plan_id) VALUES (?, 'metadata_plan', ?, ?)", [this.id(context), planId, planId]),
      statement("INSERT INTO plans(id,name,external_ynab_id,first_month,last_month) VALUES (?,?,?,strftime('%Y-%m','now'),strftime('%Y-%m','now')) ON CONFLICT(id) DO NOTHING", [planId, name, planId]),
    ]);
  }

  async touchPlan(planId: string, context?: D1WriteContext): Promise<number> {
    const commandId = this.id(context);
    await this.run("metadata.plan.touch", planId, planId, {}, context, [
      assertion(commandId, "metadata_plan_exists", planId, planId),
      statement("UPDATE plans SET server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?", [planId]),
    ]);
    const row = await this.db.get<{ server_knowledge: number }>("SELECT server_knowledge FROM plans WHERE id=?", [planId]);
    if (!row) throw new Error("Plan not found after touch");
    return Number(row.server_knowledge);
  }

  /** Narrow counterpart of `upsertPlan`: only the given formats change, and `server_knowledge` moves. */
  async updatePlanFormats(planId: string, formats: { currency_format?: unknown; date_format?: unknown }, context?: D1WriteContext): Promise<void> {
    const commandId = this.id(context);
    await this.run("metadata.plan.formats", planId, planId, { formats }, context, [
      assertion(commandId, "metadata_plan_exists", planId, planId),
      statement(
        `UPDATE plans SET currency_format_json=COALESCE(?,currency_format_json),date_format_json=COALESCE(?,date_format_json),
           server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?`,
        [formats.currency_format ? JSON.stringify(formats.currency_format) : null, formats.date_format ? JSON.stringify(formats.date_format) : null, planId],
      ),
    ]);
  }

  async upsertPlan(planId: string, plan: any, settings?: any, context?: D1WriteContext): Promise<void> {
    const payload = { plan, settings };
    const date = JSON.stringify(settings?.date_format ?? { format: "DD/MM/YYYY" });
    const currency = JSON.stringify(settings?.currency_format ?? { iso_code: "SGD", example_format: "$123,456.78", decimal_digits: 2, decimal_separator: ".", symbol_first: true, group_separator: ",", currency_symbol: "$", display_symbol: true });
    const flags = JSON.stringify(settings?.display?.flag_names ?? {});
    // On conflict, an absent block keeps what the plan has (as the SQLite store does);
    // the defaults above apply only when the row is first created.
    const keep = (value: unknown) => (value === undefined || value === null ? null : JSON.stringify(value));
    await this.run("metadata.plan.upsert", planId, planId, payload, context, [
      statement("INSERT INTO write_assertions(command_id,kind,target_id,plan_id) VALUES (?, 'metadata_plan', ?, ?)", [this.id(context), planId, planId]),
      statement(`INSERT INTO plans(id,name,first_month,last_month,date_format_json,currency_format_json,flag_names_json,external_ynab_id,deleted,updated_at) VALUES (?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name,first_month=COALESCE(excluded.first_month,plans.first_month),last_month=COALESCE(excluded.last_month,plans.last_month),date_format_json=COALESCE(?,plans.date_format_json),currency_format_json=COALESCE(?,plans.currency_format_json),flag_names_json=COALESCE(?,plans.flag_names_json),external_ynab_id=excluded.external_ynab_id,deleted=excluded.deleted,updated_at=CURRENT_TIMESTAMP`, [planId, plan.name ?? "HowMuch", plan.first_month ?? null, plan.last_month ?? null, date, currency, flags, plan.id ?? plan.external_ynab_id ?? planId, bool(plan.deleted), keep(settings?.date_format), keep(settings?.currency_format), keep(settings?.display?.flag_names)]),
    ]);
  }

  async ensureAccount(planId: string, accountId: string, name?: string, context?: D1WriteContext): Promise<void> {
    return this.upsertAccount(planId, { id: accountId, name: name ?? `Imported account ${accountId.slice(0, 8)}` }, context, true);
  }

  /**
   * The upsert branch always moves `server_knowledge`. Clients validate cached
   * accounts against it (#175), so an import carrying only account changes —
   * a rename, a close, a delete — has to be visible as a knowledge change or
   * those clients would keep serving the old list. The ensure branch inserts
   * only what is missing and is reached from transaction writes, which move
   * knowledge themselves.
   */
  async upsertAccount(planId: string, account: any, context?: D1WriteContext, ensureOnly = false): Promise<void> {
    const existing = ensureOnly ? null : await this.db.get<{ icon: string }>("SELECT icon FROM accounts WHERE id=?", [account.id]);
    const presentation = resolveAccountPresentation({
      name: account.name ?? `Account ${account.id}`,
      icon: account.icon,
      type: account.type ?? "checking",
      existingIcon: existing?.icon,
    });
    const payeeId = account.transfer_payee_id ?? transferPayeeId(planId, account.id);
    const payeeName = `Transfer : ${presentation.name}`;
    const commandId = this.id(context);
    if (ensureOnly) {
      await this.run("metadata.account.ensure", planId, account.id, { account, ensureOnly }, context, [
        assertion(commandId, "metadata_plan_exists", planId, planId),
        assertion(commandId, "metadata_account", account.id, planId),
        assertion(commandId, "metadata_payee", payeeId, planId),
        statement(`INSERT INTO payees(id,plan_id,name,transfer_account_id,external_ynab_id,deleted,updated_at)
          SELECT ?,?,?,?,?,0,CURRENT_TIMESTAMP WHERE NOT EXISTS (SELECT 1 FROM accounts WHERE id=?)
          ON CONFLICT(id) DO NOTHING`, [payeeId, planId, payeeName, account.id, payeeId, account.id]),
        statement(`INSERT INTO accounts(id,plan_id,name,icon,transfer_payee_id,external_ynab_id)
          SELECT ?,?,?,?,?,? WHERE NOT EXISTS (SELECT 1 FROM accounts WHERE id=?)
          ON CONFLICT(id) DO NOTHING`, [account.id, planId, presentation.name, presentation.icon, payeeId, account.external_ynab_id ?? account.id, account.id]),
      ]);
      return;
    }
    const conflict = `DO UPDATE SET name=excluded.name,icon=excluded.icon,type=excluded.type,on_budget=excluded.on_budget,closed=excluded.closed,opening_balance_milli=excluded.opening_balance_milli,balance_milli=excluded.balance_milli,cleared_balance_milli=excluded.cleared_balance_milli,uncleared_balance_milli=excluded.uncleared_balance_milli,transfer_payee_id=excluded.transfer_payee_id,direct_import_linked=excluded.direct_import_linked,direct_import_in_error=excluded.direct_import_in_error,external_ynab_id=excluded.external_ynab_id,deleted=excluded.deleted,updated_at=CURRENT_TIMESTAMP`;
    await this.run("metadata.account.upsert", planId, account.id, { account, ensureOnly }, context, [
      assertion(commandId, "metadata_plan_exists", planId, planId), assertion(commandId, "metadata_account", account.id, planId), assertion(commandId, "metadata_payee", payeeId, planId),
      // Imported transfer payees arrive before their accounts.  Keep their
      // source name when present; only provision this synthetic record if the
      // account truly has none yet.
      statement(`INSERT INTO payees(id,plan_id,name,transfer_account_id,external_ynab_id,deleted,updated_at) VALUES (?,?,?,?,?,0,CURRENT_TIMESTAMP) ON CONFLICT(id) DO NOTHING`, [payeeId, planId, payeeName, account.id, payeeId]),
      statement(`INSERT INTO accounts(id,plan_id,name,icon,type,on_budget,closed,opening_balance_milli,balance_milli,cleared_balance_milli,uncleared_balance_milli,transfer_payee_id,direct_import_linked,direct_import_in_error,external_ynab_id,deleted,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP) ON CONFLICT(id) ${conflict}`, [account.id, planId, presentation.name, presentation.icon, account.type ?? "checking", bool(account.on_budget, true), bool(account.closed), account.opening_balance ?? 0, account.balance ?? 0, account.cleared_balance ?? account.balance ?? 0, account.uncleared_balance ?? 0, payeeId, bool(account.direct_import_linked), bool(account.direct_import_in_error), account.external_ynab_id ?? account.id, bool(account.deleted)]),
      statement("UPDATE payees SET transfer_account_id=?,updated_at=CURRENT_TIMESTAMP WHERE id=? AND plan_id=?", [account.id, payeeId, planId]),
      statement(
        `UPDATE payees SET name=?,updated_at=CURRENT_TIMESTAMP
         WHERE plan_id=? AND deleted=0 AND transfer_account_id=? AND name LIKE 'Transfer : %' AND name<>?`,
        [payeeName, planId, account.id, payeeName],
      ),
      statement("UPDATE accounts SET transfer_payee_id=?,updated_at=CURRENT_TIMESTAMP WHERE id=? AND plan_id=?", [payeeId, account.id, planId]),
      statement("UPDATE plans SET server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?", [planId]),
    ]);
  }

  async updateAccount(planId: string, accountId: string, patch: AccountUpdatePatch, context?: D1WriteContext): Promise<void> {
    const commandId = this.id(context);
    const assignments: string[] = [];
    const values: unknown[] = [];
    if (patch.icon !== undefined) {
      assignments.push("icon=?");
      values.push(patch.icon);
    }
    if (patch.name !== undefined) {
      assignments.push("name=?");
      values.push(patch.name);
    }
    if (patch.kind !== undefined) {
      assignments.push("type=?");
      values.push(patch.kind);
      assignments.push("on_budget=?");
      values.push(onBudgetForKind(patch.kind) ? 1 : 0);
    }
    if (assignments.length === 0) throw new Error("account.icon, account.name, or account.type is required");
    await this.run("metadata.account.update", planId, accountId, patch, context, [
      assertion(commandId, "metadata_plan_exists", planId, planId),
      assertion(commandId, "metadata_account", accountId, planId),
      statement(
        `UPDATE accounts SET ${assignments.join(",")},updated_at=CURRENT_TIMESTAMP WHERE id=? AND plan_id=? AND deleted=0`,
        [...values, accountId, planId],
      ),
      ...(patch.name !== undefined
        ? [statement(
          "UPDATE payees SET name=?,updated_at=CURRENT_TIMESTAMP WHERE deleted=0 AND transfer_account_id=? AND name LIKE 'Transfer : %'",
          [`Transfer : ${patch.name}`, accountId],
        )]
        : []),
      statement("UPDATE plans SET server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?", [planId]),
    ]);
  }

  async upsertPayee(planId: string, payee: any, context?: D1WriteContext): Promise<void> {
    const commandId = this.id(context);
    await this.run("metadata.payee.upsert", planId, payee.id, { payee }, context, [assertion(commandId,"metadata_plan_exists",planId,planId), assertion(commandId,"metadata_payee",payee.id,planId),
      statement("INSERT INTO payees(id,plan_id,name,transfer_account_id,external_ynab_id,deleted,updated_at) VALUES (?,?,?,?,?,?,CURRENT_TIMESTAMP) ON CONFLICT(id) DO UPDATE SET name=excluded.name,transfer_account_id=excluded.transfer_account_id,external_ynab_id=excluded.external_ynab_id,deleted=excluded.deleted,updated_at=CURRENT_TIMESTAMP", [payee.id,planId,payee.name??`Payee ${payee.id}`,payee.transfer_account_id??null,payee.external_ynab_id??payee.id,bool(payee.deleted)]),
      // Payees are validated against `server_knowledge` by clients (#175), so
      // a rename or a delete arriving by import must move it.
      statement("UPDATE plans SET server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?", [planId])]);
  }

  async upsertYnabRawObject(planId:string,objectType:string,objectId:string,payload:unknown,serverKnowledge?:number,context?:D1WriteContext):Promise<void>{
    const json=JSON.stringify(payload); if(json===undefined) throw new Error("YNAB raw object payload must be JSON serialisable");
    const deleted=Boolean((payload as Record<string,unknown>|null)?.deleted)?1:0; const commandId=this.id(context);
    await this.run("ynab.raw.upsert",planId,`${objectType}:${objectId}`,{objectType,objectId,payload,serverKnowledge:serverKnowledge??null},context,[
      assertion(commandId,"metadata_plan_exists",planId,planId),
      statement(`INSERT INTO ynab_raw_objects(plan_id,object_type,object_id,payload_json,deleted,server_knowledge,updated_at) VALUES (?,?,?,?,?,?,CURRENT_TIMESTAMP)
        ON CONFLICT(plan_id,object_type,object_id) DO UPDATE SET payload_json=excluded.payload_json,deleted=excluded.deleted,server_knowledge=excluded.server_knowledge,updated_at=CURRENT_TIMESTAMP`,[planId,objectType,objectId,json,deleted,serverKnowledge??null]),
    ]);
  }

  /** Reconciles one exact account snapshot in a single guarded D1 batch. */
  async reconcileAccount(
    planId: string,
    accountId: string,
    statementDate: string,
    statementBalance: number,
    snapshot: AccountReconciliationSnapshot,
    context: D1WriteContext,
  ): Promise<{
    reconciled_transaction_ids: string[];
    reconciled_transaction_count: number;
    statement_date: string;
    statement_balance: number;
    prior_reconciled_balance: number;
    final_reconciled_balance: number;
  }> {
    const commandId = this.id(context);
    const auditId = `audit_reconcile_${digest(commandId).slice(0, 20)}`;
    const candidateIdsJson = JSON.stringify(snapshot.candidateIds);
    const result = {
      reconciled_transaction_ids: snapshot.candidateIds,
      reconciled_transaction_count: snapshot.candidateIds.length,
      statement_date: statementDate,
      statement_balance: statementBalance,
      prior_reconciled_balance: snapshot.priorReconciledBalance,
      final_reconciled_balance: snapshot.projectedReconciledBalance,
    };
    await this.run(
      "account.reconcile",
      planId,
      accountId,
      { statement_date: statementDate, statement_balance: statementBalance },
      context,
      [
        assertion(commandId, "metadata_plan_exists", planId, planId),
        assertion(commandId, "account", accountId, planId),
        statement(
          `INSERT INTO account_reconciliation_assertions
            (command_id,plan_id,account_id,statement_date,prior_reconciled_balance_milli,projected_reconciled_balance_milli,candidate_ids_json)
           VALUES (?,?,?,?,?,?,?)`,
          [commandId, planId, accountId, statementDate, snapshot.priorReconciledBalance, snapshot.projectedReconciledBalance, candidateIdsJson],
        ),
        statement(
          "UPDATE transactions SET cleared='reconciled',updated_at=CURRENT_TIMESTAMP WHERE plan_id=? AND account_id=? AND deleted=0 AND cleared='cleared' AND date<=?",
          [planId, accountId, statementDate],
        ),
        statement(
          `UPDATE accounts SET
             balance_milli=opening_balance_milli+COALESCE((SELECT SUM(amount_milli) FROM transactions WHERE account_id=? AND plan_id=? AND deleted=0),0),
             cleared_balance_milli=opening_balance_milli+COALESCE((SELECT SUM(amount_milli) FROM transactions WHERE account_id=? AND plan_id=? AND deleted=0 AND cleared IN ('cleared','reconciled')),0),
             uncleared_balance_milli=COALESCE((SELECT SUM(amount_milli) FROM transactions WHERE account_id=? AND plan_id=? AND deleted=0 AND cleared='uncleared'),0),
             updated_at=CURRENT_TIMESTAMP
           WHERE id=? AND plan_id=?`,
          [accountId, planId, accountId, planId, accountId, planId, accountId, planId],
        ),
        statement("UPDATE plans SET server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?", [planId]),
        statement(
          `UPDATE transactions SET
             server_knowledge=(SELECT server_knowledge FROM plans WHERE id=?),
             updated_at=CURRENT_TIMESTAMP
           WHERE plan_id=? AND id IN (SELECT value FROM json_each(?))`,
          [planId, planId, candidateIdsJson],
        ),
        statement(
          "INSERT INTO audit_events(id,plan_id,action,resource_type,resource_id,source,metadata_json) VALUES (?,?,'account.reconcile','account',?,'howmuch-local',?)",
          [auditId, planId, accountId, JSON.stringify({ result })],
        ),
      ],
    );
    const receipt = await this.db.get<{ metadata_json: string }>(
      "SELECT metadata_json FROM audit_events WHERE id=? AND plan_id=? AND action='account.reconcile' AND resource_id=?",
      [auditId, planId, accountId],
    );
    if (!receipt) throw new Error("Reconciliation receipt is missing");
    return JSON.parse(receipt.metadata_json).result;
  }

  /** Guarded, audited write of a HowMuch schedule or imported-source overlay. */
  async mutateScheduledTransaction(
    planId: string,
    transaction: EffectiveScheduledTransaction,
    origin: "howmuch-local" | "ynab-overlay",
    action: "scheduled_transaction.create" | "scheduled_transaction.update" | "scheduled_transaction.delete",
    context?: D1WriteContext,
    snapshot?: ScheduledMutationSnapshot,
  ): Promise<void> {
    const commandId = this.id(context);
    const auditId = `audit_${digest(commandId).slice(0, 24)}`;
    const { subtransactions, ...parent } = transaction;
    const subtransactionReferences = (await Promise.all(
      subtransactions.map((subtransaction) => this.scheduleReferenceAssertions(commandId, planId, subtransaction)),
    )).flat();
    const referenceCandidates = [
      assertion(commandId, "metadata_plan_exists", planId, planId),
      assertion(commandId, "account", transaction.account_id, planId),
      ...await this.scheduleReferenceAssertions(commandId, planId, transaction),
      ...subtransactionReferences,
    ];
    const referenceKeys = new Set<string>();
    const references = referenceCandidates.filter((candidate) => {
      const key = JSON.stringify(candidate.values);
      if (referenceKeys.has(key)) return false;
      referenceKeys.add(key);
      return true;
    });
    const parentStatement = action === "scheduled_transaction.create"
      ? statement(
        `INSERT INTO scheduled_transaction_edits
          (plan_id,id,origin,payload_json,account_id,date_first,date_next,frequency,amount_milli,payee_id,category_id,transfer_account_id,deleted,updated_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP)`,
        [planId, transaction.id, origin, JSON.stringify(parent), transaction.account_id, transaction.date_first, transaction.date_next, transaction.frequency, transaction.amount, transaction.payee_id ?? null, transaction.category_id ?? null, transaction.transfer_account_id ?? null, transaction.deleted ? 1 : 0],
      )
      : statement(
        `INSERT INTO scheduled_transaction_edits
          (plan_id,id,origin,payload_json,account_id,date_first,date_next,frequency,amount_milli,payee_id,category_id,transfer_account_id,deleted,updated_at)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP)
         ON CONFLICT(plan_id,id) DO UPDATE SET origin=excluded.origin,payload_json=excluded.payload_json,account_id=excluded.account_id,
           date_first=excluded.date_first,date_next=excluded.date_next,frequency=excluded.frequency,amount_milli=excluded.amount_milli,
           payee_id=excluded.payee_id,category_id=excluded.category_id,transfer_account_id=excluded.transfer_account_id,
           deleted=excluded.deleted,updated_at=CURRENT_TIMESTAMP`,
        [planId, transaction.id, origin, JSON.stringify(parent), transaction.account_id, transaction.date_first, transaction.date_next, transaction.frequency, transaction.amount, transaction.payee_id ?? null, transaction.category_id ?? null, transaction.transfer_account_id ?? null, transaction.deleted ? 1 : 0],
      );
    await this.run(action, planId, transaction.id, { transaction, origin }, context, [
      ...references,
      ...(snapshot ? [statement(
        `INSERT INTO scheduled_transaction_snapshot_assertions
          (command_id,plan_id,scheduled_transaction_id,source,payload_json,subtransactions_json,deleted)
         VALUES (?,?,?,?,?,?,?)`,
        [commandId, planId, transaction.id, snapshot.source, snapshot.payloadJson, snapshot.subtransactionsJson, snapshot.deleted],
      )] : []),
      parentStatement,
      statement("DELETE FROM scheduled_subtransaction_edits WHERE plan_id=? AND scheduled_transaction_id=?", [planId, transaction.id]),
      ...subtransactions.map((subtransaction) => statement(
        `INSERT INTO scheduled_subtransaction_edits
          (plan_id,id,scheduled_transaction_id,payload_json,amount_milli,payee_id,category_id,transfer_account_id)
         VALUES (?,?,?,?,?,?,?,?)`,
        [planId, subtransaction.id, transaction.id, JSON.stringify(subtransaction), subtransaction.amount, subtransaction.payee_id ?? null, subtransaction.category_id ?? null, subtransaction.transfer_account_id ?? null],
      )),
      statement("UPDATE plans SET server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?", [planId]),
      statement(
        "INSERT INTO audit_events(id,plan_id,action,resource_type,resource_id,source,metadata_json) VALUES (?,?,?,?,?,'howmuch-local',?)",
        [auditId, planId, action, "scheduled_transaction", transaction.id, JSON.stringify({ origin, deleted: Boolean(transaction.deleted) })],
      ),
    ]);
  }

  private async scheduleReferenceAssertions(commandId: string, planId: string, value: Record<string, any>): Promise<ReturnType<typeof statement>[]> {
    const result: ReturnType<typeof statement>[] = [];
    if (value.payee_id) {
      const payee = await this.db.get<{ transfer_account_id: string | null }>("SELECT transfer_account_id FROM payees WHERE id=? AND plan_id=? AND deleted=0", [value.payee_id, planId]);
      result.push(assertion(commandId, payee?.transfer_account_id ? "transfer_payee" : "payee", value.payee_id, planId));
    }
    if (value.category_id) result.push(assertion(commandId, "category", value.category_id, planId));
    if (value.transfer_account_id) result.push(assertion(commandId, "account", value.transfer_account_id, planId));
    return result;
  }

  async createPayee(planId: string, payee: any, context?: D1WriteContext): Promise<void> {
    const commandId = this.id(context);
    await this.run("metadata.payee.create", planId, payee.id, { payee }, context, [
      assertion(commandId,"metadata_plan_exists",planId,planId), assertion(commandId,"metadata_payee",payee.id,planId),
      statement("INSERT INTO payees(id,plan_id,name,external_ynab_id) VALUES (?,?,?,?)", [payee.id,planId,payee.name,payee.id]),
      statement("UPDATE plans SET server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?", [planId]),
    ]);
  }

  /**
   * One guarded batch for a HowMuch-native plan command. The caller supplies
   * the planned statements; this adds the plan-exists assertion and the
   * in-batch refusal to touch a YNAB-mirror plan.
   */
  async applyNativeCommand(kind: string, planId: string, resourceId: string, payload: unknown, statements: readonly PlannedSql[], context?: D1WriteContext): Promise<void> {
    const commandId = this.id(context);
    await this.run(kind, planId, resourceId, payload, context, [
      assertion(commandId, "metadata_plan_exists", planId, planId),
      ynabMirrorGuard(commandId, planId),
      ...statements.map((planned) => statement(planned.sql, planned.values as unknown[])),
    ]);
  }

  async upsertCategoryGroup(planId: string, group: any, context?: D1WriteContext): Promise<void> { await this.simpleMetadata("category_group", "category_groups", planId, group, null, context); }
  async upsertCategory(planId: string, category: any, groupId?: string | null, context?: D1WriteContext): Promise<void> { await this.simpleMetadata("category", "categories", planId, category, groupId ?? category.category_group_id ?? null, context); }

  async ensureCategory(planId:string,categoryId:string,name?:string,groupId="uncategorized-group",context?:D1WriteContext):Promise<void>{
    // Reference resolution may not know the group ID.  If the category was
    // already imported, it is a true no-op: creating an unused fallback group
    // would make the normalised ledger diverge from the YNAB source.
    const existing = await this.db.get<{ plan_id: string }>("SELECT plan_id FROM categories WHERE id=?", [categoryId]);
    if (existing) {
      if (existing.plan_id !== planId) throw new Error("Category belongs to a different plan");
      return;
    }
    const commandId=this.id(context);
    await this.run("metadata.category.ensure",planId,categoryId,{name,groupId},context,[
      assertion(commandId,"metadata_plan_exists",planId,planId), assertion(commandId,"metadata_category_group",groupId,planId), assertion(commandId,"metadata_category",categoryId,planId),
      statement("INSERT INTO category_groups(id,plan_id,name) VALUES (?,?,?) ON CONFLICT(id) DO NOTHING",[groupId,planId,groupId==="uncategorized-group"?"Uncategorised":"Imported"]),
      assertion(commandId,"metadata_category_group_exists",groupId,planId),
      statement("INSERT INTO categories(id,plan_id,category_group_id,name,external_ynab_id) VALUES (?,?,?,?,?) ON CONFLICT(id) DO NOTHING",[categoryId,planId,groupId,name??`Imported category ${categoryId.slice(0,8)}`,categoryId]),
    ]);
  }

  async createImportSession(planId: string | null, source: string, context?: D1WriteContext): Promise<string> {
    const id = context ? `imp_${digest(context.operationId).slice(0,24)}` : createId("imp"); const scope = planId ?? ""; const commandId=this.id(context);
    await this.run("import.session.create",scope,id,{planId,source},context,[...(planId?[assertion(commandId,"metadata_plan_exists",planId,planId)]:[]),assertion(commandId,"import_session_new",id,scope),statement("INSERT INTO import_sessions(id,plan_id,source) VALUES (?,?,?)",[id,planId,source])]); return id;
  }
  async finishImportSession(id: string, status: string, summary: unknown, context?: D1WriteContext): Promise<void> {
    const session=await this.db.get<Record<string,any>>("SELECT plan_id FROM import_sessions WHERE id=?",[id]); if(!session) throw new Error("Import session not found"); const scope=session.plan_id??""; const commandId=this.id(context);
    await this.run("import.session.finish",scope,id,{status,summary},context,[assertion(commandId,"import_session_running",id,scope),statement("UPDATE import_sessions SET status=?,finished_at=CURRENT_TIMESTAMP,summary_json=? WHERE id=?",[status,JSON.stringify(summary),id])]);
  }
  async recordImportRow(sessionId:string,rowIndex:number,status:string,payload:unknown,error?:string,transactionId?:string,context?:D1WriteContext):Promise<void>{
    const session=await this.db.get<Record<string,any>>("SELECT plan_id FROM import_sessions WHERE id=?",[sessionId]); if(!session) throw new Error("Import session not found"); const scope=session.plan_id??""; const id=context?`row_${digest(context.operationId).slice(0,24)}`:createId("row"); const commandId=this.id(context);
    await this.run("import.row.record",scope,id,{sessionId,rowIndex,status,payload,error:error??null,transactionId:transactionId??null},context,[assertion(commandId,"import_session_running",sessionId,scope),...(transactionId?[assertion(commandId,"import_transaction",transactionId,scope)]:[]),statement("INSERT INTO import_rows(id,import_session_id,row_index,status,payload_json,error,transaction_id) VALUES (?,?,?,?,?,?,?)",[id,sessionId,rowIndex,status,JSON.stringify(payload),error??null,transactionId??null])]);
  }

  private async simpleMetadata(kind:string,table:string,planId:string,value:any,groupId:string|null,context?:D1WriteContext){const commandId=this.id(context); const body=[assertion(commandId,"metadata_plan_exists",planId,planId),assertion(commandId,`metadata_${kind}`,value.id,planId)]; if(groupId)body.push(assertion(commandId,"metadata_category_group_exists",groupId,planId)); const groupColumn=kind==="category"?"category_group_id,":""; const groupValue=kind==="category"?[groupId]:[]; body.push(statement(`INSERT INTO ${table}(id,plan_id,${groupColumn}name,hidden,internal,external_ynab_id,deleted,updated_at) VALUES (${kind==="category"?"?,?,?,?,?,?,?,?":"?,?,?,?,?,?,?"},CURRENT_TIMESTAMP) ON CONFLICT(id) DO UPDATE SET ${kind==="category"?"category_group_id=excluded.category_group_id,":""}name=excluded.name,hidden=excluded.hidden,internal=excluded.internal,external_ynab_id=excluded.external_ynab_id,deleted=excluded.deleted,updated_at=CURRENT_TIMESTAMP`,[value.id,planId,...groupValue,value.name??`${kind} ${value.id}`,bool(value.hidden),bool(value.internal),value.external_ynab_id??value.id,bool(value.deleted)])); await this.run(`metadata.${kind}.upsert`,planId,value.id,{value,groupId},context,body);}
  private id(context?:D1WriteContext){return context?.operationId??createId("cmd");}
  private async run(kind:string,planId:string,resourceId:string,payload:unknown,context:D1WriteContext|undefined,statements:any[]){const operationId=this.id(context); const fixed=context??{operationId}; const fixedStatements=statements.map((s)=>s.sql.includes("write_assertions")?statement(s.sql,[operationId,...s.values.slice(1)]):s); await this.commands.execute({kind,planId,resourceId,payload,context:fixed,statements:fixedStatements},async()=>undefined);}
}
function assertion(commandId:string,kind:string,target:string,plan:string){return statement("INSERT INTO write_assertions(command_id,kind,target_id,plan_id) VALUES (?,?,?,?)",[commandId,kind,target,plan]);}
function bool(value:any,fallback=false){return value==null?(fallback?1:0):(value?1:0);}
function digest(value:string){return createHash("sha256").update(value).digest("hex");}
function transferPayeeId(planId:string,accountId:string){return `payee_transfer_${digest(`${planId}:${accountId}`).slice(0,20)}`;}
