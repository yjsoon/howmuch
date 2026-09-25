-- YNAB permits separate payee IDs with the same display name. Preserve every
-- existing ID and row; only remove the invalid name-level uniqueness rule.
-- D1's current production and preview schemas are empty, while disabling
-- foreign keys also keeps this rebuild safe for a populated local D1 replica.
PRAGMA foreign_keys = OFF;

DROP TRIGGER IF EXISTS accounts_transfer_payee_plan_guard;
DROP TRIGGER IF EXISTS accounts_transfer_payee_plan_update_guard;
DROP TRIGGER IF EXISTS payees_transfer_account_plan_guard;
DROP TRIGGER IF EXISTS payees_transfer_account_plan_update_guard;
DROP TRIGGER IF EXISTS write_assertions_guard;

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

CREATE TRIGGER accounts_transfer_payee_plan_guard BEFORE INSERT ON accounts
WHEN NEW.transfer_payee_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM payees p WHERE p.id=NEW.transfer_payee_id AND p.plan_id=NEW.plan_id
    AND p.transfer_account_id=NEW.id AND p.deleted=0
)
BEGIN SELECT RAISE(ABORT, 'account transfer payee ownership failed'); END;
CREATE TRIGGER accounts_transfer_payee_plan_update_guard BEFORE UPDATE OF plan_id, transfer_payee_id ON accounts
WHEN NEW.transfer_payee_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM payees p WHERE p.id=NEW.transfer_payee_id AND p.plan_id=NEW.plan_id
    AND p.transfer_account_id=NEW.id AND p.deleted=0
)
BEGIN SELECT RAISE(ABORT, 'account transfer payee ownership failed'); END;
CREATE TRIGGER payees_transfer_account_plan_guard BEFORE INSERT ON payees
WHEN NEW.transfer_account_id IS NOT NULL AND EXISTS (
  SELECT 1 FROM accounts a WHERE a.id=NEW.transfer_account_id AND a.plan_id<>NEW.plan_id
)
BEGIN SELECT RAISE(ABORT, 'transfer payee account ownership failed'); END;
CREATE TRIGGER payees_transfer_account_plan_update_guard BEFORE UPDATE OF plan_id, transfer_account_id ON payees
WHEN NEW.transfer_account_id IS NOT NULL AND EXISTS (
  SELECT 1 FROM accounts a WHERE a.id=NEW.transfer_account_id AND a.plan_id<>NEW.plan_id
)
BEGIN SELECT RAISE(ABORT, 'transfer payee account ownership failed'); END;

