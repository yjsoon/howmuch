/** Local-time ISO date: quick entry and range presets follow the user's wall clock, not UTC. */
function iso(date: Date): string {
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}

export function todayIso(): string {
  return iso(new Date());
}

export function yesterdayIso(): string {
  const date = new Date();
  date.setDate(date.getDate() - 1);
  return iso(date);
}

function shiftMonths(date: Date, months: number): Date {
  const result = new Date(date);
  result.setMonth(result.getMonth() + months);
  return result;
}

function monthBounds(year: number, monthIndex: number): { from: string; to: string } {
  return {
    from: iso(new Date(year, monthIndex, 1)),
    to: iso(new Date(year, monthIndex + 1, 0)),
  };
}

/** The calendar month `offset` months away from today (0 = this month). */
export function monthRange(offset = 0): { from: string; to: string } {
  const now = new Date();
  return monthBounds(now.getFullYear(), now.getMonth() + offset);
}

export function ytdRange(): { from: string; to: string } {
  return { from: `${new Date().getFullYear()}-01-01`, to: todayIso() };
}

export function trailingMonthsRange(months: number, today: Date = new Date()): { from: string; to: string } {
  return { from: iso(shiftMonths(today, -months)), to: iso(today) };
}

/** "2026-06" when from–to spans exactly that calendar month, else null. */
export function calendarMonthOf(from?: string, to?: string): string | null {
  const start = from?.match(/^(\d{4})-(\d{2})-01$/);
  if (!start || !to) {
    return null;
  }
  const year = Number(start[1]);
  const monthIndex = Number(start[2]) - 1;
  return monthBounds(year, monthIndex).to === to ? `${start[1]}-${start[2]}` : null;
}

/** The calendar month `delta` months away from "YYYY-MM". */
export function shiftMonth(month: string, delta: number): { from: string; to: string } {
  const [year, monthNumber] = month.split("-").map(Number);
  return monthBounds(year, monthNumber - 1 + delta);
}

export interface RangePreset {
  id: string;
  label: string;
  range: () => { from?: string; to?: string };
}

export const RANGE_PRESETS: RangePreset[] = [
  { id: "this-month", label: "This month", range: () => monthRange(0) },
  { id: "last-month", label: "Last month", range: () => monthRange(-1) },
  { id: "2m", label: "2M", range: () => trailingMonthsRange(2) },
  { id: "3m", label: "3M", range: () => trailingMonthsRange(3) },
  { id: "ytd", label: "YTD", range: () => ytdRange() },
  { id: "1y", label: "1Y", range: () => trailingMonthsRange(12) },
  { id: "all", label: "All", range: () => ({ from: undefined, to: undefined }) },
];

export function matchPreset(from?: string, to?: string): string | null {
  for (const preset of RANGE_PRESETS) {
    const range = preset.range();
    if (range.from === from && range.to === to) {
      return preset.id;
    }
    if (!range.from && !range.to && !from && !to) {
      return preset.id;
    }
  }
  return null;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const FULL_MONTHS = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

/** "2026-06" -> "June 2026", for the month stepper. */
export function formatMonthName(month: string): string {
  const [year, monthNumber] = month.split("-");
  return `${FULL_MONTHS[Number(monthNumber) - 1]} ${year}`;
}

let planDateFormat: string | undefined;

/**
 * Applies the plan's date format to full dates. Periods (months, weeks, years)
 * are unaffected. The stored value names an ordering, not a literal pattern:
 * "DD/MM/YYYY" is day first ("24 May 2026"), "MM/DD/YYYY" is month first
 * ("May 24, 2026") and "YYYY-MM-DD" is year first ("2026-05-24").
 */
export function configureDateFormat(format?: { format?: string }): void {
  planDateFormat = format?.format;
}

/** A full ISO date in the plan's ordering; an unset or unknown format renders day first. */
function formatFullDate(date: string): string {
  const [year, month, day] = date.split("-");
  if (planDateFormat === "MM/DD/YYYY") return `${MONTHS[Number(month) - 1]} ${Number(day)}, ${year}`;
  if (planDateFormat === "YYYY-MM-DD") return date;
  return `${Number(day)} ${MONTHS[Number(month) - 1]} ${year}`;
}

/** Renders API period labels ("2026-06", "2026-W23", "2026-06-10", "2026") for humans; full dates follow the plan's date format. */
export function formatPeriod(period: string): string {
  if (/^\d{4}-\d{2}-\d{2}$/.test(period)) {
    return formatFullDate(period);
  }
  if (/^\d{4}-\d{2}$/.test(period)) {
    const [year, month] = period.split("-");
    return `${MONTHS[Number(month) - 1]} ${year}`;
  }
  return period;
}

export function formatDate(date: string): string {
  return formatPeriod(date);
}

export function formatDateRange(from?: string, to?: string): string {
  if (from && to) {
    return `${formatDate(from)} to ${formatDate(to)}`;
  }
  if (from) {
    return `From ${formatDate(from)}`;
  }
  if (to) {
    return `To ${formatDate(to)}`;
  }
  return "All time";
}
