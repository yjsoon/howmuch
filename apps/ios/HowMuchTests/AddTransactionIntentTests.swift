import XCTest
@testable import HowMuch

final class AddTransactionIntentTests: XCTestCase {
  func testFourFractionalDigitsAreRejected() {
    XCTAssertNil(MoneyCodec.milliunits(from: Decimal(12345) / 10000))
    XCTAssertThrowsError(
      try AddTransactionIntentBuilder.draft(
        amount: Decimal(12345) / 10000,
        direction: .outflow,
        accountID: "acct-everyday",
        payee: nil,
        categoryID: nil,
        date: nil,
        flag: nil,
        memo: nil,
        cleared: nil,
        catalog: Self.catalog
      )
    ) { error in
      XCTAssertEqual(error as? AddTransactionIntentBuilder.Error, .tooManyFractionDigits)
    }
  }

  func testNegativeDecimalDoesNotFlipDirection() throws {
    let draft = try AddTransactionIntentBuilder.draft(
      amount: Decimal(-3500) / 1000,
      direction: .outflow,
      accountID: "acct-everyday",
      payee: nil,
      categoryID: nil,
      date: nil,
      flag: nil,
      memo: nil,
      cleared: nil,
      catalog: Self.catalog
    )
    XCTAssertEqual(draft.direction, .outflow)
    XCTAssertEqual(draft.amountMagnitudeMilli, 3_500)
    XCTAssertEqual(draft.signedMilliunits, -3_500)
  }

  func testNilCatalogStillAppliesPickedIDs() throws {
    let draft = try AddTransactionIntentBuilder.draft(
      amount: Decimal(3500) / 1000,
      direction: .outflow,
      accountID: "acct-everyday",
      payee: AddTransactionIntentBuilder.PayeeInput(
        id: "new:Shortcut Coffee Verify",
        name: "Shortcut Coffee Verify",
        transferAccountId: nil,
        isNew: true
      ),
      categoryID: "cat-dining",
      date: nil,
      flag: nil,
      memo: nil,
      cleared: nil,
      catalog: nil
    )
    XCTAssertEqual(draft.accountID, "acct-everyday")
    XCTAssertEqual(draft.payeeName, "Shortcut Coffee Verify")
    XCTAssertNil(draft.payeeID)
    XCTAssertEqual(draft.categoryID, "cat-dining")
    XCTAssertEqual(draft.amountMagnitudeMilli, 3_500)
  }

  func testNilCatalogKeepsMatchedPayeeIDs() throws {
    let draft = try AddTransactionIntentBuilder.draft(
      amount: Decimal(3500) / 1000,
      direction: .outflow,
      accountID: "acct-everyday",
      payee: AddTransactionIntentBuilder.PayeeInput(
        id: "payee-fairprice",
        name: "FairPrice Finest",
        transferAccountId: nil,
        isNew: false
      ),
      categoryID: "cat-dining",
      date: nil,
      flag: nil,
      memo: nil,
      cleared: nil,
      catalog: nil
    )
    XCTAssertEqual(draft.payeeID, "payee-fairprice")
    XCTAssertEqual(draft.payeeName, "FairPrice Finest")
    XCTAssertEqual(draft.accountID, "acct-everyday")
  }

  func testStaleIDsAreDropped() throws {
    let draft = try AddTransactionIntentBuilder.draft(
      amount: Decimal(3500) / 1000,
      direction: .outflow,
      accountID: "acct-gone",
      payee: AddTransactionIntentBuilder.PayeeInput(
        id: "payee-gone",
        name: "Ghost",
        transferAccountId: nil,
        isNew: false
      ),
      categoryID: "cat-gone",
      date: nil,
      flag: nil,
      memo: nil,
      cleared: nil,
      catalog: Self.catalog
    )
    XCTAssertEqual(draft.accountID, "")
    XCTAssertNil(draft.payeeID)
    XCTAssertEqual(draft.payeeName, "")
    XCTAssertNil(draft.categoryID)
    XCTAssertEqual(draft.amountMagnitudeMilli, 3_500)
  }

  func testTransferPayeeDropsCategoryWhenBothOnBudget() throws {
    let draft = try AddTransactionIntentBuilder.draft(
      amount: Decimal(10),
      direction: .outflow,
      accountID: "acct-everyday",
      payee: AddTransactionIntentBuilder.PayeeInput(
        id: "payee-transfer",
        name: "Travel Card",
        transferAccountId: "acct-travel",
        isNew: false
      ),
      categoryID: "cat-dining",
      date: nil,
      flag: nil,
      memo: nil,
      cleared: nil,
      catalog: Self.catalog
    )
    XCTAssertEqual(draft.payeeID, "payee-transfer")
    XCTAssertEqual(draft.transferAccountID, "acct-travel")
    XCTAssertNil(draft.categoryID)
  }

  func testEntityInitsTakeStringNames() {
    let account = AccountEntity(id: "acct-everyday", name: "Everyday Account")
    XCTAssertEqual(account.name, "Everyday Account")

    let payee = PayeeEntity(id: PayeeEntityQuery.newPayeeID(for: "Coffee"), name: "Coffee")
    XCTAssertEqual(payee.name, "Coffee")
    XCTAssertEqual(payee.isNew, true)

    let category = CategoryEntity(id: "cat-dining", name: "Dining Out", groupName: "Everyday")
    XCTAssertEqual(category.groupName, "Everyday")
  }

