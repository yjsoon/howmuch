-- Apply after the SQLite migrations 001-003 when creating a NEW, inactive D1 database.
-- This migration is intentionally not referenced by the production Worker.
PRAGMA foreign_keys = ON;

ALTER TABLE transactions ADD COLUMN ledger_sequence INTEGER;
ALTER TABLE subtransactions ADD COLUMN ledger_sequence INTEGER;

CREATE TRIGGER transactions_assign_ledger_sequence
AFTER INSERT ON transactions WHEN NEW.ledger_sequence IS NULL
BEGIN
  UPDATE transactions SET ledger_sequence = (SELECT COALESCE(MAX(ledger_sequence), 0) + 1 FROM transactions WHERE id <> NEW.id)
  WHERE id = NEW.id;
END;
CREATE TRIGGER subtransactions_assign_ledger_sequence
AFTER INSERT ON subtransactions WHEN NEW.ledger_sequence IS NULL
BEGIN
  UPDATE subtransactions SET ledger_sequence = (SELECT COALESCE(MAX(ledger_sequence), 0) + 1 FROM subtransactions WHERE id <> NEW.id)
  WHERE id = NEW.id;
END;
CREATE UNIQUE INDEX idx_transactions_ledger_sequence ON transactions(ledger_sequence);
CREATE UNIQUE INDEX idx_subtransactions_ledger_sequence ON subtransactions(ledger_sequence);

-- Import receipts are part of the inactive target schema. Each generated data
-- chunk and its receipt execute in one D1 transaction; receipts are never
-- reused for different source bytes or row boundaries.
CREATE TABLE migration_runs (
  id TEXT PRIMARY KEY,
  source_sha256 TEXT NOT NULL,
  source_bytes INTEGER NOT NULL,
  expected_chunk_count INTEGER NOT NULL CHECK (expected_chunk_count >= 0),
  status TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'complete')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at TEXT,
  UNIQUE(source_sha256),
  UNIQUE(id, source_sha256)
);
CREATE TABLE migration_chunks (
  run_id TEXT NOT NULL REFERENCES migration_runs(id) ON DELETE RESTRICT,
  source_sha256 TEXT NOT NULL,
  table_name TEXT NOT NULL,
  chunk_number INTEGER NOT NULL CHECK (chunk_number >= 0),
  row_count INTEGER NOT NULL CHECK (row_count > 0),
  chunk_sha256 TEXT NOT NULL,
  first_stable_key TEXT NOT NULL,
  last_stable_key TEXT NOT NULL,
  applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (run_id, table_name, chunk_number),
  FOREIGN KEY (run_id, source_sha256) REFERENCES migration_runs(id, source_sha256)
);
CREATE UNIQUE INDEX idx_migration_chunk_identity ON migration_chunks(
  source_sha256, table_name, chunk_number, row_count, chunk_sha256,
  first_stable_key, last_stable_key
);
CREATE TRIGGER migration_chunks_no_update BEFORE UPDATE ON migration_chunks
BEGIN
  SELECT RAISE(ABORT, 'migration chunk receipts are immutable');
END;
CREATE TRIGGER migration_chunks_no_delete BEFORE DELETE ON migration_chunks
BEGIN
  SELECT RAISE(ABORT, 'migration chunk receipts are immutable');
END;
CREATE TRIGGER migration_runs_identity_immutable BEFORE UPDATE OF id, source_sha256, source_bytes, expected_chunk_count ON migration_runs
BEGIN
  SELECT RAISE(ABORT, 'migration run identity is immutable');
END;
CREATE TRIGGER migration_runs_complete_immutable BEFORE UPDATE ON migration_runs
WHEN OLD.status = 'complete'
BEGIN
  SELECT RAISE(ABORT, 'completed migration runs are immutable');
END;
CREATE TRIGGER migration_runs_no_delete BEFORE DELETE ON migration_runs
BEGIN
  SELECT RAISE(ABORT, 'migration run receipts are immutable');
END;

-- D1 metadata writers rely on these relationships being enforced at execution
-- time, not merely observed during planning.
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
CREATE TRIGGER categories_group_plan_guard BEFORE INSERT ON categories
WHEN NEW.category_group_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM category_groups g WHERE g.id=NEW.category_group_id AND g.plan_id=NEW.plan_id
)
BEGIN SELECT RAISE(ABORT, 'category group ownership failed'); END;
CREATE TRIGGER categories_group_plan_update_guard BEFORE UPDATE OF plan_id, category_group_id ON categories
WHEN NEW.category_group_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM category_groups g WHERE g.id=NEW.category_group_id AND g.plan_id=NEW.plan_id
)
BEGIN SELECT RAISE(ABORT, 'category group ownership failed'); END;

