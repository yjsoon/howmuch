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

  const migrations: Array<{ version: string; path: string; rebuildsForeignKeyTarget?: boolean }> = [
    {
      version: "001_initial",
      path: join(migrationsDir, "001_initial.sql"),
    },
    {
      version: "002_transaction_server_knowledge",
      path: join(migrationsDir, "002_transaction_server_knowledge.sql"),
    },
    {
      version: "003_transfer_payees",
      path: join(migrationsDir, "003_transfer_payees.sql"),
    },
    {
      version: "004_auth_foundation",
      path: join(migrationsDir, "004_auth_foundation.sql"),
    },
    {
      version: "005_password_auth",
      path: join(migrationsDir, "005_password_auth.sql"),
    },
    {
      version: "006_allow_duplicate_payee_names",
      path: join(migrationsDir, "006_allow_duplicate_payee_names.sql"),
      rebuildsForeignKeyTarget: true,
    },
    {
      version: "007_ynab_raw_objects",
      path: join(migrationsDir, "007_ynab_raw_objects.sql"),
    },
    {
      version: "008_plan_month_assignments",
      path: join(migrationsDir, "008_plan_month_assignments.sql"),
    },
    {
      version: "009_plan_month_category_targets",
      path: join(migrationsDir, "009_plan_month_category_targets.sql"),
    },
    {
      version: "010_scheduled_transaction_edits",
      path: join(migrationsDir, "010_scheduled_transaction_edits.sql"),
    },
    {
      version: "011_scheduled_transaction_snapshot_assertions",
      path: join(migrationsDir, "011_scheduled_transaction_snapshot_assertions.sql"),
    },
    {
      version: "012_account_reconciliation_assertions",
      path: join(migrationsDir, "012_account_reconciliation_assertions.sql"),
    },
    {
      version: "013_unique_live_import_id",
      path: join(migrationsDir, "013_unique_live_import_id.sql"),
    },
    {
      version: "014_personal_api_tokens",
      path: join(migrationsDir, "014_personal_api_tokens.sql"),
    },
    {
      version: "015_account_preferences",
      path: join(migrationsDir, "015_account_preferences.sql"),
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
    if (migration.rebuildsForeignKeyTarget) db.run("PRAGMA foreign_keys = OFF");
    try {
      db.transaction(() => {
        db.run(sql);
        db.query("INSERT INTO schema_migrations (version) VALUES (?)").run(migration.version);
      })();
    } finally {
      if (migration.rebuildsForeignKeyTarget) db.run("PRAGMA foreign_keys = ON");
    }

    if (migration.rebuildsForeignKeyTarget && db.query("PRAGMA foreign_key_check").all().length) {
      throw new Error(`Migration ${migration.version} introduced foreign-key violations`);
    }
  }
}
