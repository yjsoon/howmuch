import { Database } from "bun:sqlite";
import { dirname, join } from "node:path";
import { mkdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, "..", "migrations");

export function openDatabase(path: string): Database {
  if (path !== ":memory:") {
    mkdirSync(dirname(path), { recursive: true });
  }

  const db = new Database(path);
  db.run("PRAGMA foreign_keys = ON");
  db.run("PRAGMA journal_mode = WAL");
  applyMigrations(db);
  return db;
}

export function applyMigrations(db: Database): void {
  db.run("PRAGMA foreign_keys = ON");
  db.run(
    "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)",
  );

  const migrations = [
    {
      version: "001_initial",
      path: join(migrationsDir, "001_initial.sql"),
    },
  ];

  for (const migration of migrations) {
    const applied = db
      .query("SELECT version FROM schema_migrations WHERE version = ?")
      .get(migration.version);

    if (applied) {
      continue;
    }

    const sql = readFileSync(migration.path, "utf8");
    db.transaction(() => {
      db.run(sql);
      db.query("INSERT INTO schema_migrations (version) VALUES (?)").run(migration.version);
    })();
  }
}
