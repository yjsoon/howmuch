import XCTest
@testable import HowMuch

// MARK: - Fixtures

/// Every value here is invented. No real ledger row, payee or memo appears in
/// these tests.
private enum SnapshotFixture {
  static let planID = "plan-1"
  static let userID = "user-1"
  static let baseURL = "https://howmuch-reference-snapshot.test"

  static func settings(
    baseURL: String = baseURL,
    userID: String = userID,
    planID: String = planID,
    sessionToken: String = "token"
  ) -> APISettings {
    var settings = APISettings()
    settings.baseURLString = baseURL
    settings.authenticatedUserID = userID
    settings.sessionToken = sessionToken
    settings.planID = planID
    return settings
  }

  static func account(id: String = "acct-1", name: String = "Fixture Account") -> Account {
    Account(
      id: id,
      name: name,
      icon: nil,
      type: "checking",
      onBudget: true,
      closed: false,
      balance: 123_400,
      clearedBalance: 123_400,
      unclearedBalance: 0,
      lastReconciledDate: nil,
      deleted: false
    )
  }

  static func categoryGroup(id: String = "group-1") -> CategoryGroup {
    CategoryGroup(
      id: id,
      name: "Fixture Group",
      hidden: false,
      deleted: false,
      categories: [
        Category(id: "\(id)-cat-1", categoryGroupID: id, name: "Fixture Category", deleted: false)
      ]
    )
  }

  static func payee(id: String = "payee-1") -> Payee {
    Payee(id: id, name: "Fixture Payee", transferAccountId: nil, deleted: false)
  }

  static func transaction(
    id: String,
    accountID: String = "acct-1",
    date: String = "2026-01-02",
    amount: Int = -1230,
    approved: Bool = true
  ) -> Transaction {
    Transaction(
      id: id,
      date: date,
      amount: amount,
      memo: nil,
      cleared: .uncleared,
      approved: approved,
      flagColor: nil,
      flagName: nil,
      accountID: accountID,
      accountName: "Fixture Account",
      payeeID: "payee-1",
      payeeName: "Fixture Payee",
      categoryID: nil,
      categoryName: nil,
      transferAccountID: nil,
      transferTransactionID: nil,
      parentTransactionID: nil,
      matchedTransactionID: nil,
      importID: nil,
      importPayeeName: nil,
      importPayeeNameOriginal: nil,
      deleted: false,
      subtransactions: []
    )
  }

  static func schedule(id: String = "sched-1") -> ScheduledTransaction {
    ScheduledTransaction(
      id: id,
      dateFirst: "2026-01-01",
      dateNext: "2026-02-01",
      frequency: "monthly",
      amount: -5000,
      memo: nil,
      flagColor: nil,
      accountID: "acct-1",
      payeeID: "payee-1",
      categoryID: nil,
      transferAccountID: nil,
      deleted: false,
      subtransactions: []
    )
  }

  static func snapshot(
    settings: APISettings,
    serverKnowledge: Int? = 7,
    accounts: [Account] = [account()],
    transactions: [Transaction] = [transaction(id: "snapshot-row")],
    hasMore: Bool = false,
    nextOffset: Int? = nil,
    unapprovedCount: Int? = nil,
    schemaVersion: Int = ReferenceSnapshot.currentSchemaVersion
  ) -> ReferenceSnapshot {
    ReferenceSnapshot(
      schemaVersion: schemaVersion,
      connectionFingerprint: settings.connectionFingerprint,
      authenticatedUserID: settings.authenticatedUserID,
      planID: settings.planID,
      serverKnowledge: serverKnowledge,
      // A whole second: the file stores ISO-8601, which carries no fractional
      // part, so a `Date()` would not survive the round trip exactly and the
      // whole-snapshot comparison below would be about clock precision rather
      // than about the encoding.
      capturedAt: Date(timeIntervalSince1970: 1_770_000_000),
      planSettings: PlanSettings(
        dateFormat: DateFormat(format: "YYYY-MM-DD"),
        currencyFormat: CurrencyFormat(
          isoCode: "SGD",
          exampleFormat: "123,456.78",
          decimalDigits: 2,
          decimalSeparator: ".",
          groupSeparator: ",",
          symbolFirst: true,
          currencySymbol: "$"
        ),
        display: DisplaySettings(flagNames: ["Fixture flag"])
      ),
      accounts: accounts,
      categoryGroups: [categoryGroup()],
      payees: [payee()],
      accountPreferences: nil,
      scheduledTransactions: [schedule()],
      ledgerPage: ReferenceSnapshot.LedgerPage(
        transactions: transactions,
        hasMore: hasMore,
        nextOffset: nextOffset
      ),
      unapprovedCount: unapprovedCount
    )
  }

  /// A store rooted in a fresh temporary directory, so no test ever reads or
  /// writes the app's real Application Support container.
  static func temporaryStore() -> SnapshotStore {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("HowMuchSnapshotTests/\(UUID().uuidString)", isDirectory: true)
    return SnapshotStore(directory: directory)
  }
}

// MARK: - Store and policy (pure)

