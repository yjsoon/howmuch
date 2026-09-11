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

  override func setUp() {
    super.setUp()
    previousCredentialService = APISettings.useCredentialService("HowMuch.LaunchRefreshTests.\(UUID().uuidString)")
  }

  override func tearDown() {
    APISettings.useCredentialService(previousCredentialService)
    super.tearDown()
  }

  /// The actual fix: keying the launch task on `launchFingerprint` must not
  /// restart when `resolvePlanSelection()` adopts the sole plan mid-refresh.
  func testLaunchTaskKeyedOnLaunchFingerprintRunsPlansOnce() async {
    let count = await runLaunchProbe { $0.settings.launchFingerprint }
    XCTAssertEqual(
      count,
      1,
      "keying the launch task on launchFingerprint must issue exactly one GET /v1/plans on first sign-in"
    )
  }

  /// Negative control: proves this harness actually detects the regression it
  /// guards against. Keying the task on the pre-fix `connectionFingerprint`
  /// (which includes `planID`) must still reproduce the double run.
  func testLaunchTaskKeyedOnConnectionFingerprintStillRunsPlansTwice() async {
    let count = await runLaunchProbe { $0.settings.connectionFingerprint }
    XCTAssertEqual(
      count,
      2,
      "connectionFingerprint changing mid-refresh must still restart the pre-fix task, or this harness cannot detect the regression it guards against"
    )
  }

  /// Runs a minimal SwiftUI view that reproduces `HowMuchApp`'s
  /// `.task(id:) { await model.refreshAll() }`, keyed on whichever
  /// fingerprint `taskID` selects, against a fresh sign-in (empty `planID`,
  /// one plan available on the server). Returns how many times the stub
  /// observed `GET /v1/plans`.
  private func runLaunchProbe(taskID: @escaping (AppModel) -> String) async -> Int {
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
      model.referencePhase != .loading
        && model.ledgerPhase != .loading
        && model.scheduledTransactionsPhase != .loading
        && model.reportsPhase != .loading
    }
    XCTAssertTrue(settled, "the launch refresh(es) must settle before counting requests")

    let count = LaunchProbeProtocol.plansRequestCount()
    XCTAssertGreaterThanOrEqual(
      count,
      1,
      "GET /v1/plans must be recorded by LaunchProbeProtocol; if 0, URLSession.shared may have copied its protocol list before registerClass and this stub never ran"
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

  override func setUp() {
    super.setUp()
    previousCredentialService = APISettings.useCredentialService("HowMuch.ApplySettingsRefreshTests.\(UUID().uuidString)")
  }

  override func tearDown() {
    APISettings.useCredentialService(previousCredentialService)
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
