import { createId } from "./ids";
import type { TransactionInput } from "./types";
import type { D1Database } from "./d1";
import type { SqlValues } from "./async-sql";
import { createHash } from "node:crypto";

export type PlannedStatement = Readonly<{ sql: string; values: Readonly<SqlValues> }>;
export type D1WriteContext = Readonly<{
  operationId: string;
  lease?: Readonly<{ planId: string; attemptId: string }>;
}>;
export type D1TransactionWriteOptions = Readonly<{ autoLink?: boolean; upsert?: boolean }>;
export type D1TransactionPlan = Readonly<{
  commandId: string;
  expectedWriteVersion: number;
  transactionId: string;
  statements: readonly PlannedStatement[];
}>;

type Snapshot = { writeVersion: number; transaction: Record<string, any> | null; subs: Record<string, any>[]; mirrors: Record<string, any>[]; linkedSub: Record<string, any> | null };

/**
 * Atomic D1 writer for ordinary (non-split, non-transfer) transactions.
 * Planning only reads; execution submits the complete immutable graph at once.
 */
export class D1TransactionRepository {
  constructor(private readonly db: D1Database, private readonly maxStaleRetries = 3) {}

  async create(planId: string, input: TransactionInput, context?: D1WriteContext, options: D1TransactionWriteOptions = {}): Promise<Record<string, any>> {
    const stable = identity(input.id ?? (context ? `${context.operationId}:transaction` : createId("txn")), context);
    const autoLink = options.autoLink ?? true;
    const fingerprint = requestHash({ input, autoLink, upsert: options.upsert ?? false });
    this.assertContext(planId, context);
    return this.write("create", planId, stable, fingerprint, context, async (snapshot) => {
      if (snapshot.transaction && !options.upsert) throw new Error("Transaction already exists");
      if (snapshot.transaction?.plan_id !== undefined && snapshot.transaction.plan_id !== planId) throw new Error("Transaction belongs to another plan");
      return this.planUpsert("create", planId, { ...input, id: stable.transactionId }, snapshot, stable, false, fingerprint, context, autoLink);
    });
  }

  async update(planId: string, transactionId: string, patch: Partial<TransactionInput>, context?: D1WriteContext): Promise<Record<string, any>> {
    const stable = identity(transactionId, context);
    const fingerprint = requestHash(patch);
    this.assertContext(planId, context);
    return this.write("update", planId, stable, fingerprint, context, async (snapshot) => {
      if (snapshot.linkedSub) throw new Error("This transaction is the linked side of a split line; edit the split parent");
      const old = snapshot.transaction;
      if (!old || old.deleted) throw new Error("Transaction not found");
      if (old.plan_id !== planId) throw new Error("Transaction belongs to another plan");
      const merged: TransactionInput = {
        id: transactionId, account_id: patch.account_id ?? old.account_id, date: patch.date ?? old.date,
        amount: patch.amount ?? old.amount_milli, memo: patch.memo === undefined ? old.memo : patch.memo,
        cleared: patch.cleared ?? old.cleared, approved: patch.approved ?? Boolean(old.approved),
        payee_id: patch.payee_id === undefined ? old.payee_id : patch.payee_id,
        payee_name: patch.payee_name === undefined ? old.payee_name_snapshot : patch.payee_name,
        category_id: patch.category_id === undefined ? old.category_id : patch.category_id,
        flag_color: patch.flag_color === undefined ? old.flag_color : patch.flag_color,
        flag_name: patch.flag_name === undefined ? old.flag_name : patch.flag_name,
        matched_transaction_id: patch.matched_transaction_id === undefined ? old.matched_transaction_id : patch.matched_transaction_id,
        import_id: old.import_id,
        import_payee_name: patch.import_payee_name === undefined ? old.import_payee_name : patch.import_payee_name,
        import_payee_name_original: patch.import_payee_name_original === undefined ? old.import_payee_name_original : patch.import_payee_name_original,
        source_kind: patch.source_kind === undefined ? old.source_kind : patch.source_kind,
        source_ref: patch.source_ref === undefined ? old.source_ref : patch.source_ref,
        external_ynab_id: patch.external_ynab_id === undefined ? old.external_ynab_id : patch.external_ynab_id,
        transfer_account_id: patch.transfer_account_id === undefined ? old.transfer_account_id : patch.transfer_account_id,
        transfer_transaction_id: patch.transfer_transaction_id === undefined ? old.transfer_transaction_id : patch.transfer_transaction_id,
        deleted: Boolean(old.deleted), subtransactions: patch.subtransactions === undefined ? snapshot.subs.map(subInput) : patch.subtransactions,
      };
      return this.planUpsert("update", planId, merged, snapshot, stable, patch.payee_id !== undefined, fingerprint, context, true);
    });
  }

