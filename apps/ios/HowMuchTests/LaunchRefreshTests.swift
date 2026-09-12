import SwiftUI
import UIKit
import XCTest
@testable import HowMuch

/// Regression tests for #178: `resolvePlanSelection()` writes `settings.planID`
/// from inside the first `refreshAll()` of a launch (adopting a sole plan).
/// Keying the launch `.task` on `connectionFingerprint` (which includes
/// `planID`) made that write change the task's identity mid-flight, so
/// SwiftUI cancelled the in-flight refresh and restarted it, running the
/// entire launch waterfall twice. The fix keys the task on `launchFingerprint`
/// (endpoint + signed-in user, no plan id) instead.
@MainActor
final class LaunchRefreshTests: XCTestCase {
  private var previousCredentialService = ""
  private var previousAPISettings: Any?
  private var previousScopedViewPrefs: Any?

  override func setUp() {
    super.setUp()
    previousCredentialService = APISettings.useCredentialService("HowMuch.LaunchRefreshTests.\(UUID().uuidString)")
    // `applySettings`/`resolvePlanSelection` call through to `settings.save()`,
    // which writes the fixture connection straight into `UserDefaults.standard`
    // under the app's real keys. Save/restore those so this fixture host never
    // leaks into other tests (e.g. CaptureOriginTests, IPadLayoutTests, which
    // construct `AppModel()` from `APISettings.load()`) or the installed app.
    previousAPISettings = UserDefaults.standard.object(forKey: APISettings.userDefaultsKey)
    previousScopedViewPrefs = UserDefaults.standard.object(forKey: ScopedViewPrefsStore.userDefaultsKey)
  }

  override func tearDown() {
    APISettings.useCredentialService(previousCredentialService)
    UserDefaults.standard.set(previousAPISettings, forKey: APISettings.userDefaultsKey)
    UserDefaults.standard.set(previousScopedViewPrefs, forKey: ScopedViewPrefsStore.userDefaultsKey)
    super.tearDown()
  }

  /// The actual fix: keying the launch task on `launchRefreshTaskID`
  /// (`launchFingerprint`) must not restart when `resolvePlanSelection()`
  /// adopts the sole plan mid-refresh.
  func testLaunchTaskKeyedOnLaunchFingerprintRunsPlansOnce() async {
    let count = await runLaunchProbe(expectedRequestCount: 1) { $0.launchRefreshTaskID }
    XCTAssertEqual(
      count,
      1,
      "keying the launch task on launchRefreshTaskID must issue exactly one GET /v1/plans on first sign-in"
    )
  }

  /// Negative control: proves this harness actually detects the regression it
  /// guards against. Keying the task on the pre-fix `connectionFingerprint`
  /// (which includes `planID`) must still reproduce the double run.
  func testLaunchTaskKeyedOnConnectionFingerprintStillRunsPlansTwice() async {
    let count = await runLaunchProbe(expectedRequestCount: 2) { $0.settings.connectionFingerprint }
    XCTAssertEqual(
      count,
      2,
      "connectionFingerprint changing mid-refresh must still restart the pre-fix task, or this harness cannot detect the regression it guards against"
    )
  }

  /// True once a launch phase has reached a terminal state. Right after
  /// `resolvePlanSelection()` adopts the sole plan, `clearConnectionOwnedState()`
  /// resets every phase to `.idle` before the individual `refresh*()` calls
  /// set them to `.loading`; treating `.idle` as "settled" would let the
  /// wait below return during that brief gap, before the requests it's
  /// supposed to count have actually happened.
  private func isTerminal(_ phase: LoadPhase) -> Bool {
    phase != .idle && phase != .loading
  }

  /// Runs a minimal SwiftUI view that reproduces `HowMuchApp`'s
  /// `.task(id:) { await model.refreshAll() }`, keyed on whichever
  /// fingerprint `taskID` selects, against a fresh sign-in (empty `planID`,
  /// one plan available on the server). Returns how many times the stub
  /// observed `GET /v1/plans`.
  private func runLaunchProbe(
    expectedRequestCount: Int,
    taskID: @escaping (AppModel) -> String
  ) async -> Int {
    XCTAssertTrue(URLProtocol.registerClass(LaunchProbeProtocol.self))
    defer { URLProtocol.unregisterClass(LaunchProbeProtocol.self) }
    LaunchProbeProtocol.reset()

    var settings = APISettings()
    settings.baseURLString = LaunchProbeProtocol.fixtureBaseURL
    settings.authenticatedUserID = "launch-probe-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = "" // fresh sign-in: no saved plan yet

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs())

