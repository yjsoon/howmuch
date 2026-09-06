import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum ComposeIntelligence {
  static var showsField: Bool {
    #if canImport(FoundationModels)
    switch SystemLanguageModel.default.availability {
    case .available:
      return true
    case .unavailable(let reason):
      if case .modelNotReady = reason {
        return true
      }
      return false
    @unknown default:
      return true
    }
    #else
    return true
    #endif
  }
}

struct SlipCandidate: Equatable, Identifiable, Sendable {
  let id: String
  let name: String
}

enum SlipAccountPick {
  static func apply(_ accountID: String, to draft: inout TransactionDraft) {
    draft.accountID = accountID
    if draft.transferAccountID == accountID {
      draft.transferAccountID = nil
      draft.payeeID = nil
      draft.payeeName = ""
    }
  }
}

struct SlipMappedDraft: Equatable, Sendable {
  var draft: TransactionDraft
  var parsedAmount: Bool
  var parsedDate: Bool
  var parsedAccount: Bool
  var parsedInflow: Bool
  var accountCandidates: [SlipCandidate]
  var categoryCandidates: [SlipCandidate]
}

enum ComposeParseApply {
  struct Outcome: Equatable {
    var draft: TransactionDraft
    var accountCandidates: [SlipCandidate]
    var categoryCandidates: [SlipCandidate]
    var showAccountPrompt: Bool
    var showCategoryPrompt: Bool
  }

  static func applying(_ row: SlipMappedDraft, to draft: TransactionDraft) -> Outcome {
    var next = draft
    if row.parsedAmount {
      next.amountMagnitudeMilli = row.draft.amountMagnitudeMilli
    }
    if row.parsedInflow {
      next.direction = .inflow
    }
    if row.parsedDate {
      next.date = row.draft.date
    }
    if !row.draft.payeeName.isEmpty || row.draft.payeeID != nil {
      next.payeeID = row.draft.payeeID
      next.payeeName = row.draft.payeeName
      next.transferAccountID = row.draft.transferAccountID
    }

    var showCategoryPrompt = false
    if let categoryID = row.draft.categoryID {
      next.categoryID = categoryID
    } else if !row.categoryCandidates.isEmpty {
      showCategoryPrompt = true
      next.categoryID = nil
    }

    var showAccountPrompt = false
    if row.parsedAccount, !row.draft.accountID.isEmpty {
      next.accountID = row.draft.accountID
    } else if row.parsedAccount, !row.accountCandidates.isEmpty {
      showAccountPrompt = true
      next.accountID = ""
    }

    return Outcome(
      draft: next,
      accountCandidates: row.accountCandidates,
      categoryCandidates: row.categoryCandidates,
      showAccountPrompt: showAccountPrompt,
      showCategoryPrompt: showCategoryPrompt
    )
  }
}

enum SlipReaderMapping {
  struct Extraction: Equatable, Sendable {
    var amount = ""
    var payee = ""
    var category = ""
    var account = ""
    var date = ""
    var isInflow = false

    var isBlank: Bool {
      amount.isEmpty && payee.isEmpty && category.isEmpty && account.isEmpty && date.isEmpty
    }
  }