/// #176: load/save/delete and the pure admission rules. Nothing here touches
/// the network or the real container.
final class ReferenceSnapshotStoreTests: XCTestCase {
  private var store = SnapshotFixture.temporaryStore()

  override func setUp() {
    super.setUp()
    store = SnapshotFixture.temporaryStore()
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: store.directory)
    super.tearDown()
  }

  func testSaveLoadDeleteRoundTrip() {
    let settings = SnapshotFixture.settings()
    let snapshot = SnapshotFixture.snapshot(settings: settings)

    XCTAssertNil(store.load(), "a fresh directory holds no snapshot")
    XCTAssertTrue(store.save(snapshot))

    let loaded = store.load()
    XCTAssertEqual(loaded, snapshot, "the snapshot must survive the file round trip unchanged")

    store.delete()
    XCTAssertNil(store.load(), "delete must leave nothing to load")
  }

  func testScheduledWriteLandsAndIsReadableSynchronously() {
    let settings = SnapshotFixture.settings()
    store.scheduleWrite(SnapshotFixture.snapshot(settings: settings))
    store.waitForPendingWrites()

    XCTAssertEqual(store.load()?.planID, settings.planID)
  }

  func testBackToBackScheduledWritesLeaveTheLatestSnapshot() {
    let settings = SnapshotFixture.settings()
    store.scheduleWrite(SnapshotFixture.snapshot(settings: settings, serverKnowledge: 1))
    store.scheduleWrite(SnapshotFixture.snapshot(settings: settings, serverKnowledge: 2))
    store.waitForPendingWrites()

    XCTAssertEqual(store.load()?.serverKnowledge, 2, "coalesced writes must keep the newest snapshot")
  }

  func testWritesQueuedBehindABusyWriterCoalesceIntoOne() {
    let settings = SnapshotFixture.settings()
    let release = DispatchSemaphore(value: 0)
    store.ioQueue.async { release.wait() }

    for knowledge in 1 ... 3 {
      store.scheduleWrite(SnapshotFixture.snapshot(settings: settings, serverKnowledge: knowledge))
    }
    release.signal()
    store.waitForPendingWrites()

    XCTAssertEqual(store.completedWriteCount, 1, "snapshots queued behind one drain must be encoded and written once")
    XCTAssertEqual(store.load()?.serverKnowledge, 3, "the one write must carry the newest snapshot")
  }

  func testAWriteScheduledAfterADeleteStillLands() {
    let settings = SnapshotFixture.settings()
    store.scheduleWrite(SnapshotFixture.snapshot(settings: settings))
    store.delete()
    store.scheduleWrite(SnapshotFixture.snapshot(settings: settings))
    store.waitForPendingWrites()

    XCTAssertEqual(store.load()?.planID, settings.planID, "only writes queued before the delete are dropped")
  }

  func testDeleteBeatsAWriteQueuedBeforeIt() {
    let settings = SnapshotFixture.settings()
    XCTAssertTrue(store.save(SnapshotFixture.snapshot(settings: settings)))

    store.scheduleWrite(SnapshotFixture.snapshot(settings: settings))
    store.delete()
    store.waitForPendingWrites()

    XCTAssertNil(
      store.load(),
      "a write queued before a sign-out must not land after it and resurrect the file"
    )
  }

  func testCorruptFileLoadsAsNilAndDeletesItself() throws {
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: store.fileURL)

    XCTAssertNil(store.load(), "a snapshot that will not decode must never be applied")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: store.fileURL.path),
      "a corrupt file must delete itself rather than fail on every launch"
    )
  }

  func testPolicyAcceptsAMatchingSnapshot() {
    let settings = SnapshotFixture.settings()
    XCTAssertNil(
      SnapshotPolicy.rejection(snapshot: SnapshotFixture.snapshot(settings: settings), settings: settings)
    )
  }

  func testPolicyRejectsADifferentConnection() {
    let settings = SnapshotFixture.settings()
    let otherEndpoint = SnapshotFixture.settings(baseURL: "https://howmuch-elsewhere.test")
    XCTAssertEqual(
      SnapshotPolicy.rejection(
        snapshot: SnapshotFixture.snapshot(settings: otherEndpoint),
        settings: settings
      ),
      .differentConnection
    )
  }

  func testPolicyRejectsADifferentUserEvenWithAMatchingFingerprint() {
    let settings = SnapshotFixture.settings()
    var snapshot = SnapshotFixture.snapshot(settings: settings)
    // Forge the joined fingerprint so only the explicit user check can catch
    // this: one user's ledger must never render under another's session.
    snapshot.authenticatedUserID = "someone-else"
    XCTAssertEqual(SnapshotPolicy.rejection(snapshot: snapshot, settings: settings), .differentUser)
  }

  func testPolicyRejectsADifferentPlanEvenWithAMatchingFingerprint() {
    let settings = SnapshotFixture.settings()
    var snapshot = SnapshotFixture.snapshot(settings: settings)
    snapshot.planID = "plan-2"
    XCTAssertEqual(SnapshotPolicy.rejection(snapshot: snapshot, settings: settings), .differentPlan)
  }

  func testPolicyRejectsAnOlderSchema() {
    let settings = SnapshotFixture.settings()
    let snapshot = SnapshotFixture.snapshot(
      settings: settings,
      schemaVersion: ReferenceSnapshot.currentSchemaVersion - 1
    )
    XCTAssertEqual(SnapshotPolicy.rejection(snapshot: snapshot, settings: settings), .schemaMismatch)
  }

  func testPolicyRejectsASignedOutSessionAndAnUnselectedPlan() {
    let settings = SnapshotFixture.settings()
    let snapshot = SnapshotFixture.snapshot(settings: settings)

    var signedOut = settings
    signedOut.sessionToken = ""
    XCTAssertEqual(SnapshotPolicy.rejection(snapshot: snapshot, settings: signedOut), .notAuthenticated)

    var noPlan = settings
    noPlan.planID = ""
    XCTAssertEqual(SnapshotPolicy.rejection(snapshot: snapshot, settings: noPlan), .noPlanSelected)
  }

  func testPolicyRejectsAnEmptySnapshot() {
    let settings = SnapshotFixture.settings()
    let snapshot = SnapshotFixture.snapshot(settings: settings, accounts: [])
    XCTAssertEqual(SnapshotPolicy.rejection(snapshot: snapshot, settings: settings), .empty)
  }

  /// The skip exists to avoid a pointless re-render, so it may only fire when
  /// the cursors agree *and* the response covers the same rows.
  func testLedgerApplyIsRedundantOnlyWhenCursorsAndRowsAgree() {
    func redundant(
      provisional: Bool = true,
      snapshot: Int? = 7,
      response: Int? = 7,
      snapshotRows: [String] = ["a", "b"],
      responseRows: [String] = ["a", "b"]
    ) -> Bool {
      SnapshotPolicy.ledgerApplyIsRedundant(
        isProvisional: provisional,
        snapshotKnowledge: snapshot,
        responseKnowledge: response,
        snapshotRowIDs: snapshotRows,
        responseRowIDs: responseRows
      )
    }

    XCTAssertTrue(redundant())
    XCTAssertFalse(redundant(response: 8), "a cursor that moved always applies")
    XCTAssertFalse(redundant(snapshot: nil), "an unknown cursor proves nothing")
    XCTAssertFalse(redundant(response: nil))
    XCTAssertFalse(
      redundant(provisional: false),
      "rows the network already replaced are not a snapshot and must always be applied"
    )
    XCTAssertFalse(
      redundant(responseRows: ["a", "b", "c"]),
      "a wider page at the same cursor — `transactionPageSize` is not in the schema version — must not be skipped, or its extra rows are lost for the session"
    )
    XCTAssertFalse(
      redundant(responseRows: ["b", "a"]),
      "the same ids in a different order are a different page"
    )
  }

  /// Keeps an eye on what the cache costs on disk. The counts are a generous
  /// synthetic plan; the measured size is printed so it can be quoted.
  func testSnapshotStaysSmallAtRealisticCounts() {
    var settings = SnapshotFixture.settings()
    settings.planID = SnapshotFixture.planID
    let snapshot = ReferenceSnapshot(
      connectionFingerprint: settings.connectionFingerprint,
      authenticatedUserID: settings.authenticatedUserID,
      planID: settings.planID,
      serverKnowledge: 7,
      planSettings: nil,
      accounts: (0..<40).map { SnapshotFixture.account(id: "acct-\($0)", name: "Account \($0)") },
      categoryGroups: (0..<30).map { SnapshotFixture.categoryGroup(id: "group-\($0)") },
      payees: (0..<800).map { SnapshotFixture.payee(id: "payee-\($0)") },
      accountPreferences: nil,
      scheduledTransactions: (0..<60).map { SnapshotFixture.schedule(id: "sched-\($0)") },
      ledgerPage: ReferenceSnapshot.LedgerPage(
        transactions: (0..<100).map { SnapshotFixture.transaction(id: "txn-\($0)") },
        hasMore: true,
        nextOffset: 100
      )
    )

    XCTAssertTrue(store.save(snapshot))
    let size = store.fileSize() ?? 0
    print("ReferenceSnapshot size at 40 accounts / 30 groups / 800 payees / 60 schedules / 100 rows: \(size) bytes")
    XCTAssertGreaterThan(size, 0)
    XCTAssertLessThan(
      size,
      1_500_000,
      "the snapshot is a launch cache, not an archive; a megabyte-and-a-half is already too much"
    )
  }
}

