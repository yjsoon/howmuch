import Foundation

/// A calendar month, the unit the report range presets and stepper move in.
/// Pure Gregorian arithmetic so the maths is unit-testable without a clock.
struct YearMonth: Hashable, Codable {
  var year: Int
  var month: Int

  static func containing(_ date: Date, calendar: Calendar = .current) -> YearMonth {
    let components = calendar.dateComponents([.year, .month], from: date)
    return YearMonth(year: components.year ?? 2000, month: components.month ?? 1)
  }

  func advanced(by offset: Int) -> YearMonth {
    // Zero-based month count stays positive for any real year, so plain
    // integer division is safe.
    let total = year * 12 + (month - 1) + offset
    return YearMonth(year: total / 12, month: total % 12 + 1)
  }

  var firstDay: String {
    String(format: "%04d-%02d-01", year, month)
  }

  var lastDay: String {
    String(format: "%04d-%02d-%02d", year, month, dayCount)
  }

  var dayCount: Int {
    switch month {
    case 1, 3, 5, 7, 8, 10, 12: return 31
    case 4, 6, 9, 11: return 30
    default: return isLeapYear ? 29 : 28
    }
  }

  var isLeapYear: Bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
  }

  /// "June 2026", for the month stepper.
  var title: String {
    let symbols = Calendar.current.monthSymbols
    guard (1 ... 12).contains(month) else {
      return String(format: "%04d-%02d", year, month)
    }
    return "\(symbols[month - 1]) \(year)"
  }
}

/// Month-first range presets shared with the web app: the calendar month is
/// the default unit, with trailing windows as deliberate alternatives. The
/// `.month` case carries a specific month reached through the stepper.
enum ReportRange: Hashable, Codable {
  case thisMonth
  case lastMonth
  case threeMonths
  case yearToDate
  case oneYear
  case month(YearMonth)

  static let presets: [ReportRange] = [.thisMonth, .lastMonth, .threeMonths, .yearToDate, .oneYear]

  var title: String {
    switch self {
    case .thisMonth:
      return "This month"
    case .lastMonth:
      return "Last month"
    case .threeMonths:
      return "3M"
    case .yearToDate:
      return "YTD"
    case .oneYear:
      return "1Y"
    case .month(let month):
      return month.title
    }
  }

  /// ISO `from`/`to` bounds for report queries, following the user's wall
  /// clock like the web presets.
  func resolvedDates(now: Date = Date(), calendar: Calendar = .current) -> (from: String, to: String) {
    let current = YearMonth.containing(now, calendar: calendar)
    switch self {
    case .thisMonth:
      return (current.firstDay, current.lastDay)
    case .lastMonth:
      let previous = current.advanced(by: -1)
      return (previous.firstDay, previous.lastDay)
    case .month(let month):
      return (month.firstDay, month.lastDay)
    case .threeMonths:
      return (Self.localISODay(monthsBefore: 3, now: now, calendar: calendar), Self.localISODay(now, calendar: calendar))
    case .yearToDate:
      return (String(format: "%04d-01-01", current.year), Self.localISODay(now, calendar: calendar))
    case .oneYear:
      return (Self.localISODay(monthsBefore: 12, now: now, calendar: calendar), Self.localISODay(now, calendar: calendar))
    }
  }

  /// The single calendar month this range covers, when it covers exactly one.
  /// Drives the `‹ June 2026 ›` stepper.
  func calendarMonth(now: Date = Date(), calendar: Calendar = .current) -> YearMonth? {
    switch self {
    case .thisMonth:
      return YearMonth.containing(now, calendar: calendar)
    case .lastMonth:
      return YearMonth.containing(now, calendar: calendar).advanced(by: -1)
    case .month(let month):
      return month
    case .threeMonths, .yearToDate, .oneYear:
      return nil
    }
  }

  /// Steps the active month, normalising back to the presets so the segmented
  /// control re-highlights when stepping returns to this or last month.
  func stepped(by offset: Int, now: Date = Date(), calendar: Calendar = .current) -> ReportRange {
    guard let month = calendarMonth(now: now, calendar: calendar) else {
      return self
    }
    let target = month.advanced(by: offset)
    let current = YearMonth.containing(now, calendar: calendar)
    if target == current {
      return .thisMonth
    }
    if target == current.advanced(by: -1) {
      return .lastMonth
    }
    return .month(target)
  }

  private static func localISODay(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
  }

  private static func localISODay(monthsBefore months: Int, now: Date, calendar: Calendar) -> String {
    let shifted = calendar.date(byAdding: .month, value: -months, to: now) ?? now
    return localISODay(shifted, calendar: calendar)
  }
}
