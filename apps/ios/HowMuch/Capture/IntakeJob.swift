import Foundation

/// Decodes one element, yielding nil (instead of failing the whole array) for a
/// shape this build cannot read, so one bad row never loses a job.
private struct Lossy<Value: Decodable>: Decodable {
  var value: Value?

  init(from decoder: Decoder) throws {
    value = try? Value(from: decoder)
  }
}

/// Where an intake job came from. Only the share sheet creates jobs today.
enum IntakeOrigin: String, Codable, Equatable, Sendable {
  case shareSheet
  case appIntent
  case detectedScreenshot
  /// An origin written by a newer build that this build does not know.
  case other

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = IntakeOrigin(rawValue: raw) ?? .other
  }

  init(source: InboxSource) {
    switch source {
    case .shareSheet: self = .shareSheet
    case .appIntent: self = .appIntent
    case .detectedScreenshot: self = .detectedScreenshot
    case .other: self = .other
    }
  }
}

enum IntakeJobState: String, Codable, Equatable, Sendable {
  case queued
  case reading
  case proposed
  case needsYou
  case applied
  case discarded
  case failed

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = IntakeJobState(rawValue: raw) ?? .failed
  }
}

enum IntakeProposalKind: String, Codable, Equatable, Sendable {
  /// A new transaction.
  case add
  /// A correction to an existing transaction (`targetTransactionID`).
  case edit
  /// Already in the register, nothing to do (`targetTransactionID`).
  case alreadyIn
  /// A weak or ambiguous match: would be a new transaction, but looks like `candidateIDs`.
  case possibleDuplicate

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    // An unknown kind from a newer build is never applied by default.
    self = IntakeProposalKind(rawValue: raw) ?? .possibleDuplicate
  }
}

enum IntakeDecision: String, Codable, Equatable, Sendable {
  case pending
  case accepted
  /// Accepted after the reviewer changed the row (the review screen, a later release).
  case editedThenAccepted
  case rejected

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = IntakeDecision(rawValue: raw) ?? .pending
  }

  var isAccepted: Bool {
    self == .accepted || self == .editedThenAccepted
  }
}

/// Fields an `edit` proposal changes on the existing transaction. The matcher
/// only emits payee and category today; the rest are reserved for notes and
/// the review screen.
enum IntakeField: String, Codable, Equatable, Sendable {
  case payee
  case category
  case amount
  case date
  case memo
  /// A field written by a newer build that this build does not know. Ignored.
  case unknown

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = IntakeField(rawValue: raw) ?? .unknown
  }

  var label: String {
    switch self {
    case .payee: "Payee"
    case .category: "Category"
    case .amount: "Amount"
    case .date: "Date"
    case .memo: "Memo"
    case .unknown: "Field"
    }
  }
}

struct IntakeProposal: Codable, Equatable, Identifiable, Sendable {
  /// At or above this a pending add or fix is ticked by default; below it the
  /// row waits unticked (an offline duplicate check, a Fix hint with no match).
  static let preselectThreshold = 0.6

  var id: UUID
  var kind: IntakeProposalKind
  /// 0 to 1: how sure the matcher is of the kind it chose.
  var confidence: Double
  /// What will be saved. Starts equal to `proposedDraft`; the review screen edits it.
  var draft: TransactionDraft
  /// What the reader and matcher proposed, never edited, so a later release can
  /// tell what the owner changed.
  var proposedDraft: TransactionDraft
  var targetTransactionID: String?
  /// The target row as it was when matched, for display. Approve re-reads it live.
  var targetSnapshot: Transaction?
  var changedFields: [IntakeField]
  /// Every existing row the matcher considered a match, best first.
  var candidateIDs: [String]
  var reasons: [String]
  var decision: IntakeDecision
  /// Index into the job's `sourceFiles` this line was read from, when known.
  var sourceFileIndex: Int?
  /// Set once this row's effect has been committed.
  var isApplied: Bool
  /// Why this row could not be applied ("Couldn't find the original transaction").
  var issue: String?
  /// Set when the owner turned a New row into a Fix of one of its candidates:
  /// the kind to go back to if they undo it.
  var flippedFrom: IntakeProposalKind?
  /// The decision the row had before it was flipped, restored on undo.
  var preFlipDecision: IntakeDecision?
  /// The learned rule that set fields on this row before matching, if any. Approve
  /// compares what it set with what the owner saved to count an override.
  var ruleApplications: [IntakeRuleApplication]
  /// What the reader saw as the payee, when a learned rule changed it. Remember
  /// this? learns from this, so a rule can match future raw descriptors.
  var readPayee: String?