    guard let surface = SnapshotSurface(
      root: LaunchProbe(model: model, taskID: taskID),
      size: CGSize(width: 10, height: 10)
    ) else {
      XCTFail("launch probe requires a connected UIWindowScene")
      return -1
    }
    defer { surface.detach() }

    let resolvedPlan = await surface.waitUntil(timeoutNanoseconds: 3_000_000_000) {
      model.settings.planID == LaunchProbeProtocol.solePlanID
    }
    XCTAssertTrue(
      resolvedPlan,
      "resolvePlanSelection() must adopt the sole plan mid-refresh, or this test isn't exercising the fingerprint-mutation bug"
    )

    // `reportsPhase` is deliberately absent: since #180 the launch refresh
    // does not fetch the four reports, so that phase stays `.idle` for the
    // whole of this probe and would never settle.
    let settled = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      self.isTerminal(model.referencePhase)
        && self.isTerminal(model.ledgerPhase)
        && self.isTerminal(model.scheduledTransactionsPhase)
    }
    XCTAssertTrue(settled, "the launch refresh(es) must settle before counting requests")

    // Wait on the exact observable this test asserts on, not just on the
    // model's own phases: a restarted run's `/v1/plans` fetch can still be
    // in flight (or its response still being dispatched back to the main
    // actor) even after the first run's phases above have gone terminal.
    let reachedExpectedCount = await surface.waitUntil(timeoutNanoseconds: 1_000_000_000) {
      LaunchProbeProtocol.plansRequestCount() >= expectedRequestCount
    }
    let count = LaunchProbeProtocol.plansRequestCount()
    XCTAssertTrue(
      reachedExpectedCount,
      "expected at least \(expectedRequestCount) GET /v1/plans requests but only saw \(count); "
        + "if 0, URLSession.shared may have copied its protocol list before registerClass and this stub never ran"
    )
    return count
  }
}

private struct LaunchProbe: View {
  @Bindable var model: AppModel
  let taskID: (AppModel) -> String

  var body: some View {
    Color.clear
      .task(id: taskID(model)) {
        await model.refreshAll()
      }
  }
}

private final class LaunchProbeRequestLog: @unchecked Sendable {
  static let shared = LaunchProbeRequestLog()
  private let lock = NSLock()
  private var plansCount = 0

  func reset() {
    lock.lock()
    plansCount = 0
    lock.unlock()
  }

  func recordPlansRequest() {
    lock.lock()
    plansCount += 1
    lock.unlock()
  }

  func plansCount_() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return plansCount
  }
}

/// Serves a single plan for `GET /v1/plans` (so `resolvePlanSelection()`
/// adopts it and writes `settings.planID` mid-refresh) and fails every other
/// request immediately, so the rest of the launch waterfall settles fast
/// without ever reaching the real network.
private final class LaunchProbeProtocol: URLProtocol {
  static let fixtureHost = "howmuch-launch-probe.test"
  static let fixtureBaseURL = "https://howmuch-launch-probe.test"
  static let solePlanID = "plan-1"

  static func reset() {
    LaunchProbeRequestLog.shared.reset()
  }

