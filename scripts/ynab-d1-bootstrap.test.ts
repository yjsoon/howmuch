import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdtempSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { openDatabase } from "../apps/api/src/db";
import { generateYnabD1Bootstrap, generateYnabD1BootstrapChunks } from "./lib/ynab-d1-bootstrap";

function fixture(dir: string): string {
  const path = join(dir, "source.sqlite"); const db = openDatabase(path);
  db.exec(`
    INSERT INTO plans(id,name,server_knowledge) VALUES('p','Private plan',50);
    INSERT INTO category_groups(id,plan_id,name) VALUES('g','p','Group');
    INSERT INTO categories(id,plan_id,category_group_id,name) VALUES('c','p','g','Category');
    INSERT INTO payees(id,plan_id,name,transfer_account_id) VALUES('pa','p','Transfer A','a'),('pb','p','Transfer B','b'),('shop','p','Shop',NULL),('shop-duplicate','p','Shop',NULL);
    INSERT INTO accounts(id,plan_id,name,transfer_payee_id,opening_balance_milli) VALUES('a','p','A','pa',100),('b','p','B','pb',0);
    INSERT INTO import_sessions(id,plan_id,source,status,finished_at,summary_json) VALUES('i','p','ynab-api','completed',CURRENT_TIMESTAMP,'{"imported_transactions":5,"server_knowledge":50}');
    INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,payee_id,category_id,source_kind,source_ref,server_knowledge) VALUES
      ('split','p','a','2026-01-01',-30,'shop',NULL,'ynab-import','i',40),
      ('split-mirror','p','b','2026-01-01',20,'pa',NULL,'ynab-import','i',40),
      ('ta','p','a','2026-01-02',-20,'pb',NULL,'ynab-import','i',41),
      ('tb','p','b','2026-01-02',20,'pa',NULL,'ynab-import','i',41),
      ('gone','p','a','2026-01-03',-999,'shop','c','ynab-import','i',42),
      ('duplicate-payee','p','a','2026-01-04',-500,'shop-duplicate','c','ynab-import','i',43);
    UPDATE transactions SET transfer_account_id='a',transfer_transaction_id='s2' WHERE id='split-mirror';
    UPDATE transactions SET transfer_account_id='b',transfer_transaction_id='tb' WHERE id='ta';
    UPDATE transactions SET transfer_account_id='a',transfer_transaction_id='ta' WHERE id='tb';
    UPDATE transactions SET deleted=1 WHERE id='gone';
    INSERT INTO subtransactions(id,transaction_id,amount_milli,payee_id,category_id,transfer_account_id,transfer_transaction_id)
      VALUES('s1','split',-10,'shop','c',NULL,NULL),('s2','split',-20,'pb',NULL,'b','split-mirror');
    INSERT INTO import_rows(id,import_session_id,row_index,status,payload_json,transaction_id) VALUES
      ('r1','i',0,'imported','{}','split'),('r2','i',1,'imported','{}','split-mirror'),('r3','i',2,'imported','{}','ta'),('r4','i',3,'imported','{}','tb'),('r5','i',4,'imported','{}','gone'),('r6','i',5,'imported','{}','duplicate-payee');
    INSERT INTO source_events(id,plan_id,transaction_id,source_kind,source_ref,payload_json) VALUES
      ('e1','p','split','ynab-import','i','{}'),('e2','p','split-mirror','ynab-import','i','{}'),('e3','p','ta','ynab-import','i','{}'),('e4','p','tb','ynab-import','i','{}'),('e5','p','gone','ynab-import','i','{}'),('e6','p','duplicate-payee','ynab-import','i','{}');
    INSERT INTO ynab_raw_objects(plan_id,object_type,object_id,payload_json,deleted,server_knowledge) VALUES
      ('p','plan','p','{"id":"p","name":"Private plan"}',0,50),
      ('p','month','2026-01-01','{"month":"2026-01-01","budgeted":10}',0,50),
      ('p','month_category','2026-01-01\u001fc','{"id":"c","budgeted":10,"goal_type":"TB"}',0,50),
      ('p','scheduled_transaction','scheduled-1','{"id":"scheduled-1","amount":-10,"date_next":"2026-02-01"}',0,50),
      ('p','transaction','split','{"id":"split"}',0,50),
      ('p','transaction','split-mirror','{"id":"split-mirror"}',0,50),
      ('p','transaction','ta','{"id":"ta"}',0,50),
      ('p','transaction','tb','{"id":"tb"}',0,50),
      ('p','transaction','gone','{"id":"gone","deleted":true}',1,50),
      ('p','transaction','duplicate-payee','{"id":"duplicate-payee"}',0,50);
    UPDATE transactions SET memo='O''Brien;
-- still data' WHERE id='ta';
    UPDATE import_sessions SET summary_json='{"imported_transactions":6,"server_knowledge":50,"raw_objects":{"plan":1,"month":1,"month_category":1,"scheduled_transaction":1,"transaction":6}}' WHERE id='i';
    UPDATE accounts SET balance_milli=opening_balance_milli+COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0),0),cleared_balance_milli=opening_balance_milli,uncleared_balance_milli=COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0),0);
  `);
  db.close(); return path;
}

