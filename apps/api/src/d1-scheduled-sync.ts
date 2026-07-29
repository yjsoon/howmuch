import { D1Database } from "./d1";

export type D1Lease =
  | { status: "acquired"; runId: string; attemptId: string; serverKnowledge: number }
  | { status: "duplicate" | "leased"; runId: string };

/** Atomic lease state machine. Network/import work intentionally happens outside these batches. */
export class D1ScheduledSyncState {
  constructor(private readonly db: D1Database) {}

  async acquire(planId: string, runId: string, attemptId: string, scheduledFor: string): Promise<D1Lease> {
    const results = await this.db.atomicBatch([
      { sql: "INSERT INTO ynab_sync_state (plan_id) VALUES ($1) ON CONFLICT(plan_id) DO NOTHING", values: [planId] },
      { sql: `INSERT INTO sync_runs (id, plan_id, scheduled_for, status)
              VALUES ($1, $2, $3, 'running')
              ON CONFLICT(plan_id, scheduled_for) DO NOTHING`, values: [runId, planId, scheduledFor] },
      { sql: `INSERT INTO sync_attempts (id, run_id)
              SELECT $1, id FROM sync_runs
              WHERE plan_id = $2 AND scheduled_for = $3 AND status = 'running'
                AND EXISTS (SELECT 1 FROM ynab_sync_state WHERE plan_id = $2 AND ((lease_until IS NULL OR lease_until < CURRENT_TIMESTAMP) OR lease_id = $1))
              ON CONFLICT(id) DO NOTHING`,
        values: [attemptId, planId, scheduledFor] },
      { sql: `UPDATE sync_attempts SET status = 'expired', finished_at = CURRENT_TIMESTAMP, error = 'lease expired'
              WHERE id = (SELECT lease_id FROM ynab_sync_state WHERE plan_id = $1 AND lease_until < CURRENT_TIMESTAMP)
                AND id <> $2 AND status = 'running'`, values: [planId, attemptId] },
      { sql: `UPDATE ynab_sync_state SET lease_id = $2, lease_until = datetime('now', '+14 minutes'), updated_at = CURRENT_TIMESTAMP
              WHERE plan_id = $1 AND ((lease_until IS NULL OR lease_until < CURRENT_TIMESTAMP) OR lease_id = $2)
                AND EXISTS (SELECT 1 FROM sync_attempts sa JOIN sync_runs sr ON sr.id = sa.run_id
                            WHERE sa.id = $2 AND sa.status = 'running' AND sr.plan_id = $1 AND sr.status = 'running')`, values: [planId, attemptId] },
      { sql: `UPDATE sync_runs SET current_attempt_id = $2
              WHERE id = (SELECT run_id FROM sync_attempts WHERE id = $2) AND plan_id = $1 AND status = 'running'
                AND EXISTS (SELECT 1 FROM ynab_sync_state WHERE plan_id = $1 AND lease_id = $2)`, values: [planId, attemptId] },
      { sql: `UPDATE sync_runs SET status = 'leased', finished_at = CURRENT_TIMESTAMP,
                result_json = '{"reason":"another_sync_is_running"}'
              WHERE id = $1 AND plan_id = $2 AND status = 'running'
                AND current_attempt_id IS NULL
                AND NOT EXISTS (SELECT 1 FROM sync_attempts WHERE id = $3)
                AND NOT EXISTS (SELECT 1 FROM ynab_sync_state WHERE plan_id = $2 AND lease_id = $3)`,
        values: [runId, planId, attemptId] },
      { sql: "SELECT lease_id, server_knowledge FROM ynab_sync_state WHERE plan_id = $1", values: [planId] },
      { sql: "SELECT id, status FROM sync_runs WHERE plan_id = $1 AND scheduled_for = $2", values: [planId, scheduledFor] },
    ]);
    if (!results.every((result) => result.success)) throw new Error("D1 lease acquisition batch failed atomically");
    const lease = results[7]?.results?.[0] as { lease_id: string | null; server_knowledge: number } | undefined;
    const existing = results[8]?.results?.[0] as { id: string; status: string } | undefined;
    if (lease?.lease_id === attemptId) {
      return { status: "acquired", runId: existing?.id ?? runId, attemptId, serverKnowledge: Number(lease.server_knowledge) };
    }
    return existing?.status !== "running" && existing?.status !== "leased"
      ? { status: "duplicate", runId: existing?.id ?? runId }
      : { status: "leased", runId: existing?.id ?? runId };
  }

