import Foundation
import Observation
import os

// The skill file and learned rules for document intake (docs/plans/share-intake.md
// sections 8 and 9). On this device only in this version: no server sync, no
// model reads the notes except the Apple Intelligence reader's prompt.

/// Decodes one element, yielding nil (instead of failing the whole array) for a
/// shape this build cannot read, so one rule from a newer build never loses the file.
private struct LossyElement<Value: Decodable>: Decodable {
  var value: Value?

  init(from decoder: Decoder) throws {
    value = try? Value(from: decoder)
  }
}

/// A JSON value kept as read, so a rule or account this build cannot understand
/// is written back unchanged instead of being erased by the next save.
enum RawJSON: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([RawJSON])
  case object([String: RawJSON])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([RawJSON].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: RawJSON].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

/// One element read twice: as the value it should be, and as raw JSON to keep if it cannot be.
private struct PreservedElement<Value: Decodable>: Decodable {
  var value: Value?
  var raw: RawJSON

  init(from decoder: Decoder) throws {
    raw = try RawJSON(from: decoder)
    value = try? Value(from: decoder)
  }
}

private extension KeyedDecodingContainer {
  /// The readable elements, and the raw JSON of those this build cannot read. A
  /// key that is present but is not an array throws, so the file counts as unreadable.
  func preservedArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> (items: [T], unread: [RawJSON]) {
    let elements = try decodeIfPresent([PreservedElement<T>].self, forKey: key) ?? []
    return (elements.compactMap(\.value), elements.filter { $0.value == nil }.map(\.raw))
  }

  /// The value, or nil when the key is missing or holds something this build cannot read.
  func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
    (try? decodeIfPresent(type, forKey: key)) ?? nil
  }

  func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
    (lenient([LossyElement<T>].self, forKey: key) ?? []).compactMap(\.value)
  }
}

// MARK: Structured settings

enum IntakeDateOrder: String, Codable, CaseIterable, Equatable, Sendable {
  case dmy
  case mdy
  case ymd

  /// "DD/MM", as the editor shows it.
  var label: String {
    switch self {
    case .dmy: "DD/MM"
    case .mdy: "MM/DD"
    case .ymd: "YYYY/MM"
    }
  }
}

struct IntakeSkillLocale: Codable, Equatable, Sendable {
  var currency = "SGD"
  var timezone = "Asia/Singapore"
  var dateOrder: IntakeDateOrder = .dmy

  init() {}

  private enum CodingKeys: String, CodingKey {
    case currency, timezone, dateOrder
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let currency = container.lenient(String.self, forKey: .currency), !currency.isEmpty {
      self.currency = currency
    }
    if let timezone = container.lenient(String.self, forKey: .timezone), !timezone.isEmpty {
      self.timezone = timezone
    }
    // An order from a newer build falls back to the default.
    dateOrder = container.lenient(IntakeDateOrder.self, forKey: .dateOrder) ?? .dmy
  }

  /// "Singapore" from "Asia/Singapore".
  var place: String {
    (timezone.split(separator: "/").last.map(String.init) ?? timezone).replacingOccurrences(of: "_", with: " ")
  }
}

struct IntakeSkillDedupe: Codable, Equatable, Sendable {
  var dayWindow = IntakeSkill.defaultDayWindow

  init() {}

  private enum CodingKeys: String, CodingKey {
    case dayWindow
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    dayWindow = IntakeSkill.clampedWindow(container.lenient(Int.self, forKey: .dayWindow) ?? IntakeSkill.defaultDayWindow)
  }
}

struct IntakeAccountSkill: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var notes: String
  var dedupeDayWindow: Int?

  init(id: String, notes: String = "", dedupeDayWindow: Int? = nil) {
    self.id = id
    self.notes = notes
    self.dedupeDayWindow = dedupeDayWindow
  }

  private enum CodingKeys: String, CodingKey {
    case id, notes, dedupeDayWindow
  }

  /// An entry without an ID cannot name an account, so it fails and is skipped.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    notes = String((container.lenient(String.self, forKey: .notes) ?? "").prefix(IntakeSkill.accountNotesLimit))
    dedupeDayWindow = container.lenient(Int.self, forKey: .dedupeDayWindow).map(IntakeSkill.clampedWindow)
  }
}

// MARK: Rules

enum IntakeAmountSign: String, Codable, Equatable, Sendable {
  case outflow
  case inflow
}

/// How far a rule reaches. The conditions in `when` decide what it matches;
/// the scope narrows it: an account scope only fires on that account, a payee
/// scope only on that payee.
enum IntakeRuleScope: Equatable, Sendable {
  case global
  case account(String)
  case payee(String)
}

extension IntakeRuleScope: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, value
  }

  /// A kind from a newer build throws, and the rule is skipped: a rule that
  /// cannot be understood must not run with a broader reach.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "global":
      self = .global
    case "account":
      self = .account(try container.decode(String.self, forKey: .value))
    case "payee":
      self = .payee(IntakeRuleCondition.normalisedToken(try container.decode(String.self, forKey: .value)))
    default:
      throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown rule scope")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .global:
      try container.encode("global", forKey: .kind)
    case .account(let id):
      try container.encode("account", forKey: .kind)
      try container.encode(id, forKey: .value)
    case .payee(let token):
      try container.encode("payee", forKey: .kind)
      try container.encode(token, forKey: .value)
    }
  }
}

