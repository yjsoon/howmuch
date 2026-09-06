import XCTest
@testable import HowMuch

final class RegisterApprovalTests: XCTestCase {
  func testKeepsOnlyVisibleUnapprovedUndeletedParentIDs() {
    XCTAssertEqual(
      RegisterApproval.eligibleIDs(in: [
        row("a"),
        row("b", approved: true),
        row("c", deleted: true),
        row("d"),
      ]),
      ["a", "d"]
    )
  }

  func testSubmittedPlanApprovesALedgerRowThatIsNotInTheInbox() {
    XCTAssertEqual(RegisterApproval.plan(submitted: [row("ledger-only")])?.ids, ["ledger-only"])
    XCTAssertNil(RegisterApproval.plan(ids: ["ledger-only"], rows: [row("inbox")]))
    XCTAssertNil(RegisterApproval.plan(submitted: [row("already", approved: true)]))
  }

  func testDropsMissingApprovedDeletedAndDuplicateIDs() {
    let plan = RegisterApproval.plan(
      ids: ["d", "a", "d", "missing", "b", "c"],
      rows: [row("a"), row("b", approved: true), row("c", deleted: true), row("d")]
    )
    XCTAssertEqual(plan?.ids, ["d", "a"])
    XCTAssertNil(RegisterApproval.plan(ids: ["b", "missing"], rows: [row("b", approved: true)]))
  }

  func testChunksApprovalPlansAt100IDs() {
    let rows = (0..<101).map { row("txn-\($0)") }
    let plan = RegisterApproval.plan(ids: rows.map(\.id), rows: rows)
    XCTAssertEqual(plan?.chunks.count, 2)
    XCTAssertEqual(plan?.chunks[0].ids.count, 100)
    XCTAssertEqual(plan?.chunks[1].ids, ["txn-100"])
  }

  func testWritesCompactBritishApprovalCopy() {
    XCTAssertEqual(RegisterApproval.approveSelectedLabel(3), "Approve 3 selected")
    XCTAssertEqual(RegisterApproval.approveAllLabel(3), "Approve all (3)")
    XCTAssertEqual(RegisterApproval.approvedToast(1), "1 transaction approved.")
    XCTAssertEqual(RegisterApproval.approvedToast(3), "3 transactions approved.")
    XCTAssertEqual(
      RegisterApproval.interruptedToast(approvedCount: 2, uncertainCount: 1),
      "2 transactions approved. 1 may not have been approved."
    )
  }

  func testBeginAddsPendingAndRejectsEmptyOrAlreadyPendingIDs() {
    XCTAssertNil(RegisterApproval.begin(.empty, ids: []))
    let started = RegisterApproval.begin(.empty, ids: ["a", "b"])
    XCTAssertEqual(started?.pending, ["a", "b"])
    XCTAssertEqual(started?.confirmed.count, 0)
    XCTAssertNotNil(started)
    XCTAssertNil(RegisterApproval.begin(started!, ids: ["b", "c"]))
  }

  func testFinishMovesIDsFromPendingToConfirmed() {
    let started = RegisterApproval.begin(.empty, ids: ["a", "b"])
    XCTAssertNotNil(started)
    let finished = RegisterApproval.finish(started!, ids: ["a"])
    XCTAssertEqual(finished.pending, ["b"])
    XCTAssertEqual(finished.confirmed, ["a"])
    XCTAssertTrue(started!.pending.contains("a"))
    XCTAssertFalse(started!.confirmed.contains("a"))
  }

  func testFailDropsPendingAndConfirmsTheAcceptedPrefix() {
    let started = RegisterApproval.begin(.empty, ids: ["a", "b", "c"])
    XCTAssertNotNil(started)
    let interrupted = RegisterApproval.fail(started!, ids: ["a", "b", "c"], approvedCount: 2)
    XCTAssertTrue(interrupted.pending.isEmpty)
    XCTAssertEqual(interrupted.confirmed, ["a", "b"])
    XCTAssertEqual(RegisterApproval.fail(started!, ids: ["a", "b", "c"], approvedCount: 0).confirmed, [])
  }

  func testLooksApprovedUsesTheConfirmedOverlay() {
    let session = RegisterApproval.finish(RegisterApproval.begin(.empty, ids: ["a"])!, ids: ["a"])
    XCTAssertTrue(RegisterApproval.looksApproved(row("a"), session: session))
    XCTAssertFalse(RegisterApproval.looksApproved(row("b"), session: session))
    XCTAssertTrue(RegisterApproval.looksApproved(row("b", approved: true), session: .empty))
  }

  func testEligibleIDsSkipConfirmedOverlayRowsWhenASessionIsPassed() {
    let session = RegisterApproval.finish(RegisterApproval.begin(.empty, ids: ["a"])!, ids: ["a"])
    XCTAssertEqual(RegisterApproval.eligibleIDs(in: [row("a"), row("d")], session: session), ["d"])
    XCTAssertEqual(RegisterApproval.eligibleIDs(in: [row("a"), row("d")]), ["a", "d"])
  }

  func testSecondPlanAfterFinishOmitsConfirmedIDs() {
    let rows = [row("a"), row("d")]
    let finished = RegisterApproval.finish(RegisterApproval.begin(.empty, ids: ["a"])!, ids: ["a"])
    XCTAssertEqual(RegisterApproval.plan(ids: ["a", "d"], rows: rows, session: finished)?.ids, ["d"])
  }

  private func row(_ id: String, approved: Bool = false, deleted: Bool = false) -> RegisterApproval.Row {
    RegisterApproval.Row(id: id, approved: approved, deleted: deleted)
  }
}
