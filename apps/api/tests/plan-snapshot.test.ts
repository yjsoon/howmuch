import { afterEach, describe, expect, test } from "bun:test";
import { chunkRows, MAX_SNAPSHOT_BYTES, parsePlanSnapshot, snapshotImportStatements, SNAPSHOT_FORMAT } from "../src/plan-snapshot";
import { BACKENDS, count, markYnabMirror, nativeHarness, sessionFor, type Backend, type NativeHarness } from "./helpers/native-harness";

const harnesses: NativeHarness[] = [];
afterEach(() => { for (const harness of harnesses.splice(0)) harness.close(); });

async function open(backend: Backend): Promise<NativeHarness> {
  const harness = await nativeHarness(backend);
  harnesses.push(harness);
  return harness;
}

const LEDGER_TABLES = ["category_groups", "categories", "payees", "accounts", "transactions", "subtransactions", "scheduled_transaction_edits", "scheduled_subtransaction_edits"];

function tableCounts(harness: NativeHarness, planId = "p"): Record<string, number> {
  const result: Record<string, number> = {};
  for (const table of LEDGER_TABLES) {
    result[table] = table === "subtransactions"
      ? count(harness.db, "SELECT COUNT(*) AS n FROM subtransactions s JOIN transactions t ON t.id = s.transaction_id WHERE t.plan_id = ?", planId)
      : count(harness.db, `SELECT COUNT(*) AS n FROM ${table} WHERE plan_id = ?`, planId);
  }
  return result;
}

/** A native ledger built through the ordinary write paths, so it has real transfers and splits. */
async function seedLedger(harness: NativeHarness): Promise<void> {
  const { request, repo } = harness;
  const post = async (path: string, body: unknown) => {
    const response = await request(path, { method: "POST", body });
    if (response.status >= 300) throw new Error(`${path} ${response.status} ${await response.text()}`);
    return (await response.json()).data;
  };
  await post("/v1/plans/p/category_groups", { category_group: { id: "grp-living", name: "Living" } });
  await post("/v1/plans/p/category_groups", { category_group: { id: "grp-fun", name: "Fun", hidden: true } });
  await post("/v1/plans/p/categories", { category: { id: "cat-food", category_group_id: "grp-living", name: "Food" } });
  await post("/v1/plans/p/categories", { category: { id: "cat-rent", category_group_id: "grp-living", name: "Rent" } });
  await post("/v1/plans/p/categories", { category: { id: "cat-games", category_group_id: "grp-fun", name: "Games", hidden: true } });
  await post("/v1/plans/p/categories", { category: { id: "cat-old", category_group_id: "grp-fun", name: "Old" } });
  const everyday = await post("/v1/plans/p/accounts", { account: { id: "acct-everyday", name: "🏦 Everyday", type: "checking", balance: 100000 } });
  const card = await post("/v1/plans/p/accounts", { account: { id: "acct-card", name: "Card", type: "creditCard" } });
  await post("/v1/plans/p/accounts", { account: { id: "acct-house", name: "House", type: "otherAsset", balance: 500000000 } });
  await post("/v1/plans/p/payees", { payee: { name: "Grocer" } });
  const payees = (await (await request("/v1/plans/p/payees")).json()).data.payees;
  const grocer = payees.find((payee: any) => payee.name === "Grocer");

  await repo.createTransaction("p", { id: "t-food", account_id: "acct-everyday", date: "2026-01-03", amount: -12340, payee_id: grocer.id, category_id: "cat-food", memo: "Weekly shop", cleared: "cleared", approved: true, flag_color: "red", import_id: "bank:1" });
  await repo.createTransaction("p", { id: "t-old", account_id: "acct-card", date: "2026-01-04", amount: -500, category_id: "cat-old", cleared: "reconciled" });
  await repo.createTransaction("p", { id: "t-pay-card", account_id: "acct-everyday", date: "2026-01-05", amount: -20000, payee_id: card.account.transfer_payee_id });
  await repo.createTransaction("p", {
    id: "t-split", account_id: "acct-card", date: "2026-01-06", amount: -30000, payee_id: grocer.id,
    subtransactions: [
      { id: "s-rent", amount: -25000, category_id: "cat-rent", memo: "half" },
      { id: "s-move", amount: -5000, payee_id: everyday.account.transfer_payee_id, memo: "to everyday" },
    ],
  });
  await repo.createTransaction("p", { id: "t-gone", account_id: "acct-everyday", date: "2026-01-07", amount: -1 });
  await repo.deleteTransaction("p", "t-gone");
  await request("/v1/plans/p/categories/cat-old", { method: "DELETE" }).then(async (response) => {
    // Still used by t-old, so it stays live: the export must carry it.
    expect(response.status).toBe(409);
  });
  await repo.createScheduledTransaction("p", { id: "sched-rent", account_id: "acct-everyday", date_first: "2026-02-01", frequency: "monthly", amount: -250000, category_id: "cat-rent", memo: "Rent" });
  await repo.createScheduledTransaction("p", {
    id: "sched-split", account_id: "acct-card", date_first: "2026-02-10", date_next: "2026-03-10", frequency: "everyOtherMonth", amount: -3000, payee_id: grocer.id,
    subtransactions: [{ id: "ss-1", amount: -1000, category_id: "cat-food" }, { id: "ss-2", amount: -2000, category_id: "cat-games" }],
  });
}

