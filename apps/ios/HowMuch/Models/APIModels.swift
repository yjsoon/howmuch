import Foundation
import Security

struct APIEnvelope<Payload: Decodable>: Decodable {
  let data: Payload
}

struct ServerErrorEnvelope: Decodable {
  let error: ServerError
}

struct ServerError: Decodable {
  let id: String
  let detail: String
  let name: String?
  let currentReconciledBalance: Int?
  let projectedReconciledBalance: Int?
  let statementBalance: Int?
  let difference: Int?
}

struct APISettings: Codable, Equatable {
  static let userDefaultsKey = "HowMuch.APISettings"
  static let productionBaseURL = "https://howmuch.soon.sg"
  private static let legacyBaseURL = "http://127.0.0.1:8787"
#if DEBUG
  /// A development-signed build may receive these once at launch through
  /// `devicectl`'s process environment. This marker makes the hand-off
  /// one-time: subsequent launches use the normal Keychain-backed settings.
  private static let debugBootstrapAppliedKey = "HowMuch.DebugBootstrapApplied"
#endif

  var baseURLString = productionBaseURL
  var username = ""
  var sessionToken = ""
  var authenticatedUserID = ""
  /// The server chooses the usable plan after sign-in. Leaving this empty on
  /// a fresh install prevents requests from accidentally targeting the old
  /// development-only `local-plan` identifier.
  var planID = ""

  var trimmedBaseURL: String {
    baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  /// A stable identity for the server that owns this session. The value is
  /// deliberately derived from the URL rather than from the user or plan so
  /// that a token can never be sent to a different endpoint after a setting
  /// change.
  var normalizedBaseURLString: String? {
    Self.normalizedBaseURLString(from: trimmedBaseURL)
  }

  static func normalizedBaseURLString(from value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host?.lowercased(),
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      return nil
    }

    var normalized = components
    normalized.scheme = scheme
    normalized.host = host
    if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
      normalized.port = nil
    }

