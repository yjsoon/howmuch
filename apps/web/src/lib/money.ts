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

/** Parses a user-typed decimal ("12.34", "-5") into integer milliunits. */
export function decimalToMilli(value: string): number {
  const parsed = Number(String(value).replace(/,/g, "").trim());
  if (!Number.isFinite(parsed)) {
    throw new Error(`Not a valid amount: ${value}`);
  }
  return Math.round(parsed * 1000);
}

export function formatShare(share: number): string {
  return `${(share * 100).toFixed(1)}%`;
}