  func testEntityQueriesKeepPickedIDsWhenCatalogIsUnread() {
    let account = AccountEntityQuery.resolved(["acct-everyday"], catalog: nil)
    XCTAssertEqual(account.map(\.id), ["acct-everyday"])

    let payee = PayeeEntityQuery.resolved(["payee-fairprice"], catalog: nil)
    XCTAssertEqual(payee.map(\.id), ["payee-fairprice"])
    XCTAssertEqual(payee.first?.isNew, false)

    let created = PayeeEntityQuery.resolved(
      [PayeeEntityQuery.newPayeeID(for: "Shortcut Coffee Verify")],
      catalog: nil
    )
    XCTAssertEqual(created.first?.isNew, true)
    XCTAssertEqual(created.first?.name, "Shortcut Coffee Verify")

    let category = CategoryEntityQuery.resolved(["cat-dining"], catalog: nil)
    XCTAssertEqual(category.map(\.id), ["cat-dining"])
  }

  func testEntityQueriesPreferCatalogNamesAndKeepUnknownIDs() {
    let account = AccountEntityQuery.resolved(["acct-everyday", "acct-gone"], catalog: Self.catalog)
    XCTAssertEqual(account.map(\.id), ["acct-everyday", "acct-gone"])
    XCTAssertEqual(account.first?.name, "Everyday Account")

    let byName = AccountEntityQuery.resolved(["Everyday Account"], catalog: Self.catalog)
    XCTAssertEqual(byName.first?.id, "acct-everyday")

    let payee = PayeeEntityQuery.resolved(["payee-transfer"], catalog: Self.catalog)
    XCTAssertEqual(payee.first?.id, "payee-transfer")
    XCTAssertEqual(payee.first?.name, "Travel Card")
    XCTAssertEqual(payee.first?.isNew, false)

    let category = CategoryEntityQuery.resolved(["Dining Out"], catalog: Self.catalog)
    XCTAssertEqual(category.first?.id, "cat-dining")
    XCTAssertEqual(category.first?.name, "Dining Out")
    XCTAssertEqual(category.first?.groupName, "Everyday")
  }

  func testBuilderResolvesAccountAndCategoryDisplayNames() throws {
    let draft = try AddTransactionIntentBuilder.draft(
      amount: Decimal(3500) / 1000,
      direction: .outflow,
      accountID: "Everyday Account",
      payee: nil,
      categoryID: "Dining Out",
      date: nil,
      flag: nil,
      memo: nil,
      cleared: nil,
      catalog: Self.catalog
    )
    XCTAssertEqual(draft.accountID, "acct-everyday")
    XCTAssertEqual(draft.categoryID, "cat-dining")
  }

  func testNewPayeeRoundTripLeavesNameOnly() async throws {
    let id = PayeeEntityQuery.newPayeeID(for: "Shortcut Coffee Verify")
    XCTAssertEqual(PayeeEntityQuery.newPayeeName(from: id), "Shortcut Coffee Verify")
    let entities = try await PayeeEntityQuery().entities(for: [id])
    XCTAssertEqual(entities.first?.id, id)
    XCTAssertEqual(entities.first?.name, "Shortcut Coffee Verify")
    XCTAssertEqual(entities.first?.isNew, true)

    let draft = try AddTransactionIntentBuilder.draft(
      amount: Decimal(3500) / 1000,
      direction: .outflow,
      accountID: "acct-everyday",
      payee: AddTransactionIntentBuilder.PayeeInput(
        id: id,
        name: "Shortcut Coffee Verify",
        transferAccountId: nil,
        isNew: true
      ),
      categoryID: nil,
      date: nil,
      flag: nil,
      memo: nil,
      cleared: nil,
      catalog: Self.catalog
    )
    XCTAssertNil(draft.payeeID)
    XCTAssertEqual(draft.payeeName, "Shortcut Coffee Verify")
  }

  func testIntentFlagNoneUsesNonEmptyRawValue() {
    XCTAssertEqual(IntentFlag.none.rawValue, "none")
    XCTAssertFalse(IntentFlag.none.rawValue.isEmpty)
    XCTAssertEqual(IntentFlag.none.flagColour, .none)
    XCTAssertEqual(IntentFlag.red.flagColour, .red)
  }

  func testBareRequestIsBlankKind() throws {
    let request = try AddTransactionIntentBuilder.request(
      amount: nil,
      direction: nil,
      accountID: nil,
      payee: nil,
      categoryID: nil,
      date: nil,
      flag: nil,
      memo: nil,
      cleared: nil,
      catalog: Self.catalog
    )
    XCTAssertEqual(request.kind, .blank)
  }

  private static let catalog = IntentCatalogSnapshot(
    connectionFingerprint: "plan-a",
    accounts: [
      IntentCatalogAccount(id: "acct-everyday", name: "Everyday Account", onBudget: true, closed: false),
      IntentCatalogAccount(id: "acct-travel", name: "Travel Card", onBudget: true, closed: false),
    ],
    payees: [
      IntentCatalogPayee(id: "payee-fairprice", name: "FairPrice Finest", transferAccountId: nil, deleted: false),
      IntentCatalogPayee(id: "payee-transfer", name: "Travel Card", transferAccountId: "acct-travel", deleted: false),
    ],
    categories: [
      IntentCatalogCategory(id: "cat-dining", name: "Dining Out", groupName: "Everyday", isQuiet: false, deleted: false),
    ]
  )
}