struct IntakeRuleCondition: Codable, Equatable, Sendable {
  /// The merchant words of a payee, cleaned by `PayeeNames` and lowercase, joined
  /// by spaces. Empty (never nil) when the text given had no merchant word: such
  /// a rule matches nothing rather than everything.
  var payeeToken: String?
  var accountID: String?
  var amountSign: IntakeAmountSign?

  init(payeeToken: String? = nil, accountID: String? = nil, amountSign: IntakeAmountSign? = nil) {
    self.payeeToken = payeeToken.map(Self.normalisedToken)
    self.accountID = accountID
    self.amountSign = amountSign
  }

  private enum CodingKeys: String, CodingKey {
    case payeeToken, accountID, amountSign
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Strict: a payee, account or direction this build cannot read would broaden
    // the rule, so the rule is kept aside unread instead.
    payeeToken = try container.decodeIfPresent(String.self, forKey: .payeeToken).map(Self.normalisedToken)
    accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    amountSign = try container.decodeIfPresent(IntakeAmountSign.self, forKey: .amountSign)
  }

  static func normalisedToken(_ raw: String) -> String {
    PayeeNames.tokens(raw).joined(separator: " ")
  }

  /// The word a rule learned from `payee` should match: the first merchant word
  /// when it is distinctive (five letters or more: "KOPITIAM AMK" gives
  /// "kopitiam"), otherwise all of them ("Four Fingers" stays whole, so it does
  /// not also match "Four Seasons"). Nil when the name has no merchant word.
  static func suggestedToken(from payee: String) -> String? {
    let tokens = PayeeNames.tokens(payee)
    guard let first = tokens.first else {
      return nil
    }
    return first.count >= 5 ? first : tokens.joined(separator: " ")
  }
}

enum IntakeRuleAction: Equatable, Sendable {
  case setCategory(String)
  case renamePayee(String)
  case treatAsTransfer(String)
  /// Leaves the row as read and asks the owner to check it.
  case flag

  /// Rules of one family replace each other for the same match.
  var family: String {
    switch self {
    case .setCategory: "category"
    case .renamePayee: "rename"
    case .treatAsTransfer: "transfer"
    case .flag: "flag"
    }
  }
}

extension IntakeRuleAction: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "setCategory":
      self = .setCategory(try container.decode(String.self, forKey: .value))
    case "renamePayee":
      self = .renamePayee(try container.decode(String.self, forKey: .value))
    case "treatAsTransfer":
      self = .treatAsTransfer(try container.decode(String.self, forKey: .value))
    case "flag":
      self = .flag
    default:
      throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown rule action")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .setCategory(let id):
      try container.encode("setCategory", forKey: .kind)
      try container.encode(id, forKey: .value)
    case .renamePayee(let name):
      try container.encode("renamePayee", forKey: .kind)
      try container.encode(name, forKey: .value)
    case .treatAsTransfer(let id):
      try container.encode("treatAsTransfer", forKey: .kind)
      try container.encode(id, forKey: .value)
    case .flag:
      try container.encode("flag", forKey: .kind)
    }
  }
}

struct IntakeRuleOrigin: Codable, Equatable, Sendable {
  /// The batch the owner corrected, so the rule detail can link to it while it is still in the Inbox.
  var jobID: UUID?
  var decidedAt = Date()
  var note: String?
  /// How many corrections in that batch said the same thing.
  var corrections = 1

  init(jobID: UUID? = nil, decidedAt: Date = Date(), note: String? = nil, corrections: Int = 1) {
    self.jobID = jobID
    self.decidedAt = decidedAt
    self.note = note
    self.corrections = corrections
  }

  private enum CodingKeys: String, CodingKey {
    case jobID, decidedAt, note, corrections
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    jobID = container.lenient(UUID.self, forKey: .jobID)
    decidedAt = container.lenient(Date.self, forKey: .decidedAt) ?? Date(timeIntervalSince1970: 0)
    note = container.lenient(String.self, forKey: .note)
    corrections = max(container.lenient(Int.self, forKey: .corrections) ?? 1, 0)
  }
}

struct IntakeRule: Codable, Equatable, Identifiable, Sendable {
  /// Overridden this many times, a rule is flagged for removal. It is never removed or switched off for the owner.
  static let overrideWarningCount = 2

  var id = UUID()
  var scope: IntakeRuleScope
  var when: IntakeRuleCondition
  var then: IntakeRuleAction
  var origin = IntakeRuleOrigin()
  var hits = 0
  var overrides = 0
  var lastUsed: Date?
  var enabled = true
  var createdAt = Date()

  init(
    id: UUID = UUID(),
    scope: IntakeRuleScope,
    when: IntakeRuleCondition,
    then: IntakeRuleAction,
    origin: IntakeRuleOrigin = IntakeRuleOrigin(),
    hits: Int = 0,
    overrides: Int = 0,
    lastUsed: Date? = nil,
    enabled: Bool = true,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.scope = scope
    self.when = when
    self.then = then
    self.origin = origin
    self.hits = hits
    self.overrides = overrides
    self.lastUsed = lastUsed
    self.enabled = enabled
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, scope, when, then, origin, hits, overrides, lastUsed, enabled, createdAt
  }