  init(
    id: UUID = UUID(),
    kind: IntakeProposalKind,
    confidence: Double,
    draft: TransactionDraft,
    proposedDraft: TransactionDraft? = nil,
    targetTransactionID: String? = nil,
    targetSnapshot: Transaction? = nil,
    changedFields: [IntakeField] = [],
    candidateIDs: [String] = [],
    reasons: [String] = [],
    decision: IntakeDecision = .pending,
    sourceFileIndex: Int? = nil,
    isApplied: Bool = false,
    issue: String? = nil,
    flippedFrom: IntakeProposalKind? = nil,
    preFlipDecision: IntakeDecision? = nil,
    ruleApplications: [IntakeRuleApplication] = [],
    readPayee: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.confidence = confidence
    self.draft = draft
    self.proposedDraft = proposedDraft ?? draft
    self.targetTransactionID = targetTransactionID
    self.targetSnapshot = targetSnapshot
    self.changedFields = changedFields
    self.candidateIDs = candidateIDs
    self.reasons = reasons
    self.decision = decision
    self.sourceFileIndex = sourceFileIndex
    self.isApplied = isApplied
    self.issue = issue
    self.flippedFrom = flippedFrom
    self.preFlipDecision = preFlipDecision
    self.ruleApplications = ruleApplications
    self.readPayee = readPayee
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, confidence, draft, proposedDraft, targetTransactionID, targetSnapshot
    case changedFields, candidateIDs, reasons, decision, sourceFileIndex, isApplied, issue, flippedFrom, preFlipDecision
    case ruleApplications, readPayee
  }

  /// Tolerant: a draft this build cannot decode (the draft type grew a field,
  /// say) yields a rejected, unappliable row instead of losing the job.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    kind = try container.decodeIfPresent(IntakeProposalKind.self, forKey: .kind) ?? .possibleDuplicate
    confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
    let decodedDraft = try? container.decode(TransactionDraft.self, forKey: .draft)
    draft = decodedDraft ?? TransactionDraft()
    proposedDraft = (try? container.decode(TransactionDraft.self, forKey: .proposedDraft)) ?? draft
    targetTransactionID = try container.decodeIfPresent(String.self, forKey: .targetTransactionID)
    targetSnapshot = try? container.decodeIfPresent(Transaction.self, forKey: .targetSnapshot)
    changedFields = (try? container.decodeIfPresent([IntakeField].self, forKey: .changedFields)) ?? []
    candidateIDs = (try? container.decodeIfPresent([String].self, forKey: .candidateIDs)) ?? []
    reasons = (try? container.decodeIfPresent([String].self, forKey: .reasons)) ?? []
    decision = (try? container.decodeIfPresent(IntakeDecision.self, forKey: .decision)) ?? .pending
    sourceFileIndex = try container.decodeIfPresent(Int.self, forKey: .sourceFileIndex)
    isApplied = try container.decodeIfPresent(Bool.self, forKey: .isApplied) ?? false
    issue = try container.decodeIfPresent(String.self, forKey: .issue)
    flippedFrom = try? container.decodeIfPresent(IntakeProposalKind.self, forKey: .flippedFrom)
    preFlipDecision = try? container.decodeIfPresent(IntakeDecision.self, forKey: .preFlipDecision)
    ruleApplications = (try? container.decodeIfPresent([Lossy<IntakeRuleApplication>].self, forKey: .ruleApplications))?
      .compactMap(\.value) ?? []
    readPayee = try? container.decodeIfPresent(String.self, forKey: .readPayee)
    if decodedDraft == nil {
      kind = .possibleDuplicate
      decision = .rejected
      issue = "Couldn’t restore this row"
    }
  }

  /// Approve all applies adds and fixes the reviewer has not turned down and
  /// that the matcher was sure enough to tick. A possible duplicate waits for
  /// an explicit accept; already-in rows never apply; a row already applied
  /// is not applied twice.
  var appliesOnApproval: Bool {
    guard !isApplied else {
      return false
    }
    switch (kind, decision) {
    case (_, .rejected), (.alreadyIn, _):
      return false
    case (_, .accepted), (_, .editedThenAccepted):
      return true
    case (.add, .pending), (.edit, .pending):
      return confidence >= Self.preselectThreshold
    case (.possibleDuplicate, .pending):
      return false
    }
  }

  /// A row that cannot be saved as read: no amount or no account yet.
  var isIncomplete: Bool {
    switch kind {
    case .edit, .alreadyIn:
      return targetTransactionID == nil
    default:
      return draft.accountID.isEmpty || draft.amountMagnitudeMilli <= 0
    }
  }

  /// The reviewer has not ticked, unticked, edited or flipped this row, so a
  /// fresh match may replace it.
  var isUntouched: Bool {
    decision == .pending && !isApplied && draft == proposedDraft && flippedFrom == nil
  }

  /// Nothing more to decide: applied, turned down, or nothing to do.
  var isResolved: Bool {
    isApplied || decision == .rejected || kind == .alreadyIn
  }
}

