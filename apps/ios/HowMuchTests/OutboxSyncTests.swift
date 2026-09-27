import XCTest
@testable import HowMuch

/// End to end: every transaction write goes through the durable outbox, shows
/// at once, and reaches a stubbed server later. No real server is contacted;
/// `OutboxLedgerServer` is an in-memory ledger behind a URLProtocol.
@MainActor
final class OutboxSyncTests: XCTestCase {
  private var credentialService = ""
  private var savedDefaults: [String: Any] = [:]
  private let keys = [APISettings.userDefaultsKey, ScopedViewPrefsStore.userDefaultsKey]
  private var server: OutboxLedgerServer { OutboxLedgerServer.shared }

  override func setUp() {
    super.setUp()
    credentialService = APISettings.useCredentialService("HowMuch.OutboxSyncTests.\(UUID())")
    for key in keys {
      savedDefaults[key] = UserDefaults.standard.object(forKey: key)
    }
    OutboxLedgerServer.shared.reset()
    XCTAssertTrue(URLProtocol.registerClass(OutboxLedgerProtocol.self))
  }

  override func tearDown() {
    OutboxLedgerServer.shared.releaseAll()
    URLProtocol.unregisterClass(OutboxLedgerProtocol.self)
    APISettings.useCredentialService(credentialService)
    for key in keys { UserDefaults.standard.set(savedDefaults[key], forKey: key) }
    super.tearDown()
  }

  // MARK: - Offline, then online

  func testOfflineCreateEditAndDeleteOfTheSameRowSendsNothing() async throws {
    let model = makeModel()
    await load(model)
    server.offline = true

    var draft = newDraft(amount: 12_000, payee: "Lunch")
    try model.commit(draft)
    let pending = try XCTUnwrap(model.pendingRows.first)
    XCTAssertEqual(pending.status, .waitingForConnection)
    XCTAssertTrue(pending.transactionID.hasPrefix("txn_"), "a queued create has its real id at once")

    draft.payeeName = "Dinner"
    var item = CaptureDraftItem(draft: draft)
    item.committed = true
    model.reviseConversationCapture(item)
    XCTAssertEqual(model.pendingRows.map(\.payeeName), ["Dinner"], "the revision folds into the queued create")
    XCTAssertEqual(model.unsentChangeCount, 1)

    try await model.deleteTransaction(fixtureRow(id: pending.transactionID, amount: -12_000))
    XCTAssertTrue(model.pendingRows.isEmpty)
    XCTAssertEqual(model.unsentChangeCount, 0)

    server.offline = false
    await model.drainOutbox(trigger: .manual)
    await model.waitForOutboxDrain()
    XCTAssertEqual(server.writes(), [], "a row made and removed offline never reaches the server")
    XCTAssertEqual(model.outboxStorePeek(), [])
  }

  func testOfflineEditsOfAnExistingRowBecomeOnePUT() async throws {
    server.seed(row(id: "row-1", amount: -5_000, payee: "Cafe"))
    let model = makeModel()
    await load(model)
    server.offline = true

    var draft = TransactionDraft(transaction: try row(in: model, "row-1"))
    draft.memo = "first"
    try model.commit(draft)
    draft.memo = "second"
    draft.amountMagnitudeMilli = 6_500
    try model.commit(draft)

    XCTAssertEqual(try row(in: model, "row-1").memo, "second", "edits show before they are sent")
    XCTAssertEqual(try row(in: model, "row-1").amount, -6_500)
    XCTAssertEqual(model.unsentChangeCount, 1)
    XCTAssertEqual(model.syncStatus(forTransactionID: "row-1"), .waitingForConnection)
    await model.drainOutbox(trigger: .manual)
    XCTAssertEqual(server.writes(), [], "nothing leaves while offline")
    XCTAssertEqual(model.unsentChangeCount, 1, "and nothing is dropped")

    server.offline = false
    await model.drainOutbox(trigger: .manual)
    await model.waitForOutboxDrain()

    let writes = server.writes()
    XCTAssertEqual(writes.map(\.description), ["PUT /v1/plans/plan-1/transactions/row-1"])
    let body = try XCTUnwrap(writes.first?.body["transaction"] as? [String: Any])
    XCTAssertEqual(body["memo"] as? String, "second")
    XCTAssertEqual(body["amount"] as? Int, -6_500)
    XCTAssertNil(body["id"], "an edit never sends an id")
    XCTAssertNil(body["import_id"])
    XCTAssertEqual(server.row("row-1")?["memo"] as? String, "second")
    XCTAssertEqual(model.unsentChangeCount, 0)
    XCTAssertNil(model.syncStatus(forTransactionID: "row-1"))
    XCTAssertEqual(try row(in: model, "row-1").memo, "second")
  }

  // MARK: - Cleared

  func testClearedToggleRoundTrip() async throws {
    server.seed(row(id: "row-1", amount: -10_000, cleared: "uncleared"))
    let model = makeModel()
    await load(model)
    XCTAssertEqual(model.accounts.first?.unclearedBalance, -10_000)

    server.offline = true
    try await model.toggleTransactionCleared(try row(in: model, "row-1"))
    XCTAssertEqual(try row(in: model, "row-1").cleared, .cleared)
    XCTAssertEqual(model.accounts.first?.clearedBalance, -10_000, "the balance buckets move at once")
    XCTAssertEqual(model.accounts.first?.unclearedBalance, 0)

    // Toggling back before anything is sent cancels the change outright.
    try await model.toggleTransactionCleared(try row(in: model, "row-1"))
    XCTAssertEqual(model.unsentChangeCount, 0)
    XCTAssertEqual(model.accounts.first?.unclearedBalance, -10_000)

    try await model.toggleTransactionCleared(try row(in: model, "row-1"))
    server.offline = false
    await model.drainOutbox(trigger: .manual)
    await model.waitForOutboxDrain()

    let writes = server.writes()
    XCTAssertEqual(writes.map(\.description), ["PATCH /v1/plans/plan-1/transactions/row-1/cleared"])
    XCTAssertEqual(writes.first?.body["expected_cleared"] as? String, "uncleared")
    XCTAssertEqual(writes.first?.body["cleared"] as? String, "cleared")
    XCTAssertEqual(server.row("row-1")?["cleared"] as? String, "cleared")
    XCTAssertEqual(try row(in: model, "row-1").cleared, .cleared)
    XCTAssertEqual(model.unsentChangeCount, 0)
  }