  async approve(planId: string, transactionId: string, approved: boolean, context?: D1WriteContext): Promise<Record<string, any>> {
    const stable = identity(transactionId, context);
    const fingerprint = requestHash({ approved });
    this.assertContext(planId, context);
    return this.write("approve", planId, stable, fingerprint, context, async (snapshot) => {
      const target = snapshot.transaction;
      if (!target || target.deleted) throw new Error("Transaction not found");
      if (target.plan_id !== planId) throw new Error("Transaction belongs to another plan");
      const parentId = snapshot.linkedSub?.transaction_id ?? transactionId;
      const rows = await this.db.all<Record<string, any>>(
        `SELECT * FROM transactions WHERE plan_id = ? AND deleted = 0 AND (
           id = ? OR transfer_transaction_id = ? OR id IN (
             SELECT transfer_transaction_id FROM subtransactions
             WHERE transaction_id = ? AND deleted = 0 AND transfer_transaction_id IS NOT NULL
           )
         ) ORDER BY id`,
        [planId, parentId, parentId, parentId],
      );
      const body: PlannedStatement[] = rows.map((row) => assertion(stable.commandId, "graph_transaction", row.id, planId));
      body.push(statement(
        `UPDATE transactions SET approved = ?, updated_at = CURRENT_TIMESTAMP
         WHERE plan_id = ? AND deleted = 0 AND id IN (${rows.map(() => "?").join(",")})`,
        [approved ? 1 : 0, planId, ...rows.map((row) => row.id)],
      ));
      for (const row of rows) body.push(knowledge(planId, row.id));
      return makePlan(stable.commandId, snapshot.writeVersion, transactionId, planId, "approve", fingerprint, context, body);
    });
  }

  async delete(planId: string, transactionId: string, context?: D1WriteContext): Promise<Record<string, any>> {
    const stable = identity(transactionId, context);
    this.assertContext(planId, context);
    return this.write("delete", planId, stable, requestHash({}), context, async (snapshot) => {
      if (snapshot.linkedSub) throw new Error("This transaction is the linked side of a split line; edit the split parent");
      if (!snapshot.transaction || snapshot.transaction.deleted) throw new Error("Transaction not found");
      if (snapshot.transaction.plan_id !== planId) throw new Error("Transaction belongs to another plan");
      const affected = new Set<string>([snapshot.transaction.account_id, ...snapshot.mirrors.map((row) => row.account_id)]);
      const rows = [snapshot.transaction, ...snapshot.mirrors];
      const body: PlannedStatement[] = [assertion(stable.commandId, "graph_update_target", transactionId, planId)];
      for (const row of rows) body.push(assertion(stable.commandId, "graph_transaction", row.id, planId));
      for (const sub of snapshot.subs) body.push(assertion(stable.commandId, "graph_subtransaction", sub.id, planId));
      body.push(statement(`UPDATE transactions SET deleted=1, updated_at=CURRENT_TIMESTAMP WHERE plan_id=? AND id IN (${rows.map(() => "?").join(",")})`, [planId, ...rows.map((r) => r.id)]));
      if (snapshot.subs.length) body.push(statement("UPDATE subtransactions SET deleted=1, updated_at=CURRENT_TIMESTAMP WHERE transaction_id=?", [transactionId]));
      for (const account of affected) body.push(recalculate(account));
      for (const row of rows) body.push(knowledge(planId, row.id));
      return makePlan(stable.commandId, snapshot.writeVersion, transactionId, planId, "delete", requestHash({}), context, [
        ...body,
      ]);
    });
  }