async function exportSnapshot(harness: NativeHarness): Promise<any> {
  const response = await harness.request("/v1/plans/p/export_snapshot");
  expect(response.status).toBe(200);
  return (await response.json()).data.snapshot;
}

async function importSnapshot(harness: NativeHarness, snapshot: unknown, key = "import-snapshot-1"): Promise<Response> {
  return harness.request("/v1/plans/p/import_snapshot", { method: "POST", key, body: { snapshot } });
}

/** Everything a client reads, minus fields that are plan- or time-specific. */
async function clientView(harness: NativeHarness): Promise<unknown> {
  const read = async (path: string) => (await (await harness.request(path)).json()).data;
  const strip = (value: any): any => JSON.parse(JSON.stringify(value, (key, entry) => key === "server_knowledge" ? undefined : entry));
  return strip({
    accounts: (await read("/v1/plans/p/accounts")).accounts,
    categories: (await read("/v1/plans/p/categories")).category_groups,
    payees: (await read("/v1/plans/p/payees")).payees,
    transactions: (await read("/v1/plans/p/transactions?limit=250")).transactions,
    scheduled: (await read("/v1/plans/p/scheduled_transactions")).scheduled_transactions,
  });
}

/**
 * Accounts a, b and c with a plain transfer a -> b (t-out / t-in) and a split
 * on a whose second line (s-move) moves 500 to b as t-split-in.
 */
function transferSnapshot(): any {
  return {
    format: SNAPSHOT_FORMAT,
    version: 1,
    category_groups: [{ id: "grp", name: "Living" }],
    categories: [{ id: "cat", category_group_id: "grp", name: "Food" }],
    accounts: [{ id: "a", name: "A" }, { id: "b", name: "B" }, { id: "c", name: "C" }],
    transactions: [
      { id: "t-out", account_id: "a", date: "2026-01-01", amount: -1000, transfer_account_id: "b", transfer_transaction_id: "t-in" },
      { id: "t-in", account_id: "b", date: "2026-01-01", amount: 1000, transfer_account_id: "a", transfer_transaction_id: "t-out" },
      {
        id: "t-split", account_id: "a", date: "2026-01-02", amount: -2500,
        subtransactions: [
          { id: "s-food", amount: -2000, category_id: "cat" },
          { id: "s-move", amount: -500, transfer_account_id: "b", transfer_transaction_id: "t-split-in" },
        ],
      },
      { id: "t-split-in", account_id: "b", date: "2026-01-02", amount: 500, transfer_account_id: "a", transfer_transaction_id: "s-move" },
    ],
  };
}

