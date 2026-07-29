import { createHash } from "node:crypto";
import { createId } from "./ids";
import type { D1Database } from "./d1";
import type { D1WriteContext } from "./d1-transaction-repository";
import { D1GuardedCommandExecutor, statement } from "./d1-guarded-command";

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

  async upsertPlan(planId: string, plan: any, settings?: any, context?: D1WriteContext): Promise<void> {
    const payload = { plan, settings };
    const date = JSON.stringify(settings?.date_format ?? { format: "DD/MM/YYYY" });
    const currency = JSON.stringify(settings?.currency_format ?? { iso_code: "SGD", example_format: "$123,456.78", decimal_digits: 2, decimal_separator: ".", symbol_first: true, group_separator: ",", currency_symbol: "$", display_symbol: true });
    const flags = JSON.stringify(settings?.display?.flag_names ?? {});
    await this.run("metadata.plan.upsert", planId, planId, payload, context, [
      statement("INSERT INTO write_assertions(command_id,kind,target_id,plan_id) VALUES (?, 'metadata_plan', ?, ?)", [this.id(context), planId, planId]),
      statement(`INSERT INTO plans(id,name,first_month,last_month,date_format_json,currency_format_json,flag_names_json,external_ynab_id,deleted,updated_at) VALUES (?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name,first_month=COALESCE(excluded.first_month,plans.first_month),last_month=COALESCE(excluded.last_month,plans.last_month),date_format_json=excluded.date_format_json,currency_format_json=excluded.currency_format_json,flag_names_json=excluded.flag_names_json,external_ynab_id=excluded.external_ynab_id,deleted=excluded.deleted,updated_at=CURRENT_TIMESTAMP`, [planId, plan.name ?? "HowMuch", plan.first_month ?? null, plan.last_month ?? null, date, currency, flags, plan.id ?? plan.external_ynab_id ?? planId, bool(plan.deleted)]),
    ]);
  }

  async ensureAccount(planId: string, accountId: string, name?: string, context?: D1WriteContext): Promise<void> {
    return this.upsertAccount(planId, { id: accountId, name: name ?? `Imported account ${accountId.slice(0, 8)}` }, context, true);
  }

  async upsertAccount(planId: string, account: any, context?: D1WriteContext, ensureOnly = false, incrementKnowledge = false): Promise<void> {
    const payeeId = account.transfer_payee_id ?? transferPayeeId(planId, account.id);
    const payeeName = `Transfer : ${account.name ?? `Account ${account.id}`}`;
    const commandId = this.id(context);
    if (ensureOnly) {
      await this.run("metadata.account.ensure", planId, account.id, { account, ensureOnly, incrementKnowledge }, context, [
        assertion(commandId, "metadata_plan_exists", planId, planId),
        assertion(commandId, "metadata_account", account.id, planId),
        assertion(commandId, "metadata_payee", payeeId, planId),
        statement(`INSERT INTO payees(id,plan_id,name,transfer_account_id,external_ynab_id,deleted,updated_at)
          SELECT ?,?,?,?,?,0,CURRENT_TIMESTAMP WHERE NOT EXISTS (SELECT 1 FROM accounts WHERE id=?)
          ON CONFLICT(id) DO NOTHING`, [payeeId, planId, payeeName, account.id, payeeId, account.id]),
        statement(`INSERT INTO accounts(id,plan_id,name,transfer_payee_id,external_ynab_id)
          SELECT ?,?,?,?,? WHERE NOT EXISTS (SELECT 1 FROM accounts WHERE id=?)
          ON CONFLICT(id) DO NOTHING`, [account.id, planId, account.name ?? `Imported account ${account.id.slice(0, 8)}`, payeeId, account.external_ynab_id ?? account.id, account.id]),
      ]);
      return;
    }
    const conflict = `DO UPDATE SET name=excluded.name,type=excluded.type,on_budget=excluded.on_budget,closed=excluded.closed,opening_balance_milli=excluded.opening_balance_milli,balance_milli=excluded.balance_milli,cleared_balance_milli=excluded.cleared_balance_milli,uncleared_balance_milli=excluded.uncleared_balance_milli,transfer_payee_id=excluded.transfer_payee_id,direct_import_linked=excluded.direct_import_linked,direct_import_in_error=excluded.direct_import_in_error,external_ynab_id=excluded.external_ynab_id,deleted=excluded.deleted,updated_at=CURRENT_TIMESTAMP`;
    await this.run("metadata.account.upsert", planId, account.id, { account, ensureOnly, incrementKnowledge }, context, [
      assertion(commandId, "metadata_plan_exists", planId, planId), assertion(commandId, "metadata_account", account.id, planId), assertion(commandId, "metadata_payee", payeeId, planId),
      statement(`INSERT INTO payees(id,plan_id,name,transfer_account_id,external_ynab_id,deleted,updated_at) VALUES (?,?,?,?,?,0,CURRENT_TIMESTAMP) ON CONFLICT(id) DO UPDATE SET name=excluded.name,transfer_account_id=excluded.transfer_account_id,deleted=0,updated_at=CURRENT_TIMESTAMP`, [payeeId, planId, payeeName, account.id, payeeId]),
      statement(`INSERT INTO accounts(id,plan_id,name,type,on_budget,closed,opening_balance_milli,balance_milli,cleared_balance_milli,uncleared_balance_milli,transfer_payee_id,direct_import_linked,direct_import_in_error,external_ynab_id,deleted,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP) ON CONFLICT(id) ${conflict}`, [account.id, planId, account.name ?? `Account ${account.id}`, account.type ?? "checking", bool(account.on_budget, true), bool(account.closed), account.opening_balance ?? 0, account.balance ?? 0, account.cleared_balance ?? account.balance ?? 0, account.uncleared_balance ?? 0, payeeId, bool(account.direct_import_linked), bool(account.direct_import_in_error), account.external_ynab_id ?? account.id, bool(account.deleted)]),
      statement("UPDATE payees SET transfer_account_id=?,updated_at=CURRENT_TIMESTAMP WHERE id=? AND plan_id=?", [account.id, payeeId, planId]),
      statement("UPDATE accounts SET transfer_payee_id=?,updated_at=CURRENT_TIMESTAMP WHERE id=? AND plan_id=?", [payeeId, account.id, planId]),
      ...(incrementKnowledge ? [statement("UPDATE plans SET server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?", [planId])] : []),
    ]);
  }

  async upsertPayee(planId: string, payee: any, context?: D1WriteContext): Promise<void> {
    const commandId = this.id(context);
    await this.run("metadata.payee.upsert", planId, payee.id, { payee }, context, [assertion(commandId,"metadata_plan_exists",planId,planId), assertion(commandId,"metadata_payee",payee.id,planId),
      ...(payee.transfer_account_id ? [assertion(commandId,"metadata_account_exists",payee.transfer_account_id,planId)] : []),
      statement("INSERT INTO payees(id,plan_id,name,transfer_account_id,external_ynab_id,deleted,updated_at) VALUES (?,?,?,?,?,?,CURRENT_TIMESTAMP) ON CONFLICT(id) DO UPDATE SET name=excluded.name,transfer_account_id=excluded.transfer_account_id,external_ynab_id=excluded.external_ynab_id,deleted=excluded.deleted,updated_at=CURRENT_TIMESTAMP", [payee.id,planId,payee.name??`Payee ${payee.id}`,payee.transfer_account_id??null,payee.external_ynab_id??payee.id,bool(payee.deleted)])]);
  }

  async createPayee(planId: string, payee: any, context?: D1WriteContext): Promise<void> {
    const commandId = this.id(context);
    await this.run("metadata.payee.create", planId, payee.id, { payee }, context, [
      assertion(commandId,"metadata_plan_exists",planId,planId), assertion(commandId,"metadata_payee",payee.id,planId),
      statement("INSERT INTO payees(id,plan_id,name,external_ynab_id) VALUES (?,?,?,?)", [payee.id,planId,payee.name,payee.id]),
      statement("UPDATE plans SET server_knowledge=server_knowledge+1,updated_at=CURRENT_TIMESTAMP WHERE id=?", [planId]),
    ]);
  }

  async upsertCategoryGroup(planId: string, group: any, context?: D1WriteContext): Promise<void> { await this.simpleMetadata("category_group", "category_groups", planId, group, null, context); }
  async upsertCategory(planId: string, category: any, groupId?: string | null, context?: D1WriteContext): Promise<void> { await this.simpleMetadata("category", "categories", planId, category, groupId ?? category.category_group_id ?? null, context); }

  async ensureCategory(planId:string,categoryId:string,name?:string,groupId="uncategorized-group",context?:D1WriteContext):Promise<void>{
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
