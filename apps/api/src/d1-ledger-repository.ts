import { createId } from "./ids";
import { createHash } from "node:crypto";
import { parseAccountIcon } from "./account-icon";
import { applyAccountUpdate, type AccountUpdatePatch } from "./account-kind";
import { LedgerRepository, NotFoundError, ReconciliationMismatchError, TransactionStateConflictError, ValidationError, type CategoryWriteOptions, type TransactionWriteOptions } from "./repository";
import {
  EntityConflictError,
  categoryCommandStatements,
  categoryInUseGuard,
  isPreconditionFailure,
  isUniqueViolation,
  type CategoryCommand,
  type CategoryCreate,
  type CategoryGroupCreate,
  type CategoryGroupPatch,
  type CategoryPatch,
  type PlannedSql,
} from "./category-management";
import { requestHash } from "./d1-guarded-command";
import type { LedgerStore } from "./storage";
import type { AccountReconciliationOptions, AccountReconciliationPreview, AccountReconciliationResult, ScheduledTransactionInput, ScheduledWriteOptions, TransactionBatchResult, TransactionBatchUpdate, TransactionInput } from "./types";
import { D1Database } from "./d1";
import { D1MetadataRepository, type AccountReconciliationSnapshot, type ScheduledMutationSnapshot } from "./d1-metadata-repository";
import { D1TransactionRepository, type D1WriteContext } from "./d1-transaction-repository";
import { scheduledTransactionMutation, type EffectiveScheduledTransaction } from "./scheduled-transactions";

export type D1LedgerRepositoryOptions = Readonly<{
  lease?: (planId: string) => D1WriteContext["lease"] | undefined;
  operationId?: (kind: string, planId: string | undefined, resourceId: string) => string;
}>;

export class D1LedgerRepository extends LedgerRepository {
  private readonly metadata: D1MetadataRepository;
  private readonly transactions: D1TransactionRepository;

  constructor(private readonly d1: D1Database, defaultPlanId: string, private readonly options: D1LedgerRepositoryOptions = {}) {
    super(d1, defaultPlanId);
    this.metadata = new D1MetadataRepository(d1);
    this.transactions = new D1TransactionRepository(d1);
  }

  private context(kind: string, planId: string | undefined, resourceId: string, operationId?: string): D1WriteContext {
    const lease = planId ? this.options.lease?.(planId) : undefined;
    return { operationId: operationId ?? this.options.operationId?.(kind, planId, resourceId) ?? createId("op"), ...(lease ? { lease } : {}) };
  }