CREATE TABLE ynab_sync_state (
  plan_id TEXT PRIMARY KEY REFERENCES plans(id) ON DELETE CASCADE,
  server_knowledge INTEGER NOT NULL DEFAULT 0,
  lease_id TEXT,
  lease_until TEXT,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE sync_runs (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  scheduled_for TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'running',
  current_attempt_id TEXT,
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  result_json TEXT NOT NULL DEFAULT '{}',
  error TEXT,
  UNIQUE(plan_id, scheduled_for)
);
CREATE INDEX idx_sync_runs_plan_started ON sync_runs(plan_id, started_at DESC);
CREATE TABLE sync_attempts (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES sync_runs(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'running',
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  error TEXT
);
CREATE INDEX idx_sync_attempts_run_started ON sync_attempts(run_id, started_at DESC);

-- IDs are globally supplied by the scheduler.  An exact retry is harmless, but
-- reusing one for a different object must not be mistaken for that retry.
CREATE TRIGGER sync_runs_id_collision_guard BEFORE INSERT ON sync_runs
WHEN EXISTS (SELECT 1 FROM sync_runs WHERE id = NEW.id AND (plan_id <> NEW.plan_id OR scheduled_for <> NEW.scheduled_for))
BEGIN SELECT RAISE(ABORT, 'sync run id collision'); END;
CREATE TRIGGER sync_attempts_id_collision_guard BEFORE INSERT ON sync_attempts
WHEN EXISTS (SELECT 1 FROM sync_attempts WHERE id = NEW.id AND run_id <> NEW.run_id)
BEGIN SELECT RAISE(ABORT, 'sync attempt id collision'); END;

-- Inserting this receipt is the first statement of a terminal batch.  The
-- trigger is the SQL-side compare-and-swap: unlike client-side change counts,
-- RAISE(ABORT) rolls the entire D1 batch back.  Existing, exact receipts make
-- an ambiguous-commit retry successful without applying the transition again.
CREATE TABLE sync_transition_receipts (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('completed', 'skipped', 'failed')),
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(plan_id, run_id, attempt_id, status)
);
CREATE TRIGGER sync_transition_receipt_guard BEFORE INSERT ON sync_transition_receipts
WHEN NOT (
  EXISTS (
    SELECT 1 FROM sync_transition_receipts r
    JOIN sync_runs sr ON sr.id = r.run_id
    JOIN sync_attempts sa ON sa.id = r.attempt_id AND sa.run_id = sr.id
    WHERE r.id = NEW.id AND r.plan_id = NEW.plan_id AND r.run_id = NEW.run_id
      AND r.attempt_id = NEW.attempt_id AND r.status = NEW.status
      AND r.payload_json = NEW.payload_json
      AND sr.plan_id = NEW.plan_id AND sr.current_attempt_id = NEW.attempt_id
      AND sr.status = NEW.status AND sa.status = NEW.status
  )
  OR (
    NOT EXISTS (SELECT 1 FROM sync_transition_receipts WHERE id = NEW.id)
    AND EXISTS (
      SELECT 1 FROM sync_runs sr
      JOIN sync_attempts sa ON sa.id = NEW.attempt_id AND sa.run_id = sr.id
      JOIN ynab_sync_state ys ON ys.plan_id = sr.plan_id
      WHERE sr.id = NEW.run_id AND sr.plan_id = NEW.plan_id
        AND sr.current_attempt_id = NEW.attempt_id AND sr.status = 'running'
        AND sa.status = 'running' AND ys.lease_id = NEW.attempt_id
        AND ys.lease_until >= CURRENT_TIMESTAMP
    )
  )
)
BEGIN SELECT RAISE(ABORT, 'scheduled sync transition rejected'); END;
CREATE TRIGGER sync_transition_receipts_immutable BEFORE UPDATE ON sync_transition_receipts
BEGIN SELECT RAISE(ABORT, 'scheduled sync transition receipts are immutable'); END;
CREATE TRIGGER sync_transition_receipts_delete_guard BEFORE DELETE ON sync_transition_receipts
BEGIN SELECT RAISE(ABORT, 'scheduled sync transition receipts cannot be deleted'); END;

CREATE TABLE sync_renewal_receipts (
  id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  renewed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TRIGGER sync_renewal_insert_guard BEFORE INSERT ON sync_renewal_receipts
WHEN NOT EXISTS (
  SELECT 1 FROM sync_runs sr
  JOIN sync_attempts sa ON sa.id = NEW.attempt_id AND sa.run_id = sr.id
  JOIN ynab_sync_state ys ON ys.plan_id = sr.plan_id
  WHERE sr.id = NEW.run_id AND sr.plan_id = NEW.plan_id
    AND sr.current_attempt_id = NEW.attempt_id AND sr.status = 'running' AND sa.status = 'running'
    AND ys.lease_id = NEW.attempt_id AND ys.lease_until >= CURRENT_TIMESTAMP
)
BEGIN SELECT RAISE(ABORT, 'scheduled sync renewal rejected'); END;
CREATE TRIGGER sync_renewal_update_guard BEFORE UPDATE ON sync_renewal_receipts
WHEN NOT EXISTS (
  SELECT 1 FROM sync_runs sr
  JOIN sync_attempts sa ON sa.id = NEW.attempt_id AND sa.run_id = sr.id
  JOIN ynab_sync_state ys ON ys.plan_id = sr.plan_id
  WHERE sr.id = NEW.run_id AND sr.plan_id = NEW.plan_id
    AND sr.current_attempt_id = NEW.attempt_id AND sr.status = 'running' AND sa.status = 'running'
    AND ys.lease_id = NEW.attempt_id AND ys.lease_until >= CURRENT_TIMESTAMP
)
BEGIN SELECT RAISE(ABORT, 'scheduled sync renewal rejected'); END;

CREATE TABLE audit_events (
  id TEXT PRIMARY KEY,
  plan_id TEXT REFERENCES plans(id) ON DELETE SET NULL,
  action TEXT NOT NULL,
  resource_type TEXT,
  resource_id TEXT,
  source TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_audit_events_plan_created ON audit_events(plan_id, created_at DESC);

CREATE TABLE write_commands (
  id TEXT PRIMARY KEY,
  expected_write_version INTEGER NOT NULL UNIQUE,
  kind TEXT NOT NULL,
  plan_id TEXT NOT NULL,
  transaction_id TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'applied')),
  result_json TEXT NOT NULL DEFAULT '{}',
  lease_plan_id TEXT,
  lease_attempt_id TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  applied_at TEXT
);
CREATE TABLE write_state (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  write_version INTEGER NOT NULL CHECK (write_version >= 0),
  last_command_id TEXT REFERENCES write_commands(id)
);
INSERT INTO write_state (singleton, write_version) VALUES (1, 0);
CREATE TRIGGER write_commands_version_guard
BEFORE INSERT ON write_commands
WHEN NEW.expected_write_version <> (SELECT write_version FROM write_state WHERE singleton = 1)
  OR (NEW.lease_attempt_id IS NULL) <> (NEW.lease_plan_id IS NULL)
  OR (NEW.lease_attempt_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM ynab_sync_state
    WHERE plan_id = NEW.lease_plan_id
      AND lease_id = NEW.lease_attempt_id
      AND lease_until >= CURRENT_TIMESTAMP
  ))
