DELETE FROM transactions AS t
WHERE t.deleted = 0
  AND t.import_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM transactions AS keep
    WHERE keep.deleted = 0
      AND keep.plan_id = t.plan_id
      AND keep.account_id = t.account_id
      AND keep.import_id = t.import_id
      AND (
        keep.updated_at > t.updated_at
        OR (keep.updated_at = t.updated_at AND keep.id > t.id)
      )
  );

UPDATE accounts
SET
  balance_milli = opening_balance_milli + COALESCE((
    SELECT SUM(amount_milli) FROM transactions
    WHERE account_id = accounts.id AND deleted = 0
  ), 0),
  cleared_balance_milli = opening_balance_milli + COALESCE((
    SELECT SUM(amount_milli) FROM transactions
    WHERE account_id = accounts.id AND deleted = 0 AND cleared IN ('cleared', 'reconciled')
  ), 0),
  uncleared_balance_milli = COALESCE((
    SELECT SUM(amount_milli) FROM transactions
    WHERE account_id = accounts.id AND deleted = 0 AND cleared = 'uncleared'
  ), 0),
  updated_at = CURRENT_TIMESTAMP;

DROP INDEX IF EXISTS idx_transactions_import_id;
DROP INDEX IF EXISTS idx_transactions_live_import_id;
CREATE UNIQUE INDEX IF NOT EXISTS idx_transactions_live_import_id
  ON transactions(plan_id, account_id, import_id)
  WHERE import_id IS NOT NULL AND deleted = 0;
