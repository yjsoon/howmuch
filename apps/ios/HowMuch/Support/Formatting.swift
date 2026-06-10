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

  static func milliunitHint(for input: String) -> String? {
    guard let milliunits = milliunits(from: input) else {
      return nil
    }
    return "\(milliunits) milliunits"
  }
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
