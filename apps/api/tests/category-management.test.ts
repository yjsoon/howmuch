import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { applyMigrations } from "../src/db";
import { createHandler } from "../src/http";
import { LedgerRepository } from "../src/repository";
import type { D1MetadataRepository } from "../src/d1-metadata-repository";
import {
  parseCategoryCreate,
  parseCategoryGroupCreate,
  parseCategoryGroupPatch,
  parseCategoryPatch,
  updateCategoryCommand,
} from "../src/category-management";
import { API_TOKEN, BACKENDS, count, markYnabMirror, nativeHarness, type NativeHarness } from "./helpers/native-harness";

const harnesses: NativeHarness[] = [];
afterEach(() => { for (const harness of harnesses.splice(0)) harness.close(); });

async function open(backend: (typeof BACKENDS)[number]): Promise<NativeHarness> {
  const harness = await nativeHarness(backend);
  harnesses.push(harness);
  return harness;
}

describe("category input parsing", () => {
  test("normalises names and defaults hidden to false", () => {
    expect(parseCategoryGroupCreate({ name: "  Bills " })).toEqual({ name: "Bills", hidden: false });
    expect(parseCategoryCreate({ id: "cat-1", category_group_id: "grp-1", name: "Rent", hidden: true }))
      .toEqual({ id: "cat-1", category_group_id: "grp-1", name: "Rent", hidden: true });
    expect(parseCategoryPatch({ category_group_id: "grp-2" })).toEqual({ category_group_id: "grp-2" });
  });

  test("rejects unknown fields, empty patches, bad ids and bad names", () => {
    expect(() => parseCategoryGroupCreate({ name: "Bills", budgeted: 1 })).toThrow("category_group.budgeted cannot be set");
    expect(() => parseCategoryGroupPatch({})).toThrow("is required");
    expect(() => parseCategoryPatch({})).toThrow("is required");
    expect(() => parseCategoryCreate({ id: "has space", category_group_id: "g", name: "x" })).toThrow("category.id");
    expect(() => parseCategoryCreate({ id: "#guard/x", category_group_id: "g", name: "x" })).toThrow("category.id");
    expect(() => parseCategoryCreate({ category_group_id: "g", name: "   " })).toThrow("category.name");
    expect(() => parseCategoryCreate({ category_group_id: "g", name: "x".repeat(101) })).toThrow("category.name");
    expect(() => parseCategoryGroupCreate({ name: "x", hidden: "yes" })).toThrow("must be a boolean");
    expect(() => parseCategoryGroupCreate(undefined)).toThrow("category_group is required");
  });

  test("internal categories cannot be changed", () => {
    const internal = { id: "c", plan_id: "p", name: "Inflow", hidden: 0, internal: 1, deleted: 0, category_group_id: "g" };
    expect(() => updateCategoryCommand("p", internal, { name: "x" }, null)).toThrow("Internal categories");
  });
});

// D1 plans commands before its atomic batch. Two disjoint PATCHes must not
// copy stale values for fields omitted from the first request.
for (const resource of ["category_group", "category"] as const) {
  test(`D1 concurrent ${resource} patches preserve disjoint changes`, async () => {
    const { request, db, repo } = await open("D1");
    db.run("INSERT INTO category_groups (id, plan_id, name) VALUES ('g1', 'p', 'Original'), ('g2', 'p', 'Other')");
    db.run("INSERT INTO categories (id, plan_id, category_group_id, name) VALUES ('c', 'p', 'g1', 'Original')");
    const metadata = (repo as unknown as { metadata: D1MetadataRepository }).metadata;
    const apply = metadata.applyNativeCommand.bind(metadata);
    let release!: () => void;
    let arrived!: () => void;
    const held = new Promise<void>((resolve) => { arrived = resolve; });
    const resume = new Promise<void>((resolve) => { release = resolve; });
    let pauseNext = true;
    metadata.applyNativeCommand = async (...args) => {
      if (pauseNext && args[0] === `${resource}.update`) {
        pauseNext = false;
        arrived();
        await resume;
      }
      return apply(...args);
    };
    const path = resource === "category" ? "/v1/plans/p/categories/c" : "/v1/plans/p/category_groups/g1";
    const rename = request(path, { method: "PATCH", body: { [resource]: { name: "Renamed" } } });
    await held;
    try {
      const other = await request(path, {
        method: "PATCH",
        body: { [resource]: { hidden: true, ...(resource === "category" ? { category_group_id: "g2" } : {}) } },
      });
      expect(other.status).toBe(200);
    } finally {
      release();
    }
    expect((await rename).status).toBe(200);
    const actual = resource === "category"
      ? db.query("SELECT name, hidden, category_group_id FROM categories WHERE id='c'").get()
      : db.query("SELECT name, hidden FROM category_groups WHERE id='g1'").get();
    expect(actual).toEqual({ name: "Renamed", hidden: 1, ...(resource === "category" ? { category_group_id: "g2" } : {}) });
  });
}

