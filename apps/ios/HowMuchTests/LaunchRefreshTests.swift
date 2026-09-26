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
  private var previousOutbox: Any?

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
    previousOutbox = UserDefaults.standard.object(forKey: OutboxStore.userDefaultsKey)
  }

  override func tearDown() {
    APISettings.useCredentialService(previousCredentialService)
    UserDefaults.standard.set(previousAPISettings, forKey: APISettings.userDefaultsKey)
    UserDefaults.standard.set(previousScopedViewPrefs, forKey: ScopedViewPrefsStore.userDefaultsKey)
    UserDefaults.standard.set(previousOutbox, forKey: OutboxStore.userDefaultsKey)
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

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: temporarySnapshotStore())

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

/// #176: every model built here gets a snapshot store rooted in a fresh
/// temporary directory, so no test reads or writes the real Application
/// Support container (or another test's cache).
private func temporarySnapshotStore() -> SnapshotStore {
  SnapshotStore(
    directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("HowMuchSnapshotTests/\(UUID().uuidString)", isDirectory: true)
  )
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

/// A capture opened on a cold launch calls `refreshAll()` while the launch
/// refresh is still waiting on `GET /v1/plans`. The second call must join the
/// first rather than repeat the whole waterfall, and when plan resolution
/// fails the capture sheet must stop waiting instead of spinning forever.
@MainActor
final class RefreshAllDedupeTests: XCTestCase {
  private var previousCredentialService = ""
  private var previousAPISettings: Any?
  private var previousScopedViewPrefs: Any?
  private var previousOutbox: Any?

  override func setUp() {
    super.setUp()
    previousCredentialService = APISettings.useCredentialService("HowMuch.RefreshAllDedupeTests.\(UUID().uuidString)")
    // `resolvePlanSelection` saves the adopted plan into the app's real
    // `UserDefaults` keys; keep this fixture host out of other tests.
    previousAPISettings = UserDefaults.standard.object(forKey: APISettings.userDefaultsKey)
    previousScopedViewPrefs = UserDefaults.standard.object(forKey: ScopedViewPrefsStore.userDefaultsKey)
    previousOutbox = UserDefaults.standard.object(forKey: OutboxStore.userDefaultsKey)
    XCTAssertTrue(URLProtocol.registerClass(RefreshAllProbeProtocol.self))
    RefreshAllProbeProtocol.reset()
  }

  override func tearDown() {
    RefreshAllProbeProtocol.release()
    URLProtocol.unregisterClass(RefreshAllProbeProtocol.self)
    APISettings.useCredentialService(previousCredentialService)
    UserDefaults.standard.set(previousAPISettings, forKey: APISettings.userDefaultsKey)
    UserDefaults.standard.set(previousScopedViewPrefs, forKey: ScopedViewPrefsStore.userDefaultsKey)
    UserDefaults.standard.set(previousOutbox, forKey: OutboxStore.userDefaultsKey)
    super.tearDown()
  }

  func testSecondRefreshAllForSameConnectionJoinsTheInFlightRun() async {
    RefreshAllProbeProtocol.holdPlans()
    let model = coldModel()

    let launch = Task { await model.refreshAll() }
    let launchAsked = await waitUntil { RefreshAllProbeProtocol.plansRequestCount() == 1 }
    XCTAssertTrue(launchAsked, "the launch refresh must be waiting on GET /v1/plans")
    XCTAssertTrue(model.isRefreshingAll)
    XCTAssertEqual(model.referencePhase, .idle, "the reference phase only moves once the plan resolves")
    XCTAssertEqual(
      CaptureAdmissionGate.referenceWait(referencePhase: model.referencePhase, isRefreshingAll: model.isRefreshingAll),
      .wait,
      "a capture opened now must wait for the launch refresh, not give up"
    )

    var captureFinished = false
    let capture = Task {
      await model.refreshAll(joinInFlight: true)
      captureFinished = true
    }
    // Give the joiner every chance to issue its own request before releasing.
    let secondRequest = await waitUntil(timeoutNanoseconds: 300_000_000) {
      RefreshAllProbeProtocol.plansRequestCount() > 1
    }
    XCTAssertFalse(secondRequest, "a second refreshAll() for the same connection must not fetch the plans again")
    XCTAssertFalse(captureFinished, "the joiner must wait for the launch run, not return early")

    RefreshAllProbeProtocol.release()
    await launch.value
    await capture.value

    XCTAssertTrue(captureFinished)
    XCTAssertEqual(RefreshAllProbeProtocol.plansRequestCount(), 1)
    XCTAssertFalse(model.isRefreshingAll)
    XCTAssertEqual(model.settings.planID, RefreshAllProbeProtocol.solePlanID)

    // Only an in-flight run is shared: a later call is a fresh refresh.
    await model.refreshAll(joinInFlight: true)
    XCTAssertEqual(RefreshAllProbeProtocol.plansRequestCount(), 2)
  }

  /// Joining is opt-in. A caller that has just changed server state (an
  /// import, a settings save) must start its own run even while another is in
  /// flight, and the superseded run must not clear the newer run's record.
  func testRefreshAllWithoutJoinStartsAFreshRunWhileOneIsInFlight() async {
    RefreshAllProbeProtocol.holdPlans()
    let model = coldModel()

    let launch = Task { await model.refreshAll() }
    let launchAsked = await waitUntil { RefreshAllProbeProtocol.plansRequestCount() == 1 }
    XCTAssertTrue(launchAsked, "the launch refresh must be waiting on GET /v1/plans")

    let fresh = Task { await model.refreshAll() }
    let freshAsked = await waitUntil { RefreshAllProbeProtocol.plansRequestCount() == 2 }
    XCTAssertTrue(
      freshAsked,
      "a refreshAll() without joinInFlight must start its own run, not wait on the one already in flight"
    )

    // Answer only the launch run's plans request: it finishes while the fresh
    // run is still parked, so a run that cleared a newer run's record would
    // show up here.
    RefreshAllProbeProtocol.releaseOldest()
    await launch.value
    XCTAssertTrue(
      model.isRefreshingAll,
      "the superseded launch run must not clear the in-flight record the newer run owns"
    )
    XCTAssertEqual(
      RefreshAllProbeProtocol.plansRequestCount(),
      2,
      "the fresh run must still be waiting on its own GET /v1/plans"
    )

    RefreshAllProbeProtocol.release()
    await fresh.value
    XCTAssertFalse(model.isRefreshingAll)
    XCTAssertEqual(RefreshAllProbeProtocol.plansRequestCount(), 2)
  }

  /// The run clears its own in-flight record as its last step, so a caller
  /// resuming from a join never observes a stale record: its next call starts
  /// a fresh run instead of waiting on an already-finished task.
  func testInFlightRecordClearsBeforeTheStartingCallerResumes() async {
    RefreshAllProbeProtocol.holdPlans()
    let model = coldModel()

    let launch = Task { await model.refreshAll() }
    let launchAsked = await waitUntil { RefreshAllProbeProtocol.plansRequestCount() == 1 }
    XCTAssertTrue(launchAsked, "the launch refresh must be waiting on GET /v1/plans")

    // The capture path joins the launch run. It resumes the instant that run
    // finishes, before the starting caller's `await task.value` continuation.
    let capture = Task { @MainActor in
      await model.refreshAll(joinInFlight: true)
      await model.refreshAll(joinInFlight: true)
    }
    // Let the capture call park on the launch run before it is released.
    try? await Task.sleep(nanoseconds: 300_000_000)

    RefreshAllProbeProtocol.release()
    await launch.value
    await capture.value

    XCTAssertEqual(
      RefreshAllProbeProtocol.plansRequestCount(),
      2,
      "once the joined run finished, the next refreshAll() must start a fresh run, not wait on a finished task"
    )
    XCTAssertFalse(model.isRefreshingAll)
  }

  func testFailedPlanResolutionStopsTheCaptureWait() async {
    RefreshAllProbeProtocol.failPlans()
    let model = coldModel()

    await model.refreshAll()

    XCTAssertEqual(RefreshAllProbeProtocol.plansRequestCount(), 1)
    XCTAssertFalse(model.isRefreshingAll)
    XCTAssertEqual(
      model.referencePhase,
      .idle,
      "with no snapshot, a failed plan fetch leaves the reference phase idle"
    )
    XCTAssertEqual(
      CaptureAdmissionGate.referenceWait(referencePhase: model.referencePhase, isRefreshingAll: model.isRefreshingAll),
      .stalled,
      "nothing will ever load the reference data, so the capture sheet must stop waiting"
    )
  }

  private func coldModel() -> AppModel {
    var settings = APISettings()
    settings.baseURLString = RefreshAllProbeProtocol.fixtureBaseURL
    settings.authenticatedUserID = "refresh-all-probe-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = ""
    return AppModel(settings: settings, viewPrefs: ViewPrefs(), snapshotStore: temporarySnapshotStore())
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

private final class RefreshAllProbeLog: @unchecked Sendable {
  static let shared = RefreshAllProbeLog()
  private let lock = NSLock()
  private var plansCount = 0
  private var holdingPlans = false
  private var failingPlans = false
  private var parked: [RefreshAllProbeProtocol] = []

  func reset() {
    lock.lock()
    plansCount = 0
    holdingPlans = false
    failingPlans = false
    parked = []
    lock.unlock()
  }

  func holdPlans() {
    lock.lock()
    holdingPlans = true
    lock.unlock()
  }

  func failPlans() {
    lock.lock()
    failingPlans = true
    lock.unlock()
  }

  func isFailingPlans() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return failingPlans
  }

  /// Counts the request and parks it when plans are being held. Returns
  /// false when the caller should answer immediately.
  func recordPlans(_ request: RefreshAllProbeProtocol) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    plansCount += 1
    guard holdingPlans else {
      return false
    }
    parked.append(request)
    return true
  }

  func release() -> [RefreshAllProbeProtocol] {
    lock.lock()
    defer { lock.unlock() }
    holdingPlans = false
    let released = parked
    parked = []
    return released
  }

  /// Removes and returns the oldest parked request, leaving the rest held
  /// (`holdingPlans` stays set, so later requests keep parking).
  func releaseOldest() -> RefreshAllProbeProtocol? {
    lock.lock()
    defer { lock.unlock() }
    guard !parked.isEmpty else {
      return nil
    }
    return parked.removeFirst()
  }

  func plansRequestCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return plansCount
  }
}

