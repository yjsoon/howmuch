import { Database } from "bun:sqlite";
import { afterEach, describe, expect, test } from "bun:test";
import { D1Database, type D1Binding, type D1Result, type D1Statement } from "../src/d1";
import { D1ReportService } from "../src/d1-reports";
import { D1ScheduledSyncState } from "../src/d1-scheduled-sync";
import { runD1ScheduledYnabSync } from "../src/d1-scheduled-sync-runner";
import { D1TransactionRepository } from "../src/d1-transaction-repository";
import { D1MetadataRepository } from "../src/d1-metadata-repository";
import { D1LedgerRepository } from "../src/d1-ledger-repository";
import { ReportService } from "../src/reports";
import worker from "../../worker/src/index";

const databases: Database[] = [];
const originalFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch=originalFetch; for (const db of databases.splice(0)) db.close(); });

describe("D1 foundation", () => {
  test("canonical schema applies cleanly with auth constraints and cascades", async () => {
    const db = sqlite();
    db.exec(await Bun.file(new URL("../d1-migrations/0001_initial.sql", import.meta.url)).text());
    const objects = db.query("SELECT name,type FROM sqlite_master WHERE type IN ('table','index','trigger')").all() as Array<{name:string;type:string}>;
    const names = new Set(objects.map((row) => row.name));
    for (const name of ["plans","import_sessions","import_rows","users","auth_identities","sessions","plan_memberships","sync_runs","sync_attempts","sync_transition_receipts","audit_events","write_state","write_commands","write_assertions","idx_sessions_user","idx_sessions_expiry","idx_plan_memberships_user_plan","transactions_assign_ledger_sequence","accounts_transfer_payee_plan_guard"]) expect(names.has(name)).toBeTrue();
    expect(names.has("schema_migrations")).toBeFalse();
    expect(names.has("migration_runs")).toBeFalse();
    expect(names.has("migration_chunks")).toBeFalse();
    expect(db.query("SELECT write_version FROM write_state WHERE singleton=1").get()).toEqual({write_version:0});
    expect(db.query("PRAGMA foreign_key_check").all()).toEqual([]);

    db.exec("INSERT INTO plans(id,name) VALUES ('p1','One'),('p2','Two'); INSERT INTO users(id) VALUES ('u1'),('u2')");
    db.run("INSERT INTO auth_identities(id,user_id,provider,issuer,provider_subject) VALUES ('i1','u1','oidc','issuer-a','subject')");
    expect(() => db.run("INSERT INTO auth_identities(id,user_id,provider,issuer,provider_subject) VALUES ('i2','u2','oidc','issuer-a','subject')")).toThrow();
    expect(() => db.run("INSERT INTO auth_identities(id,user_id,provider,issuer,provider_subject) VALUES ('i2','u2','oidc','issuer-b','subject')")).not.toThrow();
    expect(() => db.run("INSERT INTO plan_memberships VALUES ('p1','u1','admin',unixepoch())")).toThrow();
    expect(() => db.run("INSERT INTO plan_memberships VALUES ('missing','u1','viewer',unixepoch())")).toThrow();
    db.exec("INSERT INTO plan_memberships(plan_id,user_id,role) VALUES ('p1','u1','owner'),('p2','u1','viewer')");
    const hash = "a".repeat(64);
    db.run("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES ('s1','u1',?,9999999999)", [hash]);
    expect(() => db.run("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES ('s2','u2',?,9999999999)", [hash])).toThrow();
    expect(() => db.run("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES ('s3','u2',?,9999999999)", ["A".repeat(64)])).toThrow();
    db.run("DELETE FROM users WHERE id='u1'");
    expect(db.query("SELECT id FROM sessions WHERE user_id='u1'").get()).toBeNull();
    expect(db.query("SELECT plan_id FROM plan_memberships WHERE user_id='u1'").get()).toBeNull();
    expect(db.query("SELECT id FROM auth_identities WHERE user_id='u1'").get()).toBeNull();
  });

  test("Worker composition is D1-only, serves API writes, delegates assets, and blocks deployment", async () => {
    const db = await ledgerSqlite();
    const assetRequests: string[] = [];
    const env = {
      ASSETS: { fetch: async (request: Request) => { assetRequests.push(request.url); return new Response("asset"); } },
      DB: fakeD1(db),
      HOWMUCH_API_TOKEN: "worker-token",
      HOWMUCH_DEFAULT_PLAN_ID: "p",
      HOWMUCH_YNAB_PLAN_ID: "p",
      HOWMUCH_YNAB_MIN_SIMILARITY: "0.95",
    };
    const headers = { authorization: "Bearer worker-token", "content-type": "application/json" };

    const plans = await worker.fetch(new Request("https://howmuch.test/v1/plans", { headers }), env as any);
    expect(plans.status).toBe(200);
    const planBody = await plans.json() as { data: { plans: Array<{ id: string }> } };
    expect(planBody.data.plans.map((plan) => plan.id)).toEqual(["p"]);
    const account = await worker.fetch(new Request("https://howmuch.test/v1/plans/p/accounts", {
      method: "POST", headers, body: JSON.stringify({ account: { id: "worker-account", name: "Worker account" } }),
    }), env as any);
    expect(account.status).toBe(201);
    expect(db.query("SELECT name FROM accounts WHERE id='worker-account'").get()).toEqual({ name: "Worker account" });

    const asset = await worker.fetch(new Request("https://howmuch.test/dashboard"), env as any);
    expect(await asset.text()).toBe("asset");
    expect(assetRequests).toEqual(["https://howmuch.test/dashboard"]);
    await expect(worker.scheduled({ scheduledTime: Date.now() } as any, env as any)).rejects.toThrow("HOWMUCH_YNAB_TOKEN");

    const workerSource = await Bun.file(new URL("../../worker/src/index.ts", import.meta.url)).text();
    expect(workerSource).not.toContain("@neondatabase");
    expect(workerSource).not.toContain("DATABASE_URL");
    expect(workerSource).not.toContain("HOWMUCH_DATABASE_BACKEND");
    const rootPackage = await Bun.file(new URL("../../../package.json", import.meta.url)).json();
    expect(rootPackage.dependencies).toBeUndefined();
    const workerPackage = await Bun.file(new URL("../../worker/package.json", import.meta.url)).json();
    expect(workerPackage.scripts.deploy).toContain("Deployment blocked");
    expect(workerPackage.scripts["deploy:preview"]).toContain("Deployment blocked");
    const wranglerConfig = JSON.parse((await Bun.file(new URL("../../worker/wrangler.jsonc", import.meta.url)).text()).replace(/^\s*\/\/.*$/gm, ""));
    expect(wranglerConfig.d1_databases[0].database_id).toBe("local");
    expect(wranglerConfig.env.preview.d1_databases[0].database_id).toBe("local");
    expect(await Bun.file(new URL("../../../bun.lock", import.meta.url)).text()).not.toContain("@neondatabase/serverless");
  });

  test("LedgerStore facade supports HTTP, CSV, metadata, imports, and lease fencing", async () => {
    const db = await ledgerSqlite();
    const d1 = new D1Database(fakeD1(db));
    const repo = new D1LedgerRepository(d1, "p");

    const payee = await repo.createPayee("p", "Cafe", "cafe");
    const namedAccount=await repo.createAccount("p",{id:"named",name:"Named account"});
    expect(db.query("SELECT name FROM payees WHERE id=?").get(namedAccount.transfer_payee_id)).toEqual({name:"Transfer : Named account"});
    db.run("INSERT INTO payees(id,plan_id,name,transfer_account_id) VALUES ('ynab-transfer','p','YNAB transfer','imported')");
    db.run("INSERT INTO accounts(id,plan_id,name,transfer_payee_id) VALUES ('imported','p','Imported','ynab-transfer')");
    await repo.getAccount("p","imported");
    expect(db.query("SELECT id,name FROM payees WHERE transfer_account_id='imported'").all()).toEqual([{id:"ynab-transfer",name:"YNAB transfer"}]);
    const created = await repo.createTransaction("p", { id: "api-row", account_id: "a", date: "2026-07-01", amount: -100, payee_id: payee.id });
    expect(created.amount).toBe(-100);
    expect((await repo.listTransactions("p")).map((row) => row.id)).toContain("api-row");
    await expect(repo.createTransaction("p", { id: "api-row", account_id: "a", date: "2026-07-01", amount: -100 })).rejects.toThrow("already exists");
    expect((await repo.updateTransaction("p", "api-row", { amount: -125 })).amount).toBe(-125);

    const csv = { id: "csv-row", account_id: "a", date: "2026-07-02", amount: -50, import_id: "csv:1", payee_name: "Shop" };
    await repo.createTransaction("p", csv, { autoLink: false });
    await repo.createTransaction("p", { ...csv, amount: -55 }, { autoLink: false });
    expect((await repo.findDuplicateTransaction("p", { ...csv, amount: -55 }))?.id).toBe("csv-row");
    expect((await repo.listYnabTransactionFingerprints("p"))).toEqual([]);

    await repo.ensureCategory("p", "food", "Food");
    const session = await repo.createImportSession("p", "csv");
    await repo.recordImportRow(session, 0, "imported", csv, undefined, "csv-row");
    await repo.finishImportSession(session, "completed", { imported: 1 });
    expect(db.query("SELECT status FROM import_sessions WHERE id=?").get(session)).toEqual({ status: "completed" });
    expect((await repo.deleteTransaction("p", "api-row")).deleted).toBe(true);

    db.run("INSERT INTO ynab_sync_state(plan_id,lease_id,lease_until) VALUES ('p','current',datetime('now','+1 hour'))");
    const fenced = new D1LedgerRepository(d1, "p", { lease: (planId) => ({ planId, attemptId: "stale" }) });
    await expect(fenced.upsertPayee("p", { id: "blocked", name: "Blocked" })).rejects.toThrow("stale write command");
    expect(db.query("SELECT id FROM payees WHERE id='blocked'").get()).toBeNull();
  });

  test("ordinary statements work and interactive transactions fail closed", async () => {
    const db = sqlite();
    db.exec("CREATE TABLE values_table (id TEXT PRIMARY KEY, value INTEGER)");
    const d1 = new D1Database(fakeD1(db));
    expect((await d1.run("INSERT INTO values_table VALUES ($1, $2)", ["a", 7])).rowCount).toBe(1);
    expect(await d1.get<{ value: number }>("SELECT value FROM values_table WHERE id = $1", ["a"])).toEqual({ value: 7 });
    expect(() => d1.transaction(async () => 1)).toThrow("does not support interactive transactions");
  });

  test("D1 async reports match local SQLite reports", async () => {
    const db = sqlite();
    db.exec(await Bun.file(new URL("../d1-migrations/0001_initial.sql", import.meta.url)).text());
    db.run("INSERT INTO plans (id, name) VALUES ('p', 'Plan')");
    db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('a', 'p', 'Cash')");
    db.run("INSERT INTO transactions (id, ledger_sequence, plan_id, account_id, date, amount_milli, payee_name_snapshot) VALUES ('t', 1, 'p', 'a', '2026-01-02', -1200, 'Shop')");
    const expected = new ReportService(db);
    const actual = new D1ReportService(fakeD1(db));
    expect(await actual.spendingBreakdown("p")).toEqual(expected.spendingBreakdown("p"));
    expect(await actual.incomeVsSpending("p")).toEqual(expected.incomeVsSpending("p"));
    expect(await actual.incomeVsSpending("p", { interval: "week" })).toEqual(expected.incomeVsSpending("p", { interval: "week" }));
    expect(await actual.netWorth("p", { from: "2026-01-01", to: "2026-01-31" })).toEqual(expected.netWorth("p", { from: "2026-01-01", to: "2026-01-31" }));
    expect(await actual.ageOfMoney("p", { from: "2026-01-01", to: "2026-01-31" })).toEqual(expected.ageOfMoney("p", { from: "2026-01-01", to: "2026-01-31" }));
  });

  test("scheduled sync atomically acquires, deduplicates, fences, and completes leases", async () => {
    const db = sqlite();
    db.exec(await Bun.file(new URL("../d1-migrations/0001_initial.sql", import.meta.url)).text());
    db.run("INSERT INTO plans (id, name) VALUES ('p', 'Plan')");
    const state = new D1ScheduledSyncState(new D1Database(fakeD1(db)));

    expect(await state.acquire("p", "run-1", "attempt-1", "2026-01-01T00:00:00.000Z")).toEqual({
      status: "acquired", runId: "run-1", attemptId: "attempt-1", serverKnowledge: 0,
    });
    expect(await state.acquire("p", "run-1", "attempt-duplicate", "2026-01-01T00:00:00.000Z")).toEqual({
      status: "leased", runId: "run-1",
    });
    expect(db.query("SELECT status FROM sync_runs WHERE id='run-1'").get()).toEqual({status:"running"});
    await state.renew("p","run-1","attempt-1");
    expect(await state.acquire("p", "run-2", "attempt-2", "2026-01-01T01:00:00.000Z")).toEqual({
      status: "leased", runId: "run-2",
    });
    expect(db.query("SELECT status FROM sync_runs WHERE id = 'run-2'").get()).toEqual({ status: "leased" });
    db.run("UPDATE ynab_sync_state SET lease_until = datetime('now', '-1 minute') WHERE plan_id = 'p'");
    expect(await state.acquire("p", "ignored-retry-id", "attempt-3", "2026-01-01T00:00:00.000Z")).toEqual({
      status: "acquired", runId: "run-1", attemptId: "attempt-3", serverKnowledge: 0,
    });
    expect(db.query("SELECT status FROM sync_attempts WHERE id = 'attempt-1'").get()).toEqual({ status: "expired" });
    await state.renew("p", "run-1", "attempt-3");
    await expect(state.complete("p", "run-1", "attempt-1", 10, {})).rejects.toThrow("lease is no longer owned");
    await expect(state.complete("p", "wrong-run", "attempt-3", 10, {})).rejects.toThrow("lease is no longer owned");
    expect(db.query("SELECT server_knowledge, lease_id FROM ynab_sync_state WHERE plan_id = 'p'").get()).toEqual({
      server_knowledge: 0, lease_id: "attempt-3",
    });
    await state.complete("p", "run-1", "attempt-3", 10, { imported: 1 });
    await state.complete("p", "run-1", "attempt-3", 10, { imported: 1 });
    await expect(state.complete("p", "run-1", "attempt-3", 11, { imported: 2 })).rejects.toThrow("lease is no longer owned");
    expect(db.query("SELECT server_knowledge, lease_id FROM ynab_sync_state WHERE plan_id = 'p'").get()).toEqual({
      server_knowledge: 10, lease_id: null,
    });
    expect(db.query("SELECT status FROM sync_runs WHERE id = 'run-1'").get()).toEqual({ status: "completed" });
    expect(await state.acquire("p", "ignored-terminal-id", "attempt-4", "2026-01-01T00:00:00.000Z")).toEqual({
      status: "duplicate", runId: "run-1",
    });

    expect(await state.acquire("p", "run-fail", "attempt-fail", "2026-01-01T02:00:00.000Z")).toEqual({
      status: "acquired", runId: "run-fail", attemptId: "attempt-fail", serverKnowledge: 10,
    });
    await state.fail("p", "run-fail", "attempt-fail", "expected failure");
    await state.fail("p", "run-fail", "attempt-fail", "expected failure");
    await expect(state.fail("p", "run-fail", "attempt-fail", "different failure")).rejects.toThrow("lease is no longer owned");
    expect(db.query("SELECT server_knowledge FROM ynab_sync_state WHERE plan_id = 'p'").get()).toEqual({ server_knowledge: 10 });

    expect(await state.acquire("p", "run-expire", "attempt-expire", "2026-01-01T03:00:00.000Z")).toEqual({
      status: "acquired", runId: "run-expire", attemptId: "attempt-expire", serverKnowledge: 10,
    });
    db.run("UPDATE ynab_sync_state SET lease_until = datetime('now', '-1 minute') WHERE plan_id = 'p'");
    await expect(state.renew("p", "run-expire", "attempt-expire")).rejects.toThrow("scheduled sync renewal rejected");
  });

  test("scheduled completion recovers an ambiguous committed response", async () => {
    const db = await ledgerSqlite();
    const state = new D1ScheduledSyncState(new D1Database(fakeD1(db, {
      commitThenThrowSql: /^INSERT INTO sync_transition_receipts/i,
    })));
    await state.acquire("p", "run", "attempt", "2026-01-01T00:00:00.000Z");
    await state.complete("p", "run", "attempt", 7, { imported: 1 });
    expect(db.query("SELECT status FROM sync_runs WHERE id = 'run'").get()).toEqual({ status: "completed" });
    expect(db.query("SELECT server_knowledge FROM ynab_sync_state WHERE plan_id = 'p'").get()).toEqual({ server_knowledge: 7 });
  });

  test("D1 scheduled runner fences ledger writes, renews, completes, and deduplicates", async () => {
    const db=await ledgerSqlite(); const d1=new D1Database(fakeD1(db)); let clock=0;
    globalThis.fetch=(async(input:RequestInfo|URL)=>{const url=String(input);let data:any;
      if(url.endsWith("/plans/p"))data={plan:{id:"p",name:"Plan"}};
      else if(url.endsWith("/plans/p/settings"))data={settings:{}};
      else if(url.endsWith("/plans/p/accounts"))data={accounts:[{id:"a",name:"Cash"}],server_knowledge:9};
      else if(url.endsWith("/plans/p/categories"))data={category_groups:[],server_knowledge:9};
      else if(url.endsWith("/plans/p/payees"))data={payees:[],server_knowledge:9};
      else if(url.includes("/plans/p/transactions"))data={transactions:[{id:"ynab-1",account_id:"a",date:"2026-01-01",amount:-10,deleted:false,subtransactions:[]}],server_knowledge:9};
      else return new Response("not found",{status:404}); return new Response(JSON.stringify({data}),{headers:{"content-type":"application/json"}});
    }) as typeof fetch;
    const config={dbPath:"",port:0,defaultPlanId:"p",ynabToken:"token",ynabPlanId:"p",ynabMinSimilarity:0.95};
    const first=await runD1ScheduledYnabSync({db:d1,config,scheduledTime:Date.UTC(2026,0,1),now:()=>clock+=360_001,logger:{log(){},warn(){},error(){}}});
    expect(first.status).toBe("completed");
    expect(db.query("SELECT status FROM sync_runs").get()).toEqual({status:"completed"});
    expect(db.query("SELECT COUNT(*) count FROM sync_renewal_receipts").get()).toEqual({count:1});
    expect(db.query("SELECT id FROM transactions WHERE id='ynab-1'").get()).toEqual({id:"ynab-1"});
    const duplicate=await runD1ScheduledYnabSync({db:d1,config,scheduledTime:Date.UTC(2026,0,1),logger:{log(){},warn(){},error(){}}});
    expect(duplicate.status).toBe("duplicate");
  });

  test("write commands bind exactly one version increment and reject stale batches", async () => {
    const db = sqlite();
    db.exec(await Bun.file(new URL("../d1-migrations/0001_initial.sql", import.meta.url)).text());
    const d1 = new D1Database(fakeD1(db));

    await d1.atomicBatch([
      { sql: "INSERT INTO write_commands (id, expected_write_version, kind, plan_id, transaction_id, request_hash) VALUES ($1, $2, $3, 'p', 't', 'hash')", values: ["command-1", 0, "test"] },
      { sql: "UPDATE write_state SET write_version = write_version + 1, last_command_id = $1 WHERE singleton = 1", values: ["command-1"] },
      { sql: "UPDATE write_commands SET status = 'applied', applied_at = CURRENT_TIMESTAMP WHERE id = $1", values: ["command-1"] },
    ]);
    expect(db.query("SELECT write_version, last_command_id FROM write_state").get()).toEqual({
      write_version: 1, last_command_id: "command-1",
    });

    await expect(d1.atomicBatch([
      { sql: "INSERT INTO write_commands (id, expected_write_version, kind, plan_id, transaction_id, request_hash) VALUES ($1, $2, $3, 'p', 't', 'hash')", values: ["stale", 0, "test"] },
      { sql: "INSERT INTO audit_events (id, action, source) VALUES ('should-rollback', 'test', 'test')" },
    ])).rejects.toThrow("stale write command");
    expect(db.query("SELECT COUNT(*) AS count FROM audit_events").get()).toEqual({ count: 0 });
    expect(() => db.run("UPDATE write_commands SET status = 'pending' WHERE id = 'command-1'")).toThrow("immutable");
    expect(() => db.run("UPDATE write_commands SET expected_write_version = 99 WHERE id = 'command-1'")).toThrow("immutable");
    expect(() => db.run("DELETE FROM write_commands WHERE id = 'command-1'")).toThrow("cannot be deleted");
  });

  test("ordinary transaction create/update/delete is one guarded graph batch", async () => {
    const db = await ledgerSqlite();
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));
    const created = await writer.create("p", { account_id: "a", date: "2026-07-01", amount: -1200, cleared: "cleared", source_kind: "api", source_ref: "r1" });
    expect(created.id).toStartWith("txn_");
    expect(db.query("SELECT balance_milli, cleared_balance_milli FROM accounts WHERE id = 'a'").get()).toEqual({ balance_milli: -1200, cleared_balance_milli: -1200 });
    expect(db.query("SELECT COUNT(*) count FROM source_events").get()).toEqual({ count: 1 });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: 1 });

    await writer.update("p", created.id, { amount: -500, cleared: "uncleared" });
    expect(db.query("SELECT balance_milli, cleared_balance_milli, uncleared_balance_milli FROM accounts WHERE id = 'a'").get()).toEqual({ balance_milli: -500, cleared_balance_milli: 0, uncleared_balance_milli: -500 });
    await writer.delete("p", created.id);
    expect(db.query("SELECT balance_milli FROM accounts WHERE id = 'a'").get()).toEqual({ balance_milli: 0 });
    expect(db.query("SELECT server_knowledge, deleted FROM transactions WHERE id = ?").get(created.id)).toEqual({ server_knowledge: 4, deleted: 1 });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: 3 });
  });

  test("operation receipts replay exactly, including after an ambiguous commit", async () => {
    const db = await ledgerSqlite();
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db, { commitThenThrowOnce: true })));
    const input = { account_id: "a", date: "2026-07-01", amount: 25, source_kind: "api", source_ref: "same" };
    const context = { operationId: "operation-create" };
    const knowledgeBefore = Number((db.query("SELECT server_knowledge FROM plans WHERE id = 'p'").get() as { server_knowledge: number }).server_knowledge);
    const first = await writer.create("p", input, context);
    const replay = await writer.create("p", input, context);
    expect(replay.id).toBe(first.id);
    expect(db.query("SELECT COUNT(*) count FROM transactions").get()).toEqual({ count: 1 });
    expect(db.query("SELECT COUNT(*) count FROM source_events").get()).toEqual({ count: 1 });
    expect(db.query("SELECT server_knowledge FROM plans WHERE id = 'p'").get()).toEqual({ server_knowledge: knowledgeBefore + 1 });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: 1 });
  });

  test("operation IDs are bound to canonical request, kind, plan, transaction, and lease", async () => {
    const db = await ledgerSqlite();
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));
    const context = { operationId: "bound-operation" };
    const first = await writer.create("p", { amount: 25, date: "2026-07-01", account_id: "a" }, context);
    await writer.create("p", { account_id: "a", date: "2026-07-01", amount: 25 }, context);
    await expect(writer.create("p", { account_id: "a", date: "2026-07-01", amount: 26 }, context)).rejects.toThrow("idempotency-key reuse");
    await expect(writer.update("p", first.id, { amount: 25 }, context)).rejects.toThrow("idempotency-key reuse");
    await expect(writer.delete("p", first.id, context)).rejects.toThrow("idempotency-key reuse");
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: 1 });
    expect(db.query("SELECT amount_milli FROM transactions WHERE id = ?").get(first.id)).toEqual({ amount_milli: 25 });
  });

  test("in-batch payee and split preconditions abort races without mutation", async () => {
    for (const mutation of [
      (db: Database) => db.run("UPDATE payees SET transfer_account_id = 'a' WHERE id = 'payee'"),
      (db: Database) => db.run("INSERT INTO subtransactions (id, transaction_id, amount_milli) VALUES ('split', 'target', 1)"),
    ]) {
      const db = await ledgerSqlite();
      db.run("INSERT INTO payees (id, plan_id, name) VALUES ('payee', 'p', 'Payee')");
      db.run("INSERT INTO transactions (id, plan_id, account_id, date, amount_milli) VALUES ('target', 'p', 'a', '2026-01-01', 10)");
      const targetBefore = db.query("SELECT amount_milli, payee_id, server_knowledge FROM transactions WHERE id = 'target'").get();
      const before = JSON.stringify({ account: db.query("SELECT * FROM accounts WHERE id = 'a'").get(), plan: db.query("SELECT * FROM plans WHERE id = 'p'").get(), state: db.query("SELECT * FROM write_state").get() });
      const writer = new D1TransactionRepository(new D1Database(fakeD1(db, { beforeWriteBatch: mutation })));
      await expect(writer.update("p", "target", { payee_id: "payee", amount: 20 }, { operationId: `race-${Math.random()}` })).rejects.toThrow("write precondition failed");
      expect(db.query("SELECT amount_milli, payee_id, server_knowledge FROM transactions WHERE id = 'target'").get()).toEqual(targetBefore);
      expect(JSON.stringify({ account: db.query("SELECT * FROM accounts WHERE id = 'a'").get(), plan: db.query("SELECT * FROM plans WHERE id = 'p'").get(), state: db.query("SELECT * FROM write_state").get() })).toBe(before);
    }
  });

  test("global ID collision and wrong-plan writes fail without changing either plan", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO plans (id, name) VALUES ('other', 'Other')");
    db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('other-a', 'other', 'Other cash')");
    db.run("INSERT INTO transactions (id, plan_id, account_id, date, amount_milli) VALUES ('collision', 'other', 'other-a', '2026-01-01', 9)");
    const before = JSON.stringify({
      transactions: db.query("SELECT * FROM transactions ORDER BY id").all(),
      events: db.query("SELECT * FROM source_events ORDER BY id").all(),
      plans: db.query("SELECT * FROM plans ORDER BY id").all(),
      state: db.query("SELECT * FROM write_state").all(),
    });
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));
    await expect(writer.create("p", { id: "collision", account_id: "a", date: "2026-07-01", amount: 1 }, { operationId: "collision-create" })).rejects.toThrow("already exists");
    await expect(writer.update("p", "collision", { amount: 2 }, { operationId: "collision-update" })).rejects.toThrow("another plan");
    expect(JSON.stringify({ transactions: db.query("SELECT * FROM transactions ORDER BY id").all(), events: db.query("SELECT * FROM source_events ORDER BY id").all(), plans: db.query("SELECT * FROM plans ORDER BY id").all(), state: db.query("SELECT * FROM write_state").all() })).toBe(before);
  });

  test("delete receipt replays but distinct writes to a deleted row fail closed", async () => {
    const db = await ledgerSqlite();
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));
    const row = await writer.create("p", { id: "gone", account_id: "a", date: "2026-01-01", amount: 10 }, { operationId: "create-gone" });
    await writer.delete("p", row.id, { operationId: "delete-gone" });
    await writer.delete("p", row.id, { operationId: "delete-gone" });
    await expect(writer.delete("p", row.id, { operationId: "delete-again" })).rejects.toThrow("not found");
    await expect(writer.update("p", row.id, { amount: 99 }, { operationId: "update-gone" })).rejects.toThrow("not found");
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: 2 });
  });

  test("stale lease rolls back ledger, balances, knowledge, and versions", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO ynab_sync_state (plan_id, lease_id, lease_until) VALUES ('p', 'current', datetime('now', '+1 hour'))");
    const knowledgeBefore = db.query("SELECT server_knowledge FROM plans WHERE id = 'p'").get();
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));
    await expect(writer.create("p", { id: "leased", account_id: "a", date: "2026-01-01", amount: 10 }, { operationId: "lease-op", lease: { planId: "p", attemptId: "stale" } })).rejects.toThrow("stale write command");
    expect(db.query("SELECT COUNT(*) count FROM transactions").get()).toEqual({ count: 0 });
    expect(db.query("SELECT balance_milli FROM accounts WHERE id = 'a'").get()).toEqual({ balance_milli: 0 });
    expect(db.query("SELECT server_knowledge FROM plans WHERE id = 'p'").get()).toEqual(knowledgeBefore);
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: 0 });
  });

  test("reconciled balances and movement between accounts are recalculated", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('b', 'p', 'Bank')");
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));
    await writer.create("p", { id: "move", account_id: "a", date: "2026-01-01", amount: 40, cleared: "reconciled" });
    expect(db.query("SELECT balance_milli, cleared_balance_milli FROM accounts WHERE id = 'a'").get()).toEqual({ balance_milli: 40, cleared_balance_milli: 40 });
    await writer.update("p", "move", { account_id: "b" });
    expect(db.query("SELECT id, balance_milli, cleared_balance_milli FROM accounts WHERE id IN ('a','b') ORDER BY id").all()).toEqual([
      { id: "a", balance_milli: 0, cleared_balance_milli: 0 }, { id: "b", balance_milli: 40, cleared_balance_milli: 40 },
    ]);
  });

  test("atomic D1 transfers and transfer splits create stable reciprocal graphs", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('b', 'p', 'Savings')");
    db.run("INSERT INTO payees (id, plan_id, name, transfer_account_id) VALUES ('to-a','p','Transfer to Cash','a'),('to-b','p','Transfer to Savings','b')");
    db.run("UPDATE accounts SET transfer_payee_id=CASE id WHEN 'a' THEN 'to-a' ELSE 'to-b' END WHERE id IN ('a','b')");
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));
    const transfer = await writer.create("p", { id: "transfer", account_id: "a", date: "2026-07-01", amount: -100, memo: "move", cleared: "cleared", payee_id: "to-b" }, { operationId: "transfer-op" });
    const mirror = db.query("SELECT * FROM transactions WHERE id=?").get(transfer.transfer_transaction_id) as any;
    expect({ account: mirror.account_id, amount: mirror.amount_milli, link: mirror.transfer_transaction_id, memo: mirror.memo }).toEqual({ account: "b", amount: 100, link: "transfer", memo: "move" });
    expect(db.query("SELECT id,balance_milli FROM accounts ORDER BY id").all()).toEqual([{ id: "a", balance_milli: -100 }, { id: "b", balance_milli: 100 }]);
    expect(mirror.server_knowledge).toBe(transfer.server_knowledge);
    await writer.create("p", { id: "transfer", account_id: "a", date: "2026-07-01", amount: -100, memo: "move", cleared: "cleared", payee_id: "to-b" }, { operationId: "transfer-op" });
    expect(db.query("SELECT COUNT(*) count FROM transactions").get()).toEqual({ count: 2 });

    const split = await writer.create("p", { id: "split-parent", account_id: "a", date: "2026-07-02", amount: -30, source_kind: "api", subtransactions: [{ amount: -10, memo: "stash", payee_id: "to-b" }, { amount: -20 }] }, { operationId: "split-op" });
    expect(split.category_id).toBeNull();
    const lines = db.query("SELECT * FROM subtransactions WHERE transaction_id='split-parent' AND deleted=0 ORDER BY id").all() as any[];
    expect(lines).toHaveLength(2);
    const transferLine = lines.find((line) => line.transfer_transaction_id)!;
    expect(db.query("SELECT amount_milli,transfer_transaction_id FROM transactions WHERE id=?").get(transferLine.transfer_transaction_id)).toEqual({ amount_milli: 10, transfer_transaction_id: transferLine.id });
    expect(db.query("SELECT COUNT(*) count FROM source_events WHERE transaction_id='split-parent'").get()).toEqual({ count: 1 });
  });

  test("deleting either side of an intact D1 transfer deletes both sides",async()=>{
    const db=await ledgerSqlite();
    db.run("INSERT INTO accounts(id,plan_id,name) VALUES('b','p','Savings')");
    db.run("INSERT INTO payees(id,plan_id,name,transfer_account_id) VALUES('to-a','p','To Cash','a'),('to-b','p','To Savings','b')");
    db.run("UPDATE accounts SET transfer_payee_id=CASE id WHEN 'a' THEN 'to-a' ELSE 'to-b' END WHERE id IN('a','b')");
    const writer=new D1TransactionRepository(new D1Database(fakeD1(db)));
    const row=await writer.create("p",{id:"left-delete",account_id:"a",date:"2026-01-01",amount:-10,payee_id:"to-b"},{operationId:"create-delete-pair"});
    await writer.delete("p",row.transfer_transaction_id,{operationId:"delete-pair"});
    expect(db.query("SELECT id,deleted FROM transactions ORDER BY id").all()).toEqual([{id:"left-delete",deleted:1},{id:row.transfer_transaction_id,deleted:1}].sort((a,b)=>a.id.localeCompare(b.id)));
    expect(db.query("SELECT id,balance_milli FROM accounts ORDER BY id").all()).toEqual([{id:"a",balance_milli:0},{id:"b",balance_milli:0}]);
  });

  test("D1 transfer creation cannot repurpose an unrelated same-plan transaction as its mirror",async()=>{
    const db=await ledgerSqlite();
    db.run("INSERT INTO accounts(id,plan_id,name) VALUES('b','p','Savings')");
    db.run("INSERT INTO payees(id,plan_id,name,transfer_account_id) VALUES('to-a','p','To Cash','a'),('to-b','p','To Savings','b')");
    db.run("UPDATE accounts SET transfer_payee_id=CASE id WHEN 'a' THEN 'to-a' ELSE 'to-b' END WHERE id IN('a','b')");
    db.run("INSERT INTO transactions(id,plan_id,account_id,date,amount_milli) VALUES('unrelated','p','b','2026-01-01',99)");
    const before=JSON.stringify(db.query("SELECT * FROM transactions WHERE id='unrelated'").get());
    const writer=new D1TransactionRepository(new D1Database(fakeD1(db)));
    await expect(writer.create("p",{id:"attack",account_id:"a",date:"2026-01-01",amount:-10,payee_id:"to-b",transfer_transaction_id:"unrelated"},{operationId:"mirror-collision"})).rejects.toThrow("write precondition failed");
    expect(JSON.stringify(db.query("SELECT * FROM transactions WHERE id='unrelated'").get())).toBe(before);
    expect(db.query("SELECT id FROM transactions WHERE id='attack'").get()).toBeNull();
  });

  test("D1 transfer updates cannot replace an existing parent or split mirror ID",async()=>{
    const db=await ledgerSqlite();
    db.run("INSERT INTO accounts(id,plan_id,name) VALUES('b','p','Savings')");
    db.run("INSERT INTO payees(id,plan_id,name,transfer_account_id) VALUES('to-a','p','To Cash','a'),('to-b','p','To Savings','b')");
    db.run("UPDATE accounts SET transfer_payee_id=CASE id WHEN 'a' THEN 'to-a' ELSE 'to-b' END WHERE id IN('a','b')");
    const writer=new D1TransactionRepository(new D1Database(fakeD1(db)));
    const parent=await writer.create("p",{id:"parent-rekey",account_id:"a",date:"2026-01-01",amount:-10,payee_id:"to-b"},{operationId:"parent-rekey-create"});
    await expect(writer.update("p",parent.id,{transfer_transaction_id:"replacement-parent"},{operationId:"parent-rekey-update"})).rejects.toThrow("mirror ID cannot be replaced");
    expect(db.query("SELECT transfer_transaction_id FROM transactions WHERE id=?").get(parent.id)).toEqual({transfer_transaction_id:parent.transfer_transaction_id});
    expect(db.query("SELECT id FROM transactions WHERE id='replacement-parent'").get()).toBeNull();

    await writer.create("p",{id:"split-rekey",account_id:"a",date:"2026-01-02",amount:-20,subtransactions:[{id:"transfer-line",amount:-10,payee_id:"to-b"},{id:"plain-line",amount:-10}]},{operationId:"split-rekey-create"});
    const oldMirror=(db.query("SELECT transfer_transaction_id FROM subtransactions WHERE id='transfer-line'").get() as any).transfer_transaction_id;
    await expect(writer.update("p","split-rekey",{subtransactions:[{id:"transfer-line",amount:-10,payee_id:"to-b",transfer_transaction_id:"replacement-split"},{id:"plain-line",amount:-10}]},{operationId:"split-rekey-update"})).rejects.toThrow("mirror ID cannot be replaced");
    expect(db.query("SELECT transfer_transaction_id FROM subtransactions WHERE id='transfer-line'").get()).toEqual({transfer_transaction_id:oldMirror});
    expect(db.query("SELECT id FROM transactions WHERE id='replacement-split'").get()).toBeNull();
  });

  test("D1 splits deduplicate repeated category and transfer assertions",async()=>{
    const db=await ledgerSqlite();
    db.run("INSERT INTO accounts(id,plan_id,name) VALUES('b','p','Savings')");
    db.run("INSERT INTO payees(id,plan_id,name,transfer_account_id) VALUES('to-a','p','To Cash','a'),('to-b','p','To Savings','b')");
    db.run("UPDATE accounts SET transfer_payee_id=CASE id WHEN 'a' THEN 'to-a' ELSE 'to-b' END WHERE id IN('a','b')");
    db.run("INSERT INTO categories(id,plan_id,name) VALUES('food','p','Food')");
    const writer=new D1TransactionRepository(new D1Database(fakeD1(db)));
    await writer.create("p",{id:"repeated-category",account_id:"a",date:"2026-01-01",amount:-20,subtransactions:[{id:"food-1",amount:-10,category_id:"food"},{id:"food-2",amount:-10,category_id:"food"}]},{operationId:"repeated-category"});
    await writer.create("p",{id:"repeated-transfer",account_id:"a",date:"2026-01-02",amount:-20,subtransactions:[{id:"move-1",amount:-10,payee_id:"to-b"},{id:"move-2",amount:-10,payee_id:"to-b"}]},{operationId:"repeated-transfer"});
    expect(db.query("SELECT COUNT(*) count FROM subtransactions WHERE transaction_id IN ('repeated-category','repeated-transfer') AND deleted=0").get()).toEqual({count:4});
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE transfer_transaction_id IN ('move-1','move-2') AND deleted=0").get()).toEqual({count:2});
  });

  test("atomic D1 transfer and split updates synchronize or remove their mirrors", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('b', 'p', 'Savings')");
    db.run("INSERT INTO payees (id, plan_id, name, transfer_account_id) VALUES ('to-a','p','Transfer to Cash','a'),('to-b','p','Transfer to Savings','b')");
    db.run("UPDATE accounts SET transfer_payee_id=CASE id WHEN 'a' THEN 'to-a' ELSE 'to-b' END WHERE id IN ('a','b')");
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));

    const transfer = await writer.create("p", {
      id: "transfer-update", account_id: "a", date: "2026-07-01", amount: -100, memo: "first", payee_id: "to-b",
    }, { operationId: "transfer-create" });
    await writer.update("p", transfer.id, { amount: -150, memo: "changed" }, { operationId: "transfer-update" });
    const updated = db.query("SELECT * FROM transactions WHERE id = 'transfer-update'").get() as any;
    expect(db.query("SELECT amount_milli, memo, server_knowledge FROM transactions WHERE id = ?").get(updated.transfer_transaction_id)).toEqual({
      amount_milli: 150, memo: "changed", server_knowledge: updated.server_knowledge,
    });
    expect(db.query("SELECT id, balance_milli FROM accounts ORDER BY id").all()).toEqual([
      { id: "a", balance_milli: -150 }, { id: "b", balance_milli: 150 },
    ]);

    const mirrorId = updated.transfer_transaction_id;
    await writer.update("p", transfer.id, { payee_id: null }, { operationId: "transfer-break" });
    expect(db.query("SELECT transfer_account_id, transfer_transaction_id FROM transactions WHERE id = 'transfer-update'").get()).toEqual({
      transfer_account_id: null, transfer_transaction_id: null,
    });
    expect(db.query("SELECT deleted FROM transactions WHERE id = ?").get(mirrorId)).toEqual({ deleted: 1 });
    expect(db.query("SELECT id, balance_milli FROM accounts ORDER BY id").all()).toEqual([
      { id: "a", balance_milli: -150 }, { id: "b", balance_milli: 0 },
    ]);
    await writer.delete("p", transfer.id, { operationId: "transfer-delete" });
    expect(db.query("SELECT balance_milli FROM accounts WHERE id = 'a'").get()).toEqual({ balance_milli: 0 });

    await writer.create("p", {
      id: "split-update", account_id: "a", date: "2026-07-02", amount: -30,
      subtransactions: [{ id: "line-transfer", amount: -10, payee_id: "to-b" }, { id: "line-plain", amount: -20 }],
    }, { operationId: "split-create" });
    const splitMirror = (db.query("SELECT transfer_transaction_id FROM subtransactions WHERE id = 'line-transfer'").get() as any).transfer_transaction_id;
    await expect(writer.update("p", splitMirror, { memo: "blocked" }, { operationId: "split-mirror-update" })).rejects.toThrow("linked side of a split line");
    await expect(writer.delete("p", splitMirror, { operationId: "split-mirror-delete" })).rejects.toThrow("linked side of a split line");
    await writer.update("p", "split-update", {
      subtransactions: [{ id: "line-transfer", amount: -10 }, { id: "line-plain", amount: -20 }],
    }, { operationId: "split-unlink" });
    expect(db.query("SELECT transfer_account_id,transfer_transaction_id FROM subtransactions WHERE id='line-transfer'").get()).toEqual({ transfer_account_id: null, transfer_transaction_id: null });
    expect(db.query("SELECT deleted FROM transactions WHERE id = ?").get(splitMirror)).toEqual({ deleted: 1 });
    await writer.update("p", "split-update", {
      subtransactions: [{ id: "line-plain", amount: -15 }, { id: "line-new", amount: -15 }],
    }, { operationId: "split-replace" });
    expect(db.query("SELECT id, deleted FROM subtransactions WHERE transaction_id = 'split-update' ORDER BY id").all()).toEqual([
      { id: "line-new", deleted: 0 }, { id: "line-plain", deleted: 0 }, { id: "line-transfer", deleted: 1 },
    ]);
    expect(db.query("SELECT deleted FROM transactions WHERE id = ?").get(splitMirror)).toEqual({ deleted: 1 });
    await writer.delete("p", "split-update", { operationId: "split-delete" });
    expect(db.query("SELECT balance_milli FROM accounts WHERE id = 'a'").get()).toEqual({ balance_milli: 0 });
  });

  test("D1 importer upserts explicit transfer sides without minting mirrors or dropping categories", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO accounts (id,plan_id,name) VALUES ('b','p','Savings')");
    db.run("INSERT INTO categories (id,plan_id,name) VALUES ('tracking','p','Tracking transfer')");
    db.run("INSERT INTO payees (id,plan_id,name,transfer_account_id) VALUES ('to-a','p','Transfer to Cash','a'),('to-b','p','Transfer to Savings','b')");
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));
    await writer.create("p", { id:"left",account_id:"a",date:"2026-07-01",amount:-25,payee_id:"to-b",category_id:"tracking",transfer_account_id:"b",transfer_transaction_id:"right" }, { operationId:"import-left" }, { autoLink:false,upsert:true });
    await writer.create("p", { id:"right",account_id:"b",date:"2026-07-01",amount:25,payee_id:"to-a",transfer_account_id:"a",transfer_transaction_id:"left" }, { operationId:"import-right" }, { autoLink:false,upsert:true });
    expect(db.query("SELECT id,amount_milli,category_id,transfer_transaction_id FROM transactions ORDER BY id").all()).toEqual([
      { id:"left",amount_milli:-25,category_id:"tracking",transfer_transaction_id:"right" },
      { id:"right",amount_milli:25,category_id:null,transfer_transaction_id:"left" },
    ]);
    await writer.create("p", { id:"left",account_id:"a",date:"2026-07-01",amount:-30,payee_id:"to-b",category_id:"tracking",transfer_account_id:"b",transfer_transaction_id:"right" }, { operationId:"import-left-delta" }, { autoLink:false,upsert:true });
    expect(db.query("SELECT id,amount_milli FROM transactions ORDER BY id").all()).toEqual([{id:"left",amount_milli:-30},{id:"right",amount_milli:25}]);
  });

  test("D1 split IDs cannot be stolen by another parent in the same plan", async () => {
    const db=await ledgerSqlite(); const writer=new D1TransactionRepository(new D1Database(fakeD1(db)));
    await writer.create("p",{id:"first",account_id:"a",date:"2026-01-01",amount:2,subtransactions:[{id:"shared",amount:1},{id:"first-other",amount:1}]},{operationId:"first"});
    await expect(writer.create("p",{id:"second",account_id:"a",date:"2026-01-02",amount:2,subtransactions:[{id:"shared",amount:1},{id:"second-other",amount:1}]},{operationId:"second"})).rejects.toThrow("write precondition failed");
    expect(db.query("SELECT transaction_id FROM subtransactions WHERE id='shared'").get()).toEqual({transaction_id:"first"});
  });

  test("versioned D1 metadata and import-session writes replay and reject collisions", async () => {
    const db = sqlite();
    for (const path of ["../d1-migrations/0001_initial.sql"]) {
      db.exec(await Bun.file(new URL(path, import.meta.url)).text());
    }
    const metadata = new D1MetadataRepository(new D1Database(fakeD1(db)));

    await metadata.ensurePlan("p", "Plan", { operationId: "plan-create" });
    await metadata.ensurePlan("p", "Plan", { operationId: "plan-create" });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: 1 });
    await expect(metadata.ensurePlan("p", "Different", { operationId: "plan-create" })).rejects.toThrow("idempotency-key reuse");

    await metadata.upsertAccount("p", { id: "a", name: "Cash", balance: 100 }, { operationId: "account-a" });
    const account = db.query("SELECT transfer_payee_id FROM accounts WHERE id = 'a'").get() as { transfer_payee_id: string };
    expect(db.query("SELECT transfer_account_id FROM payees WHERE id = ?").get(account.transfer_payee_id)).toEqual({ transfer_account_id: "a" });
    await metadata.upsertCategoryGroup("p", { id: "group", name: "Living" }, { operationId: "group" });
    await metadata.upsertCategory("p", { id: "category", name: "Food" }, "group", { operationId: "category" });
    expect(db.query("SELECT category_group_id FROM categories WHERE id = 'category'").get()).toEqual({ category_group_id: "group" });

    const sessionId = await metadata.createImportSession("p", "fixture", { operationId: "session" });
    await metadata.recordImportRow(sessionId, 0, "imported", { amount: 1 }, undefined, undefined, { operationId: "row-0" });
    await metadata.finishImportSession(sessionId, "completed", { imported: 1 }, { operationId: "session-finish" });
    expect(db.query("SELECT status FROM import_sessions WHERE id = ?").get(sessionId)).toEqual({ status: "completed" });
    expect(db.query("SELECT row_index, status FROM import_rows WHERE import_session_id = ?").all(sessionId)).toEqual([{ row_index: 0, status: "imported" }]);

    await metadata.ensurePlan("other", "Other", { operationId: "plan-other" });
    const version = (db.query("SELECT write_version FROM write_state").get() as { write_version: number }).write_version;
    await expect(metadata.upsertAccount("other", { id: "a", name: "Collision" }, { operationId: "account-collision" })).rejects.toThrow("write precondition failed");
    expect(db.query("SELECT plan_id, name FROM accounts WHERE id = 'a'").get()).toEqual({ plan_id: "p", name: "Cash" });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: version });
  });

  test("unsupported graphs fail before any mutation", async () => {
    const db = await ledgerSqlite();
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));
    await expect(writer.create("p", { account_id: "a", date: "2026-07-01", amount: 1, subtransactions: [{ amount: 1 }] })).rejects.toThrow("at least two subtransactions");
    expect(db.query("SELECT COUNT(*) count FROM transactions").get()).toEqual({ count: 0 });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: 0 });
  });
});

