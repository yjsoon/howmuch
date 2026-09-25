// The on-device HowMuch engine: the unmodified apps/api backend, composed
// exactly as apps/worker/src/index.ts composes it, over a D1 binding that
// forwards every statement to the app's SQLite handle.
//
// The host (apps/ios/HowMuch/Engine/LocalEngine.swift) installs three globals
// before evaluating the bundle:
//   __sqlite.exec(sql, paramsJson) -> '{"rows":[...],"changes":n}' or '{"error":"..."}'
//   __random(n) -> Uint8Array of n secure random bytes
//   __log(message)
// and then drives `globalThis.__howmuch`. Every statement is synchronous, so a
// request settles within the call that starts it.
import "./shims/polyfills.js";
import type { ApiConfig } from "../../api/src/config";
import { D1Database, type D1Binding, type D1Result, type D1Statement } from "../../api/src/d1";
import { D1LedgerRepository } from "../../api/src/d1-ledger-repository";
import { D1ReportService } from "../../api/src/d1-reports";
import { D1AuthStore } from "../../api/src/auth-store";
import { createHandler } from "../../api/src/http";
import { runDailyScheduledMaterialization } from "../../api/src/scheduled-materialization-runner";

declare const __sqlite: { exec(sql: string, paramsJson: string): string };

type ExecResult = { rows: Record<string, unknown>[]; changes: number };

function exec(sql: string, params: readonly unknown[]): ExecResult {
  const values = params.map((value) => {
    if (value === undefined) return null;
    if (typeof value === "boolean") return value ? 1 : 0;
    return value;
  });
  const parsed = JSON.parse(__sqlite.exec(sql, JSON.stringify(values)));
  if (parsed.error) throw new Error(`SQLite: ${parsed.error}`);
  return parsed as ExecResult;
}

class Statement implements D1Statement {
  constructor(readonly sql: string, readonly params: readonly unknown[] = []) {}

  bind(...values: unknown[]): D1Statement {
    return new Statement(this.sql, values);
  }

  runNow<Row>(): D1Result<Row> {
    const result = exec(this.sql, this.params);
    return { results: result.rows as Row[], success: true, meta: { changes: result.changes } };
  }

  async all<Row>(): Promise<D1Result<Row>> {
    return this.runNow<Row>();
  }

  async first<Row>(): Promise<Row | null> {
    return (this.runNow<Row>().results?.[0] as Row | undefined) ?? null;
  }

  async run(): Promise<D1Result> {
    return this.runNow();
  }
}

/** D1 runs a batch as one transaction; so does this binding. */
const binding: D1Binding = {
  prepare: (sql) => new Statement(sql),
  async batch<Row>(statements: D1Statement[]) {
    exec("BEGIN IMMEDIATE", []);
    try {
      const results = (statements as Statement[]).map((statement) => statement.runNow<Row>());
      exec("COMMIT", []);
      return results;
    } catch (error) {
      try {
        exec("ROLLBACK", []);
      } catch {
        // A failed ROLLBACK must not hide why the batch failed.
      }
      throw error;
    }
  },
};

/**
 * `newPlanSettings` seeds a plan this call creates, in the stored
 * `currency_format`/`date_format` shapes. A plan that already exists keeps
 * its settings.
 */
type EngineConfig = {
  apiToken: string;
  defaultPlanId: string;
  timeZone: string;
  newPlanSettings?: { currency_format: Record<string, unknown>; date_format: { format: string } };
};

type Engine = {
  config: EngineConfig;
  repo: D1LedgerRepository;
  handler: (request: Request) => Promise<Response>;
};

let engine: Engine | null = null;

function current(): Engine {
  if (!engine) throw new Error("The engine is not configured");
  return engine;
}

/** Builds the handler. The plan row is created here because reads never create it. */
async function configure(configJson: string): Promise<void> {
  const config = JSON.parse(configJson) as EngineConfig;
  if (!config.apiToken || !config.defaultPlanId || !config.timeZone) {
    throw new Error("apiToken, defaultPlanId and timeZone are required");
  }
  const apiConfig: ApiConfig = {
    dbPath: "",
    port: 0,
    apiToken: config.apiToken,
    defaultPlanId: config.defaultPlanId,
    transitionReadOnly: false,
  };
  const database = new D1Database(binding);
  const repo = new D1LedgerRepository(database, config.defaultPlanId);
  const handler = createHandler({
    repo,
    reports: new D1ReportService(database.binding),
    auth: new D1AuthStore(database),
    config: apiConfig,
  });
  const existed = await database.get("SELECT 1 FROM plans WHERE id=?", [config.defaultPlanId]);
  await repo.ensurePlan(config.defaultPlanId);
  if (!existed && config.newPlanSettings) {
    await repo.upsertPlan(config.defaultPlanId, { name: "HowMuch" }, config.newPlanSettings);
  }
  engine = { config, repo, handler };
}

async function handle(method: string, url: string, headersJson: string, body: string | null) {
  const response = await current().handler(new Request(url, {
    method,
    headers: JSON.parse(headersJson),
    body: body ?? undefined,
  }));
  const headers: Record<string, string> = {};
  response.headers.forEach((value, key) => {
    headers[key] = value;
  });
  return { status: response.status, headers, body: await response.text() };
}

/** The Worker's daily cron, run by the app on launch and on returning to the foreground. */
async function runScheduledMaterialization(scheduledTimeMs: number) {
  const { config, repo } = current();
  return runDailyScheduledMaterialization({
    repo,
    planId: config.defaultPlanId,
    timeZone: config.timeZone,
    scheduledTime: scheduledTimeMs,
  });
}

(globalThis as Record<string, unknown>).__howmuch = { configure, handle, runScheduledMaterialization };