  override async ensurePlan(planId = this.getDefaultPlanId(), name = "HowMuch"): Promise<void> {
    if (await this.d1.get("SELECT 1 FROM plans WHERE id=? AND deleted=0", [planId])) return;
    await this.metadata.ensurePlan(planId, name, this.context("plan.ensure",planId,planId));
  }
  override async touchPlan(planId: string): Promise<number> { return this.metadata.touchPlan(planId, this.context("plan.touch",planId,planId)); }
  override async upsertPlan(planId:string,plan:any,settings?:any):Promise<void>{await this.metadata.upsertPlan(planId,plan,settings,this.context("plan.upsert",planId,planId));}
  override async ensureAccount(planId:string,accountId:string,name?:string):Promise<void>{await this.metadata.ensureAccount(planId,accountId,name,this.context("account.ensure",planId,accountId));}
  override async upsertAccount(planId:string,account:any):Promise<void>{await this.metadata.upsertAccount(planId,account,this.context("account.upsert",planId,account.id));}
  override async updateAccount(planId:string,accountId:string,patch:AccountUpdatePatch):Promise<any>{
    const parsedIcon = patch.icon === undefined ? undefined : parseAccountIcon(patch.icon);
    if (parsedIcon === null) throw new ValidationError("icon must be a single emoji");
    const parsedName = patch.name === undefined ? undefined : String(patch.name).trim();
    if (patch.name !== undefined && !parsedName) throw new ValidationError("account.name is required");
    if (parsedIcon === undefined && parsedName === undefined && patch.kind === undefined) throw new ValidationError("account.icon, account.name, or account.type is required");
    const existing = await this.d1.get("SELECT name, icon, type FROM accounts WHERE id=? AND plan_id=? AND deleted=0", [accountId, planId]);
    if (!existing) throw new NotFoundError("Account not found");
    const fields = applyAccountUpdate(
      {
        name: String(existing.name ?? ""),
        icon: typeof existing.icon === "string" ? existing.icon : null,
        type: typeof existing.type === "string" ? existing.type : null,
      },
      { ...(parsedIcon !== undefined ? { icon: parsedIcon } : {}), ...(parsedName !== undefined ? { name: parsedName } : {}), ...(patch.kind ? { kind: patch.kind } : {}) },
    );
    await this.metadata.updateAccount(planId, accountId, {
      ...(fields.name !== undefined ? { name: fields.name } : {}),
      ...(fields.icon !== undefined ? { icon: fields.icon } : {}),
      ...(fields.type !== undefined ? { kind: fields.type } : {}),
    }, this.context("account.update", planId, accountId));
    return this.getAccount(planId, accountId);
  }
  override async createAccount(planId:string,account:any):Promise<any>{
    const id=account.id??createId("acct"); const opening=account.opening_balance??account.balance??0;
    await this.metadata.upsertAccount(planId,{...account,id,...(!account.id?{opening_balance:opening,balance:account.balance??opening,cleared_balance:account.cleared_balance??account.balance??opening}: {})},this.context("account.create",planId,id));
    return this.getAccount(planId,id);
  }
  override async getAccountReconciliation(planId: string, accountId: string, statementDate: string): Promise<AccountReconciliationPreview> {
    const date = normaliseReconciliationDate(statementDate);
    const { account, snapshot } = await this.readAccountReconciliationSnapshot(planId, accountId, date);
    const formattedAccount = await this.findAccount(planId, account.id);
    if (!formattedAccount) throw new NotFoundError("Account not found");
    return {
      account: formattedAccount,
      statement_date: date,
      current_reconciled_balance: snapshot.priorReconciledBalance,
      projected_reconciled_balance: snapshot.projectedReconciledBalance,
      candidate_transaction_ids: snapshot.candidateIds,
      candidate_transaction_count: snapshot.candidateIds.length,
      server_knowledge: await this.getServerKnowledge(planId),
    };
  }
  override async reconcileAccount(
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
    const context = this.context("account.reconcile", planId, accountId, options.operationId);
    const receipt = await this.d1.get("SELECT 1 FROM write_commands WHERE id=?", [context.operationId]);
    const { snapshot } = await this.readAccountReconciliationSnapshot(planId, accountId, date);
    if (!receipt && snapshot.projectedReconciledBalance !== statementBalance) {
      throw new ReconciliationMismatchError(snapshot.priorReconciledBalance, snapshot.projectedReconciledBalance, statementBalance);
    }
    const result = await this.metadata.reconcileAccount(planId, accountId, date, statementBalance, snapshot, context);
    const reconciledAccount = await this.findAccount(planId, accountId);
    if (!reconciledAccount) throw new NotFoundError("Account not found");
    return {
      ...result,
      account: reconciledAccount,
      replayed: Boolean(receipt),
      server_knowledge: await this.getServerKnowledge(planId),
    };
  }
  private async readAccountReconciliationSnapshot(
    planId: string,
    accountId: string,
    statementDate: string,
  ): Promise<{ account: Record<string, any>; snapshot: AccountReconciliationSnapshot }> {
    const account = await this.d1.get<Record<string, any>>(
      "SELECT * FROM accounts WHERE id=? AND plan_id=? AND deleted=0",
      [accountId, planId],
    );
    if (!account) throw new NotFoundError("Account not found");
    const balances = await this.d1.get<Record<string, any>>(
      `SELECT
         ? + COALESCE(SUM(CASE WHEN deleted=0 AND cleared='reconciled' THEN amount_milli ELSE 0 END),0) current_reconciled,
         ? + COALESCE(SUM(CASE WHEN deleted=0 AND (cleared='reconciled' OR (cleared='cleared' AND date<=?)) THEN amount_milli ELSE 0 END),0) projected_reconciled
       FROM transactions WHERE plan_id=? AND account_id=?`,
      [account.opening_balance_milli, account.opening_balance_milli, statementDate, planId, accountId],
    );
    const candidates = await this.d1.all<{ id: string }>(
      "SELECT id FROM transactions WHERE plan_id=? AND account_id=? AND deleted=0 AND cleared='cleared' AND date<=? ORDER BY id",
      [planId, accountId, statementDate],
    );
    return {
      account,
      snapshot: {
        priorReconciledBalance: Number(balances?.current_reconciled),
        projectedReconciledBalance: Number(balances?.projected_reconciled),
        candidateIds: candidates.map((row) => String(row.id)),
      },
    };
  }
  override async ensureTransferPayee():Promise<{id:string;name:string}|null>{throw new Error("D1LedgerRepository.ensureTransferPayee is unsupported; use ensureAccount/upsertAccount for atomic provisioning");}
  override async createPayee(planId:string,name:string,id=createId("payee")):Promise<any>{
    const existing=await this.d1.get<Record<string,any>>("SELECT id FROM payees WHERE plan_id=? AND lower(name)=lower(?) AND deleted=0",[planId,name]);
    if(existing) {
      const payee = await this.findPayee(planId, existing.id);
      if (!payee) throw new NotFoundError("Payee not found");
      return payee;
    }
    await this.metadata.createPayee(planId,{id,name},this.context("payee.create",planId,id));
    const created = await this.findPayee(planId, id);
    if (!created) throw new NotFoundError("Payee not found");
    return created;
  }
  override async ensurePayee(planId:string,payeeId:string,name?:string):Promise<void>{await this.metadata.upsertPayee(planId,{id:payeeId,name:name??`Imported payee ${payeeId.slice(0,8)}`},this.context("payee.ensure",planId,payeeId));}
  override async upsertPayee(planId:string,payee:any):Promise<void>{await this.metadata.upsertPayee(planId,payee,this.context("payee.upsert",planId,payee.id));}
  override async upsertYnabRawObject(planId:string,objectType:string,objectId:string,payload:unknown,serverKnowledge?:number):Promise<void>{await this.metadata.upsertYnabRawObject(planId,objectType,objectId,payload,serverKnowledge,this.context("ynab-raw.upsert",planId,`${objectType}:${objectId}`));}
  override async ensureCategory(planId:string,categoryId:string,name?:string,groupId?:string|null):Promise<void>{await this.metadata.ensureCategory(planId,categoryId,name,groupId??"uncategorized-group",this.context("category.ensure",planId,categoryId));}
  override async upsertCategoryGroup(planId:string,group:any):Promise<void>{await this.metadata.upsertCategoryGroup(planId,group,this.context("category-group.upsert",planId,group.id));}
  override async upsertCategory(planId:string,category:any,groupId?:string|null):Promise<void>{await this.metadata.upsertCategory(planId,category,groupId,this.context("category.upsert",planId,category.id));}
  override async createCategoryGroup(planId: string, input: CategoryGroupCreate, options: CategoryWriteOptions = {}): Promise<any> {
    const id = input.id ?? d1DerivedEntityId("category_group", planId, options.operationId);
    return this.applyD1CategoryCommand(planId, "category_group.create", id, input, options,
      () => this.planCreateCategoryGroup(planId, id, input), () => this.readCategoryGroupResponse(planId, id), () => []);
  }
  override async updateCategoryGroup(planId: string, groupId: string, patch: CategoryGroupPatch, options: CategoryWriteOptions = {}): Promise<any> {
    return this.applyD1CategoryCommand(planId, "category_group.update", groupId, patch, options,
      () => this.planUpdateCategoryGroup(planId, groupId, patch), () => this.readCategoryGroupResponse(planId, groupId),
      (commandId) => [categoryAssertion(commandId, "metadata_category_group_exists", groupId, planId)]);
  }
  override async createCategory(planId: string, input: CategoryCreate, options: CategoryWriteOptions = {}): Promise<any> {
    const id = input.id ?? d1DerivedEntityId("category", planId, options.operationId);
    return this.applyD1CategoryCommand(planId, "category.create", id, input, options,
      () => this.planCreateCategory(planId, id, input), () => this.readCategoryResponse(planId, id),
      (commandId) => [categoryAssertion(commandId, "metadata_category_group_exists", input.category_group_id, planId)]);
  }
  override async updateCategory(planId: string, categoryId: string, patch: CategoryPatch, options: CategoryWriteOptions = {}): Promise<any> {
    return this.applyD1CategoryCommand(planId, "category.update", categoryId, patch, options,
      () => this.planUpdateCategory(planId, categoryId, patch), () => this.readCategoryResponse(planId, categoryId),
      (commandId) => [
        categoryAssertion(commandId, "category", categoryId, planId),
        ...(patch.category_group_id === undefined ? [] : [categoryAssertion(commandId, "metadata_category_group_exists", patch.category_group_id, planId)]),
      ]);
  }
  override async deleteCategory(planId: string, categoryId: string, options: CategoryWriteOptions = {}): Promise<any> {
    return this.applyD1CategoryCommand(planId, "category.delete", categoryId, {}, options,
      () => this.planDeleteCategory(planId, categoryId), () => this.readCategoryResponse(planId, categoryId),
      (commandId) => [categoryAssertion(commandId, "category", categoryId, planId), categoryInUseGuard(commandId, planId, categoryId)]);
  }

