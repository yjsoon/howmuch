import Foundation
import SwiftUI

/// Pure layout/data helpers for the Income vs Spending card, list, and month detail.
enum IncomeVsSpendingMaths {
  struct PeriodRow: Equatable, Identifiable {
    var id: String { period }
    var period: String
    var from: String
    var to: String
    var income: Int
    var spending: Int
    var net: Int
    var isEmpty: Bool
  }

  struct YearSection: Equatable, Identifiable {
    var id: String { year }
    var year: String
    var net: Int
    var rows: [PeriodRow]
  }

  /// Calendar YTD: sum nets whose period key starts with the current year.
  /// Never uses `cumulativeNet`.
  static func yearToDateNet(periods: [IncomeVsSpendingPeriod], year: Int) -> Int {
    let prefix = String(year)
    return periods.reduce(0) { sum, period in
      period.period.hasPrefix(prefix) ? sum + period.net : sum
    }
  }

  static func hasActivity(periods: [IncomeVsSpendingPeriod], matching prefix: String) -> Bool {
    periods.contains { $0.period.hasPrefix(prefix) && ($0.income != 0 || $0.spending != 0) }
  }

  static func currentMonthKey(from date: Date = .now, calendar: Calendar = .current) -> String {
    String(date.startOfMonth(calendar: calendar).isoDateString.prefix(7))
  }

  static func monthName(from date: Date = .now, calendar: Calendar = .current) -> String {
    calendar.monthSymbols[calendar.component(.month, from: date) - 1]
  }

  /// The register / groups window behind one period row. The row's bounds were
  /// already cut to the report window that produced its figures, so the
  /// drill-down covers the whole row: clamping it to today would drop
  /// future-dated activity the row counts, and would trap on a period that
  /// starts after today.
  static func drillDownRange(_ row: PeriodRow) -> ClosedRange<String> {
    row.from ... max(row.from, row.to)
  }

  static func savingsRateLabel(net: Int, income: Int) -> String {
    guard income > 0 else {
      return "—"
    }
    let rate = Double(net) / Double(income)
    if rate < -1 {
      return "—"
    }
    return rate.formatted(.percent.precision(.fractionLength(1)))
  }

  static func zeroFill(
    periods: [IncomeVsSpendingPeriod],
    interval: ReportInterval,
    from: String?,
    to: String?
  ) -> [PeriodRow] {
    guard !periods.isEmpty else {
      return []
    }
    let start = from ?? inferredStart(of: periods[0].period, interval: interval)
    let end = to ?? inferredEnd(of: periods[periods.count - 1].period, interval: interval)
    guard let start, let end, start <= end else {
      return periods.map { row(from: $0, interval: interval) }
    }
    let byKey = Dictionary(uniqueKeysWithValues: periods.map { ($0.period, $0) })
    return enumeratePeriods(from: start, to: end, interval: interval).map { bounds in
      if let existing = byKey[bounds.key] {
        return PeriodRow(
          period: bounds.key,
          from: bounds.from,
          to: bounds.to,
          income: existing.income,
          spending: existing.spending,
          net: existing.net,
          isEmpty: existing.income == 0 && existing.spending == 0
        )
      }
      return PeriodRow(
        period: bounds.key,
        from: bounds.from,
        to: bounds.to,
        income: 0,
        spending: 0,
        net: 0,
        isEmpty: true
      )
    }
  }

  static func yearSections(rows: [PeriodRow]) -> [YearSection] {
    var order: [String] = []
    var grouped: [String: [PeriodRow]] = [:]
    for row in rows {
      let year = String(row.period.prefix(4))
      if grouped[year] == nil {
        order.append(year)
        grouped[year] = []
      }
      grouped[year]?.append(row)
    }
    return order.map { year in
      let yearRows = grouped[year] ?? []
      return YearSection(year: year, net: yearRows.reduce(0) { $0 + $1.net }, rows: yearRows)
    }
  }

  static func runningNet(rows: [PeriodRow], through period: String) -> Int {
    var total = 0
    for row in rows {
      total += row.net
      if row.period == period {
        break
      }
    }
    return total
  }

  static func isCurrentPeriod(_ key: String, interval: ReportInterval, today: String) -> Bool {
    periodKey(for: today, interval: interval) == key
  }

  static func filterLine(accountCount: Int, categoryCount: Int) -> String? {
    var parts: [String] = []
    if accountCount > 0 {
      parts.append("\(accountCount) account\(accountCount == 1 ? "" : "s")")
    }
    if categoryCount > 0 {
      parts.append("\(categoryCount) categor\(categoryCount == 1 ? "y" : "ies")")
    }
    guard !parts.isEmpty else {
      return nil
    }
    return "Filtered: " + parts.joined(separator: ", ")
  }

  static func inProgressCaption(from: String, to: String) -> String {
    guard let start = parseISO(from), let end = parseISO(to) else {
      return "\(from)–\(to) so far"
    }
    let month = shortMonthSymbol(end.month)
    return "\(start.day)–\(end.day) \(month) so far"
  }

  static func runningSinceLabel(_ firstPeriod: String, interval: ReportInterval) -> String {
    switch interval {
    case .month:
      if let month = yearMonth(from: firstPeriod) {
        return "\(shortMonthSymbol(month.month)) \(month.year)"
      }
    case .day, .week, .year:
      break
    }
    return LedgerDate.periodLabel(firstPeriod)
  }

  static func emptyPeriodName(_ key: String, interval: ReportInterval) -> String {
    if interval == .month, let month = yearMonth(from: key) {
      return Calendar.current.monthSymbols[month.month - 1]
    }
    return LedgerDate.periodLabel(key)
  }

