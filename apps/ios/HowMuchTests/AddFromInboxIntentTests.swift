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
  }

  override func tearDown() async throws {
    InboxIntentHandoff.store = .shared
    CaptureRouter.shared.dropForSignOut()
    while CaptureRouter.shared.blockingSheetCount > 0 {
      CaptureRouter.shared.endBlockingSheet()
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
}

private extension InboxStore {
  func claimInboxThrowsNothing() -> Bool {
    (try? claimInbox())?.isEmpty ?? true
  }
}