  func testAReplayedToggleThatAlreadyLandedIsDone() async throws {
    server.seed(row(id: "row-1", cleared: "uncleared"))
    let model = makeModel()
    await load(model)
    server.offline = true
    try await model.toggleTransactionCleared(try row(in: model, "row-1"))
    // The first send landed but its answer was lost.
    server.setField("row-1", "cleared", "cleared")

    server.offline = false
    await model.drainOutbox(trigger: .manual)

    XCTAssertEqual(server.status(of: "PATCH /v1/plans/plan-1/transactions/row-1/cleared"), [409])
    XCTAssertEqual(model.unsentChangeCount, 0, "a 409 showing the state we asked for is success")
    XCTAssertEqual(try row(in: model, "row-1").cleared, .cleared)
  }

  func testAClearedConflictIsRejectedAndKeptForTheUser() async throws {
    server.seed(row(id: "row-1", cleared: "uncleared"))
    let model = makeModel()
    await load(model)
    server.offline = true
    try await model.toggleTransactionCleared(try row(in: model, "row-1"))
    // Reconciled on another device in the meantime.
    server.setField("row-1", "cleared", "reconciled")

    server.offline = false
    await model.drainOutbox(trigger: .manual)

    let item = try XCTUnwrap(model.outboxItems.first)
    guard case .rejected = item.status else {
      return XCTFail("a real conflict must wait for the user, saw \(item.status)")
    }
    XCTAssertEqual(model.lastSaveMessage?.kind, .failure)
    XCTAssertEqual(model.outboxStorePeek()?.count, 1, "the rejected change stays on disk")

    model.discardPending(item.id)
    XCTAssertEqual(model.unsentChangeCount, 0)
    XCTAssertEqual(try row(in: model, "row-1").cleared, .reconciled, "discard shows what the server has")
  }

  // MARK: - Delete

  func testADeleteThatFindsTheRowGoneIsDone() async throws {
    server.seed(row(id: "row-1", amount: -2_000))
    let model = makeModel()
    await load(model)
    let before = try XCTUnwrap(model.accounts.first?.balance)
    server.removeOutOfBand("row-1")

    try await model.deleteTransaction(try row(in: model, "row-1"))
    XCTAssertNil(model.transactions.first { $0.id == "row-1" }, "the row goes at once")
    XCTAssertEqual(model.accounts.first?.balance, before + 2_000)
    await model.waitForOutboxDrain()

    XCTAssertEqual(server.status(of: "DELETE /v1/plans/plan-1/transactions/row-1"), [404])
    XCTAssertEqual(model.unsentChangeCount, 0)
    XCTAssertNil(model.transactions.first { $0.id == "row-1" })
  }

  func testDeleteIsInstantAndSentLater() async throws {
    server.seed(row(id: "row-1", amount: -2_000))
    let model = makeModel()
    await load(model)
    server.offline = true

    try await model.deleteTransaction(try row(in: model, "row-1"))
    XCTAssertFalse(model.isSubmitting, "a delete no longer takes the global lock")
    XCTAssertNil(model.transactions.first { $0.id == "row-1" })
    XCTAssertEqual(model.accounts.first?.balance, 0)

    server.offline = false
    await model.drainOutbox(trigger: .manual)
    XCTAssertEqual(server.row("row-1")?["deleted"] as? Bool, true)
    XCTAssertEqual(model.accounts.first?.balance, 0)
  }

  // MARK: - Rejections

  func testARefusedEditStaysOnDiskUntilRetriedOrDiscarded() async throws {
    server.seed(row(id: "row-1", amount: -1_000, payee: "Cafe"))
    server.seed(row(id: "row-2", amount: -2_000, payee: "Shop"))
    let model = makeModel()
    await load(model)
    server.refuse("PUT", status: 400, detail: "Category not found")

    var first = TransactionDraft(transaction: try row(in: model, "row-1"))
    first.memo = "retry me"
    try model.commit(first)
    var second = TransactionDraft(transaction: try row(in: model, "row-2"))
    second.memo = "discard me"
    try model.commit(second)
    await model.waitForOutboxDrain()

    XCTAssertEqual(model.outboxItems.count, 2)
    XCTAssertTrue(model.outboxItems.allSatisfy { $0.status == .rejected("Category not found") })
    XCTAssertEqual(model.syncStatus(forTransactionID: "row-1"), .rejected("Category not found"))
    XCTAssertEqual(model.outboxStorePeek()?.count, 2)

    // A relaunch keeps them, still refused, and does not resend them.
    let relaunched = makeModel(store: model.outboxStoreForTesting)
    await relaunched.drainOutbox(trigger: .refresh)
    XCTAssertEqual(relaunched.outboxItems.count, 2)
    XCTAssertEqual(server.writes().count, 2, "rejected changes wait for Retry")

    server.acceptAll()
    let retry = try XCTUnwrap(relaunched.outboxItems.first { $0.transactionID == "row-1" })
    relaunched.retryPending(retry.id)
    await eventually { relaunched.outboxItems.count == 1 }
    await relaunched.waitForOutboxDrain()
    XCTAssertEqual(server.row("row-1")?["memo"] as? String, "retry me")

    await load(relaunched)
    XCTAssertEqual(try row(in: relaunched, "row-2").memo, "discard me")
    let discard = try XCTUnwrap(relaunched.outboxItems.first)
    relaunched.discardPending(discard.id)
    XCTAssertEqual(relaunched.unsentChangeCount, 0)
    XCTAssertNil(try row(in: relaunched, "row-2").memo, "discard reverts to the server's row")
    XCTAssertNil(server.row("row-2")?["memo"] as? String)
  }

  // MARK: - Relaunch

  func testAKillMidFlightIsRetriedWithoutADuplicate() async throws {
    let store = OutboxStore.temporary()
    let settings = fixtureSettings()
    let transactionID = OutboxCommand.mintTransactionID()
    let request = TransactionWriteRequest(
      accountID: "acct-a", date: "2026-09-20", amount: -4_000, payeeID: nil, payeeName: "Taxi",
      categoryID: nil, memo: nil, cleared: .uncleared, approved: true, flagColor: nil,
      subtransactions: [], importID: "imp-taxi"
    )
    _ = try store.load()
    try store.save([
      OutboxCommand(
        id: UUID(), seq: 1, transactionID: transactionID,
        connectionFingerprint: settings.connectionFingerprint, createdAt: .now,
        kind: .create(request), state: .inFlight, attempted: true, sentWithClientID: true
      ),
    ])
    // The POST reached the server before the app was killed.
    var landed = row(id: transactionID, amount: -4_000, payee: "Taxi")
    landed["import_id"] = "imp-taxi"
    server.seed(landed)

    let model = makeModel(store: store)
    XCTAssertEqual(model.pendingRows.first?.status, .waitingForConnection, "on the wire at the kill, queued at launch")
    await model.drainOutbox(trigger: .refresh)

    XCTAssertEqual(server.rows(importID: "imp-taxi").count, 1, "the replay returns the row the server already has")
    XCTAssertEqual(model.unsentChangeCount, 0)
    XCTAssertEqual(store.peek(), [])
  }

