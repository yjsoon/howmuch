import Foundation

/// Reward periods are civil dates in Asia/Singapore, whatever the device zone.
enum RewardsCalendar {
  static let timeZone = TimeZone(identifier: "Asia/Singapore")!

  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "en_GB")
    return calendar
  }()

  /// Noon on the civil date, so no zone or DST shift can move the day.
  static func date(_ iso: String) -> Date? {
    let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
  }

  static func isoString(_ date: Date) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  static func today(now: Date = .now) -> String {
    isoString(now)
  }

  /// `to − from` in whole civil days.
  static func days(from: String, to: String) -> Int? {
    guard let start = date(from), let end = date(to) else { return nil }
    return calendar.dateComponents([.day], from: start, to: end).day
  }

  /// "30 Sep", or "30 Sep 2025" outside the reference year.
  static func shortLabel(_ iso: String, referenceISO: String? = nil) -> String {
    guard let date = date(iso) else { return iso }
    let sameYear = referenceISO.map { $0.prefix(4) == iso.prefix(4) } ?? true
    return (sameYear ? dayMonth : dayMonthYear).string(from: date)
  }

  private static func formatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter
  }

  private static let dayMonth = formatter("d MMM")
  private static let dayMonthYear = formatter("d MMM yyyy")
}

/// What one Rewards row says, derived only from the report. Semantic values;
/// `RewardRowText` turns them into strings.
struct RewardRowProjection: Equatable {
  enum Tone: String, Equatable {
    /// Unmet minimum: amber.
    case needsMinimum
    /// Earning, heading for a tier or cap: mint.
    case earning
    /// Terminal cap reached: subdued.
    case complete
    /// Monthly qualification failed: neutral surface, warning line.
    case failed
    /// No target, or an aggregate range.
    case neutral
  }

  enum Action: Equatable {
    case qualificationFailed
    case monthlyMinimum(remaining: Double)
    case minimum(remaining: Double)
    case nextTier(remaining: Double)
    case capHeadroom(remaining: Double)
    /// `terminal` is false for an intermediate cap with no reachable tier left.
    case capReached(beyond: Double, terminal: Bool)
    case noTarget
    case range
  }

  enum DeadlineKind: Equatable {
    case ends
    case resets
  }

  struct Deadline: Equatable {
    let end: String
    /// Inclusive of the as-of day, which is still spendable.
    let days: Int
    let kind: DeadlineKind
  }

  struct Basis: Equatable {
    let spend: Double
    let target: Double
  }

  enum Exception: Equatable {
    case categoriesAtCap(names: [String], over: Bool)
    case categoriesBelowMinimum(names: [String])
    case rewardsLocked(until: String)
    case tierCapReached
    case minimumNotMet
  }

  let cardID: String
  let accountID: String
  let title: String
  let rewardType: RewardKind
  let action: Action
  let tone: Tone
  /// The fill and the spend/target line always share this basis.
  let basis: Basis?
  /// 0…1, or nil when there is no target to fill towards.
  let fill: Double?
  let deadline: Deadline?
  let totalSpend: Double
  let earned: Double
  let exceptions: [Exception]

  var isBelowMinimum: Bool {
    switch action {
    case .minimum, .monthlyMinimum: return true
    default: return false
    }
  }

  var isTerminalCap: Bool {
    if case .capReached(_, true) = action { return true }
    return false
  }