  /**
   * D1 runner. Planning reads give precise errors up front; the guarded batch
   * re-asserts every precondition, so a concurrent change aborts the whole
   * write. On such an abort the plan is re-read to report why.
   */
  private async applyD1CategoryCommand(
    planId: string,
    action: CategoryCommand["action"],
    resourceId: string,
    request: unknown,
    options: CategoryWriteOptions,
    plan: () => Promise<CategoryCommand>,
    read: () => Promise<any>,
    guards: (commandId: string) => PlannedSql[],
  ): Promise<any> {
    const hash = requestHash({ action, planId, resourceId, request });
    const context = this.context(action, planId, resourceId, options.operationId);
    const payload = { request_hash: hash };
    const receipt = options.operationId ? await this.d1.get("SELECT 1 FROM write_commands WHERE id=?", [context.operationId]) : null;
    if (receipt) {
      // The executor verifies kind, plan, resource and hash before replaying.
      await this.metadata.applyNativeCommand(action, planId, resourceId, payload, [], context);
      return read();
    }
    const command = await plan();
    const auditId = `audit_${createHash("sha256").update(context.operationId).digest("hex").slice(0, 24)}`;
    try {
      await this.metadata.applyNativeCommand(action, planId, resourceId, payload, [
        ...guards(context.operationId),
        ...categoryCommandStatements(command, planId, auditId, hash),
      ], context);
    } catch (error) {
      if (isPreconditionFailure(error)) {
        await plan();
        throw new EntityConflictError("The plan changed while this category change was being saved; refresh and try again");
      }
      if (isUniqueViolation(error)) throw new EntityConflictError(action === "category_group.create" ? "Category group already exists" : "Category already exists");
      throw error;
    }
    return read();
  }

