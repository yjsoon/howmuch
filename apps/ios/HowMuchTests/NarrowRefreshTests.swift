import XCTest
@testable import HowMuch

/// Request-level tests for #179 and the iOS half of #180. Every assertion here
/// is about what leaves the device: a write must be followed by one narrow
/// read, a pull on one tab must not fetch another tab's data, and the four
/// reports must not run on launch.
@MainActor
final class NarrowRefreshTests: XCTestCase {
  private var previousCredentialService = ""
  private var previousAPISettings: Any?
  private var previousScopedViewPrefs: Any?
  private var previousOutbox: Any?

  override func setUp() {
    super.setUp()
    previousCredentialService = APISettings.useCredentialService(
      "HowMuch.NarrowRefreshTests.\(UUID().uuidString)"
    )
    // The model writes its connection straight into `UserDefaults.standard`
    // under the app's real keys; save and restore them so this fixture host
    // never leaks into another test or the installed app.
    previousAPISettings = UserDefaults.standard.object(forKey: APISettings.userDefaultsKey)
    previousScopedViewPrefs = UserDefaults.standard.object(
      forKey: ScopedViewPrefsStore.userDefaultsKey
    )
    previousOutbox = UserDefaults.standard.object(forKey: OutboxStore.userDefaultsKey)
    UserDefaults.standard.removeObject(forKey: OutboxStore.userDefaultsKey)
    XCTAssertTrue(URLProtocol.registerClass(NarrowRefreshProtocol.self))
    NarrowRefreshProtocol.reset()
  }

  override func tearDown() {
    URLProtocol.unregisterClass(NarrowRefreshProtocol.self)
    APISettings.useCredentialService(previousCredentialService)
    UserDefaults.standard.set(previousAPISettings, forKey: APISettings.userDefaultsKey)
    UserDefaults.standard.set(previousScopedViewPrefs, forKey: ScopedViewPrefsStore.userDefaultsKey)
    UserDefaults.standard.set(previousOutbox, forKey: OutboxStore.userDefaultsKey)
    super.tearDown()
  }

  // MARK: - #179: a write costs one narrow read

  func testClearedToggleIssuesTheWriteAndAtMostOneRead() async throws {
    let model = makeModel()
    let row = try NarrowRefreshProtocol.unclearedTransaction()

    try await model.toggleTransactionCleared(row)
    _ = await waitUntil { NarrowRefreshProtocol.log().contains { $0.isRead } }

    let requests = NarrowRefreshProtocol.log()
    let writes = requests.filter { !$0.isRead }
    let reads = requests.filter(\.isRead)

    XCTAssertEqual(writes.count, 1, "the toggle must issue exactly one write, saw \(writes)")
    XCTAssertEqual(writes.first?.method, "PATCH")
    XCTAssertTrue(writes.first?.path.hasSuffix("/cleared") == true)
    XCTAssertLessThanOrEqual(
      reads.count,
      1,
      "a cleared toggle must cost at most one follow-up read, saw \(reads)"
    )
    XCTAssertEqual(
      reads.first?.path,
      "/v1/plans/\(NarrowRefreshProtocol.planID)/accounts",
      "the one follow-up read must be the account balances the server recomputed"
    )
    XCTAssertFalse(
      requests.contains { $0.path.hasSuffix("/transactions") },
      "the ledger page and the unapproved scan must not run behind a cleared toggle"
    )
    XCTAssertFalse(
      requests.contains { $0.path.contains("/scheduled_transactions") || $0.path.hasSuffix("/payees") },
      "reference data and schedules cannot change when a row is cleared"
    )
  }

  // MARK: - #179: a pull refreshes its own tab

  func testAccountsPullToRefreshTouchesNoOtherTab() async {
    let model = makeModel()

    await model.refresh(slices: TabRefresh.accounts, quiet: false)

    let requests = NarrowRefreshProtocol.log()
    XCTAssertEqual(
      requests.map(\.path),
      ["/v1/plans/\(NarrowRefreshProtocol.planID)/accounts"],
      "pulling on Accounts must fetch the accounts and nothing else, saw \(requests)"
    )
    XCTAssertTrue(
      NarrowRefreshProtocol.reportRequestCount() == 0,
      "pulling on Accounts must not call any report endpoint"
    )
  }