struct IntakeProposalCounts: Equatable, Sendable {
  var added = 0
  var fixed = 0
  var alreadyIn = 0
  var possibleDuplicates = 0

  var isEmpty: Bool {
    added == 0 && fixed == 0 && alreadyIn == 0 && possibleDuplicates == 0
  }
}

struct IntakeJob: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var createdAt: Date
  var origin: IntakeOrigin
  var sourceFiles: [InboxSourceFile]
  var accountID: String?
  var decideAccount: Bool
  var hint: IntakeHint
  var note: String?
  var contentHash: String?
  var state: IntakeJobState
  var failureMessage: String?
  var proposals: [IntakeProposal]
  /// What the reader extracted, kept so choosing an account can match again.
  var extractions: [SlipMappedDraft]
  /// For each extraction, the index into `sourceFiles` it came from.
  var extractionSourceIndexes: [Int]
  /// Extractions read by the deterministic line parser because the model
  /// returned nothing. Their proposals are capped at Likely and say so.
  var fallbackExtractionIndexes: [Int]
  /// The plan and connection the job was shared into. A job from another
  /// budget is shown as failed and cannot be approved.
  var planID: String?
  var connectionFingerprint: String?
  /// True when the register could not be fully searched for duplicates (offline).
  var duplicateCheckLimited: Bool
  /// Set just before Approve commits, cleared once the result is saved. A job
  /// found with it set was interrupted; approving again is safe because every
  /// create carries its import ID.
  var applyStartedAt: Date?
  /// "1 added, 1 fixed" once applied.
  var appliedSummary: String?
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    origin: IntakeOrigin = .shareSheet,
    sourceFiles: [InboxSourceFile],
    accountID: String? = nil,
    decideAccount: Bool = false,
    hint: IntakeHint = .auto,
    note: String? = nil,
    contentHash: String? = nil,
    state: IntakeJobState = .queued,
    failureMessage: String? = nil,
    proposals: [IntakeProposal] = [],
    extractions: [SlipMappedDraft] = [],
    extractionSourceIndexes: [Int] = [],
    fallbackExtractionIndexes: [Int] = [],
    planID: String? = nil,
    connectionFingerprint: String? = nil,
    duplicateCheckLimited: Bool = false,
    applyStartedAt: Date? = nil,
    appliedSummary: String? = nil,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.origin = origin
    self.sourceFiles = sourceFiles
    self.accountID = accountID
    self.decideAccount = decideAccount
    self.hint = hint
    self.note = note
    self.contentHash = contentHash
    self.state = state
    self.failureMessage = failureMessage
    self.proposals = proposals
    self.extractions = extractions
    self.extractionSourceIndexes = extractionSourceIndexes
    self.fallbackExtractionIndexes = fallbackExtractionIndexes
    self.planID = planID
    self.connectionFingerprint = connectionFingerprint
    self.duplicateCheckLimited = duplicateCheckLimited
    self.applyStartedAt = applyStartedAt
    self.appliedSummary = appliedSummary
    self.updatedAt = updatedAt ?? createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, createdAt, origin, sourceFiles, accountID, decideAccount, hint, note, contentHash
    case state, failureMessage, proposals, extractions, extractionSourceIndexes, fallbackExtractionIndexes
    case planID, connectionFingerprint, duplicateCheckLimited, applyStartedAt, appliedSummary, updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    origin = (try? container.decodeIfPresent(IntakeOrigin.self, forKey: .origin)) ?? .other
    sourceFiles = (try? container.decodeIfPresent([Lossy<InboxSourceFile>].self, forKey: .sourceFiles))?
      .compactMap(\.value) ?? []
    accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    decideAccount = try container.decodeIfPresent(Bool.self, forKey: .decideAccount) ?? false
    hint = (try? container.decodeIfPresent(IntakeHint.self, forKey: .hint)) ?? .auto
    note = try container.decodeIfPresent(String.self, forKey: .note)
    contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
    state = (try? container.decodeIfPresent(IntakeJobState.self, forKey: .state)) ?? .failed
    failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)
    proposals = (try? container.decodeIfPresent([Lossy<IntakeProposal>].self, forKey: .proposals))?
      .compactMap(\.value) ?? []
    extractions = (try? container.decodeIfPresent([Lossy<SlipMappedDraft>].self, forKey: .extractions))?
      .compactMap(\.value) ?? []
    extractionSourceIndexes = (try? container.decodeIfPresent([Int].self, forKey: .extractionSourceIndexes)) ?? []
    fallbackExtractionIndexes =
      (try? container.decodeIfPresent([Int].self, forKey: .fallbackExtractionIndexes)) ?? []
    planID = try container.decodeIfPresent(String.self, forKey: .planID)
    connectionFingerprint = try container.decodeIfPresent(String.self, forKey: .connectionFingerprint)
    duplicateCheckLimited = try container.decodeIfPresent(Bool.self, forKey: .duplicateCheckLimited) ?? false
    applyStartedAt = try container.decodeIfPresent(Date.self, forKey: .applyStartedAt)
    appliedSummary = try container.decodeIfPresent(String.self, forKey: .appliedSummary)
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
  }

  // MARK: Display

  var counts: IntakeProposalCounts {
    var counts = IntakeProposalCounts()
    for proposal in proposals {
      switch proposal.kind {
      case .add: counts.added += 1
      case .edit: counts.fixed += 1
      case .alreadyIn: counts.alreadyIn += 1
      case .possibleDuplicate: counts.possibleDuplicates += 1
      }
    }
    return counts
  }

  private var summaryParts: [String] {
    let counts = counts
    var parts: [String] = []
    if counts.added > 0 { parts.append("\(counts.added) new") }
    if counts.fixed > 0 { parts.append("\(counts.fixed) fix") }
    if counts.possibleDuplicates > 0 {
      parts.append("\(counts.possibleDuplicates) possible \(counts.possibleDuplicates == 1 ? "duplicate" : "duplicates")")
    }
    if counts.alreadyIn > 0 { parts.append("\(counts.alreadyIn) already in") }
    return parts
  }

  /// "1 new · 1 fix · 1 already in", or nil when nothing was proposed.
  var proposalSummary: String? {
    let parts = summaryParts
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// The same for VoiceOver: "1 new and 1 fix", with no middle dots.
  var spokenProposalSummary: String? {
    let parts = summaryParts
    switch parts.count {
    case 0: return nil
    case 1: return parts[0]
    default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
  }

  /// The line under the title: what is happening or what was found.
  var statusSummary: String {
    switch state {
    case .queued, .reading:
      return "Reading on this phone…"
    case .proposed:
      return proposalSummary ?? "Nothing to add"
    case .needsYou:
      return failureMessage ?? "Choose an account to continue"
    case .applied:
      return appliedSummary ?? "Applied"
    case .discarded:
      return "Discarded"
    case .failed:
      return failureMessage ?? "Couldn’t read this"
    }
  }

  /// The summary read aloud.
  var spokenStatusSummary: String {
    state == .proposed ? (spokenProposalSummary ?? "Nothing to add") : statusSummary
  }

  private var payloadNoun: (noun: String, count: Int) {
    let images = sourceFiles.filter { $0.kind == .image }.count
    let pdfs = sourceFiles.filter { $0.kind == .pdf }.count
    let texts = sourceFiles.filter { $0.kind == .text }.count
    if images > 0 {
      return (images == 1 ? "screenshot" : "screenshots", images)
    }
    if pdfs > 0 {
      return (pdfs == 1 ? "PDF" : "PDFs", pdfs)
    }
    return (texts == 1 ? "text" : "texts", max(texts, 1))
  }

  /// "DBS Altitude screenshots", "2 screenshots", "PDF".
  func title(accountName: String?) -> String {
    let (noun, count) = payloadNoun
    if let accountName, !accountName.isEmpty {
      return "\(accountName) \(noun)"
    }
    if count == 1 {
      return noun == "text" ? "Pasted text" : noun.prefix(1).uppercased() + String(noun.dropFirst())
    }
    return "\(count) \(noun)"
  }

  /// For a sentence: "2 DBS Altitude screenshots", "1 screenshot", "1 PDF".
  func sourceDescription(accountName: String?) -> String {
    let (noun, count) = payloadNoun
    if let accountName, !accountName.isEmpty {
      return "\(count) \(accountName) \(noun)"
    }
    return "\(count) \(noun)"
  }

  /// Lower is more urgent. The Accounts band shows the two lowest.
  var urgencyRank: Int {
    switch state {
    case .needsYou: 0
    case .proposed: 1
    case .reading, .queued: 2
    case .failed: 3
    case .applied: 4
    case .discarded: 5
    }
  }

  /// States the Accounts band cares about: anything but applied or discarded.
  var isActive: Bool {
    state != .applied && state != .discarded
  }
}
