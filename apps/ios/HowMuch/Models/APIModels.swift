import Foundation

struct APIEnvelope<Payload: Decodable>: Decodable {
  let data: Payload
}

struct ServerErrorEnvelope: Decodable {
  let error: ServerError
}

struct ServerError: Decodable {
  let id: String
  let message: String
}

struct APISettings: Codable, Equatable {
  static let userDefaultsKey = "HowMuch.APISettings"

  var baseURLString = "http://127.0.0.1:8787"
  var bearerToken = ""
  var planID = "local-plan"

  var trimmedBaseURL: String {
    baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  var connectionFingerprint: String {
    [trimmedBaseURL, planID, bearerToken].joined(separator: "|")
  }

  var isConfigured: Bool {
    URL(string: trimmedBaseURL) != nil
  }

  static func load(from defaults: UserDefaults = .standard) -> APISettings {
    guard
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(APISettings.self, from: data)
    else {
      return APISettings()
    }
    return decoded
  }

  func save(to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else {
      return
    }
    defaults.set(data, forKey: Self.userDefaultsKey)
  }
}

/// View options remembered across launches, persisted like the connection
/// settings. Defaults apply whenever a stored blob is missing or unreadable.
struct ViewPrefs: Codable, Equatable {
  static let userDefaultsKey = "HowMuch.ViewPrefs"

  var reportRange: ReportRange = .thisMonth
  var reportInterval: ReportInterval = .month
  var includeQuietSpending = false
  var lastUsedAccountID: String?
  var lastUsedCategoryID: String?

  static func load(from defaults: UserDefaults = .standard) -> ViewPrefs {
    guard
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(ViewPrefs.self, from: data)
    else {
      return ViewPrefs()
    }
    return decoded
  }

  func save(to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else {
      return
    }
    defaults.set(data, forKey: Self.userDefaultsKey)
  }
}

struct UserPayload: Decodable {
  let user: APIUser
}

struct APIUser: Decodable {
  let id: String
}

struct ReferenceData {
  let planSettings: PlanSettings
  let accounts: [Account]
  let categoryGroups: [CategoryGroup]
}

struct PlanSettingsPayload: Decodable {
  let settings: PlanSettings
}

struct AccountsPayload: Decodable {
  let accounts: [Account]
}

struct CategoriesPayload: Decodable {
  let categoryGroups: [CategoryGroup]
}

struct TransactionsPayload: Decodable {
  let transactions: [Transaction]
  let serverKnowledge: Int?
}

struct TransactionPayload: Decodable {
  let transaction: Transaction
  let serverKnowledge: Int?
}

struct PlanSettings: Decodable {
  let dateFormat: DateFormat?
  let currencyFormat: CurrencyFormat?
  let display: DisplaySettings?
}

struct DateFormat: Decodable {
  let format: String?
}

struct CurrencyFormat: Decodable {
  let isoCode: String?
  let exampleFormat: String?
  let decimalDigits: Int?
  let decimalSeparator: String?
  let groupSeparator: String?
  let symbolFirst: Bool?
  let currencySymbol: String?
}

struct DisplaySettings: Decodable {
  let flagNames: [String]?

  private enum CodingKeys: String, CodingKey {
    case flagNames
  }

  init(flagNames: [String]? = nil) {
    self.flagNames = flagNames
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    if let array = try? container.decodeIfPresent([String?].self, forKey: .flagNames) {
      flagNames = array.compactMap { value in
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
          return nil
        }
        return trimmed
      }
      return
    }

    if let mapping = try? container.decodeIfPresent([String: String].self, forKey: .flagNames) {
      flagNames = mapping
        .sorted { $0.key < $1.key }
        .map(\.value)
      return
    }

    flagNames = nil
  }
}

struct Account: Decodable, Identifiable, Hashable {
  let id: String
  let name: String
  let type: String
  let onBudget: Bool
  let closed: Bool
  let balance: Int
  let clearedBalance: Int
  let unclearedBalance: Int
  let deleted: Bool
}

struct CategoryGroup: Decodable, Identifiable, Hashable {
  let id: String
  let name: String
  let hidden: Bool
  let deleted: Bool
  let categories: [Category]
}