// MARK: - Launch behaviour

/// #176 end to end: a warm launch renders from the snapshot before the network
/// answers, the network then replaces it, and nothing older than the current
/// `server_knowledge` is left behind (#144).
@MainActor
final class ReferenceSnapshotLaunchTests: XCTestCase {
  private var previousCredentialService = ""
  private var previousAPISettings: Any?
  private var previousScopedViewPrefs: Any?
  private var previousOutbox: Any?
  private var store = SnapshotFixture.temporaryStore()

  override func setUp() {
    super.setUp()
    previousCredentialService = APISettings.useCredentialService(
      "HowMuch.ReferenceSnapshotTests.\(UUID().uuidString)"
    )
    // The model writes its connection into `UserDefaults.standard` under the
    // app's real keys; save and restore them so this fixture host never leaks
    // into another test or the installed app.
    previousAPISettings = UserDefaults.standard.object(forKey: APISettings.userDefaultsKey)
    previousScopedViewPrefs = UserDefaults.standard.object(forKey: ScopedViewPrefsStore.userDefaultsKey)
    previousOutbox = UserDefaults.standard.object(forKey: OutboxStore.userDefaultsKey)
    UserDefaults.standard.removeObject(forKey: OutboxStore.userDefaultsKey)
    store = SnapshotFixture.temporaryStore()
    XCTAssertTrue(URLProtocol.registerClass(SnapshotRefreshProtocol.self))
    SnapshotRefreshProtocol.reset()
  }

