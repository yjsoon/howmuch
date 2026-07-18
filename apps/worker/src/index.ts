import { Client } from "@neondatabase/serverless";
import type { ApiConfig } from "../../api/src/config";
import { createHandler } from "../../api/src/http";
import { PostgresDatabase } from "../../api/src/postgres";
import { PostgresReportService } from "../../api/src/postgres-reports";
import { LedgerRepository } from "../../api/src/repository";
import { PostgresRepositoryDatabase } from "../../api/src/repository-db";
import { runScheduledYnabSync } from "../../api/src/scheduled-sync";

interface Env {
  ASSETS: Fetcher;
  DATABASE_URL: string;
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

    return withDatabase(env, async (database) => {
      const config = workerConfig(env);
      const repo = new LedgerRepository(new PostgresRepositoryDatabase(database), config.defaultPlanId);
      return createHandler({ repo, reports: new PostgresReportService(database), config })(request);
    });
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    await withDatabase(env, async (database) => {
      const config = workerConfig(env);
      const repo = new LedgerRepository(new PostgresRepositoryDatabase(database), config.defaultPlanId);
      const result = await runScheduledYnabSync({
        db: database,
        repo,
        config,
        scheduledTime: controller.scheduledTime,
      });
      console.log(JSON.stringify({ event: "ynab_sync", ...result }));
    });
  },
};

async function withDatabase<Result>(env: Env, callback: (database: PostgresDatabase) => Promise<Result>): Promise<Result> {
  const client = new Client(required(env.DATABASE_URL, "DATABASE_URL"));
  await client.connect();
  try {
    return await callback(new PostgresDatabase(client));
  } finally {
    await client.end();
  }
}

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