  /// A rule whose ID, conditions, scope, action or enabled flag this build cannot
  /// read throws, and `IntakeSkill` keeps its raw JSON aside, unchanged.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    scope = try container.decode(IntakeRuleScope.self, forKey: .scope)
    when = try container.decode(IntakeRuleCondition.self, forKey: .when)
    then = try container.decode(IntakeRuleAction.self, forKey: .then)
    origin = container.lenient(IntakeRuleOrigin.self, forKey: .origin) ?? IntakeRuleOrigin()
    hits = max(container.lenient(Int.self, forKey: .hits) ?? 0, 0)
    overrides = max(container.lenient(Int.self, forKey: .overrides) ?? 0, 0)
    lastUsed = container.lenient(Date.self, forKey: .lastUsed)
    // Strict: an unreadable value must not switch a disabled rule back on.
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    createdAt = container.lenient(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
  }

  var isOverriddenTwice: Bool {
    overrides >= Self.overrideWarningCount
  }

  // MARK: Matching

  var payeeWords: String? {
    if let token = when.payeeToken {
      return token
    }
    if case .payee(let token) = scope {
      return token
    }
    return nil
  }

  /// The one account the rule is limited to, if any.
  var accountLimit: String? {
    if let id = when.accountID {
      return id
    }
    if case .account(let id) = scope {
      return id
    }
    return nil
  }

  /// How specific the rule is, for choosing between rules that both match:
  /// a payee word counts 4, an account limit 2, a direction 1. So payee + account
  /// (6) beats payee (4), which beats account + direction (3), which beats a
  /// direction alone (1). Equal rules go to the newest.
  var specificity: Int {
    (payeeWords != nil ? 4 : 0) + (accountLimit != nil ? 2 : 0) + (when.amountSign != nil ? 1 : 0)
  }

  /// Whether the rule's conditions hold for a line. A rule with no condition at
  /// all, or a payee word that cleaned to nothing, matches nothing. The payee
  /// word must appear among the line's merchant words as whole words, in order:
  /// "grab" does not match "GrabFood", and "kopitiam" matches "KOPITIAM AMK SG".
  func matches(_ draft: TransactionDraft) -> Bool {
    var hasCondition = false
    if let words = payeeWords {
      let phrase = words.split(separator: " ").map(String.init)
      guard !phrase.isEmpty, Self.contains(PayeeNames.tokens(draft.payeeName), phrase: phrase) else {
        return false
      }
      hasCondition = true
    }
    if let account = accountLimit {
      guard draft.accountID == account else {
        return false
      }
      if when.accountID != nil {
        hasCondition = true
      }
    }
    if let sign = when.amountSign {
      guard (sign == .outflow) == (draft.direction == .outflow) else {
        return false
      }
      hasCondition = true
    }
    return hasCondition
  }

  private static func contains(_ tokens: [String], phrase: [String]) -> Bool {
    guard !phrase.isEmpty, tokens.count >= phrase.count else {
      return false
    }
    for start in 0...(tokens.count - phrase.count) where Array(tokens[start..<(start + phrase.count)]) == phrase {
      return true
    }
    return false
  }

  /// A global rule with a payee is the same rule as a payee-scoped one.
  var normalisedScope: IntakeRuleScope {
    if case .global = scope, let token = when.payeeToken, !token.isEmpty {
      return .payee(token)
    }
    return scope
  }

  /// Whether the rule reaches lines on `accountID` (nil: every account).
  func covers(account accountID: String?) -> Bool {
    accountLimit == nil || accountLimit == accountID
  }

  // MARK: Words

  /// "KOPITIAM", or "Any outflow" for a direction-only rule.
  var matchText: String {
    if let words = payeeWords, !words.isEmpty {
      return words.uppercased()
    }
    if let sign = when.amountSign {
      return sign == .outflow ? "Any outflow" : "Any inflow"
    }
    return "Any payee"
  }

  func actionText(accountNames: [String: String], categoryNames: [String: String]) -> String {
    switch then {
    case .setCategory(let id): categoryNames[id] ?? "a category that is gone"
    case .renamePayee(let name): "renamed to \(name)"
    case .treatAsTransfer(let id): "transfer to \(accountNames[id] ?? "another account")"
    case .flag: "flagged for review"
    }
  }

  /// The same, for VoiceOver: no arrow. "KOPITIAM, set category Eating Out".
  func spokenSummary(accountNames: [String: String], categoryNames: [String: String]) -> String {
    let action: String
    switch then {
    case .setCategory(let id): action = "set category \(categoryNames[id] ?? "a category that is gone")"
    case .renamePayee(let name): action = "rename to \(name)"
    case .treatAsTransfer(let id): action = "treat as a transfer to \(accountNames[id] ?? "another account")"
    case .flag: action = "flag for review"
    }
    return "\(matchText), \(action)"
  }

  /// "KOPITIAM → Eating Out".
  func summary(accountNames: [String: String], categoryNames: [String: String]) -> String {
    "\(matchText) → \(actionText(accountNames: accountNames, categoryNames: categoryNames))"
  }

  /// "From 4 corrections · used 11 times".
  var provenance: String {
    let corrections = max(origin.corrections, 1)
    let from = "From \(corrections) \(corrections == 1 ? "correction" : "corrections")"
    switch hits {
    case 0: return "\(from) · not used yet"
    case 1: return "\(from) · used once"
    default: return "\(from) · used \(hits) times"
    }
  }
}

// MARK: Skill

struct IntakeSuppressedSuggestion: Codable, Equatable, Sendable {
  var key: String
  var until: Date
}

