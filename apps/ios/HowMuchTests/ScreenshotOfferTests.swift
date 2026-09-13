import XCTest
import Photos
@testable import HowMuch

@MainActor
final class ScreenshotOfferTests: XCTestCase {
  private var directory: URL!
  private var store: InboxStore!
  private var defaults: UserDefaults!
  private var suiteName: String!
  private var library: FakeScreenshotLibrary!
  private var controller: ScreenshotOfferController!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    store = InboxStore(container: directory)
    InboxIntentHandoff.store = store
    suiteName = "HowMuch.screenshotOffer.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
    library = FakeScreenshotLibrary()
    controller = ScreenshotOfferController(
      defaults: defaults,
      library: library,
      lineCounter: { _ in 3 }
    )
    CaptureRouter.shared.dropForSignOut()
    while CaptureRouter.shared.blockingSheetCount > 0 {
      CaptureRouter.shared.endBlockingSheet()
    }
  }

  override func tearDown() async throws {
    InboxIntentHandoff.store = .shared
    CaptureRouter.shared.dropForSignOut()
    while CaptureRouter.shared.blockingSheetCount > 0 {
      CaptureRouter.shared.endBlockingSheet()
    }
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }

  func testDefaultOffShowsNoOffer() async {
    XCTAssertFalse(controller.isEnabled)
    library.next = candidate(createdAt: Date.distantFuture)
    await controller.refresh()
    XCTAssertNil(controller.offer)
  }

  func testDeniedAccessKeepsPreferenceOnWithoutAnOffer() async {
    library.authorizationStatus = .denied
    await controller.setEnabled(true)
    XCTAssertTrue(controller.isEnabled)
    XCTAssertTrue(defaults.bool(forKey: ScreenshotOfferController.enabledKey))
    XCTAssertEqual(library.requestCount, 1)
    XCTAssertNil(controller.offer)
  }

  func testApplyEnabledPreferenceWritesDefaultsBeforePhotosReturns() {
    library.authorizationStatus = .denied
    controller.applyEnabledPreference(true)
    XCTAssertTrue(controller.isEnabled)
    XCTAssertTrue(defaults.bool(forKey: ScreenshotOfferController.enabledKey))
    XCTAssertEqual(library.requestCount, 0)
    XCTAssertNil(controller.offer)
  }

  func testNotDeterminedAccessKeepsTheToggleOn() async {
    library.authorizationStatus = .notDetermined
    await controller.setEnabled(true)
    XCTAssertTrue(controller.isEnabled)
    XCTAssertEqual(library.requestCount, 1)
  }

  func testCaptionUsesLineCount() {
    XCTAssertEqual(
      ScreenshotOffer(id: "a", fingerprint: "fp", lineCount: 1, imageData: Data(), filename: "payload.png").caption,
      "Looks like a screenshot · 1 line"
    )
    XCTAssertEqual(
      ScreenshotOffer(id: "a", fingerprint: "fp", lineCount: 3, imageData: Data(), filename: "payload.png").caption,
      "Looks like a screenshot · 3 lines"
    )
  }

  func testConsiderShowsOfferAfterEnable() async {
    await controller.setEnabled(true)
    XCTAssertTrue(controller.isEnabled)
    library.next = candidate(createdAt: Date.distantFuture)
    await controller.refresh()
    XCTAssertEqual(controller.offer?.id, "shot-1")
    XCTAssertEqual(controller.offer?.lineCount, 3)
    XCTAssertEqual(controller.offer?.caption, "Looks like a screenshot · 3 lines")
    XCTAssertTrue(store.claimInboxThrowsNothing())
    XCTAssertNil(CaptureRouter.shared.pending)
  }

  func testOldScreenshotsAreNotOffered() async {
    await controller.setEnabled(true)
    library.next = candidate(createdAt: Date.distantPast)
    await controller.refresh()
    XCTAssertNil(controller.offer)
  }

  func testDismissHidesCardAndDoesNotWriteInbox() async throws {
    await controller.setEnabled(true)
    library.next = candidate(createdAt: Date.distantFuture)
    await controller.refresh()
    XCTAssertEqual(controller.offer?.id, "shot-1")

    controller.dismiss()
    XCTAssertNil(controller.offer)
    XCTAssertTrue(store.claimInboxThrowsNothing())
    XCTAssertNil(CaptureRouter.shared.pending)

    await controller.refresh()
    XCTAssertNil(controller.offer)
  }

  func testReviewEnqueuesDetectedScreenshotAndHidesCard() async throws {
    await controller.setEnabled(true)
    library.next = candidate(createdAt: Date.distantFuture)
    await controller.refresh()

    try controller.review()

    XCTAssertNil(controller.offer)
    XCTAssertEqual(CaptureRouter.shared.pending?.kind, .inbox)
    let claimed = try store.claimInbox()
    XCTAssertEqual(claimed.count, 1)
    XCTAssertEqual(claimed.first?.source, .detectedScreenshot)
    XCTAssertEqual(claimed.first?.kind, .image)
    XCTAssertEqual(claimed.first?.filename, "payload.png")
    XCTAssertEqual(try claimed.first?.payloadData(), candidate().data)
  }

  func testTurningOffHidesOfferAndIgnoresNewShots() async {
    await controller.setEnabled(true)
    library.next = candidate(createdAt: Date.distantFuture)
    await controller.refresh()
    XCTAssertNotNil(controller.offer)

    await controller.setEnabled(false)
    XCTAssertFalse(controller.isEnabled)
    XCTAssertNil(controller.offer)

    await controller.refresh()
    XCTAssertNil(controller.offer)
  }

  func testDismissedScreenshotStaysGoneAfterReload() async {
    await controller.setEnabled(true)
    library.next = candidate(createdAt: Date.distantFuture)
    await controller.refresh()
    controller.dismiss()

    let reloaded = ScreenshotOfferController(
      defaults: defaults,
      library: library,
      lineCounter: { _ in 3 }
    )
    XCTAssertTrue(reloaded.isEnabled)
    await reloaded.refresh()
    XCTAssertNil(reloaded.offer)
  }

  func testDismissStillHidesWhenAssetIDChangesButBytesMatch() async {
    await controller.setEnabled(true)
    let original = candidate(id: "shot-1", createdAt: Date.distantFuture)
    library.next = original
    await controller.refresh()
    XCTAssertEqual(controller.offer?.id, "shot-1")

    controller.dismiss()
    XCTAssertNil(controller.offer)

    library.next = candidate(
      id: "shot-1-rewritten",
      createdAt: original.createdAt,
      data: original.data
    )
    await controller.refresh()
    XCTAssertNil(controller.offer)
  }

  func testDismissedFingerprintSurvivesReloadWhenAssetIDChanges() async {
    await controller.setEnabled(true)
    let original = candidate(id: "shot-1", createdAt: Date.distantFuture)
    library.next = original
    await controller.refresh()
    controller.dismiss()

    library.next = candidate(
      id: "shot-1-rewritten",
      createdAt: original.createdAt,
      data: original.data
    )
    let reloaded = ScreenshotOfferController(
      defaults: defaults,
      library: library,
      lineCounter: { _ in 3 }
    )
    await reloaded.refresh()
    XCTAssertNil(reloaded.offer)
  }

  func testDifferentScreenshotStillOffersAfterDismiss() async {
    await controller.setEnabled(true)
    library.next = candidate(id: "shot-1", createdAt: Date.distantFuture)
    await controller.refresh()
    controller.dismiss()

    library.next = candidate(
      id: "shot-2",
      createdAt: Date.distantFuture,
      data: Data([0xFF, 0xD8, 0xFF, 0xD9])
    )
    await controller.refresh()
    XCTAssertEqual(controller.offer?.id, "shot-2")
  }

  func testLaterScreenshotWithTheSameBytesStillOffers() async {
    await controller.setEnabled(true)
    let bytes = Data([0x89, 0x50, 0x4E, 0x47])
    let firstTaken = Date(timeIntervalSince1970: 1_789_000_000)
    library.next = candidate(id: "shot-1", createdAt: firstTaken, data: bytes)
    await controller.refresh()
    controller.dismiss()

    library.next = candidate(
      id: "shot-2",
      createdAt: firstTaken.addingTimeInterval(1),
      data: bytes
    )
    await controller.refresh()
    XCTAssertEqual(controller.offer?.id, "shot-2")
  }

  func testRefreshClearsOfferWhenScreenshotIsGone() async {
    await controller.setEnabled(true)
    library.next = candidate(createdAt: Date.distantFuture)
    await controller.refresh()
    XCTAssertEqual(controller.offer?.id, "shot-1")

    library.next = nil
    await controller.refresh()
    XCTAssertNil(controller.offer)
  }

  func testReEnableDoesNotRestoreAScreenshotFromBeforeTheNewWindow() async {
    await controller.setEnabled(true)
    library.next = candidate(createdAt: Date.distantFuture)
    await controller.refresh()
    XCTAssertNotNil(controller.offer)

    await controller.setEnabled(false)
    XCTAssertNil(controller.offer)

    library.next = candidate(createdAt: Date.distantPast)
    await controller.setEnabled(true)
    XCTAssertNil(controller.offer)
  }

  func testInFlightConsiderDoesNotResurrectAfterDismiss() async {
    let gate = LineCountGate()
    controller = ScreenshotOfferController(
      defaults: defaults,
      library: library,
      lineCounter: { gate.count($0) }
    )
    await controller.setEnabled(true)
    let shot = candidate(createdAt: Date.distantFuture)
    await controller.consider(shot)
    XCTAssertEqual(controller.offer?.id, "shot-1")

    gate.setDelayNext(true)
    let delayed = Task { await controller.consider(shot) }
    let started = await gate.waitUntilStarted()
    XCTAssertTrue(started, "consider never entered lineCounter")
    controller.dismiss()
    XCTAssertNil(controller.offer)
    gate.allowProceed()
    await delayed.value
    XCTAssertNil(controller.offer)
    XCTAssertTrue(store.claimInboxThrowsNothing())
  }

  func testInFlightConsiderDoesNotPublishAfterDisable() async {
    let gate = LineCountGate()
    controller = ScreenshotOfferController(
      defaults: defaults,
      library: library,
      lineCounter: { gate.count($0) }
    )
    await controller.setEnabled(true)
    gate.setDelayNext(true)
    let delayed = Task { await controller.consider(candidate(createdAt: Date.distantFuture)) }
    let started = await gate.waitUntilStarted()
    XCTAssertTrue(started, "consider never entered lineCounter")
    await controller.setEnabled(false)
    gate.allowProceed()
    await delayed.value
    XCTAssertFalse(controller.isEnabled)
    XCTAssertNil(controller.offer)
  }

  private func candidate(
    id: String = "shot-1",
    createdAt: Date = Date.distantFuture,
    data: Data = Data([0x89, 0x50, 0x4E, 0x47])
  ) -> ScreenshotCandidate {
    ScreenshotCandidate(
      id: id,
      data: data,
      filename: "payload.png",
      createdAt: createdAt
    )
  }
}