  private async write(kind: string, planId: string, stable: { transactionId: string; commandId: string; sourceEventId: string }, fingerprint: string, context: D1WriteContext | undefined, planner: (snapshot: Snapshot) => Promise<D1TransactionPlan>): Promise<Record<string, any>> {
    for (let attempt = 0; attempt <= this.maxStaleRetries; attempt++) {
      const replay = await this.commandResult(stable.commandId, kind, planId, stable.transactionId, fingerprint, context?.lease);
      if (replay) return this.readResult(planId, stable.transactionId);
      const snapshot = await this.snapshot(stable.transactionId);
      const plan = await planner(snapshot);
      try {
        const results = await this.db.atomicBatch<Record<string, any>>(
          plan.statements.map((item) => ({ sql: item.sql, values: [...item.values] })),
        );
        const committed = results.at(-1)?.results?.[0];
        if (!committed) throw new Error("Committed transaction result is missing from D1 batch");
        return committed;
      } catch (error) {
        // A transport failure can hide a committed batch. The command is the receipt.
        if (await this.commandResult(stable.commandId, kind, planId, stable.transactionId, fingerprint, context?.lease)) return this.readResult(planId, stable.transactionId);
        if (!String(error).includes("stale write command") || attempt === this.maxStaleRetries) throw error;
      }
    }
    throw new Error(`Unable to apply ${kind}`);
  }

  private async snapshot(transactionId: string): Promise<Snapshot> {
    const results = await this.db.atomicBatch<Record<string, any>>([
      { sql: "SELECT write_version FROM write_state WHERE singleton = 1" },
      { sql: "SELECT * FROM transactions WHERE id = $1", values: [transactionId] },
      { sql: "SELECT * FROM subtransactions WHERE transaction_id = $1 AND deleted = 0 ORDER BY id", values: [transactionId] },
      { sql: `SELECT * FROM transactions WHERE id IN (
          SELECT transfer_transaction_id FROM transactions WHERE id=$1 AND transfer_transaction_id IS NOT NULL
          UNION SELECT transfer_transaction_id FROM subtransactions WHERE transaction_id=$1 AND deleted=0 AND transfer_transaction_id IS NOT NULL
          UNION SELECT id FROM transactions WHERE transfer_transaction_id=$1 AND deleted=0
        ) ORDER BY id`, values: [transactionId] },
      { sql: `SELECT s.*,t.plan_id parent_plan_id FROM subtransactions s JOIN transactions t ON t.id=s.transaction_id
              WHERE s.id=(SELECT transfer_transaction_id FROM transactions WHERE id=$1) AND s.deleted=0`, values: [transactionId] },
    ]);
    const state = results[0]?.results?.[0] as { write_version: number } | undefined;
    const transaction = results[1]?.results?.[0] ?? null;
    if (!state) throw new Error("D1 write_state is not initialized");
    return {
      writeVersion: Number(state.write_version),
      transaction,
      subs: results[2]?.results ?? [], mirrors: results[3]?.results ?? [], linkedSub: results[4]?.results?.[0] ?? null,
    };
  }

