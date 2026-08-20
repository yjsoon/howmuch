import { createId } from "./ids";
import type { ScheduledSubtransactionInput, ScheduledTransactionInput } from "./types";

export class ScheduledTransactionValidationError extends Error {}

const WRITABLE_FIELDS = new Set([
  "account_id", "date_first", "date_next", "frequency", "amount", "payee_id",
  "category_id", "transfer_account_id", "memo", "flag_color", "subtransactions",
]);

export const SCHEDULE_FREQUENCIES = [
  "never", "daily", "weekly", "everyOtherWeek", "twiceAMonth", "every4Weeks",
  "monthly", "everyOtherMonth", "every3Months", "every4Months", "twiceAYear",
  "yearly", "everyOtherYear",
] as const;
const SCHEDULE_FREQUENCY_SET = new Set<string>(SCHEDULE_FREQUENCIES);

export type EffectiveScheduledTransaction = Record<string, any> & {
  id: string;
  account_id: string;
  date_first: string;
  date_next: string;
  frequency: string;
  amount: number;
  subtransactions: Array<Record<string, any> & { id: string; scheduled_transaction_id: string; amount: number }>;
};

export type ScheduledOccurrenceWindow = Readonly<{
  dates: string[];
  nextDate: string | null;
}>;

export function scheduledTransactionMutation(
  id: string,
  patch: Record<string, unknown>,
  base: Record<string, any> | null,
  existingSubtransactions: Record<string, any>[],
  idSeed?: string,
): EffectiveScheduledTransaction {
  if (!patch || typeof patch !== "object" || Array.isArray(patch)) throw new ScheduledTransactionValidationError("scheduled_transaction must be an object");
  for (const key of Object.keys(patch)) {
    if (key === "id") {
      if (patch.id !== id) throw new ScheduledTransactionValidationError("scheduled transaction id cannot be changed");
      continue;
    }
    if (!WRITABLE_FIELDS.has(key)) throw new ScheduledTransactionValidationError(`${key} cannot be changed on a scheduled transaction`);
  }

  const source = base ? { ...base } : {};
  delete source.subtransactions;
  const next: Record<string, any> = { ...source, ...patch, id, deleted: false };
  const subsInput = Object.hasOwn(patch, "subtransactions")
    ? patch.subtransactions
    : existingSubtransactions;
  if (!Array.isArray(subsInput)) throw new ScheduledTransactionValidationError("subtransactions must be an array");
  const subtransactions = subsInput.map((value, index) => normaliseSubtransaction(id, value, index, idSeed));

  if (typeof next.account_id !== "string" || !next.account_id.trim()) throw new ScheduledTransactionValidationError("account_id is required");
  next.date_first = isoDate(next.date_first, "date_first");
  next.date_next = isoDate(next.date_next ?? next.date_first, "date_next");
  if (typeof next.frequency !== "string" || !SCHEDULE_FREQUENCY_SET.has(next.frequency)) {
    throw new ScheduledTransactionValidationError(`frequency must be one of: ${SCHEDULE_FREQUENCIES.join(", ")}`);
  }
  if (next.date_next < next.date_first) throw new ScheduledTransactionValidationError("date_next cannot precede date_first");
  if (!Number.isSafeInteger(next.amount)) throw new ScheduledTransactionValidationError("amount must be integer milliunits");
  for (const field of ["payee_id", "category_id", "transfer_account_id", "memo", "flag_color"] as const) {
    if (next[field] !== undefined && next[field] !== null && typeof next[field] !== "string") {
      throw new ScheduledTransactionValidationError(`${field} must be a string or null`);
    }
  }
  if (subtransactions.length === 1) throw new ScheduledTransactionValidationError("split schedules need at least two subtransactions");
  if (subtransactions.length > 0) {
    const sum = subtransactions.reduce((total, subtransaction) => total + subtransaction.amount, 0);
    if (sum !== next.amount) throw new ScheduledTransactionValidationError(`subtransactions must sum to the scheduled amount (lines total ${sum}, schedule is ${next.amount})`);
    if (next.category_id != null) throw new ScheduledTransactionValidationError("split schedules cannot have a parent category_id");
  }
  next.subtransactions = subtransactions;
  return next as EffectiveScheduledTransaction;
}

/** Expands every due date without losing the original day-of-month anchor. */
export function scheduledOccurrencesThrough(
  dateFirst: string,
  dateNext: string,
  frequency: string,
  throughDate: string,
  maximum = 5_000,
): ScheduledOccurrenceWindow {
  const first = isoDate(dateFirst, "date_first");
  let cursor: string | null = isoDate(dateNext, "date_next");
  const through = isoDate(throughDate, "through_date");
  if (!SCHEDULE_FREQUENCY_SET.has(frequency)) {
    throw new ScheduledTransactionValidationError(`frequency must be one of: ${SCHEDULE_FREQUENCIES.join(", ")}`);
  }
  if (cursor < first) throw new ScheduledTransactionValidationError("date_next cannot precede date_first");
  if (!Number.isSafeInteger(maximum) || maximum < 1) throw new ScheduledTransactionValidationError("maximum occurrences must be a positive integer");

  const dates: string[] = [];
  while (cursor <= through) {
    if (dates.length >= maximum) throw new ScheduledTransactionValidationError(`Materialisation exceeds the ${maximum}-occurrence safety limit`);
    dates.push(cursor);
    cursor = nextScheduledOccurrence(first, cursor, frequency);
    if (cursor === null) break;
  }
  return { dates, nextDate: cursor };
}