  override func tearDown() {
    SnapshotRefreshProtocol.releaseResponses()
    URLProtocol.unregisterClass(SnapshotRefreshProtocol.self)
    APISettings.useCredentialService(previousCredentialService)
    UserDefaults.standard.set(previousAPISettings, forKey: APISettings.userDefaultsKey)
    UserDefaults.standard.set(previousScopedViewPrefs, forKey: ScopedViewPrefsStore.userDefaultsKey)
    UserDefaults.standard.set(previousOutbox, forKey: OutboxStore.userDefaultsKey)
    try? FileManager.default.removeItem(at: store.directory)
    super.tearDown()
  }

  private func fixtureSettings() -> APISettings {
    SnapshotFixture.settings(baseURL: SnapshotRefreshProtocol.fixtureBaseURL)
  }

  /// The acceptance criterion of #176: a warm launch shows the Accounts tab
  /// from the snapshot, and a loud refresh that is still waiting on the server
  /// must not replace it with a spinner.
  func testWarmLaunchIsLoadedBeforeAnyResponseArrives() async {
    let settings = fixtureSettings()
    // A cursor behind the server's, so this launch's response is known to
    // describe different rows and must replace what the snapshot put up.
    XCTAssertTrue(
      store.save(
        SnapshotFixture.snapshot(
          settings: settings,
          serverKnowledge: SnapshotRefreshProtocol.serverKnowledge - 1
        )
      )
    )
    SnapshotRefreshProtocol.holdResponses()

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)

    XCTAssertEqual(model.referencePhase, .loaded, "the snapshot must render without a request")
    XCTAssertEqual(model.ledgerPhase, .loaded)
    XCTAssertEqual(model.scheduledTransactionsPhase, .loaded)
    XCTAssertEqual(model.accounts.map(\.id), ["acct-1"])
    XCTAssertEqual(model.transactions.map(\.id), ["snapshot-row"])
    XCTAssertTrue(model.isProvisional)

    let refresh = Task { await model.refreshAll() }
    // `/v1/plans` answers immediately (the stub never holds it), so the three
    // slice fetches actually start; wait until each has been issued and is
    // sitting held, which is the only point at which the "must not blank a
    // provisional view" guards have all run.
    let asked = await waitUntil {
      SnapshotRefreshProtocol.hasSeenEverySlice()
    }
    XCTAssertTrue(
      asked,
      "the launch refresh must issue the reference, ledger and schedule fetches, saw \(SnapshotRefreshProtocol.paths())"
    )
    XCTAssertEqual(
      model.referencePhase,
      .loaded,
      "a loud refresh must not blank a snapshot the reader is already looking at"
    )
    XCTAssertEqual(model.ledgerPhase, .loaded)
    XCTAssertEqual(model.scheduledTransactionsPhase, .loaded)
    XCTAssertEqual(
      model.transactions.map(\.id),
      ["snapshot-row"],
      "the register must still be showing the snapshot's page while the fetch is in flight"
    )
    XCTAssertEqual(
      model.hasMoreTransactions,
      false,
      "the loud path's cursor reset must be skipped too, or the register loses its paging state mid-refresh"
    )

    SnapshotRefreshProtocol.releaseResponses()
    await refresh.value