describe("snapshot core", () => {
  test("rejects the wrong format, version, unknown sections and dangling references", () => {
    const base = { format: SNAPSHOT_FORMAT, version: 1 };
    expect(() => parsePlanSnapshot({ ...base, format: "ynab" }, "p")).toThrow("snapshot.format");
    expect(() => parsePlanSnapshot({ ...base, version: 2 }, "p")).toThrow("snapshot.version");
    expect(() => parsePlanSnapshot({ ...base, month_assignments: [] }, "p")).toThrow("month_assignments");
    expect(() => parsePlanSnapshot({ ...base, categories: [{ id: "c", category_group_id: "missing", name: "x" }] }, "p")).toThrow("category_group_id");
    expect(() => parsePlanSnapshot({ ...base, accounts: [{ id: "a", name: "A" }], transactions: [{ id: "t", account_id: "a", date: "2026-01-01", amount: 1, category_id: "nope" }] }, "p")).toThrow("category_id");
    expect(() => parsePlanSnapshot({ ...base, accounts: [{ id: "a", name: "A" }], transactions: [{ id: "t", account_id: "a", date: "2026-02-30", amount: 1 }] }, "p")).toThrow("valid calendar date");
    expect(() => parsePlanSnapshot({ ...base, accounts: [{ id: "a", name: "A" }], transactions: [{ id: "t", account_id: "a", date: "2026-01-01", amount: 1.5 }] }, "p")).toThrow("milliunits");
    expect(() => parsePlanSnapshot({ ...base, accounts: [{ id: "a", name: "A" }], transactions: [{ id: "t", account_id: "a", date: "2026-01-01", amount: -3, subtransactions: [{ id: "s1", amount: -1 }, { id: "s2", amount: -1 }] }] }, "p")).toThrow("subtransactions total");
    expect(() => parsePlanSnapshot({ ...base, accounts: [{ id: "a", name: "A" }, { id: "a", name: "B" }] }, "p")).toThrow("duplicated");
    expect(() => parsePlanSnapshot({ ...base, accounts: [{ id: "a", name: "A" }], transactions: [{ id: "t", account_id: "a", date: "2026-01-01", amount: 1, transfer_transaction_id: "ghost" }] }, "p")).toThrow("transfer_transaction_id");
  });

  test("provisions a missing transfer payee with a plan-stable id", () => {
    const rows = parsePlanSnapshot({ format: SNAPSHOT_FORMAT, version: 1, accounts: [{ id: "a", name: "Cash", type: "cash" }] }, "p");
    expect(rows.accounts[0]).toMatchObject({ id: "a", name: "Cash", on_budget: 1, transfer_payee_id: expect.stringMatching(/^payee_transfer_/) });
    expect(rows.payees).toEqual([{ id: rows.accounts[0]!.transfer_payee_id, name: "Transfer : Cash", transfer_account_id: "a", deleted: 0 }]);
    expect(parsePlanSnapshot({ format: SNAPSHOT_FORMAT, version: 1, accounts: [{ id: "a", name: "Cash", type: "cash" }] }, "p").payees).toEqual(rows.payees);
  });

  test("accepts transfer links shaped like the server's own transfers", () => {
    const rows = parsePlanSnapshot(transferSnapshot(), "p");
    expect(rows.transactions.map((row) => [row.id, row.transfer_transaction_id])).toEqual([
      ["t-out", "t-in"], ["t-in", "t-out"], ["t-split", null], ["t-split-in", "s-move"],
    ]);
    expect(rows.subtransactions.find((row) => row.id === "s-move")).toMatchObject({ transfer_account_id: "b", transfer_transaction_id: "t-split-in" });
  });

  test("rejects transfer links that break the counterpart invariants", () => {
    const broken = (edit: (snapshot: any) => void) => {
      const snapshot = transferSnapshot();
      edit(snapshot);
      return () => parsePlanSnapshot(snapshot, "p");
    };
    const txn = (snapshot: any, id: string) => snapshot.transactions.find((row: any) => row.id === id);
    const sub = (snapshot: any, id: string) => snapshot.transactions.flatMap((row: any) => row.subtransactions ?? []).find((row: any) => row.id === id);

    expect(broken((s) => { txn(s, "t-in").transfer_transaction_id = null; })).toThrow("counterpart t-in does not link back to t-out");
    expect(broken((s) => { txn(s, "t-out").transfer_account_id = null; })).toThrow("transfer_account_id is required");
    expect(broken((s) => { txn(s, "t-out").transfer_account_id = "c"; })).toThrow("counterpart t-in is in account b, not transfer_account_id c");
    expect(broken((s) => { txn(s, "t-in").amount = 999; })).toThrow("counterpart t-in has amount 999; it must be 1000");
    expect(broken((s) => { txn(s, "t-in").transfer_account_id = "c"; })).toThrow("counterpart t-in must name account a as its transfer_account_id");

    expect(broken((s) => { txn(s, "t-split-in").transfer_transaction_id = null; })).toThrow("counterpart t-split-in does not link back to s-move");
    // Transactions are checked before split lines, so the top-level side reports.
    expect(broken((s) => { txn(s, "t-split-in").account_id = "c"; })).toThrow("counterpart s-move must name account c as its transfer_account_id");
    expect(broken((s) => { txn(s, "t-split-in").amount = 1; })).toThrow("counterpart s-move has amount -500; it must be -1");
    expect(broken((s) => { txn(s, "t-split-in").transfer_account_id = "b"; })).toThrow("counterpart s-move is in account a, not transfer_account_id b");
    expect(broken((s) => { sub(s, "s-move").transfer_account_id = "c"; })).toThrow("transactions[3].transfer_transaction_id: counterpart s-move must name account b");
    expect(broken((s) => {
      // Only the split line is broken, so its own path reports.
      sub(s, "s-move").transfer_account_id = null;
    })).toThrow("transactions[2].subtransactions[1].transfer_transaction_id is set, so transfer_account_id is required");
    expect(broken((s) => {
      // Two split lines pointing at each other are never produced by the server.
      s.transactions.push({ id: "t-split-2", account_id: "b", date: "2026-01-02", amount: 500, subtransactions: [
        { id: "s-back", amount: 500, transfer_account_id: "a", transfer_transaction_id: "s-move" },
      ] });
      sub(s, "s-move").transfer_transaction_id = "s-back";
      s.transactions = s.transactions.filter((row: any) => row.id !== "t-split-in");
    })).toThrow("must be a transaction, not another split line");
  });

  test("chunks rows by bytes, so statement count follows size rather than row count", () => {
    const rows = Array.from({ length: 100 }, (_, index) => ({ id: `row-${index}`, memo: "x".repeat(90) }));
    const chunks = chunkRows(rows, 2048);
    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.every((chunk) => new TextEncoder().encode(chunk).length <= 2048)).toBeTrue();
    expect(chunks.flatMap((chunk) => JSON.parse(chunk))).toEqual(rows);
    expect(chunkRows([{ id: "big", memo: "y".repeat(5000) }], 2048)).toHaveLength(1);

    const snapshot = { format: SNAPSHOT_FORMAT, version: 1, accounts: [{ id: "a", name: "A" }] };
    const small = parsePlanSnapshot({ ...snapshot, transactions: Array.from({ length: 5 }, (_, index) => ({ id: `t${index}`, account_id: "a", date: "2026-01-01", amount: -1 })) }, "p");
    const large = parsePlanSnapshot({ ...snapshot, transactions: Array.from({ length: 500 }, (_, index) => ({ id: `t${index}`, account_id: "a", date: "2026-01-01", amount: -1 })) }, "p");
    expect(snapshotImportStatements("p", large, "audit", "hash").length).toBe(snapshotImportStatements("p", small, "audit", "hash").length);
  });
});