/// The skill file: structured settings code acts on, a bounded block of notes,
/// per-account overrides, and the learned rules. Stored on this device.
struct IntakeSkill: Codable, Equatable, Sendable {
  static let notesLimit = 4_000
  static let accountNotesLimit = 1_000
  /// The most guidance (global and account notes together) added to the reader's prompt.
  static let promptGuidanceLimit = 1_500
  static let defaultDayWindow = 3
  static let dayWindowRange = 1...7
  /// "Just this once" hides that exact suggestion for this long.
  static let suppressionDays = 30

  var version = 1
  var locale = IntakeSkillLocale()
  var dedupe = IntakeSkillDedupe()
  var notes = ""
  var accounts: [IntakeAccountSkill] = []
  var rules: [IntakeRule] = []
  var suppressed: [IntakeSuppressedSuggestion] = []
  /// Batches Remember this? has already been offered for: one offer per batch, ever.
  var offeredJobIDs: [UUID] = []
  /// Accounts and rules this build could not read, kept as raw JSON and written back unchanged.
  var unreadAccounts: [RawJSON] = []
  var unreadRules: [RawJSON] = []

  init() {}

  private enum CodingKeys: String, CodingKey {
    case version, locale, dedupe, notes, accounts, rules, suppressed, offeredJobs
  }

  /// Tolerant: anything this build cannot read falls back to its default, and a
  /// rule or account entry it cannot read is skipped, so the rest still loads.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = container.lenient(Int.self, forKey: .version) ?? 1
    locale = container.lenient(IntakeSkillLocale.self, forKey: .locale) ?? IntakeSkillLocale()
    dedupe = container.lenient(IntakeSkillDedupe.self, forKey: .dedupe) ?? IntakeSkillDedupe()
    notes = String((container.lenient(String.self, forKey: .notes) ?? "").prefix(Self.notesLimit))
    let readAccounts = try container.preservedArray(IntakeAccountSkill.self, forKey: .accounts)
    accounts = readAccounts.items
    unreadAccounts = readAccounts.unread
    let readRules = try container.preservedArray(IntakeRule.self, forKey: .rules)
    rules = readRules.items
    unreadRules = readRules.unread
    suppressed = container.lossyArray(IntakeSuppressedSuggestion.self, forKey: .suppressed)
    offeredJobIDs = container.lossyArray(UUID.self, forKey: .offeredJobs)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(locale, forKey: .locale)
    try container.encode(dedupe, forKey: .dedupe)
    try container.encode(notes, forKey: .notes)
    var accountsContainer = container.nestedUnkeyedContainer(forKey: .accounts)
    for account in accounts {
      try accountsContainer.encode(account)
    }
    for raw in unreadAccounts {
      try accountsContainer.encode(raw)
    }
    var rulesContainer = container.nestedUnkeyedContainer(forKey: .rules)
    for rule in rules {
      try rulesContainer.encode(rule)
    }
    for raw in unreadRules {
      try rulesContainer.encode(raw)
    }
    try container.encode(suppressed, forKey: .suppressed)
    try container.encode(offeredJobIDs, forKey: .offeredJobs)
  }

  static func clampedWindow(_ days: Int) -> Int {
    min(max(days, dayWindowRange.lowerBound), dayWindowRange.upperBound)
  }

  /// The duplicate window for a line on `accountID`: the account's own, else the global one.
  func dayWindow(forAccount accountID: String?) -> Int {
    if let accountID, let own = accounts.first(where: { $0.id == accountID })?.dedupeDayWindow {
      return Self.clampedWindow(own)
    }
    return Self.clampedWindow(dedupe.dayWindow)
  }

  func account(_ id: String) -> IntakeAccountSkill? {
    accounts.first { $0.id == id }
  }

  /// Sets an account's notes and window. An entry with neither is removed.
  mutating func setAccount(_ id: String, notes: String, dedupeDayWindow: Int?) {
    let trimmedNotes = String(notes.prefix(Self.accountNotesLimit))
    let isEmpty = trimmedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && dedupeDayWindow == nil
    accounts.removeAll { $0.id == id }
    if !isEmpty {
      accounts.append(IntakeAccountSkill(id: id, notes: trimmedNotes, dedupeDayWindow: dedupeDayWindow))
    }
  }

  /// "1.9k characters", or "No instructions yet". Currency and date order are
  /// stored but nothing reads them yet, so they are not shown.
  var summary: String {
    notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "No instructions yet"
      : Self.characterCount(notes.count)
  }

  static func characterCount(_ count: Int) -> String {
    if count < 1_000 {
      return "\(count) \(count == 1 ? "character" : "characters")"
    }
    return String(format: "%.1fk characters", Double(count) / 1_000)
  }

  // MARK: Reading guidance

  /// The owner's notes for the reader's prompt: the account's first, then the
  /// global notes, cut to `promptGuidanceLimit`. Nil when there are none. Only
  /// the Apple Intelligence reader sees it; the line parser reads no notes.
  func promptGuidance(accountID: String?) -> String? {
    var parts: [String] = []
    if let accountID, let own = account(accountID)?.notes.trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty {
      parts.append(own)
    }
    let global = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    if !global.isEmpty {
      parts.append(global)
    }
    guard !parts.isEmpty else {
      return nil
    }
    return String(parts.joined(separator: "\n\n").prefix(Self.promptGuidanceLimit))
  }

  // MARK: Rules

  /// Adds a rule. The newer owner choice supersedes the older: a rule with the
  /// same match, reach and kind of action is replaced (a global rule with a payee
  /// counts as a payee rule), and an all-accounts rule also replaces older
  /// account-limited rules for the same payee and kind of action.
  mutating func add(_ rule: IntakeRule) {
    let reach = rule.normalisedScope
    rules.removeAll { existing in
      guard existing.then.family == rule.then.family else {
        return false
      }
      if existing.when == rule.when, existing.normalisedScope == reach {
        return true
      }
      if rule.accountLimit == nil, let words = rule.payeeWords, !words.isEmpty,
         existing.accountLimit != nil, existing.payeeWords == words {
        return true
      }
      return false
    }
    rules.append(rule)
  }

  /// Notes that Remember this? has been offered for a batch. Only the latest are kept.
  mutating func markOffered(_ jobID: UUID) {
    guard !offeredJobIDs.contains(jobID) else {
      return
    }
    offeredJobIDs.append(jobID)
    if offeredJobIDs.count > 200 {
      offeredJobIDs.removeFirst(offeredJobIDs.count - 200)
    }
  }

  /// Counts one use of a rule that was approved. An override is the owner changing what the rule set.
  mutating func record(ruleID: UUID, overridden: Bool, at date: Date) {
    guard let index = rules.firstIndex(where: { $0.id == ruleID }) else {
      return
    }
    rules[index].hits += 1
    rules[index].lastUsed = date
    if overridden {
      rules[index].overrides += 1
    }
  }

  /// Removes every learned rule and every dismissed suggestion. The owner's own
  /// instructions stay.
  mutating func clearMemory() {
    rules = []
    suppressed = []
    offeredJobIDs = []
    unreadRules = []
  }

  func isSuppressed(_ key: String, at date: Date) -> Bool {
    suppressed.contains { $0.key == key && $0.until > date }
  }

  mutating func suppress(_ key: String, at date: Date) {
    let until = date.addingTimeInterval(Double(Self.suppressionDays) * 86_400)
    suppressed.removeAll { $0.key == key || $0.until <= date }
    suppressed.append(IntakeSuppressedSuggestion(key: key, until: until))
  }
}

