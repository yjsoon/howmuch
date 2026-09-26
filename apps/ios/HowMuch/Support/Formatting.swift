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
    // Milliunits are the storage precision. Reject extra digits rather than
    // silently rounding or truncating a split allocation on save.
    guard fractionalPart.count <= 3 else {
      return nil
    }
    let paddedFraction = String(fractionalPart.padding(toLength: 3, withPad: "0", startingAt: 0).prefix(3))

    guard
      let whole = Int(wholePart.isEmpty ? "0" : wholePart),
      let fraction = Int(paddedFraction)
    else {
      return nil
    }

    let scaled = whole.multipliedReportingOverflow(by: 1000)
    guard !scaled.overflow else {
      return nil
    }
    let total = scaled.partialValue.addingReportingOverflow(fraction)
    guard !total.overflow else {
      return nil
    }
    if sign == -1 {
      let negated = total.partialValue.multipliedReportingOverflow(by: -1)
      return negated.overflow ? nil : negated.partialValue
    }
    return total.partialValue
  }

  static func editableString(for milliunits: Int) -> String {
    let magnitude = milliunits.magnitude
    let whole = magnitude / 1_000
    var fraction = String(magnitude % 1_000 + 1_000).dropFirst()
    if fraction.last == "0" {
      fraction.removeLast()
    }
    let sign = milliunits < 0 ? "-" : ""
    return "\(sign)\(whole).\(fraction)"
  }

  /// Model extractions may include `$`, `S$`, grouping commas, currency codes, or trailing words.
  /// Typed fields still go through `milliunits(from:)` and reject that junk.
  static func milliunits(fromExtraction input: String) -> Int? {
    var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else {
      return nil
    }
    raw = raw.replacingOccurrences(
      of: #"(?i)(?:\b(?:s|us|a|nz|hk)\$)|\b(?:sgd|usd)\b|\b(?:dollars?)\b|\$"#,
      with: "",
      options: .regularExpression
    )
    raw = raw.replacingOccurrences(of: ",", with: "")
    guard let match = raw.range(of: #"-?(?:\d+(?:\.\d+)?|\.\d+)"#, options: .regularExpression) else {
      return nil
    }
    return milliunits(from: String(raw[match]))
  }

  static func milliunits(from value: Decimal) -> Int? {
    let magnitude = value < 0 ? -value : value
    var scaled = magnitude * 1000
    var integerPart = Decimal()
    NSDecimalRound(&integerPart, &scaled, 0, .down)
    guard integerPart == scaled else {
      return nil
    }
    let number = NSDecimalNumber(decimal: integerPart)
    let milli = number.intValue
    guard NSDecimalNumber(value: milli) == number else {
      return nil
    }
    return milli
  }

  static func displayString(for milliunits: Int, currencyFormat: CurrencyFormat?) -> String {
    let formatter = formatter(for: currencyFormat)
    let decimalValue = Decimal(milliunits) / 1000
    return formatter.string(from: decimalValue as NSDecimalNumber)
      ?? decimalValue.formatted(.number.precision(.fractionLength(2)))
  }

  static func displayString(forCurrencyUnits units: Double, currencyFormat: CurrencyFormat?) -> String {
    displayString(for: Int((units * 1000).rounded()), currencyFormat: currencyFormat)
  }

  private static let formatterLock = NSLock()
  private static var formatters: [String: NumberFormatter] = [:]

  private static func formatter(for currencyFormat: CurrencyFormat?) -> NumberFormatter {
    let key = [
      String(currencyFormat?.decimalDigits ?? 2),
      currencyFormat?.currencySymbol ?? Locale.current.currencySymbol ?? "$",
      currencyFormat?.decimalSeparator ?? "",
      currencyFormat?.groupSeparator ?? "",
    ].joined(separator: "\u{1f}")

    formatterLock.lock()
    if let cached = formatters[key] {
      formatterLock.unlock()
      return cached
    }
    formatterLock.unlock()

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

    formatterLock.lock()
    formatters[key] = formatter
    formatterLock.unlock()
    return formatter
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

  /// Compact label for a report chart's horizontal axis.
  static func periodAxisLabel(_ raw: String) -> String {
    let parts = raw.split(separator: "-")
    if parts.count == 3, let date = parser.date(from: raw) {
      return axisDayDisplay.string(from: date)
    }
    if parts.count == 2, parts[1].hasPrefix("W") {
      return String(parts[1])
    }
    if parts.count == 2, let month = Int(parts[1]), (1 ... 12).contains(month) {
      return Calendar.current.shortMonthSymbols[month - 1]
    }
    return raw
  }

  /// Axis labels for a whole series. A monthly run that crosses a year
  /// gets a short year on the first column and on January, so two Augusts
  /// in a trailing-year net-worth chart stay distinguishable.
  static func periodAxisLabels(_ raws: [String]) -> [String] {
    let months = raws.compactMap(yearMonth(from:))
    let spansYears = Set(months.map { $0.year }).count > 1
    guard months.count == raws.count, spansYears else {
      return raws.map(periodAxisLabel)
    }
    return months.enumerated().map { index, item in
      let short = Calendar.current.shortMonthSymbols[item.month - 1]
      if index == 0 || item.month == 1 {
        return "\(short) \(String(item.year).suffix(2))"
      }
      return short
    }
  }

  private static func yearMonth(from raw: String) -> (year: Int, month: Int)? {
    let parts = raw.split(separator: "-")
    guard parts.count == 2, !parts[1].hasPrefix("W"),
          let year = Int(parts[0]), let month = Int(parts[1]),
          (1 ... 12).contains(month) else {
      return nil
    }
    return (year, month)
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

  private static let axisDayDisplay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM"
    return formatter
  }()
}

extension Date {
  var isoDateString: String {
    Self.isoFormatter.string(from: self)
  }

  init?(isoDateString: String) {
    guard let parsed = Self.isoFormatter.date(from: isoDateString) else {
      return nil
    }
    self = parsed
  }

  func startOfMonth(calendar: Calendar = .current) -> Date {
    calendar.date(from: calendar.dateComponents([.year, .month], from: self)) ?? self
  }

  func endOfMonth(calendar: Calendar = .current) -> Date {
    guard
      let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth(calendar: calendar)),
      let lastDay = calendar.date(byAdding: .day, value: -1, to: nextMonth)
    else {
      return self
    }
    return lastDay
  }

  /// "September 2025"
  var monthYearLabel: String {
    Self.monthYearFormatter.string(from: self)
  }

  /// "8 Jun 2026", for compact custom-range chips.
  var compactDateLabel: String {
    Self.compactDateFormatter.string(from: self)
  }

  private static let monthYearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM yyyy"
    return formatter
  }()

  private static let compactDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM yyyy"
    return formatter
  }()

  /// Local wall-clock dates: a transaction entered before 8am in Singapore
  /// must not land on yesterday's GMT date.
  private static let isoFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}
