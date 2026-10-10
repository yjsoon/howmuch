import { Database } from "bun:sqlite";
import { applyMigrations } from "../../../../apps/api/src/db";
function attempt(label: string, lines: Array<[string, unknown]>) {
  const db = new Database(":memory:");
  applyMigrations(db);
  db.run("DELETE FROM schema_migrations WHERE version='022_own_imported_ynab_schedules'");
  db.run("ALTER TABLE plans DROP COLUMN ynab_sourced");
  db.run("INSERT INTO plans(id,name) VALUES ('p','P')");
  db.run("INSERT INTO accounts(id,plan_id,name) VALUES ('a','p','A')");
  db.run("INSERT INTO ynab_raw_objects(plan_id,object_type,object_id,payload_json) VALUES ('p','scheduled_transaction','s1',?)", [JSON.stringify({ id: "s1", account_id: "a", date_first: "2026-01-01", date_next: "2026-01-01", frequency: "never", amount: 5 })]);
  for (const [id, payload] of lines) db.run("INSERT INTO ynab_raw_objects(plan_id,object_type,object_id,payload_json) VALUES ('p','scheduled_subtransaction',?,?)", [id, JSON.stringify(payload)]);
  try { applyMigrations(db); console.log(label, "applied; lines:", (db.query("select count(*) n from scheduled_subtransaction_edits").get() as any).n); }
  catch (e) { console.log(label, "ABORTED", String(e).slice(0, 60), "| recorded:", (db.query("select count(*) n from schema_migrations where version like '022%'").get() as any).n); }
}
attempt("good lines", [["s1:a", { id: "a", scheduled_transaction_id: "s1", amount: -1 }], ["s1:b", { id: "b", scheduled_transaction_id: "s1", amount: -4, deleted: false }]]);
attempt("null-amount line", [["s1:a", { id: "a", scheduled_transaction_id: "s1", amount: null }]]);
attempt("deleted line only", [["s1:a", { id: "a", scheduled_transaction_id: "s1", amount: -1, deleted: true }]]);
