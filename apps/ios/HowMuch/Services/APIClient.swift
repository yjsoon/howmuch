import Foundation

extension Notification.Name {
  /// Posted when a request made with a saved session proves that the session
  /// is no longer accepted by the server. AppModel owns the transition back
  /// to the connection screen; the client remains usable by sign-in flows.
  static let howMuchAuthenticationExpired = Notification.Name("HowMuch.AuthenticationExpired")
}

enum APIClientError: LocalizedError {
  case invalidBaseURL
  case invalidResponse
  case server(String)
  case reconciliationMismatch(ReconciliationMismatchDetail)
  case accountPreferencesConflict
  case endpointUnsupported
  case httpStatus(Int)
  case authenticationExpired
  case decoding(String)
  case validation(String)

  var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return "Enter a valid API base URL."
    case .invalidResponse:
      return "The API returned an invalid response."
    case .server(let message):
      return message
    case .reconciliationMismatch(let detail):
      return detail.message
    case .accountPreferencesConflict:
      return "Account groups changed on another device."
    case .endpointUnsupported:
      return "This server does not support account group sync."
    case .httpStatus(let code):
      return "The API request failed with status \(code)."
    case .authenticationExpired:
      return "Your session has expired. Sign in again."
    case .decoding(let message):
      return "Could not decode API data: \(message)"
    case .validation(let message):
      return message
    }
  }
}

struct APIClient {
  let settings: APISettings
  private static let transactionPageSize = 100

  func fetchAuthStatus() async throws -> AuthStatusPayload {
    let response: APIEnvelope<AuthStatusPayload> = try await request(path: "/api/auth/status")
    return response.data
  }

  func login(username: String, password: String) async throws -> AuthTokenPayload {
    let response: APIEnvelope<AuthTokenPayload> = try await request(
      path: "/api/auth/token",
      method: "POST",
      body: LoginRequest(username: username, password: password)
    )
    return response.data
  }

  func logout() async throws {
    let _: APIEnvelope<LogoutPayload> = try await request(
      path: "/api/auth/logout",
      method: "POST",
      body: EmptyRequest()
    )
  }

  func fetchReferenceData(planID: String) async throws -> ReferenceData {
    async let planSettings = fetchPlanSettings(planID: planID)
    async let accounts = fetchAccounts(planID: planID)
    async let categories = fetchCategories(planID: planID)
    async let payees = fetchPayees(planID: planID)
    async let accountPreferences = fetchAccountPreferences(planID: planID)

    return try await ReferenceData(
      planSettings: planSettings,
      accounts: accounts,
      categoryGroups: categories,
      payees: payees,
      accountPreferences: accountPreferences
    )
  }

  /// Cheap connectivity and auth check used by the settings sheet.
  func fetchUser() async throws -> APIUser {
    let response: APIEnvelope<UserPayload> = try await request(path: "/v1/user")
    return response.data.user
  }

  func fetchPlans() async throws -> [PlanSummary] {
    let response: APIEnvelope<PlansPayload> = try await request(path: "/v1/plans")
    return response.data.plans
  }

  func fetchPlanSettings(planID: String) async throws -> PlanSettings {
    let response: APIEnvelope<PlanSettingsPayload> = try await request(path: "/v1/plans/\(planID)/settings")
    return response.data.settings
  }

  func fetchAccounts(planID: String) async throws -> [Account] {
    let response: APIEnvelope<AccountsPayload> = try await request(path: "/v1/plans/\(planID)/accounts")
    return response.data.accounts.filter { !$0.deleted }
  }

  func updateAccountIcon(planID: String, accountID: String, icon: String) async throws -> Account {
    try await updateAccount(planID: planID, accountID: accountID, icon: icon, name: nil)
  }

  func updateAccount(planID: String, accountID: String, icon: String, name: String?) async throws -> Account {
    let response: APIEnvelope<AccountPayload> = try await request(
      path: "/v1/plans/\(planID)/accounts/\(accountID)",
      method: "PATCH",
      body: AccountIconWriteRequest(icon: icon, name: name)
    )
    return response.data.account
  }

  func fetchAccountPreferences(planID: String) async throws -> SyncedAccountPreferences? {
    do {
      let response: APIEnvelope<AccountPreferencesPayload> = try await request(
        path: "/v1/plans/\(planID)/account_preferences"
      )
      guard let preferences = response.data.accountPreferences else { return nil }
      return SyncedAccountPreferences(
        preferences: preferences.presentationPreferences,
        revision: response.data.accountPreferencesRevision
      )
    } catch APIClientError.endpointUnsupported {
      return nil
    }
  }

