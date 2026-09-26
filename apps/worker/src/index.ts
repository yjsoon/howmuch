import type { ApiConfig } from "../../api/src/config";
import { D1Database as HowMuchD1Database, type D1Binding } from "../../api/src/d1";
import { D1LedgerRepository } from "../../api/src/d1-ledger-repository";
import { D1ReportService } from "../../api/src/d1-reports";
import { runDailyScheduledMaterialization } from "../../api/src/scheduled-materialization-runner";
import { runD1ScheduledYnabSync } from "../../api/src/d1-scheduled-sync-runner";
import { createHandler } from "../../api/src/http";
import { D1AuthStore } from "../../api/src/auth-store";
import { withDocumentSecurityHeaders } from "./security-headers";

const YNAB_TRANSITION_CRON = "10 16 * * *";
const SCHEDULED_MATERIALIZATION_CRON = "5 16 * * *";

interface Env {
  ASSETS: Fetcher;
  DB: D1Binding;
  HOWMUCH_API_TOKEN: string;
  HOWMUCH_DEFAULT_PLAN_ID: string;
  HOWMUCH_TIME_ZONE: string;
  HOWMUCH_YNAB_TOKEN?: string;
  HOWMUCH_YNAB_PLAN_ID?: string;
  HOWMUCH_TRANSITION_READ_ONLY?: string;
  HOWMUCH_REDIRECT_TARGET?: string;
  TYPESAFE_API_KEY?: string;
  TYPESAFE_MODEL?: string;
}

const APP_SITE_ASSOCIATION = JSON.stringify({
  webcredentials: {
    apps: ["PQ6U5ESLN2.sg.soon.howmuch"],
  },
});

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    // Serve the association file directly on every host, including the
    // redirecting legacy host: Apple fetches it from the associated domain
    // (howmuch.soon.sg), and following a redirect is not guaranteed there.
    if (pathname === "/.well-known/apple-app-site-association" || pathname === "/apple-app-site-association") {
      return new Response(APP_SITE_ASSOCIATION, {
        headers: {
          "content-type": "application/json",
          "cache-control": "public, max-age=3600",
        },
      });
    }
    if (env.HOWMUCH_REDIRECT_TARGET) {
      const url = new URL(request.url);
      // 308 preserves method and body, so API clients (including the iOS app)
      // follow the redirect without turning POSTs into GETs.
      return Response.redirect(`${env.HOWMUCH_REDIRECT_TARGET}${url.pathname}${url.search}`, 308);
    }
    if (!pathname.startsWith("/api/") && !pathname.startsWith("/v1/") && pathname !== "/health") {
      // SPA documents are usually served by Assets directly. `_headers` in
      // `apps/web/public` is the production policy; this wrap covers Worker-first fetches.
      return withDocumentSecurityHeaders(await env.ASSETS.fetch(request));
    }

    const config = workerConfig(env);
    const database = new HowMuchD1Database(requiredBinding(env.DB, "DB"));
    return createHandler({ repo: new D1LedgerRepository(database, config.defaultPlanId), reports: new D1ReportService(database.binding), auth: new D1AuthStore(database), config })(request);
  },

  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    const config = workerConfig(env);
    const database = new HowMuchD1Database(requiredBinding(env.DB, "DB"));
    assertCronMatchesMode(controller.cron, config.transitionReadOnly);

    if (controller.cron === YNAB_TRANSITION_CRON) {
      const result = await runD1ScheduledYnabSync({
        db: database,
        config,
        scheduledTime: controller.scheduledTime,
      });
      console.log(JSON.stringify({
        event: "ynab_delta_sync",
        status: result.status,
        run_id: result.run_id,
        imported_transaction_count: result.result?.imported_transactions ?? 0,
        raw_object_counts: result.result?.raw_objects ?? {},
        cursor: result.result?.server_knowledge ?? null,
      }));
      return;
    }

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
    transitionReadOnly: env.HOWMUCH_TRANSITION_READ_ONLY === "true",
    ynabToken: optional(env.HOWMUCH_YNAB_TOKEN),
    ynabPlanId: optional(env.HOWMUCH_YNAB_PLAN_ID),
    typesafeApiKey: optional(env.TYPESAFE_API_KEY),
    typesafeModel: optional(env.TYPESAFE_MODEL),
    timeZone: required(env.HOWMUCH_TIME_ZONE, "HOWMUCH_TIME_ZONE"),
  };
}

function assertCronMatchesMode(cron: string | undefined, transitionReadOnly: boolean): void {
  if (cron !== YNAB_TRANSITION_CRON && cron !== SCHEDULED_MATERIALIZATION_CRON) {
    throw new Error(`Unknown scheduled cron: ${cron ?? "missing"}`);
  }
  if (transitionReadOnly && cron !== YNAB_TRANSITION_CRON) {
    throw new Error(`Scheduled cron ${cron} does not match transition read-only mode`);
  }
}

function required(value: string | undefined, name: string): string {
  const trimmed = value?.trim();
  if (!trimmed) throw new Error(`${name} is required`);
  return trimmed;
}

function optional(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed || undefined;
}

function requiredBinding(value: D1Binding | undefined, name: string): D1Binding {
  if (!value) throw new Error(`${name} binding is required`);
  return value;
}