    XCTAssertFalse(model.isProvisional, "the network response must take ownership of the screen")
    XCTAssertEqual(
      model.accounts.map(\.id),
      [SnapshotRefreshProtocol.networkAccountID],
      "the accounts on screen after the refresh must be the ones the server just returned"
    )
    XCTAssertEqual(
      model.transactions.map(\.id),
      [SnapshotRefreshProtocol.networkTransactionID],
      "no row older than the current server_knowledge may survive the refresh"
    )
  }

  /// The cursor the snapshot was written at equals the one the server returns
  /// *and* the page covers the same ids, so the rows are known to be the same
  /// rows and the apply is skipped. The differing amount below cannot happen
  /// against a real server — at one cursor the contents are fixed — and exists
  /// only to make the skip observable.
  func testEqualServerKnowledgeSkipsTheLedgerApply() async {
    let settings = fixtureSettings()
    XCTAssertTrue(
      store.save(
        SnapshotFixture.snapshot(
          settings: settings,
          serverKnowledge: SnapshotRefreshProtocol.serverKnowledge,
          transactions: [
            SnapshotFixture.transaction(
              id: SnapshotRefreshProtocol.networkTransactionID,
              date: "2026-01-03",
              amount: -1230
            )
          ]
        )
      )
    )

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    await model.refreshAll()

    XCTAssertEqual(model.transactions.map(\.id), [SnapshotRefreshProtocol.networkTransactionID])
    XCTAssertEqual(
      model.transactions.first?.amount,
      -1230,
      "a response at the snapshot's own cursor, covering the same ids, must not be re-applied"
    )
    XCTAssertFalse(model.ledgerIsProvisional, "the rows are still validated by this refresh")
  }

  /// The page size is a compile-time constant that the schema version does not
  /// cover, so a response carrying rows the snapshot never held must apply even
  /// at an identical cursor.
  func testAWiderPageAtTheSameCursorStillApplies() async {
    let settings = fixtureSettings()
    XCTAssertTrue(
      store.save(
        SnapshotFixture.snapshot(
          settings: settings,
          serverKnowledge: SnapshotRefreshProtocol.serverKnowledge,
          transactions: []
        )
      )
    )

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    await model.refreshAll()

    XCTAssertEqual(
      model.transactions.map(\.id),
      [SnapshotRefreshProtocol.networkTransactionID],
      "a row the snapshot's page never held must not be dropped by the equal-cursor skip"
    )
  }

  /// A cursor that has moved is proof the rows differ, so the response always
  /// replaces the snapshot — never merges onto it (#144).
  func testAdvancedServerKnowledgeReplacesSnapshotRows() async {
    let settings = fixtureSettings()
    XCTAssertTrue(
      store.save(
        SnapshotFixture.snapshot(
          settings: settings,
          serverKnowledge: SnapshotRefreshProtocol.serverKnowledge - 1
        )
      )
    )

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    await model.refreshAll()

    XCTAssertEqual(
      model.transactions.map(\.id),
      [SnapshotRefreshProtocol.networkTransactionID],
      "a snapshot row the server no longer returns must not remain on screen"
    )
  }

  /// An offline warm launch never reaches a plan-scoped request:
  /// `resolvePlanSelection()` fails and `refreshAll` returns. Without a report
  /// against the restored phases the app would sit on unvalidated data with
  /// every phase claiming `.loaded`.
  func testOfflineWarmLaunchReportsTheFailureAndKeepsTheRows() async {
    let settings = fixtureSettings()
    XCTAssertTrue(store.save(SnapshotFixture.snapshot(settings: settings)))
    SnapshotRefreshProtocol.goOffline()

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    await model.refreshAll()

    XCTAssertNotNil(
      model.referencePhase.errorMessage,
      "an offline launch must not leave the reference phase claiming it loaded"
    )
    XCTAssertNotNil(model.ledgerPhase.errorMessage)
    XCTAssertNotNil(model.scheduledTransactionsPhase.errorMessage)
    XCTAssertEqual(
      model.accounts.map(\.id),
      ["acct-1"],
      "the snapshot stays on screen behind the failure, as in-memory data does after a failed refresh"
    )
    XCTAssertEqual(model.transactions.map(\.id), ["snapshot-row"])
    XCTAssertTrue(model.isProvisional)
  }

  /// A pull on a provisional Accounts tab must fetch the whole reference
  /// batch. The phase alone says `.loaded` from the snapshot, so the pull
  /// would otherwise ask for balances and leave categories, payees and plan
  /// settings unvalidated for the rest of the launch.
  func testPullOnAProvisionalAccountsTabFetchesTheReferenceBatch() async {
    XCTAssertEqual(
      TabRefresh.accounts(referencePhase: .loaded, isReferenceProvisional: true),
      [.referenceData]
    )
    XCTAssertEqual(
      TabRefresh.accounts(referencePhase: .loaded, isReferenceProvisional: false),
      [.accounts]
    )

    let settings = fixtureSettings()
    XCTAssertTrue(store.save(SnapshotFixture.snapshot(settings: settings)))
    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    XCTAssertTrue(model.referenceIsProvisional)

    await model.refresh(
      slices: TabRefresh.accounts(
        referencePhase: model.referencePhase,
        isReferenceProvisional: model.referenceIsProvisional
      ),
      quiet: false
    )

    let plan = "/v1/plans/\(SnapshotRefreshProtocol.planID)"
    XCTAssertTrue(
      SnapshotRefreshProtocol.paths().contains("\(plan)/categories"),
      "the pull must fetch the reference batch, saw \(SnapshotRefreshProtocol.paths())"
    )
    XCTAssertFalse(model.referenceIsProvisional)
  }

  /// After a failed launch ledger fetch the rows stay provisional. A reader
  /// can still scroll older pages in; the next quiet refresh must displace the
  /// snapshot's own rows (#144) without dropping the pages fetched since.
  func testQuietRefreshDisplacesSnapshotRowsButKeepsScrolledInPages() async {
    let settings = fixtureSettings()
    XCTAssertTrue(
      store.save(
        SnapshotFixture.snapshot(
          settings: settings,
          serverKnowledge: SnapshotRefreshProtocol.serverKnowledge - 1,
          hasMore: true,
          nextOffset: SnapshotRefreshProtocol.olderPageOffset
        )
      )
    )

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    await model.loadOlderTransactions()
    XCTAssertEqual(
      model.transactions.map(\.id),
      ["snapshot-row", SnapshotRefreshProtocol.olderTransactionID],
      "the older page must land under the provisional first page"
    )

    await model.refresh(slices: [.ledger], quiet: true)

    XCTAssertEqual(
      model.transactions.map(\.id),
      [SnapshotRefreshProtocol.networkTransactionID, SnapshotRefreshProtocol.olderTransactionID],
      "the response must displace the snapshot's row and leave the scrolled-in page alone"
    )
    XCTAssertFalse(model.ledgerIsProvisional)
  }

  /// A server-side session revocation is a sign-out the app did not initiate.
  func testSessionRevocationDeletesTheSnapshot() async {
    let settings = fixtureSettings()
    XCTAssertTrue(store.save(SnapshotFixture.snapshot(settings: settings)))
    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    XCTAssertTrue(model.isProvisional)

    NotificationCenter.default.post(
      name: .howMuchAuthenticationExpired,
      object: settings.sessionToken
    )
    let cleared = await waitUntil { !model.settings.isAuthenticated }
    XCTAssertTrue(cleared, "the revocation must sign the session out")

    store.waitForPendingWrites()
    XCTAssertNil(store.load(), "a revoked session must leave no cached plan data on the device")
    XCTAssertFalse(model.isProvisional)
  }

  /// #181's "New" tile is drawn from a count, and since #197 that count is a
  /// request of its own. A warm launch shows the number the snapshot carries
  /// rather than flashing 0 while the request is in flight, and the server's
  /// answer replaces it.
  func testWarmLaunchShowsTheStoredUnapprovedCountUntilTheServerAnswers() async {
    let settings = fixtureSettings()
    XCTAssertTrue(
      store.save(
        SnapshotFixture.snapshot(
          settings: settings,
          serverKnowledge: SnapshotRefreshProtocol.serverKnowledge - 1,
          unapprovedCount: 9
        )
      )
    )

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    XCTAssertEqual(
      model.unapprovedBadgeCount,
      9,
      "the tile must not flash 0 while the count request is in flight"
    )

    await model.refreshAll()
    let counted = await waitUntil {
      model.unapprovedBadgeCount == SnapshotRefreshProtocol.networkUnapprovedCount
    }
    XCTAssertTrue(
      counted,
      "the server's count must replace the stored one, saw \(model.unapprovedBadgeCount)"
    )

    // …and the fresh number is what the next launch would restore.
    store.waitForPendingWrites()
    XCTAssertEqual(store.load()?.unapprovedCount, SnapshotRefreshProtocol.networkUnapprovedCount)
  }

  /// A delete used to wipe the snapshot, so the next launch -- offline, say --
  /// started cold. It now writes the repaired page at once: the deleted row is
  /// gone from it, and a row rejected from the "New" queue is off the stored
  /// count, even when every follow-up read fails.
  func testDeletePersistsTheRepairedSnapshotWhenFollowUpReadsFail() async throws {
    let settings = fixtureSettings()
    XCTAssertTrue(
      store.save(
        SnapshotFixture.snapshot(
          settings: settings,
          serverKnowledge: SnapshotRefreshProtocol.serverKnowledge - 1
        )
      )
    )
    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    await model.refreshAll()
    let counted = await waitUntil {
      model.unapprovedBadgeCount == SnapshotRefreshProtocol.networkUnapprovedCount
    }
    XCTAssertTrue(counted, "the server's count must land before the delete")
    XCTAssertFalse(model.isProvisional, "the launch refresh must own the screen before the delete")
    XCTAssertEqual(model.transactions.map(\.id), [SnapshotRefreshProtocol.networkTransactionID])

    // Every read after the delete fails, as it would if the connection
    // dropped straight after the write.
    SnapshotRefreshProtocol.goOfflineAfterDelete()
    let row = SnapshotFixture.transaction(
      id: SnapshotRefreshProtocol.networkTransactionID,
      accountID: SnapshotRefreshProtocol.networkAccountID,
      approved: false
    )
    try await model.deleteTransaction(row)
    XCTAssertEqual(model.unapprovedBadgeCount, SnapshotRefreshProtocol.networkUnapprovedCount - 1)
    await model.refresh(slices: [.accounts, .ledger])

    store.waitForPendingWrites()
    let persisted = try XCTUnwrap(store.load(), "a delete must not leave the next launch cold")
    XCTAssertEqual(persisted.ledgerPage?.transactions.map(\.id), [])
    // The network row (-4560, uncleared) comes off its account's balances.
    let persistedAccount = try XCTUnwrap(persisted.accounts.first)
    XCTAssertEqual(persistedAccount.balance, 999 + 4_560, "the saved balance must not still count the deleted row")
    XCTAssertEqual(persistedAccount.clearedBalance, 999)
    XCTAssertEqual(persistedAccount.unclearedBalance, 4_560)
    XCTAssertEqual(
      persisted.unapprovedCount,
      SnapshotRefreshProtocol.networkUnapprovedCount - 1,
      "the rejected row must not come back on the tile at the next launch"
    )

    let relaunched = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    XCTAssertEqual(relaunched.referencePhase, .loaded)
    XCTAssertEqual(relaunched.accounts.map(\.id), [SnapshotRefreshProtocol.networkAccountID])
    XCTAssertTrue(relaunched.transactions.isEmpty)
    XCTAssertEqual(relaunched.unapprovedBadgeCount, SnapshotRefreshProtocol.networkUnapprovedCount - 1)
  }

  func testSignOutDeletesTheSnapshot() async {
    let settings = fixtureSettings()
    XCTAssertTrue(store.save(SnapshotFixture.snapshot(settings: settings)))

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    XCTAssertTrue(model.isProvisional)

    var signedOut = settings
    signedOut.sessionToken = ""
    signedOut.authenticatedUserID = ""
    signedOut.planID = ""
    await model.applySettings(signedOut)

    store.waitForPendingWrites()
    XCTAssertNil(store.load(), "signing out must leave no cached plan data on the device")
    XCTAssertFalse(model.isProvisional)
    XCTAssertTrue(model.accounts.isEmpty)
  }

  /// A snapshot belonging to another signed-in user is never applied, and is
  /// not left on disk to be reconsidered on the next launch.
  func testAnotherUsersSnapshotIsDiscardedOnLaunch() {
    let other = SnapshotFixture.settings(
      baseURL: SnapshotRefreshProtocol.fixtureBaseURL,
      userID: "someone-else"
    )
    XCTAssertTrue(store.save(SnapshotFixture.snapshot(settings: other)))

    let model = AppModel(settings: fixtureSettings(), viewPrefs: ViewPrefs(), snapshotStore: store)

    XCTAssertEqual(model.referencePhase, .idle)
    XCTAssertTrue(model.accounts.isEmpty)
    XCTAssertFalse(model.isProvisional)
    XCTAssertNil(store.load(), "a snapshot that can never be applied must not be kept")
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if condition() {
        return true
      }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }
}

