import { Database } from "bun:sqlite";
import { afterEach, describe, expect, test } from "bun:test";
import { D1Database, type D1Binding, type D1Result, type D1Statement } from "../src/d1";
import { D1ReportService } from "../src/d1-reports";
import { D1ScheduledSyncState } from "../src/d1-scheduled-sync";
import { runD1ScheduledYnabSync } from "../src/d1-scheduled-sync-runner";
import { runDailyScheduledMaterialization, scheduledLocalDate, scheduledMaterializationOperationId } from "../src/scheduled-materialization-runner";
import { D1TransactionRepository } from "../src/d1-transaction-repository";
import { D1MetadataRepository } from "../src/d1-metadata-repository";
import { D1LedgerRepository } from "../src/d1-ledger-repository";
import { LedgerRepository } from "../src/repository";
import { D1AuthStore } from "../src/auth-store";
import { CountingD1Database, fakeD1Binding } from "./helpers/counting-d1";
import { newPersonalApiToken, newSession } from "../src/password-auth";
import { ReportService } from "../src/reports";
import { importYnabFromApi } from "../src/importers/ynab";
import { exportRewardsAccountConfig, importRewardsAccountConfig } from "../src/rewards/account-config";
import rewardsAccountConfig from "../../../fixtures/rewards-account-config.json";
import worker from "../../worker/src/index";

const databases: Database[] = [];
const originalFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch=originalFetch; for (const db of databases.splice(0)) db.close(); });