  // Failure mode: the write marking a create as attempted fails, the create
  // is sent anyway, the server commits it and the app dies. The disk then
  // shows a create never sent, a later edit folds into it, and the replay
  // is answered from the import-id dedupe with the first body: the edit is
  // lost. Nothing may be sent until the attempt is on disk.
  func testNothingIsSentUntilTheAttemptIsOnDisk() async throws {
    let gate = WriteGate()
    let store = OutboxStore.temporary(writeData: { data, url in
      if gate.fails { throw CocoaError(.fileWriteOutOfSpace) }
      try data.write(to: url, options: .atomic)
    })
    let model = makeModel(store: store)
    await load(model)
    server.offline = true
    try model.commit(newDraft(amount: 19_000, payee: "Repair"))
    await model.waitForOutboxDrain()

    gate.fails = true
    server.offline = false
    await model.drainOutbox(trigger: .manual)
    XCTAssertEqual(server.writes(), [], "a send whose attempt could not be recorded never leaves")
    let onDisk = try XCTUnwrap(store.peek()?.first)
    XCTAssertFalse(onDisk.attempted)
    XCTAssertEqual(onDisk.state, .queued)
    XCTAssertEqual(model.currentOutbox.first?.state, .queued, "not left looking as if on the wire")
    XCTAssertFalse(try XCTUnwrap(model.currentOutbox.first).attempted)

    gate.fails = false
    await model.drainOutbox(trigger: .manual)
    XCTAssertEqual(server.writes().map(\.description), ["POST /v1/plans/plan-1/transactions"])
    XCTAssertEqual(model.unsentChangeCount, 0)
  }

  func testTheLegacyUserDefaultsQueueIsSentAfterAnUpgrade() async throws {
    let suite = "howmuch.tests.outbox-sync.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = fixtureSettings()
    let legacy = PendingTransaction(
      request: TransactionWriteRequest(
        accountID: "acct-a", date: "2026-09-20", amount: -7_000, payeeID: nil, payeeName: "Old capture",
        categoryID: nil, memo: nil, cleared: .uncleared, approved: true, flagColor: nil, subtransactions: []
      ),
      connectionFingerprint: settings.connectionFingerprint
    )
    defaults.set(try JSONEncoder().encode([legacy]), forKey: OutboxStore.legacyDefaultsKey)

    let model = makeModel(store: .temporary(defaults: defaults), settings: settings)
    XCTAssertEqual(model.pendingRows.map(\.payeeName), ["Old capture"])
    XCTAssertNil(defaults.data(forKey: OutboxStore.legacyDefaultsKey))
    await model.drainOutbox(trigger: .refresh)

    let body = try XCTUnwrap(server.writes().first?.body["transaction"] as? [String: Any])
    XCTAssertEqual(body["import_id"] as? String, legacy.request.importID)
    XCTAssertEqual(model.unsentChangeCount, 0)
  }

  // Failure mode: the old build kept a capture until the server said yes,
  // so any legacy item may have been created already -- without our id,
  // under a server id we never learned. If that row was later deleted on
  // another device, a replayed POST passes the import-id check (it ignores
  // deleted rows) and brings the capture back.
  func testALegacyCaptureDeletedElsewhereIsNotBroughtBackOnUpgrade() async throws {
    let (defaults, suite) = try legacyDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let legacy = legacyCapture(payee: "Old capture", amount: -7_000)
    defaults.set(try JSONEncoder().encode([legacy]), forKey: OutboxStore.legacyDefaultsKey)
    var landed = row(id: "txn_server_7", amount: -7_000, payee: "Old capture")
    landed["import_id"] = legacy.request.importID
    landed["deleted"] = true
    server.seed(landed)

    let model = makeModel(store: .temporary(defaults: defaults))
    await model.drainOutbox(trigger: .refresh)

    XCTAssertEqual(server.writes(), [], "nothing is re-created")
    XCTAssertEqual(
      model.outboxItems.first?.status,
      .rejected("This may have been deleted on another device. Retry to add it again, or Discard it.")
    )
  }

  func testALegacyCaptureTheServerAlreadyHasIsNotSentAgain() async throws {
    let (defaults, suite) = try legacyDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let legacy = legacyCapture(payee: "Old capture", amount: -7_000)
    defaults.set(try JSONEncoder().encode([legacy]), forKey: OutboxStore.legacyDefaultsKey)
    var landed = row(id: "txn_server_7", amount: -7_000, payee: "Old capture")
    landed["import_id"] = legacy.request.importID
    server.seed(landed)

    let model = makeModel(store: .temporary(defaults: defaults))
    await model.drainOutbox(trigger: .refresh)

    XCTAssertEqual(server.writes(), [])
    XCTAssertEqual(model.unsentChangeCount, 0)
    XCTAssertNotNil(model.transactions.first { $0.id == "txn_server_7" })
  }

  func testARefusedLegacyCaptureWaitsForRetryAndIsLookedUpFirst() async throws {
    let (defaults, suite) = try legacyDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    var legacy = legacyCapture(payee: "Refused", amount: -2_000)
    legacy.lastSyncError = "Category not found"
    defaults.set(try JSONEncoder().encode([legacy]), forKey: OutboxStore.legacyDefaultsKey)
    var landed = row(id: "txn_server_2", amount: -2_000, payee: "Refused")
    landed["import_id"] = legacy.request.importID
    landed["deleted"] = true
    server.seed(landed)

    let model = makeModel(store: .temporary(defaults: defaults))
    await model.drainOutbox(trigger: .refresh)
    XCTAssertEqual(server.writes(), [], "a refused capture is not retried unasked")
    XCTAssertEqual(model.outboxItems.first?.status, .rejected("Category not found"))

    await model.drainOutbox(trigger: .manual)
    XCTAssertEqual(server.writes(), [], "Sync Now looks it up before sending")
    XCTAssertEqual(
      model.outboxItems.first?.status,
      .rejected("This may have been deleted on another device. Retry to add it again, or Discard it.")
    )
  }

  private func legacyDefaults() throws -> (UserDefaults, String) {
    let suite = "howmuch.tests.outbox-sync.\(UUID().uuidString)"
    return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
  }

  private func legacyCapture(payee: String, amount: Int) -> PendingTransaction {
    PendingTransaction(
      request: TransactionWriteRequest(
        accountID: "acct-a", date: "2026-09-20", amount: amount, payeeID: nil, payeeName: payee,
        categoryID: nil, memo: nil, cleared: .uncleared, approved: true, flagColor: nil, subtransactions: []
      ),
      connectionFingerprint: fixtureSettings().connectionFingerprint
    )
  }

