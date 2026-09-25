import Foundation
import XCTest
@testable import HowMuch

final class SplitTransferDraftTests: XCTestCase {
  func testDuplicatingClearsSplitAndMirrorIdentitiesButPreservesAllocations() throws {
    let source = try splitTransfer()
    let draft = TransactionDraft(duplicating: source)
    let request = draft.writeRequest()

    XCTAssertNil(draft.id)
    XCTAssertNotNil(draft.importID)
    XCTAssertNotEqual(draft.importID, source.importID)
    XCTAssertEqual(draft.subtransactions.map(\.id), [nil, nil, nil])
    XCTAssertEqual(draft.subtransactions.map(\.transferTransactionID), [nil, nil, nil])
    XCTAssertEqual(request.subtransactions.map(\.id), [nil, nil, nil])
    XCTAssertEqual(request.subtransactions.map(\.transferTransactionID), [nil, nil, nil])
    XCTAssertEqual(request.subtransactions.map(\.transferAccountID), ["savings", nil, "travel"])
    XCTAssertEqual(request.subtransactions.map(\.amount), [-60_500, -13_980, -44_580])
    XCTAssertEqual(request.subtransactions.map(\.memo), ["Savings allocation", "Lunch", "Travel allocation"])
    XCTAssertEqual(request.subtransactions.map(\.categoryID), [nil, "dining", nil])
    XCTAssertEqual(request.subtransactions[1].payeeID, "cafe")
    XCTAssertEqual(request.amount, -119_060)
    XCTAssertEqual(request.accountID, "everyday")
    XCTAssertEqual(request.memo, "Original split")
    XCTAssertEqual(request.cleared, .uncleared)
    XCTAssertEqual(source.subtransactions.map(\.transferTransactionID), ["mirror-savings", nil, "mirror-travel"])
  }

  func testEditingPreservesSplitAndMirrorIdentities() throws {
    let draft = TransactionDraft(transaction: try splitTransfer())
    let request = draft.writeRequest()

    XCTAssertEqual(draft.id, "original")
    XCTAssertEqual(request.subtransactions.map(\.id), ["line-savings", "line-lunch", "line-travel"])
    XCTAssertEqual(request.subtransactions.map(\.transferTransactionID), ["mirror-savings", nil, "mirror-travel"])
    XCTAssertEqual(request.subtransactions.map(\.transferAccountID), ["savings", nil, "travel"])
    XCTAssertEqual(request.subtransactions.map(\.amount), [-60_500, -13_980, -44_580])
    XCTAssertFalse(draft.changesReconciliationGraph)
  }

