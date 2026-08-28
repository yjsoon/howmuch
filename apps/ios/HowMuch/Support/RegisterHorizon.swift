import Foundation

struct RegisterHorizon: Equatable, Sendable {
  static let standard = RegisterHorizon(months: 2, maxFillRows: 600)

  let months: Int
  let maxFillRows: Int

  func startDate(today: Date = .now, calendar: Calendar = .current) -> String {
    (calendar.date(byAdding: .month, value: -months, to: today) ?? today).isoDateString
  }

  func shouldFetchMore(
    oldestLoadedDate: String?,
    hasMore: Bool,
    rowCount: Int,
    today: Date = .now,
    calendar: Calendar = .current
  ) -> Bool {
    guard hasMore, rowCount < maxFillRows else {
      return false
    }
    // Inclusive start: a page that lands on the horizon day may still have more rows on that day.
    return oldestLoadedDate.map { $0 >= startDate(today: today, calendar: calendar) } ?? true
  }
}
