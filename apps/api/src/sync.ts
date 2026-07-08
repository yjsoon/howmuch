import { DEFAULT_YNAB_MIN_SIMILARITY, DEFAULT_YNAB_SYNC_INTERVAL_MS, type ApiConfig } from "./config";
import { importYnabFromApi, listYnabPlans, type YnabImportResult } from "./importers/ynab";
import type { LedgerRepository } from "./repository";

export type YnabSyncLogger = Pick<Console, "log" | "warn" | "error">;

export type YnabSyncHandle = {
  /** Runs one sync pass, or joins the pass already in flight. */
  runNow(): Promise<YnabImportResult | null>;
  stop(): void;
};

/**
 * Periodically pulls the configured YNAB budget into the local ledger.
 * Returns null (and never schedules anything) when no YNAB token is
 * configured. Each pass re-imports through the importer's similarity guard,
 * so a populated ledger is only updated when the fetched data is at least
 * `ynabMinSimilarity` similar to what was previously imported.
 */
export function startYnabSync(
  repo: LedgerRepository,
  config: ApiConfig,
  logger: YnabSyncLogger = console,
): YnabSyncHandle | null {
  const token = config.ynabToken?.trim();
  if (!token) {
    return null;
  }

  const intervalMs = config.ynabSyncIntervalMs ?? DEFAULT_YNAB_SYNC_INTERVAL_MS;
  const minSimilarity = config.ynabMinSimilarity ?? DEFAULT_YNAB_MIN_SIMILARITY;
  let planId = config.ynabPlanId;
  let current: Promise<YnabImportResult | null> | null = null;
  let stopped = false;

  const runOnce = async (): Promise<YnabImportResult | null> => {
    try {
      if (!planId) {
        planId = await discoverPlanId(token, logger);
        if (!planId) {
          return null;
        }
      }
      const result = await importYnabFromApi(repo, { token, planId, minSimilarity });
      if (result.skipped) {
        logger.warn(
          `YNAB sync skipped for plan ${planId}: fetched data is only ${Math.round((result.similarity ?? 0) * 100)}% similar to the existing ledger (needs ${Math.round(minSimilarity * 100)}%)`,
        );
      } else {
        logger.log(`YNAB sync imported ${result.imported_transactions} transactions for plan ${planId}`);
      }
      return result;
    } catch (error) {
      logger.error(`YNAB sync failed: ${error instanceof Error ? error.message : String(error)}`);
      return null;
    }
  };

  const runNow = (): Promise<YnabImportResult | null> => {
    if (stopped) {
      return Promise.resolve(null);
    }
    if (!current) {
      current = runOnce().finally(() => {
        current = null;
      });
    }
    return current;
  };

  const timer = setInterval(() => void runNow(), intervalMs);
  void runNow();

  return {
    runNow,
    stop() {
      stopped = true;
      clearInterval(timer);
    },
  };
}

async function discoverPlanId(token: string, logger: YnabSyncLogger): Promise<string | undefined> {
  const plans = await listYnabPlans({ token });
  if (plans.length === 1) {
    logger.log(`YNAB sync using the only available plan: ${plans[0].name ?? plans[0].id} (${plans[0].id})`);
    return plans[0].id;
  }
  if (plans.length === 0) {
    logger.error("YNAB sync found no plans for the configured token; set HOWMUCH_YNAB_PLAN_ID once one exists");
  } else {
    const names = plans.map((plan) => `${plan.id} (${plan.name})`).join(", ");
    logger.error(`YNAB sync needs HOWMUCH_YNAB_PLAN_ID because the token can see multiple plans: ${names}`);
  }
  return undefined;
}