  static func map(
    _ extractions: [Extraction],
    sentence: String = "",
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee],
    calendar: Calendar,
    now: Date
  ) -> [SlipMappedDraft] {
    extractions.compactMap { extraction in
      guard !extraction.isBlank else {
        return nil
      }
      return mapOne(
        extraction,
        sentence: sentence,
        accounts: accounts,
        categoryGroups: categoryGroups,
        payees: payees,
        calendar: calendar,
        now: now
      )
    }
  }

  static func date(from raw: String, calendar: Calendar, now: Date) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let today = calendar.startOfDay(for: now)
    let normalized = stripDateLeadIn(trimmed)
    if let named = namedDay(normalized, calendar: calendar, today: today) {
      return named
    }
    if let relative = relativeWeekday(normalized, calendar: calendar, today: today) {
      return relative
    }
    return formattedDay(normalized, calendar: calendar, now: today)
  }

  private static func mapOne(
    _ extraction: Extraction,
    sentence: String,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee],
    calendar: Calendar,
    now: Date
  ) -> SlipMappedDraft {
    var draft = TransactionDraft()
    draft.direction = extraction.isInflow ? .inflow : .outflow

    var parsedAmount = false
    if !extraction.amount.isEmpty, let milli = MoneyCodec.milliunits(fromExtraction: extraction.amount) {
      draft.amountMagnitudeMilli = abs(milli)
      parsedAmount = true
    }

    var parsedDate = false
    if let parsed = Self.date(from: extraction.date, calendar: calendar, now: now) {
      draft.date = parsed
      parsedDate = true
    }

    var accountCandidates: [SlipCandidate] = []
    let accountQuery = extraction.account.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsedAccount = !accountQuery.isEmpty && mentions(accountQuery, in: sentence)
    if parsedAccount {
      let matches = matchAccounts(accountQuery, in: accounts)
      if matches.count == 1 {
        draft.accountID = matches[0].id
      } else if (2...3).contains(matches.count) {
        accountCandidates = matches.map { SlipCandidate(id: $0.id, name: $0.name) }
      }
    }

    var categoryCandidates: [SlipCandidate] = []
    if !extraction.category.isEmpty {
      let matches = matchCategories(extraction.category, in: categoryGroups)
      if matches.count == 1 {
        draft.categoryID = matches[0].id
      } else if (2...3).contains(matches.count) {
        categoryCandidates = matches.map { SlipCandidate(id: $0.id, name: $0.name) }
      }
    }

    if !extraction.payee.isEmpty {
      applyPayee(
        extraction.payee,
        to: &draft,
        payees: payees,
        accounts: accounts
      )
    }

    return SlipMappedDraft(
      draft: draft,
      parsedAmount: parsedAmount,
      parsedDate: parsedDate,
      parsedAccount: parsedAccount,
      parsedInflow: extraction.isInflow,
      accountCandidates: accountCandidates,
      categoryCandidates: categoryCandidates
    )
  }

  private static func matchAccounts(_ query: String, in accounts: [Account]) -> [Account] {
    let open = accounts.filter { !$0.closed && !$0.deleted }
    let exact = open.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    if !exact.isEmpty {
      return exact
    }
    return open.filter { $0.name.localizedStandardContains(query) }
  }

  private static func matchCategories(_ query: String, in groups: [CategoryGroup]) -> [Category] {
    let live = groups.filter { !$0.deleted }.flatMap { group in
      group.categories.filter { !$0.deleted }
    }
    let exact = live.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    if !exact.isEmpty {
      return exact
    }
    return live.filter { $0.name.localizedStandardContains(query) }
  }

  private static func applyPayee(
    _ query: String,
    to draft: inout TransactionDraft,
    payees: [Payee],
    accounts: [Account]
  ) {
    draft.payeeName = query
    let live = payees.filter { $0.deleted != true }
    let exact = live.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    let matches = exact.isEmpty
      ? live.filter { $0.name.localizedStandardContains(query) }
      : exact
    guard matches.count == 1 else {
      return
    }
    let payee = matches[0]
    if let target = payee.transferAccountId {
      guard let destination = accounts.first(where: { $0.id == target && !$0.closed && !$0.deleted }) else {
        return
      }
      if destination.id == draft.accountID {
        draft.payeeID = nil
        draft.payeeName = ""
        draft.transferAccountID = nil
        return
      }
      draft.payeeID = payee.id
      draft.payeeName = payee.name
      draft.transferAccountID = target
      if bothOnBudget(draft.accountID, target, accounts: accounts) {
        draft.categoryID = nil
      }
      return
    }
    draft.payeeID = payee.id
    draft.payeeName = payee.name
    draft.transferAccountID = nil
  }

  private static func bothOnBudget(_ fromID: String, _ toID: String, accounts: [Account]) -> Bool {
    guard
      let from = accounts.first(where: { $0.id == fromID }),
      let to = accounts.first(where: { $0.id == toID })
    else {
      return false
    }
    return from.onBudget && to.onBudget
  }

  private static func mentions(_ needle: String, in sentence: String) -> Bool {
    let query = needle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return false
    }
    if sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return true
    }
    return sentence.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  private static func stripDateLeadIn(_ raw: String) -> String {
    raw.replacingOccurrences(
      of: #"^(?i)(?:(?:scheduled|on|for|due)(?:\s+the)?\s+)+"#,
      with: "",
      options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func namedDay(_ raw: String, calendar: Calendar, today: Date) -> Date? {
    if raw.caseInsensitiveCompare("today") == .orderedSame {
      return today
    }
    if raw.caseInsensitiveCompare("yesterday") == .orderedSame {
      return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }
    return nil
  }

  private static func relativeWeekday(_ raw: String, calendar: Calendar, today: Date) -> Date? {
    let lower = raw.lowercased()
    guard lower.hasPrefix("next ") else {
      return nil
    }
    let name = lower.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
    let weekdays = [
      "sunday": 1,
      "monday": 2,
      "tuesday": 3,
      "wednesday": 4,
      "thursday": 5,
      "friday": 6,
      "saturday": 7,
    ]
    guard let weekday = weekdays[name] else {
      return nil
    }
    var cursor = today
    for _ in 1...7 {
      guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
        return nil
      }
      cursor = calendar.startOfDay(for: next)
      if calendar.component(.weekday, from: cursor) == weekday {
        return cursor
      }
    }
    return nil
  }

  private static func formattedDay(_ raw: String, calendar: Calendar, now: Date) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.isLenient = false
    formatter.defaultDate = now
    let formats = [
      "yyyy-MM-dd",
      "d MMMM yyyy",
      "d MMM yyyy",
      "MMMM d yyyy",
      "MMM d yyyy",
      "d MMMM",
      "d MMM",
      "MMMM d",
      "MMM d",
      "d/M/yyyy",
      "d/M",
    ]
    for format in formats {
      formatter.dateFormat = format
      if let parsed = formatter.date(from: raw) {
        return calendar.startOfDay(for: parsed)
      }
    }
    return nil
  }
}

