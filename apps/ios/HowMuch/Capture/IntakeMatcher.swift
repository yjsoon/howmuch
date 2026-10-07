import Foundation

/// An existing register row, reduced to what matching needs. Built from
/// `Transaction` by `AppModel.intakeCandidates`.
struct IntakeCandidateRow: Equatable, Identifiable, Sendable {
  var id: String
  var accountID: String
  /// ISO `yyyy-MM-dd`, as the ledger stores it.
  var date: String
  /// Signed, in milliunits.
  var amountMilli: Int
  var payeeName: String
  var categoryID: String?
  var approved: Bool
  var isReconciled = false
  var isTransfer = false
  var isSplit = false
}

/// Decides add versus fix for what was read from a document, deterministically
/// and after extraction (docs/plans/share-intake.md section 6). Pure: the same
/// input gives the same proposals, and a proposal only ever names rows that
/// were passed in.
///
/// Scoring, highest first: the amount must already be equal (0.40), a closer
/// date adds up to 0.20, payee similarity adds up to 0.35 and an approved row
/// 0.05. 0.75 or more is a strong match, so a strong match needs a payee that
/// agrees at least in part; the same amount on the same day under another
/// merchant is only a possible duplicate.
struct IntakeMatcher: Sendable {
  var dayWindow = 3

  static let strongThreshold = 0.75
  private static let amountWeight = 0.40
  private static let dateWeight = 0.20
  private static let payeeWeight = 0.35
  private static let approvedWeight = 0.05
  private static let maxCandidateIDs = 5

  func match(
    _ extracted: [SlipMappedDraft],
    openAccountIDs: Set<String>,
    candidates: [IntakeCandidateRow]
  ) -> [IntakeProposal] {
    var claimed = Set<String>()
    var proposals: [IntakeProposal] = []
    for read in extracted {
      let result = proposal(for: read, openAccountIDs: openAccountIDs, candidates: candidates, claimed: claimed)
      // An existing row answers one line of the document, not two.
      if let target = result.targetTransactionID {
        claimed.insert(target)
      }
      proposals.append(result)
    }
    return proposals
  }

  private struct Scored {
    var row: IntakeCandidateRow
    var score: Double
    var distance: Int
  }

  private func proposal(
    for read: SlipMappedDraft,
    openAccountIDs: Set<String>,
    candidates: [IntakeCandidateRow],
    claimed: Set<String>
  ) -> IntakeProposal {
    let magnitude = read.draft.amountMagnitudeMilli
    guard magnitude > 0 else {
      return IntakeProposal(kind: .add, confidence: 0, draft: read.draft, reasons: ["No amount was read"])
    }
    let signed = read.draft.direction == .outflow ? -magnitude : magnitude
    let readDay = Self.dayNumber(read.draft.date.isoDateString)

    let pool: [(row: IntakeCandidateRow, distance: Int)] = candidates.compactMap { row in
      guard openAccountIDs.contains(row.accountID),
            !claimed.contains(row.id),
            row.amountMilli == signed,
            let readDay,
            let rowDay = Self.dayNumber(row.date) else {
        return nil
      }
      let distance = abs(rowDay - readDay)
      if distance <= dayWindow {
        return (row: row, distance: distance)
      }
      return nil
    }

    // The chosen account first; every open account only when it has nothing.
    let chosen = read.draft.accountID
    let inChosen = pool.filter { !chosen.isEmpty && $0.row.accountID == chosen }
    let searched = inChosen.isEmpty ? pool : inChosen

    guard !searched.isEmpty else {
      return IntakeProposal(
        kind: .add,
        confidence: 0.8,
        draft: read.draft,
        reasons: ["No row within \(dayWindow) days for this amount"]
      )
    }

    let unsorted = searched.map { entry in
      Scored(row: entry.row, score: score(read, entry.row, distance: entry.distance), distance: entry.distance)
    }
    let scored = unsorted.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
      return lhs.row.id < rhs.row.id
    }
    let best = scored[0]
    let candidateIDs = Array(scored.prefix(Self.maxCandidateIDs).map(\.row.id))