  private async planUpsert(kind: string, planId: string, input: TransactionInput, snapshot: Snapshot, stable: { transactionId: string; commandId: string; sourceEventId: string }, payeeChanged: boolean, fingerprint: string, context: D1WriteContext | undefined, autoLink: boolean): Promise<D1TransactionPlan> {
    this.assertInput(input);
    const account = await this.db.get<Record<string, any>>("SELECT * FROM accounts WHERE id = $1 AND plan_id = $2 AND deleted = 0", [input.account_id, planId]);
    if (!account) throw new Error("Account not found");
    const payee = input.payee_id ? await this.db.get<Record<string, any>>("SELECT id, name, transfer_account_id FROM payees WHERE id = $1 AND plan_id = $2 AND deleted = 0", [input.payee_id, planId]) : null;
    if (input.payee_id && !payee) throw new Error("Payee not found");
    const category = input.category_id ? await this.db.get<Record<string, any>>("SELECT id, name FROM categories WHERE id = $1 AND plan_id = $2 AND deleted = 0", [input.category_id, planId]) : null;
    if (input.category_id && !category) throw new Error("Category not found");
    if (snapshot.transaction && snapshot.transaction.plan_id !== planId) throw new Error("Transaction belongs to another plan");
    const body: PlannedStatement[] = [assertion(stable.commandId, "account", input.account_id, planId)];
    const touched = new Set<string>([input.id!]);
    const accounts = new Set<string>([input.account_id]);
    if (snapshot.transaction) accounts.add(snapshot.transaction.account_id);
    if (snapshot.transaction) body.push(assertion(stable.commandId, snapshot.subs.length || snapshot.transaction.transfer_transaction_id ? "graph_update_target" : "update_target", input.id!, planId));
    for (const row of snapshot.mirrors) { body.push(assertion(stable.commandId, "graph_transaction", row.id, planId)); accounts.add(row.account_id); }
    for (const sub of snapshot.subs) body.push(assertion(stable.commandId, "graph_subtransaction", sub.id, planId));

    let transferAccount = (autoLink ? payee?.transfer_account_id : null) ?? input.transfer_account_id ?? null;
    let transferId = input.transfer_transaction_id ?? snapshot.transaction?.transfer_transaction_id ?? null;
    // Replacing a transfer payee with an ordinary payee breaks the pair.
    if (autoLink && snapshot.transaction?.transfer_transaction_id && payeeChanged && !payee?.transfer_account_id) {
      body.push(statement("UPDATE transactions SET deleted=1, updated_at=CURRENT_TIMESTAMP WHERE id=? AND plan_id=?", [snapshot.transaction.transfer_transaction_id, planId]));
      touched.add(snapshot.transaction.transfer_transaction_id); transferId = null; transferAccount = null;
    }
    if (autoLink && transferAccount && snapshot.transaction?.transfer_transaction_id && transferId !== snapshot.transaction.transfer_transaction_id) {
      throw new Error("An existing transfer mirror ID cannot be replaced");
    }
    if (input.subtransactions?.length && transferAccount) throw new Error("A split transaction cannot itself be a transfer; use a transfer subtransaction instead");
    if (transferAccount && transferAccount === input.account_id) throw new Error("Transfer target must be a different account");
    let parentPayeeId = input.payee_id ?? null;
    let parentPayeeName = input.payee_name ?? payee?.name ?? null;
    if (input.payee_id && (!transferAccount || !autoLink)) body.push(assertion(stable.commandId, payee?.transfer_account_id ? "transfer_payee" : "payee", input.payee_id, planId));
    if (input.category_id && !input.subtransactions?.length && (!transferAccount || !autoLink)) body.push(assertion(stable.commandId, "category", input.category_id, planId));
    if (transferAccount && autoLink) {
      const target = await this.db.get<Record<string, any>>("SELECT * FROM accounts WHERE id=$1 AND plan_id=$2 AND deleted=0", [transferAccount, planId]);
      if (!target) throw new Error("Transfer account not found");
      body.push(assertion(stable.commandId, "account", transferAccount, planId)); accounts.add(transferAccount);
      if (!transferId) transferId = stableId(stable.commandId, "mirror", input.id!);
      const sourcePayee = await this.db.get<Record<string, any>>("SELECT id,name FROM payees WHERE id=$1 AND plan_id=$2 AND deleted=0", [account.transfer_payee_id, planId]);
      if (!sourcePayee) throw new Error("Source account transfer payee not found");
      if (input.payee_id) body.push(assertion(stable.commandId, "transfer_payee", input.payee_id, planId));
      body.push(assertion(stable.commandId, "upsert_transaction", transferId, planId));
      body.push(assertion(stable.commandId, "mirror_transaction", transferId, input.id!));
      body.push(upsertTransaction({ id: transferId, planId, accountId: transferAccount, date: input.date, amount: -input.amount, memo: input.memo, cleared: input.source_kind === "scheduled-transaction" ? (target.type === "cash" ? "cleared" : "uncleared") : input.cleared, approved: input.approved, payeeId: sourcePayee.id, payeeName: sourcePayee.name, transferAccountId: input.account_id, transferTransactionId: input.id! }));
      touched.add(transferId);
    } else if (transferAccount) {
      const target = await this.db.get<Record<string, any>>("SELECT id FROM accounts WHERE id=$1 AND plan_id=$2 AND deleted=0", [transferAccount, planId]);
      if (!target) throw new Error("Transfer account not found");
      body.push(assertion(stable.commandId, "account", transferAccount, planId));
    }
    const parentCategory = input.subtransactions?.length || (autoLink && transferAccount) ? null : input.category_id ?? null;
    body.push(assertion(stable.commandId, "upsert_transaction", input.id!, planId));
    body.push(upsertTransaction({ id: input.id!, planId, accountId: input.account_id, date: input.date, amount: input.amount, memo: input.memo, cleared: input.cleared, approved: input.approved, payeeId: parentPayeeId, payeeName: parentPayeeName, categoryId: parentCategory, categoryName: parentCategory ? category?.name : null, transferAccountId: transferAccount, transferTransactionId: transferId, deleted: input.deleted, extra: input }));

    const keptSubs = new Set<string>(); const keptMirrors = new Set<string>();
    for (let index = 0; index < (input.subtransactions?.length ?? 0); index++) {
      const sub = input.subtransactions![index]!;
      const id = sub.id ?? stableId(stable.commandId, "sub", String(index)); keptSubs.add(id);
      const subPayee = sub.payee_id ? await this.db.get<Record<string, any>>("SELECT id,name,transfer_account_id FROM payees WHERE id=$1 AND plan_id=$2 AND deleted=0", [sub.payee_id, planId]) : null;
      if (sub.payee_id && !subPayee) throw new Error("Payee not found");
      const subCategory = sub.category_id ? await this.db.get<Record<string, any>>("SELECT id,name FROM categories WHERE id=$1 AND plan_id=$2 AND deleted=0", [sub.category_id, planId]) : null;
      if (sub.category_id && !subCategory) throw new Error("Category not found");
      const oldSub = snapshot.subs.find((s) => s.id === id);
      let subTarget = (autoLink ? subPayee?.transfer_account_id : null) ?? sub.transfer_account_id ?? null;
      let subMirror = sub.transfer_transaction_id ?? oldSub?.transfer_transaction_id ?? null;
      if (!subTarget && oldSub?.transfer_transaction_id) {
        body.push(statement("UPDATE transactions SET deleted=1,updated_at=CURRENT_TIMESTAMP WHERE id=? AND plan_id=?", [oldSub.transfer_transaction_id,planId]));
        touched.add(oldSub.transfer_transaction_id); subMirror=null;
      }
      if (autoLink && subTarget && oldSub?.transfer_transaction_id && subMirror !== oldSub.transfer_transaction_id) {
        throw new Error("An existing transfer mirror ID cannot be replaced");
      }
      if (subTarget && autoLink) {
        if (subTarget === input.account_id) throw new Error("Transfer target must be a different account");
        const target = await this.db.get<Record<string, any>>("SELECT * FROM accounts WHERE id=$1 AND plan_id=$2 AND deleted=0", [subTarget, planId]);
        if (!target) throw new Error("Transfer account not found");
        body.push(assertion(stable.commandId, "account", subTarget, planId));
        if (sub.payee_id) body.push(assertion(stable.commandId, "transfer_payee", sub.payee_id, planId));
        accounts.add(subTarget);
        if (!subMirror) subMirror = stableId(stable.commandId, "submirror", id);
        const sourcePayee = await this.db.get<Record<string, any>>("SELECT id,name FROM payees WHERE id=$1 AND plan_id=$2 AND deleted=0", [account.transfer_payee_id, planId]);
        if (!sourcePayee) throw new Error("Source account transfer payee not found");
        body.push(assertion(stable.commandId, "upsert_transaction", subMirror, planId));
        body.push(assertion(stable.commandId, "mirror_transaction", subMirror, id));
        body.push(upsertTransaction({ id: subMirror, planId, accountId: subTarget, date: input.date, amount: -sub.amount, memo: sub.memo, cleared: input.source_kind === "scheduled-transaction" && target.type === "cash" ? "cleared" : "uncleared", approved: input.approved, payeeId: sourcePayee.id, payeeName: sourcePayee.name, transferAccountId: input.account_id, transferTransactionId: id }));
        keptMirrors.add(subMirror); touched.add(subMirror);
      } else if (subTarget) {
        const target = await this.db.get<Record<string, any>>("SELECT id FROM accounts WHERE id=$1 AND plan_id=$2 AND deleted=0", [subTarget,planId]);
        if (!target) throw new Error("Transfer account not found");
        body.push(assertion(stable.commandId,"account",subTarget,planId));
        if(sub.payee_id) body.push(assertion(stable.commandId,subPayee?.transfer_account_id?"transfer_payee":"payee",sub.payee_id,planId));
      }
      if (sub.category_id && (!subTarget || !autoLink)) body.push(assertion(stable.commandId, "category", sub.category_id, planId));
      body.push(assertion(stable.commandId, "upsert_subtransaction", id, planId));
      body.push(assertion(stable.commandId, "upsert_subtransaction_parent", id, input.id!));
      body.push(upsertSubtransaction(id, input.id!, sub, subPayee, subCategory, subTarget, subMirror));
    }
    for (const old of snapshot.subs) if (!keptSubs.has(old.id)) {
      body.push(statement("UPDATE subtransactions SET deleted=1, updated_at=CURRENT_TIMESTAMP WHERE id=?", [old.id]));
      if (old.transfer_transaction_id && !keptMirrors.has(old.transfer_transaction_id)) { body.push(statement("UPDATE transactions SET deleted=1, updated_at=CURRENT_TIMESTAMP WHERE id=? AND plan_id=?", [old.transfer_transaction_id, planId])); touched.add(old.transfer_transaction_id); }
    }
    if (input.source_kind || input.source_ref) body.push(statement("INSERT INTO source_events (id, plan_id, transaction_id, source_kind, source_ref, payload_json) VALUES (?, ?, ?, ?, ?, ?)", [stable.sourceEventId, planId, input.id!, input.source_kind ?? "api", input.source_ref ?? null, JSON.stringify(input)]));
    for (const accountId of accounts) body.push(recalculate(accountId));
    for (const id of touched) body.push(knowledge(planId, id));
    return makePlan(stable.commandId, snapshot.writeVersion, input.id!, planId, kind, fingerprint, context, body);
  }