/// Serves a single plan for `GET /v1/plans`, optionally held back or failed,
/// and fails every other request immediately so the waterfall settles fast.
private final class RefreshAllProbeProtocol: URLProtocol {
  static let fixtureHost = "howmuch-refresh-all-probe.test"
  static let fixtureBaseURL = "https://howmuch-refresh-all-probe.test"
  static let solePlanID = "plan-1"

  static func reset() {
    RefreshAllProbeLog.shared.reset()
  }

  static func holdPlans() {
    RefreshAllProbeLog.shared.holdPlans()
  }

  static func failPlans() {
    RefreshAllProbeLog.shared.failPlans()
  }

  /// Answers every parked plans request. Safe to call from the test's thread.
  static func release() {
    for request in RefreshAllProbeLog.shared.release() {
      request.answerPlans()
    }
  }

  /// Answers only the oldest parked plans request, leaving the rest held.
  static func releaseOldest() {
    RefreshAllProbeLog.shared.releaseOldest()?.answerPlans()
  }

  static func plansRequestCount() -> Int {
    RefreshAllProbeLog.shared.plansRequestCount()
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
    guard let url = request.url, url.path.hasSuffix("/v1/plans") else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    if RefreshAllProbeLog.shared.recordPlans(self) {
      return
    }
    answerPlans()
  }

