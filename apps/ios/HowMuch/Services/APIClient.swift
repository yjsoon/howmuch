import Foundation

extension Notification.Name {
  /// Posted when a request made with a saved session proves that the session
  /// is no longer accepted by the server. AppModel owns the transition back
  /// to the connection screen; the client remains usable by sign-in flows.
  static let howMuchAuthenticationExpired = Notification.Name("HowMuch.AuthenticationExpired")
}

struct BulkApprovalError: LocalizedError {
  let approvedCount: Int
  let underlying: Error?

  init(approvedCount: Int, underlying: Error? = nil) {
    self.approvedCount = approvedCount
    self.underlying = underlying
  }

  var errorDescription: String? {
    underlying?.localizedDescription ?? "Couldn’t approve transactions."
  }
}

enum APIClientError: LocalizedError {
  case invalidBaseURL
  case invalidResponse
  case server(String)
  /// 409 `conflict`: the entity already exists or changed underneath the
  /// request. Its message is the server's, exactly as `.server` would show it.
  case conflict(String)
  case reconciliationMismatch(ReconciliationMismatchDetail)
  case accountPreferencesConflict
  case endpointUnsupported
  case httpStatus(Int)
  case authenticationExpired
  case decoding(String)
  case validation(String)
  /// 409 `plan_not_empty` from `import_snapshot`: the plan already holds a
  /// ledger, so a snapshot cannot be imported into it.
  case planNotEmpty(String)
  /// 409 `ynab_mirror_plan` from `import_snapshot`: the plan mirrors YNAB.
  case ynabMirrorPlan(String)
  /// 403 from `import_snapshot`: only the plan's owner may import.
  case ownerRequired(String)
  /// 413 `payload_too_large`.
  case payloadTooLarge

  var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return "Enter a valid API base URL."
    case .invalidResponse:
      return "The API returned an invalid response."
    case .server(let message), .conflict(let message):
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
    case .validation(let message), .planNotEmpty(let message), .ynabMirrorPlan(let message), .ownerRequired(let message):
      return message
    case .payloadTooLarge:
      return "This is too much to send in one go."
    }
  }
}

struct APIClient {
  let settings: APISettings
  private static let transactionPageSize = 100
  /// The largest request body `import_snapshot` accepts.
  static let snapshotByteLimit = 8 * 1024 * 1024

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

  func updateAccount(planID: String, accountID: String, name: String?, icon: String?, type: String?) async throws -> Account {
    let response: APIEnvelope<AccountPayload> = try await request(
      path: "/v1/plans/\(planID)/accounts/\(accountID)",
      method: "PATCH",
      body: AccountUpdateRequest(name: name, icon: icon, type: type)
    )
    return response.data.account
  }

  func createAccount(
    planID: String,
    name: String,
    type: String,
    balance: Int,
    icon: String?,
    onBudget: Bool
  ) async throws -> Account {
    let response: APIEnvelope<AccountPayload> = try await request(
      path: "/v1/plans/\(planID)/accounts",
      method: "POST",
      body: AccountCreateRequest(
        name: name,
        type: type,
        balance: balance,
        icon: icon,
        onBudget: onBudget
      )
    )
    return response.data.account
  }