function migratedTarget(): Database {
  const target = new Database(":memory:");
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0001_initial.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0002_password_auth.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0003_allow_duplicate_payee_names.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0004_ynab_raw_objects.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0005_plan_month_assignments.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0006_plan_month_category_targets.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0007_scheduled_transaction_edits.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0008_scheduled_transaction_snapshot_assertions.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0009_account_reconciliation_assertions.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0010_unique_live_import_id.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0011_personal_api_tokens.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0012_account_preferences.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0013_account_icons.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0014_account_icon_emoji_backfill.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0015_rewards_tracker.sql", import.meta.url), "utf8"));
  return target;
}

function firstStatementList(sql: string, count: number): string[] {
  const statements: string[] = [];
  let end = 0;
  for (let index = 0; index < count; index += 1) {
    const next = sql.indexOf(";", end);
    if (next < 0) throw new Error("Generated SQL has too few guard statements");
    statements.push(sql.slice(end, next + 1));
    end = next + 1;
  }
  return statements;
}

function firstStatements(sql: string, count: number): string {
  return firstStatementList(sql, count).join("\n");
}

function executeGuard(db: Database, statements: string[]) {
  db.exec("BEGIN");
  try {
    for (const statement of statements) db.run(statement);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

function chunkFixture(dir: string): string {
  const path = fixture(dir);
  const db = new Database(path);
  const memo = "x".repeat(7_000);
  for (let index = 6; index < 406; index++) {
    const id = `wide-${String(index).padStart(4, "0")}`;
    db.run("INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,payee_id,category_id,memo,source_kind,source_ref,server_knowledge) VALUES(?,?,?,?,?,?,?,?,?,?,?)", [id, "p", "a", "2026-02-01", -1, "shop", "c", memo, "ynab-import", "i", 50]);
    db.run("INSERT INTO import_rows(id,import_session_id,row_index,status,payload_json,transaction_id) VALUES(?,?,?,?,?,?)", [`r-${index}`, "i", index, "imported", "{}", id]);
    db.run("INSERT INTO source_events(id,plan_id,transaction_id,source_kind,source_ref,payload_json) VALUES(?,?,?,?,?,?)", [`e-${index}`, "p", id, "ynab-import", "i", "{}"]);
    db.run("INSERT INTO ynab_raw_objects(plan_id,object_type,object_id,payload_json,server_knowledge) VALUES(?,?,?,?,?)", ["p", "transaction", id, JSON.stringify({ id }), 50]);
  }
  db.run("UPDATE import_sessions SET summary_json=? WHERE id='i'", [JSON.stringify({ imported_transactions: 406, server_knowledge: 50, raw_objects: { plan: 1, month: 1, month_category: 1, scheduled_transaction: 1, transaction: 406 } })]);
  db.exec("UPDATE accounts SET balance_milli=opening_balance_milli+COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0),0), cleared_balance_milli=opening_balance_milli+COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0 AND cleared IN ('cleared','reconciled')),0), uncleared_balance_milli=COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0 AND cleared='uncleared'),0)");
  db.close();
  return path;
}

describe("offline YNAB D1 bootstrap", () => {
  test("generates validated bounded SQL and privacy-safe manifest", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-bootstrap-"));
    try {
      const source = fixture(dir), output = join(dir, "bootstrap.sql");
      const manifest = generateYnabD1Bootstrap(source, output);
      const sql = readFileSync(output, "utf8");
      expect(sql.startsWith("INSERT INTO write_state(singleton,write_version) SELECT 1,0 WHERE")).toBeTrue();
      expect(firstStatements(sql, 1)).toContain("UNION ALL SELECT 1,0 WHERE");
      expect(sql).not.toContain("BEGIN"); expect(sql).not.toContain("COMMIT");
      expect(sql).toMatch(/INSERT INTO transactions \([^)]*ledger_sequence/);
      expect(sql).toMatch(/INSERT INTO subtransactions \([^)]*ledger_sequence/);
      expect(sql).toContain("O''Brien;\n-- still data");
      expect(Math.max(...sql.split(";\n").map(s => Buffer.byteLength(s)))).toBeLessThanOrEqual(8 * 1024);
      expect(manifest.counts.transactions).toEqual({ active: 5, deleted: 1 });
      expect(manifest.counts.ynab_raw_objects).toEqual({ active: 9, deleted: 1 });
      const publicManifest = readFileSync(`${output}.manifest.json`, "utf8");
      expect(publicManifest).not.toContain("Private plan"); expect(publicManifest).not.toContain("Shop");
      const target = migratedTarget(); target.exec(sql);
      expect(target.query("SELECT id,ledger_sequence FROM transactions ORDER BY ledger_sequence").all()).toEqual([{id:"split",ledger_sequence:1},{id:"split-mirror",ledger_sequence:2},{id:"ta",ledger_sequence:3},{id:"tb",ledger_sequence:4},{id:"gone",ledger_sequence:5},{id:"duplicate-payee",ledger_sequence:6}]);
      expect(target.query("SELECT id,name FROM payees WHERE name='Shop' ORDER BY id").all()).toEqual([{id:"shop",name:"Shop"},{id:"shop-duplicate",name:"Shop"}]);
      expect(target.query("SELECT object_type,object_id FROM ynab_raw_objects WHERE object_type<>'transaction' ORDER BY object_type,object_id").all()).toEqual([
        { object_type: "month", object_id: "2026-01-01" },
        { object_type: "month_category", object_id: "2026-01-01\u001fc" },
        { object_type: "plan", object_id: "p" },
        { object_type: "scheduled_transaction", object_id: "scheduled-1" },
      ]);
      expect(target.query("SELECT count(*) count FROM source_events").get()).toEqual({ count: 6 });
      expect(target.query("SELECT count(*) count FROM import_rows").get()).toEqual({ count: 6 });
      target.close();
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  test("the duplicate-singleton checkpoint guard accepts a clean target and rejects dirty or malformed targets", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-bootstrap-"));
    try {
      const output = join(dir, "bootstrap.sql"); generateYnabD1Bootstrap(fixture(dir), output);
      const guard = firstStatementList(readFileSync(output, "utf8"), 1);
      const safe = migratedTarget();
      expect(() => executeGuard(safe, guard)).not.toThrow();
      expect(safe.query("SELECT singleton,write_version,last_command_id FROM write_state").all()).toEqual([{ singleton: 1, write_version: 0, last_command_id: null }]);
      safe.close();
      const missingState = migratedTarget(); missingState.exec("DROP TABLE write_state");
      expect(() => executeGuard(missingState, guard)).toThrow(); missingState.close();
      const emptyState = migratedTarget(); emptyState.exec("DELETE FROM write_state");
      expect(() => executeGuard(emptyState, guard)).toThrow(); emptyState.close();
      const staleState = migratedTarget(); staleState.exec("DROP TRIGGER write_state_increment_guard; UPDATE write_state SET write_version=1");
      expect(() => executeGuard(staleState, guard)).toThrow(); staleState.close();
      const claimedState = migratedTarget(); claimedState.exec("PRAGMA foreign_keys=OFF; DROP TRIGGER write_state_increment_guard; UPDATE write_state SET last_command_id='already-used'; PRAGMA foreign_keys=ON");
      expect(() => executeGuard(claimedState, guard)).toThrow(); claimedState.close();
      const contaminated = migratedTarget(); contaminated.exec("INSERT INTO users(id) VALUES('u')");
      expect(() => executeGuard(contaminated, guard)).toThrow(); contaminated.close();
      const assigned = migratedTarget(); assigned.exec("INSERT INTO plans(id,name) VALUES('p','Plan'); INSERT INTO category_groups(id,plan_id,name) VALUES('g','p','Group'); INSERT INTO categories(id,plan_id,category_group_id,name) VALUES('c','p','g','Category'); INSERT INTO plan_month_assignments(plan_id,month,category_id,budgeted_milli) VALUES('p','2026-01-01','c',1)");
      expect(() => executeGuard(assigned, guard)).toThrow(); assigned.close();
      const missingGuardedTable = migratedTarget(); missingGuardedTable.exec("DROP TABLE users");
      expect(() => executeGuard(missingGuardedTable, guard)).toThrow(); missingGuardedTable.close();
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  test("writes deterministic checkpointed chunks which only apply sequentially", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-bootstrap-"));
    try {
      const source = chunkFixture(dir), output = join(dir, "chunks");
      const manifest = generateYnabD1BootstrapChunks(source, output);
      expect(manifest.format).toBe("howmuch-d1-bootstrap-chunks-v1");
      expect(manifest.chunks.length).toBeGreaterThan(1);
      expect(manifest.logical_data.statement_count).toBeGreaterThan(400);
      for (const chunk of manifest.chunks) {
        expect(chunk.statement_count).toBeLessThanOrEqual(400);
        expect(chunk.byte_count).toBeLessThanOrEqual(2 * 1024 * 1024);
        expect(readFileSync(join(output, chunk.file), "utf8")).toMatch(/^INSERT INTO write_state\(singleton,write_version\) SELECT 1,0 WHERE/);
      }
      const repeatOutput = join(dir, "chunks-repeat");
      const repeated = generateYnabD1BootstrapChunks(source, repeatOutput);
      expect(repeated).toEqual(manifest);
      for (const chunk of manifest.chunks) {
        expect(readFileSync(join(repeatOutput, chunk.file), "utf8")).toEqual(readFileSync(join(output, chunk.file), "utf8"));
      }

      const replay = migratedTarget();
      const first = readFileSync(join(output, manifest.chunks[0].file), "utf8");
      const second = readFileSync(join(output, manifest.chunks[1].file), "utf8");
      expect(() => executeGuard(replay, firstStatementList(second, 1))).toThrow();
      expect(() => replay.exec(first)).not.toThrow();
      expect(() => executeGuard(replay, firstStatementList(first, 1))).toThrow();
      replay.close();

      const target = migratedTarget();
      for (const chunk of manifest.chunks) target.exec(readFileSync(join(output, chunk.file), "utf8"));
      expect(target.query("PRAGMA foreign_key_check").all()).toEqual([]);
      expect(target.query("SELECT count(*) count FROM transactions").get()).toEqual({ count: 406 });
      expect(target.query("SELECT count(*) count FROM ynab_raw_objects").get()).toEqual({ count: 410 });
      expect(target.query("SELECT count(*) count FROM import_rows").get()).toEqual({ count: 406 });
      expect(target.query("SELECT server_knowledge FROM ynab_sync_state").get()).toEqual({ server_knowledge: 50 });
      target.close();
      expect(() => generateYnabD1BootstrapChunks(source, output)).toThrow("must not already exist");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  test("rejects contaminated or reordered source provenance", () => {
    const cases: Array<[string, string]> = [
      ["INSERT INTO users(id) VALUES('u')", "authentication or setup"],
      ["INSERT INTO plan_month_assignments(plan_id,month,category_id,budgeted_milli) VALUES('p','2026-01-01','c',1)", "local plan month assignments"],
      ["INSERT INTO audit_events(id,plan_id,action,source) VALUES('reconcile-audit','p','account.reconcile','howmuch-local')", "account reconciliation history"],
      ["INSERT INTO account_reconciliation_assertions(command_id,plan_id,account_id,statement_date,prior_reconciled_balance_milli,projected_reconciled_balance_milli,candidate_ids_json) VALUES('reconcile-assertion','p','a','2026-01-31',100,100,'[]')", "account reconciliation history"],
      ["UPDATE import_rows SET row_index=row_index+1", "zero-based"],
      ["INSERT INTO source_events(id,plan_id,transaction_id,source_kind,source_ref) VALUES('extra','p','ta','api',NULL)", "exactly one matching"],
    ];
    for (const [mutation, message] of cases) {
      const dir = mkdtempSync(join(tmpdir(), "howmuch-bootstrap-"));
      try {
        const source = fixture(dir); const db = new Database(source); db.exec(mutation); db.close();
        expect(() => generateYnabD1Bootstrap(source, join(dir,"x.sql"))).toThrow(message);
      } finally { rmSync(dir, { recursive: true, force: true }); }
    }
  });

  test("rejects malformed transfer graphs", () => {
    const cases = [
      "UPDATE transactions SET transfer_transaction_id=NULL WHERE id='ta'",
      "UPDATE transactions SET transfer_account_id=NULL,transfer_transaction_id='missing' WHERE id='duplicate-payee'",
      "UPDATE subtransactions SET transfer_account_id=NULL,transfer_transaction_id='missing' WHERE id='s1'",
      "UPDATE transactions SET amount_milli=21 WHERE id='tb'",
      "UPDATE transactions SET transfer_transaction_id='ta' WHERE id='split-mirror'",
    ];
    for (const mutation of cases) {
      const dir = mkdtempSync(join(tmpdir(), "howmuch-bootstrap-"));
      try {
        const source = fixture(dir); const db = new Database(source); db.exec(mutation); db.close();
        expect(() => generateYnabD1Bootstrap(source, join(dir,"x.sql"))).toThrow(/transfer|parity/);
      } finally { rmSync(dir, { recursive: true, force: true }); }
    }
  });

  test("preserves source-authenticated one-sided transaction and split transfers", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-bootstrap-"));
    try {
      const source = fixture(dir); const db = new Database(source);
      db.exec(`
        UPDATE transactions SET transfer_account_id='b',transfer_transaction_id=NULL WHERE id='duplicate-payee';
        UPDATE subtransactions SET transfer_account_id='b',transfer_transaction_id=NULL WHERE id='s1';
        UPDATE ynab_raw_objects SET payload_json='{"id":"duplicate-payee","account_id":"a","transfer_account_id":"b","transfer_transaction_id":null}'
          WHERE plan_id='p' AND object_type='transaction' AND object_id='duplicate-payee';
        INSERT INTO ynab_raw_objects(plan_id,object_type,object_id,payload_json,server_knowledge)
          VALUES('p','subtransaction','split\u001fs1','{"id":"s1","transaction_id":"split","transfer_account_id":"b","transfer_transaction_id":null}',50);
      `);
      db.close();

      const output = join(dir, "x.sql");
      expect(() => generateYnabD1Bootstrap(source, output)).not.toThrow();
      const target = migratedTarget(); target.exec(readFileSync(output, "utf8"));
      expect(target.query("SELECT transfer_account_id,transfer_transaction_id FROM transactions WHERE id='duplicate-payee'").get()).toEqual({ transfer_account_id: "b", transfer_transaction_id: null });
      expect(target.query("SELECT transfer_account_id,transfer_transaction_id FROM subtransactions WHERE id='s1'").get()).toEqual({ transfer_account_id: "b", transfer_transaction_id: null });
      target.close();
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  test("rejects oversized rows and existing output paths", () => {
    const oversizedDir = mkdtempSync(join(tmpdir(), "howmuch-bootstrap-"));
    try {
      const source = fixture(oversizedDir); const db = new Database(source);
      db.query("UPDATE transactions SET memo=? WHERE id='ta'").run("é".repeat(40_000)); db.close();
      const output = join(oversizedDir,"x.sql");
      expect(() => generateYnabD1Bootstrap(source, output)).toThrow("safe D1 statement size");
      expect(existsSync(output)).toBeFalse();
    } finally { rmSync(oversizedDir, { recursive: true, force: true }); }

    const existingDir = mkdtempSync(join(tmpdir(), "howmuch-bootstrap-"));
    try {
      const source = fixture(existingDir), output = join(existingDir,"x.sql");
      writeFileSync(output, "existing");
      expect(() => generateYnabD1Bootstrap(source, output)).toThrow("must not already exist");
    } finally { rmSync(existingDir, { recursive: true, force: true }); }
  });

  test("rejects an additional plan", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-bootstrap-"));
    try { const source = fixture(dir); const db = new Database(source); db.exec("INSERT INTO plans(id,name) VALUES('other','Other')"); db.close(); expect(() => generateYnabD1Bootstrap(source, join(dir,"x.sql"))).toThrow("exactly one plan"); }
    finally { rmSync(dir, { recursive: true, force: true }); }
  });
});
