import { Database } from "bun:sqlite";
import { afterEach, describe, expect, test } from "bun:test";
import { AsyncReportService } from "../src/async-reports";
import { D1AuthStore } from "../src/auth-store";
import { D1LedgerRepository } from "../src/d1-ledger-repository";
import { createHandler } from "../src/http";
import { newSession, passwordCredential } from "../src/password-auth";
import { LedgerRepository } from "../src/repository";
import { CountingD1Database, fakeD1Binding } from "./helpers/counting-d1";
import { compareMonthActivity } from "../../../scripts/verify-month-activity-parity";

const PLAN_ID = "p";
const UNIT = "";

const databases: Database[] = [];
afterEach(() => { for (const db of databases.splice(0)) db.close(); });

/** A database with every D1 migration applied, including 0017. */
async function migrated(): Promise<Database> {
  const db = new Database(":memory:", { strict: true });
  databases.push(db);
  const directory = new URL("../d1-migrations/", import.meta.url).pathname;
  for (const file of [...new Bun.Glob("*.sql").scanSync(directory)].sort()) {
    db.exec(await Bun.file(`${directory}${file}`).text());
  }
  return db;
}

function raw(db: Database, type: string, id: string, payload: unknown): void {
  db.run(
    "INSERT OR REPLACE INTO ynab_raw_objects (plan_id, object_type, object_id, payload_json) VALUES (?, ?, ?, ?)",
    [PLAN_ID, type, id, JSON.stringify(payload)],
  );
}

/**
 * Every shape the old in-Worker loop treated specially, so the SQL backfill
 * has to agree with the reference implementation on all of them. Synthetic
 * throughout: no real payee, memo or amount appears here or in the output.
 */
function seedEdgeCases(db: Database): void {
  db.run("INSERT OR IGNORE INTO plans (id, name) VALUES (?, 'Plan')", [PLAN_ID]);

  // Plain categorised transaction.
  raw(db, "transaction", "plain", { id: "plain", date: "2026-01-05", amount: -1000, category_id: "food", deleted: false });
  // Two transactions in one category in one month must sum.
  raw(db, "transaction", "plain-2", { id: "plain-2", date: "2026-01-09", amount: -250, category_id: "food", deleted: false });
  // A deleted parent contributes nothing.
  raw(db, "transaction", "gone", { id: "gone", date: "2026-01-06", amount: -9999, category_id: "food", deleted: true });
  // A split: live subtransaction lines replace the parent line entirely.
  raw(db, "transaction", "split", { id: "split", date: "2026-01-07", amount: -3000, category_id: "legacy", deleted: false });
  raw(db, "subtransaction", `split${UNIT}a`, { id: "a", transaction_id: "split", amount: -1800, category_id: "food", deleted: false });
  raw(db, "subtransaction", `split${UNIT}b`, { id: "b", transaction_id: "split", amount: -1200, category_id: "fun", deleted: false });
  // One deleted line in a split: only the live lines count, and the parent
  // line still does not.
  raw(db, "transaction", "half-dead", { id: "half-dead", date: "2026-01-08", amount: -500, category_id: "legacy", deleted: false });
  raw(db, "subtransaction", `half-dead${UNIT}live`, { id: "live", transaction_id: "half-dead", amount: -300, category_id: "fun", deleted: false });
  raw(db, "subtransaction", `half-dead${UNIT}dead`, { id: "dead", transaction_id: "half-dead", amount: -200, category_id: "fun", deleted: true });
  // Every line of a split deleted: the parent line is used again.
  raw(db, "transaction", "all-dead", { id: "all-dead", date: "2026-01-10", amount: -700, category_id: "food", deleted: false });
  raw(db, "subtransaction", `all-dead${UNIT}x`, { id: "x", transaction_id: "all-dead", amount: -700, category_id: "fun", deleted: true });
  // Null category: stored under the sentinel, resolved at read time.
  raw(db, "transaction", "nocat", { id: "nocat", date: "2026-01-11", amount: -60, category_id: null, deleted: false });
  // Absent category key behaves like a null one.
  raw(db, "transaction", "nokey", { id: "nokey", date: "2026-01-12", amount: -40, deleted: false });
  // Present-but-empty category: dropped, as `if (!categoryID) continue` did.
  raw(db, "transaction", "emptycat", { id: "emptycat", date: "2026-01-13", amount: -55, category_id: "", deleted: false });
  // Payload with no `id`: the object_id is the transaction key.
  raw(db, "transaction", "noid", { date: "2026-01-14", amount: -80, category_id: "food", deleted: false });
  raw(db, "subtransaction", `noid${UNIT}s`, { id: "s", transaction_id: "noid", amount: -80, category_id: "fun", deleted: false });
  // Orphan subtransaction: no parent, so no month, so nothing.
  raw(db, "subtransaction", `ghost${UNIT}s`, { id: "s", transaction_id: "ghost", amount: -111, category_id: "food", deleted: false });
  // Subtransaction whose parent is deleted contributes nothing either.
  raw(db, "transaction", "dead-parent", { id: "dead-parent", date: "2026-01-15", amount: -222, category_id: "food", deleted: true });
  raw(db, "subtransaction", `dead-parent${UNIT}s`, { id: "s", transaction_id: "dead-parent", amount: -222, category_id: "food", deleted: false });
  // Subtransaction with a falsy transaction_id is ignored when grouping.
  raw(db, "subtransaction", `loose${UNIT}s`, { id: "s", transaction_id: "", amount: -333, category_id: "food", deleted: false });
  // Non-string date: skipped by both paths.
  raw(db, "transaction", "nodate", { id: "nodate", date: 20260116, amount: -444, category_id: "food", deleted: false });
  // A second month, to prove months do not bleed into each other.
  raw(db, "transaction", "feb", { id: "feb", date: "2026-02-03", amount: -2500, category_id: "food", deleted: false });
  // A non-transaction object type must be ignored entirely.
  raw(db, "month", "2026-01-01", { month: "2026-01-01", categories: [] });
}