describe("D1 foundation", () => {
  test("unique live import_id cleanup recalculates denormalized account balances", async () => {
    const db = sqlite();
    for (const path of ["../d1-migrations/0001_initial.sql", "../d1-migrations/0002_password_auth.sql", "../d1-migrations/0003_allow_duplicate_payee_names.sql", "../d1-migrations/0004_ynab_raw_objects.sql", "../d1-migrations/0005_plan_month_assignments.sql", "../d1-migrations/0006_plan_month_category_targets.sql", "../d1-migrations/0007_scheduled_transaction_edits.sql", "../d1-migrations/0008_scheduled_transaction_snapshot_assertions.sql", "../d1-migrations/0009_account_reconciliation_assertions.sql"]) {
      db.exec(await Bun.file(new URL(path, import.meta.url)).text());
    }
    db.run("INSERT INTO plans (id, name) VALUES ('p', 'Plan')");
    db.run("INSERT INTO accounts (id, plan_id, name, opening_balance_milli, balance_milli, cleared_balance_milli, uncleared_balance_milli) VALUES ('a', 'p', 'Cash', 1000, -8000, -9000, 1000)");
    db.run("INSERT INTO accounts (id, plan_id, name, opening_balance_milli, balance_milli, cleared_balance_milli, uncleared_balance_milli) VALUES ('b', 'p', 'Card', 0, -9990, -9990, 0)");
    db.run("INSERT INTO transactions (id, plan_id, account_id, date, amount_milli, import_id, cleared, updated_at) VALUES ('old', 'p', 'a', '2026-01-01', -5000, 'dup', 'cleared', '2026-01-01T00:00:00Z')");
    db.run("INSERT INTO transactions (id, plan_id, account_id, date, amount_milli, import_id, cleared, updated_at) VALUES ('new', 'p', 'a', '2026-01-02', -4000, 'dup', 'uncleared', '2026-01-02T00:00:00Z')");
    db.run("INSERT INTO transactions (id, plan_id, account_id, date, amount_milli, import_id, cleared, updated_at) VALUES ('other', 'p', 'b', '2026-01-01', -9990, 'dup', 'cleared', '2026-01-01T00:00:00Z')");
    db.exec(await Bun.file(new URL("../d1-migrations/0010_unique_live_import_id.sql", import.meta.url)).text());
    expect(db.query("SELECT id, account_id, amount_milli FROM transactions ORDER BY id").all()).toEqual([
      { id: "new", account_id: "a", amount_milli: -4000 },
      { id: "other", account_id: "b", amount_milli: -9990 },
    ]);
    expect(db.query("SELECT balance_milli, cleared_balance_milli, uncleared_balance_milli FROM accounts WHERE id = 'a'").get()).toEqual({
      balance_milli: -3000,
      cleared_balance_milli: 1000,
      uncleared_balance_milli: -4000,
    });
    expect(db.query("SELECT balance_milli FROM accounts WHERE id = 'b'").get()).toEqual({ balance_milli: -9990 });
    expect(db.query("SELECT name FROM pragma_index_info('idx_transactions_live_import_id') ORDER BY seqno").all()).toEqual([
      { name: "plan_id" },
      { name: "account_id" },
      { name: "import_id" },
    ]);
  });

  test("canonical schema applies cleanly with auth constraints and cascades", async () => {
    const db = sqlite();
    for (const path of ["../d1-migrations/0001_initial.sql", "../d1-migrations/0002_password_auth.sql", "../d1-migrations/0003_allow_duplicate_payee_names.sql", "../d1-migrations/0004_ynab_raw_objects.sql", "../d1-migrations/0005_plan_month_assignments.sql", "../d1-migrations/0006_plan_month_category_targets.sql", "../d1-migrations/0007_scheduled_transaction_edits.sql", "../d1-migrations/0008_scheduled_transaction_snapshot_assertions.sql", "../d1-migrations/0009_account_reconciliation_assertions.sql", "../d1-migrations/0010_unique_live_import_id.sql", "../d1-migrations/0011_personal_api_tokens.sql", "../d1-migrations/0012_account_preferences.sql", "../d1-migrations/0013_account_icons.sql", "../d1-migrations/0014_account_icon_emoji_backfill.sql", "../d1-migrations/0015_rewards_tracker.sql", "../d1-migrations/0016_query_covering_indexes.sql", "../d1-migrations/0017_ynab_source_month_activity.sql", "../d1-migrations/0018_account_month_balances.sql"]) db.exec(await Bun.file(new URL(path, import.meta.url)).text());
    const objects = db.query("SELECT name,type FROM sqlite_master WHERE type IN ('table','index','trigger')").all() as Array<{name:string;type:string}>;
    const names = new Set(objects.map((row) => row.name));
    for (const name of ["plans","import_sessions","import_rows","ynab_raw_objects","plan_month_assignments","plan_month_category_targets","scheduled_transaction_edits","scheduled_subtransaction_edits","scheduled_transaction_snapshot_assertions","account_reconciliation_assertions","users","auth_identities","sessions","personal_api_tokens","account_preferences","plan_memberships","password_credentials","auth_setup","login_rate_limits","sync_runs","sync_attempts","sync_transition_receipts","audit_events","write_state","write_commands","write_assertions","rewards_tracker_snapshots","rewards_tracker_cards","idx_sessions_user","idx_sessions_expiry","idx_personal_api_tokens_user","idx_plan_memberships_user_plan","idx_transactions_transfer_transaction_id","idx_subtransactions_transfer_transaction_id","idx_transactions_plan_live_register","idx_transactions_account_live_register","idx_transactions_account_reconciled_date","idx_payees_plan_live_name","idx_account_reconciliation_assertions_account_date","transactions_assign_ledger_sequence","accounts_transfer_payee_plan_guard"]) expect(names.has(name)).toBeTrue();
    expect(db.query("SELECT name FROM pragma_table_info('accounts') WHERE name='icon'").get()).toEqual({ name: "icon" });
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

    db.run("INSERT INTO payees(id,plan_id,name) VALUES ('same-a','p1','Same'),('same-b','p1','Same')");
    expect(db.query("SELECT id FROM payees WHERE plan_id='p1' AND name='Same' ORDER BY id").all()).toEqual([{ id: "same-a" }, { id: "same-b" }]);
  });

  test("D1 account preferences use compare-and-set revisions", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO users(id) VALUES ('u')");
    let mutationStarted!: () => void;
    let releaseMutation!: () => void;
    const started = new Promise<void>((resolve) => { mutationStarted = resolve; });
    const gate = new Promise<void>((resolve) => { releaseMutation = resolve; });
    let shouldDelayMutation = true;
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db, {
      beforeRunMutation: async () => {
        if (!shouldDelayMutation) return;
        shouldDelayMutation = false;
        mutationStarted();
        await gate;
      },
    })), "p");
    const preferences = {
      favourite_account_ids: ["a"], account_order: [], account_order_by_group: {},
      account_group_sorts: {}, custom_account_groups: [],
    };

    expect(await repo.getAccountPreferences("p", "u")).toEqual({
      account_preferences: null, account_preferences_revision: 0,
    });
    const firstWrite = repo.setAccountPreferences("p", "u", preferences, 0);
    let firstWriteSettled = false;
    void firstWrite.then(
      () => { firstWriteSettled = true; },
      () => { firstWriteSettled = true; },
    );
    await started;
    await Bun.sleep(0);
    expect(firstWriteSettled).toBeFalse();
    releaseMutation();
    expect(await firstWrite).toEqual({
      account_preferences: preferences, account_preferences_revision: 1,
    });
    await expect(repo.setAccountPreferences("p", "u", { ...preferences, favourite_account_ids: [] }, 0)).rejects.toThrow();
    expect((await repo.setAccountPreferences("p", "u", { ...preferences, favourite_account_ids: [] }, 1)).account_preferences_revision).toBe(2);
  });

  test("D1 auth setup is atomic, one-time, and uses returning rate counters", async () => {
    const db = await ledgerSqlite();
    const auth = new D1AuthStore(new D1Database(fakeD1(db)));
    const session = newSession(1_800_000_000);
    const input = {
      userId: "owner-user",
      username: "owner",
      credential: {
        kdf: "scrypt",
        kdf_version: 1,
        cost_n: 16_384,
        block_size: 8,
        parallelization: 5,
        salt_hex: "ab".repeat(16),
        hash_hex: "cd".repeat(32),
      },
      session,
      planId: "p",
    };

    expect(await auth.setupRequired()).toBeTrue();
    expect(await auth.setup(input)).toBeTrue();
    expect(await auth.setupRequired()).toBeFalse();
    expect(await auth.setup({ ...input, userId: "other-user", username: "other", session: newSession() })).toBeFalse();
    expect(db.query("SELECT COUNT(*) AS count FROM users").get()).toEqual({ count: 1 });
    expect(db.query("SELECT role FROM plan_memberships WHERE user_id='owner-user'").get()).toEqual({ role: "owner" });
    expect((await auth.authenticateSession(session.tokenHash, 1_800_000_001))?.username).toBe("owner");
    const personal = newPersonalApiToken(1_800_000_002);
    await auth.createPersonalApiToken({
      id: personal.id,
      userId: "owner-user",
      name: "Test integration",
      tokenHash: personal.tokenHash,
      created_at: personal.createdAt,
      revoked_at: null,
    });
    expect(await auth.listPersonalApiTokens("owner-user")).toEqual([{
      id: personal.id,
      name: "Test integration",
      created_at: personal.createdAt,
      revoked_at: null,
    }]);
    expect((await auth.authenticatePersonalApiToken(personal.tokenHash))?.username).toBe("owner");
    expect(await auth.revokePersonalApiToken("other-user", personal.id, 1_800_000_003)).toBeNull();
    expect(await auth.revokePersonalApiToken("owner-user", personal.id, 1_800_000_003)).toMatchObject({ revoked_at: 1_800_000_003 });
    expect(await auth.authenticatePersonalApiToken(personal.tokenHash)).toBeNull();
    expect(await auth.rateAttempt("username", "ef".repeat(32), 1_800_000_000)).toBe(1);
    expect(await auth.rateAttempt("username", "ef".repeat(32), 1_800_000_000)).toBe(2);
  });

  test("Worker composition is D1-only, serves API writes, delegates assets, and binds reviewed databases", async () => {
    const db = await ledgerSqlite();
    const assetRequests: string[] = [];
    const env = {
      ASSETS: { fetch: async (request: Request) => { assetRequests.push(request.url); return new Response("asset"); } },
      DB: fakeD1(db),
      HOWMUCH_API_TOKEN: "worker-token",
      HOWMUCH_DEFAULT_PLAN_ID: "p",
      HOWMUCH_TIME_ZONE: "Asia/Singapore",
      HOWMUCH_TRANSITION_READ_ONLY: "false",
    };
    const headers = { authorization: "Bearer worker-token", "content-type": "application/json" };

    const plans = await worker.fetch(new Request("https://howmuch.test/v1/plans", { headers }), env as any);
    expect(plans.status).toBe(200);
    const planBody = await plans.json() as { data: { plans: Array<{ id: string }> } };
    expect(planBody.data.plans.map((plan) => plan.id)).toEqual(["p"]);
    const versionBeforeRead = db.query("SELECT write_version FROM write_state").get();
    const accounts = await worker.fetch(new Request("https://howmuch.test/v1/plans/p/accounts", { headers }), env as any);
    expect(accounts.status).toBe(200);
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual(versionBeforeRead);
    const account = await worker.fetch(new Request("https://howmuch.test/v1/plans/p/accounts", {
      method: "POST", headers, body: JSON.stringify({ account: { id: "worker-account", name: "Worker account" } }),
    }), env as any);
    expect(account.status).toBe(201);
    expect(db.query("SELECT name FROM accounts WHERE id='worker-account'").get()).toEqual({ name: "Worker account" });

    const asset = await worker.fetch(new Request("https://howmuch.test/dashboard"), env as any);
    expect(await asset.text()).toBe("asset");
    expect(assetRequests).toEqual(["https://howmuch.test/dashboard"]);
    await expect(worker.scheduled({ cron: "5 16 * * *", scheduledTime: Date.UTC(2026, 7, 20, 16, 5) } as any, env as any)).resolves.toBeUndefined();

    const workerSource = await Bun.file(new URL("../../worker/src/index.ts", import.meta.url)).text();
    expect(workerSource).not.toContain("@neondatabase");
    expect(workerSource).not.toContain("DATABASE_URL");
    expect(workerSource).not.toContain("HOWMUCH_DATABASE_BACKEND");
    const rootPackage = await Bun.file(new URL("../../../package.json", import.meta.url)).json();
    expect(rootPackage.dependencies).toBeUndefined();
    const workerPackage = await Bun.file(new URL("../../worker/package.json", import.meta.url)).json();
    expect(workerPackage.scripts["build:web"]).toBe("bun run --cwd ../web build");
    expect(workerPackage.scripts.build).toBe("bun run build:web && wrangler deploy --dry-run --outdir dist");
    // A bare deploy must refuse: every real deploy pins a profile and env.
    expect(workerPackage.scripts.deploy).toContain("Refusing unqualified deploy");
    expect(workerPackage.scripts.deploy).toContain("exit 1");
    expect(workerPackage.scripts["deploy:tk"]).toBe("bun run build:web && wrangler deploy --env tk --profile tinkertanker");
    expect(workerPackage.scripts["deploy:yj-redirect"]).toBe("bun run build:web && wrangler deploy --profile yj");
    expect(workerPackage.scripts["deploy:preview"]).toBe("bun run build:web && wrangler deploy --env preview --profile yj");
    const wranglerConfig = JSON.parse((await Bun.file(new URL("../../worker/wrangler.jsonc", import.meta.url)).text()).replace(/^\s*\/\/.*$/gm, ""));
    // Top level = legacy YJ account: frozen backup database, permanent redirect, no cron.
    expect(wranglerConfig.d1_databases[0]).toMatchObject({ database_name: "howmuch-production", database_id: "57dc5569-d639-44c1-bb9d-6214f43a43b8" });
    expect(wranglerConfig.vars).toMatchObject({
      HOWMUCH_DEFAULT_PLAN_ID: "80bc6db0-d926-4635-a37a-1ba0787c4c4e",
      HOWMUCH_TIME_ZONE: "Asia/Singapore",
      HOWMUCH_REDIRECT_TARGET: "https://howmuch.tk.sg",
    });
    expect(wranglerConfig.triggers.crons).toEqual([]);
    expect(wranglerConfig.routes).toEqual([{ pattern: "howmuch.soon.sg", custom_domain: true }]);
    // tk env = production in the Tinkertanker account: SIN database, writable, daily materialisation, no redirect var.
    expect(wranglerConfig.env.tk.d1_databases[0]).toMatchObject({ database_name: "howmuch-production-sg", database_id: "d13295f9-10d4-4ac0-bf62-b3e8c78cbf29" });
    expect(wranglerConfig.env.tk.routes).toEqual([{ pattern: "howmuch.tk.sg", custom_domain: true }]);
    expect(wranglerConfig.env.tk.triggers.crons).toEqual(["5 16 * * *"]);
    expect(wranglerConfig.env.tk.vars).toEqual({
      HOWMUCH_DEFAULT_PLAN_ID: "80bc6db0-d926-4635-a37a-1ba0787c4c4e",
      HOWMUCH_TIME_ZONE: "Asia/Singapore",
      HOWMUCH_YNAB_PLAN_ID: "",
      HOWMUCH_TRANSITION_READ_ONLY: "false",
    });
    expect(wranglerConfig.env.tk.vars).not.toHaveProperty("HOWMUCH_REDIRECT_TARGET");
    // preview env stays in the YJ account.
    expect(wranglerConfig.env.preview.d1_databases[0]).toMatchObject({ database_name: "howmuch-preview", database_id: "7ca818bd-7f04-4b9b-8a84-8c8f84a6a272" });
    expect(wranglerConfig.env.preview.routes).toEqual([]);
    expect(wranglerConfig.env.preview.triggers.crons).toEqual([]);
    expect(wranglerConfig.env.preview.vars).toEqual({
      HOWMUCH_DEFAULT_PLAN_ID: "80bc6db0-d926-4635-a37a-1ba0787c4c4e",
      HOWMUCH_TIME_ZONE: "Asia/Singapore",
      HOWMUCH_TRANSITION_READ_ONLY: "false",
    });
    expect(workerSource).toContain("HOWMUCH_YNAB_TOKEN");
    expect(workerSource).toContain("runD1ScheduledYnabSync");
    expect(await Bun.file(new URL("../../../bun.lock", import.meta.url)).text()).not.toContain("@neondatabase/serverless");
  });

  test("Worker routes exact crons while allowing YNAB sync after financial writes are enabled", async () => {
    const db = await ledgerSqlite();
    const setup = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await setup.createScheduledTransaction("p", {
      id: "transition-schedule", account_id: "a", date_first: "2026-08-21", frequency: "never", amount: -200,
    });
    let fetchCount = 0;
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      fetchCount += 1;
      const url = String(input);
      if (url.endsWith("/plans/p")) {
        return new Response(JSON.stringify({ data: { plan: {
          id: "p", name: "Plan", accounts: [{ id: "a", name: "Cash" }], category_groups: [], categories: [], payees: [],
          months: [], transactions: [], scheduled_transactions: [], scheduled_subtransactions: [], payee_locations: [],
        }, server_knowledge: 9 } }), { headers: { "content-type": "application/json" } });
      }
      if (url.endsWith("/plans/p/settings")) {
        return new Response(JSON.stringify({ data: { settings: {} } }), { headers: { "content-type": "application/json" } });
      }
      return new Response("not found", { status: 404 });
    }) as typeof fetch;
    const baseEnv = {
      ASSETS: { fetch: async () => new Response("asset") }, DB: fakeD1(db), HOWMUCH_API_TOKEN: "worker-token",
      HOWMUCH_DEFAULT_PLAN_ID: "p", HOWMUCH_TIME_ZONE: "Asia/Singapore",
    };
    const transitionEnv = {
      ...baseEnv, HOWMUCH_TRANSITION_READ_ONLY: "true", HOWMUCH_YNAB_TOKEN: "secret-token", HOWMUCH_YNAB_PLAN_ID: "p",
    };
    const writableEnv = { ...baseEnv, HOWMUCH_TRANSITION_READ_ONLY: "false" };
    const writableYnabEnv = { ...transitionEnv, HOWMUCH_TRANSITION_READ_ONLY: "false" };
    const transitionController = { cron: "10 16 * * *", scheduledTime: Date.UTC(2026, 7, 20, 16, 10) } as any;
    const logs: string[] = [];
    const originalLog = console.log;
    console.log = (value: string) => { logs.push(value); };
    try {
      await worker.scheduled(transitionController, transitionEnv as any);
      expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 0 });
      expect(logs).toHaveLength(1);
      expect(JSON.parse(logs[0])).toMatchObject({
        event: "ynab_delta_sync", status: "completed", imported_transaction_count: 0, cursor: 9,
      });
      expect(JSON.stringify(JSON.parse(logs[0]))).not.toContain("secret-token");
      expect(JSON.stringify(JSON.parse(logs[0]))).not.toContain("Plan");

      const fetchesAfterCompletion = fetchCount;
      await worker.scheduled(transitionController, transitionEnv as any);
      expect(fetchCount).toBe(fetchesAfterCompletion);
      expect(JSON.parse(logs[1])).toMatchObject({ event: "ynab_delta_sync", status: "duplicate" });

      await expect(worker.scheduled({ cron: "5 16 * * *", scheduledTime: transitionController.scheduledTime } as any, transitionEnv as any))
        .rejects.toThrow("does not match transition read-only mode");
      await expect(worker.scheduled(transitionController, writableYnabEnv as any)).resolves.toBeUndefined();
      expect(JSON.parse(logs[2])).toMatchObject({ event: "ynab_delta_sync", status: "duplicate" });
      await expect(worker.scheduled({ cron: "0 0 * * *", scheduledTime: transitionController.scheduledTime } as any, transitionEnv as any))
        .rejects.toThrow("Unknown scheduled cron");
      await expect(worker.scheduled({ scheduledTime: transitionController.scheduledTime } as any, transitionEnv as any))
        .rejects.toThrow("Unknown scheduled cron: missing");

      await worker.scheduled({ cron: "5 16 * * *", scheduledTime: Date.UTC(2026, 7, 20, 16, 5) } as any, writableEnv as any);
      expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 1 });
    } finally {
      console.log = originalLog;
    }
  });

  test("Worker cron logs a count-only failure summary after materialising valid schedules", async () => {
    const db = await ledgerSqlite();
    const setup = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await setup.upsertPayee("p", { id: "cron-deleted-payee", name: "Temporary" });
    await setup.createScheduledTransaction("p", {
      id: "cron-bad", account_id: "a", payee_id: "cron-deleted-payee", date_first: "2026-08-21", frequency: "never", amount: -100,
    });
    await setup.createScheduledTransaction("p", {
      id: "cron-good", account_id: "a", date_first: "2026-08-21", frequency: "never", amount: -200,
    });
    db.run("UPDATE payees SET deleted=1 WHERE plan_id='p' AND id='cron-deleted-payee'");
    const env = {
      ASSETS: { fetch: async () => new Response("asset") }, DB: fakeD1(db), HOWMUCH_API_TOKEN: "worker-token",
      HOWMUCH_DEFAULT_PLAN_ID: "p", HOWMUCH_TIME_ZONE: "Asia/Singapore", HOWMUCH_TRANSITION_READ_ONLY: "false",
    };
    const logs: string[] = [];
    const originalLog = console.log;
    console.log = (value: string) => { logs.push(value); };
    try {
      await expect(worker.scheduled({ cron: "5 16 * * *", scheduledTime: Date.UTC(2026, 7, 20, 16, 5) } as any, env as any))
        .rejects.toThrow("Scheduled materialisation completed with schedule failures");
    } finally {
      console.log = originalLog;
    }

    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 1 });
    const event = JSON.parse(logs[0]);
    expect(event).toEqual({
      event: "scheduled_materialization", through_date: "2026-08-21", occurrence_count: 1,
      skipped_closed_schedule_count: 0, failure_count: 1, has_more: true,
    });
    expect(JSON.stringify(event)).not.toContain("cron-bad");
    expect(JSON.stringify(event)).not.toContain("cron-good");
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
    await repo.updateTransaction("p", "api-row", { import_id: "stolen", deleted: true, memo: "keep-import" });
    expect(db.query("SELECT import_id, deleted, memo FROM transactions WHERE id='api-row'").get()).toEqual({
      import_id: null, deleted: 0, memo: "keep-import",
    });
    await repo.createTransaction("p", { id: "api-row-2", account_id: "a", date: "2026-07-01", amount: -50 });
    const batch = await repo.updateTransactions("p", [
      { lookup: { kind: "id", id: "api-row" }, patch: { memo: "one" } },
      { lookup: { kind: "id", id: "api-row-2" }, patch: { memo: "two" } },
    ]);
    expect(batch.transaction_ids).toEqual(["api-row", "api-row-2"]);
    expect(batch.transactions.map((row) => row.memo)).toEqual(["one", "two"]);
    const createdMany = await repo.createTransactions("p", [
      { account_id: "a", date: "2026-07-03", amount: -10, import_id: "d1-batch-1" },
      { account_id: "a", date: "2026-07-04", amount: -20 },
    ]);
    expect(createdMany.transaction_ids).toHaveLength(2);
    expect((await repo.createTransactions("p", [
      { account_id: "a", date: "2026-07-03", amount: -10, import_id: "d1-batch-1" },
    ])).duplicate_import_ids).toEqual(["d1-batch-1"]);

    const raceRepo = new D1LedgerRepository(d1, "p");
    const createTransaction = raceRepo.createTransaction.bind(raceRepo);
    (raceRepo as any).createTransaction = async (planId: string, input: any) => {
      await createTransaction(planId, { ...input, id: "d1-raced-create" });
      throw new Error("simulated unique import_id race");
    };
    const raced = await raceRepo.createTransactions("p", [
      { account_id: "a", date: "2026-07-05", amount: -30, import_id: "d1-batch-race" },
    ]);
    expect(raced).toMatchObject({
      transaction_ids: ["d1-raced-create"], duplicate_import_ids: ["d1-batch-race"],
    });

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

  test("D1 schedule writes overlay imported rows, replay safely, and retain transfer and split references", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.upsertAccount("p", { id: "b", name: "Savings" });
    await repo.upsertCategoryGroup("p", { id: "living", name: "Living" });
    await repo.upsertCategory("p", { id: "food", category_group_id: "living", name: "Food" });
    await repo.upsertPayee("p", { id: "merchant", name: "Merchant" });
    const transferPayee = db.query("SELECT id FROM payees WHERE plan_id='p' AND transfer_account_id='b'").get() as { id: string };
    const source = {
      id: "source-schedule", account_id: "a", account_name: "Cash", date_first: "2026-08-01",
      date_next: "2026-09-01", frequency: "monthly", amount: -1000, payee_id: "merchant",
      category_id: "food", memo: "source", source_marker: "immutable", deleted: false,
    };
    await repo.upsertYnabRawObject("p", "scheduled_transaction", source.id, source);
    const rawBefore = db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='scheduled_transaction' AND object_id=?").get(source.id);
    const versionBefore = (db.query("SELECT write_version FROM write_state").get() as { write_version: number }).write_version;

    const updated = await repo.updateScheduledTransaction("p", source.id, { date_next: "2026-10-01", memo: "edited" }, { operationId: "schedule-update-once" });
    const replayedUpdate = await repo.updateScheduledTransaction("p", source.id, { date_next: "2026-10-01", memo: "edited" }, { operationId: "schedule-update-once" });
    expect(replayedUpdate).toEqual(updated);
    expect(updated).toMatchObject({ id: source.id, date_next: "2026-10-01", memo: "edited", source_marker: "immutable", deleted: false });
    expect(Object.hasOwn(updated, "deleted")).toBe(true);
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='scheduled_transaction' AND object_id=?").get(source.id)).toEqual(rawBefore);
    expect(db.query("SELECT origin FROM scheduled_transaction_edits WHERE id=?").get(source.id)).toEqual({ origin: "ynab-overlay" });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: versionBefore + 1 });

    const splitInput = {
      account_id: "a", date_first: "2026-08-15", frequency: "monthly", amount: -3000,
      subtransactions: [
        { amount: -1000, category_id: "food", memo: "food" },
        { amount: -2000, payee_id: transferPayee.id, transfer_account_id: "b", memo: "save" },
      ],
    };
    const created = await repo.createScheduledTransaction("p", splitInput, { operationId: "schedule-create-once" });
    const replayedCreate = await repo.createScheduledTransaction("p", splitInput, { operationId: "schedule-create-once" });
    expect(replayedCreate).toEqual(created);
    expect(created).toMatchObject({ account_id: "a", date_next: "2026-08-15", amount: -3000, deleted: false });
    expect(Object.hasOwn(created, "deleted")).toBe(true);
    const patched = await repo.updateScheduledTransaction("p", created.id, { memo: "after create" }, { operationId: "schedule-patch-created" });
    expect(Object.hasOwn(patched, "deleted")).toBe(true);
    expect(patched.deleted).toBe(false);
    expect(patched.memo).toBe("after create");
    expect(created.subtransactions).toEqual(expect.arrayContaining([
      expect.objectContaining({ amount: -1000, category_id: "food" }),
      expect.objectContaining({ amount: -2000, payee_id: transferPayee.id, transfer_account_id: "b" }),
    ]));
    expect(db.query("SELECT COUNT(*) AS count FROM scheduled_subtransaction_edits WHERE scheduled_transaction_id=?").get(created.id)).toEqual({ count: 2 });
    expect(db.query("SELECT COUNT(*) AS count FROM audit_events WHERE action='scheduled_transaction.create'").get()).toEqual({ count: 1 });
    await expect(repo.createScheduledTransaction("p", { ...splitInput, memo: "different request" }, { operationId: "schedule-create-once" })).rejects.toThrow("idempotency-key reuse");
    expect((await repo.listScheduledSubtransactions("p")).map((row) => row.id)).toEqual(created.subtransactions.map((row: any) => row.id));

    const deleted = await repo.deleteScheduledTransaction("p", source.id, { operationId: "schedule-delete-once" });
    const replayedDelete = await repo.deleteScheduledTransaction("p", source.id, { operationId: "schedule-delete-once" });
    expect(replayedDelete).toEqual(deleted);
    expect(deleted.deleted).toBeTrue();
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='scheduled_transaction' AND object_id=?").get(source.id)).toEqual(rawBefore);
    expect((await repo.listScheduledTransactions("p")).map((row) => row.id)).toEqual([created.id]);
  });

  test("D1 materialisation pairs explicit transfers, applies cash clearing per leg, and replays exactly", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.upsertAccount("p", { id: "a", name: "Cash", type: "checking" });
    await repo.upsertAccount("p", { id: "wallet", name: "Wallet", type: "cash" });
    await repo.upsertCategoryGroup("p", { id: "living", name: "Living" });
    await repo.upsertCategory("p", { id: "food", name: "Food" }, "living");
    await repo.createScheduledTransaction("p", {
      id: "cash-to-bank", account_id: "wallet", date_first: "2026-01-31", date_next: "2026-01-31",
      frequency: "monthly", amount: -1000, transfer_account_id: "a",
    });

    const first = await repo.materializeScheduledOccurrence("p", "cash-to-bank", "2026-01-31", "2026-01-20", { requestOperationId: "d1-enter-cash" });
    expect(first).toMatchObject({ replayed: false, transaction: { account_id: "wallet", cleared: "cleared", approved: false }, scheduled_transaction: { date_next: "2026-02-28" } });
    expect(db.query("SELECT account_id,cleared,approved,amount_milli FROM transactions WHERE transfer_transaction_id=?").get(first.transaction.id)).toEqual({ account_id: "a", cleared: "uncleared", approved: 0, amount_milli: 1000 });
    const replay = await repo.materializeScheduledOccurrence("p", "cash-to-bank", "2026-01-31", "2026-01-20", { requestOperationId: "d1-enter-cash" });
    expect(replay).toMatchObject({ replayed: true, transaction: { id: first.transaction.id }, scheduled_transaction: { date_next: "2026-02-28" } });
    expect(db.query("SELECT COUNT(*) count FROM transactions").get()).toEqual({ count: 2 });

    await repo.createScheduledTransaction("p", {
      id: "split-to-cash", account_id: "a", date_first: "2026-08-24", frequency: "never", amount: -3000,
      subtransactions: [{ amount: -1000, category_id: "food" }, { amount: -2000, transfer_account_id: "wallet" }],
    });
    const split = await repo.materializeScheduledOccurrence("p", "split-to-cash", "2026-08-24", "2026-08-20", { requestOperationId: "d1-enter-split" });
    expect(split).toMatchObject({ completed: true, scheduled_transaction: { deleted: true } });
    expect(split.transaction.subtransactions).toEqual(expect.arrayContaining([expect.objectContaining({ transfer_account_id: "wallet", amount: -2000 })]));
    expect(db.query("SELECT cleared,approved,amount_milli FROM transactions WHERE account_id='wallet' AND id<>?").get(first.transaction.id)).toEqual({ cleared: "cleared", approved: 0, amount_milli: 2000 });
  });

  test("D1 reconciliation is account-scoped, handles large candidate sets, and replays exactly", async () => {
    const db = await ledgerSqlite();
    db.run("UPDATE accounts SET opening_balance_milli=1000 WHERE id='a'");
    db.run("INSERT INTO accounts(id,plan_id,name) VALUES ('other','p','Other')");
    db.run("INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,cleared) VALUES ('prior','p','a','2026-07-01',100,'reconciled')");
    for (let index = 0; index < 101; index += 1) {
      db.run(
        "INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,cleared) VALUES (?,?,?,?,?,'cleared')",
        [`eligible-${String(index).padStart(3, "0")}`, "p", "a", "2026-08-20", -1],
      );
    }
    db.run("INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,cleared) VALUES ('future','p','a','2026-09-01',-300,'cleared')");
    db.run("INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,cleared) VALUES ('uncleared','p','a','2026-08-01',-400,'uncleared')");
    db.run("INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,cleared,deleted) VALUES ('deleted','p','a','2026-08-01',-500,'cleared',1)");
    db.run("INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,cleared) VALUES ('other-row','p','other','2026-08-01',700,'cleared')");
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db, { maxBindings: 50 })), "p");

    const preview = await repo.getAccountReconciliation("p", "a", "2026-08-31");
    expect(preview).toMatchObject({
      account: { id: "a" }, statement_date: "2026-08-31",
      current_reconciled_balance: 1100, projected_reconciled_balance: 999,
      candidate_transaction_count: 101,
    });
    expect(preview.candidate_transaction_ids[0]).toBe("eligible-000");
    expect(preview.candidate_transaction_ids.at(-1)).toBe("eligible-100");
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: 0 });
    await expect(repo.reconcileAccount("p", "a", "2026-08-31", 1000, { operationId: "d1-reconcile-mismatch" }))
      .rejects.toMatchObject({ currentReconciledBalance: 1100, projectedReconciledBalance: 999, difference: 1 });
    const versionBefore = (db.query("SELECT write_version FROM write_state").get() as { write_version: number }).write_version;
    const first = await repo.reconcileAccount("p", "a", "2026-08-31", 999, { operationId: "d1-reconcile-august" });
    expect(first).toMatchObject({
      account: { id: "a", last_reconciled_date: "2026-08-31" }, reconciled_transaction_count: 101,
      statement_date: "2026-08-31", statement_balance: 999,
      prior_reconciled_balance: 1100, final_reconciled_balance: 999,
      replayed: false,
    });
    expect(first.reconciled_transaction_ids[0]).toBe("eligible-000");
    expect(first.reconciled_transaction_ids.at(-1)).toBe("eligible-100");
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE account_id='a' AND cleared='reconciled'").get()).toEqual({ count: 102 });
    expect(db.query("SELECT id,cleared,deleted FROM transactions WHERE id IN ('future','uncleared','deleted','other-row') ORDER BY id").all()).toEqual([
      { id: "deleted", cleared: "cleared", deleted: 1 },
      { id: "future", cleared: "cleared", deleted: 0 },
      { id: "other-row", cleared: "cleared", deleted: 0 },
      { id: "uncleared", cleared: "uncleared", deleted: 0 },
    ]);
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: versionBefore + 1 });

    const replay = await repo.reconcileAccount("p", "a", "2026-08-31", 999, { operationId: "d1-reconcile-august" });
    expect(replay).toMatchObject({ ...first, replayed: true });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: versionBefore + 1 });
    expect(db.query("SELECT COUNT(*) count FROM audit_events WHERE action='account.reconcile'").get()).toEqual({ count: 1 });
    await expect(repo.reconcileAccount("p", "a", "2026-08-31", 998, { operationId: "d1-reconcile-august" })).rejects.toThrow("idempotency-key reuse");
  });

  test("D1 reconciliation aborts the whole batch when an eligible row changes after preflight", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,cleared) VALUES ('racing-cleared','p','a','2026-08-01',-100,'cleared')");
    const knowledgeBefore = db.query("SELECT server_knowledge FROM plans WHERE id='p'").get();
    const versionBefore = db.query("SELECT write_version FROM write_state").get();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db, { beforeWriteBatch: (database) => {
      database.run("UPDATE transactions SET cleared='uncleared' WHERE id='racing-cleared'");
    } })), "p");

    await expect(repo.reconcileAccount("p", "a", "2026-08-31", -100, { operationId: "d1-reconcile-race" }))
      .rejects.toThrow("stale account reconciliation");
    expect(db.query("SELECT cleared FROM transactions WHERE id='racing-cleared'").get()).toEqual({ cleared: "uncleared" });
    expect(db.query("SELECT server_knowledge FROM plans WHERE id='p'").get()).toEqual(knowledgeBefore);
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual(versionBefore);
    expect(db.query("SELECT id FROM write_commands WHERE id='d1-reconcile-race'").get()).toBeNull();
    expect(db.query("SELECT COUNT(*) count FROM audit_events WHERE action='account.reconcile'").get()).toEqual({ count: 0 });
  });

  test("D1 reconciliation is isolated by plan and recovers an ambiguous committed batch", async () => {
    const db = await ledgerSqlite();
    const setup = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await setup.ensurePlan("other", "Other");
    await setup.createAccount("other", { id: "other-account", name: "Other account" });
    await setup.createTransaction("other", { id: "other-cleared", account_id: "other-account", date: "2026-08-01", amount: 75, cleared: "cleared" });
    const versionBefore = (db.query("SELECT write_version FROM write_state").get() as { write_version: number }).write_version;

    await expect(setup.reconcileAccount("p", "other-account", "2026-08-31", 75, { operationId: "wrong-plan-reconcile" }))
      .rejects.toThrow("Account not found");
    expect(db.query("SELECT cleared FROM transactions WHERE id='other-cleared'").get()).toEqual({ cleared: "cleared" });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: versionBefore });

    db.run("INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,cleared) VALUES ('ambiguous-cleared','p','a','2026-08-01',-100,'cleared')");
    const ambiguous = new D1LedgerRepository(new D1Database(fakeD1(db, { commitThenThrowOnce: true })), "p");
    const first = await ambiguous.reconcileAccount("p", "a", "2026-08-31", -100, { operationId: "ambiguous-reconcile" });
    expect(first).toMatchObject({ reconciled_transaction_ids: ["ambiguous-cleared"], replayed: false });
    expect(db.query("SELECT cleared FROM transactions WHERE id='ambiguous-cleared'").get()).toEqual({ cleared: "reconciled" });
    expect(db.query("SELECT COUNT(*) count FROM audit_events WHERE action='account.reconcile' AND resource_id='a'").get()).toEqual({ count: 1 });
    const replay = await ambiguous.reconcileAccount("p", "a", "2026-08-31", -100, { operationId: "ambiguous-reconcile" });
    expect(replay).toMatchObject({ reconciled_transaction_ids: ["ambiguous-cleared"], replayed: true });
    expect(db.query("SELECT COUNT(*) count FROM audit_events WHERE action='account.reconcile' AND resource_id='a'").get()).toEqual({ count: 1 });
  });

  test("D1 materialisation preserves a concurrent schedule edit and cannot post a second occurrence", async () => {
    const db = await ledgerSqlite();
    const setup = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await setup.createScheduledTransaction("p", {
      id: "racing", account_id: "a", date_first: "2026-08-24", date_next: "2026-08-24", frequency: "monthly", amount: -100,
    });
    const racing = new D1LedgerRepository(new D1Database(fakeD1(db, { beforeWriteBatch: (database) => {
      const row = database.query("SELECT payload_json FROM scheduled_transaction_edits WHERE plan_id='p' AND id='racing'").get() as { payload_json: string };
      const payload = { ...JSON.parse(row.payload_json), date_next: "2026-09-15", memo: "user edit" };
      database.query("UPDATE scheduled_transaction_edits SET payload_json=?,date_next=? WHERE plan_id='p' AND id='racing'").run(JSON.stringify(payload), payload.date_next);
    } })), "p");

    await expect(racing.materializeScheduledOccurrence("p", "racing", "2026-08-24", "2026-08-24")).rejects.toThrow("stale scheduled occurrence");
    expect(await racing.getScheduledTransaction("p", "racing")).toMatchObject({ date_next: "2026-09-15", memo: "user edit" });
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 1 });
    const replay = await racing.materializeScheduledOccurrence("p", "racing", "2026-08-24", "2026-08-24");
    expect(replay).toMatchObject({ replayed: true, scheduled_transaction: { date_next: "2026-09-15", memo: "user edit" } });
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 1 });
  });

  test("D1 manual catch-up materialises every missed anchored date and completes one-off schedules", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.createScheduledTransaction("p", {
      id: "month-end", account_id: "a", date_first: "2026-01-31", date_next: "2026-01-31", frequency: "monthly", amount: -100,
    });
    await repo.createScheduledTransaction("p", {
      id: "one-off", account_id: "a", date_first: "2026-02-10", frequency: "never", amount: -50,
    });

    const result = await repo.materializeScheduledTransactions("p", "2026-03-31", 20, "d1-catch-up");
    expect(result.occurrences.map((row) => `${row.scheduled_transaction.id}:${row.occurrence_date}`)).toEqual([
      "month-end:2026-01-31", "month-end:2026-02-28", "month-end:2026-03-31", "one-off:2026-02-10",
    ]);
    expect(await repo.getScheduledTransaction("p", "month-end")).toMatchObject({ date_next: "2026-04-30" });
    await expect(repo.getScheduledTransaction("p", "one-off")).rejects.toThrow("not found");
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 4 });
  });

  test("daily materialisation derives the Singapore date and handles zero due, due, retry, and closed skips", async () => {
    expect(scheduledLocalDate(Date.UTC(2026, 7, 20, 15, 59), "Asia/Singapore")).toBe("2026-08-20");
    expect(scheduledLocalDate(Date.UTC(2026, 7, 20, 16, 5), "Asia/Singapore")).toBe("2026-08-21");
    expect(scheduledMaterializationOperationId("p", "2026-08-21")).toBe(scheduledMaterializationOperationId("p", "2026-08-21"));

    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    const scheduledTime = Date.UTC(2026, 7, 20, 16, 5);
    expect(await runDailyScheduledMaterialization({ repo, planId: "p", timeZone: "Asia/Singapore", scheduledTime })).toEqual({
      through_date: "2026-08-21", occurrence_count: 0, skipped_closed_schedule_count: 0, failure_count: 0, has_more: false,
    });

    await repo.createScheduledTransaction("p", {
      id: "cron-due", account_id: "a", date_first: "2026-08-21", frequency: "never", amount: -100,
    });
    await repo.upsertAccount("p", { id: "closed", name: "Closed", closed: true });
    await repo.createScheduledTransaction("p", {
      id: "cron-closed", account_id: "closed", date_first: "2026-08-21", frequency: "monthly", amount: -200,
    });
    const first = await runDailyScheduledMaterialization({ repo, planId: "p", timeZone: "Asia/Singapore", scheduledTime });
    expect(first).toEqual({ through_date: "2026-08-21", occurrence_count: 1, skipped_closed_schedule_count: 1, failure_count: 0, has_more: false });
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 1 });

    const retry = await runDailyScheduledMaterialization({ repo, planId: "p", timeZone: "Asia/Singapore", scheduledTime });
    expect(retry).toEqual({ through_date: "2026-08-21", occurrence_count: 0, skipped_closed_schedule_count: 1, failure_count: 0, has_more: false });
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 1 });
  });

  test("daily materialisation propagates failure and reuses its operation seed for recovery", async () => {
    const operationIds: string[] = [];
    let attempt = 0;
    const repo = {
      materializeScheduledTransactionsForCron(_planId: string, throughDate: string, _maximum: number, operationId?: string) {
        operationIds.push(String(operationId));
        attempt += 1;
        if (attempt === 1) throw new Error("partial materialisation failure");
        return {
          through_date: throughDate,
          occurrence_count: 1,
          skipped_closed_schedule_count: 0,
          failure_count: 0,
          has_more: false,
        };
      },
    };
    const options = { repo, planId: "p", timeZone: "Asia/Singapore", scheduledTime: Date.UTC(2026, 7, 20, 16, 5) };
    await expect(runDailyScheduledMaterialization(options)).rejects.toThrow("partial materialisation failure");
    expect(await runDailyScheduledMaterialization(options)).toEqual({
      through_date: "2026-08-21", occurrence_count: 1, skipped_closed_schedule_count: 0, failure_count: 0, has_more: false,
    });
    expect(operationIds).toEqual([operationIds[0], operationIds[0]]);
    expect(operationIds[0]).toBe(scheduledMaterializationOperationId("p", "2026-08-21"));
  });

  test("D1 cron materialisation isolates a transient schedule failure and a same-day retry recovers without duplicates", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.createScheduledTransaction("p", {
      id: "cron-first", account_id: "a", date_first: "2026-08-20", frequency: "daily", amount: -100,
    });
    await repo.createScheduledTransaction("p", {
      id: "cron-second", account_id: "a", date_first: "2026-08-21", frequency: "never", amount: -200,
    });
    const materialize = repo.materializeScheduledOccurrence.bind(repo);
    let failOnce = true;
    repo.materializeScheduledOccurrence = async (...args) => {
      if (args[1] === "cron-second" && failOnce) {
        failOnce = false;
        throw new Error("temporary D1 command failure");
      }
      return materialize(...args);
    };

    const first = await repo.materializeScheduledTransactionsForCron("p", "2026-08-21", 5, "cron-run");
    expect(first).toEqual({
      through_date: "2026-08-21", occurrence_count: 2, skipped_closed_schedule_count: 0, failure_count: 1, has_more: true,
    });
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 2 });

    const retry = await repo.materializeScheduledTransactionsForCron("p", "2026-08-21", 5, "cron-run");
    expect(retry).toEqual({
      through_date: "2026-08-21", occurrence_count: 1, skipped_closed_schedule_count: 0, failure_count: 0, has_more: false,
    });
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 3 });
    expect(await repo.materializeScheduledTransactionsForCron("p", "2026-08-21", 5, "cron-run")).toMatchObject({
      occurrence_count: 0, failure_count: 0, has_more: false,
    });
  });

  test("D1 cron materialisation continues past an invalid schedule and reports only counts", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.upsertPayee("p", { id: "bad-payee", name: "Will be deleted" });
    await repo.createScheduledTransaction("p", {
      id: "bad-schedule", account_id: "a", payee_id: "bad-payee", date_first: "2026-08-21", frequency: "never", amount: -100,
    });
    await repo.createScheduledTransaction("p", {
      id: "valid-schedule", account_id: "a", date_first: "2026-08-21", frequency: "never", amount: -200,
    });
    db.run("UPDATE payees SET deleted=1 WHERE plan_id='p' AND id='bad-payee'");

    expect(await repo.materializeScheduledTransactionsForCron("p", "2026-08-21", 5, "cron-invalid")).toEqual({
      through_date: "2026-08-21", occurrence_count: 1, skipped_closed_schedule_count: 0, failure_count: 1, has_more: true,
    });
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 1 });
  });

  test("D1 cron materialisation is fair across a backlog, caps each run, and resumes deterministically", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    for (const id of ["cron-a", "cron-b"]) {
      await repo.createScheduledTransaction("p", {
        id, account_id: "a", date_first: "2026-08-01", frequency: "daily", amount: -100,
      });
    }

    const first = await repo.materializeScheduledTransactionsForCron("p", "2026-08-03", 3, "cron-fair");
    expect(first).toEqual({
      through_date: "2026-08-03", occurrence_count: 3, skipped_closed_schedule_count: 0, failure_count: 0, has_more: true,
    });
    expect(await repo.getScheduledTransaction("p", "cron-a")).toMatchObject({ date_next: "2026-08-03" });
    expect(await repo.getScheduledTransaction("p", "cron-b")).toMatchObject({ date_next: "2026-08-02" });

    const retry = await repo.materializeScheduledTransactionsForCron("p", "2026-08-03", 3, "cron-fair");
    expect(retry).toEqual({
      through_date: "2026-08-03", occurrence_count: 3, skipped_closed_schedule_count: 0, failure_count: 0, has_more: false,
    });
    expect(db.query("SELECT COUNT(*) count FROM transactions WHERE source_kind='scheduled-transaction'").get()).toEqual({ count: 6 });
  });

  test("D1 schedule patches retry a stale snapshot without losing an unrelated patch", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    const source = {
      id: "race-schedule", account_id: "a", account_name: "Cash", date_first: "2026-08-01",
      date_next: "2026-09-01", frequency: "monthly", amount: -1000, memo: "before", deleted: false,
    };
    await repo.upsertYnabRawObject("p", "scheduled_transaction", source.id, source);

    await Promise.all([
      repo.updateScheduledTransaction("p", source.id, { memo: "memo changed" }, { operationId: "schedule-race-memo" }),
      repo.updateScheduledTransaction("p", source.id, { amount: -2000 }, { operationId: "schedule-race-amount" }),
    ]);

    expect(await repo.getScheduledTransaction("p", source.id)).toMatchObject({
      memo: "memo changed", amount: -2000, date_next: "2026-09-01",
    });
    expect(db.query("SELECT COUNT(*) AS count FROM scheduled_transaction_snapshot_assertions WHERE scheduled_transaction_id=?").get(source.id)).toEqual({ count: 2 });
  });

  test("D1 schedule patches preserve concurrent split allocation changes", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.upsertCategoryGroup("p", { id: "living", name: "Living" });
    await repo.upsertCategory("p", { id: "food", category_group_id: "living", name: "Food" });
    const source = {
      id: "race-split-schedule", account_id: "a", account_name: "Cash", date_first: "2026-08-01",
      date_next: "2026-09-01", frequency: "monthly", amount: -3000, memo: "before", deleted: false,
    };
    const sourceSubtransactions = [
      { id: "race-split-one", scheduled_transaction_id: source.id, amount: -1000, category_id: "food", memo: "one" },
      { id: "race-split-two", scheduled_transaction_id: source.id, amount: -2000, category_id: "food", memo: "two" },
    ];
    await repo.upsertYnabRawObject("p", "scheduled_transaction", source.id, source);
    for (const subtransaction of sourceSubtransactions) {
      await repo.upsertYnabRawObject("p", "scheduled_subtransaction", `${source.id}\u001f${subtransaction.id}`, subtransaction);
    }

    await Promise.all([
      repo.updateScheduledTransaction("p", source.id, { subtransactions: [
        { ...sourceSubtransactions[0], amount: -1500 },
        { ...sourceSubtransactions[1], amount: -1500 },
      ] }, { operationId: "schedule-race-splits" }),
      repo.updateScheduledTransaction("p", source.id, { memo: "parent changed" }, { operationId: "schedule-race-parent" }),
    ]);

    expect(await repo.getScheduledTransaction("p", source.id)).toMatchObject({
      memo: "parent changed",
      subtransactions: [
        expect.objectContaining({ id: "race-split-one", amount: -1500 }),
        expect.objectContaining({ id: "race-split-two", amount: -1500 }),
      ],
    });
  });

  test("D1 transaction pages keep split-line lookups below the binding limit", async () => {
    const db = await ledgerSqlite();
    for (let index = 0; index < 101; index += 1) {
      db.run(
        "INSERT INTO transactions(id,plan_id,account_id,date,amount_milli) VALUES(?,?,?,?,?)",
        [`page-${String(index).padStart(3, "0")}`, "p", "a", "2026-08-20", -index],
      );
    }

    const repo = new D1LedgerRepository(new D1Database(fakeD1(db, { maxBindings: 100 })), "p");
    const page = await repo.listTransactionsPage("p");

    expect(page.transactions).toHaveLength(100);
    expect(page.has_more).toBeTrue();
    expect(page.next_offset).toBe(100);
  });

  test("D1 assignment writes are guarded, retain raw source rows, and carry availability forward", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p", {
      operationId: (kind, _planId, resourceId) => `assignment-${kind}-${resourceId.replaceAll("\u001f", "-")}`,
    });
    await repo.upsertCategoryGroup("p", { id: "food", name: "Food" });
    await repo.upsertCategory("p", { id: "groceries", category_group_id: "food", name: "Groceries" });
    for (const month of ["2026-06-01", "2026-07-01"]) {
      await repo.upsertYnabRawObject("p", "month", month, { month, budgeted: 5000, to_be_budgeted: 4000, activity: 0 });
      await repo.upsertYnabRawObject("p", "month_category", `${month}\u001fgroceries`, {
        id: "groceries", category_group_id: "food", name: "Groceries", budgeted: 5000, activity: 0, balance: 5000, deleted: false,
      });
    }
    const rawBefore = db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='month_category' AND object_id='2026-06-01\u001fgroceries'").get();
    const versionBefore = db.query("SELECT write_version FROM write_state").get() as { write_version: number };

    const june = await repo.setMonthCategoryAssignment("p", "2026-06", "groceries", 7000);
    expect(june).toMatchObject({ budgeted: 7000, to_be_budgeted: 2000 });
    expect(june.categories).toEqual([expect.objectContaining({ id: "groceries", budgeted: 7000, balance: 7000 })]);
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='month_category' AND object_id='2026-06-01\u001fgroceries'").get()).toEqual(rawBefore);
    expect(db.query("SELECT budgeted_milli FROM plan_month_assignments WHERE plan_id='p' AND month='2026-06-01' AND category_id='groceries'").get()).toEqual({ budgeted_milli: 7000 });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: versionBefore.write_version + 1 });
    expect(db.query("SELECT status FROM write_commands WHERE kind='plan.assignment.set'").get()).toEqual({ status: "applied" });

    const july = await repo.getMonth("p", "2026-07");
    expect(july).toMatchObject({ budgeted: 5000, to_be_budgeted: 4000 });
    expect(july.categories).toEqual([expect.objectContaining({ id: "groceries", budgeted: 5000, balance: 7000 })]);
    await expect(repo.setMonthCategoryAssignment("p", "2026-08", "groceries", 8000)).rejects.toThrow("Imported month not found");
    await expect(repo.setMonthCategoryAssignment("p", "2026-06", "missing", 8000)).rejects.toThrow("Imported month category not found");
  });

  test("D1 category resolution avoids a fallback group for existing categories", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    db.exec("INSERT INTO category_groups(id,plan_id,name) VALUES ('source-group','p','Source group'); INSERT INTO categories(id,plan_id,category_group_id,name) VALUES ('source-category','p','source-group','Source category')");

    await repo.ensureCategory("p", "source-category");
    expect(db.query("SELECT id FROM category_groups WHERE plan_id='p' ORDER BY id").all()).toEqual([{ id: "source-group" }]);

    await repo.ensureCategory("p", "missing-category", "Missing category");
    expect(db.query("SELECT id FROM category_groups WHERE plan_id='p' ORDER BY id").all()).toEqual([
      { id: "source-group" },
      { id: "uncategorized-group" },
    ]);
    expect(db.query("SELECT category_group_id FROM categories WHERE id='missing-category'").get()).toEqual({ category_group_id: "uncategorized-group" });
  });

  test("D1 preserves duplicate YNAB payee names as ID-distinct transaction references", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");

    await repo.upsertPayee("p", { id: "ynab-payee-a", name: "Same merchant", external_ynab_id: "ynab-payee-a" });
    await repo.upsertPayee("p", { id: "ynab-payee-b", name: "Same merchant", external_ynab_id: "ynab-payee-b" });
    await repo.createTransaction("p", { id: "ynab-txn-a", account_id: "a", date: "2026-08-01", amount: -1000, payee_id: "ynab-payee-a" }, { autoLink: false });
    await repo.createTransaction("p", { id: "ynab-txn-b", account_id: "a", date: "2026-08-02", amount: -2000, payee_id: "ynab-payee-b" }, { autoLink: false });

    expect(db.query("SELECT id,name,external_ynab_id FROM payees WHERE id LIKE 'ynab-payee-%' ORDER BY id").all()).toEqual([
      { id: "ynab-payee-a", name: "Same merchant", external_ynab_id: "ynab-payee-a" },
      { id: "ynab-payee-b", name: "Same merchant", external_ynab_id: "ynab-payee-b" },
    ]);
    expect(db.query("SELECT id,payee_id,payee_name_snapshot FROM transactions WHERE id LIKE 'ynab-txn-%' ORDER BY id").all()).toEqual([
      { id: "ynab-txn-a", payee_id: "ynab-payee-a", payee_name_snapshot: "Same merchant" },
      { id: "ynab-txn-b", payee_id: "ynab-payee-b", payee_name_snapshot: "Same merchant" },
    ]);
    expect(db.query("PRAGMA foreign_key_check").all()).toEqual([]);
  });

  test("D1 assignment writes are guarded, replayable, and preserve the YNAB source rows", async () => {
    const db = await ledgerSqlite();
    db.exec("INSERT INTO category_groups(id,plan_id,name) VALUES('food-group','p','Food'); INSERT INTO categories(id,plan_id,category_group_id,name) VALUES('food','p','food-group','Groceries')");
    const sourceMonth = { month: "2026-06-01", budgeted: 5000, to_be_budgeted: 4000, activity: 0 };
    const sourceCategory = { id: "food", category_group_id: "food-group", name: "Groceries", budgeted: 5000, activity: 0, balance: 5000, deleted: false };
    db.run("INSERT INTO ynab_raw_objects(plan_id,object_type,object_id,payload_json) VALUES('p','month','2026-06-01',?),('p','month_category','2026-06-01\u001ffood',?)", [JSON.stringify(sourceMonth), JSON.stringify(sourceCategory)]);
    const rawBefore = db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='month_category'").get();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p", {
      operationId: (kind) => kind === "plan.assignment.set" ? "assignment-once" : `op-${kind}`,
    });

    const first = await repo.setMonthCategoryAssignment("p", "2026-06", "food", 7000);
    const second = await repo.setMonthCategoryAssignment("p", "2026-06", "food", 7000);
    expect(first).toMatchObject({ budgeted: 7000, to_be_budgeted: 2000, categories: [expect.objectContaining({ id: "food", budgeted: 7000, balance: 7000, source_budgeted: 5000 })] });
    expect(second).toEqual(first);
    expect(db.query("SELECT budgeted_milli,source FROM plan_month_assignments").get()).toEqual({ budgeted_milli: 7000, source: "howmuch-local" });
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='month_category'").get()).toEqual(rawBefore);
    expect(db.query("SELECT COUNT(*) AS count FROM audit_events WHERE action='plan_assignment.set'").get()).toEqual({ count: 1 });
    expect(db.query("SELECT COUNT(*) AS count FROM write_commands WHERE kind='plan.assignment.set' AND status='applied'").get()).toEqual({ count: 1 });
  });

  test("D1 target writes are guarded, replayable, and preserve the YNAB source rows", async () => {
    const db = await ledgerSqlite();
    db.exec("INSERT INTO category_groups(id,plan_id,name) VALUES('food-group','p','Food'); INSERT INTO categories(id,plan_id,category_group_id,name) VALUES('food','p','food-group','Groceries')");
    const sourceMonth = { month: "2026-06-01", budgeted: 0, to_be_budgeted: 0, activity: 0 };
    const sourceCategory = { id: "food", category_group_id: "food-group", name: "Groceries", budgeted: 0, activity: 0, balance: 5000, goal_type: "NEED", goal_target: 9000, deleted: false };
    db.run("INSERT INTO ynab_raw_objects(plan_id,object_type,object_id,payload_json) VALUES('p','month','2026-06-01',?),('p','month_category','2026-06-01\u001ffood',?)", [JSON.stringify(sourceMonth), JSON.stringify(sourceCategory)]);
    const rawBefore = db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='month_category'").get();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p", { operationId: (kind) => kind === "plan.target.set" ? "target-once" : `op-${kind}` });

    const target = { goal_type: "TB" as const, goal_target: 7000, goal_target_month: "2026-12" };
    const first = await repo.setMonthCategoryTarget("p", "2026-06", "food", target);
    const second = await repo.setMonthCategoryTarget("p", "2026-06", "food", target);
    expect(first.categories).toEqual([expect.objectContaining({ id: "food", goal_type: "TB", goal_target: 7000, goal_target_month: "2026-12-01", target_source: "howmuch-local" })]);
    expect(second).toEqual(first);
    expect(db.query("SELECT goal_type,goal_target_milli FROM plan_month_category_targets").get()).toEqual({ goal_type: "TB", goal_target_milli: 7000 });
    expect(db.query("SELECT payload_json FROM ynab_raw_objects WHERE object_type='month_category'").get()).toEqual(rawBefore);
    expect(db.query("SELECT COUNT(*) AS count FROM write_commands WHERE kind='plan.target.set' AND status='applied'").get()).toEqual({ count: 1 });
  });

  test("D1 imports reciprocal transfer payees before their accounts", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const pathname = new URL(String(input)).pathname;
      if (pathname === "/v1/plans/p") {
        return new Response(JSON.stringify({ data: { server_knowledge: 9, plan: {
          id: "p", name: "Plan", accounts: [{ id: "ynab-account", name: "Savings", type: "savings", on_budget: true, transfer_payee_id: "ynab-transfer" }],
          category_groups: [], categories: [], payees: [{ id: "ynab-transfer", name: "Transfer : Savings", transfer_account_id: "ynab-account", deleted: false }],
          months: [], transactions: [], scheduled_transactions: [], scheduled_subtransactions: [], payee_locations: [],
        } } }), { headers: { "content-type": "application/json" } });
      }
      if (pathname === "/v1/plans/p/settings") return new Response(JSON.stringify({ data: { settings: {} } }), { headers: { "content-type": "application/json" } });
      return new Response("not found", { status: 404 });
    }) as typeof fetch;

    await importYnabFromApi(repo, { token: "ynab-token", planId: "p" });

    expect(db.query("SELECT transfer_payee_id FROM accounts WHERE id='ynab-account'").get()).toEqual({ transfer_payee_id: "ynab-transfer" });
    expect(db.query("SELECT name,transfer_account_id FROM payees WHERE id='ynab-transfer'").get()).toEqual({ name: "Transfer : Savings", transfer_account_id: "ynab-account" });
    expect(db.query("PRAGMA foreign_key_check").all()).toEqual([]);
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
    const db = await ledgerSqlite();
    db.run("INSERT INTO transactions (id, ledger_sequence, plan_id, account_id, date, amount_milli, payee_name_snapshot) VALUES ('t', 1, 'p', 'a', '2026-01-02', -1200, 'Shop')");
    const expected = new ReportService(db);
    const actual = new D1ReportService(fakeD1(db));
    expect(await actual.spendingBreakdown("p")).toEqual(expected.spendingBreakdown("p"));
    expect(await actual.incomeVsSpending("p")).toEqual(expected.incomeVsSpending("p"));
    expect(await actual.incomeVsSpending("p", { interval: "week" })).toEqual(expected.incomeVsSpending("p", { interval: "week" }));
    expect(await actual.netWorth("p", { from: "2026-01-01", to: "2026-01-31" })).toEqual(expected.netWorth("p", { from: "2026-01-01", to: "2026-01-31" }));
    expect(await actual.ageOfMoney("p", { from: "2026-01-01", to: "2026-01-31" })).toEqual(expected.ageOfMoney("p", { from: "2026-01-01", to: "2026-01-31" }));
  });

  test("D1 per-account config exchange preserves destination identity and sibling configuration", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO accounts(id,plan_id,name) VALUES('b','p','Sibling')");
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    const sibling = { id: "sibling", ynabAccountId: "b", name: "Sibling", issuer: "Other", type: "cashback", earningRate: 2 };
    await repo.upsertRewardsTrackerCard("p", sibling);
    const [card, replay] = await Promise.all([
      importRewardsAccountConfig(repo, "p", "a", rewardsAccountConfig),
      importRewardsAccountConfig(repo, "p", "a", rewardsAccountConfig),
    ]);
    expect(replay.id).toBe(card.id);
    expect(await exportRewardsAccountConfig(repo, "p", "a")).toEqual({ ...rewardsAccountConfig, card: { ...rewardsAccountConfig.card, name: "Cash" } });
    const stored = await repo.getRewardsTrackerSnapshot("p");
    expect(stored.cards).toHaveLength(2);
    expect(stored.cards.find((entry: any) => entry.id === "sibling")).toEqual(sibling);
    expect(db.query("SELECT COUNT(*) AS n FROM transactions").get()).toEqual({ n: 0 });
  });

  test("D1 and SQLite rewards retain history before a cut-in range and reset monthly caps", async () => {
    const db = await ledgerSqlite();
    const card = { id: "card", name: "Card", issuer: "Bank", type: "miles", ynabAccountId: "a", featured: false, earningRate: 2, maximumSpend: 100 };
    db.run("INSERT INTO rewards_tracker_cards(plan_id,id,account_id,name,issuer,type,payload_json) VALUES('p','card','a','Card','Bank','miles',?)", JSON.stringify(card));
    db.run("INSERT INTO transactions(id,plan_id,account_id,date,amount_milli) VALUES('early','p','a','2026-04-03',-80000),('late','p','a','2026-04-20',-60000),('may','p','a','2026-05-02',-130000),('excluded','p','a','2026-06-01',-999000)");
    const filters = { from: "2026-04-15", to: "2026-05-31" };
    const local = new ReportService(db).rewards("p", filters);
    const remote = await new D1ReportService(fakeD1(db)).rewards("p", filters);
    expect(remote).toEqual(local);
    expect(local.totals).toEqual({ spend: 190, miles: 240, cashback: 0, reward_dollars: 2.4 });
    expect(local.transaction_rewards).toEqual({ late: { reward: 40, reward_dollars: 0.4 }, may: { reward: 200, reward_dollars: 2 } });
    expect(local.cards[0]!.calculation.counted_spend).toBe(120);
  });

  test("D1 net-worth reports stay below the binding cap across long daily ranges", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO transactions(id,plan_id,account_id,date,amount_milli) VALUES('long-range-row','p','a','2026-01-02',100)");
    const reports = new D1ReportService(fakeD1(db, { maxBindings: 100 }));
    const result = await reports.netWorth("p", { from: "2026-01-01", to: "2026-04-30", interval: "day" });
    expect(result.periods).toHaveLength(120);
    expect(result.periods.at(-1).net_worth).toBe(100);
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

  test("D1 scheduled runner uses and advances the cursor, preserves it on failure, and deduplicates replays", async () => {
    const db = await ledgerSqlite();
    const d1 = new D1Database(fakeD1(db));
    let clock = 0;
    let failWithPrivateBody = false;
    const fetchedUrls: string[] = [];
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input);
      fetchedUrls.push(url);
      if (failWithPrivateBody && url.includes("/plans/p")) {
        return new Response("private YNAB response detail", { status: 500 });
      }
      const serverKnowledge = url.includes("last_knowledge_of_server=9") ? 12 : 9;
      if (url === "https://api.ynab.com/v1/plans/p" || url === "https://api.ynab.com/v1/plans/p?last_knowledge_of_server=9") {
        return new Response(JSON.stringify({ data: { plan: {
          id: "p", name: "Plan", accounts: [{ id: "a", name: "Cash" }], category_groups: [], categories: [], payees: [],
          months: [], transactions: [{ id: "ynab-1", account_id: "a", date: "2026-01-01", amount: -10, deleted: false, subtransactions: [] }],
          scheduled_transactions: [], scheduled_subtransactions: [], payee_locations: [],
        }, server_knowledge: serverKnowledge } }), { headers: { "content-type": "application/json" } });
      }
      if (url.endsWith("/plans/p/settings")) {
        return new Response(JSON.stringify({ data: { settings: {} } }), { headers: { "content-type": "application/json" } });
      }
      return new Response("not found", { status: 404 });
    }) as typeof fetch;
    const config = {
      dbPath: "", port: 0, defaultPlanId: "p", transitionReadOnly: true,
      ynabToken: "token", ynabPlanId: "p", ynabMinSimilarity: 0.95,
    };
    const logs: string[] = [];
    const errors: string[] = [];
    const logger = { log: (message: string) => logs.push(message), warn() {}, error: (message: string) => errors.push(message) };

    const first = await runD1ScheduledYnabSync({
      db: d1, config, scheduledTime: Date.UTC(2026, 0, 1), now: () => clock += 360_001, logger,
    });
    expect(first.status).toBe("completed");
    expect(db.query("SELECT status FROM sync_runs").get()).toEqual({ status: "completed" });
    expect(db.query("SELECT COUNT(*) count FROM sync_renewal_receipts").get()).toEqual({ count: 1 });
    expect(db.query("SELECT id FROM transactions WHERE id='ynab-1'").get()).toEqual({ id: "ynab-1" });
    expect(db.query("SELECT server_knowledge FROM ynab_sync_state WHERE plan_id='p'").get()).toEqual({ server_knowledge: 9 });
    expect(logs).toEqual([]);

    const fetchesAfterFirst = fetchedUrls.length;
    const duplicate = await runD1ScheduledYnabSync({ db: d1, config, scheduledTime: Date.UTC(2026, 0, 1), logger });
    expect(duplicate.status).toBe("duplicate");
    expect(fetchedUrls).toHaveLength(fetchesAfterFirst);

    const delta = await runD1ScheduledYnabSync({ db: d1, config, scheduledTime: Date.UTC(2026, 0, 2), logger });
    expect(delta).toMatchObject({ status: "completed", result: { server_knowledge: 12 } });
    expect(fetchedUrls).toContain("https://api.ynab.com/v1/plans/p?last_knowledge_of_server=9");
    expect(db.query("SELECT server_knowledge FROM ynab_sync_state WHERE plan_id='p'").get()).toEqual({ server_knowledge: 12 });

    failWithPrivateBody = true;
    const failedScheduledTime = Date.UTC(2026, 0, 3);
    await expect(runD1ScheduledYnabSync({ db: d1, config, scheduledTime: failedScheduledTime, logger }))
      .rejects.toThrow("YNAB scheduled sync failed");
    expect(db.query("SELECT server_knowledge FROM ynab_sync_state WHERE plan_id='p'").get()).toEqual({ server_knowledge: 12 });
    expect(errors).toEqual([JSON.stringify({ event: "ynab_delta_sync", status: "failed" })]);
    expect(JSON.stringify(errors)).not.toContain("private YNAB response detail");
    expect(db.query("SELECT error FROM sync_runs WHERE scheduled_for=?").get(new Date(failedScheduledTime).toISOString()))
      .toEqual({ error: "YNAB scheduled sync failed" });
    expect(db.query("SELECT summary_json FROM import_sessions WHERE status='failed' ORDER BY started_at DESC LIMIT 1").get())
      .toEqual({ summary_json: JSON.stringify({ error: "YNAB fetch failed for /plans/p?last_knowledge_of_server=12: 500" }) });

    const fetchesAfterFailure = fetchedUrls.length;
    const replayedFailure = await runD1ScheduledYnabSync({ db: d1, config, scheduledTime: failedScheduledTime, logger });
    expect(replayedFailure.status).toBe("duplicate");
    expect(fetchedUrls).toHaveLength(fetchesAfterFailure);
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

  test("D1 cleared-only updates are guarded and preserve transfer mirror states", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('b', 'p', 'Savings')");
    db.run("INSERT INTO payees (id, plan_id, name, transfer_account_id) VALUES ('to-a','p','Transfer to Cash','a'),('to-b','p','Transfer to Savings','b')");
    db.run("UPDATE accounts SET transfer_payee_id=CASE id WHEN 'a' THEN 'to-a' ELSE 'to-b' END WHERE id IN ('a','b')");
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));

    const transfer = await writer.create("p", {
      id: "clear-transfer", account_id: "a", date: "2026-07-01", amount: -100, payee_id: "to-b",
    }, { operationId: "clear-transfer-create" });
    await writer.updateCleared("p", transfer.id, "uncleared", "cleared", { operationId: "clear-transfer-source" });
    expect(db.query("SELECT id,cleared FROM transactions WHERE id IN (?,?) ORDER BY id").all(transfer.id, transfer.transfer_transaction_id)).toEqual([
      { id: transfer.id, cleared: "cleared" },
      { id: transfer.transfer_transaction_id, cleared: "uncleared" },
    ].sort((left, right) => left.id.localeCompare(right.id)));
    expect(db.query("SELECT id,cleared_balance_milli,uncleared_balance_milli FROM accounts ORDER BY id").all()).toEqual([
      { id: "a", cleared_balance_milli: -100, uncleared_balance_milli: 0 },
      { id: "b", cleared_balance_milli: 0, uncleared_balance_milli: 100 },
    ]);
    await writer.update("p", transfer.id, { memo: "cosmetic" }, { operationId: "clear-transfer-memo" });
    expect(db.query("SELECT id,cleared FROM transactions WHERE id IN (?,?) ORDER BY id").all(transfer.id, transfer.transfer_transaction_id)).toEqual([
      { id: transfer.id, cleared: "cleared" },
      { id: transfer.transfer_transaction_id, cleared: "uncleared" },
    ].sort((left, right) => left.id.localeCompare(right.id)));
    await expect(writer.updateCleared("p", transfer.id, "uncleared", "cleared", { operationId: "clear-transfer-stale" })).rejects.toThrow("cleared state conflict");

    await writer.create("p", {
      id: "clear-split", account_id: "a", date: "2026-07-02", amount: -30,
      subtransactions: [{ id: "clear-line", amount: -10, payee_id: "to-b" }, { id: "plain-line", amount: -20 }],
    }, { operationId: "clear-split-create" });
    const splitMirror = (db.query("SELECT transfer_transaction_id FROM subtransactions WHERE id='clear-line'").get() as any).transfer_transaction_id;
    await writer.updateCleared("p", splitMirror, "uncleared", "cleared", { operationId: "clear-split-mirror" });
    expect(db.query("SELECT cleared FROM transactions WHERE id=?").get(splitMirror)).toEqual({ cleared: "cleared" });
    await writer.update("p", "clear-split", { memo: "cosmetic" }, { operationId: "clear-split-memo" });
    expect(db.query("SELECT cleared FROM transactions WHERE id=?").get(splitMirror)).toEqual({ cleared: "cleared" });

    await writer.create("p", { id: "locked", account_id: "a", date: "2026-07-03", amount: 1, cleared: "reconciled" }, { operationId: "locked-create" });
    await expect(writer.updateCleared("p", "locked", "cleared", "uncleared", { operationId: "locked-stale" })).rejects.toThrow("cleared state conflict");
    await expect(writer.update("p", "locked", { cleared: "uncleared" }, { operationId: "locked-generic" })).rejects.toThrow("reconciled transaction state conflict");
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
    await writer.approve("p", splitMirror, true, { operationId: "split-mirror-approve" });
    expect(db.query("SELECT id,approved FROM transactions WHERE id IN ('split-update',?) ORDER BY id").all(splitMirror)).toEqual([
      { id: "split-update", approved: 1 },
      { id: splitMirror, approved: 1 },
    ]);
    await expect(writer.delete("p", "split-update", { operationId: "stale-split-reject" }, false)).rejects.toThrow("approved state conflict");
    expect(db.query("SELECT deleted FROM transactions WHERE id = 'split-update'").get()).toEqual({ deleted: 0 });
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

  test("D1 rejects a new linked split-transfer side and unlinks the split line", async () => {
    const db = await ledgerSqlite();
    db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('b', 'p', 'Savings')");
    db.run("INSERT INTO payees (id, plan_id, name, transfer_account_id) VALUES ('to-a','p','Transfer to Cash','a'),('to-b','p','Transfer to Savings','b')");
    db.run("UPDATE accounts SET transfer_payee_id=CASE id WHEN 'a' THEN 'to-a' ELSE 'to-b' END WHERE id IN ('a','b')");
    const d1 = new D1Database(fakeD1(db));
    const repo = new D1LedgerRepository(d1, "p");
    const created = await repo.createTransaction("p", {
      account_id: "a",
      date: "2026-07-02",
      amount: -30,
      approved: false,
      subtransactions: [
        { id: "line-transfer", amount: -10, payee_id: "to-b" },
        { id: "line-plain", amount: -20 },
      ],
    });
    const mirrorId = created.subtransactions.find((sub: { transfer_transaction_id?: string }) => sub.transfer_transaction_id)?.transfer_transaction_id;
    expect(mirrorId).toBeString();
    const rejected = await repo.deleteTransaction("p", mirrorId, false);
    expect(rejected).toMatchObject({ id: mirrorId, deleted: true, approved: false });
    expect(db.query("SELECT deleted FROM transactions WHERE id=?").get(mirrorId)).toEqual({ deleted: 1 });
    expect(db.query("SELECT transfer_account_id, transfer_transaction_id, deleted FROM subtransactions WHERE id='line-transfer'").get()).toEqual({
      transfer_account_id: null,
      transfer_transaction_id: null,
      deleted: 0,
    });
    expect(db.query("SELECT deleted FROM transactions WHERE id=?").get(created.id)).toEqual({ deleted: 0 });
    expect(db.query("SELECT balance_milli FROM accounts WHERE id='b'").get()).toEqual({ balance_milli: 0 });
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

    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    const deleted = await repo.createTransaction("p", { id:"deleted-import",account_id:"a",date:"2026-07-02",amount:0,deleted:true }, { autoLink:false });
    expect(deleted.deleted).toBe(true);
  });

  test("D1 account type updates derive on_budget and follow the default icon", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    const followed = await repo.updateAccount("p", "a", { kind: "savings" });
    expect(followed).toMatchObject({ type: "savings", on_budget: true, icon: "💰", balance: 0 });
    expect(db.query("SELECT type, on_budget, icon, balance_milli FROM accounts WHERE id='a'").get()).toEqual({
      type: "savings",
      on_budget: 1,
      icon: "💰",
      balance_milli: 0,
    });

    await repo.upsertAccount("p", { id: "b", name: "Piggy", type: "checking", icon: "🐷", on_budget: true });
    await repo.updateAccount("p", "b", { kind: "mortgage" });
    expect(db.query("SELECT type, on_budget, icon FROM accounts WHERE id='b'").get()).toEqual({
      type: "mortgage",
      on_budget: 0,
      icon: "🐷",
    });
  });

  test("D1 split IDs cannot be stolen by another parent in the same plan", async () => {
    const db=await ledgerSqlite(); const writer=new D1TransactionRepository(new D1Database(fakeD1(db)));
    await writer.create("p",{id:"first",account_id:"a",date:"2026-01-01",amount:2,subtransactions:[{id:"shared",amount:1},{id:"first-other",amount:1}]},{operationId:"first"});
    await expect(writer.create("p",{id:"second",account_id:"a",date:"2026-01-02",amount:2,subtransactions:[{id:"shared",amount:1},{id:"second-other",amount:1}]},{operationId:"second"})).rejects.toThrow("write precondition failed");
    expect(db.query("SELECT transaction_id FROM subtransactions WHERE id='shared'").get()).toEqual({transaction_id:"first"});
  });

  test("versioned D1 metadata and import-session writes replay and reject collisions", async () => {
    const db = sqlite();
    for (const path of ["../d1-migrations/0001_initial.sql", "../d1-migrations/0002_password_auth.sql", "../d1-migrations/0003_allow_duplicate_payee_names.sql", "../d1-migrations/0004_ynab_raw_objects.sql", "../d1-migrations/0005_plan_month_assignments.sql", "../d1-migrations/0006_plan_month_category_targets.sql", "../d1-migrations/0007_scheduled_transaction_edits.sql", "../d1-migrations/0008_scheduled_transaction_snapshot_assertions.sql", "../d1-migrations/0009_account_reconciliation_assertions.sql", "../d1-migrations/0010_unique_live_import_id.sql", "../d1-migrations/0011_personal_api_tokens.sql", "../d1-migrations/0012_account_preferences.sql", "../d1-migrations/0013_account_icons.sql", "../d1-migrations/0014_account_icon_emoji_backfill.sql"]) {
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
    await metadata.upsertAccount("p", { id: "a", name: "💳 OCBC", type: "checking", balance: 100 }, { operationId: "account-a-rename" });
    expect(db.query("SELECT name, icon FROM accounts WHERE id = 'a'").get()).toEqual({ name: "OCBC", icon: "💳" });
    expect(db.query("SELECT name FROM payees WHERE id = ?").get(account.transfer_payee_id)).toEqual({ name: "Transfer : OCBC" });
    await metadata.updateAccount("p", "a", { name: "Daily", icon: "🐷" }, { operationId: "account-identity" });
    expect(db.query("SELECT name, icon FROM accounts WHERE id = 'a'").get()).toEqual({ name: "Daily", icon: "🐷" });
    expect(db.query("SELECT name FROM payees WHERE id = ?").get(account.transfer_payee_id)).toEqual({ name: "Transfer : Daily" });
    // Clients revalidate cached accounts and payees against `server_knowledge`
    // (#175), so an import touching only those has to move it.
    const knowledgeBeforePayee = (db.query("SELECT server_knowledge FROM plans WHERE id='p'").get() as { server_knowledge: number }).server_knowledge;
    await metadata.upsertPayee("p", { id: "payee-import", name: "Imported Shop" }, { operationId: "payee-import" });
    expect((db.query("SELECT server_knowledge FROM plans WHERE id='p'").get() as { server_knowledge: number }).server_knowledge).toBeGreaterThan(knowledgeBeforePayee);
    const knowledgeBeforeAccountUpsert = (db.query("SELECT server_knowledge FROM plans WHERE id='p'").get() as { server_knowledge: number }).server_knowledge;
    await metadata.upsertAccount("p", { id: "a", name: "Daily", type: "checking", balance: 100 }, { operationId: "account-a-reimport" });
    expect((db.query("SELECT server_knowledge FROM plans WHERE id='p'").get() as { server_knowledge: number }).server_knowledge).toBeGreaterThan(knowledgeBeforeAccountUpsert);
    await metadata.upsertYnabRawObject("p", "month", "2026-06-01", { month: "2026-06-01", budgeted: 42, deleted: false }, 9, { operationId: "raw-month" });
    await metadata.upsertYnabRawObject("p", "month", "2026-06-01", { month: "2026-06-01", budgeted: 43, deleted: true }, 10, { operationId: "raw-month-update" });
    expect(db.query("SELECT payload_json,deleted,server_knowledge FROM ynab_raw_objects").get()).toEqual({ payload_json: '{"month":"2026-06-01","budgeted":43,"deleted":true}', deleted: 1, server_knowledge: 10 });
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
    expect(db.query("SELECT plan_id, name FROM accounts WHERE id = 'a'").get()).toEqual({ plan_id: "p", name: "Daily" });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: version });
  });

  test("account icon backfill lifts VS16 leftover names that 0013 skipped", async () => {
    const db = sqlite();
    for (const path of ["../d1-migrations/0001_initial.sql", "../d1-migrations/0002_password_auth.sql", "../d1-migrations/0003_allow_duplicate_payee_names.sql", "../d1-migrations/0004_ynab_raw_objects.sql", "../d1-migrations/0005_plan_month_assignments.sql", "../d1-migrations/0006_plan_month_category_targets.sql", "../d1-migrations/0007_scheduled_transaction_edits.sql", "../d1-migrations/0008_scheduled_transaction_snapshot_assertions.sql", "../d1-migrations/0009_account_reconciliation_assertions.sql", "../d1-migrations/0010_unique_live_import_id.sql", "../d1-migrations/0011_personal_api_tokens.sql", "../d1-migrations/0012_account_preferences.sql", "../d1-migrations/0013_account_icons.sql"]) {
      db.exec(await Bun.file(new URL(path, import.meta.url)).text());
    }
    const leftover = "\u{1F44D}\u{FE0F} Banana ";
    const thumbs = "\u{1F44D}\u{FE0F}";
    const darkThumbs = "\u{1F44D}\u{1F3FF}";
    db.run("INSERT INTO plans(id,name,server_knowledge) VALUES ('p','Plan',4)");
    db.run("INSERT INTO accounts(id,plan_id,name,type,icon) VALUES ('thumbs','p',?,'checking','🏦')", leftover);
    db.run("INSERT INTO accounts(id,plan_id,name,type,icon) VALUES ('tone','p',?,'savings','💰')", `${darkThumbs} Savings`);
    db.run("INSERT INTO payees(id,plan_id,name,transfer_account_id) VALUES ('payee-thumbs','p',?,'thumbs')", `Transfer : ${leftover}`);
    expect(db.query("SELECT name,icon FROM accounts WHERE id='thumbs'").get()).toEqual({
      name: leftover,
      icon: "🏦",
    });

    db.exec(await Bun.file(new URL("../d1-migrations/0014_account_icon_emoji_backfill.sql", import.meta.url)).text());

    expect(db.query("SELECT name,icon FROM accounts WHERE id='thumbs'").get()).toEqual({
      name: "Banana",
      icon: thumbs,
    });
    expect(db.query("SELECT name,icon FROM accounts WHERE id='tone'").get()).toEqual({
      name: "Savings",
      icon: darkThumbs,
    });
    expect(db.query("SELECT name FROM payees WHERE id='payee-thumbs'").get()).toEqual({ name: "Transfer : Banana" });
    expect(db.query("SELECT server_knowledge FROM plans WHERE id='p'").get()).toEqual({ server_knowledge: 5 });
  });

  test("unsupported graphs fail before any mutation", async () => {
    const db = await ledgerSqlite();
    const writer = new D1TransactionRepository(new D1Database(fakeD1(db)));
    await expect(writer.create("p", { account_id: "a", date: "2026-07-01", amount: 1, subtransactions: [{ amount: 1 }] })).rejects.toThrow("at least two subtransactions");
    expect(db.query("SELECT COUNT(*) count FROM transactions").get()).toEqual({ count: 0 });
    expect(db.query("SELECT write_version FROM write_state").get()).toEqual({ write_version: 0 });
  });
});