for (const backend of BACKENDS) {
  describe(`${backend} category management`, () => {
    test("creates, renames, hides and moves groups and categories", async () => {
      const { request, db } = await open(backend);
      const knowledgeBefore = count(db, "SELECT server_knowledge AS n FROM plans WHERE id = 'p'");

      const group = await request("/v1/plans/p/category_groups", { method: "POST", body: { category_group: { id: "grp-bills", name: "Bills" } } });
      expect(group.status).toBe(201);
      const groupBody = await group.json();
      expect(groupBody.data.category_group).toEqual({ id: "grp-bills", name: "Bills", hidden: false, deleted: false, categories: [] });
      expect(groupBody.data.server_knowledge).toBeGreaterThan(knowledgeBefore);

      const second = await request("/v1/plans/p/category_groups", { method: "POST", body: { category_group: { id: "grp-fun", name: "Fun" } } });
      expect(second.status).toBe(201);

      const category = await request("/v1/plans/p/categories", { method: "POST", body: { category: { id: "cat-rent", category_group_id: "grp-bills", name: "Rent" } } });
      expect(category.status).toBe(201);
      expect((await category.json()).data.category).toMatchObject({ id: "cat-rent", category_group_id: "grp-bills", name: "Rent", hidden: false, deleted: false });

      const renamed = await request("/v1/plans/p/categories/cat-rent", { method: "PATCH", body: { category: { name: "Housing", hidden: true, category_group_id: "grp-fun" } } });
      expect(renamed.status).toBe(200);
      expect((await renamed.json()).data.category).toMatchObject({ id: "cat-rent", category_group_id: "grp-fun", name: "Housing", hidden: true });

      const groupPatch = await request("/v1/plans/p/category_groups/grp-bills", { method: "PATCH", body: { category_group: { name: "Monthly bills", hidden: true } } });
      expect(groupPatch.status).toBe(200);
      expect((await groupPatch.json()).data.category_group).toMatchObject({ id: "grp-bills", name: "Monthly bills", hidden: true });

      const listed = await (await request("/v1/plans/p/categories")).json();
      const fun = listed.data.category_groups.find((entry: any) => entry.id === "grp-fun");
      expect(fun.categories.map((entry: any) => entry.id)).toEqual(["cat-rent"]);
      expect(count(db, "SELECT COUNT(*) AS n FROM audit_events WHERE plan_id = 'p' AND action LIKE 'category%'")).toBe(5);
    });

    test("generates stable ids from the Idempotency-Key and replays retries", async () => {
      const { request, db } = await open(backend);
      const first = await request("/v1/plans/p/category_groups", { method: "POST", key: "group-create-1", body: { category_group: { name: "Bills" } } });
      const retry = await request("/v1/plans/p/category_groups", { method: "POST", key: "group-create-1", body: { category_group: { name: "Bills" } } });
      expect(first.status).toBe(201);
      expect(retry.status).toBe(201);
      const firstGroup = (await first.json()).data.category_group;
      expect((await retry.json()).data.category_group).toEqual(firstGroup);
      expect(firstGroup.id).toMatch(/^category_group_[0-9a-f]{24}$/);
      expect(count(db, "SELECT COUNT(*) AS n FROM category_groups WHERE plan_id = 'p'")).toBe(1);
      expect(count(db, "SELECT COUNT(*) AS n FROM audit_events WHERE action = 'category_group.create'")).toBe(1);

      const reused = await request("/v1/plans/p/category_groups", { method: "POST", key: "group-create-1", body: { category_group: { name: "Other" } } });
      expect(reused.status).toBe(409);
    });

    test("rejects duplicate ids, including ids owned by another plan", async () => {
      const { request, db } = await open(backend);
      db.run("INSERT INTO category_groups (id, plan_id, name) VALUES ('grp-other', 'q', 'Theirs')");
      db.run("INSERT INTO categories (id, plan_id, category_group_id, name) VALUES ('cat-other', 'q', 'grp-other', 'Theirs')");
      const stolenGroup = await request("/v1/plans/p/category_groups", { method: "POST", body: { category_group: { id: "grp-other", name: "Mine" } } });
      expect(stolenGroup.status).toBe(409);
      await request("/v1/plans/p/category_groups", { method: "POST", body: { category_group: { id: "grp", name: "Mine" } } });
      const stolenCategory = await request("/v1/plans/p/categories", { method: "POST", body: { category: { id: "cat-other", category_group_id: "grp", name: "Mine" } } });
      expect(stolenCategory.status).toBe(409);
      const foreignGroup = await request("/v1/plans/p/categories", { method: "POST", body: { category: { id: "cat-x", category_group_id: "grp-other", name: "Mine" } } });
      expect(foreignGroup.status).toBe(400);
      const foreignPatch = await request("/v1/plans/p/categories/cat-other", { method: "PATCH", body: { category: { name: "Mine" } } });
      expect(foreignPatch.status).toBe(404);
      expect(db.query("SELECT plan_id, name FROM categories WHERE id = 'cat-other'").get()).toEqual({ plan_id: "q", name: "Theirs" });
      expect(db.query("SELECT plan_id, name FROM category_groups WHERE id = 'grp-other'").get()).toEqual({ plan_id: "q", name: "Theirs" });
    });

    test("soft-deletes an unused category and refuses one still in use", async () => {
      const { request, db, repo } = await open(backend);
      await request("/v1/plans/p/category_groups", { method: "POST", body: { category_group: { id: "grp", name: "Living" } } });
      await request("/v1/plans/p/categories", { method: "POST", body: { category: { id: "cat-used", category_group_id: "grp", name: "Food" } } });
      await request("/v1/plans/p/categories", { method: "POST", body: { category: { id: "cat-split", category_group_id: "grp", name: "Split" } } });
      await request("/v1/plans/p/categories", { method: "POST", body: { category: { id: "cat-free", category_group_id: "grp", name: "Spare" } } });
      await repo.createAccount("p", { id: "acct", name: "Cash", type: "cash" });
      await repo.createTransaction("p", { id: "t1", account_id: "acct", date: "2026-01-02", amount: -1000, category_id: "cat-used" });
      await repo.createTransaction("p", {
        id: "t2", account_id: "acct", date: "2026-01-03", amount: -3000,
        subtransactions: [{ amount: -1000, category_id: "cat-split" }, { amount: -2000, category_id: "cat-used" }],
      });

      for (const id of ["cat-used", "cat-split"]) {
        const refused = await request(`/v1/plans/p/categories/${id}`, { method: "DELETE" });
        expect(refused.status).toBe(409);
        expect((await refused.json()).error.name).toBe("category_in_use");
      }
      const deleted = await request("/v1/plans/p/categories/cat-free", { method: "DELETE" });
      expect(deleted.status).toBe(200);
      expect((await deleted.json()).data.category).toMatchObject({ id: "cat-free", deleted: true });
      const again = await request("/v1/plans/p/categories/cat-free", { method: "DELETE" });
      expect(again.status).toBe(404);

      await repo.deleteTransaction("p", "t2");
      const afterDelete = await request("/v1/plans/p/categories/cat-split", { method: "DELETE" });
      expect(afterDelete.status).toBe(200);
      expect(count(db, "SELECT COUNT(*) AS n FROM categories WHERE plan_id = 'p' AND deleted = 0")).toBe(1);
    });

    test("refuses a category named by a live schedule", async () => {
      const { request, repo } = await open(backend);
      await request("/v1/plans/p/category_groups", { method: "POST", body: { category_group: { id: "grp", name: "Living" } } });
      await request("/v1/plans/p/categories", { method: "POST", body: { category: { id: "cat-sched", category_group_id: "grp", name: "Rent" } } });
      await repo.createAccount("p", { id: "acct", name: "Cash", type: "cash" });
      await repo.createScheduledTransaction("p", { id: "s1", account_id: "acct", date_first: "2026-02-01", frequency: "monthly", amount: -5000, category_id: "cat-sched" });
      const refused = await request("/v1/plans/p/categories/cat-sched", { method: "DELETE" });
      expect(refused.status).toBe(409);
    });

    test("internal categories and groups are read-only", async () => {
      const { request, db } = await open(backend);
      db.run("INSERT INTO category_groups (id, plan_id, name, internal) VALUES ('internal-grp', 'p', 'Internal Master Category', 1)");
      db.run("INSERT INTO categories (id, plan_id, category_group_id, name, internal) VALUES ('internal-cat', 'p', 'internal-grp', 'Inflow: Ready to Assign', 1)");
      expect((await request("/v1/plans/p/categories/internal-cat", { method: "PATCH", body: { category: { name: "x" } } })).status).toBe(400);
      expect((await request("/v1/plans/p/categories/internal-cat", { method: "DELETE" })).status).toBe(400);
      expect((await request("/v1/plans/p/category_groups/internal-grp", { method: "PATCH", body: { category_group: { name: "x" } } })).status).toBe(400);
      expect((await request("/v1/plans/p/categories", { method: "POST", body: { category: { category_group_id: "internal-grp", name: "x" } } })).status).toBe(400);
      expect(db.query("SELECT name FROM categories WHERE id = 'internal-cat'").get()).toEqual({ name: "Inflow: Ready to Assign" });
    });

    test("returns 409 ynab_mirror_plan and changes nothing on a YNAB-mirror plan", async () => {
      const { request, db } = await open(backend);
      db.run("INSERT INTO category_groups (id, plan_id, name) VALUES ('ynab-grp', 'p', 'Imported')");
      db.run("INSERT INTO categories (id, plan_id, category_group_id, name) VALUES ('ynab-cat', 'p', 'ynab-grp', 'Groceries')");
      markYnabMirror(db);
      const snapshot = () => ({
        groups: db.query("SELECT * FROM category_groups ORDER BY id").all(),
        categories: db.query("SELECT * FROM categories ORDER BY id").all(),
        knowledge: db.query("SELECT server_knowledge FROM plans WHERE id = 'p'").get(),
        audits: count(db, "SELECT COUNT(*) AS n FROM audit_events"),
      });
      const before = snapshot();
      const attempts: Array<[string, string, unknown?]> = [
        ["/v1/plans/p/category_groups", "POST", { category_group: { name: "New" } }],
        ["/v1/plans/p/category_groups/ynab-grp", "PATCH", { category_group: { name: "Renamed" } }],
        ["/v1/plans/p/categories", "POST", { category: { category_group_id: "ynab-grp", name: "New" } }],
        ["/v1/plans/p/categories/ynab-cat", "PATCH", { category: { hidden: true } }],
        ["/v1/plans/p/categories/ynab-cat", "DELETE"],
      ];
      for (const [path, method, body] of attempts) {
        const response = await request(path, { method, body, key: `mirror-${method}-${path.length}` });
        expect(response.status).toBe(409);
        expect((await response.json()).error.name).toBe("ynab_mirror_plan");
      }
      expect(snapshot()).toEqual(before);
    });
  });
}