  // MARK: - Balances

  func testBalancesCountQueuedChangesAndDoNotJumpWhenTheyLand() async throws {
    server.seed(row(id: "row-1", amount: -10_000, cleared: "cleared"))
    let model = makeModel()
    await load(model)
    XCTAssertEqual(model.accounts.first?.balance, -10_000)

    server.offline = true
    try model.commit(newDraft(amount: 5_000, payee: "Snack"))
    XCTAssertEqual(model.accounts.first?.balance, -15_000, "a queued create moves the balance at once")
    // Let the pass the commit scheduled finish offline, so it cannot still be
    // running (and absorb the manual pass below) once the server is back.
    await model.waitForOutboxDrain()

    // An accounts read that starts before the create lands answers with the
    // old balance after it has landed.
    server.offline = false
    server.hold("GET /v1/plans/plan-1/accounts")
    let staleRead = Task { await model.refreshAccounts() }
    await eventually { self.server.isHeld("GET /v1/plans/plan-1/accounts") }
    server.stopHolding()
    await model.drainOutbox(trigger: .manual)
    XCTAssertEqual(model.unsentChangeCount, 0)
    XCTAssertEqual(model.accounts.first?.balance, -15_000, "acknowledged, before any read")

    server.release("GET /v1/plans/plan-1/accounts")
    await staleRead.value
    XCTAssertEqual(model.accounts.first?.balance, -15_000, "a read from before the ack must not undo it")

    await model.refreshAccounts()
    XCTAssertEqual(model.accounts.first?.balance, -15_000, "a read from after the ack is not counted twice")
  }

  // MARK: - Reconcile

  func testReconcileWaitsForThatAccountsChanges() async throws {
    server.seed(row(id: "row-1", amount: -1_000))
    let model = makeModel()
    await load(model)
    server.offline = true
    try await model.toggleTransactionCleared(try row(in: model, "row-1"))

    XCTAssertNotNil(model.reconcileBlockReason(accountID: "acct-a"))
    XCTAssertNil(model.reconcileBlockReason(accountID: "acct-b"))
    do {
      _ = try await model.reconcileAccount(
        accountID: "acct-a", statementDate: "2026-09-26", statementBalance: -1_000, idempotencyKey: "k"
      )
      XCTFail("reconcile must not run while the account has unsent changes")
    } catch {
      XCTAssertEqual(error.localizedDescription, model.reconcileBlockReason(accountID: "acct-a"))
    }
    XCTAssertFalse(server.log().contains { $0.path.hasSuffix("/reconcile") })

    server.offline = false
    await model.drainOutbox(trigger: .manual)
    XCTAssertNil(model.reconcileBlockReason(accountID: "acct-a"))
  }

  // MARK: - Connection gate

  func testCommandsForAnotherConnectionAreNeverSent() async throws {
    let store = OutboxStore.temporary()
    _ = try store.load()
    let foreign = OutboxCommand(
      id: UUID(), seq: 1, transactionID: "row-9",
      connectionFingerprint: "https://other.test|plan-1|someone-else", createdAt: .now,
      kind: .delete(expectedApproved: nil)
    )
    try store.save([foreign])
    server.seed(row(id: "row-9"))

    let model = makeModel(store: store)
    await load(model)
    await model.drainOutbox(trigger: .manual)

    XCTAssertEqual(server.writes(), [])
    XCTAssertEqual(model.unsentChangeCount, 0)
    XCTAssertNotNil(model.transactions.first { $0.id == "row-9" })
    XCTAssertEqual(store.peek(), [foreign], "kept for its own connection")
  }

  // Failure mode: another connection's command for a row with the same id is
  // dropped when this connection's delete lands or its create is discarded.
  func testSettlingARowLeavesAnotherConnectionsCommandsForTheSameIDAlone() async throws {
    let store = OutboxStore.temporary()
    _ = try store.load()
    let settings = fixtureSettings()
    let foreignEdit = OutboxCommand(
      id: UUID(), seq: 1, transactionID: "row-1",
      connectionFingerprint: "https://other.test|plan-1|someone-else", createdAt: .now,
      kind: .update(TransactionWriteRequest(
        accountID: "acct-a", date: "2026-09-20", amount: -9_000, payeeID: nil, payeeName: "Elsewhere",
        categoryID: nil, memo: nil, cleared: nil, approved: true, flagColor: nil, subtransactions: []
      ))
    )
    let foreignApproval = OutboxCommand(
      id: UUID(), seq: 2, transactionID: "txn_shared",
      connectionFingerprint: "https://other.test|plan-1|someone-else", createdAt: .now, kind: .approve
    )
    let localDelete = OutboxCommand(
      id: UUID(), seq: 3, transactionID: "row-1",
      connectionFingerprint: settings.connectionFingerprint, createdAt: .now,
      kind: .delete(expectedApproved: nil)
    )
    let localCreate = OutboxCommand(
      id: UUID(), seq: 4, transactionID: "txn_shared",
      connectionFingerprint: settings.connectionFingerprint, createdAt: .now,
      kind: .create(TransactionWriteRequest(
        accountID: "acct-a", date: "2026-09-20", amount: -1_000, payeeID: nil, payeeName: "Here",
        categoryID: nil, memo: nil, cleared: nil, approved: true, flagColor: nil, subtransactions: [],
        importID: "imp-here"
      )),
      state: .rejected(message: "No", code: 400)
    )
    try store.save([foreignEdit, foreignApproval, localDelete, localCreate])
    server.seed(row(id: "row-1"))
    server.offline = true
    let model = makeModel(store: store, settings: settings)

    model.discardPending(localCreate.id)
    XCTAssertEqual(store.peek()?.map(\.id), [foreignEdit.id, foreignApproval.id, localDelete.id])

    server.offline = false
    await model.drainOutbox(trigger: .manual)
    XCTAssertEqual(server.row("row-1")?["deleted"] as? Bool, true)
    XCTAssertEqual(store.peek(), [foreignEdit, foreignApproval], "the other connection's changes are still waiting")
  }

  func testSignedOutCommandsWaitOnDiskForTheSameConnection() async throws {
    server.seed(row(id: "row-1"))
    let store = OutboxStore.temporary()
    let model = makeModel(store: store)
    await load(model)
    server.refuse("PATCH", status: 401, detail: "Invalid credentials")

    try await model.toggleTransactionCleared(try row(in: model, "row-1"))
    await eventually { !model.settings.isAuthenticated }
    await model.waitForOutboxDrain()

    XCTAssertEqual(store.peek()?.count, 1, "a sign-out never deletes unsent changes")
    XCTAssertEqual(store.peek()?.first?.state, .queued)
    XCTAssertNotNil(
      ConnectionSwitch.blockReason(outbox: store.peek() ?? [], settings: model.settings),
      "switching back to the iPhone stays blocked while this server's changes wait"
    )
  }

