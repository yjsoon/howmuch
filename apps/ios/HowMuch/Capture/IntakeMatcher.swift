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

extension IntakeCandidateRow {
  init(transaction row: Transaction) {
    self.init(
      id: row.id,
      accountID: row.accountID,
      date: row.date,
      amountMilli: row.amount,
      payeeName: row.payeeName ?? "",
      categoryID: row.categoryID,
      approved: row.approved,
      isReconciled: row.cleared == .reconciled,
      isTransfer: row.transferAccountID != nil,
      isSplit: row.isSplit
    )
  }
}

/// Decides add versus fix for what was read from a document, deterministically
/// and after extraction (docs/plans/share-intake.md section 6). Pure: the same
/// input gives the same proposals, and a proposal only ever names rows that
/// were passed in.
///
/// Candidates share the line's absolute amount and fall within the day window.
/// Scoring, highest first: amount 0.30 (always earned), a closer date adds up
/// to 0.20, payee similarity up to 0.50. 0.74 or more is a strong match, so a
/// strong match needs a payee that agrees at least in part; the same amount on
/// the same day under another merchant is only a possible duplicate. Whether a
/// row is approved does not change the score.
///
/// A match is never strong, and so never a Fix or Already in, when the
/// direction differs (a refund of the same amount), when the document gave no
/// date, or when two rows score the same.
struct IntakeMatcher: Sendable {
  var dayWindow = 3

  static let strongThreshold = 0.74
  /// A weak match in another account scoring below this is plain New.
  static let possibleDuplicateFloor = 0.55
  private static let amountWeight = 0.30
  private static let dateWeight = 0.20
  private static let payeeWeight = 0.50
  private static let maxCandidateIDs = 5
  /// Confidence of a New line whose duplicate check could not be completed.
  private static let limitedConfidence = 0.5
  /// Confidence of a New line under a Fix hint: shown, but not ticked.
  private static let unmatchedFixConfidence = 0.4

  /// - Parameters:
  ///   - hint: `.fix` keeps lines with no strong match, unticked, with a reason.
  ///   - duplicateCheckLimited: the register could not be fully searched
  ///     (offline), so New lines are not ticked by default.
  func match(
    _ extracted: [SlipMappedDraft],
    openAccountIDs: Set<String>,
    candidates: [IntakeCandidateRow],
    hint: IntakeHint = .auto,
    duplicateCheckLimited: Bool = false
  ) -> [IntakeProposal] {
    var claimed = Set<String>()
    var proposals: [IntakeProposal] = []
    for read in extracted {
      var result = proposal(
        for: read, openAccountIDs: openAccountIDs, candidates: candidates, claimed: claimed, hint: hint
      )
      // An existing row answers one line of the document, not two.
      if let target = result.targetTransactionID {
        claimed.insert(target)
      }
      if result.kind == .add, duplicateCheckLimited {
        result.confidence = min(result.confidence, Self.limitedConfidence)
        result.reasons.append("Duplicate check limited · offline")
      }
      if hint == .fix, result.kind == .add || result.kind == .possibleDuplicate {
        result.confidence = min(result.confidence, Self.unmatchedFixConfidence)
        result.reasons.append("No matching transaction found")
      }
      proposals.append(result)
    }
    return proposals
  }

  private struct Scored {
    var row: IntakeCandidateRow
    var score: Double
    var distance: Int
    var sameDirection: Bool
  }

  private func proposal(
    for read: SlipMappedDraft,
    openAccountIDs: Set<String>,
    candidates: [IntakeCandidateRow],
    claimed: Set<String>,
    hint: IntakeHint
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
            abs(row.amountMilli) == magnitude,
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
      Scored(
        row: entry.row,
        score: score(read, entry.row, distance: entry.distance),
        distance: entry.distance,
        sameDirection: entry.row.amountMilli == signed
      )
    }
    // Same-direction rows outrank an opposite-direction one of any score.
    let scored = unsorted.sorted { lhs, rhs in
      if lhs.sameDirection != rhs.sameDirection { return lhs.sameDirection }
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
      return lhs.row.id < rhs.row.id
    }
    let best = scored[0]
    let candidateIDs = Array(scored.prefix(Self.maxCandidateIDs).map(\.row.id))

    guard best.sameDirection else {
      return IntakeProposal(
        kind: .possibleDuplicate,
        confidence: best.score,
        draft: read.draft,
        candidateIDs: candidateIDs,
        reasons: ["Same amount as \(describe(best.row)), but the other way round"]
      )
    }

    // Two equally good rows: do not guess which one the document means.
    if scored.count > 1,
       best.score >= Self.strongThreshold,
       scored[1].sameDirection,
       abs(scored[1].score - best.score) < 1e-9 {
      let tied = scored.filter { $0.sameDirection && abs($0.score - best.score) < 1e-9 }
      return IntakeProposal(
        kind: .possibleDuplicate,
        confidence: best.score,
        draft: read.draft,
        candidateIDs: candidateIDs,
        reasons: ["Matches \(tied.count) existing rows equally well"]
      )
    }

