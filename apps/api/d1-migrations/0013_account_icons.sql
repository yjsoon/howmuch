ALTER TABLE accounts ADD COLUMN icon TEXT NOT NULL DEFAULT '🏦';

UPDATE accounts
SET icon = CASE type
  WHEN 'savings' THEN '💰'
  WHEN 'cash' THEN '💵'
  WHEN 'creditCard' THEN '💳'
  WHEN 'lineOfCredit' THEN '💳'
  WHEN 'otherAsset' THEN '📈'
  WHEN 'otherLiability' THEN '📉'
  WHEN 'mortgage' THEN '🏠'
  WHEN 'autoLoan' THEN '🚗'
  WHEN 'studentLoan' THEN '🎓'
  WHEN 'medicalDebt' THEN '🏥'
  WHEN 'otherLoan' THEN '📄'
  ELSE icon
END
WHERE type IS NOT NULL;

UPDATE accounts
SET
  icon = substr(name, 1, 1),
  name = CASE
    WHEN trim(substr(name, 2)) = '' THEN name
    ELSE trim(substr(name, 2))
  END
WHERE deleted = 0
  AND length(name) >= 1
  AND (
    unicode(substr(name, 1, 1)) BETWEEN 0x2600 AND 0x27BF
    OR unicode(substr(name, 1, 1)) BETWEEN 0x1F000 AND 0x1FAFF
  );

UPDATE payees
SET
  name = 'Transfer : ' || (SELECT a.name FROM accounts a WHERE a.id = payees.transfer_account_id),
  updated_at = CURRENT_TIMESTAMP
WHERE deleted = 0
  AND transfer_account_id IS NOT NULL
  AND name LIKE 'Transfer : %'
  AND EXISTS (
    SELECT 1 FROM accounts a
    WHERE a.id = payees.transfer_account_id
      AND payees.name <> 'Transfer : ' || a.name
  );
