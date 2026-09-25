-- Point lookups and paged register reads were scanning the live ledger.
CREATE INDEX IF NOT EXISTS idx_transactions_transfer_transaction_id
  ON transactions(transfer_transaction_id)
  WHERE transfer_transaction_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_subtransactions_transfer_transaction_id
  ON subtransactions(transfer_transaction_id)
  WHERE transfer_transaction_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_plan_live_register
  ON transactions(plan_id, date DESC, created_at DESC, id DESC)
  WHERE deleted = 0;

CREATE INDEX IF NOT EXISTS idx_transactions_account_live_register
  ON transactions(account_id, date DESC, created_at DESC, id DESC)
  WHERE deleted = 0;

CREATE INDEX IF NOT EXISTS idx_transactions_account_reconciled_date
  ON transactions(account_id, date)
  WHERE deleted = 0 AND cleared = 'reconciled';

CREATE INDEX IF NOT EXISTS idx_payees_plan_live_name
  ON payees(plan_id, name, id, transfer_account_id)
  WHERE deleted = 0;

CREATE INDEX IF NOT EXISTS idx_account_reconciliation_assertions_account_date
  ON account_reconciliation_assertions(plan_id, account_id, statement_date);