  func updateAccountPreferences(
    planID: String,
    preferences: AccountPresentationPreferences,
    expectedRevision: Int
  ) async throws -> SyncedAccountPreferences {
    let response: APIEnvelope<AccountPreferencesPayload> = try await request(
      path: "/v1/plans/\(planID)/account_preferences",
      method: "PUT",
      body: AccountPreferencesWriteRequest(
        accountPreferences: APIAccountPreferences(preferences),
        expectedRevision: expectedRevision
      )
    )
    guard let saved = response.data.accountPreferences else {
      throw APIClientError.invalidResponse
    }
    return SyncedAccountPreferences(
      preferences: saved.presentationPreferences,
      revision: response.data.accountPreferencesRevision
    )
  }

  func fetchCategories(planID: String) async throws -> [CategoryGroup] {
    let response: APIEnvelope<CategoriesPayload> = try await request(path: "/v1/plans/\(planID)/categories")
    return response.data.categoryGroups.filter { !$0.deleted }
  }

  func fetchPayees(planID: String) async throws -> [Payee] {
    let response: APIEnvelope<PayeesPayload> = try await request(path: "/v1/plans/\(planID)/payees")
    return response.data.payees.filter { $0.deleted != true }
  }

  func fetchPlanMonth(planID: String, month: String) async throws -> PlanMonth {
    let response: APIEnvelope<PlanMonthPayload> = try await request(
      path: "/v1/plans/\(planID)/months/\(month)"
    )
    return response.data.month
  }

  func setPlanMonthCategoryAssignment(
    planID: String,
    month: String,
    categoryID: String,
    budgeted: Int,
  ) async throws -> PlanMonth {
    let response: APIEnvelope<PlanMonthPayload> = try await request(
      path: "/v1/plans/\(planID)/months/\(month)/categories/\(categoryID)",
      method: "PATCH",
      body: PlanAssignmentRequest(budgeted: budgeted)
    )
    return response.data.month
  }

  func setPlanMonthCategoryTarget(
    planID: String,
    month: String,
    categoryID: String,
    target: PlanTargetPayload?
  ) async throws -> PlanMonth {
    let response: APIEnvelope<PlanMonthPayload> = try await request(
      path: "/v1/plans/\(planID)/months/\(month)/categories/\(categoryID)",
      method: "PATCH",
      body: PlanTargetRequest(target: target)
    )
    return response.data.month
  }

  func restorePlanMonthCategoryTarget(planID: String, month: String, categoryID: String) async throws -> PlanMonth {
    let response: APIEnvelope<PlanMonthPayload> = try await request(
      path: "/v1/plans/\(planID)/months/\(month)/categories/\(categoryID)",
      method: "PATCH",
      body: PlanTargetRestoreRequest()
    )
    return response.data.month
  }

  func fetchTransactions(
    planID: String,
    offset: Int = 0,
    sinceDate: String? = nil,
    untilDate: String? = nil,
    type: String? = nil
  ) async throws -> TransactionPage {
    var queryItems = [
      URLQueryItem(name: "limit", value: String(Self.transactionPageSize)),
      URLQueryItem(name: "offset", value: String(offset)),
    ]
    if let sinceDate {
      queryItems.append(URLQueryItem(name: "since_date", value: sinceDate))
    }
    if let untilDate {
      queryItems.append(URLQueryItem(name: "until_date", value: untilDate))
    }
    if let type {
      queryItems.append(URLQueryItem(name: "type", value: type))
    }
    let response: APIEnvelope<TransactionsPayload> = try await request(
      path: "/v1/plans/\(planID)/transactions",
      queryItems: queryItems
    )
    return TransactionPage(
      transactions: response.data.transactions.filter { !$0.deleted },
      hasMore: response.data.hasMore ?? false,
      nextOffset: response.data.nextOffset,
      serverKnowledge: response.data.serverKnowledge
    )
  }

