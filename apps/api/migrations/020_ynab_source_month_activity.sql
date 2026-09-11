-- Materialise the YNAB month activity baseline.
--
-- `GET /v1/plans/:id/months/:month` used to rebuild this baseline in the
-- Worker on every request by loading every raw YNAB transaction and
-- subtransaction object in the plan (53,618 transaction objects / ~29 MB of
-- JSON in production) and filtering them by date after parsing.  The raw
-- mirror has no date column, so no index could scope that scan.
--
-- This table holds the same numbers keyed by month, so a month view reads only
-- its own month.  It does not replace `ynab_raw_objects`: nothing is pruned
-- here (see #161), and the mirror stays the provenance record.
--
-- `category_id = ''` is a sentinel meaning "the source line had no category".
-- The read path maps it to the plan's imported "Uncategorized" category, which
-- is resolved per month from the month snapshot, so it cannot be baked in here.
--
-- The backfill below is the same SELECT as `apps/api/src/ynab-month-activity.ts`,
-- which rebuilds one plan after a local YNAB import.  `tests/ynab-month-activity.test.ts`
-- runs both against a fixture and asserts they agree.
CREATE TABLE IF NOT EXISTS ynab_source_month_activity (
  plan_id TEXT NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  month TEXT NOT NULL,
  category_id TEXT NOT NULL,
  activity INTEGER NOT NULL,
  PRIMARY KEY (plan_id, month, category_id)
);

INSERT OR REPLACE INTO ynab_source_month_activity (plan_id, month, category_id, activity)
SELECT plan_id, month, category_id, SUM(amount) FROM (
  SELECT
    sub.plan_id AS plan_id,
    substr(json_extract(parent.payload_json, '$.date'), 1, 7) || '-01' AS month,
    CASE WHEN json_extract(sub.payload_json, '$.category_id') IS NULL THEN ''
         ELSE CAST(json_extract(sub.payload_json, '$.category_id') AS TEXT) END AS category_id,
    CAST(COALESCE(json_extract(sub.payload_json, '$.amount'), 0) AS INTEGER) AS amount
  FROM ynab_raw_objects sub
  JOIN ynab_raw_objects parent
    ON parent.plan_id = sub.plan_id
   AND parent.object_type = 'transaction'
   AND COALESCE(json_extract(parent.payload_json, '$.deleted'), 0) = 0
   AND json_type(parent.payload_json, '$.date') = 'text'
   AND CAST(COALESCE(json_extract(parent.payload_json, '$.id'), parent.object_id) AS TEXT)
       = CAST(json_extract(sub.payload_json, '$.transaction_id') AS TEXT)
  WHERE sub.object_type = 'subtransaction'
    AND 1 = 1
    AND COALESCE(json_extract(sub.payload_json, '$.deleted'), 0) = 0
    AND json_extract(sub.payload_json, '$.transaction_id') IS NOT NULL
    AND CAST(json_extract(sub.payload_json, '$.transaction_id') AS TEXT) <> ''
    AND NOT (json_extract(sub.payload_json, '$.category_id') IS NOT NULL
             AND CAST(json_extract(sub.payload_json, '$.category_id') AS TEXT) = '')

  UNION ALL

  SELECT
    parent.plan_id AS plan_id,
    substr(json_extract(parent.payload_json, '$.date'), 1, 7) || '-01' AS month,
    CASE WHEN json_extract(parent.payload_json, '$.category_id') IS NULL THEN ''
         ELSE CAST(json_extract(parent.payload_json, '$.category_id') AS TEXT) END AS category_id,
    CAST(COALESCE(json_extract(parent.payload_json, '$.amount'), 0) AS INTEGER) AS amount
  FROM ynab_raw_objects parent
  WHERE parent.object_type = 'transaction'
    AND 1 = 1
    AND COALESCE(json_extract(parent.payload_json, '$.deleted'), 0) = 0
    AND json_type(parent.payload_json, '$.date') = 'text'
    AND NOT (json_extract(parent.payload_json, '$.category_id') IS NOT NULL
             AND CAST(json_extract(parent.payload_json, '$.category_id') AS TEXT) = '')
    AND NOT EXISTS (
      SELECT 1 FROM ynab_raw_objects sub
      WHERE sub.plan_id = parent.plan_id
        AND sub.object_type = 'subtransaction'
        AND COALESCE(json_extract(sub.payload_json, '$.deleted'), 0) = 0
        AND json_extract(sub.payload_json, '$.transaction_id') IS NOT NULL
        AND CAST(json_extract(sub.payload_json, '$.transaction_id') AS TEXT)
            = CAST(COALESCE(json_extract(parent.payload_json, '$.id'), parent.object_id) AS TEXT)
    )
)
GROUP BY plan_id, month, category_id;
