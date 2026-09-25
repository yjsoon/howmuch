import Foundation

/// The currency and date format a new on-device plan starts with, taken from
/// the device's region. Encodes to the shapes the backend stores in
/// `plans.currency_format_json` and `plans.date_format_json`.
struct PlanSettingsSeed: Codable, Equatable {
  struct Currency: Codable, Equatable {
    var isoCode: String
    var exampleFormat: String
    var decimalDigits: Int
    var decimalSeparator: String
    var symbolFirst: Bool
    var groupSeparator: String
    var currencySymbol: String
    var displaySymbol: Bool

    private enum CodingKeys: String, CodingKey {
      case isoCode = "iso_code"
      case exampleFormat = "example_format"
      case decimalDigits = "decimal_digits"
      case decimalSeparator = "decimal_separator"
      case symbolFirst = "symbol_first"
      case groupSeparator = "group_separator"
      case currencySymbol = "currency_symbol"
      case displaySymbol = "display_symbol"
    }
  }

  struct DateFormat: Codable, Equatable {
    var format: String
  }

  var currencyFormat: Currency
  var dateFormat: DateFormat

  private enum CodingKeys: String, CodingKey {
    case currencyFormat = "currency_format"
    case dateFormat = "date_format"
  }

  /// Nil when the locale names no currency (a language without a region),
  /// which leaves the backend's defaults in place.
  static func from(locale: Locale) -> PlanSettingsSeed? {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .currency
    guard let isoCode = locale.currency?.identifier, !isoCode.isEmpty else {
      return nil
    }
    formatter.currencyCode = isoCode
    let symbol = formatter.currencySymbol ?? isoCode
    return PlanSettingsSeed(
      currencyFormat: Currency(
        isoCode: isoCode,
        exampleFormat: formatter.string(from: 123_456.78) ?? "",
        decimalDigits: formatter.maximumFractionDigits,
        decimalSeparator: formatter.currencyDecimalSeparator ?? ".",
        symbolFirst: symbolFirst(in: formatter.positiveFormat ?? ""),
        groupSeparator: formatter.currencyGroupingSeparator ?? ",",
        currencySymbol: symbol,
        displaySymbol: true
      ),
      dateFormat: DateFormat(format: dateFormat(for: locale))
    )
  }

  /// Whether the currency sign comes before the digits in a number pattern.
  static func symbolFirst(in pattern: String) -> Bool {
    guard let sign = pattern.firstIndex(of: "¤") else { return true }
    guard let digit = pattern.firstIndex(where: { $0 == "#" || $0 == "0" }) else { return true }
    return sign < digit
  }

  /// The backend knows three orders; anything else maps to the nearest one
  /// by which of year, month and day comes first.
  static func dateFormat(for locale: Locale) -> String {
    let pattern = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? ""
    let first = pattern.first { "yMd".contains($0) }
    switch first {
    case "y": return "YYYY-MM-DD"
    case "M": return "MM/DD/YYYY"
    default: return "DD/MM/YYYY"
    }
  }
}