// MARK: Applying rules to a line

struct IntakeTransferPayee: Equatable, Sendable {
  var id: String
  var name: String
}

/// What the engine needs to know about the register to apply a rule safely.
struct IntakeRuleContext: Equatable, Sendable {
  var openAccountIDs: Set<String> = []
  /// Categories that still exist.
  var categoryIDs: Set<String> = []
  var accountNames: [String: String] = [:]
  var categoryNames: [String: String] = [:]
  /// The transfer payee for each account, by the account it transfers to.
  var transferPayees: [String: IntakeTransferPayee] = [:]
  var onBudgetAccountIDs: Set<String> = []

  func summary(of rule: IntakeRule) -> String {
    rule.summary(accountNames: accountNames, categoryNames: categoryNames)
  }
}

enum IntakeRuleEffect: String, Codable, Equatable, Sendable {
  case category
  case payee
  case transfer
  /// The row was flagged for the owner to check.
  case review
}

/// A rule that fired on a proposal, kept so that approving can tell whether the
/// owner changed what it set.
struct IntakeRuleApplication: Codable, Equatable, Sendable {
  var ruleID: UUID
  var effects: [IntakeRuleEffect]

  init(ruleID: UUID, effects: [IntakeRuleEffect]) {
    self.ruleID = ruleID
    self.effects = effects
  }

  private enum CodingKeys: String, CodingKey {
    case ruleID, effects
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ruleID = try container.decode(UUID.self, forKey: .ruleID)
    // An effect from a newer build is dropped: it cannot be checked for an override.
    effects = container.lossyArray(IntakeRuleEffect.self, forKey: .effects)
  }
}

struct IntakeRuleOutcome: Equatable, Sendable {
  var application: IntakeRuleApplication
  /// "Learned rule: KOPITIAM → Eating Out (from 4 corrections)".
  var reason: String
  /// The rule asks the owner to check this row, so it is not ticked by default.
  var needsReview: Bool
}

enum IntakeRuleEngine {
  /// Every reason a rule adds starts with this.
  static let reasonPrefix = "Learned rule"
  static let notAppliedReason = "Learned rule not applied to a saved transaction"
  /// A row a "flag" rule asks the owner to check is Unsure, so it is not ticked.
  static let flaggedConfidenceCap = 0.5

