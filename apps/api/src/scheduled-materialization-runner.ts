import { createHash } from "node:crypto";
import type { ScheduledCronMaterializationResult } from "./types";

/** A small cap keeps one Worker cron invocation below D1 command/CPU limits. */
export const DAILY_SCHEDULED_MATERIALIZATION_MAXIMUM = 25;

type ScheduledMaterializationStore = {
  materializeScheduledTransactionsForCron(
    planId: string,
    throughDate: string,
    maximum: number,
    requestOperationId?: string,
  ): Promise<ScheduledCronMaterializationResult> | ScheduledCronMaterializationResult;
};

export type ScheduledMaterializationSummary = {
  through_date: string;
  occurrence_count: number;
  skipped_closed_schedule_count: number;
  failure_count: number;
  has_more: boolean;
};

/** Runs the private daily catch-up for the calendar date at the budget's home timezone. */
export async function runDailyScheduledMaterialization(options: {
  repo: ScheduledMaterializationStore;
  planId: string;
  timeZone: string;
  scheduledTime: number;
  maximum?: number;
}): Promise<ScheduledMaterializationSummary> {
  const throughDate = scheduledLocalDate(options.scheduledTime, options.timeZone);
  const operationId = scheduledMaterializationOperationId(options.planId, throughDate);
  const maximum = options.maximum ?? DAILY_SCHEDULED_MATERIALIZATION_MAXIMUM;
  if (!Number.isSafeInteger(maximum) || maximum < 1 || maximum > 50) {
    throw new Error("Daily scheduled materialisation maximum must be an integer from 1 to 50");
  }
  const result = await options.repo.materializeScheduledTransactionsForCron(
    options.planId,
    throughDate,
    maximum,
    operationId,
  );
  return {
    through_date: result.through_date,
    occurrence_count: result.occurrence_count,
    skipped_closed_schedule_count: result.skipped_closed_schedule_count,
    failure_count: result.failure_count,
    has_more: result.has_more,
  };
}

/** Converts a cron timestamp into a stable ISO calendar date without relying on Worker locale defaults. */
export function scheduledLocalDate(scheduledTime: number, timeZone: string): string {
  if (!Number.isFinite(scheduledTime)) throw new Error("scheduledTime must be a finite Unix timestamp in milliseconds");
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(scheduledTime));
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  if (!values.year || !values.month || !values.day) throw new Error("Unable to derive the scheduled local date");
  return `${values.year}-${values.month}-${values.day}`;
}

export function scheduledMaterializationOperationId(planId: string, throughDate: string): string {
  const digest = createHash("sha256").update(`${planId}:${throughDate}`).digest("hex").slice(0, 32);
  return `cron_materialize_${digest}`;
}
