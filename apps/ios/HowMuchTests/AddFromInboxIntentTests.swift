import XCTest
import AppIntents
import UniformTypeIdentifiers
@testable import HowMuch

@MainActor
final class AddFromInboxIntentTests: XCTestCase {
  private var directory: URL!
  private var store: InboxStore!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    store = InboxStore(container: directory)
    InboxIntentHandoff.store = store
    CaptureRouter.shared.dropForSignOut()
    while CaptureRouter.shared.blockingSheetCount > 0 {
      CaptureRouter.shared.endBlockingSheet()
    }
    while CaptureRouter.shared.hidingTabBarCount > 0 {
      CaptureRouter.shared.endHidingTabBar()
    }
  }

  override func tearDown() async throws {
    InboxIntentHandoff.store = .shared
    CaptureRouter.shared.dropForSignOut()
    while CaptureRouter.shared.blockingSheetCount > 0 {
      CaptureRouter.shared.endBlockingSheet()
    }
    while CaptureRouter.shared.hidingTabBarCount > 0 {
      CaptureRouter.shared.endHidingTabBar()
    }
    try? FileManager.default.removeItem(at: directory)
  }

  func testTextPerformWritesAppIntentInboxAndDoesNotCommit() async throws {
    var intent = AddFromTextIntent()
    intent.text = "5.40 of Groceries on Everyday"
    _ = try await intent.perform()

    XCTAssertEqual(CaptureRouter.shared.pending?.kind, .inbox)
    let claimed = try store.claimInbox()
    XCTAssertEqual(claimed.count, 1)
    XCTAssertEqual(claimed.first?.source, .appIntent)
    XCTAssertEqual(claimed.first?.kind, .text)
    XCTAssertEqual(claimed.first?.payloadText(), "5.40 of Groceries on Everyday")
    XCTAssertTrue(store.hasReadingItems())
  }

  func testImagePerformWritesAppIntentInboxAndDoesNotCommit() async throws {
    var intent = AddFromImageIntent()
    intent.image = IntentFile(data: Data([0x89, 0x50, 0x4E, 0x47]), filename: "slip.png", type: .png)
    _ = try await intent.perform()

    XCTAssertEqual(CaptureRouter.shared.pending?.kind, .inbox)
    let claimed = try store.claimInbox()
    XCTAssertEqual(claimed.first?.source, .appIntent)
    XCTAssertEqual(claimed.first?.kind, .image)
    XCTAssertEqual(claimed.first?.filename, "payload.png")
    XCTAssertEqual(try claimed.first?.payloadData(), Data([0x89, 0x50, 0x4E, 0x47]))
  }

  func testEmptyTextThrowsNeedsValue() async {
    var intent = AddFromTextIntent()
    intent.text = "   "
    do {
      _ = try await intent.perform()
      XCTFail("empty text should need a value")
    } catch {
      XCTAssertTrue(store.claimInboxThrowsNothing())
      XCTAssertNil(CaptureRouter.shared.pending)
    }
  }

  func testAddTransactionIntentStillHasNoFileParameter() {
    let intent = AddTransactionIntent()
    XCTAssertNil(intent.amount)
    XCTAssertNil(intent.account)
    XCTAssertNil(intent.memo)
  }

  func testUnknownImageTypeIgnoresHostileFilename() {
    let file = IntentFile(
      data: Data("webp-not".utf8),
      filename: "../manifest.json",
      type: .data
    )
    XCTAssertEqual(AddFromImageIntent.filename(for: file), "payload.img")
  }

  func testPngUsesPayloadPngEvenWhenFilenameIsHostile() {
    let file = IntentFile(
      data: Data([0x89, 0x50, 0x4E, 0x47]),
      filename: "manifest.json",
      type: .png
    )
    XCTAssertEqual(AddFromImageIntent.filename(for: file), "payload.png")
  }

  func testOversizedImagePerformThrowsPayloadTooLargeNotNeedsValue() async {
    var intent = AddFromImageIntent()
    intent.image = IntentFile(
      data: Data(repeating: 0x01, count: InboxStore.maxPayloadBytes + 1),
      filename: "huge.png",
      type: .png
    )
    do {
      _ = try await intent.perform()
      XCTFail("expected payloadTooLarge")
    } catch let error as InboxIntentHandoff.Error {
      XCTAssertEqual(error, .payloadTooLarge)
    } catch {
      XCTFail("wrong error \(error)")
    }
    XCTAssertTrue(store.claimInboxThrowsNothing())
    XCTAssertNil(CaptureRouter.shared.pending)
  }

  func testOversizedTextWriteThrowsPayloadTooLarge() {
    let text = String(repeating: "a", count: InboxStore.maxPayloadBytes + 1)
    XCTAssertThrowsError(try InboxIntentHandoff.textWrite(text)) { error in
      XCTAssertEqual(error as? InboxIntentHandoff.Error, .payloadTooLarge)
    }
  }
}

private extension InboxStore {
  func claimInboxThrowsNothing() -> Bool {
    (try? claimInbox())?.isEmpty ?? true
  }
}