  static func plansRequestCount() -> Int {
    LaunchProbeRequestLog.shared.plansCount_()
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
    guard url.path.hasSuffix("/v1/plans") else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    LaunchProbeRequestLog.shared.recordPlansRequest()
    let body = Data(
      #"{"data":{"plans":[{"id":"\#(Self.solePlanID)","name":"Only Plan"}]}}"#.utf8
    )
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
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Regression tests for the `applySettings()` half of #178: an interactive
/// sign-in (a new `launchFingerprint`) is already followed by
/// `HowMuchApp`'s launch `.task` restarting and calling `refreshAll()` on its
/// own, so `applySettings()` must not call it a second time. A plan-only
/// change (same `launchFingerprint`) does not trigger a task restart, so
/// `applySettings()` must keep calling `refreshAll()` explicitly for that
/// case, preserving existing plan-switching behaviour.
@MainActor
final class ApplySettingsRefreshTests: XCTestCase {
  private var previousCredentialService = ""
  private var previousAPISettings: Any?
  private var previousScopedViewPrefs: Any?

  override func setUp() {
    super.setUp()
    previousCredentialService = APISettings.useCredentialService("HowMuch.ApplySettingsRefreshTests.\(UUID().uuidString)")
    // `applySettings()` calls through to `settings.save()`, which writes the
    // fixture connection straight into `UserDefaults.standard` under the
    // app's real key. Save/restore it so this fixture host never leaks into
    // other tests or the installed app.
    previousAPISettings = UserDefaults.standard.object(forKey: APISettings.userDefaultsKey)
    previousScopedViewPrefs = UserDefaults.standard.object(forKey: ScopedViewPrefsStore.userDefaultsKey)
  }

  override func tearDown() {
    APISettings.useCredentialService(previousCredentialService)
    UserDefaults.standard.set(previousAPISettings, forKey: APISettings.userDefaultsKey)
    UserDefaults.standard.set(previousScopedViewPrefs, forKey: ScopedViewPrefsStore.userDefaultsKey)
    super.tearDown()
  }

  func testSignInIdentityChangeDoesNotRefreshExplicitly() async {
    XCTAssertTrue(URLProtocol.registerClass(ApplySettingsProbeProtocol.self))
    defer { URLProtocol.unregisterClass(ApplySettingsProbeProtocol.self) }
    ApplySettingsProbeProtocol.reset()

    let model = AppModel(settings: APISettings(), viewPrefs: ViewPrefs())
    XCTAssertNotEqual(model.settings.launchFingerprint, "")

    var signedIn = APISettings()
    signedIn.baseURLString = ApplySettingsProbeProtocol.fixtureBaseURL
    signedIn.authenticatedUserID = "user-1"
    signedIn.sessionToken = "token"
    signedIn.planID = ApplySettingsProbeProtocol.planA

    XCTAssertNotEqual(signedIn.launchFingerprint, model.settings.launchFingerprint)

    await model.applySettings(signedIn)

    XCTAssertEqual(model.settings.planID, ApplySettingsProbeProtocol.planA)
    XCTAssertEqual(
      ApplySettingsProbeProtocol.requestCount(),
      0,
      "a launch-identity change must be left to HowMuchApp's task restart, not refreshed again by applySettings itself"
    )
  }

  func testPlanOnlyChangeStillRefreshesExplicitly() async {
    XCTAssertTrue(URLProtocol.registerClass(ApplySettingsProbeProtocol.self))
    defer { URLProtocol.unregisterClass(ApplySettingsProbeProtocol.self) }
    ApplySettingsProbeProtocol.reset()

    var initial = APISettings()
    initial.baseURLString = ApplySettingsProbeProtocol.fixtureBaseURL
    initial.authenticatedUserID = "user-1"
    initial.sessionToken = "token"
    initial.planID = ApplySettingsProbeProtocol.planA

    let model = AppModel(settings: initial, viewPrefs: ViewPrefs())

    var switched = initial
    switched.planID = ApplySettingsProbeProtocol.planB
    XCTAssertEqual(switched.launchFingerprint, initial.launchFingerprint)

    await model.applySettings(switched)

    XCTAssertEqual(model.settings.planID, ApplySettingsProbeProtocol.planB)
    XCTAssertGreaterThan(
      ApplySettingsProbeProtocol.requestCount(),
      0,
      "switching plans (same launchFingerprint) must still trigger an explicit refreshAll(), since no task restart will happen"
    )
  }
}

private final class ApplySettingsProbeLog: @unchecked Sendable {
  static let shared = ApplySettingsProbeLog()
  private let lock = NSLock()
  private var count = 0

  func reset() {
    lock.lock()
    count = 0
    lock.unlock()
  }

  func record() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  func total() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// Fails every request immediately after recording it, so `refreshAll()`
/// settles quickly regardless of whether it was invoked; these tests only
/// need to know whether a request was attempted, not whether it succeeded.
private final class ApplySettingsProbeProtocol: URLProtocol {
  static let fixtureHost = "howmuch-apply-settings-probe.test"
  static let fixtureBaseURL = "https://howmuch-apply-settings-probe.test"
  static let planA = "plan-a"
  static let planB = "plan-b"

  static func reset() {
    ApplySettingsProbeLog.shared.reset()
  }

  static func requestCount() -> Int {
    ApplySettingsProbeLog.shared.total()
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
    ApplySettingsProbeLog.shared.record()
    if request.url?.path.hasSuffix("/v1/plans") == true {
      let body = Data(
        #"{"data":{"plans":[{"id":"\#(Self.planA)","name":"A"},{"id":"\#(Self.planB)","name":"B"}]}}"#.utf8
      )
      if let url = request.url,
         let response = HTTPURLResponse(
           url: url,
           statusCode: 200,
           httpVersion: "HTTP/1.1",
           headerFields: ["Content-Type": "application/json"]
         ) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
        return
      }
    }
    client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
  }

  override func stopLoading() {}
}

/// Regression tests for #181: launch used to await a full serial walk of the
/// unapproved queue before `ledgerPhase` became `.loaded`, so a large backlog
/// turned launch into N seconds of an unusable register. The register must now
/// be ready when its first ledger page lands, the badge must come from the
/// cheap `unapproved_count` endpoint, and the queue rows must be fetched only
/// when the approval flow is opened.
@MainActor
final class UnapprovedCountLaunchTests: XCTestCase {
  private var previousCredentialService = ""
  private var previousAPISettings: Any?
  private var previousScopedViewPrefs: Any?

  override func setUp() {
    super.setUp()
    previousCredentialService = APISettings.useCredentialService("HowMuch.UnapprovedCountLaunchTests.\(UUID().uuidString)")
    previousAPISettings = UserDefaults.standard.object(forKey: APISettings.userDefaultsKey)
    previousScopedViewPrefs = UserDefaults.standard.object(forKey: ScopedViewPrefsStore.userDefaultsKey)
  }

  override func tearDown() {
    APISettings.useCredentialService(previousCredentialService)
    UserDefaults.standard.set(previousAPISettings, forKey: APISettings.userDefaultsKey)
    UserDefaults.standard.set(previousScopedViewPrefs, forKey: ScopedViewPrefsStore.userDefaultsKey)
    super.tearDown()
  }

  /// The fix itself. The stub never answers a `type=unapproved` page, so if the
  /// launch path still awaited that walk, `ledgerPhase` could never reach
  /// `.loaded` and this test would time out.
  func testRegisterLoadsOnFirstLedgerPageWhileTheUnapprovedScanIsPending() async {
    let probe = await runUnapprovedProbe()
    XCTAssertEqual(
      probe.ledgerPhase,
      .loaded,
      "the register must be loaded once its first ledger page lands, even with the unapproved queue unanswered"
    )
    XCTAssertEqual(
      probe.unapprovedQueueRequests,
      0,
      "launch must not walk the unapproved queue; its rows are for the approval flow to fetch"
    )
  }

  /// The badge's new source: one bounded count request, not a page walk.
  func testLaunchIssuesExactlyOneUnapprovedCountRequest() async {
    let probe = await runUnapprovedProbe()
    XCTAssertEqual(
      probe.unapprovedCountRequests,
      1,
      "launch must ask for the unapproved count exactly once"
    )
    XCTAssertEqual(
      probe.badgeCount,
      UnapprovedProbeProtocol.fixtureUnapprovedCount,
      "the New badge must show the number the count endpoint reported"
    )
  }

  /// A register narrowed to one account must show that account's own number.
  /// Before the queue is loaded it has no rows to count, so it has to ask the
  /// account-scoped count endpoint -- otherwise a focused register reads zero
  /// and `showsRegisterFilterMenu` hides the way into the approval flow.
  func testNarrowedRegisterCountsItsOwnAccountFromTheScopedEndpoint() async {
    XCTAssertTrue(URLProtocol.registerClass(UnapprovedProbeProtocol.self))
    defer { URLProtocol.unregisterClass(UnapprovedProbeProtocol.self) }
    UnapprovedProbeProtocol.reset()

    var settings = APISettings()
    settings.baseURLString = UnapprovedProbeProtocol.fixtureBaseURL
    settings.authenticatedUserID = "unapproved-scope-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = UnapprovedProbeProtocol.planID

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs())

    guard let surface = SnapshotSurface(
      root: RegisterView(scope: .account(UnapprovedProbeProtocol.fixtureAccountID))
        .environment(model)
        .environment(RootChromeState()),
      size: CGSize(width: 390, height: 700)
    ) else {
      XCTFail("scoped register probe requires a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    // Wait on the model, not on the stub: the stub records a request as it
    // starts serving it, so waiting on the request count alone would race the
    // response back to the main actor.
    let counted = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.unapprovedBadgeCount(forAccountID: UnapprovedProbeProtocol.fixtureAccountID)
        == UnapprovedProbeProtocol.fixtureAccountUnapprovedCount
    }
    XCTAssertTrue(
      counted,
      "the narrowed register must show its own account's count (\(UnapprovedProbeProtocol.fixtureAccountUnapprovedCount)), "
        + "not the plan-wide one; saw \(model.unapprovedBadgeCount(forAccountID: UnapprovedProbeProtocol.fixtureAccountID)) "
        + "after \(UnapprovedProbeProtocol.scopedUnapprovedCountRequests()) scoped count request(s)"
    )
    XCTAssertGreaterThanOrEqual(
      UnapprovedProbeProtocol.scopedUnapprovedCountRequests(),
      1,
      "a register scoped to one account must request that account's unapproved count"
    )
    XCTAssertNotEqual(
      UnapprovedProbeProtocol.fixtureAccountUnapprovedCount,
      UnapprovedProbeProtocol.fixtureUnapprovedCount,
      "the fixture must use different plan and account counts, or this test cannot tell them apart"
    )
    XCTAssertEqual(
      UnapprovedProbeProtocol.unapprovedQueueRequests(),
      0,
      "a narrowed register must get its number from the count endpoint, not by walking the queue"
    )
  }

  /// Two registers can show the approval flow at once on iPad. One closing must
  /// not release the rows the other is still displaying.
  func testClosingOneApprovalFlowKeepsTheQueueForItsSibling() async {
    let model = AppModel(settings: APISettings(), viewPrefs: ViewPrefs())
    let first = UUID()
    let second = UUID()

    await model.openUnapprovedQueue(viewer: first)
    await model.openUnapprovedQueue(viewer: second)

    model.closeUnapprovedQueue(viewer: first)
    XCTAssertNotEqual(
      model.unapprovedQueuePhase,
      .idle,
      "one pane closing must not reset the queue while a sibling still shows it"
    )

    model.closeUnapprovedQueue(viewer: second)
    XCTAssertEqual(
      model.unapprovedQueuePhase,
      .idle,
      "the queue is released once no register is showing it"
    )
  }

  private struct UnapprovedProbeResult {
    let ledgerPhase: LoadPhase
    let badgeCount: Int
    let unapprovedCountRequests: Int
    let unapprovedQueueRequests: Int
  }

  private func runUnapprovedProbe() async -> UnapprovedProbeResult {
    XCTAssertTrue(URLProtocol.registerClass(UnapprovedProbeProtocol.self))
    defer { URLProtocol.unregisterClass(UnapprovedProbeProtocol.self) }
    UnapprovedProbeProtocol.reset()

    var settings = APISettings()
    settings.baseURLString = UnapprovedProbeProtocol.fixtureBaseURL
    settings.authenticatedUserID = "unapproved-probe-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = UnapprovedProbeProtocol.planID

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs())

    guard let surface = SnapshotSurface(
      root: LaunchProbe(model: model, taskID: { $0.launchRefreshTaskID }),
      size: CGSize(width: 10, height: 10)
    ) else {
      XCTFail("unapproved probe requires a connected UIWindowScene")
      return UnapprovedProbeResult(ledgerPhase: .idle, badgeCount: -1, unapprovedCountRequests: -1, unapprovedQueueRequests: -1)
    }
    defer { surface.detach() }

    let loaded = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.ledgerPhase == .loaded
    }
    XCTAssertTrue(loaded, "the register must reach .loaded without the unapproved queue ever being answered")

    // The count is fired alongside the horizon fill, so wait on the observable
    // itself rather than assuming it has landed by the time the page has.
    _ = await surface.waitUntil(timeoutNanoseconds: 2_000_000_000) {
      UnapprovedProbeProtocol.unapprovedCountRequests() >= 1 && model.unapprovedBadgeCount > 0
    }

    return UnapprovedProbeResult(
      ledgerPhase: model.ledgerPhase,
      badgeCount: model.unapprovedBadgeCount,
      unapprovedCountRequests: UnapprovedProbeProtocol.unapprovedCountRequests(),
      unapprovedQueueRequests: UnapprovedProbeProtocol.unapprovedQueueRequests()
    )
  }
}