  static func make(row: RewardsCardRow, asOf: String?, isRange: Bool) -> Self {
    let calc = row.calculation
    func build(
      _ action: Action,
      _ tone: Tone,
      basis: Basis? = nil,
      fill: Double? = nil,
      deadline: Deadline? = nil,
      exceptions: [Exception] = []
    ) -> Self {
      Self(
        cardID: row.card.id,
        accountID: row.accountId,
        title: row.card.name,
        rewardType: calc.rewardType,
        action: action,
        tone: tone,
        basis: basis,
        fill: fill ?? basis.map { $0.target > 0 ? min(1, max(0, $0.spend / $0.target)) : 0 },
        deadline: deadline,
        totalSpend: calc.totalSpend,
        earned: calc.rewardEarned,
        exceptions: exceptions
      )
    }

    // A range aggregates several periods; it has no single target or deadline,
    // and the server keeps only the last period's cap flags.
    if isRange {
      return build(.range, .neutral)
    }

    let period = asOf.flatMap { day in
      calc.periods?.last(where: { $0.start <= day && day <= $0.end })
    }
    func deadline(_ end: String?, _ kind: DeadlineKind) -> Deadline? {
      guard let asOf, let end, let gap = RewardsCalendar.days(from: asOf, to: end) else { return nil }
      return Deadline(end: end, days: gap + 1, kind: kind)
    }
    let periodEnd = period?.end
    let status = calc.qualificationStatus
    let activeMonth = asOf.flatMap { day in
      calc.monthlyQualifications?.first(where: { $0.start <= day && day <= $0.end })
    }

    var action: Action
    var tone: Tone
    var basis: Basis?
    var fill: Double?
    var due: Deadline?
    var exceptions: [Exception] = []

    if status == "failed" {
      action = .qualificationFailed
      tone = .failed
      due = deadline(periodEnd, .resets)
    } else if status == "pending", let month = activeMonth, month.spend < month.minimumSpend {
      action = .monthlyMinimum(remaining: month.minimumSpend - month.spend)
      tone = .needsMinimum
      basis = Basis(spend: month.spend, target: month.minimumSpend)
      due = deadline(month.end, .ends)
    } else if let minimum = calc.minimumSpend, minimum > 0, calc.totalSpend < minimum {
      // Raw qualifying spend, not the block-rounded counted spend.
      action = .minimum(remaining: minimum - calc.totalSpend)
      tone = .needsMinimum
      basis = Basis(spend: calc.totalSpend, target: minimum)
      due = deadline(periodEnd, .ends)
    } else if calc.hasNextSpendingTier == true,
      let threshold = calc.nextSpendingTierThreshold, threshold > calc.totalSpend
    {
      action = .nextTier(remaining: threshold - calc.totalSpend)
      tone = .earning
      basis = Basis(spend: calc.totalSpend, target: threshold)
      due = deadline(periodEnd, .ends)
      if calc.maximumSpendExceeded {
        exceptions.append(.tierCapReached)
      }
    } else if let maximum = calc.maximumSpend, maximum > 0, !calc.maximumSpendExceeded {
      // Caps count block-rounded spend.
      action = .capHeadroom(remaining: max(0, maximum - calc.countedSpend))
      tone = .earning
      basis = Basis(spend: calc.countedSpend, target: maximum)
      due = deadline(periodEnd, .ends)
    } else if calc.maximumSpendExceeded {
      // The flag is authoritative: it fires once headroom is below one block.
      let terminal = calc.shouldStopUsing == true || calc.hasNextSpendingTier != true
      let maximum = calc.maximumSpend ?? 0
      action = .capReached(beyond: maximum > 0 ? max(0, calc.totalSpend - maximum) : 0, terminal: terminal)
      tone = terminal ? .complete : .earning
      if maximum > 0 {
        basis = Basis(spend: min(calc.countedSpend, maximum), target: maximum)
      }
      fill = 1
      due = deadline(periodEnd, .resets)
    } else {
      action = .noTarget
      tone = .neutral
      due = deadline(periodEnd, .resets)
    }

    if status == "pending", !isMonthly(action) {
      let until = calc.monthlyQualifications?.map(\.end).max() ?? periodEnd
      if let until {
        exceptions.append(.rewardsLocked(until: until))
      }
    } else if !calc.minimumSpendMet, status != "failed", status != "pending", !isMinimum(action) {
      // Spend reached the figure but the server still withholds rewards,
      // e.g. an unmet tier minimum. Never imply rewards are unlocked.
      exceptions.append(.minimumNotMet)
    }

    if !calc.maximumSpendExceeded {
      let atCap = calc.flags.filter { ($0.maximumSpend ?? 0) > 0 && $0.maximumSpendExceeded == true }
      if !atCap.isEmpty {
        let over = atCap.contains { ($0.totalSpend ?? 0) > ($0.maximumSpend ?? 0) }
        exceptions.append(.categoriesAtCap(names: atCap.map(\.name), over: over))
      }
    }
    if calc.minimumSpendMet {
      let below = calc.flags.filter { ($0.minimumSpend ?? 0) > 0 && $0.minimumSpendMet == false }
      if !below.isEmpty {
        exceptions.append(.categoriesBelowMinimum(names: below.map(\.name)))
      }
    }

    return build(action, tone, basis: basis, fill: fill, deadline: due, exceptions: exceptions)
  }

