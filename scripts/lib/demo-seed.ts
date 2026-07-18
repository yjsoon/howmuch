import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { openDatabase } from "../../apps/api/src/db";
import { LedgerRepository } from "../../apps/api/src/repository";

type DemoFixture = {
  plan: {
    id: string;
    name: string;
  };
  accounts: Array<Record<string, unknown>>;
  category_groups: Array<{ id: string; name: string }>;
  categories: Array<{ id: string; group_id: string; name: string }>;
  transactions: Array<Record<string, unknown>>;
};

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const defaultFixturePath = join(repoRoot, "fixtures", "demo-ledger.json");

export function resolveFixturePath(path = defaultFixturePath): string {
  return path;
}

export function loadDemoFixture(path = defaultFixturePath): DemoFixture {
  return JSON.parse(readFileSync(path, "utf8")) as DemoFixture;
}

export function seedDemoLedger(options?: {
  dbPath?: string;
  fixturePath?: string;
  planId?: string;
}): { dbPath: string; fixturePath: string; planId: string } {
  const fixturePath = resolveFixturePath(options?.fixturePath);
  const fixture = loadDemoFixture(fixturePath);
  const dbPath = options?.dbPath ?? "data/howmuch.sqlite";
  const planId = options?.planId ?? fixture.plan.id;

  const db = openDatabase(dbPath);
  const repo = new LedgerRepository(db, planId);

  try {
    await repo.ensurePlan(planId, fixture.plan.name);

    for (const account of fixture.accounts) {
      await repo.upsertAccount(planId, account);
    }

    for (const group of fixture.category_groups) {
      await repo.upsertCategoryGroup(planId, group);
    }

    for (const category of fixture.categories) {
      await repo.upsertCategory(planId, category, category.group_id);
    }

    for (const transaction of fixture.transactions) {
      await repo.createTransaction(planId, transaction as any);
    }
  } finally {
    db.close();
  }

  return { dbPath, fixturePath, planId };
}
