import SwiftUI
import XCTest
@testable import HowMuch

/// Local mode end to end: `APIClient` → `LocalEngine` → the bundled backend →
/// SQLite, with the same decoding and error mapping as a server.
final class LocalModeTests: XCTestCase {
  private var directory: URL!
  private var previousEngine: LocalEngine?
  private var defaults: UserDefaults!
  private var suiteName = ""

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appending(path: "LocalModeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    previousEngine = LocalEngine.useShared(LocalEngine(databaseURL: directory.appending(path: "howmuch.sqlite")))
    suiteName = "HowMuch.LocalModeTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDownWithError() throws {
    LocalEngine.useShared(previousEngine)
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  func testAccountTransactionAndBalanceRoundTrip() async throws {
    let settings = APISettings.local(in: defaults)
    let client = APIClient(settings: settings)
    let planID = settings.planID

    let plans = try await client.fetchPlans()
    XCTAssertEqual(plans.map(\.id), [planID])

    let created = try await client.createAccount(
      planID: planID,
      name: "Everyday",
      type: "checking",
      balance: 100_000,
      icon: nil,
      onBudget: true
    )
    let listed = try await client.fetchAccounts(planID: planID)
    XCTAssertEqual(listed.map(\.id), [created.id])
    XCTAssertEqual(listed.first?.balance, 100_000)

    let transaction = try await client.createTransaction(
      planID: planID,
      request: TransactionWriteRequest(
        accountID: created.id,
        date: Date.now.isoDateString,
        amount: -12_340,
        payeeID: nil,
        payeeName: "Coffee",
        categoryID: nil,
        memo: nil,
        cleared: .cleared,
        approved: true,
        flagColor: nil,
        subtransactions: []
      )
    )
    XCTAssertEqual(transaction.amount, -12_340)

    let after = try await client.fetchAccounts(planID: planID)
    XCTAssertEqual(after.first?.balance, 87_660)
    let reference = try await client.fetchReferenceData(planID: planID)
    XCTAssertEqual(reference.accounts.map(\.id), [created.id])
    XCTAssertNil(reference.accountPreferences)
  }

  func testServerErrorsMapAsTheyDoOverTheNetwork() async throws {
    let settings = APISettings.local(in: defaults)
    let client = APIClient(settings: settings)

    do {
      _ = try await client.fetchTransaction(planID: settings.planID, transactionID: "missing")
      XCTFail("Expected a not-found error")
    } catch APIClientError.server(let message) {
      XCTAssertFalse(message.isEmpty)
    }
  }

  private func starterNames(_ client: APIClient, planID: String) async throws -> [String] {
    try await client.fetchCategories(planID: planID)
      .filter { !$0.isQuiet }
      .flatMap { $0.categories.map(\.name) }
      .sorted()
  }

  func testStartingLocallySeedsCategoriesOnlyOnce() async throws {
    let settings = APISettings.local(in: defaults)
    let client = APIClient(settings: settings)
    try await LocalEngine.shared.prepare(config: settings.localEngineConfig)

    try await StarterCategories.seedIfNeeded(client: client, planID: settings.planID, defaults: defaults)
    try await StarterCategories.seedIfNeeded(client: client, planID: settings.planID, defaults: defaults)

    let names = try await starterNames(client, planID: settings.planID)
    XCTAssertEqual(names, StarterCategories.groups.flatMap(\.categories).sorted())
    XCTAssertTrue(defaults.bool(forKey: StarterCategories.completionKey(planID: settings.planID)))
  }

  /// A seed cut short resumes: the next run creates only what is missing, and
  /// a starter id that already exists counts as done rather than failing.
  func testAnInterruptedSeedCompletesWithoutDuplicates() async throws {
    let settings = APISettings.local(in: defaults)
    let client = APIClient(settings: settings)
    let planID = settings.planID
    try await LocalEngine.shared.prepare(config: settings.localEngineConfig)
    let steps = StarterCategories.steps(planID: planID)
    guard case .group(let groupID, let groupName) = steps[0],
          case .category(let categoryID, _, _) = steps[1]
    else {
      return XCTFail("The starter set must open with a group and its first category")
    }
    // The first run got this far, and the user renamed that category since.
    try await client.createCategoryGroup(planID: planID, id: groupID, name: groupName)
    try await client.createCategory(planID: planID, id: categoryID, groupID: groupID, name: "Food")

    try await StarterCategories.seedIfNeeded(client: client, planID: planID, defaults: defaults)

    var expected = StarterCategories.groups.flatMap(\.categories)
    expected[0] = "Food"
    let names = try await starterNames(client, planID: planID)
    XCTAssertEqual(names, expected.sorted())
    let groupCount = try await client.fetchCategories(planID: planID).filter { !$0.isQuiet }.count
    XCTAssertEqual(groupCount, StarterCategories.groups.count)
  }

  func testACompletedSeedNeverRecreatesACategoryTheUserRemoved() async throws {
    let settings = APISettings.local(in: defaults)
    let client = APIClient(settings: settings)
    let planID = settings.planID
    try await LocalEngine.shared.prepare(config: settings.localEngineConfig)
    try await StarterCategories.seedIfNeeded(client: client, planID: planID, defaults: defaults)
    guard case .category(let categoryID, _, _) = StarterCategories.steps(planID: planID)[1] else {
      return XCTFail("Expected a starter category")
    }
    let deleted = try await LocalEngine.shared.handle(
      config: settings.localEngineConfig,
      method: "DELETE",
      path: "/v1/plans/\(planID)/categories/\(categoryID)",
      query: nil,
      headers: ["Authorization": "Bearer \(settings.sessionToken)"],
      body: nil
    )
    XCTAssertTrue((200 ..< 300).contains(deleted.status), "delete answered \(deleted.status)")
    let afterDelete = try await starterNames(client, planID: planID)
    XCTAssertFalse(afterDelete.contains("Groceries"))

    try await StarterCategories.seedIfNeeded(client: client, planID: planID, defaults: defaults)
    // Even with the completion flag lost, the deleted id is not reused.
    defaults.removeObject(forKey: StarterCategories.completionKey(planID: planID))
    try await StarterCategories.seedIfNeeded(client: client, planID: planID, defaults: defaults)

    let afterReseed = try await starterNames(client, planID: planID)
    XCTAssertFalse(afterReseed.contains("Groceries"))
    XCTAssertEqual(afterReseed.count, StarterCategories.groups.flatMap(\.categories).count - 1)
  }

  func testStarterIDsAreStableAndValidEntityIDs() {
    let steps = StarterCategories.steps(planID: "plan_0f8fad5b-d9cb-469f-a165-70867728950e")
    XCTAssertEqual(steps, StarterCategories.steps(planID: "plan_0f8fad5b-d9cb-469f-a165-70867728950e"))
    let ids = steps.map { step -> String in
      switch step {
      case .group(let id, _), .category(let id, _, _): return id
      }
    }
    XCTAssertEqual(Set(ids).count, ids.count)
    let pattern = /^[A-Za-z0-9._:-]{1,128}$/
    XCTAssertTrue(ids.allSatisfy { $0.wholeMatch(of: pattern) != nil }, "\(ids)")
    XCTAssertEqual(StarterCategories.slug("Phone and internet"), "phone-and-internet")
  }

  /// Local mode has no session to revoke: an expiry notice must not sign it out.
  @MainActor
  func testLocalModeIgnoresAuthenticationExpiry() async throws {
    let settings = APISettings.local(in: defaults)
    let model = AppModel(
      settings: settings,
      viewPrefs: ViewPrefs(),
      snapshotStore: SnapshotStore(directory: directory.appending(path: "snapshots", directoryHint: .isDirectory)),
      hasSavedSettings: true
    )

    NotificationCenter.default.post(name: .howMuchAuthenticationExpired, object: settings.sessionToken)
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertTrue(model.settings.isAuthenticated)
    XCTAssertEqual(model.settings.authenticatedUserID, APISettings.localUserID)
    XCTAssertFalse(model.isShowingSettings)
  }

  /// Lost preferences with the ledger still on disk: starting again adopts
  /// that plan rather than creating an empty one beside it.
  func testLostPlanIDAdoptsThePlanAlreadyOnTheDevice() async throws {
    let first = APISettings.local(in: defaults)
    try await LocalEngine.shared.prepare(config: first.localEngineConfig)
    defaults.removeObject(forKey: APISettings.localPlanIDKey)

    let live = try await LocalEngine.shared.livePlanIDs()
    let recovered = APISettings.local(in: defaults, livePlanIDs: live)

    XCTAssertEqual(live, [first.planID])
    XCTAssertEqual(recovered.planID, first.planID)
  }

  func testNoDatabaseMeansNoLivePlans() async throws {
    let engine = LocalEngine(databaseURL: directory.appending(path: "absent.sqlite"))
    let live = try await engine.livePlanIDs()
    XCTAssertEqual(live, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "absent.sqlite").path))
  }

  /// Opt-in visual check of the local-mode screens, driven through the real
  /// `AppModel` and engine. Set `TEST_RUNNER_HOWMUCH_LOCAL_SCREENSHOT_DIR` to
  /// a host directory to write PNGs there.
  @MainActor
  func testLocalModeScreensRender() async throws {
    guard let outputPath = ProcessInfo.processInfo.environment["HOWMUCH_LOCAL_SCREENSHOT_DIR"] else {
      throw XCTSkip("Set HOWMUCH_LOCAL_SCREENSHOT_DIR to write local-mode screenshots.")
    }
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    let size = CGSize(width: 402, height: 874)
    let settings = APISettings.local(in: defaults)
    let client = APIClient(settings: settings)
    try await LocalEngine.shared.prepare(config: settings.localEngineConfig)
    try await StarterCategories.seedIfNeeded(client: client, planID: settings.planID, defaults: defaults)
    let model = AppModel(
      settings: settings,
      viewPrefs: ViewPrefs(),
      snapshotStore: SnapshotStore(directory: directory.appending(path: "snapshots", directoryHint: .isDirectory)),
      hasSavedSettings: false
    )

    func write(_ view: some View, named name: String, waitingFor text: [String]) async throws {
      let surface = try XCTUnwrap(SnapshotSurface(root: view.environment(model).environment(RootChromeState()), size: size))
      defer { surface.detach() }
      let capture = await surface.captureUntilOCR(contains: text, timeoutNanoseconds: 3_000_000_000)
      try XCTUnwrap(capture.image.pngData()).write(to: output.appending(path: "\(name).png"))
    }

    try await write(WelcomeView(), named: "local-1-welcome", waitingFor: ["Start on this"])

    let account = try await client.createAccount(planID: settings.planID, name: "Everyday", type: "checking", balance: 250_000, icon: nil, onBudget: true)
    let groceries = try await client.fetchCategories(planID: settings.planID)
      .flatMap(\.categories).first { $0.name == "Groceries" }
    _ = try await client.createTransaction(
      planID: settings.planID,
      request: TransactionWriteRequest(
        accountID: account.id, date: Date.now.isoDateString, amount: -42_500, payeeID: nil,
        payeeName: "FairPrice", categoryID: groceries?.id, memo: nil, cleared: .cleared,
        approved: true, flagColor: nil, subtransactions: []
      )
    )
    let started = Date.now
    await model.refreshAll()
    XCTAssertLessThan(Date.now.timeIntervalSince(started), 2, "A local refresh must not wait on a network")
    XCTAssertEqual(model.accounts.first?.balance, 207_500)

    try await write(NavigationStack { AccountsView(usesSplit: false) }, named: "local-2-accounts", waitingFor: ["Everyday"])
    try await write(NavigationStack { RegisterView(scope: .account(account.id)) }, named: "local-3-register", waitingFor: ["FairPrice"])
    try await write(SettingsView(settings: settings) { _ in }, named: "local-4-settings", waitingFor: ["Connect to a server"])
  }

  func testLaunchRoute() {
    XCTAssertEqual(LaunchRoute.resolve(hasSavedSettings: false, isAuthenticated: false), .welcome)
    XCTAssertEqual(LaunchRoute.resolve(hasSavedSettings: true, isAuthenticated: false), .connection)
    XCTAssertEqual(LaunchRoute.resolve(hasSavedSettings: true, isAuthenticated: true), .main)
    XCTAssertEqual(LaunchRoute.resolve(hasSavedSettings: false, isAuthenticated: true), .main)
  }
}