  private assertInput(input: Partial<TransactionInput>): void {
    if (!input.account_id || typeof input.account_id !== "string") throw new Error("account_id is required");
    if (!input.date || !/^\d{4}-\d{2}-\d{2}$/.test(input.date)) throw new Error("date must use YYYY-MM-DD");
    if (!Number.isInteger(input.amount)) throw new Error("amount must be an integer number of milliunits");
    if (input.cleared && !["cleared", "uncleared", "reconciled"].includes(input.cleared)) {
      throw new Error("cleared must be cleared, uncleared, or reconciled");
    }
    if (input.subtransactions?.length) {
      if (input.subtransactions.length < 2) throw new Error("split transactions need at least two subtransactions");
      if (input.subtransactions.some((sub) => !Number.isInteger(sub.amount))) throw new Error("subtransaction amounts must be integer milliunits");
      const sum = input.subtransactions.reduce((total, sub) => total + sub.amount, 0);
      if (sum !== input.amount) throw new Error(`subtransactions must sum to the transaction amount (lines total ${sum}, transaction is ${input.amount})`);
    }
  }
  private assertContext(planId: string, context?: D1WriteContext): void {
    if (context && !context.operationId) throw new Error("operationId is required");
    if (context?.lease && context.lease.planId !== planId) throw new Error("Scheduler lease plan does not match transaction plan");
  }
  private async commandResult(id: string, kind: string, planId: string, transactionId: string, fingerprint: string, lease?: D1WriteContext["lease"]) {
    const row = await this.db.get<Record<string, any>>("SELECT kind, plan_id, transaction_id, request_hash, lease_plan_id, lease_attempt_id, status FROM write_commands WHERE id = $1", [id]);
    if (!row) return null;
    if (row.kind !== `transaction.${kind}` || row.plan_id !== planId || row.transaction_id !== transactionId || row.request_hash !== fingerprint
      || row.lease_plan_id !== (lease?.planId ?? null) || row.lease_attempt_id !== (lease?.attemptId ?? null)) {
      throw new Error("idempotency-key reuse");
    }
    return row.status === "applied" ? row : null;
  }
  private async readResult(planId: string, id: string): Promise<Record<string, any>> {
    const row = await this.db.get<Record<string, any>>("SELECT * FROM transactions WHERE id = $1 AND plan_id = $2", [id, planId]);
    if (!row) throw new Error("Committed transaction result is missing");
    return row;
  }
}