    var path = components.percentEncodedPath
    while path.hasSuffix("/") {
      path.removeLast()
    }
    while path.hasPrefix("/") {
      path.removeFirst()
    }
    normalized.percentEncodedPath = path.isEmpty ? "" : "/" + path
    return normalized.string
  }

  var connectionFingerprint: String {
    [trimmedBaseURL, planID, authenticatedUserID].joined(separator: "|")
  }

  var baseURL: URL? {
    guard
      let components = URLComponents(string: trimmedBaseURL),
      components.scheme == "http" || components.scheme == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      return nil
    }
    return components.url
  }

  var browserSetupURL: URL? {
    guard let baseURL, baseURL.scheme == "https",
          var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else {
      return nil
    }
    components.path = "/"
    return components.url
  }

  var isConfigured: Bool {
    baseURL != nil
  }

  var isAuthenticated: Bool {
    !sessionToken.isEmpty && !authenticatedUserID.isEmpty
  }

  /// Keeps an already-selected accessible plan, otherwise adopts the only
  /// plan the signed-in user can read. Ambiguous servers intentionally retain
  /// the existing value so a user cannot be moved to an unintended plan.
  func resolvedPlanID(from plans: [PlanSummary]) -> String? {
    let currentPlanID = planID.trimmingCharacters(in: .whitespacesAndNewlines)
    if plans.contains(where: { $0.id == currentPlanID }) {
      return currentPlanID
    }
    guard plans.count == 1 else {
      return nil
    }
    return plans[0].id
  }

  static func load(
    from defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> APISettings {
#if DEBUG
    if !defaults.bool(forKey: debugBootstrapAppliedKey),
       let bootstrap = debugBootstrapSettings(from: environment) {
      // `save` writes the opaque token only to the endpoint-scoped Keychain
      // item; the UserDefaults payload intentionally remains public settings.
      bootstrap.save(to: defaults)
      defaults.set(true, forKey: debugBootstrapAppliedKey)
      // A forced termination may follow this first launch immediately. Flush
      // the endpoint/plan and marker before a relaunch needs the Keychain token.
      defaults.synchronize()
      return bootstrap
    }
#endif
    guard
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(APISettings.self, from: data)
    else {
      return APISettings()
    }
    var settings = decoded
    if settings.normalizedBaseURLString == normalizedBaseURLString(from: legacyBaseURL) {
      settings.baseURLString = productionBaseURL
      settings.sessionToken = ""
      settings.authenticatedUserID = ""
      settings.save(to: defaults)
      return settings
    }

    if let normalizedBaseURL = decoded.normalizedBaseURLString,
       let token = CredentialStore.load(for: normalizedBaseURL) {
      settings.sessionToken = token
    } else if decoded.normalizedBaseURLString == normalizedBaseURLString(from: productionBaseURL),
              let legacyToken = CredentialStore.loadLegacy() {
      // Versions before endpoint scoping used one global Keychain account.
      // Only migrate it when UserDefaults proves the saved endpoint is the
      // production service; custom endpoints must never inherit that token.
      settings.sessionToken = legacyToken
      settings.save(to: defaults)
      return settings
    } else {
      settings.sessionToken = ""
    }
    return settings
  }

#if DEBUG
  private static func debugBootstrapSettings(from environment: [String: String]) -> APISettings? {
    guard
      let submittedURL = environment["HOWMUCH_BOOTSTRAP_BASE_URL"],
      let normalizedURL = normalizedBaseURLString(from: submittedURL),
      let normalizedProductionURL = normalizedBaseURLString(from: productionBaseURL),
      normalizedURL == normalizedProductionURL,
      URLComponents(string: normalizedURL)?.scheme?.lowercased() == "https",
      let username = environment["HOWMUCH_BOOTSTRAP_USERNAME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !username.isEmpty,
      let planID = environment["HOWMUCH_BOOTSTRAP_PLAN_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !planID.isEmpty,
      let sessionToken = environment["HOWMUCH_BOOTSTRAP_SESSION_TOKEN"],
      !sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }

    // The launch contract deliberately contains a username, not a separately
    // identifying profile payload. It is sufficient for the local signed-in
    // state; every request is still authenticated by the opaque session token.
    return APISettings(
      baseURLString: normalizedURL,
      username: username,
      sessionToken: sessionToken,
      authenticatedUserID: username,
      planID: planID
    )
  }
#endif

  func save(to defaults: UserDefaults = .standard) {
    CredentialStore.save(sessionToken, for: normalizedBaseURLString)
    var publicSettings = self
    publicSettings.sessionToken = ""
    guard let data = try? JSONEncoder().encode(publicSettings) else {
      return
    }
    defaults.set(data, forKey: Self.userDefaultsKey)
  }
}

private enum CredentialStore {
  private static let service = Bundle.main.bundleIdentifier ?? "HowMuch"
  private static let legacyAccount = "session-token"
  private static let accountPrefix = "session-token:"

  static func load(for normalizedBaseURL: String) -> String? {
    load(account: accountPrefix + normalizedBaseURL)
  }

  static func loadLegacy() -> String? {
    load(account: legacyAccount)
  }

  private static func load(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  static func save(_ token: String, for normalizedBaseURL: String?) {
    guard let normalizedBaseURL else {
      removeLegacy()
      return
    }

    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: accountPrefix + normalizedBaseURL,
    ]
    SecItemDelete(identity as CFDictionary)
    removeLegacy()
    guard !token.isEmpty, let data = token.data(using: .utf8) else {
      return
    }
    var item = identity
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }

  private static func removeLegacy() {
    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: legacyAccount,
    ]
    SecItemDelete(identity as CFDictionary)
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
  /// Account presentation preferences stay on this device. The server's
  /// account payload is an immutable source list, so these IDs are deliberately
  /// not sent back to the API.
  var favouriteAccountIDs: [String] = []
  var accountOrder: [String] = []

  private enum CodingKeys: String, CodingKey {
    case lastUsedAccountID
    case includeQuietSpending
    case favouriteAccountIDs
    case accountOrder
  }

  init(
    lastUsedAccountID: String? = nil,
    includeQuietSpending: Bool? = nil,
    favouriteAccountIDs: [String] = [],
    accountOrder: [String] = []
  ) {
    self.lastUsedAccountID = lastUsedAccountID
    self.includeQuietSpending = includeQuietSpending
    self.favouriteAccountIDs = favouriteAccountIDs
    self.accountOrder = accountOrder
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    lastUsedAccountID = try container.decodeIfPresent(String.self, forKey: .lastUsedAccountID)
    includeQuietSpending = try container.decodeIfPresent(Bool.self, forKey: .includeQuietSpending)
    favouriteAccountIDs = try container.decodeIfPresent([String].self, forKey: .favouriteAccountIDs) ?? []
    accountOrder = try container.decodeIfPresent([String].self, forKey: .accountOrder) ?? []
  }

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
  let username: String?
}

struct AuthTokenPayload: Decodable {
  let token: String
  let expiresAt: Int
  let user: APIUser
}

struct AuthStatusPayload: Decodable {
  let setupRequired: Bool
  let bootstrapRequired: Bool
  let user: APIUser?
}

struct PlansPayload: Decodable {
  let plans: [PlanSummary]
}

struct PlanSummary: Decodable {
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

struct PlanMonthPayload: Decodable {
  let month: PlanMonth
  let serverKnowledge: Int?
}

struct PlanAssignmentRequest: Encodable {
  private let category: Category

  init(budgeted: Int) {
    category = Category(budgeted: budgeted)
  }

  private struct Category: Encodable {
    let budgeted: Int
  }
}

struct PlanTargetRequest: Encodable {
  private let category: Category

  init(target: PlanTargetPayload?) {
    category = Category(target: target)
  }

  private struct Category: Encodable {
    let target: PlanTargetPayload?
  }
}

struct PlanTargetRestoreRequest: Encodable {
  private let category = Category()

  private struct Category: Encodable {
    let restoreTarget = true
  }
}

struct PlanTargetPayload: Encodable {
  let goalType: String
  let goalTarget: Int
  let goalTargetMonth: String?
}

/// A monthly planning snapshot. Imported values stay read-only unless a
/// HowMuch-owned assignment or target overlay is present.
struct PlanMonth: Decodable {
  let month: String
  let note: String?
  let income: Int?
  let budgeted: Int?
  let activity: Int?
  let toBeBudgeted: Int?
  let ageOfMoney: Int?
  let deleted: Bool?
  let categories: [PlanMonthCategory]
}

struct PlanMonthCategory: Decodable, Identifiable, Hashable {
  let id: String
  let name: String
  let categoryGroupID: String
  let hidden: Bool?
  let originalCategoryGroupID: String?
  let note: String?
  let budgeted: Int?
  let activity: Int?
  let balance: Int?
  let goalType: String?
  let goalDay: Int?
  let goalCadence: Int?
  let goalCadenceFrequency: Int?
  let goalCreationMonth: String?
  let goalTarget: Int?
  let goalTargetMonth: String?
  let goalPercentageComplete: Int?
  let goalMonthsToBudget: Int?
  let goalUnderFunded: Int?
  let goalOverallFunded: Int?
  let goalOverallLeft: Int?
  let goalNeededForSpending: Int?
  let goalNeedsWholeAmount: Bool?
  let targetSource: String?
  let deleted: Bool?

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    // `convertFromSnakeCase` normalises the API's `*_id` suffix to `*Id`.
    // Swift acronym spelling therefore needs the same explicit bridge used by
    // Category, Transaction, and the report models below.
    case categoryGroupID = "categoryGroupId"
    case hidden
    case originalCategoryGroupID = "originalCategoryGroupId"
    case note
    case budgeted
    case activity
    case balance
    case goalType
    case goalDay
    case goalCadence
    case goalCadenceFrequency
    case goalCreationMonth
    case goalTarget
    case goalTargetMonth
    case goalPercentageComplete
    case goalMonthsToBudget
    case goalUnderFunded
    case goalOverallFunded
    case goalOverallLeft
    case goalNeededForSpending
    case goalNeedsWholeAmount
    case targetSource
    case deleted
  }

  var hasTarget: Bool {
    goalType != nil || (goalTarget ?? 0) != 0
  }

  var targetProgress: Double? {
    if let goalPercentageComplete {
      return min(max(Double(goalPercentageComplete) / 100, 0), 1)
    }
    guard let goalTarget, goalTarget > 0 else {
      return nil
    }
    return min(max(Double(balance ?? 0) / Double(goalTarget), 0), 1)
  }
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
  let hasMore: Bool?
  let nextOffset: Int?
}

/// One bounded, newest-first ledger page from the HowMuch transaction API.
/// Deleted rows are removed by `APIClient` before the page reaches the UI.
struct TransactionPage {
  let transactions: [Transaction]
  let hasMore: Bool
  let nextOffset: Int?
}

struct TransactionPayload: Decodable {
  let transaction: Transaction
  let serverKnowledge: Int?
}

struct ScheduledTransactionsPayload: Decodable {
  let scheduledTransactions: [ScheduledTransaction]
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

/// An imported YNAB scheduled transaction. The API deliberately exposes this
/// as a read-only source mirror, so the app never offers an edit action here.
struct ScheduledTransaction: Decodable, Identifiable, Hashable {
  let id: String
  let dateFirst: String
  let dateNext: String
  let frequency: String
  let amount: Int
  let memo: String?
  let flagColor: String?
  let accountID: String
  let payeeID: String?
  let categoryID: String?
  let transferAccountID: String?
  let deleted: Bool
  let subtransactions: [ScheduledSubtransaction]

  private enum CodingKeys: String, CodingKey {
    case id
    case dateFirst = "dateFirst"
    case dateNext = "dateNext"
    case frequency
    case amount
    case memo
    case flagColor = "flagColor"
    case accountID = "accountId"
    case payeeID = "payeeId"
    case categoryID = "categoryId"
    case transferAccountID = "transferAccountId"
    case deleted
    case subtransactions
  }

  var isSplit: Bool {
    !activeSubtransactions.isEmpty
  }

  var activeSubtransactions: [ScheduledSubtransaction] {
    subtransactions.filter { !$0.deleted }
  }

  var recurrenceLabel: String {
    switch frequency {
    case "never": return "Does not repeat"
    case "daily": return "Repeats daily"
    case "weekly": return "Repeats weekly"
    case "everyOtherWeek": return "Repeats every other week"
    case "twiceAMonth": return "Repeats twice a month"
    case "every4Weeks": return "Repeats every 4 weeks"
    case "monthly": return "Repeats monthly"
    case "everyOtherMonth": return "Repeats every other month"
    case "every3Months": return "Repeats every 3 months"
    case "every4Months": return "Repeats every 4 months"
    case "twiceAYear": return "Repeats twice a year"
    case "yearly": return "Repeats yearly"
    case "everyOtherYear": return "Repeats every other year"
    default:
      let words = frequency
        .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        .lowercased()
      return "Repeats \(words)"
    }
  }
}

struct ScheduledSubtransaction: Decodable, Hashable {
  let id: String
  let scheduledTransactionID: String
  let amount: Int
  let memo: String?
  let payeeID: String?
  let categoryID: String?
  let transferAccountID: String?
  let deleted: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case scheduledTransactionID = "scheduledTransactionId"
    case amount
    case memo
    case payeeID = "payeeId"
    case categoryID = "categoryId"
    case transferAccountID = "transferAccountId"
    case deleted
  }
}

/// Response from entering one selected scheduled occurrence. The server
/// advances (or completes) the parent schedule atomically with the ledger
/// transaction, then the app refreshes every affected surface.
struct ScheduledOccurrencePayload: Decodable {
  let transaction: Transaction
  let scheduledTransaction: ScheduledTransaction
  let occurrenceDate: String
  let enteredDate: String
  let completed: Bool
  let replayed: Bool
}

struct ScheduledOccurrenceRequest: Encodable {
  let occurrenceDate: String
  let date: String
}

struct AccountReconciliationPayload: Decodable {
  let account: Account
  let reconciledTransactionIDs: [String]
  let reconciledTransactionCount: Int
  let statementDate: String
  let statementBalance: Int
  let priorReconciledBalance: Int
  let finalReconciledBalance: Int
  let replayed: Bool
}

/// A read-only reconciliation projection. It is deliberately separate from
/// the mutation response: the review screen must show the server's current
/// candidate set before it is safe to confirm.
struct AccountReconciliationPreview: Decodable {
  let account: Account
  let statementDate: String
  let currentReconciledBalance: Int
  let projectedReconciledBalance: Int
  let candidateTransactionIDs: [String]
  let candidateTransactionCount: Int
}

struct AccountReconciliationRequest: Encodable {
  let statementDate: String
  let statementBalance: Int
}

struct ReconciliationMismatchDetail: Equatable {
  let currentReconciledBalance: Int
  let projectedReconciledBalance: Int
  let statementBalance: Int
  let difference: Int
  let message: String
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

struct TransactionSubtransactionWriteRequest: Codable, Equatable {
  let id: String?
  let amount: Int
  let payeeID: String?
  let payeeName: String?
  let categoryID: String?
  let memo: String?
  let transferAccountID: String?
  /// Existing split-transfer mirrors must survive a parent edit. The API
  /// accepts this optional link and uses it instead of minting a new mirror.
  let transferTransactionID: String?
}

/// Create/update body. Encodes optional fields as explicit nulls so an update
/// can clear them — the API treats omitted keys as "keep existing".
/// Decodable too, so offline captures can be persisted and replayed.
struct TransactionWriteRequest: Codable, Equatable {
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
  let subtransactions: [TransactionSubtransactionWriteRequest]

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
    case subtransactions
  }

  init(
    accountID: String,
    date: String,
    amount: Int,
    payeeID: String?,
    payeeName: String?,
    categoryID: String?,
    memo: String?,
    cleared: ClearedState,
    approved: Bool,
    flagColor: String?,
    subtransactions: [TransactionSubtransactionWriteRequest]
  ) {
    self.accountID = accountID
    self.date = date
    self.amount = amount
    self.payeeID = payeeID
    self.payeeName = payeeName
    self.categoryID = categoryID
    self.memo = memo
    self.cleared = cleared
    self.approved = approved
    self.flagColor = flagColor
    self.subtransactions = subtransactions
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
    try container.encode(subtransactions, forKey: .subtransactions)
  }

  /// Captures made before split support did not persist this key. Keep those
  /// offline entries replayable instead of dropping the whole outbox on
  /// upgrade.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountID = try container.decode(String.self, forKey: .accountID)
    date = try container.decode(String.self, forKey: .date)
    amount = try container.decode(Int.self, forKey: .amount)
    payeeID = try container.decodeIfPresent(String.self, forKey: .payeeID)
    payeeName = try container.decodeIfPresent(String.self, forKey: .payeeName)
    categoryID = try container.decodeIfPresent(String.self, forKey: .categoryID)
    memo = try container.decodeIfPresent(String.self, forKey: .memo)
    cleared = try container.decode(ClearedState.self, forKey: .cleared)
    approved = try container.decode(Bool.self, forKey: .approved)
    flagColor = try container.decodeIfPresent(String.self, forKey: .flagColor)
    subtransactions = try container.decodeIfPresent([TransactionSubtransactionWriteRequest].self, forKey: .subtransactions) ?? []
  }
}