    guard best.score >= Self.strongThreshold else {
      return IntakeProposal(
        kind: .possibleDuplicate,
        confidence: best.score,
        draft: read.draft,
        candidateIDs: candidateIDs,
        reasons: ["Looks like \(describe(best.row)) already in the register"]
      )
    }

    // Two equally good rows: do not guess which one the document means.
    if scored.count > 1,
       scored[1].score >= Self.strongThreshold,
       abs(scored[1].score - best.score) < 1e-9 {
      let tied = scored.filter { abs($0.score - best.score) < 1e-9 }
      return IntakeProposal(
        kind: .add,
        confidence: 0.5,
        draft: read.draft,
        candidateIDs: candidateIDs,
        reasons: ["Matches \(tied.count) existing rows equally well, so it is added as new"]
      )
    }

    var reasons = ["Same amount within \(dayWindow) days"]
    if !chosen.isEmpty, best.row.accountID != chosen {
      reasons.append("Found in another account")
    }
    if best.row.isReconciled {
      reasons.append("Reconciled · approving reopens it")
    }
    let changed = differences(read, best.row)
    if changed.isEmpty {
      return IntakeProposal(
        kind: .alreadyIn,
        confidence: best.score,
        draft: read.draft,
        targetTransactionID: best.row.id,
        candidateIDs: candidateIDs,
        reasons: reasons
      )
    }
    if changed.contains(.payee) {
      reasons.append("Payee “\(best.row.payeeName)” becomes “\(read.draft.payeeName)”")
    }
    if changed.contains(.category) {
      reasons.append("Category differs")
    }
    return IntakeProposal(
      kind: .edit,
      confidence: best.score,
      draft: read.draft,
      targetTransactionID: best.row.id,
      changedFields: changed,
      candidateIDs: candidateIDs,
      reasons: reasons
    )
  }

  private func score(_ read: SlipMappedDraft, _ row: IntakeCandidateRow, distance: Int) -> Double {
    let dateScore = 1 - Double(distance) / Double(dayWindow + 1)
    let payeeScore = PayeeNames.similarity(read.draft.payeeName, row.payeeName)
    return Self.amountWeight
      + Self.dateWeight * max(0, dateScore)
      + Self.payeeWeight * payeeScore
      + (row.approved ? Self.approvedWeight : 0)
  }

  /// What a Fix would change. Amount and direction already agree, and a date
  /// within the window is tolerated (banks post a day late), so only the payee
  /// and category can differ. Transfers and splits keep their own payee and
  /// categories.
  private func differences(_ read: SlipMappedDraft, _ row: IntakeCandidateRow) -> [IntakeField] {
    var fields: [IntakeField] = []
    let readTokens = PayeeNames.tokens(read.draft.payeeName)
    if !row.isTransfer, read.draft.transferAccountID == nil,
       !readTokens.isEmpty, readTokens != PayeeNames.tokens(row.payeeName) {
      fields.append(.payee)
    }
    if read.parsedCategory, let category = read.draft.categoryID,
       !row.isTransfer, !row.isSplit, category != row.categoryID {
      fields.append(.category)
    }
    return fields
  }

  private func describe(_ row: IntakeCandidateRow) -> String {
    let payee = row.payeeName.isEmpty ? "a transaction" : row.payeeName
    return "\(row.date) · \(payee)"
  }

  /// Days since 1970-01-01 for an ISO `yyyy-MM-dd` date, by pure integer
  /// arithmetic so month ends, leap days and time zones cannot skew a distance.
  static func dayNumber(_ iso: String) -> Int? {
    let parts = iso.prefix(10).split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2]),
          (1...12).contains(month),
          (1...31).contains(day) else {
      return nil
    }
    let shiftedYear = month <= 2 ? year - 1 : year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let monthIndex = (month + 9) % 12
    let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }
}