  // MARK: - Approvals

  func testApprovalsQueueOfflineAndCountOnTheBadge() async throws {
    server.seed(row(id: "row-1", approved: false))
    server.seed(row(id: "row-2", approved: false))
    let model = makeModel()
    await load(model)
    await eventually { model.unapprovedBadgeCount == 2 }
    server.offline = true

    model.approveTransaction(try row(in: model, "row-1"))
    await model.waitForOutboxDrain()
    XCTAssertEqual(model.unapprovedBadgeCount, 1)
    XCTAssertTrue(try row(in: model, "row-1").approved)

    // Relaunch with the approval still queued: a fresh count from the
    // server cannot include it, so the badge still subtracts it.
    let relaunched = makeModel(store: model.outboxStoreForTesting)
    relaunched.outboxDebounce = .seconds(3_600)
    server.offline = false
    await relaunched.refreshAccounts()
    await relaunched.refreshLedger(quiet: false)
    await eventually { relaunched.unapprovedBadgeCount == 1 }
    XCTAssertEqual(relaunched.unsentChangeCount, 1)
    XCTAssertEqual(server.writes(), [], "still waiting to be sent")

    await relaunched.drainOutbox(trigger: .manual)
    XCTAssertEqual(server.row("row-1")?["approved"] as? Bool, true)
    XCTAssertEqual(relaunched.unsentChangeCount, 0)
    XCTAssertEqual(relaunched.unapprovedBadgeCount, 1, "sent and confirmed, still off the badge")
    await relaunched.refreshLedger(quiet: true)
    await eventually { relaunched.unapprovedBadgeCount == 1 }
  }

  // MARK: - Attempted creates

  func testChangesAfterALostCreateResponseStillReachTheServer() async throws {
    let model = makeModel()
    await load(model)
    server.dropResponses("POST /v1/plans/plan-1/transactions")

    try model.commit(newDraft(amount: 8_000, payee: "Market"))
    await model.waitForOutboxDrain()
    let create = try XCTUnwrap(model.currentOutbox.first)
    XCTAssertTrue(create.attempted, "the server may hold it")
    XCTAssertEqual(server.rows(importID: try XCTUnwrap(createImportID(create))).count, 1, "the POST landed")
    server.stopDropping()
    server.offline = true

    var edit = TransactionDraft(transaction: fixtureRow(id: create.transactionID, amount: -8_000))
    edit.memo = "edited after the lost answer"
    try model.commit(edit)
    XCTAssertEqual(model.currentOutbox.count, 2, "the edit queues behind the create rather than folding into it")

    server.offline = false
    await model.drainOutbox(trigger: .manual)
    XCTAssertEqual(server.row(create.transactionID)?["memo"] as? String, "edited after the lost answer")
    XCTAssertEqual(model.unsentChangeCount, 0)

    server.dropResponses("DELETE /v1/plans/plan-1/transactions/\(create.transactionID)")
    try await model.deleteTransaction(try row(in: model, create.transactionID))
    await model.waitForOutboxDrain()
    server.stopDropping()
    await model.drainOutbox(trigger: .manual)
    XCTAssertEqual(server.row(create.transactionID)?["deleted"] as? Bool, true)
    XCTAssertEqual(model.unsentChangeCount, 0, "the replayed delete finds the row gone and is done")
  }

  func testALostCreateDeletedElsewhereIsNotBroughtBack() async throws {
    let model = makeModel()
    await load(model)
    server.dropResponses("POST /v1/plans/plan-1/transactions")
    try model.commit(newDraft(amount: 8_000, payee: "Market"))
    await model.waitForOutboxDrain()
    server.stopDropping()
    let create = try XCTUnwrap(model.currentOutbox.first)
    let importID = try XCTUnwrap(createImportID(create))
    server.removeOutOfBand(create.transactionID)

    await model.drainOutbox(trigger: .refresh)
    XCTAssertEqual(server.rows(importID: importID).count, 0, "a replay must not recreate it")
    let item = try XCTUnwrap(model.outboxItems.first)
    XCTAssertEqual(
      item.status,
      .rejected("This may have been deleted on another device. Retry to add it again, or Discard it.")
    )

    // Retry is the user saying "add it again": a new row, under a new id.
    model.retryPending(item.id)
    await eventually { model.unsentChangeCount == 0 }
    let recreated = server.rows(importID: importID)
    XCTAssertEqual(recreated.count, 1)
    XCTAssertNotEqual(recreated.first?["id"] as? String, create.transactionID)
  }

  func testASettledDeleteDropsRefusedChangesForTheRow() async throws {
    let model = makeModel()
    await load(model)
    server.dropResponses("POST /v1/plans/plan-1/transactions")
    try model.commit(newDraft(amount: 8_000, payee: "Market"))
    await model.waitForOutboxDrain()
    server.stopDropping()
    let create = try XCTUnwrap(model.currentOutbox.first)
    server.removeOutOfBand(create.transactionID)
    await model.drainOutbox(trigger: .refresh)
    XCTAssertEqual(model.outboxItems.count, 1, "the create is refused as possibly deleted")

    try await model.deleteTransaction(fixtureRow(id: create.transactionID, amount: -8_000))
    await model.waitForOutboxDrain()
    XCTAssertEqual(model.unsentChangeCount, 0, "the delete's 404 settles the refused create too")
    await model.drainOutbox(trigger: .manual)
    XCTAssertEqual(
      server.rows(importID: try XCTUnwrap(createImportID(create))).count,
      0,
      "Sync Now has nothing left to bring back"
    )
  }

  func testChangesToARowWaitingToBeDeletedAreRefusedOutLoud() async throws {
    server.seed(row(id: "row-1", approved: false))
    let model = makeModel()
    await load(model)
    // Approved on another device, so the guarded delete is refused.
    let before = try row(in: model, "row-1")
    server.setField("row-1", "approved", true)
    try await model.deleteTransaction(before)
    await model.waitForOutboxDrain()
    guard case .rejected? = model.outboxItems.first?.status else {
      return XCTFail("the delete must be refused, saw \(model.outboxItems)")
    }

    var edit = TransactionDraft(transaction: before)
    edit.memo = "edit"
    XCTAssertThrowsError(try model.commit(edit)) { error in
      XCTAssertEqual(error as? OutboxEnqueueRefusal, .rowIsBeingDeleted)
    }
    do {
      try await model.toggleTransactionCleared(before)
      XCTFail("a toggle must not be swallowed")
    } catch {
      XCTAssertEqual(error as? OutboxEnqueueRefusal, .rowIsBeingDeleted)
    }
    model.approveTransaction(before)
    XCTAssertEqual(model.lastSaveMessage?.kind, .failure)
    XCTAssertEqual(model.unsentChangeCount, 1)
  }

