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

  var lastUsedAccountID: String?
  /// Whether the spending report includes bookkeeping ("quiet") category
  /// groups; mirrors the web app's persisted includeQuietSpending pref.
  var includeQuietSpending: Bool?

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
  let payees: [Payee]
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

struct PayeesPayload: Decodable {
  let payees: [Payee]
}

struct Payee: Decodable, Identifiable, Hashable {
  let id: String
  let name: String
  let transferAccountId: String?
  let deleted: Bool?

  var isTransferPayee: Bool {
    transferAccountId != nil
  }
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
  /// Matches the API's COALESCE id for transactions without a category, so it
  /// can be used as a pseudo-category in report filters (as on the web).
  static let uncategorisedCategoryID = "uncategorised"

  let id: String
  let name: String
  let hidden: Bool
  let deleted: Bool
  let categories: [Category]

  /// Bookkeeping groups the YNAB import carries as ordinary groups ("Hidden
  /// Categories", "Non-Personal (Don't Summarise)", inflows). Mirrors the web
  /// app's quiet-group regex in lib/categories.ts so pickers and reports
  /// demote the same groups everywhere.
  var isQuiet: Bool {
    hidden || CategoryGroup.isQuietName(name)
  }

  static func isQuietName(_ name: String?) -> Bool {
    guard let name else {
      return false
    }
    let pattern = "hidden|non.personal|don.t summari[sz]e|inflow|credit card payments|internal"
    return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
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

  var isSplit: Bool {
    !subtransactions.isEmpty
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

struct TransactionWriteEnvelope: Encodable {
  let transaction: TransactionWriteRequest
}

/// Create/update body. Encodes optional fields as explicit nulls so an update
/// can clear them — the API treats omitted keys as "keep existing".
struct TransactionWriteRequest: Encodable {
  let accountID: String
  let date: String
  let amount: Int
  let payeeID: String?
  let payeeName: String?
  let categoryID: String?
  let memo: String?
  let cleared: ClearedState
  let approved: Bool
  let flagColor: String?

  private enum CodingKeys: String, CodingKey {
    case accountID
    case date
    case amount
    case payeeID
    case payeeName
    case categoryID
    case memo
    case cleared
    case approved
    case flagColor
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(accountID, forKey: .accountID)
    try container.encode(date, forKey: .date)
    try container.encode(amount, forKey: .amount)
    try container.encode(payeeID, forKey: .payeeID)
    try container.encode(payeeName, forKey: .payeeName)
    try container.encode(categoryID, forKey: .categoryID)
    try container.encode(memo, forKey: .memo)
    try container.encode(cleared, forKey: .cleared)
    try container.encode(approved, forKey: .approved)
    try container.encode(flagColor, forKey: .flagColor)
  }
}

enum EntryDirection: String, CaseIterable, Identifiable {
  case outflow
  case inflow

  var id: String { rawValue }

  var title: String {
    switch self {
    case .outflow:
      return "− Outflow"
    case .inflow:
      return "+ Inflow"
    }
  }
}

/// Editable state behind both the Add Transaction sheet and the edit form.
struct TransactionDraft: Equatable {
  var id: String?
  var direction: EntryDirection = .outflow
  /// Magnitude only; the Outflow/Inflow toggle owns the sign.
  var amountMagnitudeMilli = 0
  var payeeID: String?
  var payeeName = ""
  var accountID = ""
  var categoryID: String?
  /// Set when the chosen payee is another account's transfer payee; the API
  /// keeps the mirrored transaction on that account in step.
  var transferAccountID: String?
  /// Existing split lines, shown read-only; the API preserves them as long
  /// as the total amount still matches.
  var subtransactions: [Subtransaction] = []
  var date = Date.now
  var isCleared = false
  var wasReconciled = false
  var flag: FlagColour = .none
  var memo = ""

  init() {}

  init(transaction: Transaction) {
    id = transaction.id
    direction = transaction.amount < 0 ? .outflow : .inflow
    amountMagnitudeMilli = abs(transaction.amount)
    payeeID = transaction.payeeID
    payeeName = transaction.payeeName ?? ""
    accountID = transaction.accountID
    categoryID = transaction.categoryID
    transferAccountID = transaction.transferAccountID
    subtransactions = transaction.subtransactions
    date = Date(isoDateString: transaction.date) ?? .now
    isCleared = transaction.cleared != .uncleared
    wasReconciled = transaction.cleared == .reconciled
    flag = FlagColour(rawValue: transaction.flagColor ?? "") ?? .none
    memo = transaction.memo ?? ""
  }

  /// A fresh draft copying an existing transaction's details, dated today and
  /// uncleared — the "same coffee again" shortcut. Splits are not duplicated:
  /// the app's write request carries no subtransactions, so a split's copy
  /// would silently flatten to its total.
  init(duplicating transaction: Transaction) {
    direction = transaction.amount < 0 ? .outflow : .inflow
    amountMagnitudeMilli = abs(transaction.amount)
    payeeID = transaction.payeeID
    payeeName = transaction.payeeName ?? ""
    accountID = transaction.accountID
    categoryID = transaction.categoryID
    transferAccountID = transaction.transferAccountID
    flag = FlagColour(rawValue: transaction.flagColor ?? "") ?? .none
    memo = transaction.memo ?? ""
  }

  var isTransfer: Bool {
    transferAccountID != nil
  }

  var isSplit: Bool {
    !subtransactions.isEmpty
  }

  mutating func seedIfNeeded(accounts: [Account], preferredAccountID: String? = nil) {
    guard accountID.isEmpty else {
      return
    }
    if let preferredAccountID, accounts.contains(where: { $0.id == preferredAccountID && !$0.closed }) {
      accountID = preferredAccountID
    } else if let first = accounts.first(where: { !$0.closed }) ?? accounts.first {
      accountID = first.id
    }
  }

  var signedMilliunits: Int {
    direction == .outflow ? -amountMagnitudeMilli : amountMagnitudeMilli
  }

  var canSave: Bool {
    // A split whose lines net to zero is a legal YNAB reallocation.
    !accountID.isEmpty && (amountMagnitudeMilli > 0 || isSplit)
  }

  /// Editing keeps a reconciled transaction reconciled while the toggle is on.
  var clearedState: ClearedState {
    guard isCleared else {
      return .uncleared
    }
    return wasReconciled ? .reconciled : .cleared
  }

  func writeRequest() -> TransactionWriteRequest {
    let trimmedPayee = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    return TransactionWriteRequest(
      accountID: accountID,
      date: date.isoDateString,
      amount: signedMilliunits,
      payeeID: payeeID,
      payeeName: trimmedPayee.isEmpty ? nil : trimmedPayee,
      categoryID: categoryID,
      memo: memo.trimmedNil,
      cleared: clearedState,
      approved: true,
      flagColor: flag.rawValue.isEmpty ? nil : flag.rawValue
    )
  }
}

/// Date ranges for Reflect's "Preset" mode, matching YNAB's presets plus the
/// web app's "All" range.
enum ReportPreset: String, CaseIterable, Identifiable {
  case thisMonth
  case lastMonth
  case lastThreeMonths
  case lastSixMonths
  case lastTwelveMonths
  case yearToDate
  case allTime

  var id: String { rawValue }

  var title: String {
    switch self {
    case .thisMonth:
      return "This Month"
    case .lastMonth:
      return "Last Month"
    case .lastThreeMonths:
      return "Last 3 Months"
    case .lastSixMonths:
      return "Last 6 Months"
    case .lastTwelveMonths:
      return "Last 12 Months"
    case .yearToDate:
      return "Year to Date"
    case .allTime:
      return "All Time"
    }
  }

  /// `nil` bounds mean "unbounded": All Time sends no dates at all.
  func range(now: Date = .now, calendar: Calendar = .current) -> (from: Date?, to: Date?) {
    let monthStart = now.startOfMonth(calendar: calendar)
    switch self {
    case .thisMonth:
      return (monthStart, now)
    case .lastMonth:
      let previousStart = calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
      let previousEnd = calendar.date(byAdding: .day, value: -1, to: monthStart) ?? monthStart
      return (previousStart, previousEnd)
    case .lastThreeMonths:
      return (calendar.date(byAdding: .month, value: -2, to: monthStart) ?? monthStart, now)
    case .lastSixMonths:
      return (calendar.date(byAdding: .month, value: -5, to: monthStart) ?? monthStart, now)
    case .lastTwelveMonths:
      return (calendar.date(byAdding: .month, value: -11, to: monthStart) ?? monthStart, now)
    case .yearToDate:
      let components = calendar.dateComponents([.year], from: now)
      return (calendar.date(from: components) ?? now, now)
    case .allTime:
      return (nil, nil)
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
