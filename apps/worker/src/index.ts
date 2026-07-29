import { Client } from "@neondatabase/serverless";
import type { ApiConfig } from "../../api/src/config";
import { D1Database as HowMuchD1Database, type D1Binding } from "../../api/src/d1";
import { D1LedgerRepository } from "../../api/src/d1-ledger-repository";
import { D1ReportService } from "../../api/src/d1-reports";
import { runD1ScheduledYnabSync } from "../../api/src/d1-scheduled-sync-runner";
import { createHandler } from "../../api/src/http";
import { PostgresDatabase } from "../../api/src/postgres";
import { PostgresReportService } from "../../api/src/postgres-reports";
import { LedgerRepository } from "../../api/src/repository";
import { PostgresRepositoryDatabase } from "../../api/src/repository-db";
import { runScheduledYnabSync } from "../../api/src/scheduled-sync";

interface Env {
  ASSETS: Fetcher;
  DB?: D1Binding;
  DATABASE_URL: string;
  HOWMUCH_API_TOKEN: string;
  HOWMUCH_DEFAULT_PLAN_ID: string;
  HOWMUCH_YNAB_TOKEN?: string;
  HOWMUCH_YNAB_PLAN_ID?: string;
  HOWMUCH_YNAB_MIN_SIMILARITY?: string;
  HOWMUCH_DATABASE_BACKEND?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    if (!pathname.startsWith("/api/") && !pathname.startsWith("/v1/") && pathname !== "/health") {
      return env.ASSETS.fetch(request);
    }

    const config = workerConfig(env);
    if (databaseBackend(env) === "d1") {
      const database = new HowMuchD1Database(requiredBinding(env.DB, "DB"));
      return createHandler({ repo: new D1LedgerRepository(database, config.defaultPlanId), reports: new D1ReportService(database.binding), config })(request);
    }
    return withDatabase(env, async (database) => createHandler({
      repo: new LedgerRepository(new PostgresRepositoryDatabase(database), config.defaultPlanId),
      reports: new PostgresReportService(database), config,
    })(request));
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    if (databaseBackend(env) === "d1") {
      const result = await runD1ScheduledYnabSync({
        db: new HowMuchD1Database(requiredBinding(env.DB, "DB")), config: workerConfig(env), scheduledTime: controller.scheduledTime,
      });
      console.log(JSON.stringify({ event: "ynab_sync", ...result }));
      return;
    }
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

function databaseBackend(env: Env): "neon" | "d1" {
  const value = env.HOWMUCH_DATABASE_BACKEND?.trim().toLowerCase() || "neon";
  if (value !== "neon" && value !== "d1") throw new Error("HOWMUCH_DATABASE_BACKEND must be neon or d1");
  return value;
}

function requiredBinding(value: D1Binding | undefined, name: string): D1Binding {
  if (!value) throw new Error(`${name} binding is required when HOWMUCH_DATABASE_BACKEND=d1`);
  return value;
}