  func testADelete404ForAPlanOutOfReachIsNotASuccess() async throws {
    server.seed(row(id: "row-1"))
    let model = makeModel()
    await load(model)
    server.refuse("DELETE", status: 404, detail: "Plan not found", name: "resource_not_found")

    try await model.deleteTransaction(try row(in: model, "row-1"))
    await model.waitForOutboxDrain()
    XCTAssertEqual(model.outboxItems.first?.status, .rejected("Plan not found"))
    XCTAssertEqual(server.row("row-1")?["deleted"] as? Bool, false)
  }

  func testAnUnreadableOutboxIsShownOnTheCard() throws {
    let store = OutboxStore.temporary()
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: store.fileURL)
    let model = makeModel(store: store)
    XCTAssertEqual(model.outboxNotice, "Some unsent changes couldn’t be read; a copy was kept on this iPhone.")
  }

  private func createImportID(_ command: OutboxCommand) -> String? {
    if case .create(let request) = command.kind { return request.importID }
    return nil
  }

  // MARK: - Helpers

  private func fixtureSettings() -> APISettings {
    var settings = APISettings()
    settings.baseURLString = "https://\(OutboxLedgerProtocol.host)"
    settings.authenticatedUserID = "outbox-user"
    settings.sessionToken = "fixture-token"
    settings.planID = "plan-1"
    return settings
  }

  private func makeModel(store: OutboxStore = .temporary(), settings: APISettings? = nil) -> AppModel {
    let model = AppModel(
      outboxStore: store,
      settings: settings ?? fixtureSettings(),
      viewPrefs: ViewPrefs(),
      snapshotStore: SnapshotStore(
        directory: FileManager.default.temporaryDirectory
          .appendingPathComponent("HowMuchOutboxSyncTests/\(UUID().uuidString)", isDirectory: true)
      ),
      hasSavedSettings: true
    )
    model.outboxDebounce = .zero
    return model
  }

  private func load(_ model: AppModel) async {
    await model.refreshAccounts()
    await model.refreshLedger(quiet: false)
    await model.waitForOutboxDrain()
  }

  private func newDraft(amount: Int, payee: String) -> TransactionDraft {
    var draft = TransactionDraft()
    draft.accountID = "acct-a"
    draft.amountMagnitudeMilli = amount
    draft.direction = .outflow
    draft.payeeName = payee
    return draft
  }

  private func row(in model: AppModel, _ id: String) throws -> Transaction {
    try XCTUnwrap(
      (model.transactions + model.unapprovedTransactions).first { $0.id == id },
      "row \(id) is not on screen"
    )
  }

  private func row(
    id: String,
    amount: Int = -1_000,
    cleared: String = "uncleared",
    approved: Bool = true,
    payee: String = "Fixture Payee"
  ) -> [String: Any] {
    [
      "id": id, "date": "2026-09-20", "amount": amount, "cleared": cleared, "approved": approved,
      "account_id": "acct-a", "account_name": "Account A", "payee_name": payee,
      "deleted": false, "subtransactions": [],
    ]
  }

  private func fixtureRow(id: String, amount: Int) -> Transaction {
    Transaction(
      id: id, date: "2026-09-20", amount: amount, memo: nil, cleared: .uncleared, approved: true,
      flagColor: nil, flagName: nil, accountID: "acct-a", accountName: "Account A", payeeID: nil,
      payeeName: nil, categoryID: nil, categoryName: nil, transferAccountID: nil,
      transferTransactionID: nil, parentTransactionID: nil, matchedTransactionID: nil, importID: nil,
      importPayeeName: nil, importPayeeNameOriginal: nil, deleted: false, subtransactions: []
    )
  }

  private func eventually(
    _ condition: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0 ..< 400 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "condition did not settle", file: file, line: line)
  }
}

/// Makes every outbox write fail while `fails` is set.
final class WriteGate: @unchecked Sendable {
  var fails = false
}

extension AppModel {
  /// What the outbox file holds for this model, read without side effects.
  func outboxStorePeek() -> [OutboxCommand]? {
    outboxStoreForTesting.peek()
  }
}

// MARK: - The stub server

struct OutboxLedgerRequest: Equatable, CustomStringConvertible {
  let method: String
  let path: String
  let body: [String: Any]
  let status: Int

  var description: String { "\(method) \(path)" }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.description == rhs.description && lhs.status == rhs.status
  }
}

/// An in-memory ledger with the server's write semantics for the routes the
/// outbox uses: import-id dedupe on create, compare-and-set on cleared and
/// delete, 404 for a row that is gone.
final class OutboxLedgerServer: @unchecked Sendable {
  static let shared = OutboxLedgerServer()

  private let lock = NSLock()
  private var rows: [String: [String: Any]] = [:]
  private var order: [String] = []
  private var requests: [OutboxLedgerRequest] = []
  private var refusals: [String: (Int, String)] = [:]
  private var holding: Set<String> = []
  private var parked: [String: () -> Void] = [:]
  private var knowledge = 1
  private var isOffline = false
  private var dropping: Set<String> = []
  private var refusalNames: [String: String] = [:]

  var offline: Bool {
    get { lock.lock(); defer { lock.unlock() }; return isOffline }
    set { lock.lock(); isOffline = newValue; lock.unlock() }
  }

  func reset() {
    releaseAll()
    lock.lock(); defer { lock.unlock() }
    rows = [:]; order = []; requests = []; refusals = [:]; holding = []; knowledge = 1; isOffline = false
    dropping = []; refusalNames = [:]
  }

  func seed(_ row: [String: Any]) {
    lock.lock(); defer { lock.unlock() }
    let id = row["id"] as! String
    if rows[id] == nil { order.append(id) }
    rows[id] = row
    knowledge += 1
  }

  func setField(_ id: String, _ key: String, _ value: Any) {
    lock.lock(); defer { lock.unlock() }
    rows[id]?[key] = value
    knowledge += 1
  }

  func removeOutOfBand(_ id: String) {
    setField(id, "deleted", true)
  }

  func row(_ id: String) -> [String: Any]? {
    lock.lock(); defer { lock.unlock() }
    return rows[id]
  }

  func rows(importID: String) -> [[String: Any]] {
    lock.lock(); defer { lock.unlock() }
    return rows.values.filter { $0["import_id"] as? String == importID && $0["deleted"] as? Bool != true }
  }

  func refuse(_ method: String, status: Int, detail: String) {
    lock.lock(); refusals[method] = (status, detail); lock.unlock()
  }

