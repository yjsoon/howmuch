import XCTest
@testable import HowMuch

final class SlipReaderMappingTests: XCTestCase {
  func testStringAmountsGoThroughMoneyCodec() {
    let mapped = SlipReaderMapping.map(
      [
        .init(amount: "5.00", category: "Groceries", account: "Everyday Account"),
        .init(amount: "$3.5", category: "Dining Out", account: "Everyday Account"),
      ],
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )
    XCTAssertEqual(mapped.map(\.draft.amountMagnitudeMilli), [5_000, 3_500])
    XCTAssertEqual(mapped.map(\.parsedAmount), [true, true])
    XCTAssertEqual(MoneyCodec.milliunits(from: "5.00").map(abs), mapped[0].draft.amountMagnitudeMilli)
  }

  func testUnambiguousNameMapsToID() {
    let mapped = SlipReaderMapping.map(
      [.init(amount: "5", category: "Groceries", account: "Everyday Account")],
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Card"),
      ],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )
    XCTAssertEqual(mapped.count, 1)
    XCTAssertEqual(mapped[0].draft.accountID, "acct-everyday")
    XCTAssertEqual(mapped[0].draft.categoryID, "cat-groceries")
    XCTAssertTrue(mapped[0].accountCandidates.isEmpty)
    XCTAssertTrue(mapped[0].categoryCandidates.isEmpty)
  }

  func testTwoMatchingNamesLeaveIDNil() {
    let mapped = SlipReaderMapping.map(
      [.init(amount: "5", category: "Groceries", account: "Account")],
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Account"),
      ],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )
    XCTAssertEqual(mapped.count, 1)
    XCTAssertEqual(mapped[0].draft.accountID, "")
    XCTAssertTrue(mapped[0].parsedAccount)
    XCTAssertEqual(mapped[0].accountCandidates.map(\.id), ["acct-everyday", "acct-travel"])
  }

  func testOmittedAccountDoesNotForceAMatch() {
    let mapped = SlipReaderMapping.map(
      [.init(amount: "5", category: "Groceries")],
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )
    XCTAssertEqual(mapped.count, 1)
    XCTAssertFalse(mapped[0].parsedAccount)
    XCTAssertEqual(mapped[0].draft.accountID, "")
    XCTAssertTrue(mapped[0].accountCandidates.isEmpty)
  }

  func testAmbiguousAccountKeepsTransferPayee() {
    let mapped = SlipReaderMapping.map(
      [.init(amount: "5", payee: "Transfer : Travel Account", account: "Account")],
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Account"),
      ],
      categoryGroups: [Self.everydayGroup],
      payees: [
        Payee(
          id: "payee-travel",
          name: "Transfer : Travel Account",
          transferAccountId: "acct-travel",
          deleted: false
        ),
      ],
      calendar: Self.calendar,
      now: Self.now
    )
    XCTAssertEqual(mapped.count, 1)
    XCTAssertEqual(mapped[0].draft.accountID, "")
    XCTAssertEqual(mapped[0].accountCandidates.map(\.id), ["acct-everyday", "acct-travel"])
    XCTAssertEqual(mapped[0].draft.transferAccountID, "acct-travel")
    XCTAssertEqual(mapped[0].draft.payeeID, "payee-travel")
  }

  func testPickingTransferDestinationAccountDropsSelfTransfer() {
    var draft = TransactionDraft()
    draft.transferAccountID = "acct-travel"
    draft.payeeID = "payee-travel"
    draft.payeeName = "Transfer : Travel Account"
    SlipAccountPick.apply("acct-travel", to: &draft)
    XCTAssertEqual(draft.accountID, "acct-travel")
    XCTAssertNil(draft.transferAccountID)
    XCTAssertNil(draft.payeeID)
    XCTAssertEqual(draft.payeeName, "")
  }

  func testPickingOtherAccountKeepsTransfer() {
    var draft = TransactionDraft()
    draft.transferAccountID = "acct-travel"
    draft.payeeID = "payee-travel"
    draft.payeeName = "Transfer : Travel Account"
    SlipAccountPick.apply("acct-everyday", to: &draft)
    XCTAssertEqual(draft.accountID, "acct-everyday")
    XCTAssertEqual(draft.transferAccountID, "acct-travel")
    XCTAssertEqual(draft.payeeID, "payee-travel")
  }

  func testTwoSpendsReturnTwoDrafts() {
    let mapped = SlipReaderMapping.map(
      [
        .init(amount: "5", category: "Groceries", account: "Everyday Account"),
        .init(amount: "12", category: "Dining Out", account: "Travel Card"),
      ],
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Card"),
      ],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )
    XCTAssertEqual(mapped.count, 2)
    XCTAssertEqual(mapped[0].draft.amountMagnitudeMilli, 5_000)
    XCTAssertEqual(mapped[0].draft.accountID, "acct-everyday")
    XCTAssertEqual(mapped[0].draft.categoryID, "cat-groceries")
    XCTAssertEqual(mapped[1].draft.amountMagnitudeMilli, 12_000)
    XCTAssertEqual(mapped[1].draft.accountID, "acct-travel")
    XCTAssertEqual(mapped[1].draft.categoryID, "cat-dining")
    XCTAssertNotEqual(mapped[0].draft.importID, mapped[1].draft.importID)
  }

  func testDateUsesLocalCalendar() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let now = Date(timeIntervalSince1970: 1_746_316_800)
    let mapped = SlipReaderMapping.map(
      [.init(amount: "5", date: "2026-03-04")],
      accounts: [],
      categoryGroups: [],
      payees: [],
      calendar: calendar,
      now: now
    )
    XCTAssertEqual(mapped.count, 1)
    XCTAssertTrue(mapped[0].parsedDate)
    XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: mapped[0].draft.date).year, 2026)
    XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: mapped[0].draft.date).month, 3)
    XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: mapped[0].draft.date).day, 4)
    let start = calendar.startOfDay(for: mapped[0].draft.date)
    XCTAssertEqual(mapped[0].draft.date, start)
  }

  func testPromptPrefixPutsCatalogsBeforeTheSentence() {
    let prefix = SlipReaderPrompt.prefix(
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-closed", "Closed Card", closed: true),
      ],
      categoryGroups: [Self.everydayGroup],
      payees: []
    )
    XCTAssertTrue(prefix.contains("Accounts: Everyday Account"))
    XCTAssertFalse(prefix.contains("Closed Card"))
    XCTAssertTrue(prefix.contains("Categories: Groceries, Dining Out"))
    XCTAssertTrue(prefix.hasSuffix("Sentence:\n"))
  }

  func testReadDoesNotCallCommit() async {
    let before = OutboxStore.load()
    let reader = SlipReader(extractor: .fixed { _ in
      [
        .init(amount: "5", category: "Groceries", account: "Everyday Account"),
        .init(amount: "8", category: "Dining Out", account: "Everyday Account"),
      ]
    })
    let drafts = await reader.read(
      text: "5 of Groceries and 8 of Dining Out on Everyday Account",
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup],
      payees: []
    )
    XCTAssertEqual(drafts.count, 2)
    XCTAssertEqual(drafts.map(\.amountMagnitudeMilli), [5_000, 8_000])
    XCTAssertEqual(OutboxStore.load().map(\.id), before.map(\.id))
  }

  private static let now = Date(timeIntervalSince1970: 1_746_316_800)
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  private static let everydayGroup = CategoryGroup(
    id: "grp-spend",
    name: "Everyday",
    hidden: false,
    deleted: false,
    categories: [
      Category(id: "cat-groceries", categoryGroupID: "grp-spend", name: "Groceries", deleted: false),
      Category(id: "cat-dining", categoryGroupID: "grp-spend", name: "Dining Out", deleted: false),
    ]
  )

  private static func account(_ id: String, _ name: String, closed: Bool = false) -> Account {
    Account(
      id: id,
      name: name,
      icon: nil,
      type: "checking",
      onBudget: true,
      closed: closed,
      balance: 0,
      clearedBalance: 0,
      unclearedBalance: 0,
      lastReconciledDate: nil,
      deleted: false
    )
  }
}
