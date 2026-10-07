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

private extension KeyedDecodingContainer {
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
    dedupeDayWindow = container.lenient(Int.self, forKey: .dedupeDayWindow)
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
    payeeToken = container.lenient(String.self, forKey: .payeeToken).map(Self.normalisedToken)
    accountID = container.lenient(String.self, forKey: .accountID)
    // Strict: a direction this build cannot read would broaden the rule, so the rule is skipped.
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

  /// A rule whose ID, scope or action this build cannot read throws, and
  /// `IntakeSkill` skips it.
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
    enabled = container.lenient(Bool.self, forKey: .enabled) ?? true
    createdAt = container.lenient(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
  }

  var isOverriddenTwice: Bool {
    overrides >= Self.overrideWarningCount
  }

  // MARK: Matching

  private var payeeWords: String? {
    if let token = when.payeeToken {
      return token
    }
    if case .payee(let token) = scope {
      return token
    }
    return nil
  }

  private var accountLimit: String? {
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

  init() {}

  private enum CodingKeys: String, CodingKey {
    case version, locale, dedupe, notes, accounts, rules, suppressed
  }

  /// Tolerant: anything this build cannot read falls back to its default, and a
  /// rule or account entry it cannot read is skipped, so the rest still loads.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = container.lenient(Int.self, forKey: .version) ?? 1
    locale = container.lenient(IntakeSkillLocale.self, forKey: .locale) ?? IntakeSkillLocale()
    dedupe = container.lenient(IntakeSkillDedupe.self, forKey: .dedupe) ?? IntakeSkillDedupe()
    notes = String((container.lenient(String.self, forKey: .notes) ?? "").prefix(Self.notesLimit))
    accounts = container.lossyArray(IntakeAccountSkill.self, forKey: .accounts)
    rules = container.lossyArray(IntakeRule.self, forKey: .rules)
    suppressed = container.lossyArray(IntakeSuppressedSuggestion.self, forKey: .suppressed)
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

  /// "SGD, Singapore · 1.9k characters".
  var summary: String {
    "\(locale.currency), \(locale.place) · \(Self.characterCount(notes.count))"
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

  /// Adds a rule, replacing any rule with the same match, scope and kind of
  /// action: the newer correction supersedes the older.
  mutating func add(_ rule: IntakeRule) {
    rules.removeAll { $0.when == rule.when && $0.scope == rule.scope && $0.then.family == rule.then.family }
    rules.append(rule)
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
  /// Most specific first; equally specific rules, newest first.
  static func ordered(_ rules: [IntakeRule]) -> [IntakeRule] {
    rules.sorted { lhs, rhs in
      if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  /// Applies the first enabled rule that matches the line and can be carried out
  /// (most specific first), and only that one. A rule whose target is gone (a
  /// deleted category, a closed account) is passed over for the next. Returns nil,
  /// leaving the line alone, when none applies. Counting a use is the caller's job.
  static func apply(
    _ rules: [IntakeRule],
    to read: inout SlipMappedDraft,
    context: IntakeRuleContext
  ) -> IntakeRuleOutcome? {
    for rule in ordered(rules) where rule.enabled && rule.matches(read.draft) {
      var attempt = read
      guard let effect = perform(rule.then, on: &attempt, context: context) else {
        continue
      }
      read = attempt
      let corrections = max(rule.origin.corrections, 1)
      return IntakeRuleOutcome(
        application: IntakeRuleApplication(ruleID: rule.id, effects: [effect]),
        reason: "Learned rule: \(context.summary(of: rule)) (from \(corrections) \(corrections == 1 ? "correction" : "corrections"))",
        needsReview: effect == .review
      )
    }
    return nil
  }

  private static func perform(
    _ action: IntakeRuleAction,
    on read: inout SlipMappedDraft,
    context: IntakeRuleContext
  ) -> IntakeRuleEffect? {
    switch action {
    case .setCategory(let id):
      guard context.categoryIDs.contains(id), read.draft.transferAccountID == nil else {
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
  /// rule that already exists (on or off) or that the owner dismissed within
  /// 30 days.
  static func suggest(
    applied: [IntakeProposal],
    jobID: UUID,
    skill: IntakeSkill,
    now: Date = Date()
  ) -> IntakeRuleSuggestion? {
    let rows = applied.filter { $0.isApplied && $0.decision != .rejected && $0.kind != .alreadyIn }
    var candidates: [String: Candidate] = [:]
    for (index, row) in rows.enumerated() where row.draft.transferAccountID == nil {
      guard let token = IntakeRuleCondition.suggestedToken(from: row.proposedDraft.payeeName) else {
        continue
      }
      if let category = row.draft.categoryID, category != row.proposedDraft.categoryID {
        add(
          Candidate(
            key: "category|\(token)|\(category)", token: token, action: .setCategory(category),
            rank: 2, count: 1, firstIndex: index
          ),
          to: &candidates
        )
      }
      let renamed = row.draft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
      let read = row.proposedDraft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
      // A rename to another name for the same merchant generalises; a rename to
      // something unrelated ("Dinner with Ann") does not.
      if !renamed.isEmpty, renamed != read,
         !Set(PayeeNames.tokens(renamed)).isDisjoint(with: PayeeNames.tokens(read)) {
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
        && !skill.rules.contains { $0.when.payeeToken == candidate.token && $0.then == candidate.action }
    }
    let best = usable.min { lhs, rhs in
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
      return lhs.firstIndex < rhs.firstIndex
    }
    guard let best else {
      return nil
    }

    let accounts = Set(rows.map(\.draft.accountID).filter { !$0.isEmpty })
    return IntakeRuleSuggestion(
      key: best.key,
      token: best.token,
      action: best.action,
      accountID: accounts.count == 1 ? accounts.first : nil,
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

  private static let logger = Logger(subsystem: "sg.soon.howmuch", category: "IntakeSkillStore")

  private(set) var skill: IntakeSkill

  @ObservationIgnored private let fileURL: URL

  init(container: URL) {
    let url = container
      .appendingPathComponent("Intake", isDirectory: true)
      .appendingPathComponent("skill.json")
    fileURL = url
    skill = Self.load(url)
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

  private nonisolated static func load(_ url: URL) -> IntakeSkill {
    guard let data = try? Data(contentsOf: url),
          let skill = try? decoder().decode(IntakeSkill.self, from: data) else {
      return IntakeSkill()
    }
    return skill
  }

  /// Applies `change` and saves. A failed save leaves the skill as it was and returns false.
  @discardableResult
  func update(_ change: (inout IntakeSkill) -> Void) -> Bool {
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
