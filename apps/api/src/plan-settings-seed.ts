/** Currency and date format a new plan starts with, chosen at first-owner setup. */
export type SeedCurrencyFormat = {
  iso_code: string;
  example_format: string;
  decimal_digits: number;
  decimal_separator: string;
  symbol_first: boolean;
  group_separator: string;
  currency_symbol: string;
  display_symbol: boolean;
};

export type SeedDateFormat = { format: string };

export const SEED_DATE_FORMATS = ["DD/MM/YYYY", "MM/DD/YYYY", "YYYY-MM-DD"] as const;

const CURRENCY_KEYS = [
  "iso_code", "example_format", "decimal_digits", "decimal_separator",
  "symbol_first", "group_separator", "currency_symbol", "display_symbol",
];

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function shortString(value: unknown, min: number, max: number): value is string {
  return typeof value === "string" && value.length >= min && value.length <= max;
}

/** Returns the validated currency format, or null when the value is malformed. */
export function parseSeedCurrencyFormat(value: unknown): SeedCurrencyFormat | null {
  if (!isPlainObject(value)) return null;
  const keys = Object.keys(value);
  if (keys.length !== CURRENCY_KEYS.length || !CURRENCY_KEYS.every((key) => keys.includes(key))) return null;
  const v = value;
  if (typeof v.iso_code !== "string" || !/^[A-Z]{3}$/.test(v.iso_code)) return null;
  if (!shortString(v.example_format, 1, 40)) return null;
  if (typeof v.decimal_digits !== "number" || !Number.isInteger(v.decimal_digits) || v.decimal_digits < 0 || v.decimal_digits > 4) return null;
  if (!shortString(v.decimal_separator, 1, 3) || !shortString(v.group_separator, 0, 3)) return null;
  if (!shortString(v.currency_symbol, 1, 8)) return null;
  if (typeof v.symbol_first !== "boolean" || typeof v.display_symbol !== "boolean") return null;
  return {
    iso_code: v.iso_code,
    example_format: v.example_format,
    decimal_digits: v.decimal_digits,
    decimal_separator: v.decimal_separator,
    symbol_first: v.symbol_first,
    group_separator: v.group_separator,
    currency_symbol: v.currency_symbol,
    display_symbol: v.display_symbol,
  };
}

/** Returns the validated date format, or null when the value is malformed. */
export function parseSeedDateFormat(value: unknown): SeedDateFormat | null {
  if (!isPlainObject(value) || Object.keys(value).length !== 1) return null;
  const format = value.format;
  return typeof format === "string" && (SEED_DATE_FORMATS as readonly string[]).includes(format) ? { format } : null;
}