extension CategoryGroup {
  /// Bookkeeping groups the YNAB import carries as ordinary groups ("Hidden
  /// Categories", "Non-Personal (Don't Summarise)", inflows). They are real
  /// data but not part of day-to-day budgeting, so pickers and reports demote
  /// them. Mirrors the web app's quiet-group heuristic in lib/categories.ts.
  static func isQuietGroupName(_ name: String?) -> Bool {
    guard let name else {
      return false
    }
    let pattern = "hidden|non.personal|don.t summari[sz]e|inflow|credit card payments|internal"
    return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  var isQuiet: Bool {
    hidden || Self.isQuietGroupName(name)
  }

  /// Live groups with live categories, partitioned into everyday and
  /// bookkeeping ones, preserving the server's ordering within each side.
  static func split(_ groups: [CategoryGroup]) -> (primary: [CategoryGroup], quiet: [CategoryGroup]) {
    var primary: [CategoryGroup] = []
    var quiet: [CategoryGroup] = []
    for group in groups where !group.deleted {
      let categories = group.categories.filter { !$0.deleted }
      if categories.isEmpty {
        continue
      }
      let pruned = CategoryGroup(
        id: group.id,
        name: group.name,
        hidden: group.hidden,
        deleted: group.deleted,
        categories: categories
      )
      if group.isQuiet {
        quiet.append(pruned)
      } else {
        primary.append(pruned)
      }
    }
    return (primary, quiet)
  }
}

struct Category: Decodable, Identifiable, Hashable {
  let id: String
  let categoryGroupID: String
  let name: String
  let deleted: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case categoryGroupID = "categoryGroupId"
    case name
    case deleted
  }
}

enum ClearedState: String, Codable, CaseIterable, Identifiable {
  case uncleared
  case cleared
  case reconciled

  var id: String { rawValue }

  var title: String {
    switch self {
    case .uncleared:
      return "Uncleared"
    case .cleared:
      return "Cleared"
    case .reconciled:
      return "Reconciled"
    }
  }
}

enum FlagColour: String, Codable, CaseIterable, Identifiable {
  case none = ""
  case red
  case orange
  case yellow
  case green
  case blue
  case purple

  var id: String { rawValue }

  var title: String {
    rawValue.isEmpty ? "None" : rawValue.capitalized
  }
}

struct Transaction: Decodable, Identifiable, Hashable {
  let id: String
  let date: String
  let amount: Int
  let memo: String?
  let cleared: ClearedState
  let approved: Bool
  let flagColor: String?
  let flagName: String?
  let accountID: String
  let accountName: String
  let payeeID: String?
  let payeeName: String?
  let categoryID: String?
  let categoryName: String?
  let transferAccountID: String?
  let transferTransactionID: String?
  let matchedTransactionID: String?
  let importID: String?
  let importPayeeName: String?
  let importPayeeNameOriginal: String?
  let deleted: Bool
  let subtransactions: [Subtransaction]

  private enum CodingKeys: String, CodingKey {
    case id
    case date
    case amount
    case memo
    case cleared
    case approved
    case flagColor
    case flagName
    case accountID = "accountId"
    case accountName
    case payeeID = "payeeId"
    case payeeName
    case categoryID = "categoryId"
    case categoryName
    case transferAccountID = "transferAccountId"
    case transferTransactionID = "transferTransactionId"
    case matchedTransactionID = "matchedTransactionId"
    case importID = "importId"
    case importPayeeName = "importPayeeName"
    case importPayeeNameOriginal = "importPayeeNameOriginal"
    case deleted
    case subtransactions
  }
}

extension Transaction {
  /// True when the row still needs a category: no category, not a transfer,
  /// and not a split (whose categories live on the subtransactions).
  var isUncategorised: Bool {
    categoryID == nil && transferAccountID == nil && subtransactions.isEmpty
  }
}

struct Subtransaction: Decodable, Hashable {
  let id: String
  let transactionID: String
  let amount: Int
  let memo: String?
  let payeeID: String?
  let payeeName: String?
  let categoryID: String?
  let categoryName: String?
  let transferAccountID: String?
  let transferTransactionID: String?
  let deleted: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case transactionID = "transactionId"
    case amount
    case memo
    case payeeID = "payeeId"
    case payeeName
    case categoryID = "categoryId"
    case categoryName
    case transferAccountID = "transferAccountId"
    case transferTransactionID = "transferTransactionId"
    case deleted
  }
}

struct SpendingBreakdownReport: Decodable {
  let total: Int
  let groups: [SpendingBreakdownGroup]
}

struct SpendingBreakdownGroup: Decodable, Identifiable {
  var id: String { categoryID }

  let categoryID: String
  let categoryName: String
  let categoryGroupID: String
  let categoryGroupName: String
  let amount: Int
  let share: Double
  let transactionCount: Int

  private enum CodingKeys: String, CodingKey {
    case categoryID = "categoryId"
    case categoryName = "categoryName"
    case categoryGroupID = "categoryGroupId"
    case categoryGroupName = "categoryGroupName"
    case amount
    case share
    case transactionCount = "transactionCount"
  }
}

struct IncomeVsSpendingReport: Decodable {
  let interval: String
  let periods: [IncomeVsSpendingPeriod]
}

struct IncomeVsSpendingPeriod: Decodable, Identifiable {
  var id: String { period }

  let period: String
  let income: Int
  let spending: Int
  let net: Int
  let cumulativeNet: Int
}

struct NetWorthReport: Decodable {
  let periods: [NetWorthPeriod]
}

struct NetWorthPeriod: Decodable, Identifiable {
  var id: String { period }

