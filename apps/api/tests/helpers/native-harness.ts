import { Database } from "bun:sqlite";
import { AsyncReportService } from "../../src/async-reports";
import { D1AuthStore } from "../../src/auth-store";
import { D1Database } from "../../src/d1";
import { D1LedgerRepository } from "../../src/d1-ledger-repository";
import { applyMigrations } from "../../src/db";
import { createHandler } from "../../src/http";
import { LedgerRepository } from "../../src/repository";
import type { LedgerStore } from "../../src/storage";
import { newSession } from "../../src/password-auth";
import { fakeD1Binding } from "./counting-d1";

export const BACKENDS = ["SQLite", "D1"] as const;
export type Backend = (typeof BACKENDS)[number];

export const API_TOKEN = "test-token";

export type NativeHarness = {
  backend: Backend;
  db: Database;
  repo: LedgerStore;
  /** The raw handler, for auth flows that need cookies, origins or session tokens of their own. */
  handle: (request: Request) => Promise<Response>;
  request: (path: string, init?: { method?: string; body?: unknown; key?: string; token?: string }) => Promise<Response>;
  /** D1 only: statement count of every binding.batch call (reads and writes). */
  batches: number[];
  close: () => void;
};

/**
 * One API over either storage backend, with plans `p` (default) and `q`
 * already created. SQLite uses the local migrations; D1 applies the D1
 * migrations to an in-memory database behind a fake binding, as production
 * would see them.
 */
export async function nativeHarness(backend: Backend): Promise<NativeHarness> {
  const db = new Database(":memory:", { strict: true });
  const writeBatches: number[] = [];
  let repo: LedgerStore;
  let handler: (request: Request) => Promise<Response>;
  const config = { dbPath: ":memory:", port: 0, apiToken: API_TOKEN, defaultPlanId: "p", transitionReadOnly: false };
  if (backend === "SQLite") {
    applyMigrations(db);
    repo = new LedgerRepository(db, "p");
    handler = createHandler({ db, repo, config });
  } else {
    const directory = new URL("../../d1-migrations/", import.meta.url).pathname;
    for (const file of [...new Bun.Glob("*.sql").scanSync(directory)].sort()) {
      db.exec(await Bun.file(`${directory}${file}`).text());
    }
    const binding = fakeD1Binding(db);
    const batch = binding.batch.bind(binding);
    binding.batch = (async (statements: Parameters<typeof batch>[0]) => {
      writeBatches.push(statements.length);
      return batch(statements);
    }) as typeof binding.batch;
    const d1 = new D1Database(binding);
    repo = new D1LedgerRepository(d1, "p");
    handler = createHandler({ repo, reports: new AsyncReportService(d1), auth: new D1AuthStore(d1), config });
  }
  await repo.ensurePlan("p");
  await repo.ensurePlan("q");
  return {
    backend,
    db,
    repo,
    handle: handler,
    request: (path, init = {}) => handler(new Request(`https://howmuch.test${path}`, {
      method: init.method ?? "GET",
      headers: {
        authorization: `Bearer ${init.token ?? API_TOKEN}`,
        "content-type": "application/json",
        ...(init.key ? { "idempotency-key": init.key } : {}),
      },
      ...(init.body === undefined ? {} : { body: typeof init.body === "string" ? init.body : JSON.stringify(init.body) }),
    })),
    batches: writeBatches,
    close: () => db.close(),
  };
}

/** Makes plan `p` a YNAB mirror: one `month` raw object is enough. */
export function markYnabMirror(db: Database, planId = "p"): void {
  db.run(
    "INSERT INTO ynab_raw_objects (plan_id, object_type, object_id, payload_json) VALUES (?, 'month', '2026-01-01', ?)",
    [planId, JSON.stringify({ month: "2026-01-01", categories: [] })],
  );
}

/** A bearer session for a new user holding `role` on `planId`. */
export function sessionFor(db: Database, role: "owner" | "editor" | "viewer", planId = "p"): string {
  const session = newSession();
  const userId = `user-${role}-${session.id.slice(0, 8)}`;
  db.run("INSERT INTO users (id) VALUES (?)", [userId]);
  db.run(
    "INSERT INTO password_credentials (user_id, username, cost_n, block_size, parallelization, salt_hex, hash_hex) VALUES (?, ?, 16384, 8, 1, ?, ?)",
    [userId, userId.toLowerCase(), "0".repeat(32), "0".repeat(64)],
  );
  db.run("INSERT INTO plan_memberships (plan_id, user_id, role) VALUES (?, ?, ?)", [planId, userId, role]);
  db.run("INSERT INTO sessions (id, user_id, token_hash, expires_at) VALUES (?, ?, ?, ?)", [session.id, userId, session.tokenHash, session.expiresAt]);
  return session.token;
}

export function count(db: Database, sql: string, ...values: any[]): number {
  return Number((db.query(sql).get(...values) as { n: number }).n);
}
