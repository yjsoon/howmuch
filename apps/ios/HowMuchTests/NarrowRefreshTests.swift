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
    previousOutbox = UserDefaults.standard.object(forKey: OutboxStore.legacyDefaultsKey)
    UserDefaults.standard.removeObject(forKey: OutboxStore.legacyDefaultsKey)
    XCTAssertTrue(URLProtocol.registerClass(NarrowRefreshProtocol.self))
    NarrowRefreshProtocol.reset()
    XCTAssertTrue(URLProtocol.registerClass(HorizonRefreshProtocol.self))
    HorizonRefreshProtocol.state.reset()
  }

  override func tearDown() {
    HorizonRefreshProtocol.state.release()
    URLProtocol.unregisterClass(HorizonRefreshProtocol.self)
    URLProtocol.unregisterClass(NarrowRefreshProtocol.self)
    APISettings.useCredentialService(previousCredentialService)
    UserDefaults.standard.set(previousAPISettings, forKey: APISettings.userDefaultsKey)
    UserDefaults.standard.set(previousScopedViewPrefs, forKey: ScopedViewPrefsStore.userDefaultsKey)
    UserDefaults.standard.set(previousOutbox, forKey: OutboxStore.legacyDefaultsKey)
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

  func testRegisterPullAppliesExternallyChangedBalanceAndSchedule() async {
    let model = makeModel()
    await model.refresh(slices: [.accounts, .ledger, .schedules], quiet: false)
    XCTAssertEqual(model.accounts.first?.balance, 100)
    XCTAssertEqual(model.scheduledTransactions.first?.dateNext, "2026-01-03")

    NarrowRefreshProtocol.setExternalRegisterChangesVisible()
    await model.refresh(slices: TabRefresh.register, quiet: false)

    XCTAssertEqual(model.accounts.first?.balance, 200)
    XCTAssertEqual(model.scheduledTransactions.first?.dateNext, "2026-02-03")
    XCTAssertEqual(NarrowRefreshProtocol.reportRequestCount(), 0)
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

  // MARK: - Account refresh invalidates completed register coverage

  func testAccountsRefreshInvalidatesCompletedHorizon() async throws {
    try await assertHorizonRefresh(slices: [.accounts], offsetting: false)
  }

  func testReferenceRefreshInvalidatesCompletedHorizon() async throws {
    try await assertHorizonRefresh(slices: [.referenceData], offsetting: false)
  }

  func testUnchangedBalanceDoesNotProveHorizonIsCurrent() async throws {
    try await assertHorizonRefresh(slices: [.accounts], offsetting: true)
  }

  private func assertHorizonRefresh(slices: Set<RefreshSlice>, offsetting: Bool) async throws {
    let state = HorizonRefreshProtocol.state
    let model = makeHorizonModel()
    await model.refreshAccounts()
    model.beginFocusedRegisterAccount("a")
    let loaded = await waitUntil { state.reads == 1 && !model.isFillingHorizon }
    XCTAssertTrue(loaded)
    XCTAssertEqual(model.transactions.map(\.id), ["initial"])
    model.endFocusedRegisterAccount("a")

    // Reappearing without a refresh still benefits from the memoized fill.
    model.beginFocusedRegisterAccount("a")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(state.reads, 1)
    model.endFocusedRegisterAccount("a")

    state.addExternalRows(offsetting: offsetting)
    await model.refresh(slices: slices)
    XCTAssertEqual(model.accounts.first?.balance, offsetting ? 10_000 : 8_000)
    XCTAssertEqual(state.reads, 1, "the Accounts pull itself must remain narrow")
    model.beginFocusedRegisterAccount("a")
    let refreshed = await waitUntil { state.reads == 2 && !model.isFillingHorizon }
    XCTAssertTrue(refreshed, "reopening must refetch after the account-list refresh")
    XCTAssertTrue(model.transactions.contains { $0.id == "future" })
    XCTAssertEqual(
      RegisterCurrent.asOfTodayBalance(
        working: try XCTUnwrap(model.accounts.first).balance,
        transactions: model.transactions, accountID: "a", today: Date.now.isoDateString
      ),
      offsetting ? 12_000 : 10_000
    )
    model.endFocusedRegisterAccount("a")
  }

  func testPreRefreshFillCannotRestoreCompletedHorizonAfterEitherAccountRefresh() async {
    for slices: Set<RefreshSlice> in [[.accounts], [.referenceData]] {
      let state = HorizonRefreshProtocol.state
      state.reset()
      let model = makeHorizonModel()
      await model.refreshAccounts()
      state.holdNext()
      model.beginFocusedRegisterAccount("a")
      let parked = await waitUntil { state.isHeld }
      XCTAssertTrue(parked)
      state.addExternalRows(offsetting: false)
      await model.refresh(slices: slices)
      state.release()
      let settled = await waitUntil { !model.isFillingHorizon }
      XCTAssertTrue(settled)
      XCTAssertEqual(model.transactions.map(\.id), ["initial"], "the parked response must contain the old rows")
      model.endFocusedRegisterAccount("a")
      model.beginFocusedRegisterAccount("a")
      let refetched = await waitUntil { state.reads == 2 && !model.isFillingHorizon }
      XCTAssertTrue(refetched, "the pre-refresh fill must not reauthorize the cache")
      XCTAssertTrue(model.transactions.contains { $0.id == "future" })
      model.endFocusedRegisterAccount("a")
    }
  }

  private func makeHorizonModel() -> AppModel {
    var settings = APISettings()
    settings.baseURLString = "https://horizon-refresh.test"
    settings.authenticatedUserID = UUID().uuidString
    settings.sessionToken = "fixture"
    settings.planID = "p"
    return AppModel(outboxStore: .temporary(), settings: settings, viewPrefs: ViewPrefs(), snapshotStore: temporarySnapshotStore())
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
    // Queued by the previous build, in UserDefaults: the model moves it into
    // its outbox file on launch.
    let defaults = UserDefaults(suiteName: "howmuch.tests.narrow.\(UUID().uuidString)")!
    defaults.set(try? JSONEncoder().encode([pending]), forKey: OutboxStore.legacyDefaultsKey)
    let model = AppModel(
      outboxStore: .temporary(defaults: defaults),
      settings: settings,
      viewPrefs: ViewPrefs(),
      snapshotStore: temporarySnapshotStore()
    )
    model.outboxDebounce = .zero
    return model
  }

  private func makeModel() -> AppModel {
    var settings = APISettings()
    settings.baseURLString = NarrowRefreshProtocol.fixtureBaseURL
    settings.authenticatedUserID = "narrow-refresh-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = NarrowRefreshProtocol.planID
    let model = AppModel(outboxStore: .temporary(), settings: settings, viewPrefs: ViewPrefs(), snapshotStore: temporarySnapshotStore())
    model.outboxDebounce = .zero
    return model
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
  private static let stateLock = NSLock()
  private static var hasExternalRegisterChanges = false

  static func reset() {
    NarrowRefreshLog.shared.reset()
    stateLock.lock()
    hasExternalRegisterChanges = false
    stateLock.unlock()
  }

  static func setExternalRegisterChangesVisible() {
    stateLock.lock()
    hasExternalRegisterChanges = true
    stateLock.unlock()
  }

  private static var externalRegisterChangesVisible: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return hasExternalRegisterChanges
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
      let balance = externalRegisterChangesVisible ? 200 : 100
      return #"{"data":{"accounts":[{"id":"acct-1","name":"Fixture Account","icon":null,"type":"cash","on_budget":true,"closed":false,"balance":\#(balance),"cleared_balance":\#(balance),"uncleared_balance":0,"last_reconciled_date":null,"deleted":false}],"server_knowledge":7}}"#
    case "\(plan)/payees":
      return #"{"data":{"payees":[],"server_knowledge":7}}"#
    case "\(plan)/transactions":
      return method == "POST"
        ? #"{"data":{"transaction":\#(transactionJSON),"server_knowledge":8}}"#
        : #"{"data":{"transactions":[],"has_more":false,"server_knowledge":7}}"#
    case "\(plan)/scheduled_transactions":
      let date = externalRegisterChangesVisible ? "2026-02-03" : "2026-01-03"
      return #"{"data":{"scheduled_transactions":[{"id":"schedule-1","date_first":"2026-01-03","date_next":"\#(date)","frequency":"monthly","amount":-100,"memo":null,"flag_color":null,"account_id":"acct-1","payee_id":null,"category_id":null,"transfer_account_id":null,"deleted":false,"subtransactions":[]}],"server_knowledge":7}}"#
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

@MainActor
final class ClearedEditorTests: XCTestCase {
  private var credentialService = ""
  private var defaults: [String: Any] = [:]
  private let keys = [APISettings.userDefaultsKey, ScopedViewPrefsStore.userDefaultsKey, OutboxStore.legacyDefaultsKey]

  override func setUp() {
    super.setUp()
    credentialService = APISettings.useCredentialService("HowMuch.ClearedEditorTests.\(UUID())")
    for key in keys {
      defaults[key] = UserDefaults.standard.object(forKey: key)
      UserDefaults.standard.removeObject(forKey: key)
    }
    ClearedEditorProtocol.state.reset()
    XCTAssertTrue(URLProtocol.registerClass(ClearedEditorProtocol.self))
  }

  override func tearDown() {
    ClearedEditorProtocol.state.releaseAll()
    URLProtocol.unregisterClass(ClearedEditorProtocol.self)
    APISettings.useCredentialService(credentialService)
    for key in keys { UserDefaults.standard.set(defaults[key], forKey: key) }
    super.tearDown()
  }

  func testEditorSupersedesToggleThroughDelayedFirstAndOlderPages() async throws {
    let model = makeModel()
    let state = ClearedEditorProtocol.state
    await model.refreshLedger(quiet: false)
    try await model.toggleTransactionCleared(try row(in: model))
    XCTAssertEqual(try row(in: model).cleared, .cleared)
    await model.waitForOutboxDrain()
    await model.refresh(slices: [.accounts])

    state.holdNext("first")
    let first = Task { await model.refreshLedger(quiet: true) }
    await eventually { state.isHeld("first") }
    state.holdNext("older")
    let older = Task { await model.loadOlderTransactions() }
    await eventually { state.isHeld("older") }
    var draft = TransactionDraft(transaction: try row(in: model))
    draft.isCleared = false
    try model.commit(draft)
    await eventually { model.lastSaveMessage?.text.hasPrefix("Saved ") == true }
    XCTAssertEqual(try row(in: model).cleared, .uncleared)
    await model.waitForOutboxDrain()

    // The older-page merge keeps the saved row. It must not use that cached
    // match to retire the overlay before the pre-edit first page arrives.
    state.release("older")
    await older.value
    XCTAssertTrue(model.transactions.contains { $0.id == "older-marker" })
    state.release("first")
    await first.value
    XCTAssertEqual(try row(in: model).cleared, .uncleared)

    // Another client changes the row before our FIRST post-save ledger read.
    // Retirement must follow read ownership, not wait to see our saved value.
    state.setCleared("cleared")
    await model.refresh(slices: [.ledger])
    XCTAssertEqual(try row(in: model).cleared, .cleared, "a post-save first page must retire the editor overlay")
    try await model.toggleTransactionCleared(try row(in: model))
    await model.waitForOutboxDrain()
    XCTAssertEqual(state.lastExpectedCleared, "cleared", "the next CAS must use the fresh rendered value")
    await model.refresh(slices: [.accounts])
  }

  func testFreshOlderPageRetiresEditorOverrideWithoutTrustingCachedRows() async throws {
    let model = makeModel()
    let state = ClearedEditorProtocol.state
    state.setCleared("cleared")
    await model.refreshLedger(quiet: false)
    var draft = TransactionDraft(transaction: try row(in: model))
    draft.isCleared = false
    try model.commit(draft)
    await eventually { model.lastSaveMessage?.text.hasPrefix("Saved ") == true }
    await model.waitForOutboxDrain()
    state.setCleared("cleared")
    state.omitRowFromFirstPage()
    await model.refresh(slices: [.ledger])
    XCTAssertEqual(try row(in: model).cleared, .uncleared, "a retained row is not fresh response evidence")
    await model.loadOlderTransactions()
    XCTAssertEqual(try row(in: model).cleared, .cleared, "a fresh older page must retire the saved override")
    try await model.toggleTransactionCleared(try row(in: model))
    await model.waitForOutboxDrain()
    XCTAssertEqual(state.lastExpectedCleared, "cleared")
    await model.refresh(slices: [.accounts])
  }

  func testNewToggleSupersedesEditorRetirementRuleBeforeHeldReadReturns() async throws {
    let model = makeModel()
    let state = ClearedEditorProtocol.state
    state.setCleared("cleared")
    await model.refreshLedger(quiet: false)
    var draft = TransactionDraft(transaction: try row(in: model))
    draft.isCleared = false
    try model.commit(draft)
    await eventually { model.lastSaveMessage?.text.hasPrefix("Saved ") == true }
    await model.waitForOutboxDrain()

    state.holdNext("first")
    let refresh = Task { await model.refreshLedger(quiet: true) }
    await eventually { state.isHeld("first") }
    try await model.toggleTransactionCleared(try row(in: model))
    XCTAssertEqual(try row(in: model).cleared, .cleared)
    await model.waitForOutboxDrain()
    state.release("first")
    await refresh.value
    XCTAssertEqual(try row(in: model).cleared, .cleared, "a pre-toggle read must not put the old status back")
    try await model.toggleTransactionCleared(try row(in: model))
    await model.waitForOutboxDrain()
    XCTAssertEqual(state.lastExpectedCleared, "cleared")
    await model.refresh(slices: [.accounts])
  }

  func testARefusedEditorSaveOwnsNothingOnceDiscarded() async throws {
    let model = makeModel()
    let state = ClearedEditorProtocol.state
    await model.refreshLedger(quiet: false)
    try await model.toggleTransactionCleared(try row(in: model))
    await model.waitForOutboxDrain()
    state.rejectEditor()
    var draft = TransactionDraft(transaction: try row(in: model))
    draft.isCleared = false
    try model.commit(draft)
    await eventually { model.lastSaveMessage?.kind == .failure }
    await model.refresh(slices: [.ledger, .accounts])
    XCTAssertEqual(try row(in: model).cleared, .uncleared, "a refused change still shows until it is discarded")
    let refused = try XCTUnwrap(model.outboxItems.first)
    model.discardPending(refused.id)
    XCTAssertEqual(try row(in: model).cleared, .cleared, "discarding it shows the server's status again")
    state.setCleared("uncleared")
    await model.refresh(slices: [.ledger])
    XCTAssertEqual(try row(in: model).cleared, .uncleared)
  }

  private func row(in model: AppModel) throws -> Transaction {
    try XCTUnwrap(model.transactions.first { $0.id == "row" })
  }

  private func makeModel() -> AppModel {
    var settings = APISettings()
    settings.baseURLString = "https://cleared-editor.test"
    settings.authenticatedUserID = UUID().uuidString
    settings.sessionToken = "fixture"
    settings.planID = "p"
    let model = AppModel(outboxStore: .temporary(), settings: settings, viewPrefs: ViewPrefs(), snapshotStore: temporarySnapshotStore())
    model.outboxDebounce = .zero
    return model
  }

  private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<300 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "fixture operation did not settle", file: file, line: line)
  }
}

private final class ClearedEditorState: @unchecked Sendable {
  private let lock = NSLock()
  private var cleared = "uncleared"
  private var rejectsEditor = false
  private var firstPageOmitsRow = false
  private var holds: Set<String> = []
  private var pending: [String: () -> Void] = [:]
  private var expectedCleared: String?

  func reset() {
    releaseAll()
    lock.lock(); defer { lock.unlock() }
    cleared = "uncleared"; rejectsEditor = false; firstPageOmitsRow = false; holds = []; expectedCleared = nil
  }
  func setCleared(_ value: String) { lock.lock(); cleared = value; lock.unlock() }
  func rejectEditor() { lock.lock(); rejectsEditor = true; lock.unlock() }
  func omitRowFromFirstPage() { lock.lock(); firstPageOmitsRow = true; lock.unlock() }
  func holdNext(_ kind: String) { lock.lock(); holds.insert(kind); lock.unlock() }
  func isHeld(_ kind: String) -> Bool { lock.lock(); defer { lock.unlock() }; return pending[kind] != nil }
  var lastExpectedCleared: String? { lock.lock(); defer { lock.unlock() }; return expectedCleared }
  func release(_ kind: String) {
    lock.lock(); let send = pending.removeValue(forKey: kind); lock.unlock(); send?()
  }
  func releaseAll() {
    lock.lock(); let sends = Array(pending.values); pending = [:]; lock.unlock()
    sends.forEach { $0() }
  }

  func respond(to request: URLRequest, send: @escaping (Data, Int) -> Void) {
    let body = Self.body(request)
    lock.lock()
    let url = request.url!
    var status = 200
    var kind = "other"
    let payload: [String: Any]
    if request.httpMethod == "PUT" {
      if rejectsEditor { status = 400 }
      else { cleared = (body["transaction"] as? [String: Any])?["cleared"] as? String ?? cleared }
      payload = ["transaction": row()]
    } else if request.httpMethod == "PATCH" {
      expectedCleared = body["expected_cleared"] as? String
      if expectedCleared != cleared { status = 409 }
      else { cleared = body["cleared"] as? String ?? cleared }
      payload = ["transaction": row()]
    } else if url.path.hasSuffix("unapproved_count") {
      payload = ["count": 0, "server_knowledge": 1]
    } else if url.path.hasSuffix("transactions") {
      let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value
      kind = offset == "0" ? "first" : "older"
      var rows = [row(id: kind == "first" && firstPageOmitsRow ? "first-marker" : "row")]
      if kind == "older" { rows.append(row(id: "older-marker")) }
      payload = ["transactions": rows, "has_more": kind == "first", "next_offset": kind == "first" ? 1 : NSNull(), "server_knowledge": 1]
    } else if url.path.hasSuffix("accounts") {
      payload = ["accounts": [], "server_knowledge": 1]
    } else {
      payload = ["payees": []]
    }
    let data = try! JSONSerialization.data(withJSONObject: ["data": payload])
    if holds.remove(kind) != nil {
      pending[kind] = { send(data, status) }
      lock.unlock()
    } else {
      lock.unlock()
      send(data, status)
    }
  }

  private func row(id: String = "row") -> [String: Any] {
    ["id": id, "date": "2020-01-01", "amount": -1000, "cleared": cleared,
     "approved": true, "account_id": "a", "account_name": "Fixture", "deleted": false, "subtransactions": []]
  }

  private static func body(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
      }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }
}