CREATE TRIGGER write_assertions_guard
BEFORE INSERT ON write_assertions
WHEN (NEW.kind = 'account' AND NOT EXISTS (SELECT 1 FROM accounts WHERE id = NEW.target_id AND plan_id = NEW.plan_id AND deleted = 0))
  OR (NEW.kind = 'metadata_plan' AND EXISTS (SELECT 1 FROM plans WHERE id = NEW.target_id AND id <> NEW.plan_id))
  OR (NEW.kind = 'metadata_plan_exists' AND NOT EXISTS (SELECT 1 FROM plans WHERE id = NEW.target_id AND id = NEW.plan_id))
  OR (NEW.kind = 'metadata_account' AND EXISTS (SELECT 1 FROM accounts WHERE id = NEW.target_id AND plan_id <> NEW.plan_id))
  OR (NEW.kind = 'metadata_account_exists' AND NOT EXISTS (SELECT 1 FROM accounts WHERE id = NEW.target_id AND plan_id = NEW.plan_id AND deleted = 0))
  OR (NEW.kind = 'metadata_payee' AND EXISTS (SELECT 1 FROM payees WHERE id = NEW.target_id AND plan_id <> NEW.plan_id))
  OR (NEW.kind = 'metadata_category_group' AND EXISTS (SELECT 1 FROM category_groups WHERE id = NEW.target_id AND plan_id <> NEW.plan_id))
  OR (NEW.kind = 'metadata_category_group_exists' AND NOT EXISTS (SELECT 1 FROM category_groups WHERE id = NEW.target_id AND plan_id = NEW.plan_id AND deleted = 0))
  OR (NEW.kind = 'metadata_category' AND EXISTS (SELECT 1 FROM categories WHERE id = NEW.target_id AND plan_id <> NEW.plan_id))
  OR (NEW.kind = 'import_session_new' AND EXISTS (SELECT 1 FROM import_sessions WHERE id = NEW.target_id))
  OR (NEW.kind = 'import_session_running' AND NOT EXISTS (SELECT 1 FROM import_sessions WHERE id = NEW.target_id AND plan_id IS NULLIF(NEW.plan_id, '') AND status = 'running'))
  OR (NEW.kind = 'import_transaction' AND NOT EXISTS (SELECT 1 FROM transactions WHERE id = NEW.target_id AND plan_id = NEW.plan_id))
  OR (NEW.kind = 'payee' AND NOT EXISTS (SELECT 1 FROM payees WHERE id = NEW.target_id AND plan_id = NEW.plan_id AND deleted = 0 AND transfer_account_id IS NULL))
  OR (NEW.kind = 'transfer_payee' AND NOT EXISTS (
    SELECT 1 FROM payees p JOIN accounts a ON a.id = p.transfer_account_id
    WHERE p.id = NEW.target_id AND p.plan_id = NEW.plan_id AND p.deleted = 0
      AND a.plan_id = NEW.plan_id AND a.deleted = 0
  ))
  OR (NEW.kind = 'category' AND NOT EXISTS (SELECT 1 FROM categories WHERE id = NEW.target_id AND plan_id = NEW.plan_id AND deleted = 0))
  OR (NEW.kind = 'update_target' AND NOT EXISTS (
    SELECT 1 FROM transactions t WHERE t.id = NEW.target_id AND t.plan_id = NEW.plan_id AND t.deleted = 0
      AND t.transfer_account_id IS NULL AND t.transfer_transaction_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM subtransactions s WHERE s.transaction_id = t.id AND s.deleted = 0)
  ))
  OR (NEW.kind = 'graph_update_target' AND NOT EXISTS (
    SELECT 1 FROM transactions t WHERE t.id = NEW.target_id AND t.plan_id = NEW.plan_id AND t.deleted = 0
  ))
  OR (NEW.kind = 'graph_transaction' AND NOT EXISTS (
    SELECT 1 FROM transactions WHERE id = NEW.target_id AND plan_id = NEW.plan_id
  ))
  OR (NEW.kind = 'graph_subtransaction' AND NOT EXISTS (
    SELECT 1 FROM subtransactions s JOIN transactions t ON t.id = s.transaction_id
    WHERE s.id = NEW.target_id AND t.plan_id = NEW.plan_id
  ))
  OR (NEW.kind = 'upsert_transaction' AND EXISTS (
    SELECT 1 FROM transactions WHERE id = NEW.target_id AND plan_id <> NEW.plan_id
  ))
  OR (NEW.kind = 'mirror_transaction' AND EXISTS (
    SELECT 1 FROM transactions WHERE id = NEW.target_id AND transfer_transaction_id IS NOT NEW.plan_id
  ))
  OR (NEW.kind = 'upsert_subtransaction' AND EXISTS (
    SELECT 1 FROM subtransactions s JOIN transactions t ON t.id = s.transaction_id
    WHERE s.id = NEW.target_id AND t.plan_id <> NEW.plan_id
  ))
  OR (NEW.kind = 'upsert_subtransaction_parent' AND EXISTS (
    SELECT 1 FROM subtransactions WHERE id = NEW.target_id AND transaction_id <> NEW.plan_id
  ))
BEGIN
  SELECT RAISE(ABORT, 'write precondition failed');
END;

PRAGMA foreign_keys = ON;