// MARK: - Stub server

private final class SnapshotRefreshLog: @unchecked Sendable {
  static let shared = SnapshotRefreshLog()
  private let lock = NSLock()
  private var recorded: [String] = []
  private var held = false
  private var offline = false
  private var offlineAfterDelete = false
  private var pending: [SnapshotRefreshProtocol] = []

  func reset() {
    lock.lock()
    recorded = []
    held = false
    offline = false
    offlineAfterDelete = false
    pending = []
    lock.unlock()
  }

  func goOfflineAfterDelete() {
    lock.lock()
    offlineAfterDelete = true
    lock.unlock()
  }

  /// Called once a DELETE has been answered.
  func noteDelete() {
    lock.lock()
    if offlineAfterDelete {
      offline = true
    }
    lock.unlock()
  }

  func goOffline() {
    lock.lock()
    offline = true
    lock.unlock()
  }

  func isOffline() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return offline
  }

  func record(_ path: String) {
    lock.lock()
    recorded.append(path)
    lock.unlock()
  }

  func paths() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func hold() {
    lock.lock()
    held = true
    lock.unlock()
  }

  func release() {
    lock.lock()
    held = false
    lock.unlock()
  }

  /// Parks a request instead of answering it. Returns false when nothing is
  /// being held, in which case the caller answers immediately.
  func park(_ request: SnapshotRefreshProtocol) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard held else {
      return false
    }
    pending.append(request)
    return true
  }

  func drainHeld() -> [SnapshotRefreshProtocol] {
    lock.lock()
    defer { lock.unlock() }
    let parked = pending
    pending = []
    return parked
  }
}

