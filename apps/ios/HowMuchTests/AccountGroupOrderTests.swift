import XCTest
@testable import HowMuch

/// Regression coverage for the bug where `refreshAccountUsageLast30Days()`
/// snapshotted a "Most used" group's usage ranking into
/// `viewPrefs.accountOrderByGroup[groupID]` -- the same storage the manual
/// drag order reads from (`moveAccounts(in:groupID:fromOffsets:toOffset:)`,
/// via `manualOrderedAccounts`). That clobbered the user's manual order the
/// moment a usage refresh ran while the group happened to be sorted by
/// "Most used". This test builds a manual order, switches the group to
/// "Most used", drives a usage refresh that produces a different ranking,
/// and then switches back to manual -- proving the manual order survived.
@MainActor
final class AccountGroupOrderTests: XCTestCase {
  private var credentialService = ""
  private var defaults: [String: Any] = [:]
  private let keys = [APISettings.userDefaultsKey, ScopedViewPrefsStore.userDefaultsKey, OutboxStore.legacyDefaultsKey]

  override func setUp() {
    super.setUp()
    credentialService = APISettings.useCredentialService("HowMuch.AccountGroupOrderTests.\(UUID())")
    for key in keys {
      defaults[key] = UserDefaults.standard.object(forKey: key)
      UserDefaults.standard.removeObject(forKey: key)
    }
    AccountOrderProtocol.state.reset()
    XCTAssertTrue(URLProtocol.registerClass(AccountOrderProtocol.self))
  }

  override func tearDown() {
    URLProtocol.unregisterClass(AccountOrderProtocol.self)
    APISettings.useCredentialService(credentialService)
    for key in keys { UserDefaults.standard.set(defaults[key], forKey: key) }
    super.tearDown()
  }

  func testUsageRefreshDoesNotClobberTheCashGroupsManualOrder() async throws {
    // b appears 3 times, a twice, c once -- a "Most used" ranking of
    // ["b", "a", "c"], deliberately different from the manual order below.
    AccountOrderProtocol.state.configure(accountCounts: ["b": 3, "a": 2, "c": 1])

    let model = makeModel()
    model.accounts = [
      account("a", name: "Alpha"),
      account("b", name: "Bravo"),
      account("c", name: "Charlie"),
    ]
    model.rebuildLookups()

    // 1. Establish a manual order: c, a, b.
    XCTAssertEqual(model.accounts(inGroupID: "cash").map(\.id), ["a", "b", "c"], "starts alphabetical/default")
    model.moveAccounts(in: model.accounts(inGroupID: "cash"), groupID: "cash", fromOffsets: [2], toOffset: 0)
    XCTAssertEqual(model.accounts(inGroupID: "cash").map(\.id), ["c", "a", "b"])

    // 2. Sort the group by usage and run the refresh that used to snapshot
    // the ranking into the manual-order storage.
    model.setSort(.mostUsedLast30Days, forAccountGroup: "cash")
    await model.refreshAccountUsageLast30Days()

    XCTAssertEqual(model.accountUsagePhase, .loaded)
    XCTAssertEqual(
      model.accounts(inGroupID: "cash").map(\.id), ["b", "a", "c"],
      "the stub's usage counts should now rank the group differently from the manual order"
    )

    // 3. Switching back to manual must restore the order from step 1
    // untouched -- this is what the removed snapshot used to break.
    model.setSort(.manual, forAccountGroup: "cash")
    XCTAssertEqual(
      model.accounts(inGroupID: "cash").map(\.id), ["c", "a", "b"],
      "a usage refresh while sorted by \"Most used\" must not overwrite the manual order"
    )
  }

  private func makeModel() -> AppModel {
    var settings = APISettings()
    settings.baseURLString = "https://account-order.test"
    settings.authenticatedUserID = UUID().uuidString
    settings.sessionToken = "fixture"
    settings.planID = "p"
    return AppModel(outboxStore: .temporary(), settings: settings, viewPrefs: ViewPrefs(), snapshotStore: SnapshotStore(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent("account-order-\(UUID())")
    ))
  }

  private func account(_ id: String, name: String) -> Account {
    Account(
      id: id, name: name, icon: nil, type: "checking", onBudget: true, closed: false,
      balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false
    )
  }
}

/// Minimal in-memory server for the fake `account-order.test` host: a single
/// (`has_more: false`) page of today-dated transactions whose per-account
/// counts are supplied by the test, and an empty 200 for anything else.
private final class AccountOrderState: @unchecked Sendable {
  private let lock = NSLock()
  private var accountCounts: [String: Int] = [:]

  func reset() {
    lock.lock(); defer { lock.unlock() }
    accountCounts = [:]
  }

  func configure(accountCounts: [String: Int]) {
    lock.lock(); defer { lock.unlock() }
    self.accountCounts = accountCounts
  }

  func respond(to request: URLRequest) -> Data {
    lock.lock()
    let counts = accountCounts
    lock.unlock()

    let url = request.url!
    guard url.path.hasSuffix("/transactions") else {
      return try! JSONSerialization.data(withJSONObject: ["data": [String: Any]()])
    }

    let today = Date.now.isoDateString
    var rows: [[String: Any]] = []
    for (accountID, count) in counts {
      for index in 0 ..< count {
        rows.append([
          "id": "\(accountID)-\(index)",
          "date": today,
          "amount": -1000,
          "cleared": "uncleared",
          "approved": true,
          "account_id": accountID,
          "account_name": accountID,
          "deleted": false,
          "subtransactions": [],
        ])
      }
    }
    let payload: [String: Any] = [
      "transactions": rows,
      "server_knowledge": 1,
      "has_more": false,
      "next_offset": NSNull(),
    ]
    return try! JSONSerialization.data(withJSONObject: ["data": payload])
  }
}

private final class AccountOrderProtocol: URLProtocol {
  static let state = AccountOrderState()

  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "account-order.test" }
  override class func canInit(with task: URLSessionTask) -> Bool {
    (task.currentRequest ?? task.originalRequest).map { canInit(with: $0) } ?? false
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let data = Self.state.respond(to: request)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