private final class UnapprovedProbeRequestLog: @unchecked Sendable {
  static let shared = UnapprovedProbeRequestLog()
  private let lock = NSLock()
  private var counts: [String: Int] = [:]

  func reset() {
    lock.lock()
    counts = [:]
    lock.unlock()
  }

  func record(_ key: String) {
    lock.lock()
    counts[key, default: 0] += 1
    lock.unlock()
  }

  func count(_ key: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return counts[key] ?? 0
  }
}

/// Answers the launch waterfall's plan list, its first ledger page and the
/// unapproved count, and deliberately *never* answers a `type=unapproved`
/// page. A launch that still gated the register on that walk would hang here.
private final class UnapprovedProbeProtocol: URLProtocol {
  static let fixtureHost = "howmuch-unapproved-probe.test"
  static let fixtureBaseURL = "https://howmuch-unapproved-probe.test"
  static let planID = "plan-1"
  static let fixtureUnapprovedCount = 7
  static let fixtureAccountID = "acct-1"
  static let fixtureAccountUnapprovedCount = 3

  private static let countKey = "count"
  private static let scopedCountKey = "scopedCount"
  private static let queueKey = "queue"

  static func reset() {
    UnapprovedProbeRequestLog.shared.reset()
  }

  static func unapprovedCountRequests() -> Int {
    UnapprovedProbeRequestLog.shared.count(countKey)
  }

