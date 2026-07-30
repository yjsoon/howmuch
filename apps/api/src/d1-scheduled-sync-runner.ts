import { createHash } from "node:crypto";
import type { ApiConfig } from "./config";
import { createId } from "./ids";
import { importYnabFromApi } from "./importers/ynab";
import { D1Database } from "./d1";
import { D1LedgerRepository } from "./d1-ledger-repository";
import { D1ScheduledSyncState } from "./d1-scheduled-sync";
import type { ScheduledSyncResult } from "./scheduled-sync-result";

/** Runs one YNAB delta using D1's fenced lease and guarded ledger commands. */
export async function runD1ScheduledYnabSync(options: {
  db: D1Database;
  config: ApiConfig;
  scheduledTime: number;
  logger?: Pick<Console, "log" | "warn" | "error">;
  now?: () => number;
}): Promise<ScheduledSyncResult> {
  const { db, config, scheduledTime } = options;
  const logger = options.logger ?? console;
  const token = config.ynabToken?.trim();
  const planId = config.ynabPlanId?.trim();
  if (!token || !planId) throw new Error("Scheduled YNAB sync requires HOWMUCH_YNAB_TOKEN and HOWMUCH_YNAB_PLAN_ID");

  const unfenced = new D1LedgerRepository(db, config.defaultPlanId);
  await unfenced.ensurePlan(planId);
  const state = new D1ScheduledSyncState(db);
  const scheduledFor = new Date(scheduledTime).toISOString();
  const runId = `sync_${digest(`${planId}:${scheduledFor}`).slice(0, 24)}`;
  const attemptId = createId("attempt");
  const acquisition = await state.acquire(planId, runId, attemptId, scheduledFor);
  if (acquisition.status !== "acquired") return { status: acquisition.status, run_id: acquisition.runId };

  const lease = { planId, attemptId } as const;
  const repo = new D1LedgerRepository(db, config.defaultPlanId, {
    lease: (candidate) => candidate === planId ? lease : undefined,
    operationId: (kind, candidate, resource) => `syncop_${digest(`${attemptId}:${kind}:${candidate ?? ""}:${resource}`).slice(0, 24)}`,
  });
  const now = options.now ?? Date.now;
  let renewedAt = now();
  const progress = async () => {
    if (now() - renewedAt < 5 * 60_000) return;
    await state.renew(planId, acquisition.runId, attemptId);
    renewedAt = now();
  };

  try {
    const result = await importYnabFromApi(repo, {
      token,
      planId,
      lastKnowledgeOfServer: acquisition.serverKnowledge > 0 ? acquisition.serverKnowledge : undefined,
      minSimilarity: config.ynabMinSimilarity,
      warn: (message) => logger.warn(message),
      progress,
    });
    if (result.skipped) {
      await state.skip(planId, acquisition.runId, attemptId, result);
      return { status: "skipped", run_id: acquisition.runId, result };
    }
    if (result.server_knowledge == null) throw new Error("YNAB delta responses did not include a consistent server_knowledge cursor");
    await state.complete(planId, acquisition.runId, attemptId, result.server_knowledge, result);
    logger.log(`YNAB scheduled sync completed at knowledge ${result.server_knowledge}`);
    return { status: "completed", run_id: acquisition.runId, result };
  } catch (error) {
    try {
      await state.fail(planId, acquisition.runId, attemptId, error instanceof Error ? error.message : String(error));
    } catch (transitionError) {
      logger.error(`D1 scheduled-sync failure transition was rejected: ${transitionError instanceof Error ? transitionError.message : String(transitionError)}`);
    }
    logger.error(`YNAB scheduled sync failed: ${error instanceof Error ? error.message : String(error)}`);
    throw error;
  }
}

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
