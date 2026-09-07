import { Database } from "bun:sqlite";
import { describe, expect, test } from "bun:test";
import { applyMigrations } from "../src/db";

describe("local schema migrations", () => {
  test("rebuilds legacy payees without losing referenced rows or allowing name collisions", () => {
    const db = new Database(":memory:");
    try {
      db.exec(`
        PRAGMA foreign_keys = ON;
        CREATE TABLE schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE plans (id TEXT PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE accounts (
          id TEXT PRIMARY KEY,
          plan_id TEXT NOT NULL REFERENCES plans(id),
          name TEXT NOT NULL DEFAULT 'Account',
          type TEXT NOT NULL DEFAULT 'checking',
          deleted INTEGER NOT NULL DEFAULT 0,
          transfer_payee_id TEXT,
          opening_balance_milli INTEGER NOT NULL DEFAULT 0,
          balance_milli INTEGER NOT NULL DEFAULT 0,
          cleared_balance_milli INTEGER NOT NULL DEFAULT 0,
          uncleared_balance_milli INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE payees (
          id TEXT PRIMARY KEY,
          plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          transfer_account_id TEXT,
          external_ynab_id TEXT,
          deleted INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
          updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
          UNIQUE(plan_id, name)
        );
        CREATE INDEX idx_payees_plan_id ON payees(plan_id);
        CREATE UNIQUE INDEX idx_payees_one_transfer_per_account ON payees(plan_id, transfer_account_id) WHERE transfer_account_id IS NOT NULL AND deleted = 0;
        CREATE TRIGGER accounts_transfer_payee_plan_guard BEFORE INSERT ON accounts
        WHEN NEW.transfer_payee_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM payees p WHERE p.id=NEW.transfer_payee_id AND p.plan_id=NEW.plan_id
            AND p.transfer_account_id=NEW.id AND p.deleted=0
        )
        BEGIN SELECT RAISE(ABORT, 'account transfer payee ownership failed'); END;
        CREATE TABLE transactions (
          id TEXT PRIMARY KEY,
          plan_id TEXT,
          account_id TEXT,
          import_id TEXT,
          amount_milli INTEGER NOT NULL DEFAULT 0,
          cleared TEXT NOT NULL DEFAULT 'uncleared',
          deleted INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
          payee_id TEXT REFERENCES payees(id)
        );
        INSERT INTO plans(id,name) VALUES ('p','Plan');
        INSERT INTO payees(id,plan_id,name,external_ynab_id) VALUES ('legacy-payee','p','Same merchant','legacy-payee');
        INSERT INTO transactions(id,payee_id) VALUES ('legacy-transaction','legacy-payee');
        INSERT INTO schema_migrations(version) VALUES
          ('001_initial'),('002_transaction_server_knowledge'),('003_transfer_payees'),('004_auth_foundation'),('005_password_auth');
      `);

      applyMigrations(db);
      db.run("INSERT INTO payees(id,plan_id,name,external_ynab_id) VALUES ('second-payee','p','Same merchant','second-payee')");
      db.run("INSERT INTO transactions(id,payee_id) VALUES ('second-transaction','second-payee')");

      expect(db.query("SELECT id,name FROM payees WHERE plan_id='p' ORDER BY id").all()).toEqual([
        { id: "legacy-payee", name: "Same merchant" },
        { id: "second-payee", name: "Same merchant" },
      ]);
      expect(db.query("SELECT id,payee_id FROM transactions ORDER BY id").all()).toEqual([
        { id: "legacy-transaction", payee_id: "legacy-payee" },
        { id: "second-transaction", payee_id: "second-payee" },
      ]);
      expect(db.query("SELECT name FROM sqlite_master WHERE type='trigger' AND name IN ('accounts_transfer_payee_plan_guard','accounts_transfer_payee_plan_update_guard','payees_transfer_account_plan_guard','payees_transfer_account_plan_update_guard') ORDER BY name").all()).toEqual([]);
      expect(db.query("PRAGMA foreign_key_check").all()).toEqual([]);
    } finally {
      db.close();
    }
  });

  test("unique live import_id cleanup recalculates denormalized account balances", () => {
    const db = new Database(":memory:");
    try {
      db.exec(`
        CREATE TABLE schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE plans (id TEXT PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE accounts (
          id TEXT PRIMARY KEY,
          plan_id TEXT NOT NULL REFERENCES plans(id),
          name TEXT NOT NULL DEFAULT 'Account',
          type TEXT NOT NULL DEFAULT 'checking',
          deleted INTEGER NOT NULL DEFAULT 0,
          opening_balance_milli INTEGER NOT NULL DEFAULT 0,
          balance_milli INTEGER NOT NULL DEFAULT 0,
          cleared_balance_milli INTEGER NOT NULL DEFAULT 0,
          uncleared_balance_milli INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE payees (
          id TEXT PRIMARY KEY,
          plan_id TEXT,
          name TEXT NOT NULL,
          transfer_account_id TEXT,
          deleted INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE transactions (
          id TEXT PRIMARY KEY,
          plan_id TEXT,
          account_id TEXT,
          import_id TEXT,
          amount_milli INTEGER NOT NULL DEFAULT 0,
          cleared TEXT NOT NULL DEFAULT 'uncleared',
          deleted INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        INSERT INTO plans(id,name) VALUES ('p','Plan');
        INSERT INTO accounts(id,plan_id,opening_balance_milli,balance_milli,cleared_balance_milli,uncleared_balance_milli) VALUES
          ('a','p',1000,-8000,-9000,1000),
          ('b','p',0,-9990,-9990,0);
        INSERT INTO transactions(id,plan_id,account_id,import_id,amount_milli,cleared,updated_at) VALUES
          ('old','p','a','dup',-5000,'cleared','2026-01-01T00:00:00Z'),
          ('new','p','a','dup',-4000,'uncleared','2026-01-02T00:00:00Z'),
          ('other','p','b','dup',-9990,'cleared','2026-01-01T00:00:00Z');
        INSERT INTO schema_migrations(version) VALUES
          ('001_initial'),('002_transaction_server_knowledge'),('003_transfer_payees'),('004_auth_foundation'),('005_password_auth'),
          ('006_allow_duplicate_payee_names'),('007_ynab_raw_objects'),('008_plan_month_assignments'),('009_plan_month_category_targets'),
          ('010_scheduled_transaction_edits'),('011_scheduled_transaction_snapshot_assertions'),('012_account_reconciliation_assertions');
      `);

      applyMigrations(db);

      expect(db.query("SELECT id,account_id,amount_milli FROM transactions ORDER BY id").all()).toEqual([
        { id: "new", account_id: "a", amount_milli: -4000 },
        { id: "other", account_id: "b", amount_milli: -9990 },
      ]);
      expect(db.query("SELECT balance_milli, cleared_balance_milli, uncleared_balance_milli FROM accounts WHERE id='a'").get()).toEqual({
        balance_milli: -3000,
        cleared_balance_milli: 1000,
        uncleared_balance_milli: -4000,
      });
      expect(db.query("SELECT balance_milli FROM accounts WHERE id='b'").get()).toEqual({ balance_milli: -9990 });
      expect(db.query("SELECT name FROM pragma_index_info('idx_transactions_live_import_id') ORDER BY seqno").all()).toEqual([
        { name: "plan_id" },
        { name: "account_id" },
        { name: "import_id" },
      ]);
    } finally {
      db.close();
    }
  });

  test("account icons split a leading emoji from the name and default the rest by type", () => {
    const db = new Database(":memory:");
    try {
      db.exec(`
        CREATE TABLE schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE plans (id TEXT PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE accounts (
          id TEXT PRIMARY KEY,
          plan_id TEXT NOT NULL REFERENCES plans(id),
          name TEXT NOT NULL,
          type TEXT NOT NULL DEFAULT 'checking',
          deleted INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE payees (
          id TEXT PRIMARY KEY,
          plan_id TEXT,
          name TEXT NOT NULL,
          transfer_account_id TEXT,
          deleted INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        INSERT INTO plans(id,name) VALUES ('p','Plan');
        INSERT INTO accounts(id,plan_id,name,type) VALUES
          ('card','p','💳 OCBC 365','creditCard'),
          ('saver','p','Rainy Day','savings'),
          ('bank','p','Everyday','checking'),
          ('travel','p','Travel 💳','creditCard'),
          ('dev','p','👩‍💻 Work','otherAsset'),
          ('thumbs','p', char(0x1F44D, 0xFE0F) || ' Banana ','checking'),
          ('trail','p','Banana ' || char(0x1F44D, 0xFE0F) || ' ','checking');
        INSERT INTO payees(id,plan_id,name,transfer_account_id) VALUES
          ('payee-card','p','Transfer : 💳 OCBC 365','card'),
          ('payee-travel','p','Transfer : Travel 💳','travel'),
          ('payee-thumbs','p','Transfer : ' || char(0x1F44D, 0xFE0F) || ' Banana ','thumbs');
        INSERT INTO schema_migrations(version) VALUES
          ('001_initial'),('002_transaction_server_knowledge'),('003_transfer_payees'),('004_auth_foundation'),('005_password_auth'),
          ('006_allow_duplicate_payee_names'),('007_ynab_raw_objects'),('008_plan_month_assignments'),('009_plan_month_category_targets'),
          ('010_scheduled_transaction_edits'),('011_scheduled_transaction_snapshot_assertions'),('012_account_reconciliation_assertions'),
          ('013_unique_live_import_id'),('014_personal_api_tokens'),('015_account_preferences');
      `);

      applyMigrations(db);

      const thumbs = "\u{1F44D}\u{FE0F}";
      expect(db.query("SELECT id,name,icon FROM accounts ORDER BY id").all()).toEqual([
        { id: "bank", name: "Everyday", icon: "🏦" },
        { id: "card", name: "OCBC 365", icon: "💳" },
        { id: "dev", name: "Work", icon: "👩‍💻" },
        { id: "saver", name: "Rainy Day", icon: "💰" },
        { id: "thumbs", name: "Banana", icon: thumbs },
        { id: "trail", name: `Banana ${thumbs}`, icon: "🏦" },
        { id: "travel", name: "Travel 💳", icon: "💳" },
      ]);
      expect(db.query("SELECT name FROM payees WHERE id='payee-card'").get()).toEqual({ name: "Transfer : OCBC 365" });
      expect(db.query("SELECT name FROM payees WHERE id='payee-travel'").get()).toEqual({ name: "Transfer : Travel 💳" });
      expect(db.query("SELECT name FROM payees WHERE id='payee-thumbs'").get()).toEqual({ name: "Transfer : Banana" });
    } finally {
      db.close();
    }
  });

  test("personal API tokens enforce hashed secrets and cascade with their user", () => {
    const db = new Database(":memory:");
    try {
      applyMigrations(db);
      db.run("INSERT INTO users(id,display_name) VALUES ('owner','Owner')");
      const hash = "a".repeat(64);
      db.run("INSERT INTO personal_api_tokens(id,user_id,name,token_hash) VALUES ('one','owner','Home server',?)", [hash]);
      expect(() => db.run(
        "INSERT INTO personal_api_tokens(id,user_id,name,token_hash) VALUES ('two','owner','Duplicate',?)",
        [hash],
      )).toThrow();
      expect(() => db.run(
        "INSERT INTO personal_api_tokens(id,user_id,name,token_hash) VALUES ('bad','owner','Bad hash',?)",
        ["A".repeat(64)],
      )).toThrow();
      expect(db.query("SELECT version FROM schema_migrations WHERE version='014_personal_api_tokens'").get()).toEqual({
        version: "014_personal_api_tokens",
      });
      db.run("DELETE FROM users WHERE id='owner'");
      expect(db.query("SELECT id FROM personal_api_tokens").get()).toBeNull();
      expect(db.query("PRAGMA foreign_key_check").all()).toEqual([]);
    } finally {
      db.close();
    }
  });

  test("query indexes serve transfer-graph and live register lookups", () => {
    const db = new Database(":memory:");
    try {
      applyMigrations(db);
      db.run("INSERT INTO plans(id,name) VALUES ('p','Plan')");
      db.run("INSERT INTO accounts(id,plan_id,name) VALUES ('a','p','Cash')");
      const detail = (sql: string) => JSON.stringify(db.query(`EXPLAIN QUERY PLAN ${sql}`).all());
      expect(detail("SELECT * FROM transactions WHERE transfer_transaction_id = 'x' AND deleted = 0")).toContain("idx_transactions_transfer_transaction_id");
      expect(detail("SELECT t.id FROM transactions t WHERE t.plan_id = 'p' AND t.deleted = 0 ORDER BY t.date DESC, t.created_at DESC, t.id DESC LIMIT 51")).toContain("idx_transactions_plan_live_register");
      expect(detail("SELECT t.id FROM transactions t WHERE t.account_id = 'a' AND t.deleted = 0 ORDER BY t.date DESC, t.created_at DESC, t.id DESC LIMIT 51")).toContain("idx_transactions_account_live_register");
      expect(detail("SELECT MAX(date) FROM transactions WHERE account_id = 'a' AND deleted = 0 AND cleared = 'reconciled'")).toContain("idx_transactions_account_reconciled_date");
      expect(detail("SELECT id, name, transfer_account_id, deleted FROM payees WHERE plan_id = 'p' AND deleted = 0 ORDER BY name")).toContain("idx_payees_plan_live_name");
      expect(db.query("SELECT version FROM schema_migrations WHERE version='019_query_covering_indexes'").get()).toEqual({
        version: "019_query_covering_indexes",
      });
    } finally {
      db.close();
    }
  });
});