describe("nullable approval parity", () => {
  for (const engine of ["SQLite", "D1"] as const) {
    for (const mode of ["single", "batch"] as const) {
      test(`${engine} ${mode} preserves omitted approval and clears explicit null`, async () => {
        const db = await ledgerSqlite();
        provisionTransferPayee(db, "a");
        const repo = engine === "D1"
          ? new D1LedgerRepository(new D1Database(fakeD1(db)), "p")
          : new LedgerRepository(db, "p");
        const update = async (id: string, patch: { approved?: boolean | null; memo?: string }) => {
          if (mode === "single") await repo.updateTransaction("p", id, patch);
          else await repo.updateTransactions("p", [{ lookup: { kind: "id", id }, patch }]);
        };
        await repo.createTransaction("p", {
          id: "nullable", account_id: "a", date: "2026-07-01", amount: -300, approved: true,
        });
        await update("nullable", { memo: "approval omitted" });
        expect((await repo.getTransaction("p", "nullable")).approved).toBe(true);
        await update("nullable", { approved: null, memo: "explicit null" });
        expect(await repo.getTransaction("p", "nullable")).toMatchObject({ approved: false, memo: "explicit null" });
        await update("nullable", { approved: true });
        await update("nullable", { approved: null });
        expect((await repo.getTransaction("p", "nullable")).approved).toBe(false);

        await repo.upsertAccount("p", { id: "b", name: "Savings" });
        const split = await repo.createTransaction("p", {
          id: "split-nullable", account_id: "a", date: "2026-07-01", amount: -300, approved: true,
          subtransactions: [{ amount: -100, transfer_account_id: "b" }, { amount: -200 }],
        });
        const mirrorId = split.subtransactions.find((sub: { amount: number }) => sub.amount === -100).transfer_transaction_id;
        expect(mirrorId).toBeString();
        await update(mirrorId, { approved: null });
        expect((await repo.getTransaction("p", split.id)).approved).toBe(false);
        expect((await repo.getTransaction("p", mirrorId)).approved).toBe(false);
        await update(mirrorId, { approved: true });
        expect((await repo.getTransaction("p", split.id)).approved).toBe(true);
        expect((await repo.getTransaction("p", mirrorId)).approved).toBe(true);
      });
    }
  }
});