  func fetchAllUnapprovedTransactions(planID: String) async throws -> [Transaction] {
    for _ in 0..<3 {
      var transactions: [String: Transaction] = [:]
      var expectedKnowledge: Int?
      var offset = 0
      var changed = false
      while true {
        let page = try await fetchTransactions(planID: planID, offset: offset, type: "unapproved")
        guard let knowledge = page.serverKnowledge else {
          throw APIClientError.invalidResponse
        }
        if let expectedKnowledge, knowledge != expectedKnowledge {
          changed = true
          break
        }
        expectedKnowledge = knowledge
        for transaction in page.transactions {
          transactions[transaction.id] = transaction
        }
        guard page.hasMore, let nextOffset = page.nextOffset else {
          return transactions.values.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
        }
        offset = nextOffset
      }
      if !changed {
        return transactions.values.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
      }
    }
    throw APIClientError.server("Transactions changed while the approval queue was loading. Try again.")
  }

  func fetchScheduledTransactions(planID: String) async throws -> [ScheduledTransaction] {
    let response: APIEnvelope<ScheduledTransactionsPayload> = try await request(
      path: "/v1/plans/\(planID)/scheduled_transactions"
    )
    return response.data.scheduledTransactions.filter { !$0.deleted }
  }

  func createScheduledTransaction(planID: String, idempotencyKey: String, request scheduledTransaction: ScheduledTransactionWriteRequest) async throws -> ScheduledTransaction {
    let response: APIEnvelope<ScheduledTransactionPayload> = try await request(
      path: "/v1/plans/\(planID)/scheduled_transactions",
      method: "POST",
      headers: ["Idempotency-Key": idempotencyKey],
      body: ScheduledTransactionWriteEnvelope(scheduledTransaction: scheduledTransaction)
    )
    return response.data.scheduledTransaction
  }

  func updateScheduledTransaction(planID: String, scheduleID: String, idempotencyKey: String, request scheduledTransaction: ScheduledTransactionWriteRequest) async throws -> ScheduledTransaction {
    let response: APIEnvelope<ScheduledTransactionPayload> = try await request(
      path: "/v1/plans/\(planID)/scheduled_transactions/\(scheduleID)",
      method: "PATCH",
      headers: ["Idempotency-Key": idempotencyKey],
      body: ScheduledTransactionWriteEnvelope(scheduledTransaction: scheduledTransaction)
    )
    return response.data.scheduledTransaction
  }

  func deleteScheduledTransaction(planID: String, scheduleID: String, idempotencyKey: String) async throws -> ScheduledTransaction {
    let response: APIEnvelope<ScheduledTransactionPayload> = try await request(
      path: "/v1/plans/\(planID)/scheduled_transactions/\(scheduleID)",
      method: "DELETE",
      headers: ["Idempotency-Key": idempotencyKey]
    )
    return response.data.scheduledTransaction
  }

  func materializeScheduledOccurrence(
    planID: String,
    scheduleID: String,
    idempotencyKey: String,
    occurrenceDate: String,
    enteredDate: String
  ) async throws -> ScheduledOccurrencePayload {
    let response: APIEnvelope<ScheduledOccurrencePayload> = try await request(
      path: "/v1/plans/\(planID)/scheduled_transactions/\(scheduleID)/materialize",
      method: "POST",
      headers: ["Idempotency-Key": idempotencyKey],
      body: ScheduledOccurrenceRequest(occurrenceDate: occurrenceDate, date: enteredDate)
    )
    return response.data
  }

  func reconcileAccount(
    planID: String,
    accountID: String,
    idempotencyKey: String,
    statementDate: String,
    statementBalance: Int
  ) async throws -> AccountReconciliationPayload {
    let response: APIEnvelope<AccountReconciliationPayload> = try await request(
      path: "/v1/plans/\(planID)/accounts/\(accountID)/reconcile",
      method: "POST",
      headers: ["Idempotency-Key": idempotencyKey],
      body: AccountReconciliationRequest(statementDate: statementDate, statementBalance: statementBalance)
    )
    return response.data
  }

  func fetchAccountReconciliation(
    planID: String,
    accountID: String,
    statementDate: String
  ) async throws -> AccountReconciliationPreview {
    let response: APIEnvelope<AccountReconciliationPreview> = try await request(
      path: "/v1/plans/\(planID)/accounts/\(accountID)/reconciliation",
      queryItems: [URLQueryItem(name: "statement_date", value: statementDate)]
    )
    return response.data
  }

  func fetchSpendingBreakdown(
    planID: String,
    from: String?,
    to: String?,
    accountIDs: [String] = [],
    categoryIDs: [String] = []
  ) async throws -> SpendingBreakdownReport {
    try await report(
      path: "/api/reports/spending-breakdown", planID: planID, from: from, to: to,
      interval: nil, accountIDs: accountIDs, categoryIDs: categoryIDs
    )
  }

