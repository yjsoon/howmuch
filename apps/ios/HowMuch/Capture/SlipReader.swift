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
  var accountCandidates: [SlipCandidate]
  var categoryCandidates: [SlipCandidate]
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
    if trimmed.caseInsensitiveCompare("today") == .orderedSame {
      return today
    }
    if trimmed.caseInsensitiveCompare("yesterday") == .orderedSame {
      return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    guard let parsed = formatter.date(from: trimmed) else {
      return nil
    }
    return calendar.startOfDay(for: parsed)
  }

  private static func mapOne(
    _ extraction: Extraction,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee],
    calendar: Calendar,
    now: Date
  ) -> SlipMappedDraft {
    var draft = TransactionDraft()
    draft.direction = extraction.isInflow ? .inflow : .outflow

    var parsedAmount = false
    if !extraction.amount.isEmpty, let milli = MoneyCodec.milliunits(from: extraction.amount) {
      draft.amountMagnitudeMilli = abs(milli)
      parsedAmount = true
    }

    var parsedDate = false
    if let parsed = Self.date(from: extraction.date, calendar: calendar, now: now) {
      draft.date = parsed
      parsedDate = true
    }

    var accountCandidates: [SlipCandidate] = []
    let parsedAccount = !extraction.account.isEmpty
    if parsedAccount {
      let matches = matchAccounts(extraction.account, in: accounts)
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
}

actor SlipReader {
  enum Extractor: Sendable {
    case foundationModels
    case fixed(@Sendable (String) -> [SlipReaderMapping.Extraction])
  }

  static let shared = SlipReader()

  private let extractor: Extractor

  init(extractor: Extractor = .foundationModels) {
    self.extractor = extractor
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
      extractions = await Self.extractWithModel(
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
      accounts: accounts,
      categoryGroups: categoryGroups,
      payees: payees,
      calendar: calendar,
      now: now
    )
  }

  private static func extractWithModel(
    text: String,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee]
  ) async -> [SlipReaderMapping.Extraction] {
    #if canImport(FoundationModels)
    switch SystemLanguageModel.default.availability {
    case .unavailable(let reason):
      if case .modelNotReady = reason {
        break
      }
      return []
    case .available:
      break
    @unknown default:
      break
    }

    let accountNames = accounts.filter { !$0.closed && !$0.deleted }.map(\.name)
    let categoryNames = categoryGroups.filter { !$0.deleted }.flatMap { group in
      group.categories.filter { !$0.deleted }.map(\.name)
    }
    let payeeNames = payees.filter { $0.deleted != true }.map(\.name)
    let session = LanguageModelSession(instructions: """
    Extract every distinct spend from the sentence. Amounts are decimal strings such as 5 or 5.00, never milliunits and never IDs. Copy account, category, and payee names from the provided lists when they match. Leave a field empty when it was not mentioned. Split two spends in one sentence into two items.
    """)
    let prompt = """
    Accounts: \(accountNames.joined(separator: ", "))
    Categories: \(categoryNames.joined(separator: ", "))
    Payees: \(payeeNames.joined(separator: ", "))

    Sentence:
    \(text)
    """
    do {
      let response = try await session.respond(to: prompt, generating: ExtractedSlips.self)
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
}

#if canImport(FoundationModels)
@Generable
struct ExtractedSlips {
  @Guide(description: "Each distinct spend in the sentence")
  var spends: [ExtractedSlip]
}

@Generable
struct ExtractedSlip {
  @Guide(description: "Amount as a decimal string like 5.00, no currency symbol")
  var amount: String
  @Guide(description: "Merchant or payee name if mentioned, otherwise empty")
  var payee: String
  @Guide(description: "Category name copied from the category list if mentioned, otherwise empty")
  var category: String
  @Guide(description: "Account name copied from the account list if mentioned, otherwise empty")
  var account: String
  @Guide(description: "Calendar date as yyyy-MM-dd, today, or yesterday if mentioned, otherwise empty")
  var date: String
  @Guide(description: "True only when the sentence is money received")
  var isInflow: Bool
}
#endif
