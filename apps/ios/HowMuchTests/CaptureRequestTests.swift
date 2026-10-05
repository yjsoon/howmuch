import XCTest
@testable import HowMuch

@MainActor
final class CaptureRouterTests: XCTestCase {
  override func setUp() async throws {
    let router = CaptureRouter.shared
    router.dropForSignOut()
    while router.blockingSheetCount > 0 {
      router.endBlockingSheet()
    }
  }

  override func tearDown() async throws {
    let router = CaptureRouter.shared
    router.dropForSignOut()
    while router.blockingSheetCount > 0 {
      router.endBlockingSheet()
    }
  }

  func testConsumeWaitsWhileABlockingSheetIsUp() {
    let router = CaptureRouter.shared
    router.beginBlockingSheet()
    router.enqueue(CaptureRequest(kind: .blank, connectionFingerprint: nil))
    router.consume(isAuthenticated: true, currentFingerprint: "plan-a")
    XCTAssertNotNil(router.pending)
    XCTAssertNil(router.presented)

    router.endBlockingSheet()
    router.consume(isAuthenticated: true, currentFingerprint: "plan-a")
    XCTAssertNil(router.pending)
    XCTAssertEqual(router.presented?.kind, .blank)
  }

  func testInboxConsumeWaitsWhileABlockingSheetIsUp() {
    let router = CaptureRouter.shared
    router.beginBlockingSheet()
    router.enqueue(CaptureRequest(kind: .inbox, connectionFingerprint: "plan-a"))
    router.consume(isAuthenticated: true, currentFingerprint: "plan-a")
    XCTAssertNotNil(router.pending)
    XCTAssertNil(router.presented)

    router.endBlockingSheet()
    router.consume(isAuthenticated: true, currentFingerprint: "plan-a")
    XCTAssertNil(router.pending)
    XCTAssertEqual(router.presented?.kind, .inbox)
  }

  func testSecondEnqueueReplacesThePresentedRequest() {
    let router = CaptureRouter.shared
    let first = CaptureRequest(kind: .blank, connectionFingerprint: nil)
    let second = CaptureRequest(kind: .blank, connectionFingerprint: nil)
    router.enqueue(first)
    router.consume(isAuthenticated: true, currentFingerprint: "plan-a")
    router.enqueue(second)
    router.consume(isAuthenticated: true, currentFingerprint: "plan-a")
    XCTAssertEqual(router.presented?.id, second.id)
    XCTAssertNotEqual(first.id, second.id)
  }

  func testSecondInboxEnqueueDoesNotReplacePresentedInbox() {
    let router = CaptureRouter.shared
    let first = CaptureRequest(kind: .inbox, connectionFingerprint: "plan-a")
    let second = CaptureRequest(kind: .inbox, connectionFingerprint: "plan-a")
    router.enqueue(first)
    router.consume(isAuthenticated: true, currentFingerprint: "plan-a")
    router.enqueue(second)
    router.consume(isAuthenticated: true, currentFingerprint: "plan-a")
    XCTAssertEqual(router.presented?.id, first.id)
    XCTAssertNil(router.pending)
  }

  func testSignedOutDropsEvenWhileABlockingSheetIsUp() {
    let router = CaptureRouter.shared
    router.beginBlockingSheet()
    router.enqueue(CaptureRequest(kind: .blank, connectionFingerprint: "plan-a"))
    router.consume(isAuthenticated: false, currentFingerprint: "plan-a")
    XCTAssertNil(router.pending)
    XCTAssertNil(router.presented)
  }

  func testFingerprintMismatchDropsEvenWhileABlockingSheetIsUp() {
    let router = CaptureRouter.shared
    router.beginBlockingSheet()
    router.enqueue(CaptureRequest(kind: .blank, connectionFingerprint: "plan-a"))
    router.consume(isAuthenticated: true, currentFingerprint: "plan-b")
    XCTAssertNil(router.pending)
    XCTAssertNil(router.presented)
  }

  func testBlockingSheetHidesTheCompactTabRow() {
    let router = CaptureRouter.shared
    XCTAssertFalse(router.hidesTabRowOverlay)
    router.beginBlockingSheet()
    XCTAssertTrue(router.hidesTabRowOverlay)
    router.endBlockingSheet()
    XCTAssertFalse(router.hidesTabRowOverlay)
  }
}
