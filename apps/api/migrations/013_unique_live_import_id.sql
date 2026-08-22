DELETE FROM transactions AS t
WHERE t.deleted = 0
  AND t.import_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM transactions AS keep
    WHERE keep.deleted = 0
      AND keep.plan_id = t.plan_id
      AND keep.import_id = t.import_id
      AND (
        keep.updated_at > t.updated_at
        OR (keep.updated_at = t.updated_at AND keep.id > t.id)
      )
  );

DROP INDEX IF EXISTS idx_transactions_import_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_transactions_live_import_id
  ON transactions(plan_id, import_id)
  WHERE import_id IS NOT NULL AND deleted = 0;
