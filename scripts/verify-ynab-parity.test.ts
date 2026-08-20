import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { openDatabase } from "../apps/api/src/db";

const plan = {
  id: "plan",
  name: "Source plan",
  accounts: [{ id: "account", name: "Account", balance: 0 }],
  category_groups: [{
    id: "source-group",
    name: "Source group",
    categories: [{ id: "source-category", name: "Source category", category_group_id: "source-group" }],
  }],
  payees: [],
  payee_locations: [],
  months: [],
  transactions: [{
    id: "transaction-with-legacy-category",
    account_id: "account",
    date: "2026-08-19",
    amount: 0,
    category_id: "legacy-category",
  }],
  subtransactions: [],
  scheduled_transactions: [],
  scheduled_subtransactions: [],
};

function writeFixture(dir: string, extraUnrelatedCategory = false, splitParent = false) {
  const databasePath = join(dir, "howmuch.sqlite");
  const planPath = join(dir, "plan.json");
  const sourcePlan = splitParent ? {
    ...plan,
    transactions: [{
      id: "split-parent-with-legacy-category",
      account_id: "account",
      date: "2026-08-19",
      amount: 0,
      category_id: "split-parent-legacy-category",
    }],
    subtransactions: [{
      id: "split-line",
      transaction_id: "split-parent-with-legacy-category",
      amount: 0,
      category_id: "source-category",
    }],
  } : plan;
  const db = openDatabase(databasePath);
  db.exec(`
    INSERT INTO plans(id,name) VALUES ('plan','Source plan');
    INSERT INTO accounts(id,plan_id,name,opening_balance_milli,balance_milli)
      VALUES ('account','plan','Account',0,0);
    INSERT INTO category_groups(id,plan_id,name) VALUES
      ('source-group','plan','Source group')${splitParent ? "" : ",\n      ('uncategorized-group','plan','Uncategorised')"};
    INSERT INTO categories(id,plan_id,category_group_id,name) VALUES
      ('source-category','plan','source-group','Source category')${splitParent ? "" : ",\n      ('legacy-category','plan','uncategorized-group','Imported legacy category')"};
    INSERT INTO transactions(id,plan_id,account_id,date,amount_milli,category_id)
      VALUES ('${splitParent ? "split-parent-with-legacy-category" : "transaction-with-legacy-category"}','plan','account','2026-08-19',0,${splitParent ? "NULL" : "'legacy-category'"});
  `);
  if (splitParent) {
    db.exec("INSERT INTO subtransactions(id,transaction_id,amount_milli,category_id) VALUES ('split-line','split-parent-with-legacy-category',0,'source-category')");
  }
  if (extraUnrelatedCategory) {
    db.exec(`
      INSERT INTO category_groups(id,plan_id,name)
        VALUES ('unrelated-group','plan','Unrelated group');
      INSERT INTO categories(id,plan_id,category_group_id,name)
        VALUES ('unrelated-category','plan','unrelated-group','Unrelated category');
    `);
  }
  const raw = (type: string, id: string, payload: unknown) => db
    .query("INSERT INTO ynab_raw_objects(plan_id,object_type,object_id,payload_json) VALUES ('plan',?,?,?)")
    .run(type, id, JSON.stringify(payload));
  raw("plan", "plan", { id: sourcePlan.id, name: sourcePlan.name });
  raw("account", "account", sourcePlan.accounts[0]);
  raw("category_group", "source-group", { id: "source-group", name: "Source group" });
  raw("category", "source-category", sourcePlan.category_groups[0].categories[0]);
  raw("transaction", sourcePlan.transactions[0].id, {
    id: sourcePlan.transactions[0].id,
    account_id: "account",
    date: "2026-08-19",
    amount: 0,
    category_id: sourcePlan.transactions[0].category_id,
  });
  if (splitParent) raw("subtransaction", "split-parent-with-legacy-category\u001fsplit-line", sourcePlan.subtransactions[0]);
  db.close();
  writeFileSync(planPath, JSON.stringify({ data: { plan: sourcePlan } }));
  return { databasePath, planPath };
}

function verify(databasePath: string, planPath: string, settingsPath?: string) {
  return Bun.spawnSync(
    ["bun", "scripts/verify-ynab-parity.ts", "--db", databasePath, "--plan-json", planPath, ...(settingsPath ? ["--settings", settingsPath] : [])],
    { cwd: process.cwd(), stdout: "pipe", stderr: "pipe" },
  );
}