  func testRegisterPullToRefreshFetchesTheLedgerWithoutReports() async {
    let model = makeModel()

    await model.refresh(slices: TabRefresh.register, quiet: false)

    XCTAssertEqual(NarrowRefreshProtocol.reportRequestCount(), 0)
    XCTAssertTrue(
      NarrowRefreshProtocol.log().contains { $0.path.hasSuffix("/transactions") },
      "pulling on the register must fetch the ledger page"
    )
  }

  // MARK: - #180 (iOS half): reports leave the launch path

  func testLaunchFetchesNoReports() async {
    let model = makeModel()

    await model.refreshAll()

    XCTAssertEqual(
      NarrowRefreshProtocol.reportRequestCount(),
      0,
      "launch must not fire the four reports; Reflect fetches them when it appears"
    )
    XCTAssertEqual(model.reportsPhase, .idle)
    XCTAssertTrue(
      NarrowRefreshProtocol.log().contains { $0.path.hasSuffix("/transactions") },
      "launch must still load the ledger, or this test proves nothing about the reports"
    )
  }

  func testReflectFetchesOnceAndThenServesTheCacheWhileKnowledgeHoldsStill() async {
    let model = makeModel()

    await model.refreshAll()
    XCTAssertEqual(NarrowRefreshProtocol.reportRequestCount(), 0)

    // Reflect appears.
    await model.refreshReportsIfNeeded()
    let afterFirstAppearance = NarrowRefreshProtocol.reportRequestCount()
    XCTAssertEqual(model.reportsPhase, .loaded, "the fixture must serve all four reports")
    XCTAssertEqual(
      afterFirstAppearance,
      4,
      "the first appearance fetches the four reports, saw \(afterFirstAppearance)"
    )

    // Reflect appears again with nothing written in between.
    await model.refreshReportsIfNeeded()
    XCTAssertEqual(
      NarrowRefreshProtocol.reportRequestCount(),
      afterFirstAppearance,
      "an unchanged server_knowledge and no local write must be served from the cache"
    )

    // An explicit pull always re-reads, cache or no cache.
    await model.refreshReportsIfNeeded(force: true)
    XCTAssertEqual(
      NarrowRefreshProtocol.reportRequestCount(),
      afterFirstAppearance + 4,
      "pull-to-refresh on Reflect must bypass the knowledge cache"
    )
  }

  func testALocalWriteInvalidatesTheReportsCache() async throws {
    let model = makeModel()
    await model.refreshAll()
    await model.refreshReportsIfNeeded()
    let afterFirstAppearance = NarrowRefreshProtocol.reportRequestCount()
    XCTAssertEqual(afterFirstAppearance, 4)

    // A write this device made is applied locally and never moves the cursor,
    // so the generation is what must invalidate the cache.
    let generationBefore = model.reportsRefreshGeneration
    try await model.deleteTransaction(NarrowRefreshProtocol.unclearedTransaction())
    _ = await waitUntil { model.reportsRefreshGeneration != generationBefore }

    await model.refreshReportsIfNeeded()
    XCTAssertEqual(
      NarrowRefreshProtocol.reportRequestCount(),
      afterFirstAppearance + 4,
      "an edit must make the next Reflect appearance refetch"
    )
  }

  // MARK: - The refresh queue