describe("D1 category commands re-check their preconditions inside the batch", () => {
  test("a use that lands after planning aborts the delete", async () => {
    const { request, db, repo } = await open("D1");
    await request("/v1/plans/p/category_groups", { method: "POST", body: { category_group: { id: "grp", name: "Living" } } });
    await request("/v1/plans/p/categories", { method: "POST", body: { category: { id: "cat", category_group_id: "grp", name: "Food" } } });
    await repo.createAccount("p", { id: "acct", name: "Cash", type: "cash" });
    const racing = repo as any;
    const plan = racing.planDeleteCategory.bind(racing);
    racing.planDeleteCategory = async (...args: unknown[]) => {
      const command = await plan(...args);
      if (!db.query("SELECT 1 FROM transactions WHERE id = 'late'").get()) {
        db.run("INSERT INTO transactions (id, plan_id, account_id, date, amount_milli, category_id) VALUES ('late', 'p', 'acct', '2026-01-01', -1, 'cat')");
      }
      return command;
    };
    const knowledge = db.query("SELECT server_knowledge FROM plans WHERE id = 'p'").get();
    const response = await request("/v1/plans/p/categories/cat", { method: "DELETE" });
    expect(response.status).toBe(409);
    expect((await response.json()).error.name).toBe("category_in_use");
    expect(db.query("SELECT deleted FROM categories WHERE id = 'cat'").get()).toEqual({ deleted: 0 });
    expect(db.query("SELECT server_knowledge FROM plans WHERE id = 'p'").get()).toEqual(knowledge);
  });

  test("a YNAB month that lands after planning aborts the write", async () => {
    const { request, db, repo } = await open("D1");
    const racing = repo as any;
    const plan = racing.planCreateCategoryGroup.bind(racing);
    racing.planCreateCategoryGroup = async (...args: unknown[]) => {
      const command = await plan(...args);
      if (!db.query("SELECT 1 FROM ynab_raw_objects WHERE object_type = 'month'").get()) markYnabMirror(db);
      return command;
    };
    const response = await request("/v1/plans/p/category_groups", { method: "POST", body: { category_group: { id: "grp", name: "Living" } } });
    expect(response.status).toBe(409);
    expect((await response.json()).error.name).toBe("ynab_mirror_plan");
    expect(count(db, "SELECT COUNT(*) AS n FROM category_groups")).toBe(0);
  });
});