describe("YNAB parity verifier category placeholders", () => {
  test("allows an imported uncategorised placeholder referenced by the source ledger", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-ynab-parity-"));
    try {
      const { databasePath, planPath } = writeFixture(dir);
      const result = verify(databasePath, planPath);
      expect(result.exitCode).toBe(0);
      expect(result.stderr.toString()).toBe("");
      expect(result.stdout.toString()).toContain("settings: source=separate-endpoint mirror=0");
      expect(result.stdout.toString()).toContain("YNAB parity verified for plan plan");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("rejects an unrelated additional category and category group", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-ynab-parity-"));
    try {
      const { databasePath, planPath } = writeFixture(dir, true);
      const result = verify(databasePath, planPath);
      expect(result.exitCode).toBe(1);
      expect(result.stderr.toString()).toContain("category_groups: missing=[] unexpected=[unrelated-group]");
      expect(result.stderr.toString()).toContain("categories: missing=[] unexpected=[unrelated-category]");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("does not require a placeholder for a split parent's raw legacy category", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-ynab-parity-"));
    try {
      const { databasePath, planPath } = writeFixture(dir, false, true);
      const result = verify(databasePath, planPath);
      expect(result.exitCode).toBe(0);
      expect(result.stderr.toString()).toBe("");
      expect(result.stdout.toString()).toContain("category_groups ledger_count=1 source_count=1 required_sentinel=0");
      expect(result.stdout.toString()).toContain("required_placeholders=0");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("allows an empty uncategorised sentinel when no placeholder remains", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-ynab-parity-"));
    try {
      const { databasePath, planPath } = writeFixture(dir, false, true);
      const db = openDatabase(databasePath);
      db.exec("INSERT INTO category_groups(id,plan_id,name) VALUES ('uncategorized-group','plan','Uncategorised')");
      db.close();

      const result = verify(databasePath, planPath);
      expect(result.exitCode).toBe(0);
      expect(result.stderr.toString()).toBe("");
      expect(result.stdout.toString()).toContain("category_groups ledger_count=2 source_count=1 required_sentinel=0");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("rejects an unexplained category inside the optional sentinel", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-ynab-parity-"));
    try {
      const { databasePath, planPath } = writeFixture(dir, false, true);
      const db = openDatabase(databasePath);
      db.exec(`
        INSERT INTO category_groups(id,plan_id,name) VALUES ('uncategorized-group','plan','Uncategorised');
        INSERT INTO categories(id,plan_id,category_group_id,name)
          VALUES ('unexplained-category','plan','uncategorized-group','Unexplained category');
      `);
      db.close();

      const result = verify(databasePath, planPath);
      expect(result.exitCode).toBe(1);
      expect(result.stderr.toString()).toContain("categories: missing=[] unexpected=[unexplained-category]");
      expect(result.stderr.toString()).toContain("category_groups: sentinel contains unexplained categories=[unexplained-category]");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("compares the optional settings snapshot canonically as a raw settings object", () => {
    const dir = mkdtempSync(join(tmpdir(), "howmuch-ynab-parity-"));
    try {
      const { databasePath, planPath } = writeFixture(dir);
      const settingsPath = join(dir, "settings.json");
      const settings = { date_format: { format: "YYYY-MM-DD" }, currency_format: { iso_code: "SGD" }, display: { flag_names: { blue: "Follow up" } } };
      writeFileSync(settingsPath, JSON.stringify({ data: { settings, server_knowledge: 42 } }));
      const db = openDatabase(databasePath);
      db.query("INSERT INTO ynab_raw_objects(plan_id,object_type,object_id,payload_json) VALUES ('plan','settings','settings',?)")
        .run(JSON.stringify({ display: { flag_names: { blue: "Follow up" } }, currency_format: { iso_code: "SGD" }, date_format: { format: "YYYY-MM-DD" } }));
      db.close();

      const matched = verify(databasePath, planPath, settingsPath);
      expect(matched.exitCode).toBe(0);
      expect(matched.stderr.toString()).toBe("");
      expect(matched.stdout.toString()).toMatch(/settings: source=1 mirror=1 source_hash=[a-f0-9]{64} mirror_hash=[a-f0-9]{64}/);

      const changed = openDatabase(databasePath);
      changed.query("UPDATE ynab_raw_objects SET payload_json=? WHERE plan_id='plan' AND object_type='settings' AND object_id='settings'")
        .run(JSON.stringify({ date_format: { format: "DD/MM/YYYY" } }));
      changed.close();
      const mismatched = verify(databasePath, planPath, settingsPath);
      expect(mismatched.exitCode).toBe(1);
      expect(mismatched.stderr.toString()).toContain("settings: missing=[] unexpected=[] changed=[settings]");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
