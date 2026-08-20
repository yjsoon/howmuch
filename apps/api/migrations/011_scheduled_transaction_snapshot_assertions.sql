-- Schedule PATCH/DELETE first reads an effective source row.  Keep the exact
-- source snapshot in the same write transaction so a stale merge aborts
-- instead of overwriting an unrelated concurrent schedule change.
CREATE TABLE IF NOT EXISTS scheduled_transaction_snapshot_assertions (
  command_id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  scheduled_transaction_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('edit', 'raw')),
  payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
  subtransactions_json TEXT NOT NULL CHECK (json_valid(subtransactions_json)),
  deleted INTEGER NOT NULL CHECK (deleted IN (0, 1))
);

CREATE TRIGGER scheduled_transaction_snapshot_assertions_guard
BEFORE INSERT ON scheduled_transaction_snapshot_assertions
WHEN (NEW.source = 'edit' AND NOT EXISTS (
  SELECT 1 FROM scheduled_transaction_edits e
  WHERE e.plan_id = NEW.plan_id
    AND e.id = NEW.scheduled_transaction_id
    AND e.payload_json = NEW.payload_json
    AND e.deleted = NEW.deleted
    AND COALESCE((
      SELECT json_group_array(payload_json)
      FROM (
        SELECT payload_json FROM scheduled_subtransaction_edits
        WHERE plan_id = NEW.plan_id AND scheduled_transaction_id = NEW.scheduled_transaction_id
        ORDER BY id
      )
    ), '[]') = NEW.subtransactions_json
)) OR (NEW.source = 'raw' AND (
  EXISTS (
    SELECT 1 FROM scheduled_transaction_edits e
    WHERE e.plan_id = NEW.plan_id AND e.id = NEW.scheduled_transaction_id
  ) OR NOT EXISTS (
    SELECT 1 FROM ynab_raw_objects r
    WHERE r.plan_id = NEW.plan_id
      AND r.object_type = 'scheduled_transaction'
      AND r.object_id = NEW.scheduled_transaction_id
      AND r.payload_json = NEW.payload_json
      AND r.deleted = NEW.deleted
      AND COALESCE((
        SELECT json_group_array(payload_json)
        FROM (
          SELECT payload_json FROM ynab_raw_objects
          WHERE plan_id = NEW.plan_id
            AND object_type = 'scheduled_subtransaction'
            AND json_extract(payload_json, '$.scheduled_transaction_id') = NEW.scheduled_transaction_id
            AND COALESCE(json_extract(payload_json, '$.deleted'), 0) = 0
          ORDER BY object_id
        )
      ), '[]') = NEW.subtransactions_json
  )
))
BEGIN SELECT RAISE(ABORT, 'stale scheduled transaction'); END;
