export const DEFAULT_YNAB_SYNC_INTERVAL_MS = 60 * 60 * 1000;
// YNAB allows 200 requests per token per rolling hour and a sync pass costs a
// handful of them, so refuse intervals that could crowd out other consumers.
export const MIN_YNAB_SYNC_INTERVAL_MS = 5 * 60 * 1000;
export const DEFAULT_YNAB_MIN_SIMILARITY = 0.95;

export type ApiConfig = {
  dbPath: string;
  port: number;
  apiToken?: string;
  defaultPlanId: string;
  ynabToken?: string;
  ynabPlanId?: string;
  ynabSyncIntervalMs?: number;
  ynabMinSimilarity?: number;
};

export function loadConfig(env: Record<string, string | undefined> = Bun.env): ApiConfig {
  return {
    dbPath: env.HOWMUCH_DB_PATH ?? "data/howmuch.sqlite",
    port: Number(env.PORT ?? env.HOWMUCH_PORT ?? "8787"),
    apiToken: env.HOWMUCH_API_TOKEN,
    defaultPlanId: env.HOWMUCH_DEFAULT_PLAN_ID ?? "local-plan",
    ynabToken: emptyToUndefined(env.HOWMUCH_YNAB_TOKEN),
    ynabPlanId: emptyToUndefined(env.HOWMUCH_YNAB_PLAN_ID),
    ynabSyncIntervalMs: Math.max(
      positiveNumber(env.HOWMUCH_YNAB_SYNC_INTERVAL_MS) ?? DEFAULT_YNAB_SYNC_INTERVAL_MS,
      MIN_YNAB_SYNC_INTERVAL_MS,
    ),
    ynabMinSimilarity: ratio(env.HOWMUCH_YNAB_MIN_SIMILARITY) ?? DEFAULT_YNAB_MIN_SIMILARITY,
  };
}

function emptyToUndefined(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function positiveNumber(value: string | undefined): number | undefined {
  const parsed = Number(value);
  return value && Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

function ratio(value: string | undefined): number | undefined {
  const parsed = Number(value);
  return value && Number.isFinite(parsed) && parsed >= 0 && parsed <= 1 ? parsed : undefined;
}
