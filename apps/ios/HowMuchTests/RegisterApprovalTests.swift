import XCTest
@testable import HowMuch

final class RegisterApprovalTests: XCTestCase {
  func testKeepsOnlyVisibleUnapprovedUndeletedParentIDs() {
    XCTAssertEqual(
      RegisterApproval.eligibleIDs(in: [
        row("a"),
        row("b", approved: true),
        row("c", deleted: true),
        row("d"),
      ]),
      ["a", "d"]
    )
  }

  func testSubmittedPlanApprovesALedgerRowThatIsNotInTheInbox() {
    XCTAssertEqual(RegisterApproval.plan(submitted: [row("ledger-only")])?.ids, ["ledger-only"])
    XCTAssertNil(RegisterApproval.plan(ids: ["ledger-only"], rows: [row("inbox")]))
    XCTAssertNil(RegisterApproval.plan(submitted: [row("already", approved: true)]))
  }

  func testDropsMissingApprovedDeletedAndDuplicateIDs() {
    let plan = RegisterApproval.plan(
      ids: ["d", "a", "d", "missing", "b", "c"],
      rows: [row("a"), row("b", approved: true), row("c", deleted: true), row("d")]
    )
    XCTAssertEqual(plan?.ids, ["d", "a"])
    XCTAssertNil(RegisterApproval.plan(ids: ["b", "missing"], rows: [row("b", approved: true)]))
  }

  func testChunksApprovalPlansAt100IDs() {
    let rows = (0..<101).map { row("txn-\($0)") }
    let plan = RegisterApproval.plan(ids: rows.map(\.id), rows: rows)
    XCTAssertEqual(plan?.chunks.count, 2)
    XCTAssertEqual(plan?.chunks[0].ids.count, 100)
    XCTAssertEqual(plan?.chunks[1].ids, ["txn-100"])
  }

  func testWritesCompactBritishApprovalCopy() {
    XCTAssertEqual(RegisterApproval.approveSelectedLabel(3), "Approve 3 selected")
    XCTAssertEqual(RegisterApproval.approveAllLabel(3), "Approve all (3)")
    XCTAssertEqual(RegisterApproval.approvedToast(1), "1 transaction approved.")
    XCTAssertEqual(RegisterApproval.approvedToast(3), "3 transactions approved.")
    XCTAssertEqual(
      RegisterApproval.interruptedToast(approvedCount: 2, uncertainCount: 1),
      "2 transactions approved. 1 may not have been approved."
    )
  }

  func testBeginAddsPendingAndRejectsEmptyOrAlreadyPendingIDs() {
    XCTAssertNil(RegisterApproval.begin(.empty, ids: []))
    let started = RegisterApproval.begin(.empty, ids: ["a", "b"])
    XCTAssertEqual(started?.pending, ["a", "b"])
    XCTAssertEqual(started?.confirmed.count, 0)
    XCTAssertNotNil(started)
    XCTAssertNil(RegisterApproval.begin(started!, ids: ["b", "c"]))
  }

  func testFinishMovesIDsFromPendingToConfirmed() {
    let started = RegisterApproval.begin(.empty, ids: ["a", "b"])
    XCTAssertNotNil(started)
    let finished = RegisterApproval.finish(started!, ids: ["a"])
    XCTAssertEqual(finished.pending, ["b"])
    XCTAssertEqual(finished.confirmed, ["a"])
    XCTAssertTrue(started!.pending.contains("a"))
    XCTAssertFalse(started!.confirmed.contains("a"))
  }

  func testFailDropsPendingAndConfirmsTheAcceptedPrefix() {
    let started = RegisterApproval.begin(.empty, ids: ["a", "b", "c"])
    XCTAssertNotNil(started)
    let interrupted = RegisterApproval.fail(started!, ids: ["a", "b", "c"], approvedCount: 2)
    XCTAssertTrue(interrupted.pending.isEmpty)
    XCTAssertEqual(interrupted.confirmed, ["a", "b"])
    XCTAssertEqual(RegisterApproval.fail(started!, ids: ["a", "b", "c"], approvedCount: 0).confirmed, [])
  }

  func testLooksApprovedIncludesPending() {
    let started = RegisterApproval.begin(.empty, ids: ["a"])
    XCTAssertNotNil(started)
    XCTAssertTrue(RegisterApproval.looksApproved(row("a"), session: started!))
    XCTAssertFalse(RegisterApproval.looksApproved(row("b"), session: started!))
    XCTAssertEqual(RegisterApproval.resolvedIDs(started!), Set(["a"]))
  }