  func answerPlans() {
    guard let url = request.url, !RefreshAllProbeLog.shared.isFailingPlans() else {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let body = Data(#"{"data":{"plans":[{"id":"\#(Self.solePlanID)","name":"Only Plan"}]}}"#.utf8)
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
  private var previousOutbox: Any?

  override func setUp() {
    super.setUp()
    previousCredentialService = APISettings.useCredentialService("HowMuch.ApplySettingsRefreshTests.\(UUID().uuidString)")
    // `applySettings()` calls through to `settings.save()`, which writes the
    // fixture connection straight into `UserDefaults.standard` under the
    // app's real key. Save/restore it so this fixture host never leaks into
    // other tests or the installed app.
    previousAPISettings = UserDefaults.standard.object(forKey: APISettings.userDefaultsKey)
    previousScopedViewPrefs = UserDefaults.standard.object(forKey: ScopedViewPrefsStore.userDefaultsKey)
    previousOutbox = UserDefaults.standard.object(forKey: OutboxStore.userDefaultsKey)
  }

  override func tearDown() {
    APISettings.useCredentialService(previousCredentialService)
    UserDefaults.standard.set(previousAPISettings, forKey: APISettings.userDefaultsKey)
    UserDefaults.standard.set(previousScopedViewPrefs, forKey: ScopedViewPrefsStore.userDefaultsKey)
    UserDefaults.standard.set(previousOutbox, forKey: OutboxStore.userDefaultsKey)
    super.tearDown()
  }

  func testSignInIdentityChangeDoesNotRefreshExplicitly() async {
    XCTAssertTrue(URLProtocol.registerClass(ApplySettingsProbeProtocol.self))
    defer { URLProtocol.unregisterClass(ApplySettingsProbeProtocol.self) }
    ApplySettingsProbeProtocol.reset()

    let model = AppModel(settings: APISettings(), viewPrefs: ViewPrefs(), snapshotStore: temporarySnapshotStore())
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

    let model = AppModel(settings: initial, viewPrefs: ViewPrefs(), snapshotStore: temporarySnapshotStore())

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
  private var previousOutbox: Any?

  override func setUp() {
    super.setUp()
    previousCredentialService = APISettings.useCredentialService("HowMuch.UnapprovedCountLaunchTests.\(UUID().uuidString)")
    previousAPISettings = UserDefaults.standard.object(forKey: APISettings.userDefaultsKey)
    previousScopedViewPrefs = UserDefaults.standard.object(forKey: ScopedViewPrefsStore.userDefaultsKey)
    previousOutbox = UserDefaults.standard.object(forKey: OutboxStore.userDefaultsKey)
  }

  override func tearDown() {
    APISettings.useCredentialService(previousCredentialService)
    UserDefaults.standard.set(previousAPISettings, forKey: APISettings.userDefaultsKey)
    UserDefaults.standard.set(previousScopedViewPrefs, forKey: ScopedViewPrefsStore.userDefaultsKey)
    UserDefaults.standard.set(previousOutbox, forKey: OutboxStore.userDefaultsKey)
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
    // `APISettings()` points at production by default, so the stub must be
    // registered and the fixture host set before anything can fetch.
    XCTAssertTrue(URLProtocol.registerClass(UnapprovedProbeProtocol.self))
    defer { URLProtocol.unregisterClass(UnapprovedProbeProtocol.self) }
    UnapprovedProbeProtocol.reset()
    // Each `openUnapprovedQueue` awaits the walk, so the walk has to finish:
    // the default stub never answers, and this test would sit out URLSession's
    // four-minute timeout instead of asserting on viewer bookkeeping.
    UnapprovedProbeProtocol.answerUnapprovedPageSlowly()

    let model = AppModel(settings: Self.fixtureSettings("queue-siblings"), viewPrefs: ViewPrefs())
    // Viewer tokens are the registers' own scope identities, not fresh UUIDs:
    // a rebuilt view must reclaim the token it had before.
    let first = "account(\"acct-1\")||"
    let second = "unapproved||"

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

    // A rebuilt view reclaims its own token rather than leaking a new one, so
    // one close still empties the set. A fresh UUID per rebuild would strand
    // the old token and re-walk the queue on every later refresh.
    await model.openUnapprovedQueue(viewer: first)
    await model.openUnapprovedQueue(viewer: first)
    model.closeUnapprovedQueue(viewer: first)
    XCTAssertEqual(
      model.unapprovedQueuePhase,
      .idle,
      "reopening under the same identity must not strand a viewer in the set"
    )
  }

  /// One baseline shared by the plan-wide and per-account counters let a scoped
  /// refresh rebaseline the plan-wide one: approve rows in the inbox, open an
  /// account register, and the Accounts "New" tile jumped back up by what had
  /// just been approved. Each scope keeps its own baseline.
  ///
  /// This drives the model mechanism directly -- approve, then refresh the other
  /// scope -- rather than the inbox-open/close UI sequence that surfaces it.
  func testScopedCountRefreshDoesNotRebaselineThePlanWideBadge() async {
    XCTAssertTrue(URLProtocol.registerClass(UnapprovedProbeProtocol.self))
    defer { URLProtocol.unregisterClass(UnapprovedProbeProtocol.self) }
    UnapprovedProbeProtocol.reset()

    var settings = APISettings()
    settings.baseURLString = UnapprovedProbeProtocol.fixtureBaseURL
    settings.authenticatedUserID = "unapproved-baseline-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = UnapprovedProbeProtocol.planID

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs())

    guard let surface = SnapshotSurface(
      root: LaunchProbe(model: model, taskID: { $0.launchRefreshTaskID }),
      size: CGSize(width: 10, height: 10)
    ) else {
      XCTFail("baseline probe requires a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    let counted = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.unapprovedBadgeCount == UnapprovedProbeProtocol.fixtureUnapprovedCount
    }
    XCTAssertTrue(counted, "the plan-wide count must land before this test can move it")

    let rows = (1...3).map { index in
      HowMuch.Transaction.approvalFixture(id: "row-\(index)", accountID: UnapprovedProbeProtocol.fixtureAccountID)
    }
    model.approveEligible(from: rows)

    let expected = UnapprovedProbeProtocol.fixtureUnapprovedCount - rows.count
    let dropped = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.unapprovedBadgeCount == expected
    }
    XCTAssertTrue(dropped, "approving three rows must take three off the plan-wide badge, saw \(model.unapprovedBadgeCount)")

    // Now refresh a *different* scope. This must not touch the plan-wide
    // baseline.
    await model.refreshUnapprovedCount(forAccountID: UnapprovedProbeProtocol.fixtureAccountID)

    XCTAssertEqual(
      model.unapprovedBadgeCount,
      expected,
      "an account-scoped count refresh must not rebaseline the plan-wide badge and undo its local decrement"
    )
  }

  /// A category drill-down narrows the register by something the count endpoint
  /// cannot express, so it must walk the queue rather than stand the plan-wide
  /// number in -- otherwise "Review N new transactions" overstates what is
  /// actually in view.
  func testCategoryNarrowedRegisterLoadsTheQueueInsteadOfThePlanWideCount() async {
    XCTAssertTrue(URLProtocol.registerClass(UnapprovedProbeProtocol.self))
    defer { URLProtocol.unregisterClass(UnapprovedProbeProtocol.self) }
    UnapprovedProbeProtocol.reset()

    var settings = APISettings()
    settings.baseURLString = UnapprovedProbeProtocol.fixtureBaseURL
    settings.authenticatedUserID = "unapproved-category-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = UnapprovedProbeProtocol.planID

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs())

    guard let surface = SnapshotSurface(
      root: RegisterView(scope: .all, categoryID: "cat-1")
        .environment(model)
        .environment(RootChromeState()),
      size: CGSize(width: 390, height: 700)
    ) else {
      XCTFail("category register probe requires a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    let walked = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      UnapprovedProbeProtocol.unapprovedQueueRequests() >= 1
    }
    XCTAssertTrue(walked, "a category-narrowed register must load the queue, since no count matches its scope")
    XCTAssertEqual(
      UnapprovedProbeProtocol.scopedUnapprovedCountRequests(),
      0,
      "a category-narrowed register has no account scope to count"
    )
  }

  /// Rejecting a row awaiting approval takes it off the queue exactly as
  /// approving it does, so it must come off the badge too. It used to be removed
  /// from the rows but not from the counters, so the badge climbed back by the
  /// number of rejections until the next ledger pull.
  func testRejectingAnUnapprovedRowTakesItOffTheBadge() async {
    XCTAssertTrue(URLProtocol.registerClass(UnapprovedProbeProtocol.self))
    defer { URLProtocol.unregisterClass(UnapprovedProbeProtocol.self) }
    UnapprovedProbeProtocol.reset()

    var settings = APISettings()
    settings.baseURLString = UnapprovedProbeProtocol.fixtureBaseURL
    settings.authenticatedUserID = "unapproved-reject-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = UnapprovedProbeProtocol.planID

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs())

    guard let surface = SnapshotSurface(
      root: LaunchProbe(model: model, taskID: { $0.launchRefreshTaskID }),
      size: CGSize(width: 10, height: 10)
    ) else {
      XCTFail("reject probe requires a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    let counted = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.unapprovedBadgeCount == UnapprovedProbeProtocol.fixtureUnapprovedCount
    }
    XCTAssertTrue(counted, "the plan-wide count must land before this test can move it")

    let row = HowMuch.Transaction.approvalFixture(
      id: "rejected-row",
      accountID: UnapprovedProbeProtocol.fixtureAccountID
    )
    try? await model.deleteTransaction(row)

    let expected = UnapprovedProbeProtocol.fixtureUnapprovedCount - 1
    let dropped = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.unapprovedBadgeCount == expected
    }
    XCTAssertTrue(dropped, "rejecting an unapproved row must take one off the badge, saw \(model.unapprovedBadgeCount)")

    // And a refresh of a different scope must not undo that, exactly as for
    // approvals.
    await model.refreshUnapprovedCount(forAccountID: UnapprovedProbeProtocol.fixtureAccountID)
    XCTAssertEqual(
      model.unapprovedBadgeCount,
      expected,
      "a scoped count refresh must not resurrect a rejected row on the plan-wide badge"
    )
  }

  func testApproveToastsAndHidesInboxRowsBeforeBatchReturns() async {
    XCTAssertTrue(URLProtocol.registerClass(UnapprovedProbeProtocol.self))
    defer { URLProtocol.unregisterClass(UnapprovedProbeProtocol.self) }
    UnapprovedProbeProtocol.reset()
    UnapprovedProbeProtocol.hangApprovePatch()
    let rows = (1...2).map { index in
      HowMuch.Transaction.approvalFixture(id: "hang-\(index)", accountID: UnapprovedProbeProtocol.fixtureAccountID)
    }
    UnapprovedProbeProtocol.serveUnapprovedFixtures(rows.map(\.id))

    let model = AppModel(settings: Self.fixtureSettings("approve-hang-success"), viewPrefs: ViewPrefs())
    guard let surface = SnapshotSurface(
      root: LaunchProbe(model: model, taskID: { _ in "static" }),
      size: CGSize(width: 10, height: 10)
    ) else {
      UnapprovedProbeProtocol.releaseApprovePatch()
      XCTFail("hang-approve probe requires a connected UIWindowScene")
      return
    }
    defer {
      UnapprovedProbeProtocol.releaseApprovePatch()
      surface.detach()
    }

    await model.openUnapprovedQueue(viewer: "hang-success")
    let loaded = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.unapprovedQueuePhase == .loaded
        && model.unapprovedTransactions.map(\.id).sorted() == rows.map(\.id).sorted()
    }
    XCTAssertTrue(loaded, "the fixture inbox rows must land before approve can hide them")

    model.approveEligible(from: rows)
    let optimistic = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.lastSaveMessage?.kind == .success
        && model.unapprovedTransactions.isEmpty
        && model.unapprovedBadgeCount == 0
        && model.isApprovalInFlight
    }
    XCTAssertTrue(
      optimistic,
      "approve must toast and drop the inbox before PATCH returns; saw toast \(String(describing: model.lastSaveMessage)), "
        + "rows \(model.unapprovedTransactions.map(\.id)), badge \(model.unapprovedBadgeCount), "
        + "inFlight \(model.isApprovalInFlight)"
    )
    XCTAssertEqual(model.lastSaveMessage?.text, RegisterApproval.approvedToast(rows.count))

    UnapprovedProbeProtocol.releaseApprovePatch()
    let settled = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      !model.isApprovalInFlight
    }
    XCTAssertTrue(settled, "pending must clear after the hung PATCH succeeds")
    XCTAssertEqual(model.unapprovedBadgeCount, 0)
    XCTAssertTrue(model.unapprovedTransactions.isEmpty)
  }

  func testApproveFailureRestoresRowsAndReplacesSuccessToast() async {
    XCTAssertTrue(URLProtocol.registerClass(UnapprovedProbeProtocol.self))
    defer { URLProtocol.unregisterClass(UnapprovedProbeProtocol.self) }
    UnapprovedProbeProtocol.reset()
    UnapprovedProbeProtocol.hangApprovePatch()
    UnapprovedProbeProtocol.failApprovePatch()
    let rows = (1...2).map { index in
      HowMuch.Transaction.approvalFixture(id: "fail-\(index)", accountID: UnapprovedProbeProtocol.fixtureAccountID)
    }
    UnapprovedProbeProtocol.serveUnapprovedFixtures(rows.map(\.id))

    let model = AppModel(settings: Self.fixtureSettings("approve-hang-fail"), viewPrefs: ViewPrefs())
    guard let surface = SnapshotSurface(
      root: LaunchProbe(model: model, taskID: { _ in "static" }),
      size: CGSize(width: 10, height: 10)
    ) else {
      UnapprovedProbeProtocol.releaseApprovePatch()
      XCTFail("hang-approve failure probe requires a connected UIWindowScene")
      return
    }
    defer {
      UnapprovedProbeProtocol.releaseApprovePatch()
      surface.detach()
    }

    await model.openUnapprovedQueue(viewer: "hang-fail")
    let loaded = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.unapprovedQueuePhase == .loaded
        && model.unapprovedTransactions.count == rows.count
    }
    XCTAssertTrue(loaded, "the fixture inbox rows must land before approve can hide them")

    model.approveEligible(from: rows)
    let optimistic = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.lastSaveMessage?.kind == .success
        && model.unapprovedTransactions.isEmpty
        && model.unapprovedBadgeCount == 0
        && model.isApprovalInFlight
    }
    XCTAssertTrue(optimistic, "the success toast and badge drop must land before the hung PATCH fails")

    UnapprovedProbeProtocol.releaseApprovePatch()
    let restored = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.lastSaveMessage?.kind == .failure
        && model.unapprovedTransactions.map(\.id).sorted() == rows.map(\.id).sorted()
        && model.unapprovedBadgeCount == rows.count
        && !model.isApprovalInFlight
    }
    XCTAssertTrue(
      restored,
      "a 0-count PATCH error must restore rows and replace the success toast; saw toast \(String(describing: model.lastSaveMessage)), "
        + "rows \(model.unapprovedTransactions.map(\.id)), badge \(model.unapprovedBadgeCount)"
    )
  }

  /// Closing the flow while its load is in flight must not leave the queue
  /// `.loaded` with nobody showing it -- every later ledger refresh would then
  /// walk the whole queue again.
  func testClosingTheFlowMidLoadLeavesTheQueueIdle() async {
    XCTAssertTrue(URLProtocol.registerClass(UnapprovedProbeProtocol.self))
    defer { URLProtocol.unregisterClass(UnapprovedProbeProtocol.self) }
    UnapprovedProbeProtocol.reset()
    // Let the walk finish, but slowly enough to close the flow underneath it.
    UnapprovedProbeProtocol.answerUnapprovedPageSlowly()

    let model = AppModel(settings: Self.fixtureSettings("queue-midload"), viewPrefs: ViewPrefs())

    guard let surface = SnapshotSurface(
      root: LaunchProbe(model: model, taskID: { _ in "static" }),
      size: CGSize(width: 10, height: 10)
    ) else {
      XCTFail("mid-load probe requires a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    let viewer = "unapproved||"
    // A detached task, not `async let`: both sides hop the main actor, and
    // `async let` would let the close run before the open had even started.
    let opening = Task { await model.openUnapprovedQueue(viewer: viewer) }

    let started = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      model.unapprovedQueuePhase.isLoading
    }
    XCTAssertTrue(started, "the walk must actually be in flight before this test closes the flow")

    model.closeUnapprovedQueue(viewer: viewer)
    XCTAssertEqual(model.unapprovedQueuePhase, .idle, "closing the last viewer releases the queue")

    // Now let the late response land. It must not resurrect the phase.
    await opening.value
    XCTAssertEqual(
      model.unapprovedQueuePhase,
      .idle,
      "a load that finishes after its flow closed must not leave the queue loaded for nobody"
    )
  }

  /// Fixture connection. `APISettings()` defaults to the production host, so
  /// every test here must set the stub's host explicitly -- nothing in this
  /// suite may reach the real API.
  private static func fixtureSettings(_ label: String) -> APISettings {
    var settings = APISettings()
    settings.baseURLString = UnapprovedProbeProtocol.fixtureBaseURL
    settings.authenticatedUserID = "\(label)-\(UUID().uuidString)"
    settings.sessionToken = "token"
    settings.planID = UnapprovedProbeProtocol.planID
    return settings
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
  private var answersUnapprovedPageSlowly = false
  private var hangsApprovePatch = false
  private var failsApprovePatch = false
  private var approvePatchGate: DispatchSemaphore?
  private var unapprovedPageJSON: String?

  func reset() {
    lock.lock()
    counts = [:]
    answersUnapprovedPageSlowly = false
    hangsApprovePatch = false
    failsApprovePatch = false
    unapprovedPageJSON = nil
    let gate = approvePatchGate
    approvePatchGate = nil
    lock.unlock()
    gate?.signal()
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

  func setAnswersUnapprovedPageSlowly(_ value: Bool) {
    lock.lock()
    answersUnapprovedPageSlowly = value
    lock.unlock()
  }

  func answersUnapprovedPageSlowly_() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return answersUnapprovedPageSlowly
  }

  func hangApprovePatch() {
    lock.lock()
    hangsApprovePatch = true
    approvePatchGate = DispatchSemaphore(value: 0)
    lock.unlock()
  }

  func failApprovePatch() {
    lock.lock()
    failsApprovePatch = true
    lock.unlock()
  }

  func releaseApprovePatch() {
    lock.lock()
    let gate = approvePatchGate
    lock.unlock()
    gate?.signal()
  }

  func approvePatchShouldHang() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return hangsApprovePatch
  }

  func waitForApprovePatchRelease() {
    lock.lock()
    let gate = approvePatchGate
    lock.unlock()
    gate?.wait()
  }

  func approvePatchShouldFail() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return failsApprovePatch
  }

  func setUnapprovedPageBody(_ body: String?) {
    lock.lock()
    unapprovedPageJSON = body
    lock.unlock()
  }

  func unapprovedPageBody() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return unapprovedPageJSON
  }
}