/// A capture made while the server was unreachable, waiting to be replayed.
/// Kept as the exact write request so the sync sends what the user saved,
/// stamped with the connection it was captured against so a later change of
/// server or plan cannot replay it somewhere it does not belong.
struct PendingTransaction: Codable, Equatable, Identifiable {
  let id: UUID
  let request: TransactionWriteRequest
  let connectionFingerprint: String
  let capturedAt: Date
  /// Last non-transport failure from a sync attempt, e.g. a server rejection.
  var lastSyncError: String?

  init(request: TransactionWriteRequest, connectionFingerprint: String, capturedAt: Date = .now) {
    id = UUID()
    self.request = request
    self.connectionFingerprint = connectionFingerprint
    self.capturedAt = capturedAt
  }
}

/// Persists the offline queue like the connection settings, so captures
/// survive relaunches until they reach the server.
enum OutboxStore {
  static let userDefaultsKey = "HowMuch.Outbox"

  static func load(from defaults: UserDefaults = .standard) -> [PendingTransaction] {
    guard
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode([PendingTransaction].self, from: data)
    else {
      return []
    }
    return decoded
  }

  static func save(_ pending: [PendingTransaction], to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(pending) else {
      return
    }
    defaults.set(data, forKey: userDefaultsKey)
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
struct TransactionSubtransactionDraft: Equatable {
  /// Existing IDs are preserved on edit. Fresh and duplicated lines omit IDs
  /// so the server creates a distinct graph rather than mutating the source.
  var id: String?
  var amountText: String
  var payeeID: String?
  var payeeName: String
  var categoryID: String?
  var transferAccountID: String?
  var transferTransactionID: String?
  /// The account paired with `transferTransactionID` when this line was
  /// loaded. Changing the target must mint a new mirror, not reuse the old
  /// mirror ID against a different account.
  private var mirroredTransferAccountID: String?
  var memo: String

  init(
    id: String? = nil,
    amountText: String = "0",
    payeeID: String? = nil,
    payeeName: String = "",
    categoryID: String? = nil,
    transferAccountID: String? = nil,
    transferTransactionID: String? = nil,
    mirroredTransferAccountID: String? = nil,
    memo: String = ""
  ) {
    self.id = id
    self.amountText = amountText
    self.payeeID = payeeID
    self.payeeName = payeeName
    self.categoryID = categoryID
    self.transferAccountID = transferAccountID
    self.transferTransactionID = transferTransactionID
    self.mirroredTransferAccountID = mirroredTransferAccountID ?? transferAccountID
    self.memo = memo
  }

  init(subtransaction: Subtransaction, preserveID: Bool = true) {
    id = preserveID ? subtransaction.id : nil
    amountText = MoneyCodec.displayString(for: subtransaction.amount, currencyFormat: nil)
    payeeID = subtransaction.payeeID
    payeeName = subtransaction.payeeName ?? ""
    categoryID = subtransaction.categoryID
    transferAccountID = subtransaction.transferAccountID
    transferTransactionID = subtransaction.transferTransactionID
    mirroredTransferAccountID = subtransaction.transferAccountID
    memo = subtransaction.memo ?? ""
  }

  var amount: Int? { MoneyCodec.milliunits(from: amountText) }

  func writeRequest() -> TransactionSubtransactionWriteRequest? {
    guard let amount else { return nil }
    let trimmedPayeeName = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    return TransactionSubtransactionWriteRequest(
      id: id,
      amount: amount,
      payeeID: transferAccountID == nil ? payeeID : nil,
      payeeName: transferAccountID == nil && !trimmedPayeeName.isEmpty ? trimmedPayeeName : nil,
      categoryID: transferAccountID == nil ? categoryID : nil,
      memo: memo.trimmedNil,
      transferAccountID: transferAccountID,
      transferTransactionID: transferAccountID == mirroredTransferAccountID ? transferTransactionID : nil
    )
  }
}

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
  /// Editable signed allocations for split transactions.
  var subtransactions: [TransactionSubtransactionDraft] = []
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
    // A split owns categorisation and transfer state on its lines. Do not
    // carry an old parent transfer into a split edit where the API would
    // reject the hybrid transaction.
    transferAccountID = transaction.isSplit ? nil : transaction.transferAccountID
    subtransactions = transaction.subtransactions.map { TransactionSubtransactionDraft(subtransaction: $0) }
    date = Date(isoDateString: transaction.date) ?? .now
    isCleared = transaction.cleared != .uncleared
    wasReconciled = transaction.cleared == .reconciled
    flag = FlagColour(rawValue: transaction.flagColor ?? "") ?? .none
    memo = transaction.memo ?? ""
  }