  func fetchIncomeVsSpending(
    planID: String,
    from: String?,
    to: String?,
    interval: ReportInterval,
    accountIDs: [String] = [],
    categoryIDs: [String] = []
  ) async throws -> IncomeVsSpendingReport {
    try await report(
      path: "/api/reports/income-vs-spending", planID: planID, from: from, to: to,
      interval: interval.rawValue, accountIDs: accountIDs, categoryIDs: categoryIDs
    )
  }

  func fetchNetWorth(
    planID: String,
    from: String?,
    to: String?,
    interval: ReportInterval,
    accountIDs: [String] = []
  ) async throws -> NetWorthReport {
    try await report(
      path: "/api/reports/net-worth", planID: planID, from: from, to: to,
      interval: interval.rawValue, accountIDs: accountIDs
    )
  }

  /// Deliberately takes no date range: the server replays income lots from
  /// `from`, so the weighted age is only honest over the full history.
  func fetchAgeOfMoney(planID: String, interval: ReportInterval, accountIDs: [String] = []) async throws -> AgeOfMoneyReport {
    try await report(
      path: "/api/reports/age-of-money", planID: planID, from: nil, to: nil,
      interval: interval.rawValue, accountIDs: accountIDs
    )
  }

  func createTransaction(planID: String, request body: TransactionWriteRequest) async throws -> Transaction {
    let response: APIEnvelope<TransactionPayload> = try await request(
      path: "/v1/plans/\(planID)/transactions",
      method: "POST",
      body: TransactionWriteEnvelope(transaction: body)
    )
    return response.data.transaction
  }

  func updateTransaction(planID: String, transactionID: String, request body: TransactionWriteRequest) async throws -> Transaction {
    let response: APIEnvelope<TransactionPayload> = try await request(
      path: "/v1/plans/\(planID)/transactions/\(transactionID)",
      method: "PUT",
      body: TransactionWriteEnvelope(transaction: body)
    )
    return response.data.transaction
  }

  func approveTransaction(planID: String, transactionID: String) async throws -> Transaction {
    let response: APIEnvelope<TransactionPayload> = try await request(
      path: "/v1/plans/\(planID)/transactions/\(transactionID)",
      method: "PATCH",
      body: TransactionApprovalEnvelope(transaction: TransactionApprovalRequest(approved: true))
    )
    return response.data.transaction
  }

  func updateTransactionCleared(
    planID: String,
    transactionID: String,
    expectedCleared: ClearedState,
    cleared: ClearedState
  ) async throws -> Transaction {
    let response: APIEnvelope<TransactionPayload> = try await request(
      path: "/v1/plans/\(planID)/transactions/\(transactionID)/cleared",
      method: "PATCH",
      body: ClearedUpdateRequest(expectedCleared: expectedCleared, cleared: cleared)
    )
    return response.data.transaction
  }

  func deleteTransaction(planID: String, transactionID: String, expectedApproved: Bool? = nil) async throws -> Transaction {
    let expectation = expectedApproved.map { "?expected_approved=\($0)" } ?? ""
    let response: APIEnvelope<TransactionPayload> = try await request(
      path: "/v1/plans/\(planID)/transactions/\(transactionID)\(expectation)",
      method: "DELETE"
    )
    return response.data.transaction
  }

  private func report<Payload: Decodable>(
    path: String,
    planID: String,
    from: String?,
    to: String?,
    interval: String?,
    accountIDs: [String] = [],
    categoryIDs: [String] = []
  ) async throws -> Payload {
    // plan_id is mandatory on every report call: without it the API silently
    // answers for its configured default plan.
    var queryItems = [URLQueryItem(name: "plan_id", value: planID)]
    if let from {
      queryItems.append(URLQueryItem(name: "from", value: from))
    }
    if let to {
      queryItems.append(URLQueryItem(name: "to", value: to))
    }
    if let interval {
      queryItems.append(URLQueryItem(name: "interval", value: interval))
    }
    if !accountIDs.isEmpty {
      queryItems.append(URLQueryItem(name: "account_ids", value: accountIDs.sorted().joined(separator: ",")))
    }
    if !categoryIDs.isEmpty {
      queryItems.append(URLQueryItem(name: "category_ids", value: categoryIDs.sorted().joined(separator: ",")))
    }

    let response: APIEnvelope<Payload> = try await request(path: path, queryItems: queryItems)
    return response.data
  }

