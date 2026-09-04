import XCTest
@testable import HowMuch

final class CaptureRequestTests: XCTestCase {
  func testInboxKindIsRepresentable() {
    let request = CaptureRequest(kind: .inbox, connectionFingerprint: "plan-a")
    XCTAssertEqual(request.kind, .inbox)
  }

  func testSignedOutDrops() {
    let request = CaptureRequest(kind: .blank, connectionFingerprint: "plan-a")
    XCTAssertEqual(
      CaptureAdmission.decide(request, isAuthenticated: false, currentFingerprint: "plan-a"),
      .drop
    )
  }

  func testFingerprintMismatchDrops() {
    let request = CaptureRequest(kind: .blank, connectionFingerprint: "plan-a")
    XCTAssertEqual(
      CaptureAdmission.decide(request, isAuthenticated: true, currentFingerprint: "plan-b"),
      .drop
    )
  }

  func testNilFingerprintAdmitsWhenSignedIn() {
    let request = CaptureRequest(kind: .blank, connectionFingerprint: nil)
    let decision = CaptureAdmission.decide(
      request,
      isAuthenticated: true,
      currentFingerprint: "plan-a"
    )
    XCTAssertEqual(decision, .present(request))
  }

  func testMatchingFingerprintPresentsDraft() {
    var draft = TransactionDraft()
    draft.accountID = "acct-everyday"
    let request = CaptureRequest(kind: .draft(draft), connectionFingerprint: "plan-a")
    XCTAssertEqual(
      CaptureAdmission.decide(request, isAuthenticated: true, currentFingerprint: "plan-a"),
      .present(request)
    )
  }

  func testInboxDoesNotFatalError() {
    let request = CaptureRequest(kind: .inbox, connectionFingerprint: "plan-a")
    XCTAssertEqual(
      CaptureAdmission.decide(request, isAuthenticated: true, currentFingerprint: "plan-a"),
      .inbox
    )
  }

  func testNewIdIsNotEqual() {
    let first = CaptureRequest(kind: .blank, connectionFingerprint: nil)
    let second = CaptureRequest(kind: .blank, connectionFingerprint: nil)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertNotEqual(first, second)
  }
}

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

  func testInboxConsumeDoesNotPresentAForm() {
    let router = CaptureRouter.shared
    router.enqueue(CaptureRequest(kind: .inbox, connectionFingerprint: "plan-a"))
    router.consume(isAuthenticated: true, currentFingerprint: "plan-a")
    XCTAssertNil(router.pending)
    XCTAssertNil(router.presented)
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

  func testDropForSignOutClearsPendingAndPresented() {
    let router = CaptureRouter.shared
    router.enqueue(CaptureRequest(kind: .blank, connectionFingerprint: "plan-a"))
    router.consume(isAuthenticated: true, currentFingerprint: "plan-a")
    router.dropForSignOut()
    XCTAssertNil(router.pending)
    XCTAssertNil(router.presented)
  }

  func testFingerprintMismatchDropsWithoutPresenting() {
    let router = CaptureRouter.shared
    router.enqueue(CaptureRequest(kind: .blank, connectionFingerprint: "plan-a"))
    router.consume(isAuthenticated: true, currentFingerprint: "plan-b")
    XCTAssertNil(router.pending)
    XCTAssertNil(router.presented)
  }

  func testSignedOutDropsWithoutPresenting() {
    let router = CaptureRouter.shared
    router.enqueue(CaptureRequest(kind: .blank, connectionFingerprint: "plan-a"))
    router.consume(isAuthenticated: false, currentFingerprint: "plan-a")
    XCTAssertNil(router.pending)
    XCTAssertNil(router.presented)
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
}