  /// Most specific first; equally specific rules, newest first.
  static func ordered(_ rules: [IntakeRule]) -> [IntakeRule] {
    rules.sorted { lhs, rhs in
      if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  /// Applies the best enabled matching rule of each family to one line, most
  /// specific first, passing over a rule whose target is gone (a deleted category,
  /// a closed account). A transfer rule excludes category and rename rules;
  /// otherwise one category rule and one rename rule can both apply. A matching
  /// flag rule is always honoured. Matching looks at the line as read, so one
  /// rule's change never decides whether another matches. A category the reader
  /// already set is left alone, and so is any field in `skipping` (what the owner
  /// has edited). Counting a use is the caller's job.
  static func apply(
    _ rules: [IntakeRule],
    to read: inout SlipMappedDraft,
    context: IntakeRuleContext,
    skipping: Set<IntakeRuleEffect> = []
  ) -> [IntakeRuleOutcome] {
    let matching = ordered(rules).filter { $0.enabled && $0.matches(read.draft) }
    guard !matching.isEmpty else {
      return []
    }
    let original = read
    var working = read
    var outcomes: [IntakeRuleOutcome] = []

    func take(_ family: String, skipped: IntakeRuleEffect) -> Bool {
      guard !skipping.contains(skipped) else {
        return false
      }
      for rule in matching where rule.then.family == family {
        var attempt = working
        if let effect = perform(rule.then, on: &attempt, original: original, context: context) {
          working = attempt
          let corrections = max(rule.origin.corrections, 1)
          outcomes.append(
            IntakeRuleOutcome(
              application: IntakeRuleApplication(ruleID: rule.id, effects: [effect]),
              reason: "\(reasonPrefix): \(context.summary(of: rule)) (from \(corrections) \(corrections == 1 ? "correction" : "corrections"))",
              needsReview: effect == .review
            )
          )
          return true
        }
      }
      return false
    }

    if !take("transfer", skipped: .transfer) {
      _ = take("category", skipped: .category)
      _ = take("rename", skipped: .payee)
    }
    _ = take("flag", skipped: .review)
    read = working
    return outcomes
  }

  private static func perform(
    _ action: IntakeRuleAction,
    on read: inout SlipMappedDraft,
    original: SlipMappedDraft,
    context: IntakeRuleContext
  ) -> IntakeRuleEffect? {
    switch action {
    case .setCategory(let id):
      let readerSetCategory = original.parsedCategory && original.draft.categoryID != nil
      guard context.categoryIDs.contains(id), read.draft.transferAccountID == nil, !readerSetCategory else {
        return nil
      }
      read.draft.categoryID = id
      read.parsedCategory = true
      read.unrecognizedCategory = nil
      return .category
    case .renamePayee(let name):
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, read.draft.transferAccountID == nil else {
        return nil
      }
      read.draft.payeeName = trimmed
      read.draft.payeeID = nil
      return .payee
    case .treatAsTransfer(let target):
      guard context.openAccountIDs.contains(target),
            !read.draft.accountID.isEmpty,
            target != read.draft.accountID,
            let payee = context.transferPayees[target] else {
        return nil
      }
      read.draft.transferAccountID = target
      read.draft.payeeID = payee.id
      read.draft.payeeName = payee.name
      if context.onBudgetAccountIDs.contains(read.draft.accountID), context.onBudgetAccountIDs.contains(target) {
        read.draft.categoryID = nil
      }
      return .transfer
    case .flag:
      return .review
    }
  }

  /// Applies learned rules to proposals that were matched on the lines as read
  /// (`reads[i]` is the line behind `proposals[i]`). Only New and Possible
  /// duplicate rows take a rule's effects: a Fix or Already in row is about a
  /// saved transaction, which a rule never changes, so it only gets a note in Why.
  static func applyLearned(
    _ rules: [IntakeRule],
    to proposals: inout [IntakeProposal],
    reads: [SlipMappedDraft],
    context: IntakeRuleContext,
    skipping: Set<IntakeRuleEffect> = []
  ) {
    for index in proposals.indices where index < reads.count {
      var read = reads[index]
      read.draft = proposals[index].draft
      switch proposals[index].kind {
      case .add, .possibleDuplicate:
        let readPayee = read.draft.payeeName
        let outcomes = apply(rules, to: &read, context: context, skipping: skipping)
        guard !outcomes.isEmpty else {
          continue
        }
        proposals[index].draft = read.draft
        proposals[index].proposedDraft = read.draft
        proposals[index].readPayee = read.draft.payeeName == readPayee ? nil : readPayee
        proposals[index].ruleApplications = outcomes.map(\.application)
        proposals[index].reasons.insert(contentsOf: outcomes.map(\.reason), at: 0)
        if outcomes.contains(where: \.needsReview) {
          proposals[index].confidence = min(proposals[index].confidence, flaggedConfidenceCap)
        }
      case .edit, .alreadyIn:
        if !apply(rules, to: &read, context: context, skipping: skipping).isEmpty {
          proposals[index].reasons.insert(notAppliedReason, at: 0)
        }
      }
    }
  }

  /// Whether the owner changed something the rule set: the category, the payee
  /// name, or the transfer. Compared on what was proposed against what is saved.
  static func wasOverridden(
    _ application: IntakeRuleApplication,
    proposed: TransactionDraft,
    final: TransactionDraft
  ) -> Bool {
    application.effects.contains { effect in
      switch effect {
      case .category:
        return final.categoryID != proposed.categoryID
      case .payee:
        return final.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
          != proposed.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
      case .transfer:
        return final.transferAccountID != proposed.transferAccountID
      case .review:
        return false
      }
    }
  }
}

// MARK: Remember this?

enum IntakeRuleScopeChoice: String, CaseIterable, Identifiable, Equatable, Sendable {
  case global
  case account
  case payee

  var id: String { rawValue }
}

struct IntakeRuleTrackRecord: Equatable, Sendable {
  var ruleID: UUID
  /// Times it fired in this batch and was left alone.
  var count: Int
}

/// One rule to offer after an approval, never more.
struct IntakeRuleSuggestion: Equatable, Identifiable, Sendable {
  var id = UUID()
  /// What "Just this once" suppresses.
  var key: String
  var token: String
  var action: IntakeRuleAction
  /// The one account the batch was for, when it was for just one.
  var accountID: String?
  var jobID: UUID
  var corrections: Int
  var decidedAt: Date
  var alsoNoticed: IntakeRuleTrackRecord?

  /// The batch's own account when it had one ("DBS Altitude only"), else this payee.
  var defaultScope: IntakeRuleScopeChoice {
    accountID == nil ? .payee : .account
  }

  /// The rule this suggestion becomes under a scope. An account scope needs the batch's account.
  func rule(scope choice: IntakeRuleScopeChoice) -> IntakeRule {
    let scope: IntakeRuleScope
    var condition = IntakeRuleCondition(payeeToken: token)
    switch choice {
    case .account where accountID != nil:
      scope = .account(accountID ?? "")
      condition.accountID = accountID
    case .global:
      scope = .global
    default:
      scope = .payee(token)
    }
    return IntakeRule(
      id: id,
      scope: scope,
      when: condition,
      then: action,
      origin: IntakeRuleOrigin(jobID: jobID, decidedAt: decidedAt, corrections: corrections),
      createdAt: decidedAt
    )
  }
}

enum IntakeRuleSuggester {
  private struct Candidate {
    var key: String
    var token: String
    var action: IntakeRuleAction
    /// A category correction outranks a rename.
    var rank: Int
    var count: Int
    var firstIndex: Int
  }

  /// The strongest generalisation of what the owner changed in `applied` (the
  /// rows that were just approved), or nil. A candidate is a category chosen
  /// for a payee the reader or a rule left otherwise, or a payee renamed to a
  /// cleaner name for the same merchant. The one corrected most often wins;
  /// ties go to a category, then to the earlier row. Nothing is offered for a
  /// batch already offered one, for a rule that already exists for this account
  /// (on or off), or one the owner dismissed within 30 days. No category rule is
  /// offered for a row in `readerCategoryRows` (the document itself named the
  /// category): the engine never replaces that, so the rule would never apply.
  static func suggest(
    applied: [IntakeProposal],
    jobID: UUID,
    skill: IntakeSkill,
    now: Date = Date(),
    readerCategoryRows: Set<UUID> = []
  ) -> IntakeRuleSuggestion? {
    guard !skill.offeredJobIDs.contains(jobID) else {
      return nil
    }
    let rows = applied.filter { $0.isApplied && $0.decision != .rejected && $0.kind != .alreadyIn }
    let accounts = Set(rows.map(\.draft.accountID).filter { !$0.isEmpty })
    let accountID = accounts.count == 1 ? accounts.first : nil
    var candidates: [String: Candidate] = [:]
    for (index, row) in rows.enumerated() where row.draft.transferAccountID == nil {
      // The token comes from what the reader saw, before any rename rule, so the
      // learned rule can match the raw descriptors of future documents.
      let proposedName = row.proposedDraft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
      let rawName = row.readPayee ?? proposedName
      guard let token = IntakeRuleCondition.suggestedToken(from: rawName) else {
        continue
      }
      if let category = row.draft.categoryID, category != row.proposedDraft.categoryID,
         !readerCategoryRows.contains(row.id) {
        add(
          Candidate(
            key: "category|\(token)|\(category)", token: token, action: .setCategory(category),
            rank: 2, count: 1, firstIndex: index
          ),
          to: &candidates
        )
      }
      let renamed = row.draft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
      // A rename to another name for the same merchant generalises; a rename to
      // something unrelated ("Dinner with Ann") does not.
      if !renamed.isEmpty, renamed != proposedName,
         !Set(PayeeNames.tokens(renamed)).isDisjoint(with: PayeeNames.tokens(rawName)) {
        add(
          Candidate(
            key: "rename|\(token)|\(renamed)", token: token, action: .renamePayee(renamed),
            rank: 1, count: 1, firstIndex: index
          ),
          to: &candidates
        )
      }
    }

    let usable = candidates.values.filter { candidate in
      !skill.isSuppressed(candidate.key, at: now)
        && !skill.rules.contains {
          $0.payeeWords == candidate.token && $0.then == candidate.action && $0.covers(account: accountID)
        }
    }
    let best = usable.min { lhs, rhs in
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
      return lhs.firstIndex < rhs.firstIndex
    }
    guard let best else {
      return nil
    }

    return IntakeRuleSuggestion(
      key: best.key,
      token: best.token,
      action: best.action,
      accountID: accountID,
      jobID: jobID,
      corrections: best.count,
      decidedAt: now,
      alsoNoticed: alsoNoticed(in: rows, skill: skill)
    )
  }

  private static func add(_ candidate: Candidate, to candidates: inout [String: Candidate]) {
    if var existing = candidates[candidate.key] {
      existing.count += 1
      candidates[candidate.key] = existing
    } else {
      candidates[candidate.key] = candidate
    }
  }

  /// The existing rule that fired most in this batch and was left alone.
  private static func alsoNoticed(in rows: [IntakeProposal], skill: IntakeSkill) -> IntakeRuleTrackRecord? {
    var counts: [UUID: Int] = [:]
    var order: [UUID] = []
    for row in rows {
      for application in row.ruleApplications
      where !IntakeRuleEngine.wasOverridden(application, proposed: row.proposedDraft, final: row.draft)
        && skill.rules.contains(where: { $0.id == application.ruleID && $0.enabled }) {
        if counts[application.ruleID] == nil {
          order.append(application.ruleID)
        }
        counts[application.ruleID, default: 0] += 1
      }
    }
    guard let top = order.max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }), let count = counts[top] else {
      return nil
    }
    return IntakeRuleTrackRecord(ruleID: top, count: count)
  }
}

