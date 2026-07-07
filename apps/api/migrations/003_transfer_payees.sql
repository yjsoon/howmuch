-- YNAB parity: every account owns a "Transfer : <name>" payee so clients can
-- record transfers by picking a payee. Adopt payees that already carry the
-- conventional name, then provision the missing ones and point accounts at them.

UPDATE payees
SET transfer_account_id = (
  SELECT a.id FROM accounts a
  WHERE a.plan_id = payees.plan_id
    AND a.deleted = 0
    AND 'Transfer : ' || a.name = payees.name
)
WHERE transfer_account_id IS NULL
  AND deleted = 0
  AND name LIKE 'Transfer : %';

INSERT OR IGNORE INTO payees (id, plan_id, name, transfer_account_id, external_ynab_id)
SELECT 'payee-transfer-' || a.id, a.plan_id, 'Transfer : ' || a.name, a.id, 'payee-transfer-' || a.id
FROM accounts a
WHERE a.deleted = 0
  AND NOT EXISTS (
    SELECT 1 FROM payees p
    WHERE p.plan_id = a.plan_id AND p.transfer_account_id = a.id AND p.deleted = 0
  );

UPDATE accounts
SET transfer_payee_id = (
  SELECT p.id FROM payees p
  WHERE p.plan_id = accounts.plan_id AND p.transfer_account_id = accounts.id AND p.deleted = 0
  LIMIT 1
)
WHERE transfer_payee_id IS NULL
  AND deleted = 0;
