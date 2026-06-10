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

export interface RangePreset {
  id: string;
  label: string;
  range: () => { from?: string; to?: string };
}

export const RANGE_PRESETS: RangePreset[] = [
  { id: "1m", label: "1M", range: () => ({ from: iso(shiftMonths(new Date(), -1)), to: todayIso() }) },
  { id: "3m", label: "3M", range: () => ({ from: iso(shiftMonths(new Date(), -3)), to: todayIso() }) },
  { id: "6m", label: "6M", range: () => ({ from: iso(shiftMonths(new Date(), -6)), to: todayIso() }) },
  { id: "12m", label: "12M", range: () => ({ from: iso(shiftMonths(new Date(), -12)), to: todayIso() }) },
  {
    id: "ytd",
    label: "YTD",
    range: () => ({ from: `${new Date().getFullYear()}-01-01`, to: todayIso() }),
  },
  { id: "all", label: "All", range: () => ({}) },
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

/** Renders API period labels ("2026-06", "2026-W23", "2026-06-10", "2026") for humans. */
export function formatPeriod(period: string): string {
  if (/^\d{4}-\d{2}-\d{2}$/.test(period)) {
    const [, month, day] = period.split("-");
    return `${Number(day)} ${MONTHS[Number(month) - 1]} ${period.slice(0, 4)}`;
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