// MARK: Store

/// Persists the skill file at `{appGroup}/Intake/skill.json`, written atomically.
/// Main app only. Under the unit-test host the container is the same isolated
/// temporary one `IntakeJobStore` uses, so tests never read a simulator's real skill.
@MainActor
@Observable
final class IntakeSkillStore {
  static let shared = IntakeSkillStore(container: IntakeJobStore.sharedContainer)

  private nonisolated static let logger = Logger(subsystem: "sg.soon.howmuch", category: "IntakeSkillStore")

  private(set) var skill: IntakeSkill
  /// The file exists but could not be read. Saving would overwrite it, so it is refused.
  /// A file that failed to decode stays this way for the process; one that failed to
  /// be read at all (a launch before first unlock) is tried again on the next save.
  private(set) var isReadOnly = false
  @ObservationIgnored private var needsReload = false

  @ObservationIgnored private let fileURL: URL

  init(container: URL) {
    let url = container
      .appendingPathComponent("Intake", isDirectory: true)
      .appendingPathComponent("skill.json")
    fileURL = url
    let loaded = Self.load(url)
    skill = loaded.skill
    isReadOnly = loaded.failed || loaded.unreadable
    needsReload = loaded.unreadable
  }

  /// Tries a file that could not be read again, for as long as the failure was an
  /// I/O error rather than a bad file.
  private func reloadIfNeeded() {
    guard needsReload else {
      return
    }
    let loaded = Self.load(fileURL)
    skill = loaded.skill
    isReadOnly = loaded.failed || loaded.unreadable
    needsReload = loaded.unreadable
  }