  func acceptAll() {
    lock.lock(); refusals = [:]; lock.unlock()
  }

  /// Applies requests on `route` but loses the answer on the way back.
  func dropResponses(_ route: String) { lock.lock(); dropping.insert(route); lock.unlock() }
  func stopDropping() { lock.lock(); dropping = []; lock.unlock() }

  func refuse(_ method: String, status: Int, detail: String, name: String) {
    lock.lock(); refusals[method] = (status, detail); refusalNames[method] = name; lock.unlock()
  }

  func hold(_ route: String) { lock.lock(); holding.insert(route); lock.unlock() }
  func stopHolding() { lock.lock(); holding = []; lock.unlock() }
  func isHeld(_ route: String) -> Bool { lock.lock(); defer { lock.unlock() }; return parked[route] != nil }
  func release(_ route: String) {
    lock.lock(); let send = parked.removeValue(forKey: route); lock.unlock(); send?()
  }
  func releaseAll() {
    lock.lock(); let sends = Array(parked.values); parked = [:]; holding = []; lock.unlock()
    sends.forEach { $0() }
  }

  func log() -> [OutboxLedgerRequest] {
    lock.lock(); defer { lock.unlock() }
    return requests
  }

  /// Every request that changes the ledger, in the order it arrived.
  func writes() -> [OutboxLedgerRequest] {
    log().filter { $0.method != "GET" }
  }

  func status(of route: String) -> [Int] {
    log().filter { $0.description == route }.map(\.status)
  }

  enum Outcome { case answered, offline, dropped }

  /// Answers `request` through `send`, unless the device is "offline" or the
  /// answer is lost.
  func respond(to request: URLRequest, send: @escaping (Int, Data) -> Void) -> Outcome {
    let url = request.url!
    let method = request.httpMethod ?? "GET"
    let path = url.path
    let route = "\(method) \(path)"
    let body = Self.body(of: request)
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

    lock.lock()
    if isOffline {
      lock.unlock()
      return .offline
    }
    let (status, payload) = handle(method: method, path: path, query: query, body: body)
    requests.append(OutboxLedgerRequest(method: method, path: path, body: body, status: status))
    let data = try! JSONSerialization.data(withJSONObject: payload)
    if dropping.contains(route) {
      lock.unlock()
      return .dropped
    }
    if holding.contains(route) {
      parked[route] = { send(status, data) }
      lock.unlock()
    } else {
      lock.unlock()
      send(status, data)
    }
    return .answered
  }

  private func handle(method: String, path: String, query: [URLQueryItem], body: [String: Any]) -> (Int, Any) {
    let plan = "/v1/plans/plan-1"
    func error(_ status: Int, _ name: String, _ detail: String) -> (Int, Any) {
      (status, ["error": ["id": String(status), "name": name, "detail": detail]])
    }
    func live(_ id: String) -> [String: Any]? {
      guard let row = rows[id], row["deleted"] as? Bool != true else { return nil }
      return row
    }
    if method != "GET", let (status, detail) = refusals[method] {
      return error(status, refusalNames[method] ?? (status == 401 ? "unauthorized" : "bad_request"), detail)
    }
    let segments = path.dropFirst(plan.count).split(separator: "/").map(String.init)
    switch (method, segments) {
    case ("GET", ["accounts"]):
      var balance = 0, cleared = 0
      for id in order { if let row = live(id) {
        let amount = row["amount"] as! Int
        balance += amount
        if row["cleared"] as? String != "uncleared" { cleared += amount }
      } }
      let account: [String: Any] = [
        "id": "acct-a", "name": "Account A", "type": "checking", "on_budget": true, "closed": false,
        "balance": balance, "cleared_balance": cleared, "uncleared_balance": balance - cleared, "deleted": false,
      ]
      let other: [String: Any] = [
        "id": "acct-b", "name": "Account B", "type": "checking", "on_budget": true, "closed": false,
        "balance": 0, "cleared_balance": 0, "uncleared_balance": 0, "deleted": false,
      ]
      return (200, ["data": ["accounts": [account, other], "server_knowledge": knowledge]])
    case ("GET", ["transactions", "unapproved_count"]):
      let count = order.compactMap(live).filter { $0["approved"] as? Bool == false }.count
      return (200, ["data": ["count": count, "server_knowledge": knowledge]])
    case ("GET", ["transactions"]) where query.contains(where: { $0.name == "last_knowledge_of_server" }):
      // A delta read, as the server answers it: deleted rows included.
      let list = order.compactMap { rows[$0] }
      return (200, ["data": ["transactions": list, "has_more": false, "server_knowledge": knowledge]])
    case ("GET", ["transactions"]):
      var list = order.compactMap(live)
      if query.contains(where: { $0.name == "type" && $0.value == "unapproved" }) {
        list = list.filter { $0["approved"] as? Bool == false }
      }
      return (200, ["data": ["transactions": list, "has_more": false, "server_knowledge": knowledge]])
    case ("GET", let parts) where parts.count == 2 && parts[0] == "transactions":
      guard let row = live(parts[1]) else { return error(404, "resource_not_found", "Transaction not found") }
      return (200, ["data": ["transaction": row, "server_knowledge": knowledge]])
    case ("POST", ["transactions"]):
      var input = body["transaction"] as? [String: Any] ?? [:]
      if let importID = input["import_id"] as? String,
         let existing = order.compactMap(live).first(where: {
           $0["import_id"] as? String == importID && $0["account_id"] as? String == input["account_id"] as? String
         }) {
        return (200, ["data": ["transaction": existing, "server_knowledge": knowledge]])
      }
      let id = input["id"] as? String ?? "txn_server_\(order.count)"
      if rows[id] != nil { return error(500, "internal_server_error", "An internal error occurred") }
      input["id"] = id
      input["cleared"] = input["cleared"] ?? "uncleared"
      input["deleted"] = false
      input["account_name"] = "Account A"
      input["subtransactions"] = []
      rows[id] = input
      order.append(id)
      knowledge += 1
      return (201, ["data": ["transaction": input, "server_knowledge": knowledge]])
    case ("PUT", let parts) where parts.count == 2:
      guard var row = live(parts[1]) else { return error(404, "resource_not_found", "Transaction not found") }
      for (key, value) in body["transaction"] as? [String: Any] ?? [:] where key != "subtransactions" {
        row[key] = value is NSNull ? nil : value
      }
      rows[parts[1]] = row
      knowledge += 1
      return (200, ["data": ["transaction": row, "server_knowledge": knowledge]])
    case ("PATCH", let parts) where parts.count == 3 && parts[2] == "cleared":
      guard var row = live(parts[1]) else { return error(404, "resource_not_found", "Transaction not found") }
      guard row["cleared"] as? String == body["expected_cleared"] as? String else {
        return error(409, "transaction_state_conflict", "Transaction cleared state changed")
      }
      row["cleared"] = body["cleared"]
      rows[parts[1]] = row
      knowledge += 1
      return (200, ["data": ["transaction": row, "server_knowledge": knowledge]])
    case ("PATCH", ["transactions"]):
      let items = body["transactions"] as? [[String: Any]] ?? []
      var changed: [[String: Any]] = []
      for item in items {
        guard let id = item["id"] as? String, var row = live(id) else {
          return error(404, "resource_not_found", "Transaction not found")
        }
        row["approved"] = true
        rows[id] = row
        changed.append(row)
      }
      knowledge += 1
      return (200, ["data": ["transactions": changed, "transaction_ids": changed.map { $0["id"]! }, "server_knowledge": knowledge]])
    case ("DELETE", let parts) where parts.count == 2:
      guard var row = live(parts[1]) else { return error(404, "resource_not_found", "Transaction not found") }
      if let expected = query.first(where: { $0.name == "expected_approved" })?.value,
         (row["approved"] as? Bool ?? true) != (expected == "true") {
        return error(409, "transaction_state_conflict", "Transaction approval state changed")
      }
      row["deleted"] = true
      rows[parts[1]] = row
      knowledge += 1
      return (200, ["data": ["transaction": row, "server_knowledge": knowledge]])
    case ("GET", ["payees"]):
      return (200, ["data": ["payees": [], "server_knowledge": knowledge]])
    default:
      if path == "/v1/plans" {
        return (200, ["data": ["plans": [["id": "plan-1", "name": "Plan"]]]])
      }
      return error(404, "not_found", "Route not found")
    }
  }

