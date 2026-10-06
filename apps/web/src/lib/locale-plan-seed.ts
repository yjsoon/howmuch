/**
 * Currency and date format for a new server plan. The setup form prefills a
 * guess from the browser locale and the person can change it before creating
 * the account. Mirrors the iOS PlanSettingsSeed in shape.
 *
 * The separators are always "." (decimal) and "," (group), whatever the
 * locale: those are the only marks the web and iOS amount parsers understand,
 * and the server validator rejects anything else.
 */
export type DateFormatChoice = "DD/MM/YYYY" | "MM/DD/YYYY" | "YYYY-MM-DD";

export type LocalePlanSeed = {
  currency_format: {
    iso_code: string;
    example_format: string;
    decimal_digits: number;
    decimal_separator: ".";
    symbol_first: boolean;
    group_separator: ",";
    currency_symbol: string;
    display_symbol: boolean;
  };
  date_format: { format: DateFormatChoice };
};

export const DATE_FORMAT_CHOICES: readonly DateFormatChoice[] = ["DD/MM/YYYY", "MM/DD/YYYY", "YYYY-MM-DD"];

export const CURRENCY_CHOICES: readonly string[] = [
  "SGD", "USD", "EUR", "GBP", "AUD", "NZD", "CAD", "JPY", "MYR", "HKD", "CNY", "INR",
  "IDR", "THB", "PHP", "VND", "KRW", "TWD", "CHF", "SEK", "NOK", "DKK",
];

export const DEFAULT_CURRENCY = "SGD";
export const DEFAULT_DATE_FORMAT: DateFormatChoice = "DD/MM/YYYY";

// Intl has no region-to-currency lookup, so the common regions are listed.
const EURO_REGIONS = "AT BE CY DE EE ES FI FR GR HR IE IT LT LU LV MT NL PT SI SK".split(" ");
const REGION_CURRENCY: Record<string, string> = {
  AU: "AUD", CA: "CAD", CH: "CHF", CN: "CNY", DK: "DKK", GB: "GBP", HK: "HKD", ID: "IDR", IN: "INR",
  JP: "JPY", KR: "KRW", MY: "MYR", NO: "NOK", NZ: "NZD", PH: "PHP", SE: "SEK", SG: "SGD", TH: "THB",
  TW: "TWD", US: "USD", VN: "VND",
  ...Object.fromEntries(EURO_REGIONS.map((region) => [region, "EUR"])),
};

function browserLanguage(): string | undefined {
  return typeof navigator === "undefined" ? undefined : navigator.language;
}

/** Region of a tag, recovering a likely one for region-less tags such as "de" or "en". */
function regionOf(languageTag: string): string | undefined {
  const locale = new Intl.Locale(languageTag);
  return locale.region ?? locale.maximize().region;
}

/** The currency the locale suggests, if it is one of the offered choices. */
export function guessCurrency(languageTag: string | undefined = browserLanguage()): string | null {
  try {
    if (!languageTag) return null;
    const currency = REGION_CURRENCY[regionOf(languageTag) ?? ""];
    return currency && CURRENCY_CHOICES.includes(currency) ? currency : null;
  } catch {
    return null;
  }
}

/** The date order the locale uses; DD/MM/YYYY when it cannot be determined. */
export function guessDateFormat(languageTag: string | undefined = browserLanguage()): DateFormatChoice {
  try {
    if (!languageTag) return DEFAULT_DATE_FORMAT;
    const first = new Intl.DateTimeFormat(languageTag, { year: "numeric", month: "numeric", day: "numeric" })
      .formatToParts(new Date(2000, 10, 22))
      .find((part) => part.type === "year" || part.type === "month" || part.type === "day")?.type;
    return first === "year" ? "YYYY-MM-DD" : first === "month" ? "MM/DD/YYYY" : DEFAULT_DATE_FORMAT;
  } catch {
    return DEFAULT_DATE_FORMAT;
  }
}

/**
 * Builds the seed for the chosen currency and date format. The ISO code, symbol,
 * symbol position and decimal digits come from Intl; the separators are fixed.
 */
export function buildPlanSeed(
  currency: string,
  dateFormat: DateFormatChoice,
  languageTag: string | undefined = browserLanguage(),
): LocalePlanSeed {
  let symbol = currency;
  let symbolFirst = true;
  let decimalDigits = 2;
  try {
    let money: Intl.NumberFormat;
    try {
      money = new Intl.NumberFormat(languageTag || "en", { style: "currency", currency, currencyDisplay: "narrowSymbol" });
    } catch {
      money = new Intl.NumberFormat("en", { style: "currency", currency, currencyDisplay: "narrowSymbol" });
    }
    const types = money.formatToParts(123_456.78).map((part) => part.type);
    symbol = money.formatToParts(123_456.78).find((part) => part.type === "currency")?.value ?? currency;
    symbolFirst = types.indexOf("currency") < types.indexOf("integer");
    decimalDigits = Math.min(4, money.resolvedOptions().maximumFractionDigits ?? 2);
  } catch {
    // Keep the plain-ISO-code defaults above.
  }
  const number = new Intl.NumberFormat("en-US", { minimumFractionDigits: decimalDigits, maximumFractionDigits: decimalDigits })
    .format(123_456.78);
  return {
    currency_format: {
      iso_code: currency,
      example_format: symbolFirst ? `${symbol}${number}` : `${number} ${symbol}`,
      decimal_digits: decimalDigits,
      decimal_separator: ".",
      symbol_first: symbolFirst,
      group_separator: ",",
      currency_symbol: symbol,
      display_symbol: true,
    },
    date_format: { format: dateFormat },
  };
}
