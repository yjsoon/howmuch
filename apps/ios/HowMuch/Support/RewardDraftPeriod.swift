import Foundation

/// Prospective boundaries only, not a reward calculation. Keep the precedence
/// and anchor arithmetic aligned with API rewards/engine/utils/periods.ts.
struct RewardDraftPeriod: Equatable {
  let start: String
  let end: String
  let rule: String
  let reset: String?

  static func make(_ draft: RewardCardDraft, asOf: String = RewardsCalendar.today()) -> Self? {
    let calendar = RewardsCalendar.calendar
    func date(_ text: String) -> Date? {
      guard text.count == 10, let value = RewardsCalendar.date(text),
        RewardsCalendar.isoString(value) == text
      else { return nil }
      return value
    }
    guard let reference = date(asOf) else { return nil }
    func monthStart(_ value: Date) -> Date {
      let parts = calendar.dateComponents([.year, .month], from: value)
      return calendar.date(
        from: DateComponents(year: parts.year, month: parts.month, day: 1, hour: 12))!
    }
    // Always offset from the original anchor, never from a previously clamped day.
    func anchored(_ anchor: Date, months: Int, day: Int) -> Date {
      let month = calendar.date(byAdding: .month, value: months, to: monthStart(anchor))!
      let last = calendar.range(of: .day, in: .month, for: month)!.count
      return calendar.date(byAdding: .day, value: min(day, last) - 1, to: month)!
    }
    func period(_ start: Date, next: Date, rule: String, resets: Bool = false) -> Self {
      Self(
        start: RewardsCalendar.isoString(start),
        end: RewardsCalendar.isoString(calendar.date(byAdding: .day, value: -1, to: next)!),
        rule: rule, reset: resets ? RewardsCalendar.isoString(next) : nil)
    }

    if !draft.rewardMonthCount.isEmpty || !draft.rewardAnchorDate.isEmpty
      || !draft.rewardMonthlyMinimum.isEmpty
    {
      guard let months = Int(draft.rewardMonthCount), (2...24).contains(months),
        let anchor = date(draft.rewardAnchorDate)
      else { return nil }
      if reference >= anchor {
        let a = calendar.dateComponents([.year, .month, .day], from: anchor)
        let r = calendar.dateComponents([.year, .month], from: reference)
        let distance = (r.year! - a.year!) * 12 + r.month! - a.month!
        var offset = distance / months
        if reference < anchored(anchor, months: offset * months, day: a.day!) { offset -= 1 }
        return period(
          anchored(anchor, months: offset * months, day: a.day!),
          next: anchored(anchor, months: (offset + 1) * months, day: a.day!),
          rule: "\(months)-month qualification overrides promotion and billing dates."
        )
      }
    }

    func ordinaryPeriod() -> Self? {
      if draft.billingType == .billing {
        guard let day = Int(draft.billingDay), (1...31).contains(day) else { return nil }
        let current = anchored(reference, months: 0, day: day)
        let offset = reference < current ? -1 : 0
        return period(
          anchored(reference, months: offset, day: day),
          next: anchored(reference, months: offset + 1, day: day),
          rule: "Billing cycle starts on day \(day).", resets: true)
      }
      return period(
        monthStart(reference), next: anchored(reference, months: 1, day: 1),
        rule: "Calendar month; saved billing day is ignored.", resets: true)
    }

    if !draft.promoStart.isEmpty || !draft.promoEnd.isEmpty || !draft.promoDescription.isEmpty {
      guard let end = date(draft.promoEnd) else { return nil }
      let start: Date?
      if draft.promoStart.isEmpty {
        if reference > end { return ordinaryPeriod() }
        start = ordinaryPeriod().flatMap { date($0.start) }
      } else {
        start = date(draft.promoStart)
      }
      guard let start, start <= end else { return nil }
      if reference >= start && reference <= end {
        return Self(
          start: RewardsCalendar.isoString(start), end: draft.promoEnd,
          rule: "Promotion overrides the regular cycle.", reset: nil)
      }
    }
    return ordinaryPeriod()
  }
}