async function ledgerSqlite(): Promise<Database> {
  const db = sqlite();
  for (const path of ["../d1-migrations/0001_initial.sql"]) db.exec(await Bun.file(new URL(path, import.meta.url)).text());
  db.run("INSERT INTO plans (id, name) VALUES ('p', 'Plan')");
  db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('a', 'p', 'Cash')");
  return db;
}

function sqlite(): Database { const db = new Database(":memory:", { strict: true }); databases.push(db); return db; }

function fakeD1(db: Database, faults: { commitThenThrowOnce?: boolean; commitThenThrowSql?: RegExp; beforeWriteBatch?: (db: Database) => void } = {}): D1Binding {
  let commitThenThrow = faults.commitThenThrowOnce ?? Boolean(faults.commitThenThrowSql);
  let mutateBeforeWrite = faults.beforeWriteBatch;
  class Statement implements D1Statement {
    values: unknown[] = [];
    constructor(readonly sql: string) {}
    bind(...values: unknown[]) { this.values = values; return this; }
    async all<Row>(): Promise<D1Result<Row>> { return { success: true, results: db.query(this.sql).all(...this.values as any[]) as Row[] }; }
    async first<Row>(): Promise<Row | null> { return db.query(this.sql).get(...this.values as any[]) as Row | null; }
    async run(): Promise<D1Result> { const result = db.query(this.sql).run(...this.values as any[]); return { success: true, meta: { changes: Number(result.changes) } }; }
    async execute<Row>(): Promise<D1Result<Row>> {
      return /^\s*(SELECT|WITH)\b/i.test(this.sql) ? this.all<Row>() : this.run() as Promise<D1Result<Row>>;
    }
  }
  return {
    prepare: (sql) => new Statement(sql),
    batch: async <Row>(statements: D1Statement[]) => {
      if (mutateBeforeWrite && statements.some((item) => /^INSERT INTO write_commands/i.test((item as Statement).sql))) {
        const mutate = mutateBeforeWrite; mutateBeforeWrite = undefined; mutate(db);
      }
      db.exec("BEGIN IMMEDIATE");
      try { const results = []; for (const statement of statements) results.push(await (statement as Statement).execute<Row>()); db.exec("COMMIT"); if (commitThenThrow && statements.some((item) => (faults.commitThenThrowSql ?? /^INSERT INTO write_commands/i).test((item as Statement).sql))) { commitThenThrow = false; throw new Error("ambiguous committed batch"); } return results as D1Result<Row>[]; }
      catch (error) { if (db.inTransaction) db.exec("ROLLBACK"); throw error; }
    },
  };
}
