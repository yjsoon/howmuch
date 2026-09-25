-- Net worth replayed every transaction in the plan on each call, and age of
-- money replayed every income lot over the whole ledger.  Keep a per-account,
-- per-month net change so net worth reads months x accounts, and a small
-- knowledge-keyed cache so age of money is recomputed only when the ledger
-- actually moves.

CREATE TABLE IF NOT EXISTS account_month_balances (
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id),
  month TEXT NOT NULL,
  net_change_milli INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (plan_id, account_id, month)
);

CREATE INDEX IF NOT EXISTS idx_account_month_balances_plan_month
  ON account_month_balances(plan_id, month, account_id, net_change_milli);

CREATE TABLE IF NOT EXISTS report_cache (
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  cache_key TEXT NOT NULL,
  server_knowledge INTEGER NOT NULL,
  payload_json TEXT NOT NULL,
  computed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (plan_id, cache_key)
);

-- The aggregate is maintained by triggers rather than by each write path.
-- There are more than a dozen sites that insert, update or soft-delete a live
-- transaction across the shared repository, the D1 batch writer, the importers,
-- scheduled materialisation and the reconciliation adjustments; a trigger
-- cannot be missed by any of them, and it stays correct for raw-SQL fixtures
-- and bulk imports too.  Each trigger recomputes the affected (account, month)
-- from scratch, so it is idempotent and self-healing: an account, date, amount
-- or deleted-flag edit simply recomputes the pair it left and the pair it
-- joined.  A pair whose net change falls to zero is dropped, so a rebuild from
-- history reproduces the maintained row set exactly.
--
-- Any future migration that rebuilds the transactions table must recreate
-- these triggers.

CREATE TRIGGER IF NOT EXISTS account_month_balances_after_insert
AFTER INSERT ON transactions
BEGIN
  INSERT INTO account_month_balances (plan_id, account_id, month, net_change_milli, updated_at)
  VALUES (
    NEW.plan_id,
    NEW.account_id,
    substr(NEW.date, 1, 7),
    COALESCE((
      SELECT SUM(t.amount_milli) FROM transactions t
      WHERE t.plan_id = NEW.plan_id AND t.account_id = NEW.account_id AND t.deleted = 0
        AND t.date >= substr(NEW.date, 1, 7) || '-01'
        AND t.date < date(substr(NEW.date, 1, 7) || '-01', '+1 month')
    ), 0),
    CURRENT_TIMESTAMP
  )
  ON CONFLICT(plan_id, account_id, month) DO UPDATE SET
    net_change_milli = excluded.net_change_milli,
    updated_at = CURRENT_TIMESTAMP;

  DELETE FROM account_month_balances
  WHERE plan_id = NEW.plan_id AND account_id = NEW.account_id AND month = substr(NEW.date, 1, 7)
    AND net_change_milli = 0;

END;

CREATE TRIGGER IF NOT EXISTS account_month_balances_after_delete
AFTER DELETE ON transactions
BEGIN
  INSERT INTO account_month_balances (plan_id, account_id, month, net_change_milli, updated_at)
  VALUES (
    OLD.plan_id,
    OLD.account_id,
    substr(OLD.date, 1, 7),
    COALESCE((
      SELECT SUM(t.amount_milli) FROM transactions t
      WHERE t.plan_id = OLD.plan_id AND t.account_id = OLD.account_id AND t.deleted = 0
        AND t.date >= substr(OLD.date, 1, 7) || '-01'
        AND t.date < date(substr(OLD.date, 1, 7) || '-01', '+1 month')
    ), 0),
    CURRENT_TIMESTAMP
  )
  ON CONFLICT(plan_id, account_id, month) DO UPDATE SET
    net_change_milli = excluded.net_change_milli,
    updated_at = CURRENT_TIMESTAMP;

  DELETE FROM account_month_balances
  WHERE plan_id = OLD.plan_id AND account_id = OLD.account_id AND month = substr(OLD.date, 1, 7)
    AND net_change_milli = 0;

END;

-- The WHEN gate keeps balance-neutral writes -- cleared toggles, approvals,
-- server_knowledge stamps, transfer relinks, the ledger-sequence backfill --
-- off the aggregate entirely.
CREATE TRIGGER IF NOT EXISTS account_month_balances_after_update
AFTER UPDATE ON transactions
WHEN OLD.plan_id IS NOT NEW.plan_id
  OR OLD.account_id IS NOT NEW.account_id
  OR OLD.date IS NOT NEW.date
  OR OLD.amount_milli IS NOT NEW.amount_milli
  OR OLD.deleted IS NOT NEW.deleted
BEGIN
  INSERT INTO account_month_balances (plan_id, account_id, month, net_change_milli, updated_at)
  VALUES (
    OLD.plan_id,
    OLD.account_id,
    substr(OLD.date, 1, 7),
    COALESCE((
      SELECT SUM(t.amount_milli) FROM transactions t
      WHERE t.plan_id = OLD.plan_id AND t.account_id = OLD.account_id AND t.deleted = 0
        AND t.date >= substr(OLD.date, 1, 7) || '-01'
        AND t.date < date(substr(OLD.date, 1, 7) || '-01', '+1 month')
    ), 0),
    CURRENT_TIMESTAMP
  )
  ON CONFLICT(plan_id, account_id, month) DO UPDATE SET
    net_change_milli = excluded.net_change_milli,
    updated_at = CURRENT_TIMESTAMP;

  DELETE FROM account_month_balances
  WHERE plan_id = OLD.plan_id AND account_id = OLD.account_id AND month = substr(OLD.date, 1, 7)
    AND net_change_milli = 0;

  INSERT INTO account_month_balances (plan_id, account_id, month, net_change_milli, updated_at)
  VALUES (
    NEW.plan_id,
    NEW.account_id,
    substr(NEW.date, 1, 7),
    COALESCE((
      SELECT SUM(t.amount_milli) FROM transactions t
      WHERE t.plan_id = NEW.plan_id AND t.account_id = NEW.account_id AND t.deleted = 0
        AND t.date >= substr(NEW.date, 1, 7) || '-01'
        AND t.date < date(substr(NEW.date, 1, 7) || '-01', '+1 month')
    ), 0),
    CURRENT_TIMESTAMP
  )
  ON CONFLICT(plan_id, account_id, month) DO UPDATE SET
    net_change_milli = excluded.net_change_milli,
    updated_at = CURRENT_TIMESTAMP;

  DELETE FROM account_month_balances
  WHERE plan_id = NEW.plan_id AND account_id = NEW.account_id AND month = substr(NEW.date, 1, 7)
    AND net_change_milli = 0;

END;

-- Rebuild from history.  Idempotent, and the same statement the parity script
-- and the drift test use.
DELETE FROM account_month_balances;

INSERT INTO account_month_balances (plan_id, account_id, month, net_change_milli, updated_at)
SELECT t.plan_id, t.account_id, substr(t.date, 1, 7), SUM(t.amount_milli), CURRENT_TIMESTAMP
FROM transactions t
WHERE t.deleted = 0
GROUP BY t.plan_id, t.account_id, substr(t.date, 1, 7)
HAVING SUM(t.amount_milli) <> 0;