describe("materialised YNAB month activity", () => {
  test("the migration backfill matches the raw-object scan on every edge case", async () => {
    const db = await migrated();
    seedEdgeCases(db);
    // 0017 ran against an empty database, so rebuild what the seed wrote using
    // the same statement the migration embeds.
    const { REMATERIALISE_ALL_PLANS } = await import("../src/ynab-month-activity");
    db.run(REMATERIALISE_ALL_PLANS);

    const counts = compareMonthActivity(db);
    console.log(JSON.stringify({ event: "month_activity_parity_fixture", ...counts }));

    expect(counts.mismatches).toBe(0);
    expect(counts.missing).toBe(0);
    expect(counts.extra).toBe(0);
    expect(counts.different).toBe(0);
    // A fixture that compared nothing would also report zero mismatches.
    expect(counts.rows).toBeGreaterThan(0);
    expect(counts.months).toBe(2);
    expect(counts.plans).toBe(1);
  });

  test("the backfill stores the amounts the old loop computed", async () => {
    const db = await migrated();
    seedEdgeCases(db);
    const { REMATERIALISE_ALL_PLANS } = await import("../src/ynab-month-activity");
    db.run(REMATERIALISE_ALL_PLANS);

    expect(db.query("SELECT month, category_id, activity FROM ynab_source_month_activity ORDER BY month, category_id").all()).toEqual([
      // -60 (null category) and -40 (absent key) share the sentinel. The -55
      // with a present-but-empty category is not here: it was dropped.
      { month: "2026-01-01", category_id: "", activity: -100 },
      // -1000 plain, -250 plain-2, -1800 split line a, -700 all-dead parent
      // (every one of its lines was deleted, so the parent line counts again).
      { month: "2026-01-01", category_id: "food", activity: -3750 },
      // -1200 split line b, -300 the one live line of half-dead, -80 the line
      // of the parent that carries no `id` in its payload.
      { month: "2026-01-01", category_id: "fun", activity: -1580 },
      // The split parents' own "legacy" category never appears: live lines
      // replaced it. Nor do the orphan, the dead parent's line, the loose
      // subtransaction, or the non-string date.
      { month: "2026-02-01", category_id: "food", activity: -2500 },
    ]);
  });

  test("a month view reads the materialised table and never scans raw transactions", async () => {
    const db = await migrated();
    seedEdgeCases(db);
    db.run("INSERT INTO category_groups (id, plan_id, name) VALUES ('group', ?, 'Living')", [PLAN_ID]);
    db.run("INSERT INTO categories (id, plan_id, category_group_id, name) VALUES ('food', ?, 'group', 'Food')", [PLAN_ID]);
    db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('acct', ?, 'Cash')", [PLAN_ID]);
    db.run(
      `INSERT INTO transactions (id, plan_id, account_id, category_id, date, amount_milli, cleared, updated_at)
       VALUES ('txn', ?, 'acct', 'food', '2026-01-05', -1000, 'cleared', '2026-01-05T00:00:00Z')`,
      [PLAN_ID],
    );
    const { REMATERIALISE_ALL_PLANS } = await import("../src/ynab-month-activity");
    db.run(REMATERIALISE_ALL_PLANS);

    const counting = new CountingD1Database(fakeD1Binding(db));
    const session = newSession();
    expect(await new D1AuthStore(counting).setup({
      userId: "user-1",
      username: "reader",
      credential: await passwordCredential("correct-horse-battery-staple"),
      session,
      planId: PLAN_ID,
    })).toBeTrue();

    const handler = createHandler({
      repo: new D1LedgerRepository(counting, PLAN_ID),
      reports: new AsyncReportService(counting),
      auth: new D1AuthStore(counting),
      config: { dbPath: "", port: 0, apiToken: "api-token", defaultPlanId: PLAN_ID, transitionReadOnly: false },
    });

    counting.reset();
    const response = await handler(new Request(`https://howmuch.test/v1/plans/${PLAN_ID}/months/2026-01`, {
      headers: { authorization: `Bearer ${session.token}` },
    }));
    expect(response.status).toBe(200);

    const rawStatements = counting.roundTrips.map((trip) => trip.sql).filter((sql) => sql.includes("ynab_raw_objects"));

    // The acceptance criterion in #174 is worded as "no query against
    // `ynab_raw_objects`". Three reads of that table survive and are out of
    // scope here: the month snapshot, its month_category rows, and the
    // cumulative-assignment join. All three are primary-key or key-prefix
    // lookups on `(plan_id, object_type, object_id)`, bounded by the number of
    // categories in the plan. What #174 removed is the unbounded part: the
    // whole-plan scan of `object_type = 'transaction'` and `'subtransaction'`.
    for (const sql of rawStatements) {
      expect(`${sql.includes("'transaction'")} for ${sql.slice(0, 60)}`).toBe(`false for ${sql.slice(0, 60)}`);
      expect(`${sql.includes("'subtransaction'")} for ${sql.slice(0, 60)}`).toBe(`false for ${sql.slice(0, 60)}`);
    }
    // Exactly three, and each one names the object type it looks up: the month
    // snapshot, its month_category rows, and the cumulative-assignment join
    // (which also joins on month_category). Any new entry here is a regression.
    expect(rawStatements.map((sql) => sql.match(/object_type\s*=\s*'(\w+)'/)?.[1] ?? "unscoped").sort())
      .toEqual(["month", "month_category", "month_category"]);

    // And the materialised table was read, scoped to the requested month.
    expect(counting.roundTrips.some((trip) =>
      trip.sql.includes("FROM ynab_source_month_activity") && trip.sql.includes("month = ?"))).toBeTrue();
  });

  test("an unmaterialised plan falls back to the raw scan rather than reporting no activity", async () => {
    const db = await migrated();
    seedEdgeCases(db);
    // No backfill at all: a deploy that landed before the migration.
    expect(db.query("SELECT COUNT(*) AS rows FROM ynab_source_month_activity").get()).toEqual({ rows: 0 });

    const repo = new LedgerRepository(db as any, PLAN_ID);
    const source = await (repo as any).sourceMonthActivity(PLAN_ID, "2026-01-01", "uncat");
    expect(source.get("food")).toBe(-3750);
    expect(source.get("uncat")).toBe(-100);
  });

  test("a materialised plan reports a genuinely empty month as no activity, not as unmaterialised", async () => {
    const db = await migrated();
    seedEdgeCases(db);
    const { REMATERIALISE_ALL_PLANS } = await import("../src/ynab-month-activity");
    db.run(REMATERIALISE_ALL_PLANS);

    const repo = new LedgerRepository(db as any, PLAN_ID);
    // March has no source rows, but the plan is materialised.
    const source = await (repo as any).sourceMonthActivity(PLAN_ID, "2026-03-01", "uncat");
    expect(source).not.toBeNull();
    expect(source.size).toBe(0);
  });

  test("a plan with no source objects at all still reports every ledger row as local", async () => {
    const db = await migrated();
    db.run("INSERT OR IGNORE INTO plans (id, name) VALUES (?, 'Plan')", [PLAN_ID]);
    const repo = new LedgerRepository(db as any, PLAN_ID);
    expect(await (repo as any).sourceMonthActivity(PLAN_ID, "2026-01-01", "uncat")).toBeNull();
  });

  test("rebuilding one plan clears rows a moved transaction left behind", async () => {
    const db = await migrated();
    seedEdgeCases(db);
    const repo = new LedgerRepository(db as any, PLAN_ID);
    await repo.rematerialiseYnabMonthActivity(PLAN_ID);
    expect(db.query("SELECT COUNT(*) AS rows FROM ynab_source_month_activity WHERE month = '2026-02-01'").get()).toEqual({ rows: 1 });

    // The February transaction moves to March. A per-object upsert would leave
    // the February row behind; a plan rebuild must not.
    raw(db, "transaction", "feb", { id: "feb", date: "2026-03-03", amount: -2500, category_id: "food", deleted: false });
    await repo.rematerialiseYnabMonthActivity(PLAN_ID);

    expect(db.query("SELECT COUNT(*) AS rows FROM ynab_source_month_activity WHERE month = '2026-02-01'").get()).toEqual({ rows: 0 });
    expect(db.query("SELECT activity FROM ynab_source_month_activity WHERE month = '2026-03-01' AND category_id = 'food'").get())
      .toEqual({ activity: -2500 });
    expect(compareMonthActivity(db).mismatches).toBe(0);
  });
});