  /// What to tell the owner when a save fails. A file that could not be read is
  /// tried again on the next save; one that does not decode is kept, never
  /// cleared, in case a newer Halation wrote it.
  func saveFailureMessage(_ fallback: String) -> String {
    guard isReadOnly else {
      return fallback
    }
    return needsReload
      ? "Couldn’t read your skill file. Changes weren’t saved. Try again."
      : "Couldn’t read your skill file, so changes weren’t saved. If you recently went back to an older Halation, update it."
  }

  nonisolated static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private nonisolated static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  /// A missing file is a fresh start. A file that exists but cannot be read or
  /// decoded gives the default skill and `failed`, so it is never overwritten. A
  /// read error (permission, before first unlock) is `unreadable`: also never
  /// overwritten, but worth trying again.
  private nonisolated static func load(
    _ url: URL
  ) -> (skill: IntakeSkill, failed: Bool, unreadable: Bool) {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return (IntakeSkill(), false, false)
    }
    guard let data = try? Data(contentsOf: url) else {
      logger.error("Couldn't read the skill file; will try again")
      return (IntakeSkill(), false, true)
    }
    guard let skill = try? decoder().decode(IntakeSkill.self, from: data) else {
      logger.error("Couldn't decode the skill file; leaving it as it is")
      return (IntakeSkill(), true, false)
    }
    return (skill, false, false)
  }

  /// Applies `change` and saves. A failed save leaves the skill as it was and returns false.
  @discardableResult
  func update(_ change: (inout IntakeSkill) -> Void) -> Bool {
    reloadIfNeeded()
    guard !isReadOnly else {
      Self.logger.error("Refusing to save over a skill file that could not be read")
      return false
    }
    var next = skill
    change(&next)
    guard next != skill else {
      return true
    }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try Self.encoder().encode(next).write(to: fileURL, options: .atomic)
    } catch {
      Self.logger.error("Couldn't save the skill file: \(error.localizedDescription, privacy: .public)")
      return false
    }
    skill = next
    return true
  }

  @discardableResult
  func add(_ rule: IntakeRule) -> Bool {
    update { $0.add(rule) }
  }

  @discardableResult
  func setEnabled(_ enabled: Bool, rule id: UUID) -> Bool {
    update { skill in
      if let index = skill.rules.firstIndex(where: { $0.id == id }) {
        skill.rules[index].enabled = enabled
      }
    }
  }

  /// Saves an edited rule, keeping its counts and creation date.
  @discardableResult
  func replace(_ rule: IntakeRule) -> Bool {
    update { skill in
      if let index = skill.rules.firstIndex(where: { $0.id == rule.id }) {
        skill.rules[index] = rule
      }
    }
  }

  @discardableResult
  func delete(rule id: UUID) -> Bool {
    update { $0.rules.removeAll { $0.id == id } }
  }

  func markOffered(_ jobID: UUID) {
    update { $0.markOffered(jobID) }
  }

  @discardableResult
  func suppress(_ key: String, at date: Date = Date()) -> Bool {
    update { $0.suppress(key, at: date) }
  }

  @discardableResult
  func clearMemory() -> Bool {
    update { $0.clearMemory() }
  }

  /// Counts approved rule uses: a hit for each, and an override where the owner changed what it set.
  func record(_ outcomes: [(ruleID: UUID, overridden: Bool)], at date: Date = Date()) {
    guard !outcomes.isEmpty else {
      return
    }
    update { skill in
      for outcome in outcomes {
        skill.record(ruleID: outcome.ruleID, overridden: outcome.overridden, at: date)
      }
    }
  }
}

// MARK: Matcher

extension IntakeMatcher {
  /// A matcher with the skill's duplicate windows: the global one, and each
  /// account's own where it has one.
  init(skill: IntakeSkill) {
    var windows: [String: Int] = [:]
    for account in skill.accounts {
      if let own = account.dedupeDayWindow {
        windows[account.id] = IntakeSkill.clampedWindow(own)
      }
    }
    self.init(dayWindow: skill.dayWindow(forAccount: nil), accountDayWindows: windows)
  }
}