function statement(sql: string, values: SqlValues = []): PlannedStatement { return Object.freeze({ sql, values: Object.freeze([...values]) }); }
function stableId(operationId: string, kind: string, seed: string): string {
  return `${kind}_${createHash("sha256").update(`${operationId}:${kind}:${seed}`).digest("hex").slice(0, 24)}`;
}
function subInput(row: Record<string, any>) {
  return { id: row.id, amount: row.amount_milli, memo: row.memo, payee_id: row.payee_id, payee_name: row.payee_name_snapshot, category_id: row.category_id, transfer_account_id: row.transfer_account_id, transfer_transaction_id: row.transfer_transaction_id, external_ynab_id: row.external_ynab_id };
}
function upsertTransaction(value: Record<string, any>): PlannedStatement {
  const extra = value.extra ?? {};
  const columns = "id,plan_id,account_id,date,amount_milli,memo,cleared,approved,flag_color,flag_name,payee_id,payee_name_snapshot,category_id,category_name_snapshot,transfer_account_id,transfer_transaction_id,matched_transaction_id,import_id,import_payee_name,import_payee_name_original,source_kind,source_ref,external_ynab_id,deleted";
  const values = [value.id,value.planId,value.accountId,value.date,value.amount,value.memo??null,value.cleared??"uncleared",value.approved?1:0,extra.flag_color??null,extra.flag_name??null,value.payeeId??null,value.payeeName??null,value.categoryId??null,value.categoryName??null,value.transferAccountId??null,value.transferTransactionId??null,extra.matched_transaction_id??null,extra.import_id??null,extra.import_payee_name??null,extra.import_payee_name_original??null,extra.source_kind??null,extra.source_ref??null,extra.external_ynab_id??value.id,value.deleted?1:0];
  return statement(`INSERT INTO transactions (${columns},updated_at) VALUES (${values.map(() => "?").join(",")},CURRENT_TIMESTAMP) ON CONFLICT(id) DO UPDATE SET account_id=excluded.account_id,date=excluded.date,amount_milli=excluded.amount_milli,memo=excluded.memo,cleared=excluded.cleared,approved=excluded.approved,flag_color=excluded.flag_color,flag_name=excluded.flag_name,payee_id=excluded.payee_id,payee_name_snapshot=excluded.payee_name_snapshot,category_id=excluded.category_id,category_name_snapshot=excluded.category_name_snapshot,transfer_account_id=excluded.transfer_account_id,transfer_transaction_id=excluded.transfer_transaction_id,matched_transaction_id=excluded.matched_transaction_id,import_id=excluded.import_id,import_payee_name=excluded.import_payee_name,import_payee_name_original=excluded.import_payee_name_original,source_kind=excluded.source_kind,source_ref=excluded.source_ref,external_ynab_id=excluded.external_ynab_id,deleted=excluded.deleted,updated_at=CURRENT_TIMESTAMP`, values);
}
function upsertSubtransaction(id: string, parentId: string, sub: Record<string, any>, payee: Record<string, any> | null, category: Record<string, any> | null, transferAccountId: string | null, transferTransactionId: string | null): PlannedStatement {
  const values = [id,parentId,sub.amount,sub.memo??null,sub.payee_id??null,sub.payee_name??payee?.name??null,transferAccountId?null:sub.category_id??null,transferAccountId?null:category?.name??null,transferAccountId,transferTransactionId,sub.external_ynab_id??id];
  return statement(`INSERT INTO subtransactions (id,transaction_id,amount_milli,memo,payee_id,payee_name_snapshot,category_id,category_name_snapshot,transfer_account_id,transfer_transaction_id,external_ynab_id,deleted,updated_at) VALUES (${values.map(() => "?").join(",")},0,CURRENT_TIMESTAMP) ON CONFLICT(id) DO UPDATE SET transaction_id=excluded.transaction_id,amount_milli=excluded.amount_milli,memo=excluded.memo,payee_id=excluded.payee_id,payee_name_snapshot=excluded.payee_name_snapshot,category_id=excluded.category_id,category_name_snapshot=excluded.category_name_snapshot,transfer_account_id=excluded.transfer_account_id,transfer_transaction_id=excluded.transfer_transaction_id,external_ynab_id=excluded.external_ynab_id,deleted=0,updated_at=CURRENT_TIMESTAMP`, values);
}
function recalculate(accountId: string): PlannedStatement { return statement(`UPDATE accounts SET balance_milli = opening_balance_milli + COALESCE((SELECT SUM(amount_milli) FROM transactions WHERE account_id = ? AND deleted = 0), 0), cleared_balance_milli = opening_balance_milli + COALESCE((SELECT SUM(amount_milli) FROM transactions WHERE account_id = ? AND deleted = 0 AND cleared IN ('cleared', 'reconciled')), 0), uncleared_balance_milli = COALESCE((SELECT SUM(amount_milli) FROM transactions WHERE account_id = ? AND deleted = 0 AND cleared = 'uncleared'), 0), updated_at = CURRENT_TIMESTAMP WHERE id = ?`, [accountId, accountId, accountId, accountId]); }
function knowledge(planId: string, transactionId: string): PlannedStatement { return statement("UPDATE transactions SET server_knowledge = (SELECT server_knowledge + 1 FROM plans WHERE id = ?), updated_at = CURRENT_TIMESTAMP WHERE id = ? AND plan_id = ?", [planId, transactionId, planId]); }
const ASSERTION_SQL = "INSERT INTO write_assertions (command_id, kind, target_id, plan_id) VALUES (?, ?, ?, ?)";
function assertion(commandId: string, kind: string, targetId: string, planId: string) { return statement(ASSERTION_SQL, [commandId, kind, targetId, planId]); }
function identity(transactionId: string, context?: D1WriteContext) {
  const operationId = context?.operationId ?? createId("cmd");
  return { transactionId, commandId: operationId, sourceEventId: `${operationId}:source` };
}
function makePlan(commandId: string, version: number, transactionId: string, planId: string, kind: string, fingerprint: string, context: D1WriteContext | undefined, body: PlannedStatement[]): D1TransactionPlan {
  const result = JSON.stringify({ transactionId });
  const assertionKeys = new Set<string>();
  const deduplicatedBody = body.filter((item) => {
    if (item.sql !== ASSERTION_SQL) return true;
    const key = canonicalJson(item.values);
    if (assertionKeys.has(key)) return false;
    assertionKeys.add(key);
    return true;
  });
  const statements = Object.freeze([
    statement("INSERT INTO write_commands (id, expected_write_version, kind, plan_id, transaction_id, request_hash, result_json, lease_plan_id, lease_attempt_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", [commandId, version, `transaction.${kind}`, planId, transactionId, fingerprint, result, context?.lease?.planId ?? null, context?.lease?.attemptId ?? null]),
    ...deduplicatedBody,
    statement("UPDATE plans SET server_knowledge = server_knowledge + 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?", [planId]),
    statement("UPDATE write_state SET write_version = write_version + 1, last_command_id = ? WHERE singleton = 1", [commandId]),
    statement("UPDATE write_commands SET status = 'applied', applied_at = CURRENT_TIMESTAMP WHERE id = ?", [commandId]),
    statement("SELECT * FROM transactions WHERE id = ? AND plan_id = ?", [transactionId, planId]),
  ]);
  return Object.freeze({ commandId, expectedWriteVersion: version, transactionId, statements });
}

function requestHash(value: unknown): string {
  return createHash("sha256").update(canonicalJson(value)).digest("hex");
}
function canonicalJson(value: unknown): string {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  return `{${Object.keys(value as Record<string, unknown>).filter((key) => (value as any)[key] !== undefined).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson((value as any)[key])}`).join(",")}}`;
}
