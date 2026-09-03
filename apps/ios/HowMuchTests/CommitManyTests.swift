import XCTest
@testable import HowMuch

final class CommitManyTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() {
    suiteName = "howmuch.tests.outbox.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
  }

  func testOneSaveForTwoDrafts() throws {
    let first = Self.draft(importID: "imp-one", amount: 7_100)
    let second = Self.draft(importID: "imp-two", amount: 2_300)
    let pending = OutboxBatch.appending(
      [first, second],
      onto: [],
      fingerprint: "fp",
      isCurrentConnection: { $0 == "fp" }
    )
    XCTAssertEqual(pending.count, 2)
    XCTAssertEqual(pending.map { $0.request.importID }, ["imp-one", "imp-two"])
    XCTAssertEqual(pending.map(\.request.amount), [-7_100, -2_300])
    XCTAssertTrue(pending.allSatisfy(\.request.approved))

    try OutboxStore.save(pending, to: defaults)
    XCTAssertEqual(OutboxStore.load(from: defaults).map { $0.request.importID }, ["imp-one", "imp-two"])
  }

  func testIdenticalImportIDReplayDoesNotDuplicate() throws {
    let draft = Self.draft(importID: "imp-same", amount: 5_000)
    let first = OutboxBatch.appending(
      [draft],
      onto: [],
      fingerprint: "fp",
      isCurrentConnection: { $0 == "fp" }
    )
    try OutboxStore.save(first, to: defaults)

    let replayed = OutboxBatch.appending(
      [draft],
      onto: OutboxStore.load(from: defaults),
      fingerprint: "fp",
      isCurrentConnection: { $0 == "fp" }
    )
    XCTAssertEqual(replayed.count, 1)
    XCTAssertEqual(replayed.first?.request.importID, "imp-same")
    try OutboxStore.save(replayed, to: defaults)
    XCTAssertEqual(OutboxStore.load(from: defaults).count, 1)
  }

  func testSingleDraftCommitStillMatchesToday() {
    let draft = Self.draft(importID: "imp-single", amount: 5_400)
    let pending = OutboxBatch.appending(
      [draft],
      onto: [],
      fingerprint: "fp",
      isCurrentConnection: { $0 == "fp" }
    )
    XCTAssertEqual(pending.count, 1)
    let request = pending[0].request
    XCTAssertEqual(request.accountID, "acct-everyday")
    XCTAssertEqual(request.amount, -5_400)
    XCTAssertEqual(request.approved, true)
    XCTAssertEqual(request.importID, "imp-single")
    XCTAssertEqual(request, draft.writeRequest(includeCleared: draft.shouldWriteCleared))
  }

  func testRepairAssignsCategoryByPayee() {
    var groceries = Self.draft(importID: "imp-cold", amount: 4_000)
    groceries.payeeName = "Cold Storage"
    groceries.categoryID = nil
    var other = Self.draft(importID: "imp-other", amount: 1_000)
    other.payeeName = "FairPrice Finest"
    other.categoryID = nil
    let items = [IntakeReviewItem(draft: groceries), IntakeReviewItem(draft: other)]
    let next = IntakeRepair.apply(
      "everything from Cold Storage is groceries",
      to: items,
      categoryGroups: [Self.everydayGroup]
    )
    XCTAssertEqual(next?[0].draft.categoryID, "cat-groceries")
    XCTAssertNil(next?[1].draft.categoryID)
  }

  private static func draft(importID: String, amount: Int) -> TransactionDraft {
    var draft = TransactionDraft()
    draft.importID = importID
    draft.accountID = "acct-everyday"
    draft.amountMagnitudeMilli = amount
    draft.direction = .outflow
    return draft
  }

  private static let everydayGroup = CategoryGroup(
    id: "grp-spend",
    name: "Everyday",
    hidden: false,
    deleted: false,
    categories: [
      Category(id: "cat-groceries", categoryGroupID: "grp-spend", name: "Groceries", deleted: false),
    ]
  )
}