    guard best.score >= Self.strongThreshold, read.parsedDate else {
      var reasons = ["Looks like \(describe(best.row)) already in the register"]
      if !read.parsedDate {
        reasons.append("No date was read, so it cannot be a certain match")
      }
      // A near miss in another account under a different merchant is a
      // coincidence of amount: plain New, keeping the candidates for a flip.
      if !chosen.isEmpty, best.row.accountID != chosen, best.score < Self.possibleDuplicateFloor {
        return IntakeProposal(
          kind: .add,
          confidence: 0.8,
          draft: read.draft,
          candidateIDs: candidateIDs,
          reasons: ["Same amount in another account, but a different payee"]
        )
      }
      return IntakeProposal(
        kind: .possibleDuplicate,
        confidence: best.score,
        draft: read.draft,
        candidateIDs: candidateIDs,
        reasons: reasons
      )
    }

    var reasons = ["Same amount within \(dayWindow) days"]
    if !chosen.isEmpty, best.row.accountID != chosen {
      reasons.append("Found in another account")
    }
    if best.row.isReconciled {
      // Editing payee or category leaves the cleared state alone
      // (`TransactionDraft.shouldWriteCleared`), so a Fix never reopens it.
      reasons.append("Reconciled · stays reconciled")
    }
    let changed = Self.differences(
      draft: read.draft, parsedCategory: read.parsedCategory, row: best.row,
      allowContainment: hint != .fix
    )
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
    return Self.amountWeight + Self.dateWeight * max(0, dateScore) + Self.payeeWeight * payeeScore
  }

  /// What a Fix would change on `row`. Amount already agrees, and a date
  /// within the window is tolerated (banks post a day late), so only the payee
  /// and category can differ. Transfers and splits keep their own payee and
  /// categories. Approve runs this again on the live row.
  static func differences(
    draft: TransactionDraft,
    parsedCategory: Bool,
    row: IntakeCandidateRow,
    allowContainment: Bool = true
  ) -> [IntakeField] {
    var fields: [IntakeField] = []
    let readTokens = PayeeNames.tokens(draft.payeeName)
    let existingTokens = PayeeNames.tokens(row.payeeName)
    // A raw bank descriptor that contains every word of the saved payee is the
    // same payee ("KOPITIAM AMK" for "Kopitiam"). The test is on whole words,
    // so "GrabFood" does not contain "Grab" and stays a different payee.
    // Under a Fix hint the owner asked for corrections, so a longer name is a rename.
    let samePayee = readTokens == existingTokens
      || (allowContainment && !existingTokens.isEmpty && Set(existingTokens).isSubset(of: Set(readTokens)))
    if !row.isTransfer, draft.transferAccountID == nil, !readTokens.isEmpty, !samePayee {
      fields.append(.payee)
    }
    if parsedCategory, let category = draft.categoryID,
       !row.isTransfer, !row.isSplit, category != row.categoryID {
      fields.append(.category)
    }
    return fields
  }

  /// The fields a Fix changes once the reviewer has edited it: what the
  /// matcher found (`differences`, against the reader's draft) plus any
  /// amount, date or memo the reviewer changed from the reader's draft and
  /// that differs from the live row. Order: payee, category, amount, date, memo.
  static func editedDifferences(
    draft: TransactionDraft,
    proposed: TransactionDraft,
    parsedCategory: Bool,
    live: Transaction,
    allowContainment: Bool = true
  ) -> [IntakeField] {
    let base = differences(
      draft: draft,
      parsedCategory: parsedCategory,
      row: IntakeCandidateRow(transaction: live),
      allowContainment: allowContainment
    )
    var fields: [IntakeField] = base.filter { $0 == .payee || $0 == .category }
    if draft.signedMilliunits != proposed.signedMilliunits, draft.signedMilliunits != live.amount {
      fields.append(.amount)
    }
    if draft.date.isoDateString != proposed.date.isoDateString, draft.date.isoDateString != live.date {
      fields.append(.date)
    }
    if trimmed(draft.memo) != trimmed(proposed.memo), trimmed(draft.memo) != trimmed(live.memo ?? "") {
      fields.append(.memo)
    }
    return fields
  }

  /// Which of a Fix's wanted fields still differ on the live row at approval.
  static func pendingFixFields(
    wanted: [IntakeField],
    draft: TransactionDraft,
    live: Transaction,
    allowContainment: Bool = true
  ) -> [IntakeField] {
    let base = differences(
      draft: draft,
      parsedCategory: wanted.contains(.category),
      row: IntakeCandidateRow(transaction: live),
      allowContainment: allowContainment
    )
    return wanted.filter { field in
      switch field {
      case .payee, .category: base.contains(field)
      case .amount: live.amount != draft.signedMilliunits
      case .date: live.date != draft.date.isoDateString
      case .memo: trimmed(draft.memo) != trimmed(live.memo ?? "")
      case .unknown: false
      }
    }
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
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