  private func splitTransfer() throws -> Transaction {
    try JSONDecoder().decode(Transaction.self, from: Data(#"""
      {
        "id": "original", "date": "2026-09-20", "amount": -119060,
        "memo": "Original split", "cleared": "cleared", "approved": true,
        "accountId": "everyday", "accountName": "Everyday", "importId": "original-import",
        "deleted": false,
        "subtransactions": [
          {"id": "line-savings", "transactionId": "original", "amount": -60500,
           "memo": "Savings allocation", "transferAccountId": "savings",
           "transferTransactionId": "mirror-savings", "deleted": false},
          {"id": "line-lunch", "transactionId": "original", "amount": -13980,
           "memo": "Lunch", "payeeId": "cafe", "payeeName": "Cafe",
           "categoryId": "dining", "deleted": false},
          {"id": "line-travel", "transactionId": "original", "amount": -44580,
           "memo": "Travel allocation", "transferAccountId": "travel",
           "transferTransactionId": "mirror-travel", "deleted": false}
        ]
      }
      """#.utf8))
  }
}

/// Regression tests for deleting one side of a split transfer.
///
/// The server tombstones the deleted row and, when that row was the mirrored
/// side of a split line, leaves the split parent in place and clears only the
/// matching line's transfer link (web: `unlinkSplitMirrorParent`). The app has
/// to reproduce that locally, and it has to keep doing so when a read that was
/// already in flight when the delete landed answers with pre-delete rows.
///
/// The fixture is stateful: a response that is parked before a delete keeps the
/// pre-delete body, while every later response serves the post-delete one, so
/// the two orders a device can actually hit are both exercised.
@MainActor
final class SplitMirrorDeleteTests: XCTestCase {
  private var previousCredentialService = ""
  private var previousAPISettings: Any?
  private var previousScopedViewPrefs: Any?
  private var previousOutbox: Any?
  private var store: SnapshotStore!

  override func setUp() {
    super.setUp()
    previousCredentialService = APISettings.useCredentialService(
      "HowMuch.SplitMirrorDeleteTests.\(UUID().uuidString)"
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
    XCTAssertTrue(URLProtocol.registerClass(SplitMirrorFixtureProtocol.self))
    SplitMirrorFixtureProtocol.reset()
    store = SnapshotStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("HowMuchSplitMirrorTests/\(UUID().uuidString)", isDirectory: true)
    )
  }

  override func tearDown() {
    URLProtocol.unregisterClass(SplitMirrorFixtureProtocol.self)
    APISettings.useCredentialService(previousCredentialService)
    UserDefaults.standard.set(previousAPISettings, forKey: APISettings.userDefaultsKey)
    UserDefaults.standard.set(previousScopedViewPrefs, forKey: ScopedViewPrefsStore.userDefaultsKey)
    UserDefaults.standard.set(previousOutbox, forKey: OutboxStore.userDefaultsKey)
    super.tearDown()
  }

  // MARK: - The local apply

  func testDeletingASplitMirrorKeepsTheParentAndClearsOnlyItsLine() async throws {
    let model = makeModel()
    await loadLedger(model)
    let mirror = try XCTUnwrap(loadedMirror(in: model))

    try await model.deleteTransaction(mirror)

    let parent = try XCTUnwrap(
      model.transactions.first { $0.id == SplitMirrorFixtureProtocol.parentID },
      "deleting a mirrored split line must not remove the parent"
    )
    XCTAssertEqual(parent.subtransactions.count, 2, "the parent's other line must survive")
    let link = try XCTUnwrap(
      parent.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subLinkID }
    )
    XCTAssertNil(link.transferTransactionID, "the deleted mirror's line must forget the link")
    XCTAssertNil(link.transferAccountID)
    let sibling = try XCTUnwrap(
      parent.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subSiblingID }
    )
    XCTAssertEqual(sibling.categoryID, "cat-1", "an unrelated split line must be untouched")
    XCTAssertNil(sibling.transferAccountID)
    XCTAssertNil(sibling.transferTransactionID)

    XCTAssertFalse(model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.mirrorID })
    XCTAssertFalse(model.unapprovedTransactions.contains { $0.id == SplitMirrorFixtureProtocol.mirrorID })
    XCTAssertTrue(model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.siblingID })

    // The delete is the server's own tombstone, not a cascade that could take
    // the parent with it.
    let deletes = SplitMirrorFixtureProtocol.requests().filter { $0.method == "DELETE" }
    XCTAssertEqual(deletes.count, 1, "the delete must be one request, saw \(deletes)")
    XCTAssertEqual(
      deletes.first?.path,
      "/v1/plans/\(SplitMirrorFixtureProtocol.planID)/transactions/\(SplitMirrorFixtureProtocol.mirrorID)"
    )

    // The editor draft is built from the row on screen, so it must not resend
    // the link the server has already cleared.
    let draft = TransactionDraft(transaction: parent)
    let draftLine = try XCTUnwrap(
      draft.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subLinkID }
    )
    let write = try XCTUnwrap(draftLine.writeRequest())
    XCTAssertNil(write.transferTransactionID)
    XCTAssertNil(write.transferAccountID)

    // The snapshot is written from the first page as the network returned it,
    // and the delete's own balance refresh persists it. A mirror this delete
    // removed must not come back on the next cold launch.
    let refreshed = await waitUntil {
      model.accounts.first { $0.id == SplitMirrorFixtureProtocol.accountID }?.balance == 250
    }
    XCTAssertTrue(refreshed, "the delete's balance refresh must land before the snapshot is read")
    store.waitForPendingWrites()
    let page = try XCTUnwrap(store.load()?.ledgerPage, "the delete's refresh must have persisted a snapshot")
    XCTAssertFalse(
      page.transactions.contains { $0.id == SplitMirrorFixtureProtocol.mirrorID },
      "the persisted first page must not carry the deleted mirror"
    )
    let persistedParent = try XCTUnwrap(
      page.transactions.first { $0.id == SplitMirrorFixtureProtocol.parentID }
    )
    XCTAssertNil(
      persistedParent.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subLinkID }?.transferTransactionID,
      "the persisted first page must carry the unlinked line"
    )
  }

  func testSuccessfulDeleteInvalidatesSnapshotWhenAccountsRefreshFails() async throws {
    let initial = makeModel()
    await loadLedger(initial)
    store.waitForPendingWrites()
    let snapshot = try XCTUnwrap(store.load())
    XCTAssertTrue(snapshot.ledgerPage?.transactions.contains {
      $0.id == SplitMirrorFixtureProtocol.mirrorID
    } == true)

    // Delete from a warm launch, before its provisional references have been
    // refreshed. Simply calling persistSnapshot would refuse to write here.
    let model = AppModel(settings: initial.settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    XCTAssertTrue(model.ledgerIsProvisional)
    let mirror = try XCTUnwrap(loadedMirror(in: model))
    SplitMirrorFixtureProtocol.failReadsAfterDelete()
    // A queued pre-delete write must not recreate the invalidated file either.
    store.scheduleWrite(snapshot)
    try await model.deleteTransaction(mirror)
    await model.refresh(slices: [.accounts])
    assertMirrorGoneAndParentUnlinked(model)
    let requests = SplitMirrorFixtureProtocol.requests()
    let deleteIndex = try XCTUnwrap(requests.firstIndex { $0.method == "DELETE" })
    XCTAssertTrue(requests.dropFirst(deleteIndex + 1).contains {
      $0.method == "GET" && $0.path.hasSuffix("/accounts")
    })
    store.waitForPendingWrites()

    // No network refresh runs on this new model: this is the offline first frame.
    let restored = AppModel(settings: model.settings, viewPrefs: ViewPrefs(), snapshotStore: store)
    XCTAssertFalse(restored.transactions.contains { $0.id == SplitMirrorFixtureProtocol.mirrorID })
    XCTAssertFalse(restored.transactions.flatMap(\.subtransactions).contains {
      $0.transferTransactionID == SplitMirrorFixtureProtocol.mirrorID
    })
    XCTAssertNil(store.load(), "failed follow-up reads must not leave the pre-delete snapshot")
  }

  // MARK: - Reads that were already in flight

  func testADelayedFirstPageCannotResurrectTheDeletedMirrorOrItsLink() async throws {
    let model = makeModel()
    await loadLedger(model)
    let mirror = try XCTUnwrap(loadedMirror(in: model))

    SplitMirrorFixtureProtocol.hold(.firstPage)
    let refresh = Task { await model.refreshLedger(quiet: true) }
    let parked = await waitUntil { SplitMirrorFixtureProtocol.parkedCount == 1 }
    XCTAssertTrue(parked, "the first page must be in flight before the delete lands")

    try await model.deleteTransaction(mirror)
    SplitMirrorFixtureProtocol.releaseParked()
    await refresh.value

    assertMirrorGoneAndParentUnlinked(model)
  }

  func testADelayedOlderPageCannotResurrectTheDeletedMirrorOrItsLink() async throws {
    // The parent is not on the first page, so the older page is the only place
    // it can arrive from -- the "missing parent" order.
    SplitMirrorFixtureProtocol.setFirstPage(omitsParent: true, hasMore: true)
    let model = makeModel()
    await loadLedger(model)
    XCTAssertNil(
      model.transactions.first { $0.id == SplitMirrorFixtureProtocol.parentID },
      "this test needs the parent to arrive from the older page"
    )
    XCTAssertTrue(model.hasMoreTransactions)
    let mirror = try XCTUnwrap(loadedMirror(in: model))

    SplitMirrorFixtureProtocol.hold(.olderPage)
    let older = Task { await model.loadOlderTransactions() }
    let parked = await waitUntil { SplitMirrorFixtureProtocol.parkedCount == 1 }
    XCTAssertTrue(parked, "the older page must be in flight before the delete lands")

    try await model.deleteTransaction(mirror)
    SplitMirrorFixtureProtocol.releaseParked()
    await older.value

    XCTAssertTrue(
      model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.olderMarkerID },
      "the older page must have landed, or this test proves nothing"
    )
    assertMirrorGoneAndParentUnlinked(model)
  }

  func testARelinkThatLandsAfterTheDeleteSurvivesTheWalksNextPage() async throws {
    // The walk's first page is asked for before the delete; its next page is
    // asked for after it, by which time another client has relinked the
    // surviving line to a new mirror. That page must be applied as it came.
    // The first load stops at its first page (`hasMore: false`), so the parent
    // and the relink stay unread until the walk's later page.
    SplitMirrorFixtureProtocol.setFirstPage(omitsParent: true, hasMore: false, recentRows: true)
    SplitMirrorFixtureProtocol.relinkOnDelete()
    let model = makeModel()
    await loadLedger(model)
    XCTAssertFalse(
      model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.parentID },
      "this test needs the parent to arrive from the walk's later page"
    )
    XCTAssertFalse(model.hasMoreTransactions, "the first load must not consume the later page")
    let mirror = try XCTUnwrap(loadedMirror(in: model))

    // The walk's own first page has more rows, and its rows are recent enough
    // that the horizon fill goes on to ask for the next one.
    SplitMirrorFixtureProtocol.setFirstPage(omitsParent: true, hasMore: true, recentRows: true)
    SplitMirrorFixtureProtocol.hold(.firstPage)
    let walk = Task { await model.refreshLedger(quiet: false) }
    let parked = await waitUntil { SplitMirrorFixtureProtocol.parkedCount == 1 }
    XCTAssertTrue(parked, "the walk's first page must be in flight before the delete lands")

    try await model.deleteTransaction(mirror)
    SplitMirrorFixtureProtocol.clearHold()
    SplitMirrorFixtureProtocol.releaseParked()
    await walk.value

    let requests = SplitMirrorFixtureProtocol.requests()
    guard
      let deleteIndex = requests.firstIndex(where: { $0.method == "DELETE" }),
      let laterPageIndex = requests.firstIndex(where: {
        $0.query.contains("offset=\(SplitMirrorFixtureProtocol.olderOffset)")
      })
    else {
      XCTFail("this test needs both the delete and the walk's later page, saw \(requests)")
      return
    }
    XCTAssertLessThan(
      deleteIndex,
      laterPageIndex,
      "the walk's later page must have been asked for after the delete"
    )

    XCTAssertTrue(
      model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.olderMarkerID },
      "the walk's later page must have landed, or this test proves nothing"
    )
    XCTAssertFalse(model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.mirrorID })
    XCTAssertTrue(
      model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.newMirrorID },
      "another client's replacement mirror must survive"
    )
    let parent = try XCTUnwrap(
      model.transactions.first { $0.id == SplitMirrorFixtureProtocol.parentID }
    )
    let line = try XCTUnwrap(
      parent.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subLinkID }
    )
    XCTAssertEqual(
      line.transferTransactionID,
      SplitMirrorFixtureProtocol.newMirrorID,
      "a page asked for after the delete must not unlink a line that was relinked"
    )
    XCTAssertEqual(
      line.transferAccountID,
      SplitMirrorFixtureProtocol.thirdAccountID,
      "the relinked line must keep its new destination"
    )
    XCTAssertEqual(
      parent.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subSiblingID }?.categoryID,
      "cat-1"
    )
  }

  func testADelayedApprovalQueueCannotResurrectTheDeletedMirrorOrItsLink() async throws {
    let model = makeModel()
    await loadLedger(model)
    let mirror = try XCTUnwrap(loadedMirror(in: model))

    SplitMirrorFixtureProtocol.hold(.unapprovedQueue)
    let queue = Task { await model.openUnapprovedQueue(viewer: "split-mirror-test") }
    let parked = await waitUntil { SplitMirrorFixtureProtocol.parkedCount == 1 }
    XCTAssertTrue(parked, "the queue must be in flight before the delete lands")

    try await model.deleteTransaction(mirror)
    SplitMirrorFixtureProtocol.releaseParked()
    await queue.value

    XCTAssertEqual(model.unapprovedQueuePhase, .loaded, "the queue response must have landed")
    XCTAssertFalse(
      model.unapprovedTransactions.contains { $0.id == SplitMirrorFixtureProtocol.mirrorID },
      "a pre-delete queue response must not restore the deleted mirror"
    )
    let queuedParent = try XCTUnwrap(
      model.unapprovedTransactions.first { $0.id == SplitMirrorFixtureProtocol.parentID }
    )
    XCTAssertNil(
      queuedParent.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subLinkID }?.transferTransactionID,
      "a pre-delete queue response must not restore the cleared link"
    )
    XCTAssertNil(
      queuedParent.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subLinkID }?.transferAccountID
    )
    XCTAssertEqual(
      queuedParent.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subSiblingID }?.categoryID,
      "cat-1"
    )
  }

  func testADelayedFocusedAccountHorizonCannotResurrectTheDeletedMirror() async throws {
    let model = makeModel()
    await loadLedger(model)
    let mirror = try XCTUnwrap(loadedMirror(in: model))

    SplitMirrorFixtureProtocol.hold(.focusedAccount)
    model.beginFocusedRegisterAccount(SplitMirrorFixtureProtocol.mirrorAccountID)
    let parked = await waitUntil { SplitMirrorFixtureProtocol.parkedCount == 1 }
    XCTAssertTrue(parked, "the focused account page must be in flight before the delete lands")

    try await model.deleteTransaction(mirror)
    SplitMirrorFixtureProtocol.releaseParked()

    let landed = await waitUntil {
      model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.focusedMarkerID }
    }
    XCTAssertTrue(landed, "the focused page must have landed, or this test proves nothing")
    assertMirrorGoneAndParentUnlinked(model)
  }

  // MARK: - Later reads and other scopes

  func testAReadThatStartsAfterTheDeleteStillApplies() async throws {
    let model = makeModel()
    await loadLedger(model)
    let mirror = try XCTUnwrap(loadedMirror(in: model))
    try await model.deleteTransaction(mirror)

    await model.refresh(slices: [.ledger], quiet: false)

    XCTAssertFalse(model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.mirrorID })
    XCTAssertTrue(
      model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.siblingID },
      "protection must not suppress rows the delete never touched"
    )
    let parent = try XCTUnwrap(model.transactions.first { $0.id == SplitMirrorFixtureProtocol.parentID })
    XCTAssertNil(parent.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subLinkID }?.transferTransactionID)
  }

  func testADeleteWithoutParentMetadataStillUnlinksTheMatchingLine() async throws {
    // The tombstone and the row in hand both omit `parent_transaction_id`, as a
    // legacy row can. The line that named the mirror is then the only way back
    // to the parent, and it must still be unlinked.
    SplitMirrorFixtureProtocol.omitParentMetadata()
    let model = makeModel()
    await loadLedger(model)
    let mirror = try XCTUnwrap(loadedMirror(in: model))
    XCTAssertNil(mirror.parentTransactionID, "this test needs the row in hand to omit the parent")

    try await model.deleteTransaction(mirror)

    assertMirrorGoneAndParentUnlinked(model)
  }

  func testSwitchingPlansResetsDeleteProtection() async throws {
    let model = makeModel()
    await loadLedger(model)
    let mirror = try XCTUnwrap(loadedMirror(in: model))

    // A plan-one read is still in flight when the delete lands and when the
    // plan switches, which is the order a slow network produces.
    SplitMirrorFixtureProtocol.hold(.firstPage)
    let stale = Task { await model.refreshLedger(quiet: true) }
    let parked = await waitUntil { SplitMirrorFixtureProtocol.parkedCount == 1 }
    XCTAssertTrue(parked, "the plan-one page must be in flight before the delete lands")
    try await model.deleteTransaction(mirror)
    SplitMirrorFixtureProtocol.clearHold()

    var switched = model.settings
    switched.planID = SplitMirrorFixtureProtocol.secondPlanID
    await model.applySettings(switched)

    SplitMirrorFixtureProtocol.releaseParked()
    await stale.value

    XCTAssertEqual(model.settings.planID, SplitMirrorFixtureProtocol.secondPlanID)
    // The second plan's own row reuses the deleted id. Protection is scoped to
    // one connection's read order, so it must not survive the switch.
    XCTAssertTrue(
      model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.mirrorID },
      "a new scope must not inherit the old plan's delete protection"
    )
    XCTAssertTrue(model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.secondPlanRowID })
    XCTAssertFalse(
      model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.parentID },
      "the previous plan's rows must be gone after the switch"
    )
  }

  // MARK: - Fixture helpers

  private func makeModel() -> AppModel {
    var settings = APISettings()
    settings.baseURLString = SplitMirrorFixtureProtocol.fixtureBaseURL
    settings.authenticatedUserID = "split-mirror-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = SplitMirrorFixtureProtocol.planID
    return AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: store)
  }

  private func loadLedger(_ model: AppModel) async {
    await model.refresh(slices: [.accounts, .ledger], quiet: false)
    XCTAssertEqual(model.ledgerPhase, .loaded, "the fixture ledger must load")
  }

  private func loadedMirror(in model: AppModel) -> Transaction? {
    model.transactions.first { $0.id == SplitMirrorFixtureProtocol.mirrorID }
  }

  private func assertMirrorGoneAndParentUnlinked(
    _ model: AppModel,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertFalse(
      model.transactions.contains { $0.id == SplitMirrorFixtureProtocol.mirrorID },
      "a response fetched before the delete must not restore the mirror",
      file: file,
      line: line
    )
    guard let parent = model.transactions.first(where: { $0.id == SplitMirrorFixtureProtocol.parentID })
    else {
      XCTFail("the surviving parent must be on screen", file: file, line: line)
      return
    }
    let link = parent.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subLinkID }
    XCTAssertNil(
      link?.transferTransactionID,
      "a response fetched before the delete must not restore the cleared link",
      file: file,
      line: line
    )
    XCTAssertNil(link?.transferAccountID, file: file, line: line)
    XCTAssertEqual(
      parent.subtransactions.first { $0.id == SplitMirrorFixtureProtocol.subSiblingID }?.categoryID,
      "cat-1",
      "an unrelated split line must survive",
      file: file,
      line: line
    )
  }

  /// Polls a main-actor condition; the reads and follow-up refreshes under test
  /// are detached, so there is no task to await from the call site.
  private func waitUntil(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    _ condition: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if condition() {
        try? await Task.sleep(nanoseconds: 50_000_000)
        return true
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
  }
}

// MARK: - Fixture server

/// Serves one split parent with a mirrored line on a second account, an
/// unrelated sibling row, and the delete tombstone that clears the parent's
/// link. Every ledger response can be parked so a test can land a delete while
/// a read is in flight; the parked body is the pre-delete one, and every later
/// response serves the post-delete state. The script can also show the
/// surviving line relinked to a replacement mirror on a third account, which is
/// what another client's write to the same line looks like.
private final class SplitMirrorFixtureProtocol: URLProtocol {
  static let fixtureHost = "howmuch-split-mirror.test"
  static let fixtureBaseURL = "https://howmuch-split-mirror.test"
  static let planID = "plan-1"
  static let secondPlanID = "plan-2"
  static let accountID = "acct-1"
  static let mirrorAccountID = "acct-2"
  static let parentID = "txn-parent"
  static let mirrorID = "txn-mirror"
  static let siblingID = "txn-sibling"
  static let subLinkID = "sub-link"
  static let subSiblingID = "sub-sibling"
  static let olderMarkerID = "txn-older"
  static let focusedMarkerID = "txn-focused"
  static let secondPlanRowID = "txn-plan-2"
  /// Another client's replacement mirror for the surviving split line.
  static let newMirrorID = "txn-new-mirror"
  static let thirdAccountID = "acct-3"
  static let olderOffset = 2

  enum Hold: Equatable {
    case none
    case firstPage
    case olderPage
    case unapprovedQueue
    case focusedAccount
  }

  struct RecordedRequest: Equatable {
    let method: String
    let path: String
    let query: String
  }

  private struct Parked {
    let urlProtocol: SplitMirrorFixtureProtocol
    let body: String
  }

  private static let lock = NSLock()
  private static var recordedRequests: [RecordedRequest] = []
  private static var parkedResponses: [Parked] = []
  private static var currentHold: Hold = .none
  private static var deleteLanded = false
  private static var firstPageOmitsParent = false
  private static var firstPageHasMore = false
  private static var firstPageRecentRows = false
  private static var parentMetadataOmitted = false
  private static var relinkAfterDelete = false
  private static var readsFailAfterDelete = false

  static func reset() {
    lock.lock()
    recordedRequests = []
    parkedResponses = []
    currentHold = .none
    deleteLanded = false
    firstPageOmitsParent = false
    firstPageHasMore = false
    firstPageRecentRows = false
    parentMetadataOmitted = false
    relinkAfterDelete = false
    readsFailAfterDelete = false
    lock.unlock()
  }

  static func failReadsAfterDelete() {
    lock.lock()
    readsFailAfterDelete = true
    lock.unlock()
  }

  static func hold(_ kind: Hold) {
    lock.lock()
    currentHold = kind
    lock.unlock()
  }

  static func clearHold() {
    hold(.none)
  }

  static func setFirstPage(omitsParent: Bool, hasMore: Bool, recentRows: Bool = false) {
    lock.lock()
    firstPageOmitsParent = omitsParent
    firstPageHasMore = hasMore
    firstPageRecentRows = recentRows
    lock.unlock()
  }

  /// Serves the mirror row and its tombstone without `parent_transaction_id`,
  /// the way a legacy row can arrive.
  static func omitParentMetadata() {
    lock.lock()
    parentMetadataOmitted = true
    lock.unlock()
  }

  /// After the delete, the server shows the surviving split line relinked to a
  /// new mirror on a third account -- another client moved it while this one was
  /// deleting the old mirror.
  static func relinkOnDelete() {
    lock.lock()
    relinkAfterDelete = true
    lock.unlock()
  }

  private static var omitsParentMetadata: Bool {
    lock.lock()
    defer { lock.unlock() }
    return parentMetadataOmitted
  }

  static func requests() -> [RecordedRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests
  }

  static var parkedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return parkedResponses.count
  }

  static func releaseParked() {
    lock.lock()
    let responses = parkedResponses
    parkedResponses = []
    lock.unlock()
    for response in responses {
      response.urlProtocol.send(body: response.body)
    }
  }

  private static var hasDeleteLanded: Bool {
    lock.lock()
    defer { lock.unlock() }
    return deleteLanded
  }

  private static var omitsParent: Bool {
    lock.lock()
    defer { lock.unlock() }
    return firstPageOmitsParent
  }

  private static var hasMoreFirstPage: Bool {
    lock.lock()
    defer { lock.unlock() }
    return firstPageHasMore
  }

  private static var usesRecentFirstPageRows: Bool {
    lock.lock()
    defer { lock.unlock() }
    return firstPageRecentRows
  }

  private static var relinksAfterDelete: Bool {
    lock.lock()
    defer { lock.unlock() }
    return relinkAfterDelete
  }

  // MARK: URLProtocol

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
    let method = request.httpMethod ?? "GET"
    Self.record(method: method, url: url)
    guard let body = Self.body(for: url, method: method) else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    if Self.shouldPark(method: method, url: url) {
      Self.park(Parked(urlProtocol: self, body: body))
      return
    }
    send(body: body)
  }

  override func stopLoading() {}

  private func send(body: String) {
    guard let url = request.url,
          let response = HTTPURLResponse(
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

  private static func record(method: String, url: URL) {
    lock.lock()
    recordedRequests.append(
      RecordedRequest(method: method, path: url.path, query: url.query ?? "")
    )
    if method == "DELETE" {
      deleteLanded = true
    }
    lock.unlock()
  }

  private static func park(_ response: Parked) {
    lock.lock()
    parkedResponses.append(response)
    lock.unlock()
  }

  private static func shouldPark(method: String, url: URL) -> Bool {
    guard method == "GET" else {
      return false
    }
    lock.lock()
    let kind = currentHold
    lock.unlock()
    let query = url.query ?? ""
    switch kind {
    case .none:
      return false
    case .firstPage:
      return isPlanLedger(url) && query.contains("offset=0") && !query.contains("type=")
    case .olderPage:
      return isPlanLedger(url) && !query.contains("offset=0") && !query.contains("type=")
    case .unapprovedQueue:
      return isPlanLedger(url) && query.contains("type=unapproved")
    case .focusedAccount:
      return url.path.hasSuffix("/accounts/\(mirrorAccountID)/transactions")
    }
  }

  private static func isPlanLedger(_ url: URL) -> Bool {
    url.path.hasSuffix("/transactions") && !url.path.contains("/accounts/")
  }

  // MARK: Responses

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }()

  private static func encoded<T: Encodable>(_ value: T) -> String {
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return text
  }

  private static func body(for url: URL, method: String) -> String? {
    let path = url.path
    let query = url.query ?? ""
    lock.lock()
    let failRead = method == "GET" && deleteLanded && readsFailAfterDelete
    lock.unlock()
    if failRead { return nil }
    if method == "DELETE" {
      return encoded(
        Envelope(data: SingleTransactionBody(transaction: tombstoneRow(), serverKnowledge: 8))
      )
    }
    if path == "/v1/plans" {
      return encoded(
        Envelope(
          data: PlansBody(plans: [
            PlansBody.Plan(id: planID, name: "Fixture Plan"),
            PlansBody.Plan(id: secondPlanID, name: "Second Plan"),
          ])
        )
      )
    }
    guard let plan = planIDFromPath(path) else {
      return nil
    }
    if path.hasSuffix("/accounts") {
      return encoded(Envelope(data: AccountsBody(accounts: accountRows(), serverKnowledge: 9)))
    }
    if path.hasSuffix("/payees") {
      return encoded(Envelope(data: PayeesBody(payees: [])))
    }
    if path.hasSuffix("/transactions"), path.contains("/accounts/") {
      return encoded(
        Envelope(
          data: PageBody(
            transactions: focusedPageRows(),
            serverKnowledge: 10,
            hasMore: false,
            nextOffset: nil
          )
        )
      )
    }
    if path.hasSuffix("/transactions") {
      if query.contains("type=unapproved") {
        return encoded(
          Envelope(
            data: PageBody(
              transactions: queueRows(),
              serverKnowledge: 12,
              hasMore: false,
              nextOffset: nil
            )
          )
        )
      }
      if query.contains("offset=0") {
        return encoded(Envelope(data: firstPage(forPlan: plan)))
      }
      return encoded(Envelope(data: olderPage(forPlan: plan)))
    }
    return nil
  }

  private static func planIDFromPath(_ path: String) -> String? {
    let prefix = "/v1/plans/"
    guard path.hasPrefix(prefix) else {
      return nil
    }
    return path.dropFirst(prefix.count).split(separator: "/").first.map { String($0) }
  }

  private static func accountRows() -> [Account] {
    let balance = hasDeleteLanded ? 250 : 100
    return [
      Account(
        id: accountID,
        name: "Fixture Account",
        icon: nil,
        type: "checking",
        onBudget: true,
        closed: false,
        balance: balance,
        clearedBalance: balance,
        unclearedBalance: 0,
        lastReconciledDate: nil,
        deleted: false
      ),
      Account(
        id: mirrorAccountID,
        name: "Mirror Account",
        icon: nil,
        type: "checking",
        onBudget: true,
        closed: false,
        balance: 0,
        clearedBalance: 0,
        unclearedBalance: 0,
        lastReconciledDate: nil,
        deleted: false
      ),
    ]
  }

  private static func firstPage(forPlan plan: String) -> PageBody {
    if plan == secondPlanID {
      return PageBody(
        transactions: [
          row(id: mirrorID, accountID: accountID, date: "2026-09-02", amount: -900),
          row(id: secondPlanRowID, accountID: accountID, date: "2026-09-03", amount: -400),
        ],
        serverKnowledge: 21,
        hasMore: false,
        nextOffset: nil
      )
    }
    let deleted = hasDeleteLanded
    var rows: [Transaction] = []
    if !omitsParent {
      rows.append(parentRow(approved: true, link: survivingLink(deleted: deleted)))
    }
    rows.append(contentsOf: survivingMirrorRows(deleted: deleted))
    rows.append(
      row(
        id: siblingID,
        accountID: accountID,
        date: usesRecentFirstPageRows ? Date.now.isoDateString : "2020-01-02",
        amount: -700
      )
    )
    let hasMore = hasMoreFirstPage
    return PageBody(
      transactions: rows,
      serverKnowledge: 7,
      hasMore: hasMore,
      nextOffset: hasMore ? olderOffset : nil
    )
  }

  private static func olderPage(forPlan plan: String) -> PageBody {
    guard plan == planID else {
      return PageBody(transactions: [], serverKnowledge: 22, hasMore: false, nextOffset: nil)
    }
    let deleted = hasDeleteLanded
    var rows: [Transaction] = [parentRow(approved: true, link: survivingLink(deleted: deleted))]
    rows.append(contentsOf: survivingMirrorRows(deleted: deleted))
    rows.append(row(id: olderMarkerID, accountID: accountID, date: "2019-12-01", amount: -300))
    return PageBody(transactions: rows, serverKnowledge: 8, hasMore: false, nextOffset: nil)
  }

  private static func queueRows() -> [Transaction] {
    if hasDeleteLanded {
      return [parentRow(approved: false, link: .none)]
    }
    return [parentRow(approved: false, link: .mirror), mirrorRow()]
  }

  /// Which mirror the surviving split line names once this delete has landed.
  private enum ParentLink {
    /// The mirror this delete removed.
    case mirror
    /// No link: the server cleared the line, as this delete asks it to.
    case none
    /// Another client's replacement mirror, on a third account.
    case relinked
  }

  private static func survivingLink(deleted: Bool) -> ParentLink {
    guard deleted else {
      return .mirror
    }
    return relinksAfterDelete ? .relinked : .none
  }

  private static func survivingMirrorRows(deleted: Bool) -> [Transaction] {
    guard deleted else {
      return [mirrorRow()]
    }
    return relinksAfterDelete ? [newMirrorRow()] : []
  }

  private static func focusedPageRows() -> [Transaction] {
    let marker = row(
      id: focusedMarkerID,
      accountID: mirrorAccountID,
      date: Date.now.isoDateString,
      amount: 1_200
    )
    return hasDeleteLanded ? [marker] : [mirrorRow(), marker]
  }

  private static func tombstoneRow() -> Transaction {
    row(
      id: mirrorID,
      accountID: mirrorAccountID,
      date: "2026-09-01",
      amount: 6_000,
      approved: false,
      parentTransactionID: omitsParentMetadata ? nil : parentID,
      transferTransactionID: subLinkID,
      deleted: true
    )
  }

  private static func parentRow(approved: Bool, link: ParentLink) -> Transaction {
    row(
      id: parentID,
      accountID: accountID,
      date: "2020-01-01",
      amount: -5_000,
      approved: approved,
      subtransactions: [
        Subtransaction(
          id: subLinkID,
          transactionID: parentID,
          amount: -6_000,
          memo: nil,
          payeeID: nil,
          payeeName: nil,
          categoryID: nil,
          categoryName: nil,
          transferAccountID: linkedDestination(link),
          transferTransactionID: linkedMirrorID(link),
          deleted: false
        ),
        Subtransaction(
          id: subSiblingID,
          transactionID: parentID,
          amount: 1_000,
          memo: nil,
          payeeID: nil,
          payeeName: nil,
          categoryID: "cat-1",
          categoryName: "Groceries",
          transferAccountID: nil,
          transferTransactionID: nil,
          deleted: false
        ),
      ]
    )
  }

  private static func mirrorRow() -> Transaction {
    row(
      id: mirrorID,
      accountID: mirrorAccountID,
      date: Date.now.isoDateString,
      amount: 6_000,
      approved: false,
      parentTransactionID: omitsParentMetadata ? nil : parentID,
      transferTransactionID: subLinkID
    )
  }

  private static func newMirrorRow() -> Transaction {
    row(
      id: newMirrorID,
      accountID: thirdAccountID,
      date: "2026-09-02",
      amount: 6_000,
      approved: false,
      parentTransactionID: parentID,
      transferTransactionID: subLinkID
    )
  }

  private static func linkedDestination(_ link: ParentLink) -> String? {
    switch link {
    case .mirror: return mirrorAccountID
    case .relinked: return thirdAccountID
    case .none: return nil
    }
  }

  private static func linkedMirrorID(_ link: ParentLink) -> String? {
    switch link {
    case .mirror: return mirrorID
    case .relinked: return newMirrorID
    case .none: return nil
    }
  }

  private static func row(
    id: String,
    accountID: String,
    date: String,
    amount: Int,
    approved: Bool = true,
    parentTransactionID: String? = nil,
    transferAccountID: String? = nil,
    transferTransactionID: String? = nil,
    deleted: Bool = false,
    subtransactions: [Subtransaction] = []
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
      payeeID: nil,
      payeeName: "Fixture Payee",
      categoryID: nil,
      categoryName: nil,
      transferAccountID: transferAccountID,
      transferTransactionID: transferTransactionID,
      parentTransactionID: parentTransactionID,
      matchedTransactionID: nil,
      importID: nil,
      importPayeeName: nil,
      importPayeeNameOriginal: nil,
      deleted: deleted,
      subtransactions: subtransactions
    )
  }
}

private struct Envelope<Payload: Encodable>: Encodable {
  let data: Payload
}

private struct PageBody: Encodable {
  let transactions: [Transaction]
  let serverKnowledge: Int
  let hasMore: Bool
  let nextOffset: Int?
}

private struct SingleTransactionBody: Encodable {
  let transaction: Transaction
  let serverKnowledge: Int
}

private struct AccountsBody: Encodable {
  let accounts: [Account]
  let serverKnowledge: Int
}

private struct PayeesBody: Encodable {
  let payees: [Payee]
}

private struct PlansBody: Encodable {
  struct Plan: Encodable {
    let id: String
    let name: String
  }

  let plans: [Plan]
}

/// What a delete takes off each account. Pure: rows in, deltas out. Every
/// value is invented.
final class DeleteBalanceDeltaTests: XCTestCase {
  func testAPlainRowComesOffItsAccountByClearedState() {
    let uncleared = Self.row("txn-1", account: "acct-a", amount: -1_000, cleared: .uncleared)
    XCTAssertEqual(
      DeleteBalanceDelta.deltas(deleted: uncleared, removedIDs: ["txn-1"], knownRows: [:]),
      ["acct-a": .init(balance: 1_000, cleared: 0, uncleared: 1_000)]
    )
    let reconciled = Self.row("txn-2", account: "acct-a", amount: 2_500, cleared: .reconciled)
    XCTAssertEqual(
      DeleteBalanceDelta.deltas(deleted: reconciled, removedIDs: ["txn-2"], knownRows: [:]),
      ["acct-a": .init(balance: -2_500, cleared: -2_500, uncleared: 0)]
    )
  }

  func testATransferTakesBothSidesUsingEachSidesClearedState() {
    let out = Self.row("out", account: "acct-a", amount: -5_000, cleared: .cleared,
                       transferAccount: "acct-b", transferID: "in")
    let into = Self.row("in", account: "acct-b", amount: 5_000, cleared: .uncleared,
                        transferAccount: "acct-a", transferID: "out")
    XCTAssertEqual(
      DeleteBalanceDelta.deltas(deleted: out, removedIDs: ["out", "in"], knownRows: ["out": out, "in": into]),
      [
        "acct-a": .init(balance: 5_000, cleared: 5_000, uncleared: 0),
        "acct-b": .init(balance: -5_000, cleared: 0, uncleared: -5_000),
      ]
    )
  }

  func testATransferSideNotInHandIsDerivedFromTheLink() {
    let out = Self.row("out", account: "acct-a", amount: -5_000, cleared: .cleared,
                       transferAccount: "acct-b", transferID: "in")
    XCTAssertEqual(
      DeleteBalanceDelta.deltas(deleted: out, removedIDs: ["out", "in"], knownRows: [:])["acct-b"],
      .init(balance: -5_000, cleared: 0, uncleared: -5_000)
    )
  }

  func testASplitParentTakesItsMirroredLines() {
    let parent = Self.row("parent", account: "acct-a", amount: -3_000, cleared: .uncleared, lines: [
      Self.line("line-1", parent: "parent", amount: -1_000),
      Self.line("line-2", parent: "parent", amount: -2_000, transferAccount: "acct-b", transferID: "mirror"),
    ])
    XCTAssertEqual(
      DeleteBalanceDelta.deltas(deleted: parent, removedIDs: ["parent", "mirror"], knownRows: [:]),
      [
        "acct-a": .init(balance: 3_000, cleared: 0, uncleared: 3_000),
        "acct-b": .init(balance: -2_000, cleared: 0, uncleared: -2_000),
      ]
    )
  }

  /// Deleting a split mirror removes only the mirror; the parent and its line
  /// stay, so the parent's account does not move.
  func testASplitMirrorMovesOnlyItsOwnAccount() {
    let mirror = Self.row("mirror", account: "acct-b", amount: 2_000, cleared: .cleared,
                          transferAccount: "acct-a", transferID: "line-2", parentID: "parent")
    XCTAssertEqual(
      DeleteBalanceDelta.deltas(deleted: mirror, removedIDs: ["mirror"], knownRows: [:]),
      ["acct-b": .init(balance: -2_000, cleared: -2_000, uncleared: 0)]
    )
  }

  func testApplyingAdjustsOnlyTheNamedAccounts() {
    let accounts = [Self.account("acct-a", balance: 10_000, cleared: 8_000), Self.account("acct-b", balance: 0, cleared: 0)]
    let next = DeleteBalanceDelta.applying(["acct-a": .init(balance: 1_000, cleared: 0, uncleared: 1_000)], to: accounts)
    XCTAssertEqual(next[0].balance, 11_000)
    XCTAssertEqual(next[0].clearedBalance, 8_000)
    XCTAssertEqual(next[0].unclearedBalance, 3_000)
    XCTAssertEqual(next[1], accounts[1])
  }

  // MARK: Fixtures

  private static func row(
    _ id: String,
    account: String,
    amount: Int,
    cleared: ClearedState,
    transferAccount: String? = nil,
    transferID: String? = nil,
    parentID: String? = nil,
    lines: [Subtransaction] = []
  ) -> Transaction {
    Transaction(
      id: id, date: "2026-01-02", amount: amount, memo: nil, cleared: cleared, approved: true,
      flagColor: nil, flagName: nil, accountID: account, accountName: "Fixture", payeeID: nil,
      payeeName: nil, categoryID: nil, categoryName: nil, transferAccountID: transferAccount,
      transferTransactionID: transferID, parentTransactionID: parentID, matchedTransactionID: nil,
      importID: nil, importPayeeName: nil, importPayeeNameOriginal: nil, deleted: false,
      subtransactions: lines
    )
  }

  private static func line(
    _ id: String,
    parent: String,
    amount: Int,
    transferAccount: String? = nil,
    transferID: String? = nil
  ) -> Subtransaction {
    Subtransaction(
      id: id, transactionID: parent, amount: amount, memo: nil, payeeID: nil, payeeName: nil,
      categoryID: nil, categoryName: nil, transferAccountID: transferAccount,
      transferTransactionID: transferID, deleted: false
    )
  }

  private static func account(_ id: String, balance: Int, cleared: Int) -> Account {
    Account(
      id: id, name: "Fixture", icon: nil, type: "checking", onBudget: true, closed: false,
      balance: balance, clearedBalance: cleared, unclearedBalance: balance - cleared,
      lastReconciledDate: nil, deleted: false
    )
  }
}