for (const backend of BACKENDS) {
  describe(`${backend} plan snapshots`, () => {
    test("export then import into an empty plan round-trips the ledger", async () => {
      const source = await open(backend);
      await seedLedger(source);
      const exported = await exportSnapshot(source);
      expect(exported.format).toBe(SNAPSHOT_FORMAT);
      expect(exported.version).toBe(1);
      expect(exported.transactions.map((transaction: any) => transaction.id)).not.toContain("t-gone");
      expect(exported).not.toHaveProperty("month_assignments");

      const target = await open(backend);
      const imported = await importSnapshot(target, exported);
      expect(imported.status).toBe(201);
      const body = (await imported.json()).data;
      expect(body.replayed).toBeFalse();
      expect(body.imported).toMatchObject({ accounts: 3, transactions: exported.transactions.length, scheduled_transactions: 2 });

      expect(await exportSnapshot(target)).toEqual(exported);
      expect(await clientView(target)).toEqual(await clientView(source));
      expect(count(target.db, "SELECT COUNT(*) AS n FROM audit_events WHERE action = 'plan.snapshot.import'")).toBe(1);
    });

    test("an exact retry replays; a different body under the same key conflicts", async () => {
      const source = await open(backend);
      await seedLedger(source);
      const exported = await exportSnapshot(source);
      const target = await open(backend);
      expect((await importSnapshot(target, exported)).status).toBe(201);
      const before = tableCounts(target);
      const retry = await importSnapshot(target, exported);
      expect(retry.status).toBe(201);
      expect((await retry.json()).data.replayed).toBeTrue();
      expect(tableCounts(target)).toEqual(before);
      const reused = await importSnapshot(target, { ...exported, transactions: exported.transactions.map((transaction: any) => ({ ...transaction, memo: "changed" })) });
      expect(reused.status).toBe(409);
      const fresh = await importSnapshot(target, exported, "import-snapshot-2");
      expect(fresh.status).toBe(409);
      expect((await fresh.json()).error.name).toBe("plan_not_empty");
    });

    test("refuses a plan that already has accounts, but allows internal categories", async () => {
      const source = await open(backend);
      await seedLedger(source);
      const exported = await exportSnapshot(source);

      const occupied = await open(backend);
      await occupied.repo.createAccount("p", { id: "existing", name: "Existing" });
      const refused = await importSnapshot(occupied, exported);
      expect(refused.status).toBe(409);
      expect((await refused.json()).error.name).toBe("plan_not_empty");

      const internalOnly = await open(backend);
      internalOnly.db.run("INSERT INTO category_groups (id, plan_id, name, internal) VALUES ('int-grp', 'p', 'Internal Master Category', 1)");
      internalOnly.db.run("INSERT INTO categories (id, plan_id, category_group_id, name, internal) VALUES ('int-rta', 'p', 'int-grp', 'Inflow: Ready to Assign', 1)");
      expect((await importSnapshot(internalOnly, exported)).status).toBe(201);
    });

    test("a user category group or a payee makes the plan non-empty; a fresh plan is accepted", async () => {
      const snapshot = transferSnapshot();

      const withGroup = await open(backend);
      const group = await withGroup.request("/v1/plans/p/category_groups", { method: "POST", body: { category_group: { id: "grp-empty", name: "Someday" } } });
      expect(group.status).toBe(201);
      const refusedGroup = await importSnapshot(withGroup, snapshot);
      expect(refusedGroup.status).toBe(409);
      expect((await refusedGroup.json()).error.name).toBe("plan_not_empty");
      expect(count(withGroup.db, "SELECT COUNT(*) AS n FROM accounts WHERE plan_id = 'p'")).toBe(0);

      const withPayee = await open(backend);
      expect((await withPayee.request("/v1/plans/p/payees", { method: "POST", body: { payee: { name: "Grocer" } } })).status).toBeLessThan(300);
      const refusedPayee = await importSnapshot(withPayee, snapshot);
      expect(refusedPayee.status).toBe(409);
      expect((await refusedPayee.json()).error.name).toBe("plan_not_empty");
      expect(count(withPayee.db, "SELECT COUNT(*) AS n FROM accounts WHERE plan_id = 'p'")).toBe(0);

      const fresh = await open(backend);
      expect(tableCounts(fresh)).toEqual(Object.fromEntries(LEDGER_TABLES.map((table) => [table, 0])));
      expect((await importSnapshot(fresh, snapshot)).status).toBe(201);
    });

    test("plain and split transfers round-trip; a broken link is 400 and writes nothing", async () => {
      const target = await open(backend);
      const bad = transferSnapshot();
      bad.transactions[1].amount = 999;
      const refused = await importSnapshot(target, bad, "bad-transfer-1");
      expect(refused.status).toBe(400);
      expect((await refused.json()).error.detail).toContain("counterpart t-in has amount 999; it must be 1000");
      expect(tableCounts(target)).toEqual(Object.fromEntries(LEDGER_TABLES.map((table) => [table, 0])));

      expect((await importSnapshot(target, transferSnapshot())).status).toBe(201);
      const exported = await exportSnapshot(target);
      const byId = Object.fromEntries(exported.transactions.map((row: any) => [row.id, row]));
      expect(byId["t-out"]).toMatchObject({ account_id: "a", amount: -1000, transfer_account_id: "b", transfer_transaction_id: "t-in" });
      expect(byId["t-in"]).toMatchObject({ account_id: "b", amount: 1000, transfer_account_id: "a", transfer_transaction_id: "t-out" });
      expect(byId["t-split"].subtransactions[1]).toMatchObject({ id: "s-move", amount: -500, transfer_account_id: "b", transfer_transaction_id: "t-split-in" });
      expect(byId["t-split-in"]).toMatchObject({ account_id: "b", amount: 500, transfer_account_id: "a", transfer_transaction_id: "s-move" });

      const again = await open(backend);
      expect((await importSnapshot(again, exported)).status).toBe(201);
      expect(await exportSnapshot(again)).toEqual(exported);
    });

    test("refuses a YNAB-mirror plan with 409 ynab_mirror_plan and writes nothing", async () => {
      const source = await open(backend);
      await seedLedger(source);
      const exported = await exportSnapshot(source);
      const mirror = await open(backend);
      markYnabMirror(mirror.db);
      const before = tableCounts(mirror);
      const refused = await importSnapshot(mirror, exported);
      expect(refused.status).toBe(409);
      expect((await refused.json()).error.name).toBe("ynab_mirror_plan");
      expect(tableCounts(mirror)).toEqual(before);
    });

    test("an id owned by another plan aborts the whole import", async () => {
      const source = await open(backend);
      await seedLedger(source);
      const exported = await exportSnapshot(source);
      const target = await open(backend);
      target.db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('other-acct', 'q', 'Theirs')");
      target.db.run("INSERT INTO transactions (id, plan_id, account_id, date, amount_milli) VALUES ('t-split', 'q', 'other-acct', '2026-01-01', -1)");
      const knowledge = target.db.query("SELECT server_knowledge FROM plans WHERE id = 'p'").get();
      const refused = await importSnapshot(target, exported);
      expect(refused.status).toBe(409);
      expect((await refused.json()).error.name).toBe("conflict");
      expect(tableCounts(target)).toEqual(Object.fromEntries(LEDGER_TABLES.map((table) => [table, 0])));
      expect(target.db.query("SELECT server_knowledge FROM plans WHERE id = 'p'").get()).toEqual(knowledge);
      expect(target.db.query("SELECT plan_id, amount_milli FROM transactions WHERE id = 't-split'").get()).toEqual({ plan_id: "q", amount_milli: -1 });
    });

    test("invalid snapshots are 400 and change nothing", async () => {
      const target = await open(backend);
      const bad = await importSnapshot(target, { format: SNAPSHOT_FORMAT, version: 1, accounts: [{ id: "a", name: "A" }], transactions: [{ id: "t", account_id: "missing", date: "2026-01-01", amount: -1 }] });
      expect(bad.status).toBe(400);
      expect((await target.request("/v1/plans/p/import_snapshot", { method: "POST", body: { snapshot: { format: SNAPSHOT_FORMAT, version: 1 } } })).status).toBe(400);
      expect((await target.request("/v1/plans/p/import_snapshot", { method: "POST", key: "no-snapshot-1", body: {} })).status).toBe(400);
      expect(tableCounts(target)).toEqual(Object.fromEntries(LEDGER_TABLES.map((table) => [table, 0])));
    });

    test("import is owner-only and export excludes viewers", async () => {
      const source = await open(backend);
      await seedLedger(source);
      const editor = sessionFor(source.db, "editor");
      const viewer = sessionFor(source.db, "viewer");
      expect((await source.request("/v1/plans/p/export_snapshot", { token: editor })).status).toBe(200);
      expect((await source.request("/v1/plans/p/export_snapshot", { token: viewer })).status).toBe(403);
      const target = await open(backend);
      const exported = await exportSnapshot(source);
      const editorImport = await target.request("/v1/plans/p/import_snapshot", { method: "POST", key: "editor-import-1", token: sessionFor(target.db, "editor"), body: { snapshot: exported } });
      expect(editorImport.status).toBe(403);
      const ownerImport = await target.request("/v1/plans/p/import_snapshot", { method: "POST", key: "owner-import-1", token: sessionFor(target.db, "owner"), body: { snapshot: exported } });
      expect(ownerImport.status).toBe(201);
    });
  });
}