@MainActor
final class FakeScreenshotLibrary: ScreenshotLibrary {
  var authorizationStatus: PHAuthorizationStatus = .authorized
  var observesPhotoLibrary = false
  var next: ScreenshotCandidate?
  var requestCount = 0

  func requestAccess() async -> PHAuthorizationStatus {
    requestCount += 1
    return authorizationStatus
  }

  func latestScreenshot(createdAfter: Date, excluding: Set<String>) async -> ScreenshotCandidate? {
    guard let next, next.createdAt >= createdAfter, !excluding.contains(next.id) else {
      return nil
    }
    return next
  }
}

final class LineCountGate: @unchecked Sendable {
  private let lock = NSLock()
  private var delayNext = false
  private var didStart = false
  private let proceed = DispatchSemaphore(value: 0)

  func setDelayNext(_ value: Bool) {
    lock.lock()
    delayNext = value
    if value {
      didStart = false
    }
    lock.unlock()
  }

  func waitUntilStarted(timeout: TimeInterval = 2) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !hasStarted {
      if Date() > deadline {
        return false
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  func allowProceed() {
    proceed.signal()
  }

  func count(_ data: Data) -> Int {
    lock.lock()
    let delay = delayNext
    lock.unlock()
    if delay {
      lock.lock()
      didStart = true
      lock.unlock()
      proceed.wait()
    }
    return 3
  }

  private var hasStarted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didStart
  }
}

private extension InboxStore {
  func claimInboxThrowsNothing() -> Bool {
    (try? claimInbox())?.isEmpty ?? true
  }
}