enum SlipReaderPrompt {
  static let instructions = """
  Extract every distinct spend from the sentence. Amount is the numeric figure even when the sentence uses $, S$, SGD, USD, or the word dollars. Write it as a decimal string such as 5 or 5.00, never milliunits and never IDs. Payee is a name from the sentence. Copy a category name from the provided list only when the sentence names that category. Leave account empty unless the sentence explicitly names an account. Do not pick an account from the list just because it is there. Leave a field empty when it was not mentioned. Fill date when the sentence names a day to post or schedule, including today, yesterday, 8 Sep, 15 September, 8/9, next Friday, or yyyy-MM-dd. Split two spends in one sentence into two items. Return spends. Each spend has amount, payee, category, account, date, and isInflow (true only when money is received).
  """

  static func prefix(
    accounts: [Account],
    categoryGroups: [CategoryGroup]
  ) -> String {
    let accountNames = accounts.filter { !$0.closed && !$0.deleted }.map(\.name)
    let categoryNames = categoryGroups.filter { !$0.deleted }.flatMap { group in
      group.categories.filter { !$0.deleted }.map(\.name)
    }
    return """
    Accounts: \(accountNames.joined(separator: ", "))
    Categories: \(categoryNames.joined(separator: ", "))

    Sentence:

    """
  }
}