describe("transition read-only lock", () => {
  test("blocks category management writes and snapshot import, but not reads", async () => {
    const db = new Database(":memory:", { strict: true });
    applyMigrations(db);
    await new LedgerRepository(db, "p").ensurePlan("p");
    try {
      const handler = createHandler({
        db,
        config: { dbPath: ":memory:", port: 0, apiToken: API_TOKEN, defaultPlanId: "p", transitionReadOnly: true },
      });
      const send = (path: string, method: string) => handler(new Request(`https://howmuch.test${path}`, {
        method,
        headers: { authorization: `Bearer ${API_TOKEN}`, "content-type": "application/json", "idempotency-key": "lock-1" },
        ...(method === "GET" ? {} : { body: "{}" }),
      }));
      const locked: Array<[string, string]> = [
        ["/v1/plans/p/category_groups", "POST"],
        ["/v1/plans/p/category_groups/grp", "PATCH"],
        ["/v1/plans/p/categories", "POST"],
        ["/v1/plans/p/categories/cat", "PATCH"],
        ["/v1/plans/p/categories/cat", "DELETE"],
        ["/v1/plans/p/import_snapshot", "POST"],
      ];
      for (const [path, method] of locked) {
        const response = await send(path, method);
        expect(response.status, `${method} ${path}`).toBe(423);
        expect((await response.json()).error.name).toBe("transition_read_only");
      }
      expect((await send("/v1/plans/p/categories", "GET")).status).toBe(200);
      expect(count(db, "SELECT COUNT(*) AS n FROM category_groups")).toBe(0);
    } finally {
      db.close();
    }
  });
});
