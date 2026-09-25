-- Imported YNAB schedules remain immutable in ynab_raw_objects. These tables
-- contain complete HowMuch-owned effective records: either a local schedule or
-- an overlay/tombstone for a source schedule with the same ID.
CREATE TABLE IF NOT EXISTS scheduled_transaction_edits (
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  origin TEXT NOT NULL CHECK (origin IN ('howmuch-local', 'ynab-overlay')),
  payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
  account_id TEXT NOT NULL REFERENCES accounts(id),
  date_first TEXT NOT NULL CHECK (date_first GLOB '????-??-??'),
  date_next TEXT NOT NULL CHECK (date_next GLOB '????-??-??'),
  frequency TEXT NOT NULL,
  amount_milli INTEGER NOT NULL,
  payee_id TEXT REFERENCES payees(id),
  category_id TEXT REFERENCES categories(id),
  transfer_account_id TEXT REFERENCES accounts(id),
  deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (plan_id, id)
);

CREATE INDEX IF NOT EXISTS idx_scheduled_transaction_edits_next
  ON scheduled_transaction_edits(plan_id, deleted, date_next, id);

CREATE TABLE IF NOT EXISTS scheduled_subtransaction_edits (
  plan_id TEXT NOT NULL,
  id TEXT NOT NULL,
  scheduled_transaction_id TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
  amount_milli INTEGER NOT NULL,
  payee_id TEXT REFERENCES payees(id),
  category_id TEXT REFERENCES categories(id),
  transfer_account_id TEXT REFERENCES accounts(id),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (plan_id, id),
  FOREIGN KEY (plan_id, scheduled_transaction_id)
    REFERENCES scheduled_transaction_edits(plan_id, id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_scheduled_subtransaction_edits_parent
  ON scheduled_subtransaction_edits(plan_id, scheduled_transaction_id, id);

CREATE TRIGGER scheduled_transaction_edits_source_guard BEFORE INSERT ON scheduled_transaction_edits
WHEN (NEW.origin = 'ynab-overlay' AND NOT EXISTS (
  SELECT 1 FROM ynab_raw_objects r
  WHERE r.plan_id = NEW.plan_id AND r.object_type = 'scheduled_transaction' AND r.object_id = NEW.id
)) OR (NEW.origin = 'howmuch-local' AND EXISTS (
  SELECT 1 FROM ynab_raw_objects r
  WHERE r.plan_id = NEW.plan_id AND r.object_type = 'scheduled_transaction' AND r.object_id = NEW.id
))
BEGIN SELECT RAISE(ABORT, 'scheduled transaction origin mismatch'); END;

CREATE TRIGGER scheduled_transaction_edits_source_update_guard BEFORE UPDATE OF plan_id, id, origin ON scheduled_transaction_edits
WHEN (NEW.origin = 'ynab-overlay' AND NOT EXISTS (
  SELECT 1 FROM ynab_raw_objects r
  WHERE r.plan_id = NEW.plan_id AND r.object_type = 'scheduled_transaction' AND r.object_id = NEW.id
)) OR (NEW.origin = 'howmuch-local' AND EXISTS (
  SELECT 1 FROM ynab_raw_objects r
  WHERE r.plan_id = NEW.plan_id AND r.object_type = 'scheduled_transaction' AND r.object_id = NEW.id
))
BEGIN SELECT RAISE(ABORT, 'scheduled transaction origin mismatch'); END;

CREATE TRIGGER scheduled_transaction_edits_ownership_guard BEFORE INSERT ON scheduled_transaction_edits
WHEN NOT EXISTS (SELECT 1 FROM accounts a WHERE a.id = NEW.account_id AND a.plan_id = NEW.plan_id AND a.deleted = 0)
  OR (NEW.payee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM payees p WHERE p.id = NEW.payee_id AND p.plan_id = NEW.plan_id AND p.deleted = 0))
  OR (NEW.category_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categories c WHERE c.id = NEW.category_id AND c.plan_id = NEW.plan_id AND c.deleted = 0))
  OR (NEW.transfer_account_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM accounts a WHERE a.id = NEW.transfer_account_id AND a.plan_id = NEW.plan_id AND a.deleted = 0))
BEGIN SELECT RAISE(ABORT, 'scheduled transaction ownership failed'); END;

CREATE TRIGGER scheduled_transaction_edits_ownership_update_guard BEFORE UPDATE OF plan_id, account_id, payee_id, category_id, transfer_account_id ON scheduled_transaction_edits
WHEN NOT EXISTS (SELECT 1 FROM accounts a WHERE a.id = NEW.account_id AND a.plan_id = NEW.plan_id AND a.deleted = 0)
  OR (NEW.payee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM payees p WHERE p.id = NEW.payee_id AND p.plan_id = NEW.plan_id AND p.deleted = 0))
  OR (NEW.category_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categories c WHERE c.id = NEW.category_id AND c.plan_id = NEW.plan_id AND c.deleted = 0))
  OR (NEW.transfer_account_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM accounts a WHERE a.id = NEW.transfer_account_id AND a.plan_id = NEW.plan_id AND a.deleted = 0))
BEGIN SELECT RAISE(ABORT, 'scheduled transaction ownership failed'); END;

CREATE TRIGGER scheduled_subtransaction_edits_ownership_guard BEFORE INSERT ON scheduled_subtransaction_edits
WHEN (NEW.payee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM payees p WHERE p.id = NEW.payee_id AND p.plan_id = NEW.plan_id AND p.deleted = 0))
  OR (NEW.category_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categories c WHERE c.id = NEW.category_id AND c.plan_id = NEW.plan_id AND c.deleted = 0))
  OR (NEW.transfer_account_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM accounts a WHERE a.id = NEW.transfer_account_id AND a.plan_id = NEW.plan_id AND a.deleted = 0))
BEGIN SELECT RAISE(ABORT, 'scheduled subtransaction ownership failed'); END;

CREATE TRIGGER scheduled_subtransaction_edits_ownership_update_guard BEFORE UPDATE OF plan_id, payee_id, category_id, transfer_account_id ON scheduled_subtransaction_edits
WHEN (NEW.payee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM payees p WHERE p.id = NEW.payee_id AND p.plan_id = NEW.plan_id AND p.deleted = 0))
  OR (NEW.category_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categories c WHERE c.id = NEW.category_id AND c.plan_id = NEW.plan_id AND c.deleted = 0))
  OR (NEW.transfer_account_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM accounts a WHERE a.id = NEW.transfer_account_id AND a.plan_id = NEW.plan_id AND a.deleted = 0))
BEGIN SELECT RAISE(ABORT, 'scheduled subtransaction ownership failed'); END;
