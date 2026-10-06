/**
 * Currency and date format for a new server plan, derived from the browser
 * locale. Mirrors the iOS PlanSettingsSeed: nil/null when the locale names no
 * region, so the server keeps its default.
 */
export type LocalePlanSeed = {
  currency_format: {
    iso_code: string;
    example_format: string;
    decimal_digits: number;
    decimal_separator: string;
    symbol_first: boolean;
    group_separator: string;
    currency_symbol: string;
    display_symbol: boolean;
  };
  date_format: { format: "DD/MM/YYYY" | "MM/DD/YYYY" | "YYYY-MM-DD" };
};

// Intl has no region-to-currency lookup, so the common regions are listed.
const EURO_REGIONS = "AT BE CY DE EE ES FI FR GR HR IE IT LT LU LV MT NL PT SI SK".split(" ");
const REGION_CURRENCY: Record<string, string> = {
  AE: "AED", AR: "ARS", AU: "AUD", BD: "BDT", BG: "BGN", BR: "BRL", CA: "CAD", CH: "CHF", CL: "CLP", CN: "CNY",
  CO: "COP", CZ: "CZK", DK: "DKK", EG: "EGP", GB: "GBP", HK: "HKD", HU: "HUF", ID: "IDR", IL: "ILS", IN: "INR",
  JP: "JPY", KE: "KES", KR: "KRW", LK: "LKR", MX: "MXN", MY: "MYR", NG: "NGN", NO: "NOK", NZ: "NZD", PE: "PEN",
  PH: "PHP", PK: "PKR", PL: "PLN", QA: "QAR", RO: "RON", SA: "SAR", SE: "SEK", SG: "SGD", TH: "THB", TR: "TRY",
  TW: "TWD", UA: "UAH", US: "USD", VN: "VND", ZA: "ZAR",
  ...Object.fromEntries(EURO_REGIONS.map((region) => [region, "EUR"])),
};

export function localePlanSeed(languageTag: string | undefined = typeof navigator === "undefined" ? undefined : navigator.language): LocalePlanSeed | null {
  try {
    if (!languageTag) return null;
    const currency = REGION_CURRENCY[new Intl.Locale(languageTag).region ?? ""];
    if (!currency) return null;
    const money = new Intl.NumberFormat(languageTag, { style: "currency", currency });
    const parts = money.formatToParts(123_456.78);
    const symbol = parts.find((part) => part.type === "currency")?.value;
    if (!symbol) return null;
    const decimalDigits = Math.min(4, money.resolvedOptions().maximumFractionDigits ?? 2);
    const decimal = new Intl.NumberFormat(languageTag).formatToParts(1.5).find((part) => part.type === "decimal")?.value ?? ".";
    const group = parts.find((part) => part.type === "group")?.value ?? "";
    const types = parts.map((part) => part.type);
    const first = new Intl.DateTimeFormat(languageTag, { year: "numeric", month: "numeric", day: "numeric" })
      .formatToParts(new Date(2000, 10, 22))
      .find((part) => part.type === "year" || part.type === "month" || part.type === "day")?.type;
    return {
      currency_format: {
        iso_code: currency,
        example_format: money.format(123_456.78),
        decimal_digits: decimalDigits,
        decimal_separator: decimal,
        symbol_first: types.indexOf("currency") < types.indexOf("integer"),
        group_separator: group,
        currency_symbol: symbol,
        display_symbol: true,
      },
      date_format: { format: first === "year" ? "YYYY-MM-DD" : first === "month" ? "MM/DD/YYYY" : "DD/MM/YYYY" },
    };
  } catch {
    return null;
  }
}