  override async createScheduledTransaction(planId: string, input: ScheduledTransactionInput, options: ScheduledWriteOptions = {}): Promise<any> {
    await this.ensurePlan(planId);
    const id = input.id ?? (options.operationId ? `scheduled_${scheduleId(`${planId}:${options.operationId}`)}` : createId("scheduled"));
    const context = this.context("scheduled_transaction.create", planId, id, options.operationId);
    const receipt = options.operationId ? await this.d1.get("SELECT 1 FROM write_commands WHERE id=?", [context.operationId]) : null;
    if (!receipt) {
      const collision = await this.d1.get(
        `SELECT 1 FROM scheduled_transaction_edits WHERE plan_id=? AND id=?
         UNION ALL SELECT 1 FROM ynab_raw_objects WHERE plan_id=? AND object_type='scheduled_transaction' AND object_id=? LIMIT 1`,
        [planId, id, planId, id],
      );
      if (collision) throw new ValidationError("Scheduled transaction already exists");
    }
    const transaction = scheduledTransactionMutation(id, input as Record<string, unknown>, null, [], options.operationId);
    await this.validateD1ScheduledReferences(planId, transaction);
    await this.metadata.mutateScheduledTransaction(planId, transaction, "howmuch-local", "scheduled_transaction.create", context);
    return this.getScheduledTransaction(planId, id);
  }

