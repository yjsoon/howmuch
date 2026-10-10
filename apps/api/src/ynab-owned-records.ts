/**
 * Turns a YNAB source object into HowMuch's own records.
 *
 * `ynab_raw_objects` is provenance only. The importer still stores every
 * source object there, and for the few that HowMuch serves it also writes the
 * record the app reads: imported schedules into the schedule tables, and the
 * plan-level "came from YNAB" marker into `plans.ynab_sourced`.
 *
 * Once a schedule exists in HowMuch's tables it is HowMuch's. A later import
 * never overwrites it, so local edits and deletions survive a resync.
 * Migration 0019 / 022 copies the schedules imported before this existed.
 */
export type OwnedRecordStatement = { sql: string; values: unknown[] };

// A reference that no longer resolves is stored as NULL in the indexed column
// (the payload keeps the original ID), as the migration does.
const refId = (table: "payees" | "categories" | "accounts", field: string) =>
  `(SELECT x.id FROM ${table} x WHERE x.id = json_extract(?3, '$.${field}'))`;

/** Statements to run, in order, alongside the raw-object upsert. */
export function ownedRecordStatements(
  planId: string,
  objectType: string,
  objectId: string,
  payloadJson: string,
  deleted: 0 | 1,
): OwnedRecordStatement[] {
  if (objectType === "month") {
    return [{ sql: "UPDATE plans SET ynab_sourced = 1 WHERE id = ?1 AND ynab_sourced = 0", values: [planId] }];
  }
  if (objectType === "scheduled_transaction") {
    return [{
      sql: `INSERT INTO scheduled_transaction_edits
        (plan_id, id, origin, payload_json, account_id, date_first, date_next, frequency, amount_milli,
         payee_id, category_id, transfer_account_id, deleted)
        SELECT ?1, ?2, 'ynab-overlay', ?3,
          json_extract(?3, '$.account_id'), json_extract(?3, '$.date_first'), json_extract(?3, '$.date_next'),
          json_extract(?3, '$.frequency'), CAST(json_extract(?3, '$.amount') AS INTEGER),
          ${refId("payees", "payee_id")}, ${refId("categories", "category_id")}, ${refId("accounts", "transfer_account_id")}, ?4
        WHERE true
        ON CONFLICT(plan_id, id) DO NOTHING`,
      values: [planId, objectId, payloadJson, deleted],
    }];
  }
  if (objectType === "scheduled_subtransaction") {
    // Only lines of a schedule that is still the unedited import: its stored
    // payload equals the mirror's. A schedule the user has since changed owns
    // its own lines.
    return [{
      sql: `INSERT INTO scheduled_subtransaction_edits
        (plan_id, id, scheduled_transaction_id, payload_json, amount_milli, payee_id, category_id, transfer_account_id)
        SELECT ?1, COALESCE(json_extract(?3, '$.id'), ?2), json_extract(?3, '$.scheduled_transaction_id'), ?3,
          CAST(json_extract(?3, '$.amount') AS INTEGER),
          ${refId("payees", "payee_id")}, ${refId("categories", "category_id")}, ${refId("accounts", "transfer_account_id")}
        WHERE COALESCE(json_extract(?3, '$.deleted'), 0) = 0
          AND EXISTS (
            SELECT 1 FROM scheduled_transaction_edits e
            JOIN ynab_raw_objects r ON r.plan_id = e.plan_id AND r.object_type = 'scheduled_transaction' AND r.object_id = e.id
            WHERE e.plan_id = ?1 AND e.id = json_extract(?3, '$.scheduled_transaction_id')
              AND e.origin = 'ynab-overlay' AND e.payload_json = r.payload_json
          )
        ON CONFLICT(plan_id, id) DO NOTHING`,
      values: [planId, objectId, payloadJson],
    }];
  }
  return [];
}