  static func emptyWindowNoun(_ interval: ReportInterval) -> String {
    switch interval {
    case .day:
      return "this day"
    case .week:
      return "this week"
    case .month:
      return "this month"
    case .year:
      return "this year"
    }
  }

  static func txnShareLabel(count: Int, share: Double) -> String {
    let percent = share * 100
    let shareText = percent > 0 && percent < 1 ? "< 1%" : "\(Int(percent.rounded()))%"
    return "\(count) txns · \(shareText)"
  }

  static func voiceOverRowLabel(
    period: String,
    income: String,
    spending: String,
    net: String,
    destination: String = "month detail"
  ) -> String {
    "\(period), income \(income), spending \(spending), net \(net). Opens \(destination)."
  }

  static func enumeratePeriods(from: String, to: String, interval: ReportInterval) -> [(key: String, from: String, to: String)] {
    var results: [(key: String, from: String, to: String)] = []
    var cursor: String? = from
    var current: (key: String, from: String, to: String)?
    while let day = cursor, day <= to {
      let key = periodKey(for: day, interval: interval)
      if current?.key != key {
        if let current {
          results.append(current)
        }
        current = (key, day, day)
      } else {
        current?.to = day
      }
      cursor = nextISODate(day)
    }
    if let current {
      results.append(current)
    }
    return results
  }

  static func periodKey(for isoDate: String, interval: ReportInterval) -> String {
    switch interval {
    case .day:
      return isoDate
    case .month:
      return String(isoDate.prefix(7))
    case .year:
      return String(isoDate.prefix(4))
    case .week:
      return sqliteWeekKey(for: isoDate) ?? isoDate
    }
  }

  /// Monday-first week number matching SQLite `strftime('%Y-W%W', date)`.
  static func sqliteWeekKey(for isoDate: String) -> String? {
    guard let parts = parseISO(isoDate) else {
      return nil
    }
    let dayOfYear = ordinalDay(year: parts.year, month: parts.month, day: parts.day) - 1
    let jan1Weekday = weekdaySundayZero(year: parts.year, month: 1, day: 1)
    let jan1MondayBased = (jan1Weekday + 6) % 7
    let week = (dayOfYear + jan1MondayBased) / 7
    return String(format: "%04d-W%02d", parts.year, week)
  }

  static func nextISODate(_ iso: String) -> String? {
    guard let parts = parseISO(iso) else {
      return nil
    }
    var year = parts.year
    var month = parts.month
    var day = parts.day + 1
    let dim = daysInMonth(year: year, month: month)
    if day > dim {
      day = 1
      month += 1
    }
    if month > 12 {
      month = 1
      year += 1
    }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }
}

private extension IncomeVsSpendingMaths {
  static func row(from period: IncomeVsSpendingPeriod, interval: ReportInterval) -> PeriodRow {
    let bounds = inferredBounds(of: period.period, interval: interval)
    return PeriodRow(
      period: period.period,
      from: bounds.from,
      to: bounds.to,
      income: period.income,
      spending: period.spending,
      net: period.net,
      isEmpty: period.income == 0 && period.spending == 0
    )
  }

  static func inferredStart(of period: String, interval: ReportInterval) -> String? {
    inferredBounds(of: period, interval: interval).from
  }

  static func inferredEnd(of period: String, interval: ReportInterval) -> String? {
    inferredBounds(of: period, interval: interval).to
  }

  static func inferredBounds(of period: String, interval: ReportInterval) -> (from: String, to: String) {
    switch interval {
    case .day:
      return (period, period)
    case .month:
      if let month = yearMonth(from: period) {
        let from = String(format: "%04d-%02d-01", month.year, month.month)
        let to = String(format: "%04d-%02d-%02d", month.year, month.month, daysInMonth(year: month.year, month: month.month))
        return (from, to)
      }
    case .year:
      if let year = Int(period) {
        return (String(format: "%04d-01-01", year), String(format: "%04d-12-31", year))
      }
    case .week:
      if let year = Int(period.prefix(4)), period.contains("W") {
        let start = String(format: "%04d-01-01", year)
        let end = String(format: "%04d-12-31", year)
        if let match = enumeratePeriods(from: start, to: end, interval: .week).first(where: { $0.key == period }) {
          return (match.from, match.to)
        }
      }
    }
    return (period, period)
  }

  static func yearMonth(from raw: String) -> (year: Int, month: Int)? {
    let parts = raw.split(separator: "-")
    guard parts.count == 2, !parts[1].hasPrefix("W"),
          let year = Int(parts[0]), let month = Int(parts[1]),
          (1 ... 12).contains(month) else {
      return nil
    }
    return (year, month)
  }

  static func parseISO(_ iso: String) -> (year: Int, month: Int, day: Int)? {
    let parts = iso.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
      return nil
    }
    return (year, month, day)
  }

  static func daysInMonth(year: Int, month: Int) -> Int {
    let lengths = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if month == 2, isLeapYear(year) {
      return 29
    }
    return lengths[month]
  }

  static func isLeapYear(_ year: Int) -> Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  }

  static func ordinalDay(year: Int, month: Int, day: Int) -> Int {
    let lengths = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    var total = day
    if month > 1 {
      for prior in 1 ..< month {
        total += lengths[prior]
      }
    }
    if month > 2, isLeapYear(year) {
      total += 1
    }
    return total
  }

  /// Sakamoto: 0 = Sunday.
  static func weekdaySundayZero(year: Int, month: Int, day: Int) -> Int {
    let table = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
    var y = year
    if month < 3 {
      y -= 1
    }
    return (y + y / 4 - y / 100 + y / 400 + table[month - 1] + day) % 7
  }

  static func shortMonthSymbol(_ month: Int) -> String {
    Calendar.current.shortMonthSymbols[month - 1]
  }
}