  override async updateScheduledTransaction(planId: string, id: string, patch: Partial<ScheduledTransactionInput>, options: ScheduledWriteOptions = {}): Promise<any> {
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const current = await this.readD1ScheduleForMutation(planId, id);
      assertExpectedD1Schedule(current.payload, options.expected);
      const transaction = scheduledTransactionMutation(id, patch as Record<string, unknown>, current.payload, current.subtransactions, options.operationId);
      await this.validateD1ScheduledReferences(planId, transaction);
      try {
        await this.metadata.mutateScheduledTransaction(planId, transaction, current.origin, "scheduled_transaction.update", this.context("scheduled_transaction.update", planId, id, options.operationId), current.snapshot);
        return this.getScheduledTransaction(planId, id);
      } catch (error) {
        if (!isStaleScheduledTransaction(error) || options.expected || attempt === 3) throw error;
      }
    }
    throw new Error("Unable to update scheduled transaction");
  }

  override async deleteScheduledTransaction(planId: string, id: string, options: ScheduledWriteOptions = {}): Promise<any> {
    const context = this.context("scheduled_transaction.delete", planId, id, options.operationId);
    const receipt = options.operationId ? await this.d1.get("SELECT 1 FROM write_commands WHERE id=?", [context.operationId]) : null;
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const current = await this.readD1ScheduleForMutation(planId, id, Boolean(receipt));
      assertExpectedD1Schedule(current.payload, options.expected);
      if (current.payload.deleted && !receipt) throw new NotFoundError("Scheduled transaction not found");
      const transaction = {
        ...current.payload,
        deleted: true,
        subtransactions: current.subtransactions,
      } as unknown as EffectiveScheduledTransaction;
      try {
        await this.metadata.mutateScheduledTransaction(planId, transaction, current.origin, "scheduled_transaction.delete", context, current.snapshot);
        return { ...transaction, subtransactions: current.subtransactions };
      } catch (error) {
        if (!isStaleScheduledTransaction(error) || options.expected || attempt === 3) throw error;
      }
    }
    throw new Error("Unable to delete scheduled transaction");
  }

  private async readD1ScheduleForMutation(planId: string, id: string, includeDeleted = false): Promise<{ payload: Record<string, any>; subtransactions: Record<string, any>[]; origin: "howmuch-local" | "ynab-overlay"; snapshot: ScheduledMutationSnapshot }> {
    const edit = await this.d1.get<Record<string, any>>("SELECT origin,payload_json,deleted FROM scheduled_transaction_edits WHERE plan_id=? AND id=?", [planId, id]);
    if (edit) {
      if (Boolean(edit.deleted) && !includeDeleted) throw new NotFoundError("Scheduled transaction not found");
      const subs = await this.d1.all<Record<string, any>>("SELECT payload_json FROM scheduled_subtransaction_edits WHERE plan_id=? AND scheduled_transaction_id=? ORDER BY id", [planId, id]);
      return {
        payload: { ...JSON.parse(edit.payload_json), deleted: Boolean(edit.deleted) },
        subtransactions: subs.map((row) => JSON.parse(row.payload_json)),
        origin: edit.origin,
        snapshot: {
          source: "edit",
          payloadJson: String(edit.payload_json),
          subtransactionsJson: JSON.stringify(subs.map((row) => String(row.payload_json))),
          deleted: Number(Boolean(edit.deleted)),
        },
      };
    }
    const source = await this.d1.get<Record<string, any>>("SELECT payload_json,deleted FROM ynab_raw_objects WHERE plan_id=? AND object_type='scheduled_transaction' AND object_id=?", [planId, id]);
    if (!source || (Boolean(source.deleted) && !includeDeleted)) throw new NotFoundError("Scheduled transaction not found");
    const rawSubs = await this.d1.all<Record<string, any>>("SELECT payload_json FROM ynab_raw_objects WHERE plan_id=? AND object_type='scheduled_subtransaction' ORDER BY object_id", [planId]);
    const sourceSubtransactions = rawSubs.filter((row) => {
      const subtransaction = JSON.parse(row.payload_json) as Record<string, any>;
      return subtransaction.scheduled_transaction_id === id && !subtransaction.deleted;
    });
    return {
      payload: { ...JSON.parse(source.payload_json), deleted: Boolean(source.deleted) },
      subtransactions: sourceSubtransactions.map((row) => JSON.parse(row.payload_json)),
      origin: "ynab-overlay",
      snapshot: {
        source: "raw",
        payloadJson: String(source.payload_json),
        subtransactionsJson: JSON.stringify(sourceSubtransactions.map((row) => String(row.payload_json))),
        deleted: Number(Boolean(source.deleted)),
      },
    };
  }

  private async validateD1ScheduledReferences(planId: string, transaction: EffectiveScheduledTransaction): Promise<void> {
    const requireReference = async (table: "accounts" | "payees" | "categories", id: unknown, label: string) => {
      if (id == null) return null;
      const row = await this.d1.get<Record<string, any>>(`SELECT name FROM ${table} WHERE id=? AND plan_id=? AND deleted=0`, [id, planId]);
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

  override async createTransaction(planId:string,input:TransactionInput,options:TransactionWriteOptions={}):Promise<any>{
    const autoLink=options.autoLink??true;
    const id=input.id??(options.operationId?`txn_${scheduleId(`${planId}:${options.operationId}`)}`:createId("txn"));
    const row=await this.transactions.create(planId,{...input,id},this.context("transaction.create",planId,id,options.operationId),{autoLink,upsert:!autoLink});
    return this.getTransaction(planId,row.id,Boolean(input.deleted));
  }
  protected override async applyTransactionUpdate(planId:string,id:string,patch:Partial<TransactionInput>):Promise<void>{
    try {
      if (patch.approved !== undefined && Object.keys(patch).length === 1) {
        await this.transactions.approve(planId,id,patch.approved ?? false,this.context("transaction.approve",planId,id));
      } else {
        await this.transactions.update(planId,id,patch,this.context("transaction.update",planId,id));
      }
    } catch (error) {
      if (error instanceof Error && error.message.includes("reconciled transaction state conflict")) {
        throw new TransactionStateConflictError("Reconciled transactions cannot be changed to another cleared state");
      }
      throw error;
    }
  }
  protected override async applyTransactionCleared(planId:string,id:string,expectedCleared:"uncleared"|"cleared",cleared:"uncleared"|"cleared"):Promise<void>{
    try {
      await this.transactions.updateCleared(planId,id,expectedCleared,cleared,this.context("transaction.cleared",planId,id));
    } catch (error) {
      if (error instanceof Error && error.message.includes("cleared state conflict")) throw new TransactionStateConflictError();
      // Match the SQLite path: a row that is gone is `already_removed`, not an
      // infrastructure failure that stops the whole command.
      if (error instanceof Error && error.message === "Transaction not found") {
        throw new NotFoundError("Transaction not found");
      }
      throw error;
    }
  }
  protected override async applyTransactionDelete(planId:string,id:string,expectedApproved?:boolean):Promise<void>{
    try {
      await this.transactions.delete(planId,id,this.context("transaction.delete",planId,id),expectedApproved);
    } catch (error) {
      if (error instanceof Error && error.message.includes("approved state conflict")) {
        throw new TransactionStateConflictError("Transaction approval state changed");
      }
      if (error instanceof Error && error.message === "Transaction not found") {
        throw new NotFoundError("Transaction not found");
      }
      throw error;
    }
  }
  override async updateTransactions(planId: string, edits: TransactionBatchUpdate[]): Promise<TransactionBatchResult> {
    const ids: string[] = [];
    const seen = new Set<string>();
    for (const edit of edits) {
      const id = await this.resolveTransactionLookup(planId, edit.lookup);
      if (seen.has(id)) throw new ValidationError("Duplicate transaction in batch");
      seen.add(id);
      ids.push(id);
    }
    // Write-only per row: the committed row the writer returns is discarded here
    // and the batch response is hydrated once, at the end, from the final state.
    for (const [index, edit] of edits.entries()) {
      await this.applyTransactionUpdate(planId, ids[index]!, edit.patch);
    }
    return this.loadTransactionSaveResult(planId, ids, []);
  }
  override async createTransactions(planId: string, inputs: TransactionInput[]): Promise<TransactionBatchResult> {
    const explicitIds = inputs.map((input) => input.id).filter((id): id is string => Boolean(id));
    if (new Set(explicitIds).size !== explicitIds.length) {
      throw new ValidationError("Duplicate transaction id in batch");
    }
    const transactionIds: string[] = [];
    const duplicateImportIds: string[] = [];
    for (const input of inputs) {
      if (input.import_id && input.account_id) {
        const existing = await this.findTransactionByImportId(planId, input.import_id, input.account_id);
        if (existing) {
          duplicateImportIds.push(input.import_id);
          transactionIds.push(existing.id);
          continue;
        }
      }
      try {
        transactionIds.push((await this.createTransaction(planId, input)).id);
      } catch (error) {
        const raced = input.import_id && input.account_id
          ? await this.findTransactionByImportId(planId, input.import_id, input.account_id)
          : null;
        if (!raced) throw error;
        duplicateImportIds.push(input.import_id!);
        transactionIds.push(raced.id);
      }
    }
    return this.loadTransactionSaveResult(planId, transactionIds, duplicateImportIds);
  }
  override async importTransactions(planId:string,inputs:TransactionInput[]):Promise<{transaction_ids:string[];duplicate_import_ids:string[];duplicate_transaction_ids:string[];server_knowledge:number}>{
    const transaction_ids:string[]=[]; const duplicate_import_ids=new Set<string>(); const duplicate_transaction_ids=new Set<string>();
    for(const input of inputs){const duplicate=await this.findDuplicateTransaction(planId,input);if(duplicate){if(input.import_id)duplicate_import_ids.add(input.import_id);duplicate_transaction_ids.add(duplicate.id);}else transaction_ids.push((await this.createTransaction(planId,input,{autoLink:false})).id);}
    return {transaction_ids,duplicate_import_ids:[...duplicate_import_ids],duplicate_transaction_ids:[...duplicate_transaction_ids],server_knowledge:await this.getServerKnowledge(planId)};
  }
  override async createImportSession(planId:string|null,source:string):Promise<string>{return this.metadata.createImportSession(planId,source,this.context("import-session.create",planId??undefined,source));}
  override async finishImportSession(id:string,status:string,summary:unknown):Promise<void>{const row=await this.d1.get<{plan_id:string|null}>("SELECT plan_id FROM import_sessions WHERE id=?",[id]);await this.metadata.finishImportSession(id,status,summary,this.context("import-session.finish",row?.plan_id??undefined,id));}
  override async recordImportRow(sessionId:string,rowIndex:number,status:string,payload:unknown,error?:string,transactionId?:string):Promise<void>{const row=await this.d1.get<{plan_id:string|null}>("SELECT plan_id FROM import_sessions WHERE id=?",[sessionId]);await this.metadata.recordImportRow(sessionId,rowIndex,status,payload,error,transactionId,this.context("import-row.record",row?.plan_id??undefined,`${sessionId}:${rowIndex}`));}
}

const _d1LedgerStoreTypecheck: LedgerStore = null as unknown as D1LedgerRepository;
void _d1LedgerStoreTypecheck;

function normaliseReconciliationDate(date: string): string {
  if (typeof date !== "string" || !/^\d{4}-(0[1-9]|1[0-2])-([0-2]\d|3[01])$/.test(date)) {
    throw new ValidationError("statement_date must be an ISO date (YYYY-MM-DD)");
  }
  const parsed = new Date(`${date}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date) {
    throw new ValidationError("statement_date must be a valid ISO date");
  }
  return date;
}

function scheduleId(seed: string): string {
  return createHash("sha256").update(seed).digest("hex").slice(0, 24);
}

function assertExpectedD1Schedule(payload: Record<string, any>, expected: ScheduledWriteOptions["expected"]): void {
  if (!expected) return;
  if (payload.date_first !== expected.date_first || payload.date_next !== expected.date_next || payload.frequency !== expected.frequency) {
    throw new Error("stale scheduled occurrence");
  }
}

function isStaleScheduledTransaction(error: unknown): boolean {
  return String(error).includes("stale scheduled transaction");
}

function d1DerivedEntityId(prefix: string, planId: string, operationId?: string): string {
  return operationId ? `${prefix}_${scheduleId(`${planId}:${operationId}`)}` : createId(prefix);
}

function categoryAssertion(commandId: string, kind: string, targetId: string, planId: string): PlannedSql {
  return { sql: "INSERT INTO write_assertions(command_id,kind,target_id,plan_id) VALUES (?,?,?,?)", values: [commandId, kind, targetId, planId] };
}