/// Serves one plan whose reference set and ledger page differ from the
/// snapshot fixture, so "did the network replace what was on screen?" is
/// always answerable. Responses can be held back to model a slow server.
private final class SnapshotRefreshProtocol: URLProtocol {
  static let fixtureHost = "howmuch-reference-snapshot.test"
  static let fixtureBaseURL = "https://howmuch-reference-snapshot.test"
  static let planID = SnapshotFixture.planID
  static let networkAccountID = "acct-from-network"
  static let networkTransactionID = "txn-from-network"
  static let olderTransactionID = "txn-older"
  static let olderPageOffset = 100
  static let networkUnapprovedCount = 4
  static let serverKnowledge = 7

  static func reset() {
    SnapshotRefreshLog.shared.reset()
  }

  static func paths() -> [String] {
    SnapshotRefreshLog.shared.paths()
  }

  /// True once the launch refresh has issued all three slice fetches, which
  /// is the point at which every "do not blank a provisional view" guard has
  /// run. `/v1/plans` alone proves nothing: `refreshAll` awaits it before any
  /// slice starts.
  static func hasSeenEverySlice() -> Bool {
    let seen = Set(paths())
    let plan = "/v1/plans/\(planID)"
    return seen.contains("\(plan)/settings")
      && seen.contains("\(plan)/transactions")
      && seen.contains("\(plan)/scheduled_transactions")
  }

