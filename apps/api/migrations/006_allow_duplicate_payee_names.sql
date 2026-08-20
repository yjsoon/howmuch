-- YNAB permits separate payee IDs with the same display name. Rebuild the
-- table rather than changing or merging any payee rows, so transaction IDs and
-- snapshots continue to point at the original payee records.
-- These ownership triggers originated in the D1 schema, not the local
-- schema. Remove any accidental local copies during the rebuild; this
-- migration deliberately does not recreate them.
DROP TRIGGER IF EXISTS accounts_transfer_payee_plan_guard;
DROP TRIGGER IF EXISTS accounts_transfer_payee_plan_update_guard;
DROP TRIGGER IF EXISTS payees_transfer_account_plan_guard;
DROP TRIGGER IF EXISTS payees_transfer_account_plan_update_guard;

CREATE TABLE payees_replacement (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  transfer_account_id TEXT,
  external_ynab_id TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO payees_replacement (
  id, plan_id, name, transfer_account_id, external_ynab_id, deleted, created_at, updated_at
)
SELECT id, plan_id, name, transfer_account_id, external_ynab_id, deleted, created_at, updated_at
FROM payees;

DROP TABLE payees;
ALTER TABLE payees_replacement RENAME TO payees;

CREATE INDEX idx_payees_plan_id ON payees(plan_id);
CREATE UNIQUE INDEX idx_payees_one_transfer_per_account
  ON payees(plan_id, transfer_account_id) WHERE transfer_account_id IS NOT NULL AND deleted = 0;
