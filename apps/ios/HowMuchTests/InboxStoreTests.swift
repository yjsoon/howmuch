import XCTest
@testable import HowMuch

final class InboxStoreTests: XCTestCase {
  private var directory: URL!
  private var store: InboxStore!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    store = InboxStore(container: directory)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testWriteUsesPartialThenRename() throws {
    let id = UUID()
    try store.write(
      InboxWrite(
        id: id,
        source: .shareSheet,
        kind: .text,
        filename: "payload.txt",
        data: Data("5 of Groceries on Everyday".utf8)
      )
    )
    let ready = store.inboxDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    let partial = store.inboxDirectory.appendingPathComponent("\(id.uuidString).partial", isDirectory: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertTrue(store.hasReadyInboxItems())
    XCTAssertFalse(store.hasReadingItems())
  }

  func testClaimMovesInboxToReading() throws {
    let id = UUID()
    try store.write(
      InboxWrite(
        id: id,
        source: .shareSheet,
        kind: .text,
        filename: "payload.txt",
        data: Data("12 coffee".utf8)
      )
    )
    let claimed = try store.claimInbox()
    XCTAssertEqual(claimed.map(\.id), [id])
    XCTAssertEqual(claimed.first?.source, .shareSheet)
    XCTAssertEqual(claimed.first?.payloadText(), "12 coffee")
    XCTAssertFalse(store.hasReadyInboxItems())
    XCTAssertTrue(store.hasReadingItems())
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: store.readingDirectory.appendingPathComponent(id.uuidString).path
      )
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.inboxDirectory.appendingPathComponent(id.uuidString).path
      )
    )
  }

  func testSecondClaimOfTheSameIDIsANoOp() throws {
    let id = UUID()
    try store.write(
      InboxWrite(
        id: id,
        source: .shareSheet,
        kind: .text,
        filename: "payload.txt",
        data: Data("5 groceries".utf8)
      )
    )
    XCTAssertEqual(try store.claim(id)?.id, id)
    XCTAssertNil(try store.claim(id))
    XCTAssertEqual(try store.claimInbox(), [])
    XCTAssertEqual(store.loadReading().map(\.id), [id])
  }

  func testClaimSkipsPartialDirectories() throws {
    let id = UUID()
    let partial = store.inboxDirectory.appendingPathComponent("\(id.uuidString).partial", isDirectory: true)
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data("incomplete".utf8).write(to: partial.appendingPathComponent("payload.txt"))
    XCTAssertEqual(try store.claimInbox(), [])
    XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertFalse(store.hasReadingItems())
  }

  func testOversizedPayloadIsRejectedAndLeavesNoPartial() {
    let id = UUID()
    let data = Data(repeating: 0x61, count: InboxStore.maxPayloadBytes + 1)
    XCTAssertThrowsError(
      try store.write(
        InboxWrite(
          id: id,
          source: .shareSheet,
          kind: .image,
          filename: "payload.jpg",
          data: data
        )
      )
    ) { error in
      XCTAssertEqual(error as? InboxStoreError, .payloadTooLarge)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.inboxDirectory.appendingPathComponent(id.uuidString).path
      )
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.inboxDirectory.appendingPathComponent("\(id.uuidString).partial").path
      )
    )
  }

  func testAppIntentAndScreenshotSourcesAreRepresentable() throws {
    try store.write(
      InboxWrite(
        source: .appIntent,
        kind: .text,
        filename: "payload.txt",
        data: Data("intent".utf8)
      )
    )
    try store.write(
      InboxWrite(
        source: .detectedScreenshot,
        kind: .image,
        filename: "payload.png",
        data: Data([0x89, 0x50, 0x4E, 0x47])
      )
    )
    let claimed = try store.claimInbox()
    XCTAssertEqual(Set(claimed.map(\.source)), [.appIntent, .detectedScreenshot])
  }
}