  private func request<Payload: Decodable>(
    path: String,
    queryItems: [URLQueryItem] = [],
    method: String = "GET",
    headers: [String: String] = [:]
  ) async throws -> Payload {
    try await executeRequest(path: path, queryItems: queryItems, method: method, headers: headers, bodyData: nil)
  }

  private func request<Payload: Decodable, Body: Encodable>(
    path: String,
    queryItems: [URLQueryItem] = [],
    method: String = "GET",
    headers: [String: String] = [:],
    body: Body
  ) async throws -> Payload {
    try await executeRequest(path: path, queryItems: queryItems, method: method, headers: headers, bodyData: try encoder.encode(body))
  }

  private func executeRequest<Payload: Decodable>(
    path: String,
    queryItems: [URLQueryItem] = [],
    method: String = "GET",
    headers: [String: String] = [:],
    bodyData: Data?
  ) async throws -> Payload {
    let url = try makeURL(path: path, queryItems: queryItems)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }

    let trimmedToken = settings.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let requestHasSession = !trimmedToken.isEmpty
    if !trimmedToken.isEmpty {
      request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
    }

    if let bodyData {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = bodyData
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIClientError.invalidResponse
    }

    guard (200 ..< 300).contains(httpResponse.statusCode) else {
      if httpResponse.statusCode == 404, path.hasSuffix("/account_preferences") {
        throw APIClientError.endpointUnsupported
      }
      if let serverError = try? decoder.decode(ServerErrorEnvelope.self, from: data) {
        // Login failures are intentionally not treated as session expiry: the
        // settings sheet uses a tokenless client to authenticate. For an
        // already-authenticated request, 401 (or the API's auth-shaped 403)
        // means every surface must return to sign-in together.
        let authFailure = requestHasSession &&
          (httpResponse.statusCode == 401 ||
           (httpResponse.statusCode == 403 && serverError.error.name == "not_authorized"))
        if authFailure {
          NotificationCenter.default.post(name: .howMuchAuthenticationExpired, object: trimmedToken)
          throw APIClientError.authenticationExpired
        }
        if serverError.error.name == "reconciliation_mismatch",
           let current = serverError.error.currentReconciledBalance,
           let projected = serverError.error.projectedReconciledBalance,
           let statement = serverError.error.statementBalance,
           let difference = serverError.error.difference {
          throw APIClientError.reconciliationMismatch(
            ReconciliationMismatchDetail(
              currentReconciledBalance: current,
              projectedReconciledBalance: projected,
              statementBalance: statement,
              difference: difference,
              message: serverError.error.detail
            )
          )
        }
        if serverError.error.name == "account_preferences_conflict" {
          throw APIClientError.accountPreferencesConflict
        }
        throw APIClientError.server(serverError.error.detail)
      }
      if requestHasSession && httpResponse.statusCode == 401 {
        NotificationCenter.default.post(name: .howMuchAuthenticationExpired, object: trimmedToken)
        throw APIClientError.authenticationExpired
      }
      throw APIClientError.httpStatus(httpResponse.statusCode)
    }

    do {
      return try decoder.decode(Payload.self, from: data)
    } catch {
      throw APIClientError.decoding(error.localizedDescription)
    }
  }

  private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
    guard let baseURL = settings.baseURL,
          var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else {
      throw APIClientError.invalidBaseURL
    }

    let requestPath = Self.encodedPath(path)
    let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.percentEncodedPath = basePath.isEmpty ? requestPath : "/\(basePath)\(requestPath)"
    components.queryItems = queryItems.isEmpty ? nil : queryItems

    guard let url = components.url else {
      throw APIClientError.invalidBaseURL
    }
    return url
  }

  private static func encodedPath(_ path: String) -> String {
    let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
    let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map { segment in
      segment.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
        ?? String(segment)
    }
    return "/" + segments.joined(separator: "/")
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }
}

private struct ClearedUpdateRequest: Encodable {
  let expectedCleared: ClearedState
  let cleared: ClearedState
}

private struct LoginRequest: Encodable {
  let username: String
  let password: String
}

private struct EmptyRequest: Encodable {}

private struct LogoutPayload: Decodable {
  let ok: Bool
}

extension Error {
  /// Failures where the request provably never reached the server — the only
  /// cases safe to queue for replay. Timeouts and dropped connections are
  /// deliberately excluded: the server may have committed the write before
  /// the failure, and replaying would double-post money.
  var isOfflineError: Bool {
    guard let urlError = self as? URLError else {
      return false
    }
    switch urlError.code {
    case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
         .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
      return true
    default:
      return false
    }
  }
}
