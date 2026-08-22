import type { CurrencyFormat } from "../api/types";

let formatter = new Intl.NumberFormat("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
let symbol = "";
let symbolFirst = true;

export function configureMoney(format?: CurrencyFormat): void {
  const digits = format?.decimal_digits ?? 2;
  formatter = new Intl.NumberFormat("en-GB", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
  symbol = format?.display_symbol === false ? "" : (format?.currency_symbol ?? "");
  symbolFirst = format?.symbol_first ?? true;
}

/**
 * Exact decimal → milliunit conversion. Never use `Number(value) * 1000`:
 * values such as 1.135 cannot be represented in binary floating point.
 */
export function parseMilliunits(value: string): number | null {
  const match = value.trim().match(/^([+-]?)(?:(\d+)(?:\.(\d{0,3}))?|\.(\d{1,3}))$/);
  if (!match) {
    return null;
  }
  const whole = match[2] === undefined ? 0 : Number(match[2]);
  const fractionDigits = match[2] === undefined ? (match[4] ?? "") : (match[3] ?? "");
  const amount = whole * 1_000 + Number(fractionDigits.padEnd(3, "0"));
  const signed = match[1] === "-" ? -amount : amount;
  return Number.isSafeInteger(signed) ? signed : null;
}

/** Formats integer milliunits for an editable decimal field without float rounding. */
export function formatMilliunitsInput(milliunits: number): string {
  const sign = milliunits < 0 ? "-" : "";
  const absolute = Math.abs(milliunits);
  const whole = Math.trunc(absolute / 1_000);
  const fraction = absolute % 1_000;
  if (fraction === 0) {
    return `${sign}${whole}`;
  }
  return `${sign}${whole}.${String(fraction).padStart(3, "0").replace(/0+$/, "")}`;
}

/** Formats integer milliunits for display, e.g. -12340 -> "−£12.34". */
export function formatMoney(milliunits: number, options?: { sign?: boolean }): string {
  const absolute = formatter.format(Math.abs(milliunits) / 1000);
  const withSymbol = symbolFirst ? `${symbol}${absolute}` : `${absolute}${symbol}`;
  if (milliunits < 0) {
    return `−${withSymbol}`;
  }
  return options?.sign && milliunits > 0 ? `+${withSymbol}` : withSymbol;
}

/** Formats positive magnitudes (report totals are already absolute). */
export function formatAmount(milliunits: number): string {
  return formatMoney(Math.abs(milliunits));
}

export function formatShare(share: number): string {
  return `${(share * 100).toFixed(1)}%`;
}
