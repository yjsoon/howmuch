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
  let flagNames: [String?]?
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

struct Category: Decodable, Identifiable, Hashable {
  let id: String
  let categoryGroupID: String
  let name: String
  let deleted: Bool
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
  let accounts: [NetWorthAccount]
}

struct NetWorthAccount: Decodable, Identifiable {
  var id: String { accountID }

  let accountID: String
  let accountName: String
  let balance: Int
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

struct QuickEntryDraft: Equatable {
  var accountID = ""
  var date = Date()
  var payeeName = ""
  var amountText = ""
  var memo = ""
  var categoryID = ""
  var flagColour: FlagColour = .none
  var clearedState: ClearedState = .uncleared

  mutating func seedIfNeeded(accounts: [Account]) {
    if accountID.isEmpty, let first = accounts.first {
      accountID = first.id
    }
  }

  var canAttemptSubmit: Bool {
    !accountID.isEmpty && !payeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func makeTransactionRequest() throws -> TransactionCreateRequest {
    guard let milliunits = MoneyCodec.milliunits(from: amountText) else {
      throw APIClientError.validation("Enter a valid decimal amount.")
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
    guard let milliunits = MoneyCodec.milliunits(from: amountText) else {
      throw APIClientError.validation("Enter a valid decimal amount.")
    }

    return MobileQuickEntryRequest(
      clientID: UUID().uuidString.lowercased(),
      accountID: accountID,
      date: date.isoDateString,
      amount: amountText.trimmingCharacters(in: .whitespacesAndNewlines),
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
      memo: "",
      categoryID: categoryID,
      flagColour: flagColour,
      clearedState: clearedState
    )
  }
}

enum ReportWindow: String, CaseIterable, Identifiable {
  case oneMonth
  case threeMonths
  case twelveMonths

  var id: String { rawValue }

  var title: String {
    switch self {
    case .oneMonth:
      return "1M"
    case .threeMonths:
      return "3M"
    case .twelveMonths:
      return "12M"
    }
  }

  func startDate(from endDate: Date = Date(), calendar: Calendar = .current) -> Date {
    switch self {
    case .oneMonth:
      return calendar.date(byAdding: .month, value: -1, to: endDate) ?? endDate
    case .threeMonths:
      return calendar.date(byAdding: .month, value: -3, to: endDate) ?? endDate
    case .twelveMonths:
      return calendar.date(byAdding: .year, value: -1, to: endDate) ?? endDate
    }
  }
}

enum ReportInterval: String, CaseIterable, Identifiable {
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
