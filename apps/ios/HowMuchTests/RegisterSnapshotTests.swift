import XCTest
@testable import HowMuch

final class RegisterSnapshotTests: XCTestCase {
  func testPartitionsTodayAndFutureWithoutChangingRowIdentityOrOrder() throws {
    let transactions = try [
      transaction("future", date: "2026-09-06", amount: -4_000),
      transaction("today-b", date: "2026-09-05", amount: 10_000),
      transaction("today-a", date: "2026-09-05", amount: -2_000),
      transaction("old", date: "2026-09-04", amount: -1_000)
    ]
    let waiting = pending(date: "2026-09-05")
    let future = pending(date: "2026-09-06")
    let snapshot = RegisterSnapshot(
      transactions: transactions, pending: [future, waiting],
      schedules: [try schedule("overdue", date: "2026-09-04"), try schedule("next", date: "2026-09-06")],
      today: "2026-09-05"
    )
    XCTAssertEqual(snapshot.currentDateSections.map(\.id), ["2026-09-05", "2026-09-04"])
    XCTAssertEqual(snapshot.currentDateSections[0].transactions.map(\.id), ["today-b", "today-a"])
    XCTAssertEqual(snapshot.currentDateSections[0].pending.map(\.id), [waiting.id])
    XCTAssertTrue(snapshot.currentDateSections.allSatisfy { $0.schedules.isEmpty })
    XCTAssertEqual(snapshot.disclosureDateSections.map(\.id), ["2026-09-06", "2026-09-04"])
    XCTAssertEqual(snapshot.disclosureDateSections[0].transactions.map(\.id), ["future"])
    XCTAssertEqual(snapshot.disclosureDateSections[0].pending.map(\.id), [future.id])
    XCTAssertEqual(snapshot.disclosureDateSections[1].schedules.map(\.id), ["overdue"])
    XCTAssertEqual(snapshot.scheduledDisclosureCount, 4)
    XCTAssertEqual(snapshot.scheduleCount, 2)
    XCTAssertEqual(snapshot.transactionCount, 4)
    // Filter totals include posted futures, but not uncommitted or recurring rows.
    XCTAssertEqual(snapshot.inflow, 10_000)
    XCTAssertEqual(snapshot.outflow, 7_000)
    XCTAssertFalse(snapshot.isEmpty)
  }

  func testEmptyAndPendingOnlyStates() {
    let empty = RegisterSnapshot(transactions: [], pending: [], schedules: [], today: "2026-09-05")
    XCTAssertTrue(empty.isEmpty)
    XCTAssertTrue(empty.currentDateSections.isEmpty)
    XCTAssertTrue(empty.disclosureDateSections.isEmpty)
    XCTAssertEqual(empty.scheduledDisclosureCount, 0)
    let queued = RegisterSnapshot(transactions: [], pending: [pending(date: "2026-09-05")], schedules: [], today: "2026-09-05")
    XCTAssertFalse(queued.isEmpty)
    XCTAssertEqual(queued.transactionCount, 0)
    XCTAssertEqual(queued.currentDateSections.count, 1)
    XCTAssertEqual(queued.inflow, 0)
    XCTAssertEqual(queued.outflow, 0)
  }

  func testNewSnapshotReflectsEditsAndDayRollover() throws {
    let future = try transaction("edited", date: "2026-09-06", amount: -1_000)
    let first = RegisterSnapshot(transactions: [future], pending: [], schedules: [], today: "2026-09-05")
    let nextDay = RegisterSnapshot(transactions: [future], pending: [], schedules: [], today: "2026-09-06")
    XCTAssertEqual(first.scheduledDisclosureCount, 1)
    XCTAssertEqual(nextDay.scheduledDisclosureCount, 0)
    XCTAssertEqual(nextDay.currentDateSections.first?.transactions.map(\.id), ["edited"])
    let edited = try transaction("edited", date: "2026-09-04", amount: 2_000)
    let next = RegisterSnapshot(transactions: [edited], pending: [], schedules: [], today: "2026-09-05")
    XCTAssertEqual(next.inflow, 2_000)
    XCTAssertEqual(next.outflow, 0)
    XCTAssertEqual(next.currentDateSections.first?.date, "2026-09-04")
  }

  func testLargeRegisterSnapshotPerformance() throws {
    let rows = try (0..<10_000).map { index in
      try transaction("row-\(index)", date: index.isMultiple(of: 2) ? "2026-09-05" : "2026-09-06", amount: -1_000)
    }
    measure {
      let snapshot = RegisterSnapshot(transactions: rows, pending: [], schedules: [], today: "2026-09-05")
      XCTAssertEqual(snapshot.transactionCount, 10_000)
      XCTAssertEqual(snapshot.scheduledDisclosureCount, 5_000)
      XCTAssertEqual(snapshot.outflow, 10_000_000)
    }
  }

  private func transaction(_ id: String, date: String, amount: Int) throws -> Transaction {
    try JSONDecoder().decode(Transaction.self, from: JSONSerialization.data(withJSONObject: [
      "id": id, "date": date, "amount": amount, "cleared": "uncleared", "approved": true,
      "accountId": "demo", "accountName": "Demo", "deleted": false, "subtransactions": []
    ]))
  }

  private func schedule(_ id: String, date: String) throws -> ScheduledTransaction {
    try JSONDecoder().decode(ScheduledTransaction.self, from: JSONSerialization.data(withJSONObject: [
      "id": id, "dateFirst": date, "dateNext": date, "frequency": "monthly", "amount": -9_000,
      "accountId": "demo", "deleted": false, "subtransactions": []
    ]))
  }

  private func pending(date: String) -> PendingRow {
    let request = TransactionWriteRequest(
      accountID: "demo", date: date, amount: -8_000, payeeID: nil, payeeName: "Demo",
      categoryID: nil, memo: nil, cleared: .uncleared, approved: true, flagColor: nil, subtransactions: []
    )
    return PendingRow(
      pending: PendingTransaction(request: request, connectionFingerprint: "demo"),
      status: .waitingForConnection, accountName: "Demo", categoryName: nil, payeeName: "Demo"
    )
  }
}
