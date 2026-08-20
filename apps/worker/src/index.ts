import type { ApiConfig } from "../../api/src/config";
import { D1Database as HowMuchD1Database, type D1Binding } from "../../api/src/d1";
import { D1LedgerRepository } from "../../api/src/d1-ledger-repository";
import { D1ReportService } from "../../api/src/d1-reports";
import { runDailyScheduledMaterialization } from "../../api/src/scheduled-materialization-runner";
import { createHandler } from "../../api/src/http";
import { D1AuthStore } from "../../api/src/auth-store";

interface Env {
  ASSETS: Fetcher;
  DB: D1Binding;
  HOWMUCH_API_TOKEN: string;
  HOWMUCH_DEFAULT_PLAN_ID: string;
  HOWMUCH_TIME_ZONE: string;
}

const APP_SITE_ASSOCIATION = JSON.stringify({
  webcredentials: {
    apps: ["XL5JK4F896.sg.soon.howmuch"],
  },
});

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    if (pathname === "/.well-known/apple-app-site-association" || pathname === "/apple-app-site-association") {
      return new Response(APP_SITE_ASSOCIATION, {
        headers: {
          "content-type": "application/json",
          "cache-control": "public, max-age=3600",
        },
      });
    }
    if (!pathname.startsWith("/api/") && !pathname.startsWith("/v1/") && pathname !== "/health") {
      return env.ASSETS.fetch(request);
    }

    const config = workerConfig(env);
    const database = new HowMuchD1Database(requiredBinding(env.DB, "DB"));
    return createHandler({ repo: new D1LedgerRepository(database, config.defaultPlanId), reports: new D1ReportService(database.binding), auth: new D1AuthStore(database), config })(request);
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    const config = workerConfig(env);
    const database = new HowMuchD1Database(requiredBinding(env.DB, "DB"));
    const result = await runDailyScheduledMaterialization({
      repo: new D1LedgerRepository(database, config.defaultPlanId),
      planId: config.defaultPlanId,
      timeZone: config.timeZone,
      scheduledTime: controller.scheduledTime,
    });
    console.log(JSON.stringify({ event: "scheduled_materialization", ...result }));
    // The repository has already given unrelated schedules their bounded chance
    // to run. Fail after the count-only log so Cloudflare records a retryable,
    // observable cron failure without exposing schedule or transaction data.
    if (result.failure_count > 0) {
      throw new Error("Scheduled materialisation completed with schedule failures");
    }
  },
};

function workerConfig(env: Env): ApiConfig & { timeZone: string } {
  return {
    dbPath: "",
    port: 0,
    apiToken: required(env.HOWMUCH_API_TOKEN, "HOWMUCH_API_TOKEN"),
    defaultPlanId: required(env.HOWMUCH_DEFAULT_PLAN_ID, "HOWMUCH_DEFAULT_PLAN_ID"),
    timeZone: required(env.HOWMUCH_TIME_ZONE, "HOWMUCH_TIME_ZONE"),
  };
}

function required(value: string | undefined, name: string): string {
  const trimmed = value?.trim();
  if (!trimmed) throw new Error(`${name} is required`);
  return trimmed;
}

function requiredBinding(value: D1Binding | undefined, name: string): D1Binding {
  if (!value) throw new Error(`${name} binding is required`);
  return value;
}