  func testFailWithoutPrefixStopsLookingApproved() {
    let started = RegisterApproval.begin(.empty, ids: ["a"])
    XCTAssertNotNil(started)
    let failed = RegisterApproval.fail(started!, ids: ["a"], approvedCount: 0)
    XCTAssertFalse(RegisterApproval.looksApproved(row("a"), session: failed))
    XCTAssertTrue(RegisterApproval.resolvedIDs(failed).isEmpty)
  }

  func testEligibleIDsSkipPending() {
    let started = RegisterApproval.begin(.empty, ids: ["a"])
    XCTAssertNotNil(started)
    XCTAssertEqual(RegisterApproval.eligibleIDs(in: [row("a"), row("d")], session: started!), ["d"])
    XCTAssertNil(RegisterApproval.plan(submitted: [row("a")], session: started!))
    XCTAssertEqual(RegisterApproval.plan(ids: ["a", "d"], rows: [row("a"), row("d")], session: started!)?.ids, ["d"])
  }

  func testLooksApprovedUsesTheConfirmedOverlay() {
    let session = RegisterApproval.finish(RegisterApproval.begin(.empty, ids: ["a"])!, ids: ["a"])
    XCTAssertTrue(RegisterApproval.looksApproved(row("a"), session: session))
    XCTAssertFalse(RegisterApproval.looksApproved(row("b"), session: session))
    XCTAssertTrue(RegisterApproval.looksApproved(row("b", approved: true), session: .empty))
  }

  func testEligibleIDsSkipConfirmedOverlayRowsWhenASessionIsPassed() {
    let session = RegisterApproval.finish(RegisterApproval.begin(.empty, ids: ["a"])!, ids: ["a"])
    XCTAssertEqual(RegisterApproval.eligibleIDs(in: [row("a"), row("d")], session: session), ["d"])
    XCTAssertEqual(RegisterApproval.eligibleIDs(in: [row("a"), row("d")]), ["a", "d"])
  }

  func testSecondPlanAfterFinishOmitsConfirmedIDs() {
    let rows = [row("a"), row("d")]
    let finished = RegisterApproval.finish(RegisterApproval.begin(.empty, ids: ["a"])!, ids: ["a"])
    XCTAssertEqual(RegisterApproval.plan(ids: ["a", "d"], rows: rows, session: finished)?.ids, ["d"])
  }

  private func row(_ id: String, approved: Bool = false, deleted: Bool = false) -> RegisterApproval.Row {
    RegisterApproval.Row(id: id, approved: approved, deleted: deleted)
  }
}

@MainActor
final class ApprovalCascadeTests: XCTestCase {
  private var credentialService = ""
  private var defaults: [String: Any] = [:]
  private let keys = [APISettings.userDefaultsKey, ScopedViewPrefsStore.userDefaultsKey, OutboxStore.userDefaultsKey]

  override func setUp() {
    super.setUp()
    credentialService = APISettings.useCredentialService("HowMuch.ApprovalCascadeTests.\(UUID())")
    for key in keys {
      defaults[key] = UserDefaults.standard.object(forKey: key)
      UserDefaults.standard.removeObject(forKey: key)
    }
    ApprovalCascadeProtocol.state.reset()
    XCTAssertTrue(URLProtocol.registerClass(ApprovalCascadeProtocol.self))
  }

  override func tearDown() {
    ApprovalCascadeProtocol.state.releaseAll()
    URLProtocol.unregisterClass(ApprovalCascadeProtocol.self)
    APISettings.useCredentialService(credentialService)
    for key in keys { UserDefaults.standard.set(defaults[key], forKey: key) }
    super.tearDown()
  }

  func testSplitApprovalSurvivesAnOlderQueueResponse() async throws {
    let state = ApprovalCascadeProtocol.state
    state.configure([
      fixture("parent", mirrors: ["mirror"]), fixture("mirror", parent: "parent"), fixture("other"),
    ], approvedIDs: ["parent", "mirror"], requestedID: "parent")
    let model = makeModel()
    await model.refreshLedger(quiet: false)
    await model.openUnapprovedQueue(viewer: "test")
    XCTAssertEqual(Set(model.unapprovedTransactions.map(\.id)), ["parent", "mirror", "other"])

    model.closeUnapprovedQueue(viewer: "test")
    state.holdNext("queue")
    let olderQueue = Task { await model.openUnapprovedQueue(viewer: "test") }
    await eventually { state.isHeld("queue") }
    state.holdNext("ledger")
    model.approveTransaction(try XCTUnwrap(model.transactions.first { $0.id == "parent" }))
    await eventually { !model.isApprovalInFlight && state.isHeld("ledger") }
    XCTAssertEqual(model.unapprovedTransactions.map(\.id), ["other"])
    state.release("queue")
    await olderQueue.value
    XCTAssertEqual(model.unapprovedTransactions.map(\.id), ["other"], "an old queue must not restore approved siblings")
    XCTAssertTrue(try XCTUnwrap(model.transactions.first { $0.id == "mirror" }).approved)
    state.release("ledger")
    await model.refresh(slices: [.ledger])
    await eventually { model.ledgerPhase == .loaded && model.unapprovedQueuePhase == .loaded }
    XCTAssertEqual(model.unapprovedBadgeCount, 1)
  }