actor SlipReader {
  enum Extractor: Sendable {
    case foundationModels
    case fixed(@Sendable (String) -> [SlipReaderMapping.Extraction])
  }

  static let shared = SlipReader()

  private let extractor: Extractor
  #if canImport(FoundationModels)
  private var primedPrefix: String?
  private var primedSession: LanguageModelSession?
  private var isExtracting = false
  #endif

  init(extractor: Extractor = .foundationModels) {
    self.extractor = extractor
  }

  func prewarm(
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee]
  ) {
    guard case .foundationModels = extractor else {
      return
    }
    #if canImport(FoundationModels)
    guard !isExtracting, Self.modelAllowsExtract else {
      return
    }
    let prefix = SlipReaderPrompt.prefix(
      accounts: accounts,
      categoryGroups: categoryGroups
    )
    if primedPrefix == prefix, let session = primedSession {
      session.prewarm(promptPrefix: Prompt(prefix))
      return
    }
    startPrime(prefix)
    #endif
  }

  func read(
    text: String,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee],
    calendar: Calendar = .current,
    now: Date = .now
  ) async -> [TransactionDraft] {
    await interpret(
      text: text,
      accounts: accounts,
      categoryGroups: categoryGroups,
      payees: payees,
      calendar: calendar,
      now: now
    ).map(\.draft)
  }

  func interpret(
    text: String,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee],
    calendar: Calendar = .current,
    now: Date = .now
  ) async -> [SlipMappedDraft] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return []
    }
    let extractions: [SlipReaderMapping.Extraction]
    switch extractor {
    case .foundationModels:
      extractions = await extractWithModel(
        text: trimmed,
        accounts: accounts,
        categoryGroups: categoryGroups,
        payees: payees
      )
    case .fixed(let extract):
      extractions = extract(trimmed)
    }
    return SlipReaderMapping.map(
      extractions,
      sentence: trimmed,
      accounts: accounts,
      categoryGroups: categoryGroups,
      payees: payees,
      calendar: calendar,
      now: now
    )
  }

  private func extractWithModel(
    text: String,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee]
  ) async -> [SlipReaderMapping.Extraction] {
    #if canImport(FoundationModels)
    guard Self.modelAllowsExtract else {
      return []
    }

    let prefix = SlipReaderPrompt.prefix(
      accounts: accounts,
      categoryGroups: categoryGroups
    )
    let session: LanguageModelSession
    if primedPrefix == prefix, let primedSession {
      session = primedSession
      self.primedSession = nil
      primedPrefix = nil
    } else {
      session = LanguageModelSession(instructions: SlipReaderPrompt.instructions)
    }
    isExtracting = true
    defer {
      isExtracting = false
      startPrime(prefix)
    }
    let prompt = prefix + text
    do {
      let response = try await session.respond(
        to: prompt,
        generating: ExtractedSlips.self,
        includeSchemaInPrompt: false,
        options: GenerationOptions(sampling: .greedy)
      )
      return response.content.spends.map { slip in
        SlipReaderMapping.Extraction(
          amount: slip.amount,
          payee: slip.payee,
          category: slip.category,
          account: slip.account,
          date: slip.date,
          isInflow: slip.isInflow
        )
      }
    } catch {
      return []
    }
    #else
    return []
    #endif
  }

  #if canImport(FoundationModels)
  private static var modelAllowsExtract: Bool {
    switch SystemLanguageModel.default.availability {
    case .unavailable(let reason):
      if case .modelNotReady = reason {
        return true
      }
      return false
    case .available:
      return true
    @unknown default:
      return true
    }
  }

  private func startPrime(_ prefix: String) {
    let session = LanguageModelSession(instructions: SlipReaderPrompt.instructions)
    session.prewarm(promptPrefix: Prompt(prefix))
    primedPrefix = prefix
    primedSession = session
  }
  #endif
}

#if canImport(FoundationModels)
@Generable
struct ExtractedSlips {
  @Guide(description: "Each distinct spend in the sentence")
  var spends: [ExtractedSlip]
}

@Generable
struct ExtractedSlip {
  @Guide(description: "Numeric amount such as 5.00 even if the sentence had $, S$, SGD, USD, or dollars")
  var amount: String
  @Guide(description: "Merchant or payee name if mentioned, otherwise empty")
  var payee: String
  @Guide(description: "Category name copied from the category list only if the sentence names it, otherwise empty")
  var category: String
  @Guide(description: "Account name only if the sentence explicitly names one, otherwise empty")
  var account: String
  @Guide(description: "Day to post or schedule as yyyy-MM-dd, today, yesterday, 8 Sep, 8/9, next Friday, or empty")
  var date: String
  @Guide(description: "True only when the sentence is money received")
  var isInflow: Bool
}
#endif
