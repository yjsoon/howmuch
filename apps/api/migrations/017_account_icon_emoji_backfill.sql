-- 0013 skipped emoji+VS16 clusters (common for 👍) and ignored trailing
-- spaces, so leftover names such as "👍 Banana" kept the type-default icon.
-- Trim first, then lift a leading or trailing pictograph plus its optional
-- FE0F. Leave ZWJ sequences for the JS resolver. Only overwrite icons that
-- are still the type default so a custom pick is kept.

UPDATE accounts
SET name = trim(name)
WHERE deleted = 0
  AND name <> trim(name);

UPDATE accounts
SET
  icon = CASE
    WHEN length(name) >= 2 AND unicode(substr(name, 2, 1)) BETWEEN 0xFE00 AND 0xFE0F
      THEN substr(name, 1, 2)
    ELSE substr(name, 1, 1)
  END,
  name = CASE
    WHEN length(name) >= 2 AND unicode(substr(name, 2, 1)) BETWEEN 0xFE00 AND 0xFE0F
      THEN CASE WHEN trim(substr(name, 3)) = '' THEN name ELSE trim(substr(name, 3)) END
    ELSE CASE WHEN trim(substr(name, 2)) = '' THEN name ELSE trim(substr(name, 2)) END
  END
WHERE deleted = 0
  AND length(name) >= 1
  AND (
    unicode(substr(name, 1, 1)) BETWEEN 0x2600 AND 0x27BF
    OR unicode(substr(name, 1, 1)) BETWEEN 0x1F000 AND 0x1FAFF
  )
  AND (
    length(name) = 1
    OR unicode(substr(name, 2, 1)) <> 0x200D
  )
  AND (
    (COALESCE(type, 'checking') = 'checking' AND icon = '🏦')
    OR (type = 'savings' AND icon = '💰')
    OR (type = 'cash' AND icon = '💵')
    OR (type IN ('creditCard', 'lineOfCredit') AND icon = '💳')
    OR (type = 'otherAsset' AND icon = '📈')
    OR (type = 'otherLiability' AND icon = '📉')
    OR (type = 'mortgage' AND icon = '🏠')
    OR (type = 'autoLoan' AND icon = '🚗')
    OR (type = 'studentLoan' AND icon = '🎓')
    OR (type = 'medicalDebt' AND icon = '🏥')
    OR (type = 'otherLoan' AND icon = '📄')
    OR (
      icon = '🏦'
      AND COALESCE(type, 'checking') NOT IN (
        'savings', 'cash', 'creditCard', 'lineOfCredit', 'otherAsset',
        'otherLiability', 'mortgage', 'autoLoan', 'studentLoan', 'medicalDebt', 'otherLoan'
      )
    )
  );

UPDATE accounts
SET
  icon = CASE
    WHEN unicode(substr(name, length(name), 1)) BETWEEN 0xFE00 AND 0xFE0F
      THEN substr(name, length(name) - 1, 2)
    ELSE substr(name, length(name), 1)
  END,
  name = CASE
    WHEN unicode(substr(name, length(name), 1)) BETWEEN 0xFE00 AND 0xFE0F
      THEN CASE
        WHEN trim(substr(name, 1, length(name) - 2)) = '' THEN name
        ELSE trim(substr(name, 1, length(name) - 2))
      END
    ELSE CASE
      WHEN trim(substr(name, 1, length(name) - 1)) = '' THEN name
      ELSE trim(substr(name, 1, length(name) - 1))
    END
  END
WHERE deleted = 0
  AND length(name) >= 2
  AND (
    (
      unicode(substr(name, length(name), 1)) BETWEEN 0xFE00 AND 0xFE0F
      AND length(name) >= 3
      AND (
        unicode(substr(name, length(name) - 1, 1)) BETWEEN 0x2600 AND 0x27BF
        OR unicode(substr(name, length(name) - 1, 1)) BETWEEN 0x1F000 AND 0x1FAFF
      )
      AND unicode(substr(name, length(name) - 1, 1)) <> 0x200D
    )
    OR (
      (
        unicode(substr(name, length(name), 1)) BETWEEN 0x2600 AND 0x27BF
        OR unicode(substr(name, length(name), 1)) BETWEEN 0x1F000 AND 0x1FAFF
      )
      AND unicode(substr(name, length(name) - 1, 1)) NOT BETWEEN 0xFE00 AND 0xFE0F
      AND unicode(substr(name, length(name) - 1, 1)) <> 0x200D
      AND unicode(substr(name, length(name) - 1, 1)) NOT BETWEEN 0x1F3FB AND 0x1F3FF
    )
  )
  AND (
    (COALESCE(type, 'checking') = 'checking' AND icon = '🏦')
    OR (type = 'savings' AND icon = '💰')
    OR (type = 'cash' AND icon = '💵')
    OR (type IN ('creditCard', 'lineOfCredit') AND icon = '💳')
    OR (type = 'otherAsset' AND icon = '📈')
    OR (type = 'otherLiability' AND icon = '📉')
    OR (type = 'mortgage' AND icon = '🏠')
    OR (type = 'autoLoan' AND icon = '🚗')
    OR (type = 'studentLoan' AND icon = '🎓')
    OR (type = 'medicalDebt' AND icon = '🏥')
    OR (type = 'otherLoan' AND icon = '📄')
    OR (
      icon = '🏦'
      AND COALESCE(type, 'checking') NOT IN (
        'savings', 'cash', 'creditCard', 'lineOfCredit', 'otherAsset',
        'otherLiability', 'mortgage', 'autoLoan', 'studentLoan', 'medicalDebt', 'otherLoan'
      )
    )
  );

-- Strip a leftover name emoji after a custom icon was already chosen.
UPDATE accounts
SET name = CASE
  WHEN length(name) >= 2 AND unicode(substr(name, 2, 1)) BETWEEN 0xFE00 AND 0xFE0F
    THEN CASE WHEN trim(substr(name, 3)) = '' THEN name ELSE trim(substr(name, 3)) END
  ELSE CASE WHEN trim(substr(name, 2)) = '' THEN name ELSE trim(substr(name, 2)) END
END
WHERE deleted = 0
  AND length(name) >= 2
  AND (
    unicode(substr(name, 1, 1)) BETWEEN 0x2600 AND 0x27BF
    OR unicode(substr(name, 1, 1)) BETWEEN 0x1F000 AND 0x1FAFF
  )
  AND unicode(substr(name, 2, 1)) <> 0x200D;

UPDATE accounts
SET name = CASE
  WHEN unicode(substr(name, length(name), 1)) BETWEEN 0xFE00 AND 0xFE0F
    THEN CASE
      WHEN trim(substr(name, 1, length(name) - 2)) = '' THEN name
      ELSE trim(substr(name, 1, length(name) - 2))
    END
  ELSE CASE
    WHEN trim(substr(name, 1, length(name) - 1)) = '' THEN name
    ELSE trim(substr(name, 1, length(name) - 1))
  END
END
WHERE deleted = 0
  AND length(name) >= 2
  AND (
    (
      unicode(substr(name, length(name), 1)) BETWEEN 0xFE00 AND 0xFE0F
      AND length(name) >= 3
      AND (
        unicode(substr(name, length(name) - 1, 1)) BETWEEN 0x2600 AND 0x27BF
        OR unicode(substr(name, length(name) - 1, 1)) BETWEEN 0x1F000 AND 0x1FAFF
      )
    )
    OR (
      unicode(substr(name, length(name), 1)) BETWEEN 0x2600 AND 0x27BF
      OR unicode(substr(name, length(name), 1)) BETWEEN 0x1F000 AND 0x1FAFF
    )
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
