import XCTest
@testable import HowMuch

/// Pure rules for moving an on-device ledger to a server.
final class ServerConnectionRulesTests: XCTestCase {
  private func account(_ id: String, closed: Bool = false, deleted: Bool = false) -> Account {
    Account(
      id: id, name: id, icon: nil, type: "checking", onBudget: true, closed: closed,
      balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: deleted
    )
  }

  private func schedule(deleted: Bool = false) -> ScheduledTransaction {
    ScheduledTransaction(
      id: "s", dateFirst: "2026-01-01", dateNext: "2026-02-01", frequency: "monthly", amount: -1_000,
      memo: nil, flagColor: nil, accountID: "a", payeeID: nil, categoryID: nil, transferAccountID: nil,
      deleted: deleted, subtransactions: []
    )
  }

  private func contents(
    accounts: [Account] = [],
    hasTransactions: Bool = false,
    schedules: [ScheduledTransaction] = [],
    payees: [Payee] = [],
    groups: [CategoryGroup] = []
  ) -> ServerPlanContents {
    ServerPlanContents(
      accounts: accounts,
      hasTransactions: hasTransactions,
      scheduledTransactions: schedules,
      payees: payees,
      categoryGroups: groups
    )
  }

  func testAFreshPlanIsEmpty() {
    XCTAssertTrue(contents().isEmpty)
  }

  func testTombstonesDoNotCount() {
    let plan = contents(
      accounts: [account("gone", deleted: true)],
      schedules: [schedule(deleted: true)],
      payees: [Payee(id: "p", name: "Old", transferAccountId: nil, deleted: true)],
      groups: [CategoryGroup(id: "g", name: "Old", hidden: false, deleted: true, categories: [])]
    )
    XCTAssertTrue(plan.isEmpty)
  }

  func testAnyLiveRowMakesAPlanNotEmpty() {
    XCTAssertFalse(contents(accounts: [account("closed", closed: true)]).isEmpty, "A closed account is still live")
    XCTAssertFalse(contents(hasTransactions: true).isEmpty)
    XCTAssertFalse(contents(schedules: [schedule()]).isEmpty)
    XCTAssertFalse(contents(payees: [Payee(id: "p", name: "Shop", transferAccountId: nil, deleted: nil)]).isEmpty)
    XCTAssertFalse(contents(groups: [CategoryGroup(id: "g", name: "Bills", hidden: true, deleted: false, categories: [])]).isEmpty)
    let category = Category(id: "c", categoryGroupID: "g", name: "Rent", deleted: false)
    let plan = contents(groups: [CategoryGroup(id: "g", name: "Bills", hidden: false, deleted: false, categories: [category])])
    XCTAssertEqual(plan.categories, 1)
    XCTAssertFalse(plan.isEmpty)
  }

  func testIdempotencyKeyIsStableValidAndSpecificToBothPlans() {
    let key = SnapshotImport.idempotencyKey(localPlanID: "plan_local", serverPlanID: "plan/server")
    XCTAssertEqual(key, SnapshotImport.idempotencyKey(localPlanID: "plan_local", serverPlanID: "plan/server"))
    XCTAssertNotNil(key.wholeMatch(of: /[A-Za-z0-9._:-]{8,128}/), key)
    XCTAssertNotEqual(key, SnapshotImport.idempotencyKey(localPlanID: "plan_local", serverPlanID: "plan_other"))
    XCTAssertNotEqual(key, SnapshotImport.idempotencyKey(localPlanID: "plan_other", serverPlanID: "plan/server"))
    XCTAssertNotEqual(
      SnapshotImport.idempotencyKey(localPlanID: "a", serverPlanID: "b"),
      SnapshotImport.idempotencyKey(localPlanID: "b", serverPlanID: "a")
    )
  }