describe("snapshot request size", () => {
  test("bodies over 8 MiB are 413 and write nothing", async () => {
    const target = await open("SQLite");
    const oversized = JSON.stringify({ snapshot: { format: SNAPSHOT_FORMAT, version: 1, padding: "x".repeat(MAX_SNAPSHOT_BYTES) } });
    expect(MAX_SNAPSHOT_BYTES).toBe(8 * 1024 * 1024);
    const response = await target.request("/v1/plans/p/import_snapshot", { method: "POST", key: "too-big-1", body: oversized });
    expect(response.status).toBe(413);
    expect((await response.json()).error.name).toBe("payload_too_large");
    expect(tableCounts(target)).toEqual(Object.fromEntries(LEDGER_TABLES.map((table) => [table, 0])));
  });
});

describe("snapshots cross backends", () => {
  test("a SQLite export imports into D1 and exports identically, and back again", async () => {
    const sqlite = await open("SQLite");
    await seedLedger(sqlite);
    const fromSqlite = await exportSnapshot(sqlite);
    const d1 = await open("D1");
    expect((await importSnapshot(d1, fromSqlite)).status).toBe(201);
    expect(await exportSnapshot(d1)).toEqual(fromSqlite);
    const sqliteAgain = await open("SQLite");
    expect((await importSnapshot(sqliteAgain, await exportSnapshot(d1))).status).toBe(201);
    expect(await exportSnapshot(sqliteAgain)).toEqual(fromSqlite);
    expect(await clientView(sqliteAgain)).toEqual(await clientView(d1));
  });
});

