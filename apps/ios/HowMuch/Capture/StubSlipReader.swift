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

enum StubSlipReader {
  struct Candidate: Equatable, Identifiable {
    let id: String
    let name: String
  }

  struct Outcome: Equatable {
    var amountMilli: Int?
    var categoryID: String?
    var categoryCandidates: [Candidate] = []
    var accountID: String?
    var accountCandidates: [Candidate] = []
  }

  static func read(
    text: String,
    placeholder: String,
    accounts: [Account],
    categoryGroups: [CategoryGroup]
  ) -> Outcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return Outcome()
    }

    let sentence = trimmed.caseInsensitiveCompare(placeholder) == .orderedSame
      ? placeholder
      : trimmed
    if let parsed = parseAmountOfOn(sentence) {
      return resolve(
        amountText: parsed.amount,
        categoryQuery: parsed.category,
        accountQuery: parsed.account,
        accounts: accounts,
        categoryGroups: categoryGroups
      )
    }
    if let accountQuery = parseOnAccount(sentence) {
      return resolve(
        amountText: nil,
        categoryQuery: nil,
        accountQuery: accountQuery,
        accounts: accounts,
        categoryGroups: categoryGroups
      )
    }
    return Outcome()
  }

  private static func parseAmountOfOn(_ text: String) -> (amount: String, category: String, account: String)? {
    let pattern = #"^\$?\s*(\d+(?:\.\d+)?)\s+of\s+(.+?)\s+on\s+(.+)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let nsrange = NSRange(text.startIndex..., in: text)
    guard let result = regex.firstMatch(in: text, range: nsrange), result.numberOfRanges == 4 else {
      return nil
    }
    let ns = text as NSString
    let amount = ns.substring(with: result.range(at: 1))
    let category = ns.substring(with: result.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
    let account = ns.substring(with: result.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
    return (amount, category, account)
  }

  private static func parseOnAccount(_ text: String) -> String? {
    let pattern = #"^.+\s+on\s+(.+)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          result.numberOfRanges == 2
    else {
      return nil
    }
    return (text as NSString).substring(with: result.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func resolve(
    amountText: String?,
    categoryQuery: String?,
    accountQuery: String,
    accounts: [Account],
    categoryGroups: [CategoryGroup]
  ) -> Outcome {
    var outcome = Outcome()
    if let amountText {
      outcome.amountMilli = MoneyCodec.milliunits(from: amountText).map(abs)
    }

    let accountMatches = matchAccounts(accountQuery, in: accounts)
    if accountMatches.count == 1 {
      outcome.accountID = accountMatches[0].id
    } else if (2...3).contains(accountMatches.count) {
      outcome.accountCandidates = accountMatches.map { Candidate(id: $0.id, name: $0.name) }
    }

    if let categoryQuery {
      let categoryMatches = matchCategories(categoryQuery, in: categoryGroups)
      if categoryMatches.count == 1 {
        outcome.categoryID = categoryMatches[0].id
      } else if (2...3).contains(categoryMatches.count) {
        outcome.categoryCandidates = categoryMatches.map { Candidate(id: $0.id, name: $0.name) }
      }
    }
    return outcome
  }

  private static func matchAccounts(_ query: String, in accounts: [Account]) -> [Account] {
    let open = accounts.filter { !$0.closed }
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
    let needle = query.caseInsensitiveCompare("food") == .orderedSame ? "Groceries" : query
    let exact = live.filter { $0.name.caseInsensitiveCompare(needle) == .orderedSame }
    if !exact.isEmpty {
      return exact
    }
    return live.filter { $0.name.localizedStandardContains(needle) }
  }
}