  func testAnOutboxSyncDuringAPullStillRefreshesBalances() async {
    // A pull replays the outbox. The rows it creates move balances, and the
    // drain runs inside the pull, so its follow-up must join that same pass.
    let model = makeModelWithOnePendingCapture()

    await model.refresh(slices: TabRefresh.register, quiet: false)
    _ = await waitUntil { model.pendingRows.isEmpty }

    let requests = NarrowRefreshProtocol.log()
    XCTAssertTrue(
      requests.contains { $0.method == "POST" && $0.path.hasSuffix("/transactions") },
      "the pull must replay the queued capture, saw \(requests)"
    )
    XCTAssertTrue(
      requests.contains {
        $0.isRead && $0.path == "/v1/plans/\(NarrowRefreshProtocol.planID)/accounts"
      },
      "a synced capture moves balances, so the pull must also read them, saw \(requests)"
    )
    XCTAssertGreaterThan(
      model.reportsRefreshGeneration,
      0,
      "a synced capture changes the reports, which must be marked stale"
    )
  }

  func testAccountsSliceNeverClaimsTheReferenceBatchIsLoaded() async {
    let model = makeModel()
    XCTAssertEqual(model.referencePhase, .idle)

    await model.refresh(slices: TabRefresh.accounts, quiet: false)

    XCTAssertNotEqual(
      model.referencePhase,
      .loaded,
      "one GET of balances must not claim that categories, payees and plan settings loaded"
    )
  }

  func testSwitchingPlanRestartsReflect() async {
    let model = makeModel()
    let generationBefore = model.reportsRefreshGeneration

    var switched = model.settings
    switched.planID = "plan-2"
    await model.applySettings(switched)

    XCTAssertGreaterThan(
      model.reportsRefreshGeneration,
      generationBefore,
      "ReflectView's only trigger is this generation; a plan switch must restart it"
    )
  }

  // MARK: - Helpers

  private func makeModelWithOnePendingCapture() -> AppModel {
    var settings = APISettings()
    settings.baseURLString = NarrowRefreshProtocol.fixtureBaseURL
    settings.authenticatedUserID = "narrow-refresh-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = NarrowRefreshProtocol.planID
    let request = TransactionWriteRequest(
      accountID: NarrowRefreshProtocol.accountID,
      date: "2026-01-02",
      amount: -1230,
      payeeID: nil,
      payeeName: "Fixture Payee",
      categoryID: nil,
      memo: nil,
      cleared: .uncleared,
      approved: true,
      flagColor: nil,
      subtransactions: []
    )
    let pending = PendingTransaction(
      request: request,
      connectionFingerprint: settings.connectionFingerprint
    )
    try? OutboxStore.save([pending])
    return AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: temporarySnapshotStore())
  }

  private func makeModel() -> AppModel {
    var settings = APISettings()
    settings.baseURLString = NarrowRefreshProtocol.fixtureBaseURL
    settings.authenticatedUserID = "narrow-refresh-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = NarrowRefreshProtocol.planID
    return AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: temporarySnapshotStore())
  }

  /// Polls a main-actor condition; the follow-up refresh after a write is
  /// detached, so there is no task to await from the call site.
  private func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if condition() {
        // Let anything that fired alongside the condition land too.
        try? await Task.sleep(nanoseconds: 100_000_000)
        return true
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
  }
}

/// #176: every model built here gets a snapshot store rooted in a fresh
/// temporary directory, so no test reads or writes the real Application
/// Support container (or another test's cache).
private func temporarySnapshotStore() -> SnapshotStore {
  SnapshotStore(
    directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("HowMuchSnapshotTests/\(UUID().uuidString)", isDirectory: true)
  )
}

private struct RecordedRequest: CustomStringConvertible {
  let method: String
  let path: String

  var isRead: Bool { method == "GET" }
  var description: String { "\(method) \(path)" }
}

private final class NarrowRefreshLog: @unchecked Sendable {
  static let shared = NarrowRefreshLog()
  private let lock = NSLock()
  private var requests: [RecordedRequest] = []

  func reset() {
    lock.lock()
    requests = []
    lock.unlock()
  }

  func record(_ request: RecordedRequest) {
    lock.lock()
    requests.append(request)
    lock.unlock()
  }