BEGIN
  SELECT RAISE(ABORT, 'stale write command');
END;
CREATE TRIGGER write_state_increment_guard
BEFORE UPDATE OF write_version, last_command_id ON write_state
WHEN NEW.write_version <> OLD.write_version + 1 OR NEW.last_command_id IS NULL OR NOT EXISTS (
  SELECT 1 FROM write_commands
  WHERE id = NEW.last_command_id
    AND expected_write_version = OLD.write_version
    AND status = 'pending'
)
BEGIN
  SELECT RAISE(ABORT, 'write_version increment requires its pending command');
END;
CREATE TRIGGER write_commands_apply_guard
BEFORE UPDATE OF status ON write_commands
WHEN NEW.status = 'applied' AND (
  OLD.status <> 'pending'
  OR (SELECT last_command_id FROM write_state WHERE singleton = 1) <> NEW.id
  OR (SELECT write_version FROM write_state WHERE singleton = 1) <> NEW.expected_write_version + 1
)
BEGIN
  SELECT RAISE(ABORT, 'write command is not bound to current version');
END;
CREATE TRIGGER write_commands_immutable
BEFORE UPDATE ON write_commands
WHEN OLD.status = 'applied'
  OR NEW.id <> OLD.id
  OR NEW.expected_write_version <> OLD.expected_write_version
  OR NEW.kind <> OLD.kind
  OR NEW.plan_id <> OLD.plan_id
  OR NEW.transaction_id <> OLD.transaction_id
  OR NEW.request_hash <> OLD.request_hash
  OR NEW.result_json <> OLD.result_json
  OR NEW.lease_plan_id IS NOT OLD.lease_plan_id
  OR NEW.lease_attempt_id IS NOT OLD.lease_attempt_id
  OR NEW.created_at <> OLD.created_at
  OR OLD.status <> 'pending'
  OR NEW.status <> 'applied'
  OR NEW.applied_at IS NULL
BEGIN
  SELECT RAISE(ABORT, 'write command is immutable');
END;
CREATE TRIGGER write_commands_delete_guard
BEFORE DELETE ON write_commands
BEGIN
  SELECT RAISE(ABORT, 'write command receipts cannot be deleted');
END;

-- Assertions are deliberately executed inside the write batch. Preflight reads
-- improve error messages, but cannot protect against a row disappearing between
-- planning and D1's atomic batch.
CREATE TABLE write_assertions (
  command_id TEXT NOT NULL REFERENCES write_commands(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('account', 'payee', 'transfer_payee', 'category', 'update_target', 'graph_update_target', 'graph_transaction', 'graph_subtransaction', 'upsert_transaction', 'mirror_transaction', 'upsert_subtransaction', 'upsert_subtransaction_parent', 'metadata_plan', 'metadata_plan_exists', 'metadata_account', 'metadata_account_exists', 'metadata_payee', 'metadata_category_group', 'metadata_category_group_exists', 'metadata_category', 'import_session_new', 'import_session_running', 'import_transaction')),
  target_id TEXT NOT NULL,
  plan_id TEXT NOT NULL,
  PRIMARY KEY (command_id, kind, target_id)
);
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