  func fetchAccountPreferences(planID: String) async throws -> SyncedAccountPreferences? {
    // Account preferences sync between a user's devices. The on-device engine
    // has one device and no user principal (it answers 403), and the app
    // already keeps the same preferences locally.
    guard !settings.isLocal else {
      return nil
    }
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
    guard !settings.isLocal else {
      throw APIClientError.endpointUnsupported
    }
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

  /// Creates a category group on a HowMuch-native plan. The id is chosen here,
  /// so a retried create cannot make a second group.
  func createCategoryGroup(planID: String, id: String, name: String) async throws {
    let _: APIEnvelope<IgnoredPayload> = try await request(
      path: "/v1/plans/\(planID)/category_groups",
      method: "POST",
      headers: ["Idempotency-Key": id],
      body: CategoryGroupCreateRequest(categoryGroup: .init(id: id, name: name))
    )
  }

  func createCategory(planID: String, id: String, groupID: String, name: String) async throws {
    let _: APIEnvelope<IgnoredPayload> = try await request(
      path: "/v1/plans/\(planID)/categories",
      method: "POST",
      headers: ["Idempotency-Key": id],
      body: CategoryCreateRequest(category: .init(id: id, categoryGroupId: groupID, name: name))
    )
  }

  func fetchPayees(planID: String) async throws -> [Payee] {
    let response: APIEnvelope<PayeesPayload> = try await request(path: "/v1/plans/\(planID)/payees")
    return response.data.payees.filter { $0.deleted != true }
  }

  func fetchTransactions(
    planID: String,
    accountID: String? = nil,
    offset: Int = 0,
    sinceDate: String? = nil,
    untilDate: String? = nil,
    type: String? = nil,
    q: String? = nil,
    limit: Int = transactionPageSize
  ) async throws -> TransactionPage {
    var queryItems = [
      URLQueryItem(name: "limit", value: String(limit)),
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
    if let q, !q.isEmpty {
      queryItems.append(URLQueryItem(name: "q", value: q))
    }
    let path = accountID.map { "/v1/plans/\(planID)/accounts/\($0)/transactions" }
      ?? "/v1/plans/\(planID)/transactions"
    let response: APIEnvelope<TransactionsPayload> = try await request(
      path: path,
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

  func fetchTransaction(planID: String, transactionID: String) async throws -> Transaction {
    let response: APIEnvelope<TransactionPayload> = try await request(
      path: "/v1/plans/\(planID)/transactions/\(transactionID)"
    )
    return response.data.transaction
  }

  /// How many live unapproved rows the plan has, without fetching any of them.
  /// One bounded server-side count, so launch no longer waits on a full walk of
  /// the queue just to label the inbox.
  func fetchUnapprovedCount(planID: String, accountID: String? = nil) async throws -> Int {
    let path = accountID.map { "/v1/plans/\(planID)/accounts/\($0)/transactions/unapproved_count" }
      ?? "/v1/plans/\(planID)/transactions/unapproved_count"
    let response: APIEnvelope<UnapprovedCountPayload> = try await request(path: path)
    return response.data.count
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

  func fetchRewards(
    planID: String,
    from: String?,
    to: String?,
    accountIDs: [String] = [],
    group: RewardGroupBy
  ) async throws -> RewardsReport {
    try await report(
      path: "/api/reports/rewards", planID: planID, from: from, to: to,
      interval: nil, accountIDs: accountIDs, group: group.rawValue
    )
  }

  func fetchRewardsTrackerSnapshot(planID: String) async throws -> RewardsTrackerSnapshot {
    let response: APIEnvelope<RewardsTrackerSnapshot> = try await request(
      path: "/api/import/rewards-tracker",
      queryItems: [URLQueryItem(name: "plan_id", value: planID)]
    )
    return response.data
  }

  func importRewardsTracker(planID: String, payloadJSON: Data) async throws -> RewardsTrackerImportResult {
    let payload = try RewardsImportFile.wholeSettings(payloadJSON)
    let body = try JSONSerialization.data(withJSONObject: [
      "plan_id": planID,
      "payload": payload,
    ])
    let response: APIEnvelope<RewardsTrackerImportResult> = try await executeRequest(
      path: "/api/import/rewards-tracker",
      method: "POST",
      bodyData: body
    )
    return response.data
  }

  func importRewardsAccountConfig(planID: String, accountID: String, payloadJSON: Data) async throws -> CreditCard {
    _ = try RewardsImportFile.accountConfig(payloadJSON)
    // JSONSerialization preserves absent keys, explicit nulls and unknown configuration.
    // CreditCard decoding/encoding would silently normalise those distinctions.
    let payload = try JSONSerialization.jsonObject(with: payloadJSON)
    let body = try JSONSerialization.data(withJSONObject: ["plan_id": planID, "payload": payload])
    let response: APIEnvelope<RewardCardPayload> = try await executeRequest(
      path: "/api/rewards/accounts", appendedPathSegments: [accountID, "config"], method: "PUT", bodyData: body
    )
    return response.data.card
  }

  func createRewardCard(planID: String, card: CreditCard) async throws -> CreditCard {
    let response: APIEnvelope<RewardCardPayload> = try await executeRequest(
      path: "/api/rewards/cards",
      method: "POST",
      bodyData: try rewardCardBody(planID: planID, card: card, clearMissing: false)
    )
    return response.data.card
  }

  func updateRewardCard(planID: String, cardID: String, card: CreditCard) async throws -> CreditCard {
    let response: APIEnvelope<RewardCardPayload> = try await executeRequest(
      path: "/api/rewards/cards/\(cardID)",
      method: "PATCH",
      bodyData: try rewardCardBody(planID: planID, card: card, clearMissing: true)
    )
    return response.data.card
  }

  func deleteRewardCard(planID: String, cardID: String) async throws -> CreditCard {
    let body = try JSONSerialization.data(withJSONObject: ["plan_id": planID])
    let response: APIEnvelope<RewardCardPayload> = try await executeRequest(
      path: "/api/rewards/cards/\(cardID)",
      method: "DELETE",
      bodyData: body
    )
    return response.data.card
  }

  func updateRewardSettings(planID: String, milesValuation: Double) async throws -> RewardSettings {
    let body = try JSONSerialization.data(withJSONObject: [
      "plan_id": planID,
      "milesValuation": milesValuation,
    ])
    let response: APIEnvelope<RewardSettingsPayload> = try await executeRequest(
      path: "/api/rewards/settings",
      method: "PATCH",
      bodyData: body
    )
    return response.data.settings
  }

  private func rewardCardBody(planID: String, card: CreditCard, clearMissing: Bool) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "plan_id": planID,
      "card": card.jsonObject(clearMissing: clearMissing),
    ])
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

  func approveTransactionBatch(planID: String, transactionIDs: [String]) async throws -> [Transaction] {
    guard !transactionIDs.isEmpty else {
      throw APIClientError.validation("Transaction approval batch must not be empty.")
    }
    guard transactionIDs.count <= RegisterApproval.batchLimit else {
      throw APIClientError.validation(
        "Transaction approval batch cannot exceed \(RegisterApproval.batchLimit) items."
      )
    }
    let response: APIEnvelope<TransactionCollectionPayload> = try await request(
      path: "/v1/plans/\(planID)/transactions",
      method: "PATCH",
      body: TransactionCollectionApprovalEnvelope(
        transactions: transactionIDs.map { .init(id: $0, approved: true) }
      )
    )
    return response.data.transactions
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
    var queryItems: [URLQueryItem] = []
    if let expectedApproved {
      queryItems.append(URLQueryItem(name: "expected_approved", value: expectedApproved ? "true" : "false"))
    }
    let response: APIEnvelope<TransactionPayload> = try await request(
      path: "/v1/plans/\(planID)/transactions/\(transactionID)",
      queryItems: queryItems,
      method: "DELETE"
    )
    return response.data.transaction
  }

  /// The plan's whole ledger in the `howmuch-plan-snapshot` format, as JSON
  /// bytes. The snapshot object is re-serialised with `JSONSerialization`
  /// (sorted keys, so the same ledger always gives the same bytes), never
  /// through models: this client's snake-case coding would rename its keys.
  func exportSnapshot(planID: String) async throws -> Data {
    let data = try await executeRawRequest(path: "/v1/plans/\(planID)/export_snapshot", bodyData: nil)
    return try SnapshotImport.snapshot(fromExportResponse: data)
  }

  /// Imports snapshot bytes (from `exportSnapshot`) into an empty plan.
  /// Returns whether the server replayed an earlier import with this key.
  @discardableResult
  func importSnapshot(planID: String, idempotencyKey: String, snapshot: Data) async throws -> Bool {
    let data = try await executeRawRequest(
      path: "/v1/plans/\(planID)/import_snapshot",
      method: "POST",
      headers: ["Idempotency-Key": idempotencyKey],
      bodyData: SnapshotImport.requestBody(snapshot: snapshot)
    )
    do {
      return try decoder.decode(APIEnvelope<SnapshotImportPayload>.self, from: data).data.replayed
    } catch {
      throw APIClientError.decoding(error.localizedDescription)
    }
  }

  private func report<Payload: Decodable>(
    path: String,
    planID: String,
    from: String?,
    to: String?,
    interval: String?,
    accountIDs: [String] = [],
    categoryIDs: [String] = [],
    group: String? = nil
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
    if let group {
      queryItems.append(URLQueryItem(name: "group", value: group))
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
    appendedPathSegments: [String] = [],
    queryItems: [URLQueryItem] = [],
    method: String = "GET",
    headers: [String: String] = [:],
    bodyData: Data?
  ) async throws -> Payload {
    let data = try await executeRawRequest(
      path: path,
      appendedPathSegments: appendedPathSegments,
      queryItems: queryItems,
      method: method,
      headers: headers,
      bodyData: bodyData
    )
    do {
      return try decoder.decode(Payload.self, from: data)
    } catch {
      throw APIClientError.decoding(error.localizedDescription)
    }
  }

  /// Sends one request and maps a failure status to `APIClientError`.
  /// Returns a successful response's body undecoded.
  private func executeRawRequest(
    path: String,
    appendedPathSegments: [String] = [],
    queryItems: [URLQueryItem] = [],
    method: String = "GET",
    headers: [String: String] = [:],
    bodyData: Data?
  ) async throws -> Data {
    let url = try makeURL(path: path, appendedPathSegments: appendedPathSegments, queryItems: queryItems)
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

    let (data, response) = try await send(request)
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
          postAuthenticationExpiry(token: trimmedToken)
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
        if httpResponse.statusCode == 409, serverError.error.name == "conflict" {
          throw APIClientError.conflict(serverError.error.detail)
        }
        if path.hasSuffix("/import_snapshot") {
          switch (httpResponse.statusCode, serverError.error.name) {
          case (409, "plan_not_empty"):
            throw APIClientError.planNotEmpty(serverError.error.detail)
          case (409, "ynab_mirror_plan"):
            throw APIClientError.ynabMirrorPlan(serverError.error.detail)
          case (403, _):
            throw APIClientError.ownerRequired(serverError.error.detail)
          default:
            break
          }
        }
        if httpResponse.statusCode == 413 {
          throw APIClientError.payloadTooLarge
        }
        throw APIClientError.server(serverError.error.detail)
      }
      if requestHasSession && httpResponse.statusCode == 401 {
        postAuthenticationExpiry(token: trimmedToken)
        throw APIClientError.authenticationExpired
      }
      if httpResponse.statusCode == 413 {
        throw APIClientError.payloadTooLarge
      }
      throw APIClientError.httpStatus(httpResponse.statusCode)
    }
    return data
  }

  /// Signs every surface out of a server session the server stopped
  /// accepting. The on-device engine has no session to lose: its token is
  /// repaired on load, so local mode never signs out here.
  private func postAuthenticationExpiry(token: String) {
    guard !settings.isLocal else {
      return
    }
    NotificationCenter.default.post(name: .howMuchAuthenticationExpired, object: token)
  }

  /// The one transport seam. Local mode hands the same request to the
  /// embedded engine; the response goes through the same decoding and error
  /// mapping either way. Engine failures are not `URLError`s, so they are
  /// never mistaken for offline writes and queued for replay.
  private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
    guard settings.isLocal else {
      return try await URLSession.shared.data(for: request)
    }
    guard
      let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      throw APIClientError.invalidBaseURL
    }
    let result = try await LocalEngine.shared.handle(
      config: settings.localEngineConfig,
      method: request.httpMethod ?? "GET",
      path: components.percentEncodedPath,
      query: components.percentEncodedQuery,
      headers: request.allHTTPHeaderFields ?? [:],
      body: request.httpBody
    )
    guard let response = HTTPURLResponse(
      url: url,
      statusCode: result.status,
      httpVersion: "HTTP/1.1",
      headerFields: result.headers
    ) else {
      throw APIClientError.invalidResponse
    }
    return (result.body, response)
  }