describe("D1 snapshot import is one atomic batch", () => {
  test("a large ledger lands in a single guarded write", async () => {
    const target = await open("D1");
    const transactions = Array.from({ length: 3000 }, (_, index) => ({
      id: `txn-${String(index).padStart(5, "0")}`,
      account_id: "acct",
      date: `2026-${String((index % 12) + 1).padStart(2, "0")}-15`,
      amount: -(index + 1) * 10,
      memo: `Memo ${index} ${"m".repeat(120)}`,
      cleared: index % 3 === 0 ? "cleared" : "uncleared",
      category_id: "cat",
    }));
    const snapshot = {
      format: SNAPSHOT_FORMAT,
      version: 1,
      category_groups: [{ id: "grp", name: "Living" }],
      categories: [{ id: "cat", category_group_id: "grp", name: "Food" }],
      accounts: [{ id: "acct", name: "Everyday", type: "checking", opening_balance: 1_000_000 }],
      transactions,
    };
    target.batches.length = 0;
    const response = await importSnapshot(target, snapshot);
    expect(response.status).toBe(201);
    const writes = target.batches.filter((size) => size > 1);
    expect(writes).toHaveLength(1);
    expect(count(target.db, "SELECT COUNT(*) AS n FROM transactions WHERE plan_id = 'p'")).toBe(3000);
    const expectedBalance = 1_000_000 - transactions.reduce((sum, transaction) => sum - transaction.amount, 0);
    expect(target.db.query("SELECT balance_milli FROM accounts WHERE id = 'acct'").get()).toEqual({ balance_milli: expectedBalance });
    expect(count(target.db, "SELECT COUNT(DISTINCT month) AS n FROM account_month_balances WHERE plan_id = 'p'")).toBe(12);
  });

  test("a plan that fills up after the preflight aborts the batch", async () => {
    const target = await open("D1");
    const racing = target.repo as any;
    const requireEmpty = racing.requireEmptyPlan.bind(racing);
    let raced = false;
    racing.requireEmptyPlan = async (planId: string) => {
      await requireEmpty(planId);
      if (!raced) {
        raced = true;
        target.db.run("INSERT INTO accounts (id, plan_id, name) VALUES ('late', 'p', 'Late')");
      }
    };
    const response = await importSnapshot(target, { format: SNAPSHOT_FORMAT, version: 1, accounts: [{ id: "acct", name: "Everyday" }] });
    expect(response.status).toBe(409);
    expect((await response.json()).error.name).toBe("plan_not_empty");
    expect(count(target.db, "SELECT COUNT(*) AS n FROM accounts WHERE plan_id = 'p'")).toBe(1);
  });

  test("a payee or user category group that lands after the preflight also aborts the batch", async () => {
    for (const late of [
      "INSERT INTO payees (id, plan_id, name) VALUES ('late', 'p', 'Late')",
      "INSERT INTO category_groups (id, plan_id, name) VALUES ('late', 'p', 'Late')",
    ]) {
      const target = await open("D1");
      const racing = target.repo as any;
      const requireEmpty = racing.requireEmptyPlan.bind(racing);
      let raced = false;
      racing.requireEmptyPlan = async (planId: string) => {
        await requireEmpty(planId);
        if (!raced) {
          raced = true;
          target.db.run(late);
        }
      };
      const response = await importSnapshot(target, { format: SNAPSHOT_FORMAT, version: 1, accounts: [{ id: "acct", name: "Everyday" }] });
      expect(response.status).toBe(409);
      expect((await response.json()).error.name).toBe("plan_not_empty");
      expect(count(target.db, "SELECT COUNT(*) AS n FROM accounts WHERE plan_id = 'p'")).toBe(0);
    }
  });
});
