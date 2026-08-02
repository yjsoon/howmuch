import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdtempSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { openDatabase } from "../apps/api/src/db";
import { generateYnabD1Bootstrap } from "./lib/ynab-d1-bootstrap";

function fixture(dir: string): string {
  const path = join(dir, "source.sqlite"); const db = openDatabase(path);
  db.exec(`
    INSERT INTO plans(id,name,server_knowledge) VALUES('p','Private plan',50);
    INSERT INTO category_groups(id,plan_id,name) VALUES('g','p','Group');
    INSERT INTO categories(id,plan_id,category_group_id,name) VALUES('c','p','g','Category');
    INSERT INTO payees(id,plan_id,name,transfer_account_id) VALUES('pa','p','Transfer A','a'),('pb','p','Transfer B','b'),('shop','p','Shop',NULL);
    INSERT INTO accounts(id,plan_id,name,transfer_payee_id,opening_balance_milli) VALUES('a','p','A','pa',100),('b','p','B','pb',0);
    INSERT INTO import_sessions(id,plan_id,source,status,finished_at,summary_json) VALUES('i','p','ynab-api','completed',CURRENT_TIMESTAMP,'{"imported_transactions":5,"server_knowledge":50}');
    INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,payee_id,category_id,source_kind,source_ref,server_knowledge) VALUES
      ('split','p','a','2026-01-01',-30,'shop',NULL,'ynab-import','i',40),
      ('split-mirror','p','b','2026-01-01',20,'pa',NULL,'ynab-import','i',40),
      ('ta','p','a','2026-01-02',-20,'pb',NULL,'ynab-import','i',41),
      ('tb','p','b','2026-01-02',20,'pa',NULL,'ynab-import','i',41),
      ('gone','p','a','2026-01-03',-999,'shop','c','ynab-import','i',42);
    UPDATE transactions SET transfer_account_id='a',transfer_transaction_id='s2' WHERE id='split-mirror';
    UPDATE transactions SET transfer_account_id='b',transfer_transaction_id='tb' WHERE id='ta';
    UPDATE transactions SET transfer_account_id='a',transfer_transaction_id='ta' WHERE id='tb';
    UPDATE transactions SET deleted=1 WHERE id='gone';
    INSERT INTO subtransactions(id,transaction_id,amount_milli,payee_id,category_id,transfer_account_id,transfer_transaction_id)
      VALUES('s1','split',-10,'shop','c',NULL,NULL),('s2','split',-20,'pb',NULL,'b','split-mirror');
    INSERT INTO import_rows(id,import_session_id,row_index,status,payload_json,transaction_id) VALUES
      ('r1','i',0,'imported','{}','split'),('r2','i',1,'imported','{}','split-mirror'),('r3','i',2,'imported','{}','ta'),('r4','i',3,'imported','{}','tb'),('r5','i',4,'imported','{}','gone');
    INSERT INTO source_events(id,plan_id,transaction_id,source_kind,source_ref,payload_json) VALUES
      ('e1','p','split','ynab-import','i','{}'),('e2','p','split-mirror','ynab-import','i','{}'),('e3','p','ta','ynab-import','i','{}'),('e4','p','tb','ynab-import','i','{}'),('e5','p','gone','ynab-import','i','{}');
    UPDATE transactions SET memo='O''Brien;
-- still data' WHERE id='ta';
    UPDATE accounts SET balance_milli=opening_balance_milli+COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0),0),cleared_balance_milli=opening_balance_milli,uncleared_balance_milli=COALESCE((SELECT sum(amount_milli) FROM transactions WHERE account_id=accounts.id AND deleted=0),0);
  `);
  db.close(); return path;
}

function migratedTarget(): Database {
  const target = new Database(":memory:");
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0001_initial.sql", import.meta.url), "utf8"));
  target.exec(readFileSync(new URL("../apps/api/d1-migrations/0002_password_auth.sql", import.meta.url), "utf8"));
  return target;
}

function firstStatement(sql: string): string {
  return sql.slice(0, sql.indexOf(";") + 1);
}

describe("offline YNAB D1 bootstrap", () => {
  test("generates validated bounded SQL and privacy-safe manifest", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-bootstrap-"));
    try {
      const source = fixture(dir), output = join(dir, "bootstrap.sql");
      const manifest = generateYnabD1Bootstrap(source, output);
      const sql = readFileSync(output, "utf8");
      expect(sql.startsWith("INSERT INTO write_state(singleton,write_version) SELECT 2,-1 WHERE")).toBeTrue();
      expect(sql).not.toContain("BEGIN"); expect(sql).not.toContain("COMMIT");
      expect(sql).toMatch(/INSERT INTO transactions \([^)]*ledger_sequence/);
      expect(sql).toMatch(/INSERT INTO subtransactions \([^)]*ledger_sequence/);
      expect(sql).toContain("O''Brien;\n-- still data");
      expect(Math.max(...sql.split(";\n").map(s => Buffer.byteLength(s)))).toBeLessThanOrEqual(80_000);
      expect(manifest.counts.transactions).toEqual({ active: 4, deleted: 1 });
      const publicManifest = readFileSync(`${output}.manifest.json`, "utf8");
      expect(publicManifest).not.toContain("Private plan"); expect(publicManifest).not.toContain("Shop");
      const target = migratedTarget(); target.exec(sql);
      expect(target.query("SELECT id,ledger_sequence FROM transactions ORDER BY ledger_sequence").all()).toEqual([{id:"split",ledger_sequence:1},{id:"split-mirror",ledger_sequence:2},{id:"ta",ledger_sequence:3},{id:"tb",ledger_sequence:4},{id:"gone",ledger_sequence:5}]);
      target.close();
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  test("the first statement rejects every non-default target state", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-bootstrap-"));
    try {
      const output = join(dir, "bootstrap.sql"); generateYnabD1Bootstrap(fixture(dir), output);
      const guard = firstStatement(readFileSync(output, "utf8"));
      const safe = migratedTarget(); expect(() => safe.run(guard)).not.toThrow(); safe.close();
      const missingState = migratedTarget(); missingState.exec("DROP TABLE write_state");
      // Recreate the malformed empty table so the guard can evaluate all referenced schema.
      missingState.exec("CREATE TABLE write_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),write_version INTEGER NOT NULL CHECK(write_version>=0),last_command_id TEXT)");
      expect(() => missingState.run(guard)).toThrow(); missingState.close();
      const contaminated = migratedTarget(); contaminated.exec("INSERT INTO users(id) VALUES('u')");
      expect(() => contaminated.run(guard)).toThrow(); contaminated.close();
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  test("rejects contaminated or reordered source provenance", () => {
    const cases: Array<[string, string]> = [
      ["INSERT INTO users(id) VALUES('u')", "authentication or setup"],
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
