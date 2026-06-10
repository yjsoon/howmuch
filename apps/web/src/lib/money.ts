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

export function formatShare(share: number): string {
  return `${(share * 100).toFixed(1)}%`;
}