describe("D1 bulk transaction commands", () => {
  test("bulk cleared keeps per-row CAS, continues past conflicts, and reports ordered outcomes", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.createTransaction("p", { id: "c1", account_id: "a", date: "2026-07-01", amount: -100, cleared: "uncleared" });
    await repo.createTransaction("p", { id: "c2", account_id: "a", date: "2026-07-02", amount: -200, cleared: "uncleared" });
    await repo.createTransaction("p", { id: "c3", account_id: "a", date: "2026-07-03", amount: -300, cleared: "cleared" });
    await repo.createTransaction("p", { id: "c4", account_id: "a", date: "2026-07-04", amount: -400, cleared: "reconciled" });

    const result = await repo.updateTransactionsCleared("p", [
      { id: "c1", expected_cleared: "uncleared", cleared: "cleared" },
      { id: "c2", expected_cleared: "cleared", cleared: "uncleared" },
      { id: "c3", expected_cleared: "cleared", cleared: "uncleared" },
      { id: "c4", expected_cleared: "cleared", cleared: "uncleared" },
    ]);

    expect(result.outcomes.map((outcome) => [outcome.id, outcome.status])).toEqual([
      ["c1", "applied"],
      ["c2", "conflict"],
      ["c3", "applied"],
      ["c4", "conflict"],
    ]);
    expect(result.applied_count).toBe(2);
    expect(result.conflict_count).toBe(2);
    expect(db.query("SELECT id, cleared FROM transactions ORDER BY id").all()).toEqual([
      { id: "c1", cleared: "cleared" },
      { id: "c2", cleared: "uncleared" },
      { id: "c3", cleared: "uncleared" },
      { id: "c4", cleared: "reconciled" },
    ]);
    // The reconciled row still counts toward the cleared balance, untouched.
    expect(db.query("SELECT cleared_balance_milli, uncleared_balance_milli FROM accounts WHERE id='a'").get()).toEqual({
      cleared_balance_milli: -500,
      uncleared_balance_milli: -500,
    });
  });

  test("bulk cleared changes only the selected transfer side", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.upsertAccount("p", { id: "b", name: "Savings" });
    provisionTransferPayee(db, "a");
    const created = await repo.createTransaction("p", {
      id: "leg-a", account_id: "a", date: "2026-07-01", amount: -250, transfer_account_id: "b", cleared: "uncleared",
    });
    const mirror = created.transfer_transaction_id as string;
    expect(mirror).toBeString();

    const result = await repo.updateTransactionsCleared("p", [
      { id: "leg-a", expected_cleared: "uncleared", cleared: "cleared" },
    ]);

    expect(result.outcomes).toEqual([{ id: "leg-a", status: "applied" }]);
    expect(db.query("SELECT id, cleared FROM transactions ORDER BY id").all()).toEqual([
      { id: "leg-a", cleared: "cleared" },
      { id: mirror, cleared: "uncleared" },
    ]);
  });

  test("bulk cleared reports a missing row like SQLite and keeps going", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.createTransaction("p", { id: "c-live", account_id: "a", date: "2026-07-01", amount: -100, cleared: "uncleared" });

    const result = await repo.updateTransactionsCleared("p", [
      { id: "c-missing", expected_cleared: "uncleared", cleared: "cleared" },
      { id: "c-live", expected_cleared: "uncleared", cleared: "cleared" },
    ]);

    expect(result.outcomes.map((outcome) => [outcome.id, outcome.status])).toEqual([
      ["c-missing", "already_removed"],
      ["c-live", "applied"],
    ]);
    expect(result.already_removed_count).toBe(1);
    expect(result.applied_count).toBe(1);
    expect(db.query("SELECT cleared FROM transactions WHERE id='c-live'").get()).toEqual({ cleared: "cleared" });
  });

  test("bulk delete reports a selected transfer pair as one delete and one already-removed row", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.upsertAccount("p", { id: "b", name: "Savings" });
    provisionTransferPayee(db, "a");
    const created = await repo.createTransaction("p", {
      id: "leg-a", account_id: "a", date: "2026-07-01", amount: -250, transfer_account_id: "b",
    });
    const mirror = created.transfer_transaction_id as string;

    const result = await repo.deleteTransactions("p", [{ id: "leg-a" }, { id: mirror }]);

    expect(result.outcomes.map((outcome) => [outcome.id, outcome.status])).toEqual([
      ["leg-a", "applied"],
      [mirror, "already_removed"],
    ]);
    // Only the first leg is this command's work; the cascade is observed, not claimed.
    expect(result.applied_count).toBe(1);
    expect(result.already_removed_count).toBe(1);
    expect(result.conflict_count).toBe(0);
    expect(db.query("SELECT id, deleted FROM transactions ORDER BY id").all()).toEqual([
      { id: "leg-a", deleted: 1 },
      { id: mirror, deleted: 1 },
    ]);
    expect(db.query("SELECT id, balance_milli FROM accounts ORDER BY id").all()).toEqual([
      { id: "a", balance_milli: 0 },
      { id: "b", balance_milli: 0 },
    ]);
  });

  test("bulk delete never claims an already-gone or unknown row as its own work", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.createTransaction("p", { id: "gone", account_id: "a", date: "2026-07-01", amount: -100 });
    await repo.createTransaction("p", { id: "here", account_id: "a", date: "2026-07-02", amount: -200 });
    await repo.deleteTransaction("p", "gone");

    const result = await repo.deleteTransactions("p", [{ id: "gone" }, { id: "here" }, { id: "never-existed" }]);

    expect(result.outcomes.map((outcome) => [outcome.id, outcome.status])).toEqual([
      ["gone", "already_removed"],
      ["here", "applied"],
      ["never-existed", "already_removed"],
    ]);
    expect(result.applied_count).toBe(1);
    expect(result.already_removed_count).toBe(2);
    expect(db.query("SELECT id, deleted FROM transactions ORDER BY id").all()).toEqual([
      { id: "gone", deleted: 1 },
      { id: "here", deleted: 1 },
    ]);
  });

  test("bulk delete does not attribute an external deletion to this command", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.createTransaction("p", { id: "x1", account_id: "a", date: "2026-07-01", amount: -100 });
    await repo.createTransaction("p", { id: "x2", account_id: "a", date: "2026-07-02", amount: -200 });
    // Another client removed x1 before this command reached it.
    db.run("UPDATE transactions SET deleted=1 WHERE id='x1'");

    const result = await repo.deleteTransactions("p", [{ id: "x1" }, { id: "x2" }]);

    expect(result.outcomes.map((outcome) => [outcome.id, outcome.status])).toEqual([
      ["x1", "already_removed"],
      ["x2", "applied"],
    ]);
    expect(result.applied_count).toBe(1);
    expect(result.already_removed_count).toBe(1);
  });

  test("bulk delete keeps an approval race as a conflict and leaves the row alone", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.createTransaction("p", { id: "n1", account_id: "a", date: "2026-07-01", amount: -100, approved: false });
    await repo.createTransaction("p", { id: "n2", account_id: "a", date: "2026-07-02", amount: -200, approved: false });
    db.run("UPDATE transactions SET approved=1 WHERE id='n2'");

    const result = await repo.deleteTransactions("p", [
      { id: "n1", expected_approved: false },
      { id: "n2", expected_approved: false },
    ]);

    expect(result.outcomes.map((outcome) => [outcome.id, outcome.status])).toEqual([
      ["n1", "applied"],
      ["n2", "conflict"],
    ]);
    expect(db.query("SELECT id, deleted FROM transactions ORDER BY id").all()).toEqual([
      { id: "n1", deleted: 1 },
      { id: "n2", deleted: 0 },
    ]);
  });

  test("bulk delete keeps a conflict as a conflict even when a sibling delete cascades over it", async () => {
    const db = await ledgerSqlite();
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db)), "p");
    await repo.upsertAccount("p", { id: "b", name: "Savings" });
    provisionTransferPayee(db, "a");
    const created = await repo.createTransaction("p", {
      id: "leg-a", account_id: "a", date: "2026-07-01", amount: -250, transfer_account_id: "b", approved: false,
    });
    const mirror = created.transfer_transaction_id as string;
    db.run("UPDATE transactions SET approved=1 WHERE id=?", [mirror]);

    const result = await repo.deleteTransactions("p", [
      { id: mirror, expected_approved: false },
      { id: "leg-a", expected_approved: false },
    ]);

    // The mirror's own command was rejected; the later leg-a delete happens to
    // cascade over it, but this command has no committed-deletion ids to prove
    // that, so it must not restate the item as its own removal.
    expect(result.outcomes.map((outcome) => [outcome.id, outcome.status])).toEqual([
      [mirror, "conflict"],
      ["leg-a", "applied"],
    ]);
    expect(result.applied_count).toBe(1);
    expect(result.conflict_count).toBe(1);
    expect(result.already_removed_count).toBe(0);
    expect(db.query("SELECT deleted FROM transactions WHERE id=?").get(mirror)).toEqual({ deleted: 1 });
  });

  test("bulk delete stops at an ambiguous failure without replaying or leaking its detail", async () => {
    const db = await ledgerSqlite();
    const sentinel = "PRIVATE_ledger_table_9f3c";
    let commandInserts = 0;
    let armed = false;
    const repo = new D1LedgerRepository(new D1Database(fakeD1(db, {
      beforeRunMutation: async (sql) => {
        if (!armed || !sql.includes("INSERT INTO write_commands")) return;
        commandInserts += 1;
        if (commandInserts === 2) throw new Error(`no such table: ${sentinel} (bound values withheld)`);
      },
    })), "p");
    await repo.createTransaction("p", { id: "d1", account_id: "a", date: "2026-07-01", amount: -100 });
    await repo.createTransaction("p", { id: "d2", account_id: "a", date: "2026-07-02", amount: -200 });
    await repo.createTransaction("p", { id: "d3", account_id: "a", date: "2026-07-03", amount: -300 });
    armed = true;

    const result = await repo.deleteTransactions("p", [{ id: "d1" }, { id: "d2" }, { id: "d3" }]);

    expect(result.outcomes.map((outcome) => [outcome.id, outcome.status])).toEqual([
      ["d1", "applied"],
      ["d2", "unresolved"],
      ["d3", "unattempted"],
    ]);
    // A 200 bulk body must not carry what a 500 would redact.
    expect(result.outcomes[1]!.detail).toBe("This row's write could not be confirmed");
    expect(JSON.stringify(result)).not.toContain(sentinel);
    expect(db.query("SELECT id, deleted FROM transactions ORDER BY id").all()).toEqual([
      { id: "d1", deleted: 1 },
      { id: "d2", deleted: 0 },
      { id: "d3", deleted: 0 },
    ]);
    // The unresolved write left no receipt and was not replayed; the row behind
    // it was never attempted.
    expect(db.query("SELECT COUNT(*) count FROM write_commands WHERE kind='transaction.delete'").get()).toEqual({ count: 1 });
    expect(db.query("SELECT COUNT(*) count FROM write_commands WHERE kind='transaction.delete' AND transaction_id='d2'").get()).toEqual({ count: 0 });
  });

  test("bulk update hydrates each row once instead of once per write and once per response", async () => {
    const db = await ledgerSqlite();
    const counting = new CountingD1Database(fakeD1Binding(db));
    const repo = new D1LedgerRepository(counting, "p");
    await repo.createTransaction("p", { id: "b1", account_id: "a", date: "2026-07-01", amount: -100 });
    await repo.createTransaction("p", { id: "b2", account_id: "a", date: "2026-07-02", amount: -200 });

    counting.reset();
    const batch = await repo.updateTransactions("p", [
      { lookup: { kind: "id", id: "b1" }, patch: { memo: "one" } },
      { lookup: { kind: "id", id: "b2" }, patch: { memo: "two" } },
    ]);

    expect(batch.transactions.map((row) => row.memo)).toEqual(["one", "two"]);
    // Two lookup reads, two guarded writes (each a batch read + a batch write),
    // one hydration read per row, and one knowledge read. The discarded
    // per-write hydration the batch used to do would add two more.
    const hydrationReads = counting.roundTrips.filter((trip) => trip.kind === "all" && trip.sql.includes("st.*"));
    expect(hydrationReads).toHaveLength(2);
    expect(counting.count).toBe(15);
  });
});