  static func unapprovedQueueRequests() -> Int {
    UnapprovedProbeRequestLog.shared.count(queueKey)
  }

  static func scopedUnapprovedCountRequests() -> Int {
    UnapprovedProbeRequestLog.shared.count(scopedCountKey)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.lowercased() == fixtureHost
  }

  override class func canInit(with task: URLSessionTask) -> Bool {
    guard let request = task.currentRequest ?? task.originalRequest else { return false }
    return canInit(with: request)
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let isUnapprovedPage = (components.queryItems ?? []).contains { $0.name == "type" && $0.value == "unapproved" }

    if components.path.hasSuffix("/transactions/unapproved_count") {
      // The account-scoped path reports only that account's rows, so a narrowed
      // register can be checked against a different number from the plan's.
      let scoped = components.path.contains("/accounts/\(Self.fixtureAccountID)/")
      UnapprovedProbeRequestLog.shared.record(scoped ? Self.scopedCountKey : Self.countKey)
      let count = scoped ? Self.fixtureAccountUnapprovedCount : Self.fixtureUnapprovedCount
      send(url: url, body: #"{"data":{"count":\#(count),"server_knowledge":1}}"#)
      return
    }
    if components.path.hasSuffix("/transactions"), isUnapprovedPage {
      // Recorded and then left hanging on purpose: the register must not be
      // waiting on this.
      UnapprovedProbeRequestLog.shared.record(Self.queueKey)
      return
    }
    if components.path.hasSuffix("/transactions") {
      send(url: url, body: #"{"data":{"transactions":[],"server_knowledge":1,"has_more":false,"next_offset":null}}"#)
      return
    }
    if components.path.hasSuffix("/v1/plans") {
      send(url: url, body: #"{"data":{"plans":[{"id":"\#(Self.planID)","name":"Only Plan"}]}}"#)
      return
    }
    // Everything else settles fast so the rest of the waterfall cannot stall
    // the wait above.
    client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
  }

  private func send(url: URL, body: String) {
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
}