  func testMirrorFetchesAbsentParentAndApprovesItsLoadedSibling() async throws {
    let state = ApprovalCascadeProtocol.state
    state.configure([
      fixture("parent", mirrors: ["mirror", "sibling"]),
      fixture("mirror", parent: "parent"), fixture("sibling", parent: "parent"), fixture("other"),
    ], visibleIDs: ["mirror", "sibling", "other"], approvedIDs: ["parent", "mirror", "sibling"], requestedID: "mirror")
    let model = makeModel()
    await model.refreshLedger(quiet: false)
    await model.openUnapprovedQueue(viewer: "test")
    XCTAssertFalse(model.transactions.contains { $0.id == "parent" })
    state.holdNext("ledger")
    model.approveTransaction(try XCTUnwrap(model.transactions.first { $0.id == "mirror" }))
    await eventually { !model.isApprovalInFlight && state.isHeld("ledger") }
    XCTAssertEqual(state.reads(of: "parent"), 1)
    XCTAssertEqual(model.unapprovedTransactions.map(\.id), ["other"])
    XCTAssertTrue(try XCTUnwrap(model.transactions.first { $0.id == "sibling" }).approved)
    state.release("ledger")
    await model.refresh(slices: [.ledger])
    await eventually { model.ledgerPhase == .loaded && model.unapprovedQueuePhase == .loaded }
  }

  func testOrdinaryTransferApprovesBothRows() async throws {
    let state = ApprovalCascadeProtocol.state
    state.configure([
      fixture("source", transfer: "destination"), fixture("destination", transfer: "source"), fixture("other"),
    ], approvedIDs: ["source", "destination"], requestedID: "source")
    let model = makeModel()
    await model.refreshLedger(quiet: false)
    await model.openUnapprovedQueue(viewer: "test")
    state.holdNext("ledger")
    model.approveTransaction(try XCTUnwrap(model.transactions.first { $0.id == "source" }))
    await eventually { !model.isApprovalInFlight && state.isHeld("ledger") }
    XCTAssertEqual(model.unapprovedTransactions.map(\.id), ["other"])
    XCTAssertTrue(try XCTUnwrap(model.transactions.first { $0.id == "destination" }).approved)
    state.release("ledger")
    await model.refresh(slices: [.ledger])
    await eventually { model.ledgerPhase == .loaded && model.unapprovedQueuePhase == .loaded }
  }

  func testAlreadyApprovedCompanionDoesNotReduceCountOnlyBadges() async throws {
    let state = ApprovalCascadeProtocol.state
    state.configure([
      fixture("parent", mirrors: ["approved-mirror"]),
      fixture("approved-mirror", account: "b", parent: "parent", approved: true),
      fixture("other-a"), fixture("other-b", account: "b"),
    ], approvedIDs: ["parent", "approved-mirror"], requestedID: "parent")
    let model = makeModel()
    await model.refreshLedger(quiet: false)
    await model.refreshUnapprovedCount(forAccountID: nil)
    await model.refreshUnapprovedCount(forAccountID: "a")
    await model.refreshUnapprovedCount(forAccountID: "b")
    XCTAssertEqual(model.unapprovedQueuePhase, .idle)
    XCTAssertEqual(model.unapprovedBadgeCount, 3)
    XCTAssertEqual(model.unapprovedBadgeCount(forAccountID: "a"), 2)
    XCTAssertEqual(model.unapprovedBadgeCount(forAccountID: "b"), 1)
    state.holdNext("ledger")
    model.approveTransaction(try XCTUnwrap(model.transactions.first { $0.id == "parent" }))
    await eventually { !model.isApprovalInFlight && state.isHeld("ledger") }
    // Assert before the follow-up count can conceal an incorrect decrement.
    XCTAssertEqual(model.unapprovedBadgeCount, 2)
    XCTAssertEqual(model.unapprovedBadgeCount(forAccountID: "a"), 1)
    XCTAssertEqual(model.unapprovedBadgeCount(forAccountID: "b"), 1)
    state.release("ledger")
    await model.refresh(slices: [.ledger])
    await eventually { model.ledgerPhase == .loaded }
  }