  static func holdResponses() {
    SnapshotRefreshLog.shared.hold()
  }

  /// Fails every request, including `/v1/plans`, the way a launch with no
  /// network does.
  static func goOffline() {
    SnapshotRefreshLog.shared.goOffline()
  }

  /// Answers the next DELETE, then fails every request after it.
  static func goOfflineAfterDelete() {
    SnapshotRefreshLog.shared.goOfflineAfterDelete()
  }

  /// Lets every held response finish. Called from the test's thread; the
  /// stub never blocks a URLSession worker, so a held request cannot stop the
  /// next one from being issued.
  static func releaseResponses() {
    SnapshotRefreshLog.shared.release()
    for held in SnapshotRefreshLog.shared.drainHeld() {
      held.finish()
    }
  }

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
    SnapshotRefreshLog.shared.record(url.path)
    if SnapshotRefreshLog.shared.isOffline() {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    // `/v1/plans` is never held: `refreshAll` awaits it before starting any
    // slice, so holding it would park the launch before the code under test
    // ever runs. Everything else is parked and returned to, rather than slept
    // on, so no URLSession worker is blocked and later requests still issue.
    if request.httpMethod == "DELETE" {
      finish()
      SnapshotRefreshLog.shared.noteDelete()
      return
    }
    if url.path != "/v1/plans", SnapshotRefreshLog.shared.park(self) {
      return
    }
    finish()
  }

  /// Answers the request. Safe to call from the test's thread once released.
  func finish() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    guard let body = Self.body(for: url) else {
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

  override func stopLoading() {}

  private static let accountJSON = """
  {
    "id": "\(networkAccountID)",
    "name": "Network Account",
    "icon": null,
    "type": "checking",
    "on_budget": true,
    "closed": false,
    "balance": 999,
    "cleared_balance": 999,
    "uncleared_balance": 0,
    "last_reconciled_date": null,
    "deleted": false
  }
  """

  private static let transactionJSON = """
  {
    "id": "\(networkTransactionID)",
    "date": "2026-01-03",
    "amount": -4560,
    "memo": null,
    "cleared": "uncleared",
    "approved": true,
    "flag_color": null,
    "flag_name": null,
    "account_id": "\(networkAccountID)",
    "account_name": "Network Account",
    "payee_id": null,
    "payee_name": "Network Payee",
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

  private static let olderTransactionJSON = """
  {
    "id": "\(olderTransactionID)",
    "date": "2025-12-01",
    "amount": -700,
    "memo": null,
    "cleared": "cleared",
    "approved": true,
    "flag_color": null,
    "flag_name": null,
    "account_id": "acct-1",
    "account_name": "Fixture Account",
    "payee_id": null,
    "payee_name": "Older Payee",
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

  private static func body(for url: URL) -> String? {
    let path = url.path
    let plan = "/v1/plans/\(planID)"
    // The second page the reader scrolls to. Routing on the query keeps the
    // first page and the older page distinguishable on one path.
    if path == "\(plan)/transactions",
       url.query?.contains("offset=\(olderPageOffset)") == true {
      return #"{"data":{"transactions":[\#(olderTransactionJSON)],"has_more":false,"server_knowledge":\#(serverKnowledge)}}"#
    }
    switch path {
    case "\(plan)/transactions/\(networkTransactionID)":
      // Only DELETE reaches this path in these tests.
      return #"{"data":{"transaction":\#(transactionJSON),"server_knowledge":\#(serverKnowledge + 1)}}"#
    case "/v1/plans":
      return #"{"data":{"plans":[{"id":"\#(planID)","name":"Fixture Plan"}]}}"#
    case "\(plan)/settings":
      return #"{"data":{"settings":{"date_format":{"format":"YYYY-MM-DD"}}}}"#
    case "\(plan)/accounts":
      return #"{"data":{"accounts":[\#(accountJSON)]}}"#
    case "\(plan)/categories":
      return #"{"data":{"category_groups":[]}}"#
    case "\(plan)/payees":
      return #"{"data":{"payees":[]}}"#
    case "\(plan)/account_preferences":
      return #"{"data":{"account_preferences":null,"account_preferences_revision":0}}"#
    case "\(plan)/transactions":
      return #"{"data":{"transactions":[\#(transactionJSON)],"has_more":false,"server_knowledge":\#(serverKnowledge)}}"#
    case "\(plan)/transactions/unapproved_count":
      return #"{"data":{"count":\#(networkUnapprovedCount),"server_knowledge":\#(serverKnowledge)}}"#
    case "\(plan)/scheduled_transactions":
      return #"{"data":{"scheduled_transactions":[],"server_knowledge":\#(serverKnowledge)}}"#
    default:
      return nil
    }
  }
}
