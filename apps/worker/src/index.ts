import type { ApiConfig } from "../../api/src/config";
import { D1Database as HowMuchD1Database, type D1Binding } from "../../api/src/d1";
import { D1LedgerRepository } from "../../api/src/d1-ledger-repository";
import { D1ReportService } from "../../api/src/d1-reports";
import { runD1ScheduledYnabSync } from "../../api/src/d1-scheduled-sync-runner";
import { createHandler } from "../../api/src/http";

interface Env {
  ASSETS: Fetcher;
  DB: D1Binding;
  HOWMUCH_API_TOKEN: string;
  HOWMUCH_DEFAULT_PLAN_ID: string;
  HOWMUCH_YNAB_TOKEN?: string;
  HOWMUCH_YNAB_PLAN_ID?: string;
  HOWMUCH_YNAB_MIN_SIMILARITY?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    if (!pathname.startsWith("/api/") && !pathname.startsWith("/v1/") && pathname !== "/health") {
      return env.ASSETS.fetch(request);
    }

    const config = workerConfig(env);
    const database = new HowMuchD1Database(requiredBinding(env.DB, "DB"));
    return createHandler({ repo: new D1LedgerRepository(database, config.defaultPlanId), reports: new D1ReportService(database.binding), config })(request);
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    const result = await runD1ScheduledYnabSync({
      db: new HowMuchD1Database(requiredBinding(env.DB, "DB")), config: workerConfig(env), scheduledTime: controller.scheduledTime,
    });
    console.log(JSON.stringify({ event: "ynab_sync", ...result }));
  },
};

function workerConfig(env: Env): ApiConfig {
  return {
    dbPath: "",
    port: 0,
    apiToken: required(env.HOWMUCH_API_TOKEN, "HOWMUCH_API_TOKEN"),
    defaultPlanId: required(env.HOWMUCH_DEFAULT_PLAN_ID, "HOWMUCH_DEFAULT_PLAN_ID"),
    ynabToken: env.HOWMUCH_YNAB_TOKEN?.trim() || undefined,
    ynabPlanId: env.HOWMUCH_YNAB_PLAN_ID?.trim() || undefined,
    ynabMinSimilarity: ratio(env.HOWMUCH_YNAB_MIN_SIMILARITY) ?? 0.95,
  };
}

function required(value: string | undefined, name: string): string {
  const trimmed = value?.trim();
  if (!trimmed) throw new Error(`${name} is required`);
  return trimmed;
}

function ratio(value: string | undefined): number | undefined {
  const parsed = Number(value);
  return value && Number.isFinite(parsed) && parsed >= 0 && parsed <= 1 ? parsed : undefined;
}

function requiredBinding(value: D1Binding | undefined, name: string): D1Binding {
  if (!value) throw new Error(`${name} binding is required`);
  return value;
}
