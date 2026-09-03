import XCTest
@testable import HowMuch

final class StubSlipReaderTests: XCTestCase {
  func testPlaceholderSentenceFillsAmountCategoryAndAccount() {
    let outcome = StubSlipReader.read(
      text: "5 of Groceries on Everyday Account",
      placeholder: "5 of Groceries on Everyday Account",
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup]
    )
    XCTAssertEqual(outcome.amountMilli, 5_000)
    XCTAssertEqual(outcome.categoryID, "cat-groceries")
    XCTAssertEqual(outcome.accountID, "acct-everyday")
    XCTAssertTrue(outcome.accountCandidates.isEmpty)
  }

  func testFoodFixtureFillsGroceriesAndNamedAccount() {
    let outcome = StubSlipReader.read(
      text: "$5 of food on Everyday Account",
      placeholder: "5 of Groceries on Everyday Account",
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup]
    )
    XCTAssertEqual(outcome.amountMilli, 5_000)
    XCTAssertEqual(outcome.categoryID, "cat-groceries")
    XCTAssertEqual(outcome.accountID, "acct-everyday")
  }

  func testUnmatchedAccountStaysEmpty() {
    let outcome = StubSlipReader.read(
      text: "$5 of food on No Such Bank",
      placeholder: "5 of Groceries on Everyday Account",
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup]
    )
    XCTAssertEqual(outcome.amountMilli, 5_000)
    XCTAssertEqual(outcome.categoryID, "cat-groceries")
    XCTAssertNil(outcome.accountID)
    XCTAssertTrue(outcome.accountCandidates.isEmpty)
  }

  func testAmbiguousAccountLeavesCandidates() {
    let outcome = StubSlipReader.read(
      text: "$5 of food on Account",
      placeholder: "5 of Groceries on Everyday Account",
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Account"),
      ],
      categoryGroups: [Self.everydayGroup]
    )
    XCTAssertNil(outcome.accountID)
    XCTAssertEqual(outcome.accountCandidates.map(\.id), ["acct-everyday", "acct-travel"])
  }

  func testNoAmountLeavesAmountNil() {
    let outcome = StubSlipReader.read(
      text: "coffee on Everyday Account",
      placeholder: "5 of Groceries on Everyday Account",
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup]
    )
    XCTAssertNil(outcome.amountMilli)
    XCTAssertEqual(outcome.accountID, "acct-everyday")
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

  private static func account(_ id: String, _ name: String) -> Account {
    Account(
      id: id,
      name: name,
      icon: nil,
      type: "checking",
      onBudget: true,
      closed: false,
      balance: 0,
      clearedBalance: 0,
      unclearedBalance: 0,
      lastReconciledDate: nil,
      deleted: false
    )
  }
}