  func snapshot() -> [RecordedRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
}

/// Serves a minimal but decodable plan: one plan, an empty ledger carrying a
/// `server_knowledge` cursor, empty accounts, empty schedules, and four empty
/// reports. Every request is recorded with its method and path so the tests
/// can assert on exactly what the app asked for.
private final class NarrowRefreshProtocol: URLProtocol {
  static let fixtureHost = "howmuch-narrow-refresh.test"
  static let fixtureBaseURL = "https://howmuch-narrow-refresh.test"
  static let planID = "plan-1"
  static let transactionID = "txn-1"
  static let accountID = "acct-1"

  static func reset() {
    NarrowRefreshLog.shared.reset()
  }

  static func log() -> [RecordedRequest] {
    NarrowRefreshLog.shared.snapshot()
  }

  static func reportRequestCount() -> Int {
    log().filter { $0.path.hasPrefix("/api/reports/") }.count
  }

  /// A synthetic uncleared row. Values are invented; no real ledger data is
  /// used anywhere in these tests.
  static func unclearedTransaction() throws -> Transaction {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(Transaction.self, from: Data(transactionJSON.utf8))
  }

  private static let transactionJSON = """
  {
    "id": "\(transactionID)",
    "date": "2026-01-02",
    "amount": -1230,
    "memo": null,
    "cleared": "uncleared",
    "approved": true,
    "flag_color": null,
    "flag_name": null,
    "account_id": "\(accountID)",
    "account_name": "Fixture Account",
    "payee_id": null,
    "payee_name": "Fixture Payee",
    "category_id": null,
    "category_name": null,
    "transfer_account_id": null,
    "transfer_transaction_id": null,
    "parent_transaction_id": null,
    "matched_transaction_id": null,
    "import_id": null,
    "import_payee_name": null,
    "import_payee_name_original": null,
    "deleted": false,
    "subtransactions": []
  }
  """

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.lowercased() == fixtureHost
  }

  override class func canInit(with task: URLSessionTask) -> Bool {
    guard let request = task.currentRequest ?? task.originalRequest else {
      return false
    }
    return canInit(with: request)
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let path = url.path
    NarrowRefreshLog.shared.record(
      RecordedRequest(method: request.httpMethod ?? "GET", path: path)
    )
    guard let body = Self.body(forPath: path, method: request.httpMethod ?? "GET") else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    guard let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    ) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  private static func body(forPath path: String, method: String) -> String? {
    let plan = "/v1/plans/\(planID)"
    switch path {
    case "/v1/plans":
      return #"{"data":{"plans":[{"id":"\#(planID)","name":"Fixture Plan"}]}}"#
    case "\(plan)/accounts":
      return #"{"data":{"accounts":[],"server_knowledge":7}}"#
    case "\(plan)/payees":
      return #"{"data":{"payees":[],"server_knowledge":7}}"#
    case "\(plan)/transactions":
      return method == "POST"
        ? #"{"data":{"transaction":\#(transactionJSON),"server_knowledge":8}}"#
        : #"{"data":{"transactions":[],"has_more":false,"server_knowledge":7}}"#
    case "\(plan)/scheduled_transactions":
      return #"{"data":{"scheduled_transactions":[],"server_knowledge":7}}"#
    case "\(plan)/transactions/\(transactionID)/cleared",
         "\(plan)/transactions/\(transactionID)":
      return #"{"data":{"transaction":\#(transactionJSON),"server_knowledge":8}}"#
    case "/api/reports/spending-breakdown":
      return #"{"data":{"total":0,"groups":[]}}"#
    case "/api/reports/income-vs-spending":
      return #"{"data":{"interval":"month","periods":[]}}"#
    case "/api/reports/net-worth":
      return #"{"data":{"periods":[]}}"#
    case "/api/reports/age-of-money":
      return #"{"data":{"interval":"month","periods":[]}}"#
    default:
      // Everything else (plan settings, categories, account preferences) fails
      // fast: these tests count requests, they do not exercise those screens.
      return nil
    }
  }

  override func stopLoading() {}
}