  let period: String
  let endDate: String
  let netWorth: Int
  let delta: Int?
  let accounts: [NetWorthAccount]
}

struct NetWorthAccount: Decodable, Identifiable {
  var id: String { accountID }

  let accountID: String
  let accountName: String
  let balance: Int

  private enum CodingKeys: String, CodingKey {
    case accountID = "accountId"
    case accountName = "accountName"
    case balance
  }
}

struct AgeOfMoneyReport: Decodable {
  let interval: String
  let periods: [AgeOfMoneyPeriod]
}

struct AgeOfMoneyPeriod: Decodable, Identifiable {
  var id: String { period }

  let period: String
  let ageOfMoneyDays: Double?
  let spent: Int
  let unmatchedSpending: Int
}

struct TransactionCreateEnvelope: Encodable {
  let transaction: TransactionCreateRequest
}

struct TransactionCreateRequest: Encodable {
  let accountID: String
  let date: String
  let amount: Int
  let payeeName: String
  let categoryID: String?
  let memo: String?
  let cleared: ClearedState
  let approved: Bool
  let flagColor: String?
}

struct MobileQuickEntryRequest: Encodable {
  let clientID: String
  let accountID: String
  let date: String
  let amount: String
  let amountMilli: Int
  let payeeName: String
  let categoryID: String?
  let memo: String?
  let flagColor: String?
}

enum EntryDirection: String, CaseIterable, Identifiable {
  case spent
  case received

  var id: String { rawValue }

  var title: String {
    switch self {
    case .spent:
      return "Spent"
    case .received:
      return "Received"
    }
  }
}

struct QuickEntryDraft: Equatable {
  var accountID = ""
  var date = Date()
  var payeeName = ""
  var amountText = ""
  var direction: EntryDirection = .spent
  var memo = ""
  var categoryID = ""
  var flagColour: FlagColour = .none
  var clearedState: ClearedState = .cleared

  mutating func seedIfNeeded(accounts: [Account], preferredAccountID: String? = nil, preferredCategoryID: String? = nil) {
    if accountID.isEmpty {
      if let preferredAccountID, accounts.contains(where: { $0.id == preferredAccountID && !$0.closed }) {
        accountID = preferredAccountID
      } else if let first = accounts.first(where: { !$0.closed }) ?? accounts.first {
        accountID = first.id
      }
    }
    if categoryID.isEmpty, let preferredCategoryID {
      categoryID = preferredCategoryID
    }
  }

  /// Milliunits with the sign taken from the Spent/Received toggle, ignoring
  /// any sign typed into the amount field.
  var signedMilliunits: Int? {
    guard let parsed = MoneyCodec.milliunits(from: amountText), parsed != 0 else {
      return nil
    }
    let magnitude = abs(parsed)
    return direction == .spent ? -magnitude : magnitude
  }

  var canAttemptSubmit: Bool {
    !accountID.isEmpty
      && !payeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && signedMilliunits != nil
  }

  func makeTransactionRequest() throws -> TransactionCreateRequest {
    guard let milliunits = signedMilliunits else {
      throw APIClientError.validation("Enter an amount above zero.")
    }

    return TransactionCreateRequest(
      accountID: accountID,
      date: date.isoDateString,
      amount: milliunits,
      payeeName: payeeName.trimmingCharacters(in: .whitespacesAndNewlines),
      categoryID: categoryID.isEmpty ? nil : categoryID,
      memo: memo.trimmedNil,
      cleared: clearedState,
      approved: true,
      flagColor: flagColour.rawValue.isEmpty ? nil : flagColour.rawValue
    )
  }

  func makeMobileQuickEntryRequest() throws -> MobileQuickEntryRequest {
    guard let milliunits = signedMilliunits else {
      throw APIClientError.validation("Enter an amount above zero.")
    }

    return MobileQuickEntryRequest(
      clientID: UUID().uuidString.lowercased(),
      accountID: accountID,
      date: date.isoDateString,
      amount: (Decimal(milliunits) / 1000).description,
      amountMilli: milliunits,
      payeeName: payeeName.trimmingCharacters(in: .whitespacesAndNewlines),
      categoryID: categoryID.isEmpty ? nil : categoryID,
      memo: memo.trimmedNil,
      flagColor: flagColour.rawValue.isEmpty ? nil : flagColour.rawValue
    )
  }

  func resetAfterSubmit() -> QuickEntryDraft {
    QuickEntryDraft(
      accountID: accountID,
      date: Date(),
      payeeName: "",
      amountText: "",
      direction: .spent,
      memo: "",
      categoryID: categoryID,
      flagColour: .none,
      clearedState: clearedState
    )
  }
}

enum ReportInterval: String, Codable, CaseIterable, Identifiable {
  case week
  case month
  case year

  var id: String { rawValue }

  var title: String {
    rawValue.capitalized
  }
}

extension String {
  var trimmedNil: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
