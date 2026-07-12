import Foundation

enum APIClientError: LocalizedError {
  case invalidBaseURL
  case invalidResponse
  case server(String)
  case httpStatus(Int)
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
    case .httpStatus(let code):
      return "The API request failed with status \(code)."
    case .decoding(let message):
      return "Could not decode API data: \(message)"
    case .validation(let message):
      return message
    }
  }
}

struct APIClient {
  let settings: APISettings

  func fetchReferenceData(planID: String) async throws -> ReferenceData {
    async let planSettings = fetchPlanSettings(planID: planID)
    async let accounts = fetchAccounts(planID: planID)
    async let categories = fetchCategories(planID: planID)
    async let payees = fetchPayees(planID: planID)

    return try await ReferenceData(
      planSettings: planSettings,
      accounts: accounts,
      categoryGroups: categories,
      payees: payees
    )
  }

  /// Cheap connectivity and auth check used by the settings sheet.
  func fetchUser() async throws -> APIUser {
    let response: APIEnvelope<UserPayload> = try await request(path: "/v1/user")
    return response.data.user
  }

  func fetchPlanSettings(planID: String) async throws -> PlanSettings {
    let response: APIEnvelope<PlanSettingsPayload> = try await request(path: "/v1/plans/\(planID)/settings")
    return response.data.settings
  }

  func fetchAccounts(planID: String) async throws -> [Account] {
    let response: APIEnvelope<AccountsPayload> = try await request(path: "/v1/plans/\(planID)/accounts")
    return response.data.accounts.filter { !$0.deleted }
  }

  func fetchCategories(planID: String) async throws -> [CategoryGroup] {
    let response: APIEnvelope<CategoriesPayload> = try await request(path: "/v1/plans/\(planID)/categories")
    return response.data.categoryGroups.filter { !$0.deleted }
  }

  func fetchPayees(planID: String) async throws -> [Payee] {
    let response: APIEnvelope<PayeesPayload> = try await request(path: "/v1/plans/\(planID)/payees")
    return response.data.payees.filter { $0.deleted != true }
  }

  func fetchTransactions(planID: String) async throws -> [Transaction] {
    let response: APIEnvelope<TransactionsPayload> = try await request(path: "/v1/plans/\(planID)/transactions")
    return response.data.transactions.filter { !$0.deleted }
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

  func deleteTransaction(planID: String, transactionID: String) async throws -> Transaction {
    let response: APIEnvelope<TransactionPayload> = try await request(
      path: "/v1/plans/\(planID)/transactions/\(transactionID)",
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
    method: String = "GET"
  ) async throws -> Payload {
    try await executeRequest(path: path, queryItems: queryItems, method: method, bodyData: nil)
  }

  private func request<Payload: Decodable, Body: Encodable>(
    path: String,
    queryItems: [URLQueryItem] = [],
    method: String = "GET",
    body: Body
  ) async throws -> Payload {
    try await executeRequest(path: path, queryItems: queryItems, method: method, bodyData: try encoder.encode(body))
  }

  private func executeRequest<Payload: Decodable>(
    path: String,
    queryItems: [URLQueryItem] = [],
    method: String = "GET",
    bodyData: Data?
  ) async throws -> Payload {
    let url = try makeURL(path: path, queryItems: queryItems)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let trimmedToken = settings.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
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
      if let serverError = try? decoder.decode(ServerErrorEnvelope.self, from: data) {
        throw APIClientError.server(serverError.error.message)
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
    guard var components = URLComponents(string: settings.trimmedBaseURL) else {
      throw APIClientError.invalidBaseURL
    }

    components.path = path.hasPrefix("/") ? path : "/\(path)"
    components.queryItems = queryItems.isEmpty ? nil : queryItems

    guard let url = components.url else {
      throw APIClientError.invalidBaseURL
    }
    return url
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
