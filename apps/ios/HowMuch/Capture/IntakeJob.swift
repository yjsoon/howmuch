import Foundation

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
  /// A weak match: would be a new transaction, but looks like `candidateIDs`.
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
  case rejected

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = IntakeDecision(rawValue: raw) ?? .pending
  }
}

/// Fields an `edit` proposal changes on the existing transaction.
enum IntakeField: String, Codable, Equatable, Sendable {
  case payee
  case category

  var label: String {
    switch self {
    case .payee: "Payee"
    case .category: "Category"
    }
  }
}

struct IntakeProposal: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var kind: IntakeProposalKind
  /// 0 to 1: how sure the matcher is of the kind it chose.
  var confidence: Double
  /// What was read from the document. For an edit, only `changedFields` of it
  /// are applied, on top of the target row as it is when approved.
  var draft: TransactionDraft
  var targetTransactionID: String?
  var changedFields: [IntakeField]
  /// Every existing row the matcher considered a match, best first.
  var candidateIDs: [String]
  var reasons: [String]
  var decision: IntakeDecision

  init(
    id: UUID = UUID(),
    kind: IntakeProposalKind,
    confidence: Double,
    draft: TransactionDraft,
    targetTransactionID: String? = nil,
    changedFields: [IntakeField] = [],
    candidateIDs: [String] = [],
    reasons: [String] = [],
    decision: IntakeDecision = .pending
  ) {
    self.id = id
    self.kind = kind
    self.confidence = confidence
    self.draft = draft
    self.targetTransactionID = targetTransactionID
    self.changedFields = changedFields
    self.candidateIDs = candidateIDs
    self.reasons = reasons
    self.decision = decision
  }

  /// Approve all applies adds and edits the reviewer has not rejected. A
  /// possible duplicate waits for an explicit accept; already-in rows never apply.
  var appliesOnApproval: Bool {
    switch (kind, decision) {
    case (_, .rejected), (.alreadyIn, _):
      return false
    case (_, .accepted):
      return true
    case (.add, .pending), (.edit, .pending):
      return true
    case (.possibleDuplicate, .pending):
      return false
    }
  }

  /// A row that cannot be saved as read: no amount or no account yet.
  var isIncomplete: Bool {
    switch kind {
    case .edit:
      return targetTransactionID == nil
    default:
      return draft.accountID.isEmpty || draft.amountMagnitudeMilli <= 0
    }
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
    self.appliedSummary = appliedSummary
    self.updatedAt = updatedAt ?? createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, createdAt, origin, sourceFiles, accountID, decideAccount, hint, note, contentHash
    case state, failureMessage, proposals, extractions, appliedSummary, updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    origin = try container.decodeIfPresent(IntakeOrigin.self, forKey: .origin) ?? .other
    sourceFiles = try container.decodeIfPresent([InboxSourceFile].self, forKey: .sourceFiles) ?? []
    accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    decideAccount = try container.decodeIfPresent(Bool.self, forKey: .decideAccount) ?? false
    hint = (try? container.decodeIfPresent(IntakeHint.self, forKey: .hint)) ?? .auto
    note = try container.decodeIfPresent(String.self, forKey: .note)
    contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
    state = try container.decodeIfPresent(IntakeJobState.self, forKey: .state) ?? .failed
    failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)
    proposals = try container.decodeIfPresent([IntakeProposal].self, forKey: .proposals) ?? []
    extractions = try container.decodeIfPresent([SlipMappedDraft].self, forKey: .extractions) ?? []
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

  /// "1 new · 1 fix · 1 already in", or nil when nothing was proposed.
  var proposalSummary: String? {
    let counts = counts
    var parts: [String] = []
    if counts.added > 0 { parts.append("\(counts.added) new") }
    if counts.fixed > 0 { parts.append("\(counts.fixed) fix") }
    if counts.possibleDuplicates > 0 {
      parts.append("\(counts.possibleDuplicates) possible \(counts.possibleDuplicates == 1 ? "duplicate" : "duplicates")")
    }
    if counts.alreadyIn > 0 { parts.append("\(counts.alreadyIn) already in") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
      return failureMessage ?? "Couldn't read this"
    }
  }

  /// "DBS Altitude screenshots", "2 screenshots", "PDF".
  func title(accountName: String?) -> String {
    let images = sourceFiles.filter { $0.kind == .image }.count
    let pdfs = sourceFiles.filter { $0.kind == .pdf }.count
    let texts = sourceFiles.filter { $0.kind == .text }.count
    let noun: String
    let count: Int
    if images > 0 {
      noun = images == 1 ? "screenshot" : "screenshots"
      count = images
    } else if pdfs > 0 {
      noun = pdfs == 1 ? "PDF" : "PDFs"
      count = pdfs
    } else {
      noun = texts == 1 ? "text" : "texts"
      count = max(texts, 1)
    }
    if let accountName, !accountName.isEmpty {
      return "\(accountName) \(noun)"
    }
    if count == 1 {
      return noun == "text" ? "Pasted text" : noun.prefix(1).uppercased() + String(noun.dropFirst())
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
}