private final class ClearedEditorProtocol: URLProtocol {
  static let state = ClearedEditorState()
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cleared-editor.test" }
  override class func canInit(with task: URLSessionTask) -> Bool {
    (task.currentRequest ?? task.originalRequest).map { canInit(with: $0) } ?? false
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.state.respond(to: request) { [self] data, status in
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}

private final class HorizonRefreshState: @unchecked Sendable {
  private let lock = NSLock()
  private var changed = false
  private var offsetting = false
  private var shouldHold = false
  private var pending: (() -> Void)?
  private var readCount = 0

  var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
  var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
  func reset() {
    release()
    lock.lock(); defer { lock.unlock() }
    changed = false; offsetting = false; shouldHold = false; readCount = 0
  }
  func holdNext() { lock.lock(); shouldHold = true; lock.unlock() }
  func addExternalRows(offsetting: Bool) {
    lock.lock(); defer { lock.unlock() }
    changed = true; self.offsetting = offsetting
  }
  func release() {
    lock.lock(); let send = pending; pending = nil; lock.unlock()
    send?()
  }

  func respond(to request: URLRequest, send: @escaping (Data) -> Void) {
    lock.lock()
    let path = request.url!.path
    let payload: [String: Any]
    if path.hasSuffix("/accounts/a/transactions") {
      readCount += 1
      var rows = [row("initial", amount: -1_000, date: Date.now)]
      if changed {
        rows.append(row("future", amount: -2_000, date: Calendar.current.date(byAdding: .day, value: 1, to: .now)!))
        if offsetting { rows.append(row("current", amount: 2_000, date: .now)) }
      }
      payload = ["transactions": rows, "has_more": false, "server_knowledge": 1]
    } else if path.hasSuffix("/accounts") {
      let balance = changed && !offsetting ? 8_000 : 10_000
      payload = ["accounts": [["id": "a", "name": "Account", "type": "cash", "on_budget": true,
        "closed": false, "deleted": false, "balance": balance, "cleared_balance": balance, "uncleared_balance": 0]]]
    } else if path.hasSuffix("/settings") {
      payload = ["settings": [:]]
    } else if path.hasSuffix("/categories") {
      payload = ["category_groups": []]
    } else if path.hasSuffix("/payees") {
      payload = ["payees": []]
    } else if path.hasSuffix("/account_preferences") {
      payload = ["account_preferences": NSNull(), "account_preferences_revision": 0]
    } else {
      payload = ["count": 0, "server_knowledge": 1]
    }
    let data = try! JSONSerialization.data(withJSONObject: ["data": payload])
    if path.hasSuffix("/accounts/a/transactions"), shouldHold {
      shouldHold = false
      pending = { send(data) }
      lock.unlock()
    } else {
      lock.unlock()
      send(data)
    }
  }

  private func row(_ id: String, amount: Int, date: Date) -> [String: Any] {
    ["id": id, "date": date.isoDateString, "amount": amount, "cleared": "cleared", "approved": true,
     "account_id": "a", "account_name": "Account", "deleted": false, "subtransactions": []]
  }
}

private final class HorizonRefreshProtocol: URLProtocol {
  static let state = HorizonRefreshState()
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "horizon-refresh.test" }
  override class func canInit(with task: URLSessionTask) -> Bool {
    (task.currentRequest ?? task.originalRequest).map { canInit(with: $0) } ?? false
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.state.respond(to: request) { [self] data in
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}