  private static func isMonthly(_ action: Action) -> Bool {
    if case .monthlyMinimum = action { return true }
    return false
  }

  private static func isMinimum(_ action: Action) -> Bool {
    switch action {
    case .minimum, .monthlyMinimum: return true
    default: return false
    }
  }
}

/// Display strings for a projection. Kept apart so tests can assert meaning.
struct RewardRowText {
  let amount: String?
  let actionLabel: String
  let deadline: String?
  let isUrgent: Bool
  let basisLine: String?
  let exceptionLines: [String]
  let accessibilityValue: String

  static let visibleExceptionLimit = 2

  init(_ projection: RewardRowProjection, currencyFormat: CurrencyFormat?) {
    func money(_ value: Double) -> String {
      MoneyCodec.displayString(forCurrencyUnits: value, currencyFormat: currencyFormat)
    }
    let earned = Self.reward(projection.earned, projection.rewardType, currencyFormat: currencyFormat)

    switch projection.action {
    case .qualificationFailed:
      amount = nil
      actionLabel = "Monthly minimum missed"
    case .monthlyMinimum(let remaining):
      amount = money(Self.roundedUpToCent(remaining))
      actionLabel = "to this month's minimum"
    case .minimum(let remaining):
      amount = money(Self.roundedUpToCent(remaining))
      actionLabel = "to minimum"
    case .nextTier(let remaining):
      amount = money(Self.roundedUpToCent(remaining))
      actionLabel = "to next tier"
    case .capHeadroom(let remaining):
      amount = money(remaining)
      actionLabel = "left before cap"
    case .capReached:
      amount = nil
      actionLabel = "Cap reached"
    case .noTarget:
      amount = nil
      actionLabel = "No cap"
    case .range:
      amount = earned
      actionLabel = "earned"
    }

    if let due = projection.deadline {
      deadline = Self.deadlineText(due)
      isUrgent = due.kind == .ends && due.days <= 3
    } else {
      deadline = nil
      isUrgent = false
    }

    switch projection.action {
    case .range:
      basisLine = "\(money(projection.totalSpend)) spent"
    case .capReached(let beyond, _):
      let spendPart: String
      if let basis = projection.basis {
        spendPart = "\(money(basis.spend)) / \(money(basis.target))"
      } else {
        spendPart = "\(money(projection.totalSpend)) spent"
      }
      var parts: [String] = [spendPart, "\(earned) earned"]
      if beyond > 0 {
        parts.append("\(money(beyond)) beyond cap")
      }
      basisLine = parts.joined(separator: " · ")
    default:
      if let basis = projection.basis {
        basisLine = "\(money(basis.spend)) / \(money(basis.target)) · \(earned) earned"
      } else {
        basisLine = "\(money(projection.totalSpend)) spent · \(earned) earned"
      }
    }

    let allExceptions = projection.exceptions.map { Self.exceptionText($0, currencyFormat: currencyFormat) }
    if allExceptions.count > Self.visibleExceptionLimit {
      exceptionLines = Array(allExceptions.prefix(Self.visibleExceptionLimit))
        + ["+\(allExceptions.count - Self.visibleExceptionLimit) more"]
    } else {
      exceptionLines = allExceptions
    }

    // Locals, not self: a closure may not capture self before init completes.
    let label = actionLabel
    var spoken: [String] = [amount.map { "\($0) \(label)" } ?? label]
    if let basis = projection.basis, basis.target > 0, projection.action != .range {
      let percent = Int((min(1, max(0, basis.spend / basis.target)) * 100).rounded())
      spoken.append("\(money(basis.spend)) of \(money(basis.target)), \(percent) per cent")
    } else if let basisLine {
      spoken.append(basisLine)
    }
    if let due = projection.deadline, let deadline {
      spoken.append("\(deadline), \(due.kind == .ends ? "ends" : "period ends") \(RewardsCalendar.shortLabel(due.end))")
    }
    if projection.action != .range {
      spoken.append("\(earned) earned")
    }
    spoken.append(contentsOf: allExceptions)
    accessibilityValue = spoken.joined(separator: ". ")
  }

