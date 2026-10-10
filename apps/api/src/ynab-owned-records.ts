import { randomUUID } from "node:crypto";

/**
 * Turns a YNAB source object into HowMuch's own records.
 *
 * `ynab_raw_objects` is provenance only. The importer still stores every
 * source object there, and for the few that HowMuch serves it also writes the
 * record the app reads: imported schedules and their split lines into the
 * schedule tables, and the plan-level "came from YNAB" marker into
 * `plans.ynab_sourced`.
 *
 * Once a schedule exists in HowMuch's tables it is HowMuch's, lines included.
 * A later import never touches it, so local edits and deletions survive a
 * resync, and a schedule whose lines YNAB later replaces is not given a mix of
 * old and new lines. Migration 0019 / 022 copies the schedules imported before
 * this existed.
 */
export type OwnedRecordStatement = { sql: string; values: unknown[] };

// A reference that no longer resolves is stored as NULL in the indexed column
// (the payload keeps the original ID), as the migration does.
const refId = (table: "payees" | "categories" | "accounts", field: string) =>
  `(SELECT x.id FROM ${table} x WHERE x.id = json_extract(?3, '$.${field}'))`;

/**
 * Statements to run, in order, alongside the raw-object upsert. `lines` are the
 * schedule's split lines as YNAB sent them; they are stored only if this call
 * is what creates the schedule.
 */
export function ownedRecordStatements(
  planId: string,
  objectType: string,
  objectId: string,
  payloadJson: string,
  deleted: 0 | 1,
  lines: readonly unknown[] = [],
): OwnedRecordStatement[] {
  if (objectType === "month") {
    return [{ sql: "UPDATE plans SET ynab_sourced = 1 WHERE id = ?1 AND ynab_sourced = 0", values: [planId] }];
  }
  if (objectType !== "scheduled_transaction") return [];

  // `created_at` carries a one-off token while this call is the one creating
  // the schedule; the lines are accepted only against that token, and the last
  // statement restores the timestamp.
  const token = `ynab-import-${randomUUID()}`;
  const statements: OwnedRecordStatement[] = [{
    sql: `INSERT INTO scheduled_transaction_edits
      (plan_id, id, origin, payload_json, account_id, date_first, date_next, frequency, amount_milli,
       payee_id, category_id, transfer_account_id, deleted, created_at)
      SELECT ?1, ?2, 'ynab-overlay', ?3,
        json_extract(?3, '$.account_id'), json_extract(?3, '$.date_first'), json_extract(?3, '$.date_next'),
        json_extract(?3, '$.frequency'), CAST(json_extract(?3, '$.amount') AS INTEGER),
        ${refId("payees", "payee_id")}, ${refId("categories", "category_id")}, ${refId("accounts", "transfer_account_id")}, ?4, ?5
      WHERE true
      ON CONFLICT(plan_id, id) DO NOTHING`,
    values: [planId, objectId, payloadJson, deleted, token],
  }];
  for (const line of lines) {
    const lineJson = JSON.stringify(line);
    if (lineJson === undefined) continue;
    statements.push({
      sql: `INSERT INTO scheduled_subtransaction_edits
        (plan_id, id, scheduled_transaction_id, payload_json, amount_milli, payee_id, category_id, transfer_account_id)
        SELECT ?1, json_extract(?3, '$.id'), ?2, ?3, CAST(json_extract(?3, '$.amount') AS INTEGER),
          ${refId("payees", "payee_id")}, ${refId("categories", "category_id")}, ${refId("accounts", "transfer_account_id")}
        WHERE json_extract(?3, '$.id') IS NOT NULL
          AND COALESCE(json_extract(?3, '$.deleted'), 0) = 0
          AND EXISTS (SELECT 1 FROM scheduled_transaction_edits e WHERE e.plan_id = ?1 AND e.id = ?2 AND e.created_at = ?4)
        ON CONFLICT(plan_id, id) DO NOTHING`,
      values: [planId, objectId, lineJson, token],
    });
  }
  statements.push({
    sql: "UPDATE scheduled_transaction_edits SET created_at = updated_at WHERE plan_id = ?1 AND id = ?2 AND created_at = ?3",
    values: [planId, objectId, token],
  });
  return statements;
}
