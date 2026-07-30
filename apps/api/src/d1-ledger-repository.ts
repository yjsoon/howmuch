import { createId } from "./ids";
import { LedgerRepository, type TransactionWriteOptions } from "./repository";
import type { LedgerStore } from "./storage";
import type { TransactionInput } from "./types";
import { D1Database } from "./d1";
import { D1MetadataRepository } from "./d1-metadata-repository";
import { D1TransactionRepository, type D1WriteContext } from "./d1-transaction-repository";

export type D1LedgerRepositoryOptions = Readonly<{
  lease?: (planId: string) => D1WriteContext["lease"] | undefined;
  operationId?: (kind: string, planId: string | undefined, resourceId: string) => string;
}>;

/** D1 facade: inherited methods are reads; all public mutations use guarded batches. */
export class D1LedgerRepository extends LedgerRepository {
  private readonly metadata: D1MetadataRepository;
  private readonly transactions: D1TransactionRepository;

  constructor(private readonly d1: D1Database, defaultPlanId: string, private readonly options: D1LedgerRepositoryOptions = {}) {
    super(d1, defaultPlanId);
    this.metadata = new D1MetadataRepository(d1);
    this.transactions = new D1TransactionRepository(d1);
  }

  private context(kind: string, planId: string | undefined, resourceId: string): D1WriteContext {
    const lease = planId ? this.options.lease?.(planId) : undefined;
    return { operationId: this.options.operationId?.(kind, planId, resourceId) ?? createId("op"), ...(lease ? { lease } : {}) };
  }

  override async ensurePlan(planId = this.getDefaultPlanId(), name = "HowMuch"): Promise<void> {
    if (await this.d1.get("SELECT 1 FROM plans WHERE id=? AND deleted=0", [planId])) return;
    await this.metadata.ensurePlan(planId, name, this.context("plan.ensure",planId,planId));
  }
  override async touchPlan(planId: string): Promise<number> { return this.metadata.touchPlan(planId, this.context("plan.touch",planId,planId)); }
  override async upsertPlan(planId:string,plan:any,settings?:any):Promise<void>{await this.metadata.upsertPlan(planId,plan,settings,this.context("plan.upsert",planId,planId));}
  override async ensureAccount(planId:string,accountId:string,name?:string):Promise<void>{await this.metadata.ensureAccount(planId,accountId,name,this.context("account.ensure",planId,accountId));}
  override async upsertAccount(planId:string,account:any):Promise<void>{await this.metadata.upsertAccount(planId,account,this.context("account.upsert",planId,account.id));}
  override async createAccount(planId:string,account:any):Promise<any>{
    const id=account.id??createId("acct"); const opening=account.opening_balance??account.balance??0;
    await this.metadata.upsertAccount(planId,{...account,id,...(!account.id?{opening_balance:opening,balance:account.balance??opening,cleared_balance:account.cleared_balance??account.balance??opening}: {})},this.context("account.create",planId,id),false,true);
    return this.getAccount(planId,id);
  }
  override async ensureTransferPayee():Promise<{id:string;name:string}|null>{throw new Error("D1LedgerRepository.ensureTransferPayee is unsupported; use ensureAccount/upsertAccount for atomic provisioning");}
  override async createPayee(planId:string,name:string,id=createId("payee")):Promise<any>{
    const existing=await this.d1.get<Record<string,any>>("SELECT id FROM payees WHERE plan_id=? AND lower(name)=lower(?) AND deleted=0",[planId,name]);
    if(existing)return (await this.listPayees(planId)).find((p)=>p.id===existing.id);
    await this.metadata.createPayee(planId,{id,name},this.context("payee.create",planId,id));
    return (await this.listPayees(planId)).find((p)=>p.id===id);
  }
  override async ensurePayee(planId:string,payeeId:string,name?:string):Promise<void>{await this.metadata.upsertPayee(planId,{id:payeeId,name:name??`Imported payee ${payeeId.slice(0,8)}`},this.context("payee.ensure",planId,payeeId));}
  override async upsertPayee(planId:string,payee:any):Promise<void>{await this.metadata.upsertPayee(planId,payee,this.context("payee.upsert",planId,payee.id));}
  override async ensureCategory(planId:string,categoryId:string,name?:string,groupId?:string|null):Promise<void>{await this.metadata.ensureCategory(planId,categoryId,name,groupId??"uncategorized-group",this.context("category.ensure",planId,categoryId));}
  override async upsertCategoryGroup(planId:string,group:any):Promise<void>{await this.metadata.upsertCategoryGroup(planId,group,this.context("category-group.upsert",planId,group.id));}
  override async upsertCategory(planId:string,category:any,groupId?:string|null):Promise<void>{await this.metadata.upsertCategory(planId,category,groupId,this.context("category.upsert",planId,category.id));}

  override async createTransaction(planId:string,input:TransactionInput,options:TransactionWriteOptions={}):Promise<any>{
    const autoLink=options.autoLink??true;
    const row=await this.transactions.create(planId,input,this.context("transaction.create",planId,input.id??createId("transaction-operation")),{autoLink,upsert:!autoLink});
    return this.getTransaction(planId,row.id,Boolean(input.deleted));
  }
  override async updateTransaction(planId:string,id:string,patch:Partial<TransactionInput>):Promise<any>{await this.transactions.update(planId,id,patch,this.context("transaction.update",planId,id));return this.getTransaction(planId,id);}
  override async deleteTransaction(planId:string,id:string):Promise<any>{await this.transactions.delete(planId,id,this.context("transaction.delete",planId,id));return this.getTransaction(planId,id,true);}
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
