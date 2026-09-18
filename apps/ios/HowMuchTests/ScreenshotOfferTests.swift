import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import HowMuch

@MainActor
final class ScreenshotOfferTests: XCTestCase {
  private var directory: URL!
  private var store: InboxStore!
  private var defaults: UserDefaults!
  private var suiteName: String!
  private var clipboard: FakeClipboard!
  private var controller: ScreenshotOfferController!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    store = InboxStore(container: directory)
    InboxIntentHandoff.store = store
    suiteName = "HowMuch.clipboard.tests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    clipboard = FakeClipboard()
    controller = makeController()
    CaptureRouter.shared.dropForSignOut()
    while CaptureRouter.shared.blockingSheetCount > 0 { CaptureRouter.shared.endBlockingSheet() }
  }

  override func tearDown() async throws {
    controller.applyEnabledPreference(false)
    InboxIntentHandoff.store = .shared
    CaptureRouter.shared.dropForSignOut()
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeController(epoch: String? = nil) -> ScreenshotOfferController {
    ScreenshotOfferController(defaults: defaults, clipboard: clipboard, epoch: epoch, lineCounter: { _ in 3 })
  }

  func testNewBootReoffersDifferentImageAtSameRevision() async {
    let first = makeController(epoch: "boot-A")
    await first.setEnabled(true)
    first.dismiss()
    let sameBoot = makeController(epoch: "boot-A")
    await sameBoot.refresh()
    XCTAssertNil(sameBoot.offer)
    XCTAssertEqual(clipboard.reads, 1)

    clipboard.data = Data([9, 8, 7])
    let newBoot = makeController(epoch: "boot-B")
    await newBoot.refresh()
    XCTAssertEqual(newBoot.offer?.imageData, Data([9, 8, 7]))
    XCTAssertEqual(clipboard.reads, 2)
  }

  func testNewBootReoffersIdenticalImageAtSameRevision() async {
    let first = makeController(epoch: "boot-A")
    await first.setEnabled(true)
    first.dismiss()
    let newBoot = makeController(epoch: "boot-B")
    await newBoot.refresh()
    XCTAssertEqual(newBoot.offer?.imageData, clipboard.data)
    XCTAssertEqual(clipboard.reads, 2)
    XCTAssertFalse(newBoot.offer?.id.contains("boot-B") ?? true)
  }

  func testNewBootInvalidatesDeniedReadSuppression() async {
    clipboard.data = nil
    let first = makeController(epoch: "boot-A")
    await first.setEnabled(true)
    await makeController(epoch: "boot-A").refresh()
    XCTAssertEqual(clipboard.reads, 1)

    clipboard.data = Data([4, 5, 6])
    let newBoot = makeController(epoch: "boot-B")
    await newBoot.refresh()
    XCTAssertEqual(newBoot.offer?.imageData, Data([4, 5, 6]))
    XCTAssertEqual(clipboard.reads, 2)
  }

  func testMissingEpochInvalidatesLegacySuppressionAndDismissal() async {
    await controller.setEnabled(true)
    controller.dismiss()
    defaults.removeObject(forKey: ScreenshotOfferController.epochKey)
    let migrated = makeController()
    await migrated.refresh()
    XCTAssertEqual(migrated.offer?.imageData, clipboard.data)
    XCTAssertEqual(clipboard.reads, 2)
  }

  func testRuntimeEpochProbeAndUnavailableFallback() async {
    let boot = ClipboardOfferEpoch.readBootSessionUUID()
    XCTAssertTrue(ClipboardOfferEpoch.current == ClipboardOfferEpoch.resolve(boot))
    let fallback = ClipboardOfferEpoch.resolve(nil)
    XCTAssertTrue(fallback == ClipboardOfferEpoch.resolve(nil), "fallback must be process-stable")
    XCTAssertTrue(fallback.hasPrefix("process:"))
    XCTAssertTrue(UUID(uuidString: String(fallback.dropFirst("process:".count))) != nil)

    let oldProcess = makeController(epoch: "process:previous")
    await oldProcess.setEnabled(true)
    oldProcess.dismiss()
    let currentProcess = makeController(epoch: fallback)
    await currentProcess.refresh()
    XCTAssertEqual(currentProcess.offer?.imageData, clipboard.data)
    currentProcess.dismiss()
    let sameProcess = makeController(epoch: ClipboardOfferEpoch.resolve(nil))
    await sameProcess.refresh()
    XCTAssertNil(sameProcess.offer)
    XCTAssertEqual(clipboard.reads, 2)
    // Report capability, never the local boot or process identifier itself.
    print("Clipboard epoch: kern.bootsessionuuid available=\(boot != nil); unavailable fallback verified")
  }

  func testLegacyPhotosConsentDoesNotEnableClipboard() async {
    defaults.set(true, forKey: "HowMuch.screenshotOffer.enabled")
    let reloaded = makeController()
    XCTAssertFalse(reloaded.isEnabled, "Photos consent is not clipboard consent")
    reloaded.startIfNeeded()
    await reloaded.refresh()
    XCTAssertEqual(clipboard.reads, 0)
    XCTAssertEqual(clipboard.availabilityChecks, 0)
  }

  func testDefaultOffAndDisabledNeverReadPayload() async {
    await controller.refresh()
    XCTAssertEqual(clipboard.reads, 0)
    XCTAssertEqual(clipboard.availabilityChecks, 0)
    await controller.setEnabled(true)
    XCTAssertNotNil(controller.offer)
    await controller.setEnabled(false)
    clipboard.changeCount += 1
    await controller.refresh()
    controller.startIfNeeded()
    await Task.yield()
    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertNil(controller.offer)
  }

  func testDeniedReadIsNotRetriedAcrossRefreshReenableOrReload() async {
    clipboard.data = nil // hasImages is true, but iOS refuses the payload.
    await controller.setEnabled(true)
    await controller.refresh()
    await controller.setEnabled(false)
    await controller.setEnabled(true)
    await makeController().refresh()
    XCTAssertTrue(controller.isEnabled)
    XCTAssertNil(controller.offer)
    XCTAssertEqual(clipboard.reads, 1)
    clipboard.changeCount += 1
    clipboard.data = Data([2])
    await controller.refresh()
    XCTAssertEqual(controller.offer?.imageData, Data([2]))
    XCTAssertEqual(clipboard.reads, 2)
  }

  func testUnchangedDoesNotReadOrOCRAgain() async {
    let counter = LineCountGate()
    controller = ScreenshotOfferController(defaults: defaults, clipboard: clipboard, lineCounter: { counter.count($0) })
    await controller.setEnabled(true)
    let offer = controller.offer
    await controller.refresh()
    controller.startIfNeeded()
    await Task.yield()
    XCTAssertEqual(controller.offer, offer)
    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertEqual(counter.calls, 1)
    XCTAssertEqual(offer?.caption, "Clipboard image · 3 lines")
    XCTAssertEqual(ScreenshotOffer(id: "x", lineCount: 1, imageData: Data(), filename: "x").caption,
      "Clipboard image · 1 line")
  }

  func testDismissPersistsButANewCopyOfSameBytesIsOffered() async throws {
    await controller.setEnabled(true)
    let firstID = controller.offer?.id
    controller.dismiss()
    await controller.refresh()
    let reloaded = makeController()
    await reloaded.refresh()
    XCTAssertNil(reloaded.offer)
    XCTAssertEqual(clipboard.reads, 1)
    XCTAssertTrue(try store.claimInbox().isEmpty)
    clipboard.changeCount += 1
    await reloaded.refresh()
    XCTAssertNotNil(reloaded.offer)
    XCTAssertNotEqual(reloaded.offer?.id, firstID)
  }

  func testReviewKeepsInboxSourceCompatibilityAndSuppressesUnchangedCopy() async throws {
    await controller.setEnabled(true)
    try controller.review()
    XCTAssertNil(controller.offer)
    XCTAssertEqual(CaptureRouter.shared.pending?.kind, .inbox)
    let claimed = try store.claimInbox()
    XCTAssertEqual(claimed.count, 1)
    XCTAssertEqual(claimed.first?.source, .detectedScreenshot)
    XCTAssertEqual(claimed.first?.filename, "payload.png")
    XCTAssertEqual(try claimed.first?.payloadData(), clipboard.data)
    await makeController().refresh()
    XCTAssertEqual(clipboard.reads, 1)
  }

  func testReviewRejectsOfferChangedBeforeNotificationArrives() async throws {
    await controller.setEnabled(true)
    clipboard.changeCount += 1
    clipboard.data = Data([99])
    try controller.review()
    XCTAssertNil(controller.offer)
    XCTAssertTrue(try store.claimInbox().isEmpty)
    await controller.refresh()
    XCTAssertEqual(controller.offer?.imageData, Data([99]))
  }

  func testTextEmptyAndOversizedReplacementsClearOfferWithoutFallback() async {
    await controller.setEnabled(true)
    XCTAssertNotNil(controller.offer)
    clipboard.changeCount += 1
    clipboard.hasImages = false
    await controller.refresh()
    XCTAssertNil(controller.offer)
    XCTAssertEqual(clipboard.reads, 1)
    clipboard.changeCount += 1
    clipboard.hasImages = true
    clipboard.data = Data()
    await controller.refresh()
    XCTAssertNil(controller.offer)
    clipboard.changeCount += 1
    clipboard.data = Data(repeating: 0, count: InboxStore.maxPayloadBytes + 1)
    await controller.refresh()
    XCTAssertNil(controller.offer)
  }

  func testStaleOCRCannotPublishAfterTextReplacementOrDisable() async {
    for disable in [false, true] {
      let gate = LineCountGate()
      clipboard.changeCount += 1
      clipboard.hasImages = true
      controller = ScreenshotOfferController(defaults: defaults, clipboard: clipboard, lineCounter: { gate.count($0) })
      gate.delayNext = true
      let pending = Task { await controller.setEnabled(true) }
      let started = await gate.waitUntilStarted()
      XCTAssertTrue(started)
      if disable {
        controller.applyEnabledPreference(false)
      } else {
        clipboard.changeCount += 1
        clipboard.hasImages = false
        await controller.refresh()
      }
      gate.allowProceed()
      await pending.value
      XCTAssertNil(controller.offer)
    }
  }

  func testNewImageWinsOverOldOCRAndDismissDoesNotResurrectIt() async {
    let gate = LineCountGate()
    controller = ScreenshotOfferController(defaults: defaults, clipboard: clipboard, lineCounter: { gate.count($0) })
    gate.delayNext = true
    let old = Task { await controller.setEnabled(true) }
    let started = await gate.waitUntilStarted()
    XCTAssertTrue(started)
    clipboard.changeCount += 1
    clipboard.data = Data([7, 8])
    await controller.refresh()
    XCTAssertEqual(controller.offer?.imageData, Data([7, 8]))
    controller.dismiss()
    gate.allowProceed()
    await old.value
    XCTAssertNil(controller.offer)
  }

  func testQueuedEnableRefreshCannotUndoNewerDisable() async {
    controller.applyEnabledPreference(true)
    let queued = Task { await controller.refresh() }
    controller.applyEnabledPreference(false)
    await queued.value
    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(clipboard.reads, 0)
    await controller.setEnabled(true)
    XCTAssertNotNil(controller.offer)
  }

  func testOCRRevalidatesEvenWithoutAChangeNotification() async {
    let gate = LineCountGate()
    controller = ScreenshotOfferController(defaults: defaults, clipboard: clipboard, lineCounter: { gate.count($0) })
    gate.delayNext = true
    let pending = Task { await controller.setEnabled(true) }
    let started = await gate.waitUntilStarted()
    XCTAssertTrue(started)
    clipboard.changeCount += 1
    clipboard.hasImages = false
    gate.allowProceed()
    await pending.value
    XCTAssertNil(controller.offer)
  }

  func testDisableThenReenableDuringOCRStillOffersCurrentImage() async {
    let gate = LineCountGate()
    controller = ScreenshotOfferController(defaults: defaults, clipboard: clipboard, lineCounter: { gate.count($0) })
    gate.delayNext = true
    let pending = Task { await controller.setEnabled(true) }
    let started = await gate.waitUntilStarted()
    XCTAssertTrue(started)
    controller.applyEnabledPreference(false)
    await controller.setEnabled(true)
    XCTAssertEqual(controller.offer?.imageData, clipboard.data)
    controller.dismiss()
    gate.allowProceed()
    await pending.value
    XCTAssertNil(controller.offer)
  }

  func testRealPasteboardUsesOnlyFirstItemAndReplacesImages() async throws {
    let board = UIPasteboard.withUniqueName()
    defer { UIPasteboard.remove(withName: board.name) }
    let source = PasteboardImageSource(pasteboard: board)
    let red = image(.red)
    let blue = image(.blue)
    board.items = [[UTType.utf8PlainText.identifier: "Not an image"], [UTType.png.identifier: red.pngData()!]]
    XCTAssertTrue(source.hasImages)
    XCTAssertNil(source.imageData(), "Must not search the second item for an image")
    controller = ScreenshotOfferController(defaults: defaults, clipboard: source, lineCounter: { _ in 2 })
    await controller.setEnabled(true)
    XCTAssertNil(controller.offer)
    board.image = red
    await controller.refresh()
    XCTAssertEqual(controller.offer?.imageData, red.pngData())
    let firstID = controller.offer?.id
    board.image = blue
    await controller.refresh()
    XCTAssertNotEqual(controller.offer?.id, firstID)
    XCTAssertEqual(controller.offer?.imageData, blue.pngData())
    board.string = "replacement text"
    await controller.refresh()
    XCTAssertNil(controller.offer)
    board.items = []
    await controller.refresh()
    XCTAssertNil(controller.offer)
  }

  func testRealPasteboardNotificationClearsOffer() async {
    let board = UIPasteboard.withUniqueName()
    defer { UIPasteboard.remove(withName: board.name) }
    board.image = image(.green)
    controller = ScreenshotOfferController(defaults: defaults, clipboard: PasteboardImageSource(pasteboard: board))
    await controller.setEnabled(true)
    XCTAssertNotNil(controller.offer)
    board.items = []
    for _ in 0..<100 where controller.offer != nil { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNil(controller.offer, "The pasteboard notification must clear without foreground refresh")
  }

  func testRenderedClipboardSettingsAndDismissedToast() async throws {
    let harness = SnapshotHarness.make()
    var draft = APISettings()
    draft.baseURLString = ""
    let settings = SettingsView(settings: draft, screenshots: controller) { _ in }
      .environment(harness.model)
    let settingsSurface = try XCTUnwrap(SnapshotSurface(root: settings, size: CGSize(width: 390, height: 844)))
    defer { settingsSurface.detach() }
    _ = await settingsSurface.captureUntilOCR(contains: ["Connection"])
    if let scroll = settingsSurface.firstDescendant(UIScrollView.self) {
      scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
    }
    let rendered = await settingsSurface.captureUntilOCR(contains: ["Offer clipboard images", "paste permission"])
    XCTAssertTrue(rendered.text.contains("offer clipboard images"), rendered.text)
    XCTAssertTrue(rendered.text.contains("paste permission"), rendered.text)
    attach(rendered.image, name: "clipboard-settings-off")
    let toggle = try XCTUnwrap(settingsSurface.firstControl(label: "Offer clipboard images"))
    XCTAssertTrue(settingsSurface.activate(toggle))
    let enabled = await settingsSurface.waitUntil { self.controller.isEnabled }
    XCTAssertTrue(enabled)
    let enabledRender = await settingsSurface.captureUntilOCR(contains: ["On", "paste permission"])
    attach(enabledRender.image, name: "clipboard-settings-on")
    settingsSurface.detach()

    clipboard.changeCount += 1
    clipboard.data = image(.systemTeal).pngData()
    await controller.refresh()
    let surface = try XCTUnwrap(SnapshotSurface(root: ClipboardToastFixture(controller: controller), size: CGSize(width: 390, height: 844)))
    defer { surface.detach() }
    let offered = await surface.captureUntilOCR(contains: ["Clipboard image", "3 lines"])
    XCTAssertTrue(offered.text.contains("clipboard image"), offered.text)
    XCTAssertTrue(offered.text.contains("3 lines"), offered.text)
    XCTAssertTrue(offered.text.contains("add these transactions"), offered.text)
    attach(offered.image, name: "clipboard-offered")
    let dismiss = try XCTUnwrap(surface.firstControl(label: "Dismiss clipboard image"))
    XCTAssertTrue(surface.activate(dismiss))
    let gone = await surface.waitUntil { self.controller.offer == nil }
    XCTAssertTrue(gone)
    await controller.refresh()
    let dismissed = await surface.captureUntilOCR(contains: ["No clipboard offer"])
    XCTAssertFalse(dismissed.text.contains("add these transactions"))
    attach(dismissed.image, name: "clipboard-dismissed")
    XCTAssertTrue(try store.claimInbox().isEmpty)
  }

  private func image(_ colour: UIColor) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 160, height: 100)).image { context in
      colour.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
      ("TEST RECEIPT\nCoffee $4.50" as NSString).draw(at: CGPoint(x: 8, y: 20), withAttributes: [.foregroundColor: UIColor.white])
    }
  }

  private func attach(_ image: UIImage, name: String) {
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

@MainActor
private struct ClipboardToastFixture: View {
  let controller: ScreenshotOfferController
  var body: some View {
    VStack {
      Text("Clipboard image offer").font(.title2)
      Spacer()
      if let offer = controller.offer {
        ScreenshotOfferToast(offer: offer, onAdd: { try? controller.review() }, onDismiss: { controller.dismiss() })
      } else {
        Text("No clipboard offer")
      }
    }
    .padding()
    .background(Theme.canvas)
  }
}

@MainActor
private final class FakeClipboard: ClipboardImageSource {
  var changeCount = 42
  private var available = true
  var hasImages: Bool {
    get { availabilityChecks += 1; return available }
    set { available = newValue }
  }
  var notificationObject: AnyObject? { nil }
  var data: Data? = Data([1, 2, 3])
  var reads = 0
  var availabilityChecks = 0
  func imageData() -> Data? {
    reads += 1
    return data
  }
}

private final class LineCountGate: @unchecked Sendable {
  private let lock = NSLock()
  var delayNext = false
  private var started = false
  private var countValue = 0
  private let proceed = DispatchSemaphore(value: 0)
  var calls: Int { lock.withLock { countValue } }

  func waitUntilStarted() async -> Bool {
    for _ in 0..<200 {
      if lock.withLock({ started }) { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  func allowProceed() { proceed.signal() }

  func count(_ data: Data) -> Int {
    let delay = lock.withLock {
      countValue += 1
      let delay = delayNext
      delayNext = false
      if delay { started = true }
      return delay
    }
    if delay { proceed.wait() }
    return 3
  }
}