  func testSummaryCountsLiveRowsAndTheRequestLimit() throws {
    let snapshot = Data(#"{"format":"howmuch-plan-snapshot","version":1,"accounts":[{"id":"a"},{"id":"b"}],"transactions":[{"id":"t1"},{"id":"t2","deleted":true}]}"#.utf8)
    let summary = try SnapshotImport.summary(of: snapshot)
    XCTAssertEqual(summary, SnapshotImport.Summary(accounts: 2, transactions: 1, fitsOneRequest: true))

    let body = SnapshotImport.requestBody(snapshot: snapshot)
    let wrapped = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual((wrapped["snapshot"] as? [String: Any])?["format"] as? String, "howmuch-plan-snapshot")

    let padding = String(repeating: "x", count: APIClient.snapshotByteLimit)
    let large = Data(#"{"accounts":[],"memo":"\#(padding)"}"#.utf8)
    XCTAssertFalse(try SnapshotImport.summary(of: large).fitsOneRequest)
  }

  func testImportFailuresMapToTheNextStep() {
    XCTAssertEqual(SnapshotImport.failure(for: APIClientError.planNotEmpty("full")), .serverHasData)
    XCTAssertEqual(SnapshotImport.failure(for: APIClientError.payloadTooLarge), .tooLarge)
    XCTAssertEqual(SnapshotImport.failure(for: APIClientError.conflict("reused")), .recheck("reused"))
    XCTAssertEqual(SnapshotImport.failure(for: APIClientError.server("boom")), .failed("boom"))
    XCTAssertEqual(SnapshotImport.failure(for: APIClientError.ynabMirrorPlan("mirror")), .refused(SnapshotImport.ynabMirrorMessage))
    XCTAssertEqual(SnapshotImport.failure(for: APIClientError.ownerRequired("owner")), .refused(SnapshotImport.ownerRequiredMessage))
  }

  private func pending(_ fingerprint: String) -> PendingTransaction {
    PendingTransaction(
      request: TransactionWriteRequest(
        accountID: "a", date: "2026-09-01", amount: -1_000, payeeID: nil, payeeName: "Shop", categoryID: nil,
        memo: nil, cleared: .uncleared, approved: true, flagColor: nil, subtransactions: []
      ),
      connectionFingerprint: fingerprint
    )
  }

  func testUnsentChangesForThisServerBlockSwitchingBack() {
    let server = APISettings(baseURLString: "https://ledger.example.test", sessionToken: "t", authenticatedUserID: "u", planID: "p")
    let other = APISettings(baseURLString: "https://other.example.test", sessionToken: "t", authenticatedUserID: "u", planID: "p")

    XCTAssertNil(ConnectionSwitch.blockReason(pending: [], settings: server))
    XCTAssertNil(ConnectionSwitch.blockReason(pending: [pending(other.connectionFingerprint)], settings: server))
    XCTAssertEqual(
      ConnectionSwitch.blockReason(pending: [pending(server.connectionFingerprint)], settings: server),
      "1 change hasn’t reached the server yet. Connect to the internet and try again."
    )
    XCTAssertEqual(
      ConnectionSwitch.blockReason(pending: [pending(server.connectionFingerprint), pending(server.connectionFingerprint)], settings: server),
      "2 changes haven’t reached the server yet. Connect to the internet and try again."
    )
  }

  @MainActor
  func testALeftFlowCanNeverBeAdopted() {
    let server = APISettings(baseURLString: "https://ledger.example.test", sessionToken: "t", authenticatedUserID: "u", planID: "p")
    let left = ServerConnectFlow(local: APISettings(), signedIn: server)
    XCTAssertEqual(left.abandon(), server, "Leaving returns the session to sign out")
    XCTAssertNil(left.abandon(), "Only once")
    XCTAssertNil(left.adopt(server))

    let chosen = ServerConnectFlow(local: APISettings(), signedIn: server)
    XCTAssertEqual(chosen.adopt(server), server)
    XCTAssertNil(chosen.abandon(), "A chosen server is not signed out when the sheet closes")
    XCTAssertNil(chosen.adopt(server), "Only once")
  }

  func testArchivePathIsRelativeToApplicationSupport() {
    let inside = LocalEngine.defaultDatabaseURL
    let archive = LocalArchive(databaseURL: inside, planID: "p", archivedAt: .now)
    XCTAssertEqual(archive.path, "HowMuch/Local/howmuch.sqlite")
    XCTAssertEqual(archive.databaseURL.standardizedFileURL, inside.standardizedFileURL)

    let outside = URL(fileURLWithPath: "/tmp/elsewhere/howmuch.sqlite")
    XCTAssertEqual(LocalArchive(databaseURL: outside, planID: "p", archivedAt: .now).databaseURL.path, outside.path)
  }
}

/// The connect flow end to end, with a second on-device engine standing in for
/// the server behind a `URLProtocol`. Nothing leaves the test process.
@MainActor
final class ServerConnectionFlowTests: XCTestCase {
  private static let serverURL = "https://connect-server.test"
  private var directory: URL!
  private var previousEngine: LocalEngine?
  private var defaults: UserDefaults!
  private var suiteName = ""
  private var previousCredentialService = ""
  private var local: APISettings!
  private var localDatabase: URL!

  private let server = APISettings(
    baseURLString: ServerConnectionFlowTests.serverURL,
    username: "owner",
    sessionToken: "server-token",
    authenticatedUserID: "server-user",
    planID: "plan_server",
    mode: .server
  )

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appending(path: "ServerConnectionFlowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    localDatabase = directory.appending(path: "local.sqlite")
    previousEngine = LocalEngine.useShared(LocalEngine(databaseURL: localDatabase))
    suiteName = "HowMuch.ServerConnectionFlowTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    previousCredentialService = APISettings.useCredentialService("HowMuch.ServerConnectionFlowTests.\(UUID().uuidString)")
    local = APISettings.local(in: defaults)
    ServerEngineProtocol.install(
      engine: LocalEngine(databaseURL: directory.appending(path: "server.sqlite")),
      config: LocalEngineConfig(apiToken: "server-token", defaultPlanId: "plan_server", timeZone: "Asia/Singapore")
    )
    XCTAssertTrue(URLProtocol.registerClass(ServerEngineProtocol.self))
  }

  override func tearDown() async throws {
    URLProtocol.unregisterClass(ServerEngineProtocol.self)
    ServerEngineProtocol.reset()
    LocalEngine.useShared(previousEngine)
    APISettings.useCredentialService(previousCredentialService)
    defaults.removePersistentDomain(forName: suiteName)
    UserDefaults.standard.removePersistentDomain(forName: suiteName + ".earlier")
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  /// Two accounts, a categorised purchase and a transfer between them.
  private func seedLocalLedger() async throws {
    let client = APIClient(settings: local)
    let planID = local.planID
    try await LocalEngine.shared.prepare(config: local.localEngineConfig)
    try await StarterCategories.seedIfNeeded(client: client, planID: planID, defaults: defaults)
    let everyday = try await client.createAccount(planID: planID, name: "Everyday", type: "checking", balance: 100_000, icon: nil, onBudget: true)
    let wallet = try await client.createAccount(planID: planID, name: "Wallet", type: "cash", balance: 5_000, icon: nil, onBudget: true)
    let category = try await client.fetchCategories(planID: planID).flatMap(\.categories).first
    _ = try await client.createTransaction(planID: planID, request: TransactionWriteRequest(
      accountID: everyday.id, date: "2026-09-01", amount: -12_340, payeeID: nil, payeeName: "Coffee",
      categoryID: category?.id, memo: "flat white", cleared: .cleared, approved: true, flagColor: nil, subtransactions: []
    ))
    let walletPayee = try await client.fetchPayees(planID: planID).first { $0.transferAccountId == wallet.id }
    _ = try await client.createTransaction(planID: planID, request: TransactionWriteRequest(
      accountID: everyday.id, date: "2026-09-02", amount: -20_000, payeeID: try XCTUnwrap(walletPayee).id, payeeName: nil,
      categoryID: nil, memo: nil, cleared: .uncleared, approved: true, flagColor: nil, subtransactions: []
    ))
  }

  private func ledger(_ settings: APISettings) async throws -> (accounts: [String], transactions: [String], payeeNames: [String]) {
    let client = APIClient(settings: settings)
    let accounts = try await client.fetchAccounts(planID: settings.planID)
      .map { "\($0.id)|\($0.name)|\($0.type)|\($0.balance)|\($0.clearedBalance)" }
      .sorted()
    let rows = try await client.fetchTransactions(planID: settings.planID).transactions
    let transactions = rows
      .map { "\($0.id)|\($0.accountID)|\($0.date)|\($0.amount)|\($0.payeeID ?? "")|\($0.categoryID ?? "")|\($0.memo ?? "")" }
      .sorted()
    let payeeNames = rows.map { "\($0.id)|\($0.payeeName ?? "")" }.sorted()
    return (accounts, transactions, payeeNames)
  }

  func testAnEmptyServerReceivesTheLedgerAndTheDeviceKeepsIt() async throws {
    try await seedLocalLedger()
    let flow = ServerConnectFlow(local: local, signedIn: server)

    await flow.check()
    guard case .confirmUpload(let summary) = flow.step else {
      return XCTFail("Expected the upload question, got \(flow.step)")
    }
    XCTAssertEqual(summary.accounts, 2)
    let before = try await ledger(local)
    XCTAssertEqual(summary.transactions, before.transactions.count)

    let adopted = await flow.upload()
    XCTAssertEqual(adopted, server)
    XCTAssertEqual(ServerEngineProtocol.importCount, 1)

    let after = try await ledger(server)
    XCTAssertEqual(after.accounts, before.accounts)
    XCTAssertEqual(after.transactions, before.transactions)
    // A payee typed as a name (no payee row) travels as `payee_name`.
    XCTAssertEqual(after.payeeNames, before.payeeNames)
    let deviceAfter = try await ledger(local)
    XCTAssertEqual(deviceAfter.transactions, before.transactions, "The device ledger is unchanged")
    XCTAssertTrue(FileManager.default.fileExists(atPath: localDatabase.path))

    // A retry after a lost response replays rather than importing again.
    let connector = ServerConnector(local: local, server: server)
    let replayed = await connector.upload(try await connector.exportLocalLedger())
    XCTAssertEqual(replayed, .uploaded)
    XCTAssertEqual(ServerEngineProtocol.importCount, 1, "The retry replayed; nothing was imported twice")
    let serverAfterRetry = try await ledger(server)
    XCTAssertEqual(serverAfterRetry.transactions, before.transactions)
  }

  /// The user leaves while the upload is on its way. The server may take it,
  /// but the app stays local and never adopts the signed-out session.
  func testAnUploadThatLandsAfterLeavingIsIgnored() async throws {
    try await seedLocalLedger()
    let flow = ServerConnectFlow(local: local, signedIn: server)
    await flow.check()
    ServerEngineProtocol.beforeImportResponse = {
      DispatchQueue.main.sync {
        MainActor.assumeIsolated { _ = flow.abandon() }
      }
    }

    let adopted = await flow.upload()

    XCTAssertNil(adopted)
    XCTAssertTrue(flow.isAbandoned)
    XCTAssertFalse(flow.isFinished)
  }

  func testAYNABPlanRefusesTheUploadWithoutARetry() async throws {
    try await seedLocalLedger()
    let flow = ServerConnectFlow(local: local, signedIn: server)
    await flow.check()
    ServerEngineProtocol.forcedImportResponse = (409, #"{"error":{"id":"409","name":"ynab_mirror_plan","detail":"This plan mirrors YNAB"}}"#)

    let adopted = await flow.upload()

    XCTAssertNil(adopted)
    XCTAssertEqual(flow.step, .refused(SnapshotImport.ynabMirrorMessage))
  }

  func testAnEditorCannotUpload() async throws {
    try await seedLocalLedger()
    let flow = ServerConnectFlow(local: local, signedIn: server)
    await flow.check()
    ServerEngineProtocol.forcedImportResponse = (403, #"{"error":{"id":"403","name":"forbidden","detail":"Plan owner access is required"}}"#)

    let adopted = await flow.upload()

    XCTAssertNil(adopted)
    XCTAssertEqual(flow.step, .refused(SnapshotImport.ownerRequiredMessage))
    XCTAssertEqual(ServerEngineProtocol.importCount, 0)
  }

  func testAServerWithRecordsIsNeverUploadedTo() async throws {
    try await seedLocalLedger()
    _ = try await APIClient(settings: server).createAccount(planID: server.planID, name: "Joint", type: "checking", balance: 0, icon: nil, onBudget: true)
    let flow = ServerConnectFlow(local: local, signedIn: server)

    await flow.check()

    XCTAssertEqual(flow.step, .serverHasData)
    XCTAssertEqual(ServerEngineProtocol.importCount, 0)
    let serverAccounts = try await ledger(server).accounts
    XCTAssertEqual(serverAccounts.count, 1)
  }

  /// Someone adds records between the check and the upload.
  func testRecordsAddedDuringTheFlowLeadToTheChoice() async throws {
    try await seedLocalLedger()
    let flow = ServerConnectFlow(local: local, signedIn: server)
    await flow.check()
    guard case .confirmUpload = flow.step else {
      return XCTFail("Expected the upload question, got \(flow.step)")
    }
    _ = try await APIClient(settings: server).createAccount(planID: server.planID, name: "Joint", type: "checking", balance: 0, icon: nil, onBudget: true)

    let adopted = await flow.upload()

    XCTAssertNil(adopted)
    XCTAssertEqual(flow.step, .serverHasData)
    let serverAccounts = try await ledger(server).accounts
    XCTAssertEqual(serverAccounts.count, 1)
  }

  func testSwitchingToTheServerAndBackPersists() async throws {
    try requireUsableKeychain()
    try await seedLocalLedger()
    let archivedAt = Date(timeIntervalSince1970: 1_790_000_000)

    // An older session for the same server, left from an earlier connection.
    var earlier = server
    earlier.sessionToken = "old-token"
    earlier.save(to: UserDefaults(suiteName: suiteName + ".earlier")!)

    let adoption = ConnectionSwitch.adoptServer(server, leaving: local, databaseURL: localDatabase, in: defaults, now: archivedAt)

    let loaded = APISettings.load(from: defaults)
    XCTAssertEqual(adoption.settings, server)
    XCTAssertEqual(adoption.supersededToken, "old-token", "The replaced session is handed back to be signed out")
    XCTAssertEqual(loaded.mode, .server)
    XCTAssertEqual(loaded.planID, "plan_server")
    XCTAssertEqual(loaded.sessionToken, "server-token")
    XCTAssertEqual(LocalArchive.existing(in: defaults), LocalArchive(databaseURL: localDatabase, planID: local.planID, archivedAt: archivedAt))

    // The archive can still be exported while the app uses the server.
    let archive = try XCTUnwrap(LocalArchive.existing(in: defaults))
    let exported = try await ServerConnector.exportArchive(archive)
    XCTAssertEqual(try SnapshotImport.summary(of: exported).accounts, 2)

    let restored = try XCTUnwrap(ConnectionSwitch.returnToArchive(leaving: server, in: defaults))
    XCTAssertEqual(restored.mode, .local)
    XCTAssertEqual(restored.planID, local.planID)
    XCTAssertNil(LocalArchive.load(from: defaults))
    let reloaded = APISettings.load(from: defaults)
    XCTAssertTrue(reloaded.isLocal)
    XCTAssertEqual(reloaded.planID, local.planID)
    XCTAssertNil(APISettings.savedSessionToken(forBaseURL: Self.serverURL), "Switching back forgets the server session")
    let restoredAccounts = try await ledger(reloaded).accounts
    XCTAssertEqual(restoredAccounts.count, 2)
  }

  func testForgettingTheServerSessionLeavesLocalModeAlone() throws {
    try requireUsableKeychain()
    // A session from an earlier connection, saved while in local mode.
    server.save(to: defaults)
    local.save(to: defaults)
    XCTAssertEqual(APISettings.savedSessionToken(forBaseURL: Self.serverURL), "server-token")

    APISettings.forgetSavedSession(forBaseURL: Self.serverURL)

    XCTAssertNil(APISettings.savedSessionToken(forBaseURL: Self.serverURL))
    let reloaded = APISettings.load(from: defaults)
    XCTAssertTrue(reloaded.isLocal)
    XCTAssertEqual(reloaded.sessionToken, local.sessionToken)
  }

  private func requireUsableKeychain() throws {
    APISettings(baseURLString: "https://keychain-probe.example.test", sessionToken: "probe").save(to: defaults)
    defer { defaults.removeObject(forKey: APISettings.userDefaultsKey) }
    guard APISettings.savedSessionToken(forBaseURL: "https://keychain-probe.example.test") == "probe" else {
      throw XCTSkip("This test host has no usable Keychain.")
    }
  }
}

/// Answers requests to the test server host from an on-device engine.
private final class ServerEngineProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var engine: LocalEngine?
  nonisolated(unsafe) private static var config: LocalEngineConfig?
  nonisolated(unsafe) private static var imports = 0
  /// Answers `import_snapshot` with this instead of asking the engine.
  nonisolated(unsafe) static var forcedImportResponse: (status: Int, body: String)?
  /// Runs off the main thread once the engine has answered an import, before
  /// the response reaches the app.
  nonisolated(unsafe) static var beforeImportResponse: (() -> Void)?

  static func install(engine: LocalEngine, config: LocalEngineConfig) {
    lock.withLock {
      self.engine = engine
      self.config = config
      imports = 0
    }
  }

  static func reset() {
    lock.withLock {
      engine = nil
      config = nil
      imports = 0
      forcedImportResponse = nil
      beforeImportResponse = nil
    }
  }

  static var importCount: Int {
    lock.withLock { imports }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "connect-server.test"
  }

  override class func canInit(with task: URLSessionTask) -> Bool {
    (task.currentRequest ?? task.originalRequest).map { canInit(with: $0) } ?? false
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let request = self.request
    let (engine, config) = Self.lock.withLock { (Self.engine, Self.config) }
    guard let engine, let config, let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
    let isImport = components.path.hasSuffix("/import_snapshot")
    let (forced, hook) = Self.lock.withLock { (Self.forcedImportResponse, Self.beforeImportResponse) }
    Task {
      do {
        let result: LocalEngineResponse
        if isImport, let forced {
          result = LocalEngineResponse(status: forced.status, headers: ["content-type": "application/json"], body: Data(forced.body.utf8))
        } else {
          result = try await engine.handle(
            config: config,
            method: request.httpMethod ?? "GET",
            path: components.percentEncodedPath,
            query: components.percentEncodedQuery,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
          )
        }
        // Counts imports that wrote rows, not replays of an earlier one.
        if isImport, result.status == 201, String(decoding: result.body, as: UTF8.self).contains(#""replayed":false"#) {
          Self.lock.withLock { Self.imports += 1 }
        }
        if isImport {
          hook?()
        }
        let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: result.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }
  }

  override func stopLoading() {}

  private static func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