/** `ledgerSqlite` inserts account `a` directly, so a transfer needs its payee. */
function provisionTransferPayee(db: Database, accountId: string): void {
  db.run(
    "INSERT INTO payees (id, plan_id, name, transfer_account_id) VALUES (?, 'p', ?, ?)",
    [`to-${accountId}`, `Transfer to ${accountId}`, accountId],
  );
  db.run("UPDATE accounts SET transfer_payee_id=? WHERE id=?", [`to-${accountId}`, accountId]);
}

async function ledgerSqlite(): Promise<Database> {
  const db = sqlite();
  for (const path of ["../d1-migrations/0001_initial.sql", "../d1-migrations/0002_password_auth.sql", "../d1-migrations/0003_allow_duplicate_payee_names.sql", "../d1-migrations/0004_ynab_raw_objects.sql", "../d1-migrations/0005_plan_month_assignments.sql", "../d1-migrations/0006_plan_month_category_targets.sql", "../d1-migrations/0007_scheduled_transaction_edits.sql", "../d1-migrations/0008_scheduled_transaction_snapshot_assertions.sql", "../d1-migrations/0009_account_reconciliation_assertions.sql", "../d1-migrations/0010_unique_live_import_id.sql", "../d1-migrations/0011_personal_api_tokens.sql", "../d1-migrations/0012_account_preferences.sql", "../d1-migrations/0013_account_icons.sql", "../d1-migrations/0014_account_icon_emoji_backfill.sql", "../d1-migrations/0015_rewards_tracker.sql", "../d1-migrations/0016_query_covering_indexes.sql", "../d1-migrations/0017_ynab_source_month_activity.sql", "../d1-migrations/0018_account_month_balances.sql"]) db.exec(await Bun.file(new URL(path, import.meta.url)).text());
  db.run("INSERT INTO plans (id, name) VALUES ('p', 'Plan')");
  db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('a', 'p', 'Cash')");
  return db;
}