  async complete(planId: string, runId: string, attemptId: string, serverKnowledge: number, result: unknown): Promise<void> {
    await this.finish(planId, runId, attemptId,
      `UPDATE ynab_sync_state SET server_knowledge = MAX(server_knowledge, $3), lease_id = NULL, lease_until = NULL, updated_at = CURRENT_TIMESTAMP
       WHERE plan_id = $1 AND lease_id = $2 AND lease_until >= CURRENT_TIMESTAMP`,
      [planId, attemptId, serverKnowledge], "completed", canonicalJson(result), null,
      canonicalJson({ serverKnowledge, result }));
  }

  async fail(planId: string, runId: string, attemptId: string, error: string): Promise<void> {
    await this.finish(planId, runId, attemptId,
      `UPDATE ynab_sync_state SET lease_id = NULL, lease_until = NULL, updated_at = CURRENT_TIMESTAMP
       WHERE plan_id = $1 AND lease_id = $2 AND lease_until >= CURRENT_TIMESTAMP`,
      [planId, attemptId], "failed", "{}", error, canonicalJson({ error }));
  }

  async skip(planId: string, runId: string, attemptId: string, result: unknown): Promise<void> {
    await this.finish(planId, runId, attemptId,
      `UPDATE ynab_sync_state SET lease_id = NULL, lease_until = NULL, updated_at = CURRENT_TIMESTAMP
       WHERE plan_id = $1 AND lease_id = $2 AND lease_until >= CURRENT_TIMESTAMP`,
      [planId, attemptId], "skipped", canonicalJson(result), null, canonicalJson({ result }));
  }

  async renew(planId: string, runId: string, attemptId: string): Promise<void> {
    await this.db.atomicBatch([
      { sql: `INSERT INTO sync_renewal_receipts (id, plan_id, run_id, attempt_id) VALUES ($1, $2, $3, $4)
              ON CONFLICT(id) DO UPDATE SET renewed_at = CURRENT_TIMESTAMP`, values: [`renew:${planId}:${runId}:${attemptId}`, planId, runId, attemptId] },
      { sql: `UPDATE ynab_sync_state SET lease_until = datetime('now', '+14 minutes'), updated_at = CURRENT_TIMESTAMP
      WHERE plan_id = $1 AND lease_id = $3 AND lease_until >= CURRENT_TIMESTAMP
        AND EXISTS (SELECT 1 FROM sync_runs sr JOIN sync_attempts sa ON sa.id = $3 AND sa.run_id = sr.id
                    WHERE sr.id = $2 AND sr.plan_id = $1 AND sr.current_attempt_id = $3
                      AND sr.status = 'running' AND sa.status = 'running')`, values: [planId, runId, attemptId] },
    ]);
  }

  private async finish(planId: string, runId: string, attemptId: string, leaseSql: string, leaseValues: unknown[], status: string, result: string, error: string | null, receiptPayload: string) {
    const statements = [
      { sql: `INSERT INTO sync_transition_receipts (id, plan_id, run_id, attempt_id, status, payload_json)
              VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT(id) DO NOTHING`,
        values: [`${status}:${planId}:${runId}:${attemptId}`, planId, runId, attemptId, status, receiptPayload] },
      { sql: `UPDATE sync_runs SET status = $4, finished_at = CURRENT_TIMESTAMP, result_json = $5, error = $6
              WHERE id = $2 AND plan_id = $1 AND status = 'running' AND current_attempt_id = $3 AND EXISTS
                (SELECT 1 FROM ynab_sync_state WHERE plan_id = $1 AND lease_id = $3 AND lease_until >= CURRENT_TIMESTAMP)`,
        values: [planId, runId, attemptId, status, result, error] },
      { sql: `UPDATE sync_attempts SET status = $2, finished_at = CURRENT_TIMESTAMP, error = $3
              WHERE id = $1 AND status = 'running' AND EXISTS
                (SELECT 1 FROM ynab_sync_state WHERE plan_id = $4 AND lease_id = $1 AND lease_until >= CURRENT_TIMESTAMP)`,
        values: [attemptId, status, error, planId] },
      { sql: leaseSql, values: leaseValues },
    ];
    let results;
    try {
      results = await this.db.atomicBatch(statements);
    } catch {
      // A D1 transport failure can arrive after commit.  The stable receipt
      // turns this retry into a read-equivalent successful terminal replay.
      try {
        results = await this.db.atomicBatch(statements);
      } catch (cause) {
        throw new Error(`D1 scheduled-sync ${status} batch rejected: lease is no longer owned by ${attemptId}`, { cause });
      }
    }
    if (!results.every((item) => item.success)) {
      throw new Error(`D1 scheduled-sync ${status} batch rejected: lease is no longer owned by ${attemptId}`);
    }
  }
}

function canonicalJson(value: unknown): string {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const row = value as Record<string, unknown>;
  return `{${Object.keys(row).filter((key) => row[key] !== undefined).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(row[key])}`).join(",")}}`;
}
