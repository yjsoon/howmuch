import Foundation

enum MoneyCodec {
  static func milliunits(from input: String) -> Int? {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "[$,\\s]", with: "", options: .regularExpression)
    guard !raw.isEmpty else {
      return nil
    }

    let sign = raw.hasPrefix("-") ? -1 : 1
    let unsigned = raw.replacingOccurrences(of: "^[+-]", with: "", options: .regularExpression)
    let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2 else {
      return nil
    }

    let wholePart = String(parts.first ?? "0")
    let fractionalPart = parts.count == 2 ? String(parts[1]) : ""
    let paddedFraction = String(fractionalPart.padding(toLength: 3, withPad: "0", startingAt: 0).prefix(3))

    guard
      let whole = Int(wholePart.isEmpty ? "0" : wholePart),
      let fraction = Int(paddedFraction)
    else {
      return nil
    }

    return sign * ((whole * 1000) + fraction)
  }

  static func displayString(for milliunits: Int, currencyFormat: CurrencyFormat?) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.minimumFractionDigits = currencyFormat?.decimalDigits ?? 2
    formatter.maximumFractionDigits = currencyFormat?.decimalDigits ?? 2
    formatter.currencySymbol = currencyFormat?.currencySymbol ?? Locale.current.currencySymbol ?? "$"
    if let decimalSeparator = currencyFormat?.decimalSeparator {
      formatter.decimalSeparator = decimalSeparator
    }
    if let groupSeparator = currencyFormat?.groupSeparator {
      formatter.groupingSeparator = groupSeparator
    }

    let decimalValue = Decimal(milliunits) / 1000
    return formatter.string(from: decimalValue as NSDecimalNumber) ?? String(format: "%.2f", NSDecimalNumber(decimal: decimalValue).doubleValue)
  }

  /// Signed display with an explicit plus on inflows, for ledger-style rows.
  static func signedDisplayString(for milliunits: Int, currencyFormat: CurrencyFormat?) -> String {
    let base = displayString(for: milliunits, currencyFormat: currencyFormat)
    return milliunits > 0 ? "+\(base)" : base
  }
}

enum LedgerDate {
  /// "Today", "Yesterday", or "Mon 8 Jun 2026" from an ISO `yyyy-MM-dd` string.
  static func friendlyString(fromISO isoDate: String) -> String {
    guard let date = parser.date(from: isoDate) else {
      return isoDate
    }
    if Calendar.current.isDateInToday(date) {
      return "Today"
    }
    if Calendar.current.isDateInYesterday(date) {
      return "Yesterday"
    }
    return display.string(from: date)
  }

  /// Human label for a report period key: `2026-06-10`, `2026-W23`, `2026-06`, or `2026`.
  static func periodLabel(_ raw: String) -> String {
    let parts = raw.split(separator: "-")
    if parts.count == 3 {
      return friendlyString(fromISO: raw)
    }
    if parts.count == 2, parts[1].hasPrefix("W") {
      return "Week \(parts[1].dropFirst()), \(parts[0])"
    }
    if parts.count == 2, let month = Int(parts[1]), (1 ... 12).contains(month) {
      return "\(Calendar.current.monthSymbols[month - 1]) \(parts[0])"
    }
    return raw
  }

  private static let parser: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let display: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE d MMM yyyy"
    return formatter
  }()
}

extension Date {
  var isoDateString: String {
    Self.isoFormatter.string(from: self)
  }

  private static let isoFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}
