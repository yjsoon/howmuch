/**
 * The materialised YNAB month activity baseline.
 *
 * `monthCategoryActivityDeltas` used to derive the source baseline by loading
 * every raw YNAB transaction and subtransaction object in the plan and parsing
 * them in the Worker, once per month view (53k objects / ~29 MB in
 * production). `ynab_source_month_activity` holds the same numbers keyed by
 * `(plan_id, month, category_id)` so a month view reads only its own month.
 *
 * The statement below is the single definition of that baseline. Migrations
 * `020_ynab_source_month_activity.sql` / `0017_ynab_source_month_activity.sql`
 * embed the unscoped form to backfill existing databases; the plan-scoped form
 * rebuilds one plan after a local YNAB import, and `scripts/lib/ynab-d1-bootstrap.ts`
 * appends it to the generated data statements, because a bootstrapped D1
 * migrates an empty database and would otherwise never materialise anything.
 *
 * `tests/ynab-month-activity.test.ts` pins this two ways: it compares both
 * migration files' embedded INSERT against the constant below as text, since a
 * migration's backfill only ever runs against an empty database in the tests
 * and behaviour alone could not catch drift; and it checks the result against
 * a straight transcription of the old loop over a fixture of edge cases.
 *
 * Rules reproduced from the old in-Worker loop, exactly:
 *
 * - `deleted` is read from the payload, not from the `ynab_raw_objects.deleted`
 *   column, because the loop read the payload.
 * - A transaction only contributes when its payload `date` is a JSON string;
 *   its month is the first seven characters plus `-01`.
 * - Live subtransaction lines replace the parent line entirely. A transaction
 *   contributes its own category and amount only when no live subtransaction
 *   claims it. Subtransactions carry no date, so they inherit the parent's
 *   month and an orphan subtransaction contributes nothing.
 * - `category_id` is stored as the empty string when the payload has no
 *   category (JSON `null` or absent). That is a sentinel, not a category: the
 *   read path maps it to the plan's imported "Uncategorized" category, which
 *   can differ per month, so resolving it here would be wrong.
 * - A line whose payload carries a present-but-empty `category_id` was dropped
 *   by the old loop (`if (!categoryID) continue`), so `has_category`
 *   distinguishes it from the sentinel and the final WHERE drops it. The drop
 *   happens after the split decision, because such a line still counted
 *   towards "this transaction has subtransaction lines".
 * - Amounts are integer milliunits. `integerMilliunits` threw on a
 *   non-integer; SQL truncates instead. YNAB only ever emits integers, and a
 *   silently truncated backfill row beats a migration that aborts mid-plan.
 *
 * Shape matters as much as the rules, because this runs once against 53,618
 * transaction objects on a production D1 that enforces a per-statement time
 * limit. Timings on a fixture of that size:
 *
 *   80.0s  joining on `json_extract(...)` expressions directly
 *   37.7s  the same keys lifted into CTE columns, but the CTEs flattened away
 *    0.15s `MATERIALIZED`, which is what is below
 *
 * SQLite cannot index an expression in a join, so the first two shapes both
 * re-evaluate `json_extract` per candidate pair — 53,618 x 810 of them. The
 * `MATERIALIZED` hints stop SQLite from flattening the CTEs back into the
 * outer query, so `transaction_key` becomes a real column of a temporary
 * table and the planner builds automatic indexes over it. Do not drop them:
 * the query stays correct without them and becomes 500 times slower.
 * `MATERIALIZED` needs SQLite 3.35 (2021); D1 is well past that.
 */

const CATEGORY = (alias: string) => `
    CASE WHEN json_extract(${alias}.payload_json, '$.category_id') IS NULL THEN ''
         ELSE CAST(json_extract(${alias}.payload_json, '$.category_id') AS TEXT) END AS category_id,
    CASE WHEN json_extract(${alias}.payload_json, '$.category_id') IS NULL THEN 0 ELSE 1 END AS has_category`;

const LINES = (planFilter: string) => `
WITH parents AS MATERIALIZED (
  SELECT
    parent.plan_id AS plan_id,
    CAST(COALESCE(json_extract(parent.payload_json, '$.id'), parent.object_id) AS TEXT) AS transaction_key,
    substr(json_extract(parent.payload_json, '$.date'), 1, 7) || '-01' AS month,${CATEGORY("parent")},
    CAST(COALESCE(json_extract(parent.payload_json, '$.amount'), 0) AS INTEGER) AS amount
  FROM ynab_raw_objects parent
  WHERE parent.object_type = 'transaction'
    AND ${planFilter.replaceAll("@alias", "parent")}
    AND COALESCE(json_extract(parent.payload_json, '$.deleted'), 0) = 0
    AND json_type(parent.payload_json, '$.date') = 'text'
),
subs AS MATERIALIZED (
  SELECT
    sub.plan_id AS plan_id,
    CAST(json_extract(sub.payload_json, '$.transaction_id') AS TEXT) AS transaction_key,${CATEGORY("sub")},
    CAST(COALESCE(json_extract(sub.payload_json, '$.amount'), 0) AS INTEGER) AS amount
  FROM ynab_raw_objects sub
  WHERE sub.object_type = 'subtransaction'
    AND ${planFilter.replaceAll("@alias", "sub")}
    AND COALESCE(json_extract(sub.payload_json, '$.deleted'), 0) = 0
    AND json_extract(sub.payload_json, '$.transaction_id') IS NOT NULL
    AND CAST(json_extract(sub.payload_json, '$.transaction_id') AS TEXT) <> ''
),
split_keys AS (SELECT DISTINCT plan_id, transaction_key FROM subs),
lines AS (
  SELECT parents.plan_id, parents.month, subs.category_id, subs.has_category, subs.amount
  FROM subs
  JOIN parents ON parents.plan_id = subs.plan_id AND parents.transaction_key = subs.transaction_key

  UNION ALL

  SELECT parents.plan_id, parents.month, parents.category_id, parents.has_category, parents.amount
  FROM parents
  LEFT JOIN split_keys
    ON split_keys.plan_id = parents.plan_id AND split_keys.transaction_key = parents.transaction_key
  WHERE split_keys.transaction_key IS NULL
)
SELECT plan_id, month, category_id, SUM(amount) AS activity
FROM lines
WHERE NOT (has_category = 1 AND category_id = '')
GROUP BY plan_id, month, category_id`;

/** `INSERT … SELECT` that rebuilds the baseline for every plan in the database. */
export const REMATERIALISE_ALL_PLANS =
  `INSERT OR REPLACE INTO ynab_source_month_activity (plan_id, month, category_id, activity)${LINES("1 = 1")}`;

/** The same rebuild, scoped to one plan. Binds the plan ID twice. */
export const REMATERIALISE_ONE_PLAN =
  `INSERT OR REPLACE INTO ynab_source_month_activity (plan_id, month, category_id, activity)${LINES("@alias.plan_id = ?")}`;

/** Clears a plan's baseline so a rebuild cannot leave rows behind in a month a transaction moved out of. */
export const CLEAR_ONE_PLAN = "DELETE FROM ynab_source_month_activity WHERE plan_id = ?";
