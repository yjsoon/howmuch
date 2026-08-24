import type { ScheduledTransaction } from "../api/types";

export function activeSchedulesForAccount(
  schedules: ScheduledTransaction[],
  accountId: string,
): ScheduledTransaction[] {
  return schedules
    .filter((schedule) => !schedule.deleted && schedule.account_id === accountId)
    .sort((left, right) =>
      String(left.date_next ?? left.date_first ?? "9999-12-31")
        .localeCompare(String(right.date_next ?? right.date_first ?? "9999-12-31"))
      || left.id.localeCompare(right.id));
}

export function scheduledAmount(schedule: ScheduledTransaction): number {
  if (Number.isSafeInteger(schedule.amount)) return Number(schedule.amount);
  return (schedule.subtransactions ?? []).reduce(
    (sum, line) => sum + (Number.isSafeInteger(line.amount) ? line.amount : 0),
    0,
  );
}
