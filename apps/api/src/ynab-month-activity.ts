/**
 * The materialised YNAB month activity baseline.
 *
 * `monthCategoryActivityDeltas` used to derive the source baseline by loading
 * every raw YNAB transaction and subtransaction object in the plan and parsing
 * them in the Worker, once per month view (53k objects / ~29 MB in
 * production). `ynab_source_month_activity` holds the same numbers keyed by
 * `(plan_id, month, category_id)` so a month view reads only its own month.
 *
 * The SELECT below is the single definition of that baseline. Migrations
 * `020_ynab_source_month_activity.sql` / `0017_ynab_source_month_activity.sql`
 * embed the unscoped form to backfill existing databases; the plan-scoped form
 * rebuilds one plan after a local YNAB import. `tests/ynab-month-activity.test.ts`
 * asserts the migration and this module agree on a fixture, so the two cannot
 * drift apart silently.
 *
 * Rules reproduced from the old in-Worker loop, exactly:
 *
 * - `deleted` is read from the payload, not from the `ynab_raw_objects.deleted`
 *   column, because the loop read the payload.
 * - A transaction only contributes when its payload `date` is a JSON string;
 *   its month is the first seven characters plus `-01`.
 * - Live subtransaction lines replace the parent line entirely. A transaction
 *   contributes its own category/amount only when no live subtransaction
 *   claims it. Subtransactions carry no date, so they inherit the parent's
 *   month and an orphan subtransaction contributes nothing.
 * - `category_id` is stored as the empty string when the payload has no
 *   category (JSON `null` or absent). That is a sentinel, not a category:
 *   the read path maps it to the plan's imported "Uncategorized" category,
 *   which can differ per month, so resolving it here would be wrong. A line
 *   whose payload carries a present-but-empty `category_id` was dropped by the
 *   old loop (`if (!categoryID) continue`) and is dropped here too.
 * - Amounts are integer milliunits. `integerMilliunits` threw on a
 *   non-integer; SQL truncates instead. YNAB only ever emits integers, and a
 *   silently truncated backfill row beats a migration that aborts mid-plan.
 */

const LINES = (planFilter: string) => `
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
    AND ${planFilter.replaceAll("@alias", "sub")}
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
    AND ${planFilter.replaceAll("@alias", "parent")}
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
`;

/** `INSERT … SELECT` that rebuilds the baseline for every plan in the database. */
export const REMATERIALISE_ALL_PLANS = `INSERT OR REPLACE INTO ynab_source_month_activity (plan_id, month, category_id, activity)
SELECT plan_id, month, category_id, SUM(amount) FROM (${LINES("1 = 1")})
GROUP BY plan_id, month, category_id`;

/** The same rebuild, scoped to one plan. Binds the plan ID twice. */
export const REMATERIALISE_ONE_PLAN = `INSERT OR REPLACE INTO ynab_source_month_activity (plan_id, month, category_id, activity)
SELECT plan_id, month, category_id, SUM(amount) FROM (${LINES("@alias.plan_id = ?")})
GROUP BY plan_id, month, category_id`;

/** Clears a plan's baseline so a rebuild cannot leave rows behind in a month a transaction moved out of. */
export const CLEAR_ONE_PLAN = "DELETE FROM ynab_source_month_activity WHERE plan_id = ?";