export function nextScheduledOccurrence(dateFirst: string, currentDate: string, frequency: string): string | null {
  const first = isoDate(dateFirst, "date_first");
  const current = isoDate(currentDate, "date_next");
  if (current < first) throw new ScheduledTransactionValidationError("date_next cannot precede date_first");
  if (!SCHEDULE_FREQUENCY_SET.has(frequency)) {
    throw new ScheduledTransactionValidationError(`frequency must be one of: ${SCHEDULE_FREQUENCIES.join(", ")}`);
  }
  if (frequency === "never") return null;
  const dayIntervals: Record<string, number> = { daily: 1, weekly: 7, everyOtherWeek: 14, every4Weeks: 28 };
  if (dayIntervals[frequency]) return addDays(current, dayIntervals[frequency]);
  if (frequency === "twiceAMonth") return nextTwiceMonthly(first, current);
  const monthIntervals: Record<string, number> = {
    monthly: 1, everyOtherMonth: 2, every3Months: 3, every4Months: 4,
    twiceAYear: 6, yearly: 12, everyOtherYear: 24,
  };
  return addAnchoredMonths(current, monthIntervals[frequency], Number(first.slice(8, 10)));
}

function normaliseSubtransaction(
  scheduledTransactionId: string,
  value: unknown,
  index: number,
  idSeed?: string,
): EffectiveScheduledTransaction["subtransactions"][number] {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ScheduledTransactionValidationError("subtransactions must be objects");
  const input = value as ScheduledSubtransactionInput & Record<string, unknown>;
  const id = typeof input.id === "string" && input.id.trim()
    ? input.id
    : idSeed ? `scheduled_sub_${hashSeed(`${idSeed}:${index}`)}` : createId("scheduled_sub");
  if (!Number.isSafeInteger(input.amount)) throw new ScheduledTransactionValidationError("subtransaction amounts must be integer milliunits");
  for (const field of ["payee_id", "category_id", "transfer_account_id", "memo"] as const) {
    if (input[field] !== undefined && input[field] !== null && typeof input[field] !== "string") {
      throw new ScheduledTransactionValidationError(`subtransaction ${field} must be a string or null`);
    }
  }
  return { ...input, id, scheduled_transaction_id: scheduledTransactionId, amount: input.amount } as EffectiveScheduledTransaction["subtransactions"][number];
}

function isoDate(value: unknown, field: string): string {
  if (typeof value !== "string" || !/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/.test(value)) {
    throw new ScheduledTransactionValidationError(`${field} must be an ISO date (YYYY-MM-DD)`);
  }
  const date = new Date(`${value}T00:00:00Z`);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== value) throw new ScheduledTransactionValidationError(`${field} must be a valid calendar date`);
  return value;
}

function addDays(value: string, count: number): string {
  const date = new Date(`${value}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + count);
  return date.toISOString().slice(0, 10);
}

function addAnchoredMonths(value: string, count: number, anchorDay: number): string {
  const year = Number(value.slice(0, 4));
  const monthIndex = Number(value.slice(5, 7)) - 1 + count;
  const targetYear = year + Math.floor(monthIndex / 12);
  const targetMonth = ((monthIndex % 12) + 12) % 12;
  const lastDay = new Date(Date.UTC(targetYear, targetMonth + 1, 0)).getUTCDate();
  return `${String(targetYear).padStart(4, "0")}-${String(targetMonth + 1).padStart(2, "0")}-${String(Math.min(anchorDay, lastDay)).padStart(2, "0")}`;
}

function nextTwiceMonthly(dateFirst: string, currentDate: string): string {
  const firstYear = Number(dateFirst.slice(0, 4));
  const firstMonth = Number(dateFirst.slice(5, 7)) - 1;
  const currentYear = Number(currentDate.slice(0, 4));
  const currentMonth = Number(currentDate.slice(5, 7)) - 1;
  const approximateOffset = (currentYear - firstYear) * 12 + currentMonth - firstMonth;
  const anchorDay = Number(dateFirst.slice(8, 10));
  const candidates: string[] = [];
  for (let offset = Math.max(0, approximateOffset - 2); offset <= approximateOffset + 3; offset += 1) {
    const anchor = anchoredMonth(dateFirst, offset, anchorDay);
    candidates.push(anchor, addDays(anchor, 15));
  }
  const next = [...new Set(candidates)].sort().find((candidate) => candidate > currentDate && candidate >= dateFirst);
  if (!next) throw new ScheduledTransactionValidationError("Unable to calculate the next twice-monthly occurrence");
  return next;
}

function anchoredMonth(dateFirst: string, offset: number, anchorDay: number): string {
  const firstYear = Number(dateFirst.slice(0, 4));
  const firstMonth = Number(dateFirst.slice(5, 7)) - 1;
  const monthIndex = firstMonth + offset;
  const year = firstYear + Math.floor(monthIndex / 12);
  const month = ((monthIndex % 12) + 12) % 12;
  const lastDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  return `${String(year).padStart(4, "0")}-${String(month + 1).padStart(2, "0")}-${String(Math.min(anchorDay, lastDay)).padStart(2, "0")}`;
}

function hashSeed(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let hash = 2166136261;
  for (const byte of bytes) hash = Math.imul(hash ^ byte, 16777619);
  return (hash >>> 0).toString(16).padStart(8, "0");
}

const _scheduledInputTypecheck: ScheduledTransactionInput | null = null;
void _scheduledInputTypecheck;
