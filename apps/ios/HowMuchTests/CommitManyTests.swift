import XCTest
@testable import HowMuch

/// Saving captures: each becomes one durable create command, in order, with
/// its import id as the replay key. Nothing here reaches a network: the
/// outbox waits far longer than any test runs before it would send.
@MainActor
final class CommitManyTests: XCTestCase {
  private var credentialService = ""
  private var savedDefaults: [String: Any] = [:]
  private let keys = [APISettings.userDefaultsKey, ScopedViewPrefsStore.userDefaultsKey]

  override func setUp() {
    super.setUp()
    credentialService = APISettings.useCredentialService("HowMuch.CommitManyTests.\(UUID())")
    for key in keys {
      savedDefaults[key] = UserDefaults.standard.object(forKey: key)
    }
  }

  override func tearDown() {
    APISettings.useCredentialService(credentialService)
    for key in keys { UserDefaults.standard.set(savedDefaults[key], forKey: key) }
    super.tearDown()
  }

  func testOneSaveForTwoDrafts() throws {
    let model = makeModel()
    try model.commit([Self.draft(importID: "imp-one", amount: 7_100), Self.draft(importID: "imp-two", amount: 2_300)])

    let creates = createRequests(model.currentOutbox)
    XCTAssertEqual(creates.map(\.importID), ["imp-one", "imp-two"])
    XCTAssertEqual(creates.map(\.amount), [-7_100, -2_300])
    XCTAssertTrue(creates.allSatisfy(\.approved))
    XCTAssertEqual(createRequests(model.outboxStorePeek() ?? []), creates, "on disk before the call returns")
    XCTAssertEqual(model.pendingRows.map(\.signedAmount), [-7_100, -2_300])
  }

  func testIdenticalImportIDReplayDoesNotDuplicate() throws {
    let model = makeModel()
    let draft = Self.draft(importID: "imp-same", amount: 5_000)
    try model.commit(draft)
    try model.commit(draft)
    try model.commit([draft, draft])

    XCTAssertEqual(createRequests(model.currentOutbox).map(\.importID), ["imp-same"])
    XCTAssertTrue(model.hasPendingCreate(importID: "imp-same"))
  }

  func testSingleDraftCommitStillMatchesToday() throws {
    let model = makeModel()
    let draft = Self.draft(importID: "imp-single", amount: 5_400)
    try model.commit(draft)

    let request = try XCTUnwrap(createRequests(model.currentOutbox).first)
    XCTAssertEqual(request, draft.writeRequest(includeCleared: draft.shouldWriteCleared))
    XCTAssertNil(request.id, "the client id lives on the command until it is sent")
    XCTAssertTrue(try XCTUnwrap(model.currentOutbox.first).transactionID.hasPrefix("txn_"))
  }

  func testRevisingAQueuedCaptureKeepsItsIdentity() throws {
    let model = makeModel()
    let draft = Self.draft(importID: "imp-posb", amount: 54_530)
    try model.commit(draft)
    let queued = try XCTUnwrap(model.currentOutbox.first)

    var item = CaptureDraftItem(draft: draft)
    item.committed = true
    item.draft.payeeName = "POSB rebate"
    item.draft.direction = .inflow
    model.reviseConversationCapture(item)

    XCTAssertEqual(model.currentOutbox.count, 1, "the revision folds into the create")
    let revised = try XCTUnwrap(model.currentOutbox.first)
    XCTAssertEqual(revised.id, queued.id)
    XCTAssertEqual(revised.transactionID, queued.transactionID)
    let request = try XCTUnwrap(createRequests([revised]).first)
    XCTAssertEqual(request.importID, "imp-posb")
    XCTAssertEqual(request.payeeName, "POSB rebate")
    XCTAssertEqual(request.amount, 54_530)
  }

  func testAFailedWriteRefusesTheSave() {
    struct DiskFull: Error {}
    let model = makeModel(store: .temporary(writeData: { _, _ in throw DiskFull() }))
    XCTAssertThrowsError(try model.commit(Self.draft(importID: "imp-x", amount: 1_000))) { error in
      XCTAssertEqual(error as? CommitRejection, .persistFailed)
    }
    XCTAssertTrue(model.currentOutbox.isEmpty, "nothing shows that is not on disk")
  }

  private func createRequests(_ commands: [OutboxCommand]) -> [TransactionWriteRequest] {
    commands.compactMap { command in
      if case .create(let request) = command.kind { return request }
      return nil
    }
  }

  private func makeModel(store: OutboxStore = .temporary()) -> AppModel {
    var settings = APISettings()
    settings.baseURLString = "https://commit-many.invalid"
    settings.authenticatedUserID = "commit-many"
    settings.sessionToken = "fixture"
    settings.planID = "plan"
    let model = AppModel(
      outboxStore: store,
      settings: settings,
      viewPrefs: ViewPrefs(),
      snapshotStore: SnapshotStore(
        directory: FileManager.default.temporaryDirectory
          .appendingPathComponent("HowMuchCommitManyTests/\(UUID().uuidString)", isDirectory: true)
      ),
      hasSavedSettings: true
    )
    model.outboxDebounce = .seconds(3_600)
    return model
  }

  private static func draft(importID: String, amount: Int) -> TransactionDraft {
    var draft = TransactionDraft()
    draft.importID = importID
    draft.accountID = "acct-everyday"
    draft.amountMagnitudeMilli = amount
    draft.direction = .outflow
    return draft
  }
}