  private func makeURL(path: String, appendedPathSegments: [String], queryItems: [URLQueryItem]) throws -> URL {
    guard let baseURL = settings.baseURL,
          var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else {
      throw APIClientError.invalidBaseURL
    }

    // Dynamic IDs are opaque segments: a slash or percent sign belongs to the
    // identifier, not the route. Match encodeURIComponent's ASCII allowlist.
    let segmentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    let suffix = try appendedPathSegments.map { segment in
      guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: segmentCharacters) else {
        throw APIClientError.invalidBaseURL
      }
      return "/" + encoded
    }.joined()
    let requestPath = Self.encodedPath(path) + suffix
    let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.percentEncodedPath = basePath.isEmpty ? requestPath : "/\(basePath)\(requestPath)"
    components.queryItems = queryItems.isEmpty ? nil : queryItems

    guard let url = components.url else {
      throw APIClientError.invalidBaseURL
    }
    return url
  }

  /// Encodes path segments only. Put query in `queryItems`, not in `path` —
  /// `?` is not url-path-allowed, so it becomes `%3F` and the server 404s.
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

/// A response whose payload the caller does not read.
private struct IgnoredPayload: Decodable {}

private struct CategoryGroupCreateRequest: Encodable {
  struct Group: Encodable {
    let id: String
    let name: String
  }

  let categoryGroup: Group
}

private struct CategoryCreateRequest: Encodable {
  struct NewCategory: Encodable {
    let id: String
    let categoryGroupId: String
    let name: String
  }

  let category: NewCategory
}

private struct LogoutPayload: Decodable {
  let ok: Bool
}

private struct SnapshotImportPayload: Decodable {
  let replayed: Bool
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
