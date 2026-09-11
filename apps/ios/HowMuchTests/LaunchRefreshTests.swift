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

    let settled = await surface.waitUntil(timeoutNanoseconds: 4_000_000_000) {
      self.isTerminal(model.referencePhase)
        && self.isTerminal(model.ledgerPhase)
        && self.isTerminal(model.scheduledTransactionsPhase)
        && self.isTerminal(model.reportsPhase)
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
