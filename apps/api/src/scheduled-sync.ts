import type { ApiConfig } from "./config";
import { createId } from "./ids";
import { importYnabFromApi, type YnabImportResult } from "./importers/ynab";
import type { AsyncSqlDatabase } from "./postgres";
import type { LedgerStore } from "./storage";

export type ScheduledSyncResult =
  | { status: "completed"; run_id: string; result: YnabImportResult }
  | { status: "duplicate" | "leased" | "skipped"; run_id: string; result?: YnabImportResult };

/**
 * Runs one recoverable YNAB delta pass. The database lease prevents overlap,
 * while the scheduled timestamp makes Cloudflare retries idempotent.
 */
export async function runScheduledYnabSync(options: {
  db: AsyncSqlDatabase;
  repo: LedgerStore;
  config: ApiConfig;
  scheduledTime: number;
  logger?: Pick<Console, "log" | "warn" | "error">;
}): Promise<ScheduledSyncResult> {
  const { db, repo, config, scheduledTime } = options;
  const logger = options.logger ?? console;
  const token = config.ynabToken?.trim();
  const planId = config.ynabPlanId?.trim();
  if (!token || !planId) throw new Error("Scheduled YNAB sync requires HOWMUCH_YNAB_TOKEN and HOWMUCH_YNAB_PLAN_ID");

  await repo.ensurePlan(planId);
  const runId = createId("sync");
  const scheduledFor = new Date(scheduledTime).toISOString();
  const acquisition = await db.transaction(async (transaction) => {
    const run = await transaction.get(
      `INSERT INTO sync_runs (id, plan_id, scheduled_for)
       VALUES ($1, $2, $3)
       ON CONFLICT (plan_id, scheduled_for) DO NOTHING
       RETURNING id`,
      [runId, planId, scheduledFor],
    );
    if (!run) {
      const existing = await transaction.get<{ id: string }>(
        `SELECT id FROM sync_runs WHERE plan_id = $1 AND scheduled_for = $2`,
        [planId, scheduledFor],
      );
      return { status: "duplicate" as const, knowledge: 0, runId: existing?.id ?? runId };
    }

    await transaction.run(
      `INSERT INTO ynab_sync_state (plan_id) VALUES ($1)
       ON CONFLICT (plan_id) DO NOTHING`,
      [planId],
    );
    const lease = await transaction.get<{ server_knowledge: string | number }>(
      `UPDATE ynab_sync_state
       SET lease_id = $2, lease_until = CURRENT_TIMESTAMP + INTERVAL '14 minutes', updated_at = CURRENT_TIMESTAMP
       WHERE plan_id = $1 AND (lease_until IS NULL OR lease_until < CURRENT_TIMESTAMP)
       RETURNING server_knowledge`,
      [planId, runId],
    );
    if (!lease) {
      await transaction.run(
        `UPDATE sync_runs SET status = 'leased', finished_at = CURRENT_TIMESTAMP,
           result_json = '{"reason":"another_sync_is_running"}'::jsonb WHERE id = $1`,
        [runId],
      );
      return { status: "leased" as const, knowledge: 0, runId };
    }
    return { status: "acquired" as const, knowledge: Number(lease.server_knowledge), runId };
  });

  const acquiredRunId = acquisition.runId;
  if (acquisition.status === "duplicate") return { status: "duplicate", run_id: acquiredRunId };
  if (acquisition.status === "leased") return { status: "leased", run_id: acquiredRunId };

  try {
    const result = await importYnabFromApi(repo, {
      token,
      planId,
      lastKnowledgeOfServer: acquisition.knowledge > 0 ? acquisition.knowledge : undefined,
      minSimilarity: config.ynabMinSimilarity,
      warn: (message) => logger.warn(message),
    });
    if (result.skipped) {
      await finish(db, planId, acquiredRunId, "skipped", result);
      return { status: "skipped", run_id: acquiredRunId, result };
    }
    if (result.server_knowledge == null) {
      throw new Error("YNAB delta responses did not include a consistent server_knowledge cursor");
    }

    await db.transaction(async (transaction) => {
      await transaction.run(
        `UPDATE ynab_sync_state
         SET server_knowledge = GREATEST(server_knowledge, $3), lease_id = NULL, lease_until = NULL, updated_at = CURRENT_TIMESTAMP
         WHERE plan_id = $1 AND lease_id = $2`,
        [planId, acquiredRunId, result.server_knowledge],
      );
      await transaction.run(
        `UPDATE sync_runs SET status = 'completed', finished_at = CURRENT_TIMESTAMP, result_json = $2::jsonb WHERE id = $1`,
        [acquiredRunId, JSON.stringify(result)],
      );
    });
    logger.log(`YNAB scheduled sync completed at knowledge ${result.server_knowledge}`);
    return { status: "completed", run_id: acquiredRunId, result };
  } catch (error) {
    await db.transaction(async (transaction) => {
      await transaction.run(
        `UPDATE ynab_sync_state SET lease_id = NULL, lease_until = NULL, updated_at = CURRENT_TIMESTAMP
         WHERE plan_id = $1 AND lease_id = $2`,
        [planId, acquiredRunId],
      );
      await transaction.run(
        `UPDATE sync_runs SET status = 'failed', finished_at = CURRENT_TIMESTAMP, error = $2 WHERE id = $1`,
        [acquiredRunId, error instanceof Error ? error.message : String(error)],
      );
    });
    logger.error(`YNAB scheduled sync failed: ${error instanceof Error ? error.message : String(error)}`);
    throw error;
  }
}

async function finish(
  db: AsyncSqlDatabase,
  planId: string,
  runId: string,
  status: string,
  result: YnabImportResult,
): Promise<void> {
  await db.transaction(async (transaction) => {
    await transaction.run(
      `UPDATE ynab_sync_state SET lease_id = NULL, lease_until = NULL, updated_at = CURRENT_TIMESTAMP
       WHERE plan_id = $1 AND lease_id = $2`,
      [planId, runId],
    );
    await transaction.run(
      `UPDATE sync_runs SET status = $2, finished_at = CURRENT_TIMESTAMP, result_json = $3::jsonb WHERE id = $1`,
      [runId, status, JSON.stringify(result)],
    );
  });
}
