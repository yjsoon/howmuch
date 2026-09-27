import XCTest
@testable import HowMuch

extension OutboxStore {
  /// A store in a fresh temporary directory, reading legacy items from a
  /// fresh UserDefaults suite, so no test touches the app's real outbox.
  static func temporary(
    defaults: UserDefaults? = nil,
    writeData: ((Data, URL) throws -> Void)? = nil
  ) -> OutboxStore {
    let suite = "howmuch.tests.outbox.\(UUID().uuidString)"
    return OutboxStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("HowMuchOutboxTests/\(UUID().uuidString)", isDirectory: true),
      defaults: defaults ?? UserDefaults(suiteName: suite)!,
      writeData: writeData
    )
  }
}

/// The outbox on disk: durable, atomic, never silently emptied, and the one
/// place the old UserDefaults queue moves into.
final class OutboxStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var directory: URL!

  override func setUp() {
    super.setUp()
    suiteName = "howmuch.tests.outbox-store.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("HowMuchOutboxStoreTests/\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  private func store(writeData: ((Data, URL) throws -> Void)? = nil) -> OutboxStore {
    OutboxStore(directory: directory, defaults: defaults, writeData: writeData)
  }

  private func request(importID: String? = "imp-1", amount: Int = -12_500) -> TransactionWriteRequest {
    TransactionWriteRequest(
      accountID: "acct-everyday",
      date: "2026-09-20",
      amount: amount,
      payeeID: nil,
      payeeName: "Kopi",
      categoryID: "cat-food",
      memo: nil,
      cleared: .uncleared,
      approved: true,
      flagColor: nil,
      subtransactions: [],
      importID: importID
    )
  }

  private func command(_ kind: OutboxCommand.Kind, id: String = "txn_a", state: OutboxCommand.State = .queued, seq: Int = 1) -> OutboxCommand {
    OutboxCommand(
      id: UUID(),
      seq: seq,
      transactionID: id,
      connectionFingerprint: "https://howmuch.test|plan|user",
      createdAt: Date(timeIntervalSince1970: 1_790_000_000),
      kind: kind,
      state: state
    )
  }

  // MARK: - Persistence

  func testNoFileLoadsEmpty() throws {
    XCTAssertEqual(try store().load(), [])
    XCTAssertNil(store().peek(), "a load with nothing to migrate writes nothing")
  }

  func testSavedCommandsSurviveARelaunch() throws {
    let commands = [
      command(.create(request()), id: "txn_a", seq: 1),
      command(.cleared(expected: .uncleared, cleared: .cleared, approve: true), id: "txn_b", state: .rejected(message: "No", code: 400), seq: 2),
      command(.delete(expectedApproved: false), id: "txn_c", seq: 3),
    ]
    let first = store()
    _ = try first.load()
    try first.save(commands)

    XCTAssertEqual(try store().load(), commands)
  }

  func testSaveBeforeLoadIsRefused() {
    XCTAssertThrowsError(try store().save([command(.approve)]))
  }

  func testInFlightCommandsComeBackQueuedAndAreRewritten() throws {
    let first = store()
    _ = try first.load()
    try first.save([command(.update(request()), state: .inFlight)])

    let reloaded = try store().load()
    XCTAssertEqual(reloaded.map(\.state), [.queued])
    XCTAssertEqual(reloaded.map(\.attempted), [true], "it was on the wire, so it may be on the server")
    XCTAssertEqual(store().peek()?.map(\.state), [.queued], "the requeue is written back")
  }

  func testAFailedWriteLeavesThePreviousFileWhole() throws {
    let good = store()
    _ = try good.load()
    let kept = [command(.approve)]
    try good.save(kept)

    struct DiskFull: Error {}
    let failing = store(writeData: { _, _ in throw DiskFull() })
    _ = try failing.load()
    XCTAssertThrowsError(try failing.save([command(.approve), command(.approve, id: "txn_b")]))
    XCTAssertEqual(store().peek(), kept)
  }

  func testTheFileIsWrittenAtomically() throws {
    var options: [String] = []
    let recording = store(writeData: { data, url in
      options.append(url.lastPathComponent)
      try data.write(to: url, options: .atomic)
    })
    _ = try recording.load()
    try recording.save([command(.approve)])
    XCTAssertEqual(options, [OutboxStore.fileName])
    // The default writer is the atomic one; a leftover temporary file would
    // show up next to it.
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(names, [OutboxStore.fileName])
  }

  // MARK: - Quarantine

  func testACorruptFileIsSetAsideAndTheOutboxStartsEmpty() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let garbage = Data("{\"version\":1,\"commands\":[{\"broken\":".utf8)
    try garbage.write(to: directory.appendingPathComponent(OutboxStore.fileName))

    let outbox = store()
    XCTAssertEqual(try outbox.load(), [])
    XCTAssertTrue(outbox.quarantinedOnLastLoad)
    let quarantined = outbox.quarantinedFiles()
    XCTAssertEqual(quarantined.count, 1)
    XCTAssertEqual(try Data(contentsOf: quarantined[0]), garbage, "the unreadable bytes are kept as they were")

    try outbox.save([command(.approve)])
    XCTAssertEqual(outbox.quarantinedFiles().count, 1, "a later write never removes the quarantined copy")
    XCTAssertEqual(store().peek()?.count, 1)
  }

  func testAnUnreadableFileRefusesWritesRatherThanReplacingIt() throws {
    // A directory where the file should be cannot be read as data, like a
    // file protected before first unlock.
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(OutboxStore.fileName),
      withIntermediateDirectories: true
    )
    let outbox = store()
    XCTAssertThrowsError(try outbox.load())
    XCTAssertThrowsError(try outbox.save([command(.approve)]))
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: outbox.fileURL.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
  }

  // MARK: - Migration from UserDefaults

  /// Exactly what the previous build wrote: `JSONEncoder()` defaults, the
  /// request's own key names, dates as seconds since 2001, a rejected item,
  /// and an item from before splits (no `subtransactions`) and before import
  /// ids were minted at capture.
  private static let legacyPayload = """
  [
    {
      "id": "6F1C2A3B-0000-4000-8000-000000000001",
      "request": {
        "accountID": "acct-everyday", "date": "2026-09-20", "amount": -12500,
        "payeeID": null, "payeeName": "Kopi", "categoryID": "cat-food", "memo": null,
        "cleared": "uncleared", "approved": true, "flagColor": null,
        "subtransactions": [], "importID": "imp-kopi"
      },
      "connectionFingerprint": "https://howmuch.tk.sg|plan-1|user-1",
      "capturedAt": 780000000
    },
    {
      "id": "6F1C2A3B-0000-4000-8000-000000000002",
      "request": {
        "accountID": "acct-card", "date": "2026-09-21", "amount": -48000,
        "payeeID": "payee-grocer", "payeeName": null, "categoryID": null, "memo": "Weekly shop",
        "cleared": "cleared", "approved": true, "flagColor": "red",
        "subtransactions": [
          {"id": null, "amount": -30000, "payeeID": null, "payeeName": null, "categoryID": "cat-food",
           "memo": null, "transferAccountID": null, "transferTransactionID": null},
          {"id": null, "amount": -18000, "payeeID": null, "payeeName": null, "categoryID": "cat-home",
           "memo": null, "transferAccountID": null, "transferTransactionID": null}
        ],
        "importID": "imp-grocer"
      },
      "connectionFingerprint": "https://howmuch.tk.sg|plan-1|user-1",
      "capturedAt": 780000100,
      "lastSyncError": "Category not found"
    },
    {
      "id": "6F1C2A3B-0000-4000-8000-000000000003",
      "request": {
        "accountID": "acct-everyday", "date": "2026-09-22", "amount": 5000,
        "payeeName": "Refund", "cleared": "uncleared", "approved": true
      },
      "connectionFingerprint": "https://howmuch.tk.sg|plan-1|user-1",
      "capturedAt": 780000200
    }
  ]
  """

  func testLegacyQueueMovesIntoTheFileInOrderWithItsIdentity() throws {
    defaults.set(Data(Self.legacyPayload.utf8), forKey: OutboxStore.legacyDefaultsKey)
    let legacy = try JSONDecoder().decode([PendingTransaction].self, from: Data(Self.legacyPayload.utf8))

    let commands = try store().load()

    XCTAssertEqual(commands.map(\.id), legacy.map(\.id), "order and identity are kept")
    XCTAssertEqual(commands.map(\.seq), [1, 2, 3])
    XCTAssertEqual(commands.map(\.connectionFingerprint), legacy.map(\.connectionFingerprint))
    XCTAssertEqual(commands.map(\.createdAt), legacy.map(\.capturedAt))
    XCTAssertEqual(
      commands.map(\.state),
      [.queued, .rejected(message: "Category not found", code: nil), .queued],
      "a refused item keeps its refusal and waits for Retry or Discard, as the old queue showed it"
    )
    XCTAssertTrue(commands.allSatisfy(\.attempted), "the old build may have sent any of them")
    XCTAssertFalse(commands.contains(where: \.sentWithClientID), "none went out with an id")
    XCTAssertTrue(commands.allSatisfy { $0.transactionID.hasPrefix("txn_") && $0.transactionID.count == 40 })
    XCTAssertEqual(Set(commands.map(\.transactionID)).count, 3)

    let requests = commands.map { command -> TransactionWriteRequest? in
      if case .create(let request) = command.kind { return request }
      return nil
    }
    XCTAssertEqual(requests[0], legacy[0].request, "a queued capture is sent exactly as it was saved")
    XCTAssertEqual(requests[1], legacy[1].request)
    XCTAssertEqual(requests[1]?.subtransactions.count, 2)
    XCTAssertEqual(
      requests[2]?.importID,
      "6f1c2a3b-0000-4000-8000-000000000003",
      "an item saved before import ids gets the key the old drain would have sent"
    )
    XCTAssertEqual(requests[2]?.subtransactions, [])
    XCTAssertNil(requests.compactMap { $0?.id }.first, "the client id is stamped at send time, not stored")

    XCTAssertNil(defaults.data(forKey: OutboxStore.legacyDefaultsKey), "the old key goes once the file has it")
    XCTAssertEqual(store().peek(), commands)
  }

  // Failure mode: the move's file write fails, the migrated commands are
  // used anyway while the old key stays, a later save (a Discard, say)
  // succeeds without clearing it, and the next launch moves the discarded
  // capture in again. Until the move is on disk the store takes no writes.
  func testAMoveThatCannotBeWrittenRefusesWritesUntilItIs() throws {
    let payload = Data(Self.legacyPayload.utf8)
    defaults.set(payload, forKey: OutboxStore.legacyDefaultsKey)
    struct DiskFull: Error {}
    let gate = WriteGate()
    gate.fails = true
    let outbox = store(writeData: { data, url in
      if gate.fails { throw DiskFull() }
      try data.write(to: url, options: .atomic)
    })

    XCTAssertThrowsError(try outbox.load())
    XCTAssertThrowsError(try outbox.save([]), "a Discard cannot land before the move has")
    XCTAssertEqual(defaults.data(forKey: OutboxStore.legacyDefaultsKey), payload, "nothing is lost")

    gate.fails = false
    let moved = try outbox.load()
    XCTAssertEqual(moved.count, 3)
    XCTAssertNil(defaults.data(forKey: OutboxStore.legacyDefaultsKey))
  }

  // Failure mode: removing a UserDefaults key is not flushed at once, so it
  // can come back after the move reached the file. A capture discarded in
  // between must not be moved in a second time.
  func testADiscardedMovedCaptureIsNotMovedAgain() throws {
    let payload = Data(Self.legacyPayload.utf8)
    defaults.set(payload, forKey: OutboxStore.legacyDefaultsKey)
    let first = store()
    let moved = try first.load()
    try first.save(Array(moved.dropFirst()))
    defaults.set(payload, forKey: OutboxStore.legacyDefaultsKey)

    let again = try store().load()
    XCTAssertEqual(again.map(\.id), moved.dropFirst().map(\.id), "the discarded capture stays discarded")
  }

  func testMigrationThatRanBeforeIsNotRepeated() throws {
    defaults.set(Data(Self.legacyPayload.utf8), forKey: OutboxStore.legacyDefaultsKey)
    let migrated = try store().load()
    // The key comes back, as if its removal had not stuck.
    defaults.set(Data(Self.legacyPayload.utf8), forKey: OutboxStore.legacyDefaultsKey)

    let again = try store().load()
    XCTAssertEqual(again.map(\.id), migrated.map(\.id), "no capture is queued twice")
    XCTAssertEqual(again.map(\.transactionID), migrated.map(\.transactionID))
  }

  func testLegacyItemsQueueAfterCommandsAlreadyInTheFile() throws {
    let first = store()
    _ = try first.load()
    let existing = command(.approve, id: "txn_existing", seq: 7)
    try first.save([existing])
    defaults.set(Data(Self.legacyPayload.utf8), forKey: OutboxStore.legacyDefaultsKey)

    let commands = try store().load()
    XCTAssertEqual(commands.first, existing)
    XCTAssertEqual(commands.map(\.seq), [7, 8, 9, 10])
  }

  func testAnUnreadableLegacyQueueIsSetAsideNotDropped() throws {
    let garbage = Data("not json".utf8)
    defaults.set(garbage, forKey: OutboxStore.legacyDefaultsKey)
    let outbox = store()

    XCTAssertEqual(try outbox.load(), [])
    XCTAssertEqual(outbox.quarantinedFiles().count, 1)
    XCTAssertEqual(try Data(contentsOf: outbox.quarantinedFiles()[0]), garbage)
    XCTAssertNil(defaults.data(forKey: OutboxStore.legacyDefaultsKey))
  }
}
