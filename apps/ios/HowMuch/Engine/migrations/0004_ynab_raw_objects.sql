-- Retain the source form of every YNAB entity alongside the normalised
-- ledger.  This is deliberately one row per source object: a plan export can
-- be large, but no single row contains the entire export envelope.
CREATE TABLE IF NOT EXISTS ynab_raw_objects (
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  object_type TEXT NOT NULL,
  object_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  server_knowledge INTEGER,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (plan_id, object_type, object_id)
);

CREATE INDEX IF NOT EXISTS idx_ynab_raw_objects_plan_type
  ON ynab_raw_objects(plan_id, object_type, object_id);