  private static func body(of request: URLRequest) -> [String: Any] {
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

final class OutboxLedgerProtocol: URLProtocol {
  static let host = "outbox-ledger.test"

  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
  override class func canInit(with task: URLSessionTask) -> Bool {
    (task.currentRequest ?? task.originalRequest).map { canInit(with: $0) } ?? false
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let outcome = OutboxLedgerServer.shared.respond(to: request) { [self] status, data in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
    switch outcome {
    case .answered:
      break
    case .offline:
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    case .dropped:
      client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }
  }

  override func stopLoading() {}
}

/// The read overlay on its own: rows in, rows as they will be.
final class OutboxOverlayTests: XCTestCase {
  private func row(
    _ id: String,
    account: String = "a",
    amount: Int = -1_000,
    date: String = "2026-09-20",
    transfer: (account: String, id: String)? = nil,
    parent: String? = nil,
    lines: [Subtransaction] = []
  ) -> Transaction {
    Transaction(
      id: id, date: date, amount: amount, memo: nil, cleared: .uncleared, approved: false,
      flagColor: nil, flagName: nil, accountID: account, accountName: account.uppercased(), payeeID: nil,
      payeeName: "P", categoryID: nil, categoryName: nil, transferAccountID: transfer?.account,
      transferTransactionID: transfer?.id, parentTransactionID: parent, matchedTransactionID: nil,
      importID: nil, importPayeeName: nil, importPayeeNameOriginal: nil, deleted: false, subtransactions: lines
    )
  }

  private func command(_ id: String, _ kind: OutboxCommand.Kind, seq: Int = 1) -> OutboxCommand {
    OutboxCommand(id: UUID(), seq: seq, transactionID: id, connectionFingerprint: "fp", createdAt: .now, kind: kind)
  }

  func testEditsStatusAndApprovalApplyInOrder() {
    let rows = [row("t1", date: "2026-09-20"), row("t2", date: "2026-09-19")]
    let edit = TransactionWriteRequest(
      accountID: "b", date: "2026-09-21", amount: -2_500, payeeID: nil, payeeName: "New payee",
      categoryID: "c1", memo: "m", cleared: nil, approved: true, flagColor: "red", subtransactions: []
    )
    let result = OutboxOverlay.apply(
      [
        command("t2", .update(edit), seq: 1),
        command("t2", .cleared(expected: .uncleared, cleared: .cleared, approve: false), seq: 2),
      ],
      to: rows,
      names: OutboxOverlay.Names(accountName: { $0 == "b" ? "Bee" : nil }, categoryName: { _ in "Food" })
    )
    XCTAssertEqual(result.map(\.id), ["t2", "t1"], "a new date re-sorts the register")
    let edited = result[0]
    XCTAssertEqual(edited.amount, -2_500)
    XCTAssertEqual(edited.accountID, "b")
    XCTAssertEqual(edited.accountName, "Bee")
    XCTAssertEqual(edited.categoryName, "Food")
    XCTAssertEqual(edited.payeeName, "New payee")
    XCTAssertEqual(edited.cleared, .cleared)
    XCTAssertTrue(edited.approved)
    XCTAssertEqual(result[1], rows[0])
  }

  func testDeleteHidesAWholeTransferAndUnlinksASplitParent() {
    let source = row("s", transfer: ("b", "m"))
    let mirror = row("m", account: "b", amount: 1_000, transfer: ("a", "s"))
    let line = Subtransaction(
      id: "line-1", transactionID: "parent", amount: -500, memo: nil, payeeID: nil, payeeName: nil,
      categoryID: nil, categoryName: nil, transferAccountID: "c", transferTransactionID: "split-mirror", deleted: false
    )
    let parent = row("parent", lines: [line])
    // A legacy mirror without parent metadata: only the line leads back.
    let splitMirror = row("split-mirror", account: "c", amount: 500, transfer: ("a", "line-1"))

    let result = OutboxOverlay.apply(
      [command("s", .delete(expectedApproved: nil)), command("split-mirror", .delete(expectedApproved: nil), seq: 2)],
      to: [source, mirror, parent, splitMirror],
      names: .init()
    )
    XCTAssertEqual(result.map(\.id), ["parent"])
    XCTAssertNil(result[0].subtransactions.first?.transferTransactionID)
    XCTAssertNil(result[0].subtransactions.first?.transferAccountID)
  }

  func testAnEditedTransferMovesItsFarSide() {
    let source = row("s", amount: -1_000, transfer: ("b", "m"))
    let mirror = row("m", account: "b", amount: 1_000, transfer: ("a", "s"))
    let edit = TransactionWriteRequest(
      accountID: "a", date: "2026-09-20", amount: -3_000, payeeID: nil, payeeName: nil, categoryID: nil,
      memo: nil, cleared: nil, approved: true, flagColor: nil, subtransactions: []
    )
    let result = OutboxOverlay.apply([command("s", .update(edit))], to: [source, mirror], names: .init())
    XCTAssertEqual(result.first { $0.id == "m" }?.amount, 3_000)
  }
}