  static func roundedUpToCent(_ value: Double) -> Double {
    guard value > 0 else { return 0 }
    // The epsilon keeps binary noise (102.0000000001) from adding a cent.
    return ((value * 100) - 1e-7).rounded(.up) / 100
  }

  static func reward(_ value: Double, _ type: RewardKind, currencyFormat: CurrencyFormat?) -> String {
    switch type {
    case .cashback:
      return MoneyCodec.displayString(forCurrencyUnits: value, currencyFormat: currencyFormat)
    case .miles:
      return "\(milesString(value)) miles"
    }
  }

  static func milesString(_ value: Double) -> String {
    Int(value.rounded()).formatted(IntegerFormatStyle<Int>(locale: Locale(identifier: "en_GB")))
  }

  static func deadlineText(_ deadline: RewardRowProjection.Deadline) -> String {
    guard deadline.days >= 1 else { return "Period ended" }
    switch deadline.kind {
    case .ends:
      return deadline.days == 1 ? "Last day" : "\(deadline.days) days left"
    case .resets:
      return deadline.days == 1 ? "Resets tomorrow" : "Resets in \(deadline.days) days"
    }
  }

  static func exceptionText(_ exception: RewardRowProjection.Exception, currencyFormat: CurrencyFormat?) -> String {
    switch exception {
    case .categoriesAtCap(let names, let over):
      let state = over ? "over cap" : "at cap"
      return names.count == 1 ? "\(names[0]) \(state)" : "\(names.count) categories \(state)"
    case .categoriesBelowMinimum(let names):
      return names.count == 1 ? "\(names[0]) below its minimum" : "\(names.count) categories below minimum"
    case .rewardsLocked(let until):
      return "Rewards unlock after \(RewardsCalendar.shortLabel(until))"
    case .tierCapReached:
      return "Current tier cap reached"
    case .minimumNotMet:
      return "Minimum not yet met"
    }
  }
}

/// The quiet line under the board controls. Scope is the whole report:
/// Featured and hidden choices never change these numbers.
struct RewardsBoardSummary: Equatable {
  let earnedLine: String
  let statusCounts: [String]

  init(report: RewardsReport, projections: [RewardRowProjection], currencyFormat: CurrencyFormat?) {
    let totals = report.totals
    let money = { (value: Double) in MoneyCodec.displayString(forCurrencyUnits: value, currencyFormat: currencyFormat) }
    if totals.miles > 0, report.milesValuation <= 0 {
      earnedLine = "\(money(totals.cashback)) cashback · \(RewardRowText.milesString(totals.miles)) miles"
    } else if totals.miles > 0 {
      earnedLine = "≈ \(money(totals.rewardDollars)) earned"
    } else {
      earnedLine = "\(money(totals.rewardDollars)) earned"
    }
    let below = projections.filter(\.isBelowMinimum).count
    let failed = projections.filter { $0.action == .qualificationFailed }.count
    let capped = projections.filter(\.isTerminalCap).count
    let counts: [String?] = [
      below > 0 ? "\(below) below minimum" : nil,
      failed > 0 ? "\(failed) failed" : nil,
      capped > 0 ? "\(capped) capped" : nil,
    ]
    statusCounts = counts.compactMap { $0 }
  }

  var line: String {
    ([earnedLine] + statusCounts).joined(separator: " · ")
  }
}

enum RewardsBoardOrdering {
  /// Fallback for cards without a saved position: nearest deadline, then name.
  static func fallbackOrder(_ projections: [RewardRowProjection]) -> [String] {
    projections.sorted { left, right in
      let leftDays = left.deadline?.days ?? Int.max
      let rightDays = right.deadline?.days ?? Int.max
      if leftDays != rightDays { return leftDays < rightDays }
      let byName = left.title.localizedStandardCompare(right.title)
      if byName != .orderedSame { return byName == .orderedAscending }
      return left.cardID < right.cardID
    }
    .map(\.cardID)
  }
}
