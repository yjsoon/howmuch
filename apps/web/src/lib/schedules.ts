import type { ScheduledTransaction } from "../api/types";

export function activeSchedulesForAccount(
  schedules: ScheduledTransaction[],
  accountId: string,
): ScheduledTransaction[] {
  return activeSchedulesForScope(schedules, new Set([accountId]));
}

export function activeSchedulesForScope(
  schedules: ScheduledTransaction[],
  accountIds: ReadonlySet<string>,
): ScheduledTransaction[] {
  return schedules
    .filter((schedule) => !schedule.deleted && typeof schedule.account_id === "string" && accountIds.has(schedule.account_id))
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

export function scheduleRecurrence(value: string | null | undefined): string {
  const labels: Record<string, string> = {
    daily: "Daily",
    weekly: "Weekly",
    monthly: "Monthly",
    yearly: "Yearly",
    never: "Once",
    twiceamonth: "Twice a month",
    twiceayear: "Twice a year",
    everyotherweek: "Every other week",
    everyothermonth: "Every other month",
  };
  if (!value) return "Recurring";
  const key = value.trim().toLowerCase();
  if (labels[key]) return labels[key];
  const words = value.trim()
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/([A-Za-z])(\d)/g, "$1 $2")
    .replace(/(\d)([A-Za-z])/g, "$1 $2")
    .replace(/[_-]+/g, " ")
    .toLowerCase();
  return words ? `${words[0].toUpperCase()}${words.slice(1)}` : "Recurring";
}

export function transferScheduleLabel(accountId: string, accounts: Map<string, string>): string {
  return `Transfer to ${accounts.get(accountId) ?? "account"}`;
}