  private func makeModel() -> AppModel {
    var settings = APISettings()
    settings.baseURLString = "https://approval-cascade.test"
    settings.authenticatedUserID = UUID().uuidString
    settings.sessionToken = "fixture"
    settings.planID = "p"
    return AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: SnapshotStore(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent("approval-\(UUID())")
    ))
  }

  private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<300 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "fixture operation did not settle", file: file, line: line)
  }

  private func fixture(
    _ id: String, account: String = "a", parent: String? = nil,
    transfer: String? = nil, mirrors: [String] = [], approved: Bool = false
  ) -> [String: Any] {
    var row: [String: Any] = [
      "id": id, "date": "2026-09-01", "amount": -1000, "cleared": "uncleared",
      "approved": approved, "account_id": account, "account_name": "Fixture", "deleted": false,
      "subtransactions": mirrors.map { mirror in [
        "id": "sub-\(mirror)", "transaction_id": id, "amount": -1000,
        "transfer_account_id": "b", "transfer_transaction_id": mirror, "deleted": false,
      ] as [String: Any] },
    ]
    row["parent_transaction_id"] = parent
    row["transfer_transaction_id"] = transfer
    return row
  }
}

/// Independent in-memory server: the test supplies the server's affected IDs;
/// it does not reuse the client's graph-discovery algorithm for expectations.
private final class ApprovalCascadeState: @unchecked Sendable {
  private let lock = NSLock()
  private var rows: [[String: Any]] = []
  private var visible: Set<String>?
  private var approvedIDs: Set<String> = []
  private var requestedID = ""
  private var holds: Set<String> = []
  private var pending: [String: () -> Void] = [:]
  private var itemReads: [String: Int] = [:]

  func reset() {
    releaseAll()
    lock.lock()
    defer { lock.unlock() }
    rows = []; visible = nil; approvedIDs = []; requestedID = ""; holds = []; itemReads = [:]
  }

  func configure(_ rows: [[String: Any]], visibleIDs: Set<String>? = nil, approvedIDs: Set<String>, requestedID: String) {
    lock.lock()
    defer { lock.unlock() }
    self.rows = rows; visible = visibleIDs; self.approvedIDs = approvedIDs; self.requestedID = requestedID
  }

  func holdNext(_ kind: String) { lock.lock(); holds.insert(kind); lock.unlock() }
  func isHeld(_ kind: String) -> Bool { lock.lock(); defer { lock.unlock() }; return pending[kind] != nil }
  func reads(of id: String) -> Int { lock.lock(); defer { lock.unlock() }; return itemReads[id, default: 0] }
  func release(_ kind: String) {
    lock.lock(); let send = pending.removeValue(forKey: kind); lock.unlock(); send?()
  }
  func releaseAll() {
    lock.lock(); let sends = Array(pending.values); pending = [:]; lock.unlock()
    sends.forEach { $0() }
  }

  func respond(to request: URLRequest, send: @escaping (Data) -> Void) {
    lock.lock()
    let url = request.url!
    let isQueue = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .contains { $0.name == "type" && $0.value == "unapproved" } == true
    var kind = "other"
    let payload: [String: Any]
    if request.httpMethod == "PATCH" {
      for index in rows.indices where approvedIDs.contains(rows[index]["id"] as! String) {
        rows[index]["approved"] = true
      }
      payload = ["transactions": rows.filter { $0["id"] as? String == requestedID }, "server_knowledge": 2]
    } else if url.path.hasSuffix("unapproved_count") {
      let parts = url.pathComponents
      let account = parts.firstIndex(of: "accounts").map { parts[$0 + 1] }
      payload = ["count": rows.filter {
        $0["approved"] as? Bool == false && (account == nil || $0["account_id"] as? String == account)
      }.count, "server_knowledge": 2]
    } else if url.path.hasSuffix("transactions") {
      kind = isQueue ? "queue" : "ledger"
      payload = ["transactions": rows.filter {
        (visible == nil || visible!.contains($0["id"] as! String)) && (!isQueue || $0["approved"] as? Bool == false)
      }, "server_knowledge": 2, "has_more": false, "next_offset": NSNull()]
    } else {
      let id = url.lastPathComponent
      itemReads[id, default: 0] += 1
      payload = ["transaction": rows.first { $0["id"] as? String == id } ?? [:]]
    }
    let data = try! JSONSerialization.data(withJSONObject: ["data": payload])
    if holds.remove(kind) != nil {
      pending[kind] = { send(data) }
      lock.unlock()
    } else {
      lock.unlock()
      send(data)
    }
  }
}

private final class ApprovalCascadeProtocol: URLProtocol {
  static let state = ApprovalCascadeState()
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "approval-cascade.test" }
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