  /// A fresh draft copying an existing transaction's details, dated today and
  /// uncleared. Split allocations duplicate too, but always get fresh IDs.
  init(duplicating transaction: Transaction) {
    direction = transaction.amount < 0 ? .outflow : .inflow
    amountMagnitudeMilli = abs(transaction.amount)
    payeeID = transaction.payeeID
    payeeName = transaction.payeeName ?? ""
    accountID = transaction.accountID
    categoryID = transaction.categoryID
    transferAccountID = transaction.isSplit ? nil : transaction.transferAccountID
    subtransactions = transaction.subtransactions.map { TransactionSubtransactionDraft(subtransaction: $0, preserveID: false) }
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
    if isSplit {
      return subtransactions.reduce(0) { $0 + ($1.amount ?? 0) }
    }
    return direction == .outflow ? -amountMagnitudeMilli : amountMagnitudeMilli
  }

  var splitValidationMessage: String? {
    guard isSplit else { return nil }
    guard subtransactions.count >= 2 else {
      return "A split transaction needs at least two lines."
    }
    guard subtransactions.allSatisfy({ $0.amount != nil }) else {
      return "Enter a signed amount for every split line."
    }
    return nil
  }

  mutating func enableSplit() {
    guard !isSplit else { return }
    subtransactions = [
      TransactionSubtransactionDraft(amountText: MoneyCodec.displayString(for: signedMilliunits, currencyFormat: nil)),
      TransactionSubtransactionDraft(),
    ]
    categoryID = nil
    transferAccountID = nil
  }

  mutating func disableSplit() {
    let total = signedMilliunits
    if total != 0 {
      direction = total < 0 ? .outflow : .inflow
    }
    amountMagnitudeMilli = abs(total)
    subtransactions = []
  }

  var canSave: Bool {
    // Imported zero-value rows may still need a memo, flag, or cleared-state
    // correction. New non-split zero captures remain invalid; zero-net splits
    // are legal YNAB reallocations.
    !accountID.isEmpty && splitValidationMessage == nil && (id != nil || amountMagnitudeMilli > 0 || isSplit)
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
    let hasParentTransfer = transferAccountID != nil
    return TransactionWriteRequest(
      accountID: accountID,
      date: date.isoDateString,
      amount: signedMilliunits,
      payeeID: isSplit && hasParentTransfer ? nil : payeeID,
      payeeName: isSplit && hasParentTransfer ? nil : (trimmedPayee.isEmpty ? nil : trimmedPayee),
      categoryID: isSplit ? nil : categoryID,
      memo: memo.trimmedNil,
      cleared: clearedState,
      approved: true,
      flagColor: flag.rawValue.isEmpty ? nil : flag.rawValue,
      subtransactions: subtransactions.compactMap { $0.writeRequest() }
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
