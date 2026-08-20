-- A reconciliation is planned from a precise account/transaction snapshot.
-- The assertion executes inside the same transaction as the state change.
CREATE TABLE IF NOT EXISTS account_reconciliation_assertions (
  command_id TEXT PRIMARY KEY,
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  statement_date TEXT NOT NULL,
  prior_reconciled_balance_milli INTEGER NOT NULL,
  projected_reconciled_balance_milli INTEGER NOT NULL,
  candidate_ids_json TEXT NOT NULL CHECK (json_valid(candidate_ids_json))
);

CREATE TRIGGER account_reconciliation_assertions_guard
BEFORE INSERT ON account_reconciliation_assertions
WHEN NOT EXISTS (
  SELECT 1 FROM accounts a
  WHERE a.id = NEW.account_id AND a.plan_id = NEW.plan_id AND a.deleted = 0
) OR NEW.prior_reconciled_balance_milli <> (
  SELECT a.opening_balance_milli + COALESCE(SUM(CASE
    WHEN t.deleted = 0 AND t.cleared = 'reconciled' THEN t.amount_milli ELSE 0 END), 0)
  FROM accounts a LEFT JOIN transactions t ON t.account_id = a.id
  WHERE a.id = NEW.account_id AND a.plan_id = NEW.plan_id
  GROUP BY a.id
) OR NEW.projected_reconciled_balance_milli <> (
  SELECT a.opening_balance_milli + COALESCE(SUM(CASE
    WHEN t.deleted = 0 AND (
      t.cleared = 'reconciled' OR (t.cleared = 'cleared' AND t.date <= NEW.statement_date)
    ) THEN t.amount_milli ELSE 0 END), 0)
  FROM accounts a LEFT JOIN transactions t ON t.account_id = a.id
  WHERE a.id = NEW.account_id AND a.plan_id = NEW.plan_id
  GROUP BY a.id
) OR NEW.candidate_ids_json <> COALESCE((
  SELECT json_group_array(id) FROM (
    SELECT id FROM transactions
    WHERE plan_id = NEW.plan_id AND account_id = NEW.account_id
      AND deleted = 0 AND cleared = 'cleared' AND date <= NEW.statement_date
    ORDER BY id
  )
), '[]')
BEGIN SELECT RAISE(ABORT, 'stale account reconciliation'); END;