function sqlite(): Database { const db = new Database(":memory:", { strict: true }); databases.push(db); return db; }

function fakeD1(db: Database, faults: { commitThenThrowOnce?: boolean; commitThenThrowSql?: RegExp; beforeWriteBatch?: (db: Database) => void; maxBindings?: number; beforeRunMutation?: (sql: string) => Promise<void> } = {}): D1Binding {
  let commitThenThrow = faults.commitThenThrowOnce ?? Boolean(faults.commitThenThrowSql);
  let mutateBeforeWrite = faults.beforeWriteBatch;
  // D1 serialises atomic batches.  Keep the fake faithful while still letting
  // callers race their reads before either guarded batch starts.
  let batchTail = Promise.resolve();
  class Statement implements D1Statement {
    values: unknown[] = [];
    constructor(readonly sql: string) {}
    bind(...values: unknown[]) {
      if (faults.maxBindings != null && values.length > faults.maxBindings) throw new Error("too many SQL parameters");
      this.values = values; return this;
    }
    async all<Row>(): Promise<D1Result<Row>> { return { success: true, results: db.query(this.sql).all(...this.values as any[]) as Row[] }; }
    async first<Row>(): Promise<Row | null> { return db.query(this.sql).get(...this.values as any[]) as Row | null; }
    async run(): Promise<D1Result> { await faults.beforeRunMutation?.(this.sql); const result = db.query(this.sql).run(...this.values as any[]); return { success: true, meta: { changes: Number(result.changes) } }; }
    async execute<Row>(): Promise<D1Result<Row>> {
      return /^\s*(SELECT|WITH)\b/i.test(this.sql) ? this.all<Row>() : this.run() as Promise<D1Result<Row>>;
    }
  }
  return {
    prepare: (sql) => new Statement(sql),
    batch: async <Row>(statements: D1Statement[]) => {
      const previous = batchTail;
      let release!: () => void;
      batchTail = new Promise<void>((resolve) => { release = resolve; });
      await previous;
      try {
        if (mutateBeforeWrite && statements.some((item) => /^INSERT INTO write_commands/i.test((item as Statement).sql))) {
          const mutate = mutateBeforeWrite; mutateBeforeWrite = undefined; mutate(db);
        }
        db.exec("BEGIN IMMEDIATE");
        try { const results = []; for (const statement of statements) results.push(await (statement as Statement).execute<Row>()); db.exec("COMMIT"); if (commitThenThrow && statements.some((item) => (faults.commitThenThrowSql ?? /^INSERT INTO write_commands/i).test((item as Statement).sql))) { commitThenThrow = false; throw new Error("ambiguous committed batch"); } return results as D1Result<Row>[]; }
        catch (error) { if (db.inTransaction) db.exec("ROLLBACK"); throw error; }
      } finally {
        release();
      }
    },
  };
}