/// Answers the launch waterfall's plan list, its first ledger page, and the
/// unapproved count. The unapproved page hangs unless a test serves a fixture
/// body or asks for the slow answer.
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

  /// Lets the unapproved walk finish, slowly, so a test can close the flow
  /// underneath it and check what the late response does.
  static func answerUnapprovedPageSlowly() {
    UnapprovedProbeRequestLog.shared.setAnswersUnapprovedPageSlowly(true)
  }

  static func hangApprovePatch() {
    UnapprovedProbeRequestLog.shared.hangApprovePatch()
  }

  static func failApprovePatch() {
    UnapprovedProbeRequestLog.shared.failApprovePatch()
  }

  static func releaseApprovePatch() {
    UnapprovedProbeRequestLog.shared.releaseApprovePatch()
  }

  static func serveUnapprovedFixtures(_ ids: [String]) {
    let transactions = ids.map { unapprovedFixtureJSON(id: $0) }.joined(separator: ",")
    UnapprovedProbeRequestLog.shared.setUnapprovedPageBody(
      #"{"data":{"transactions":[\#(transactions)],"server_knowledge":1,"has_more":false,"next_offset":null}}"#
    )
  }

  private static func unapprovedFixtureJSON(id: String) -> String {
    #"{"id":"\#(id)","date":"2026-09-01","amount":-1000,"memo":null,"cleared":"uncleared","approved":false,"flag_color":null,"flag_name":null,"account_id":"\#(fixtureAccountID)","account_name":"Fixture Account","payee_id":null,"payee_name":"Fixture Payee","category_id":null,"category_name":null,"transfer_account_id":null,"transfer_transaction_id":null,"parent_transaction_id":null,"matched_transaction_id":null,"import_id":null,"import_payee_name":null,"import_payee_name_original":null,"deleted":false,"subtransactions":[]}"#
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
    if components.path.hasSuffix("/transactions"), request.httpMethod == "PATCH" {
      if UnapprovedProbeRequestLog.shared.approvePatchShouldHang() {
        DispatchQueue.global().async { [weak self] in
          UnapprovedProbeRequestLog.shared.waitForApprovePatchRelease()
          self?.finishApprovePatch(url: url)
        }
        return
      }
      finishApprovePatch(url: url)
      return
    }
    if components.path.hasSuffix("/transactions"), isUnapprovedPage {
      UnapprovedProbeRequestLog.shared.record(Self.queueKey)
      if let body = UnapprovedProbeRequestLog.shared.unapprovedPageBody() {
        send(url: url, body: body)
        return
      }
      guard UnapprovedProbeRequestLog.shared.answersUnapprovedPageSlowly_() else { return }
      let target = url
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.send(
          url: target,
          body: #"{"data":{"transactions":[],"server_knowledge":1,"has_more":false,"next_offset":null}}"#
        )
      }
      return
    }
    // Rejecting a row: answer it so `deleteTransaction` reaches its local
    // bookkeeping instead of throwing at the network.
    if request.httpMethod == "DELETE", components.path.contains("/transactions/") {
      send(url: url, body: Self.deletedTransactionBody)
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

  private func finishApprovePatch(url: URL) {
    if UnapprovedProbeRequestLog.shared.approvePatchShouldFail() {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    send(url: url, body: #"{"data":{"transactions":[],"server_knowledge":2}}"#)
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

  /// A tombstoned row, in the snake_case the shared decoder expects.
  private static let deletedTransactionBody = #"""
  {"data":{"transaction":{"id":"rejected-row","date":"2026-09-01","amount":-1000,"memo":null,  "cleared":"uncleared","approved":false,"flag_color":null,"flag_name":null,"account_id":"acct-1",  "account_name":"Fixture Account","payee_id":null,"payee_name":"Fixture Payee","category_id":null,  "category_name":null,"transfer_account_id":null,"transfer_transaction_id":null,  "parent_transaction_id":null,"matched_transaction_id":null,"import_id":null,  "import_payee_name":null,"import_payee_name_original":null,"deleted":true,"subtransactions":[]},  "server_knowledge":2}}
  """#

  override func stopLoading() {}
}

private extension HowMuch.Transaction {
  /// Minimal unapproved row for approval-path tests. Synthetic values only.
  /// Qualified: this file imports SwiftUI, which has its own `Transaction`.
  static func approvalFixture(id: String, accountID: String) -> HowMuch.Transaction {
    HowMuch.Transaction(
      id: id,
      date: "2026-09-01",
      amount: -1_000,
      memo: nil,
      cleared: .uncleared,
      approved: false,
      flagColor: nil,
      flagName: nil,
      accountID: accountID,
      accountName: "Fixture Account",
      payeeID: nil,
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
}
