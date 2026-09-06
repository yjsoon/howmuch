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

  func testExtractionAmountsAcceptCurrencyPrefixesAndJunk() {
    let mapped = SlipReaderMapping.map(
      [
        .init(amount: "S$50"),
        .init(amount: "SGD 50"),
        .init(amount: "USD 12.5"),
        .init(amount: "$50 for coffee"),
        .init(amount: "50 dollars"),
        .init(amount: "$5"),
        .init(amount: "$1,234.56"),
        .init(amount: "S$1,234"),
        .init(amount: "$.50"),
      ],
      accounts: [],
      categoryGroups: [],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )
    XCTAssertEqual(
      mapped.map(\.draft.amountMagnitudeMilli),
      [50_000, 50_000, 12_500, 50_000, 50_000, 5_000, 1_234_560, 1_234_000, 500]
    )
    XCTAssertEqual(mapped.map(\.parsedAmount), Array(repeating: true, count: 9))
    XCTAssertEqual(MoneyCodec.milliunits(fromExtraction: "S$50"), 50_000)
    XCTAssertEqual(MoneyCodec.milliunits(fromExtraction: "$1,234.56"), 1_234_560)
    XCTAssertEqual(MoneyCodec.milliunits(fromExtraction: "S$1,234"), 1_234_000)
    XCTAssertEqual(MoneyCodec.milliunits(fromExtraction: "$.50"), 500)
    XCTAssertEqual(MoneyCodec.milliunits(from: "$.50"), 500)
    XCTAssertNil(MoneyCodec.milliunits(from: "S$50"))
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

  func testNaturalAndScheduledDatesParse() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_788_652_800)
    let cases: [(String, Int, Int, Int)] = [
      ("today", 2026, 9, 6),
      ("yesterday", 2026, 9, 5),
      ("8 Sep", 2026, 9, 8),
      ("Sep 8", 2026, 9, 8),
      ("8 September", 2026, 9, 8),
      ("8/9", 2026, 9, 8),
      ("scheduled 15 September", 2026, 9, 15),
      ("scheduled for 15 September", 2026, 9, 15),
      ("due on 15 September", 2026, 9, 15),
      ("next Friday", 2026, 9, 11),
      ("2026-09-20", 2026, 9, 20),
    ]
    for (raw, year, month, day) in cases {
      let parsed = SlipReaderMapping.date(from: raw, calendar: calendar, now: now)
      XCTAssertNotNil(parsed, raw)
      guard let parsed else {
        continue
      }
      let parts = calendar.dateComponents([.year, .month, .day], from: parsed)
      XCTAssertEqual(parts.year, year, raw)
      XCTAssertEqual(parts.month, month, raw)
      XCTAssertEqual(parts.day, day, raw)
      XCTAssertEqual(parsed, calendar.startOfDay(for: parsed), raw)
    }
  }

  func testApplySetsScheduledNaturalDate() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_788_652_800)
    var draft = TransactionDraft()
    draft.date = calendar.startOfDay(for: now)
    let row = SlipReaderMapping.map(
      [.init(amount: "5", date: "scheduled 15 September")],
      accounts: [],
      categoryGroups: [],
      payees: [],
      calendar: calendar,
      now: now
    )[0]
    XCTAssertTrue(row.parsedDate)
    let applied = ComposeParseApply.applying(row, to: draft)
    let parts = calendar.dateComponents([.year, .month, .day], from: applied.draft.date)
    XCTAssertEqual(parts.year, 2026)
    XCTAssertEqual(parts.month, 9)
    XCTAssertEqual(parts.day, 15)
  }

  func testUnmatchedAccountNameLeavesIDEmptyWithoutChips() {
    let mapped = SlipReaderMapping.map(
      [.init(amount: "5", account: "No Such Bank")],
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )
    XCTAssertEqual(mapped.count, 1)
    XCTAssertTrue(mapped[0].parsedAccount)
    XCTAssertEqual(mapped[0].draft.accountID, "")
    XCTAssertTrue(mapped[0].accountCandidates.isEmpty)
  }

  func testApplyKeepsSeededAccountWhenNameDoesNotMatch() {
    var draft = TransactionDraft()
    draft.accountID = "acct-everyday"
    draft.direction = .inflow
    let row = SlipReaderMapping.map(
      [.init(amount: "5", account: "No Such Bank")],
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )[0]
    let applied = ComposeParseApply.applying(row, to: draft)
    XCTAssertEqual(applied.draft.accountID, "acct-everyday")
    XCTAssertFalse(applied.showAccountPrompt)
    XCTAssertTrue(applied.accountCandidates.isEmpty)
    XCTAssertEqual(applied.draft.amountMagnitudeMilli, 5_000)
    XCTAssertEqual(applied.draft.direction, .inflow)
  }

  func testApplyDoesNotForceOutflowWhenInflowWasToggled() {
    var draft = TransactionDraft()
    draft.direction = .inflow
    draft.accountID = "acct-everyday"
    let row = SlipReaderMapping.map(
      [.init(amount: "5", category: "Groceries")],
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )[0]
    XCTAssertFalse(row.parsedInflow)
    let applied = ComposeParseApply.applying(row, to: draft)
    XCTAssertEqual(applied.draft.direction, .inflow)
  }

  func testApplySetsInflowWhenTheSentenceReceivedMoney() {
    var draft = TransactionDraft()
    draft.direction = .outflow
    let row = SlipReaderMapping.map(
      [.init(amount: "5", isInflow: true)],
      accounts: [],
      categoryGroups: [],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )[0]
    XCTAssertTrue(row.parsedInflow)
    let applied = ComposeParseApply.applying(row, to: draft)
    XCTAssertEqual(applied.draft.direction, .inflow)
  }

  func testApplyKeepsSeededAccountWhenExtractionOmitsAccount() {
    var draft = TransactionDraft()
    draft.accountID = "acct-travel"
    let row = SlipReaderMapping.map(
      [.init(amount: "5")],
      sentence: "$5 coffee",
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Card"),
      ],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )[0]
    XCTAssertFalse(row.parsedAccount)
    let applied = ComposeParseApply.applying(row, to: draft)
    XCTAssertEqual(applied.draft.accountID, "acct-travel")
    XCTAssertFalse(applied.showAccountPrompt)
  }

  func testApplyShowsChipsAndClearsAccountWhenAmbiguous() {
    var draft = TransactionDraft()
    draft.accountID = "acct-everyday"
    let row = SlipReaderMapping.map(
      [.init(amount: "5", account: "Account")],
      sentence: "5 on Account",
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Account"),
      ],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )[0]
    let applied = ComposeParseApply.applying(row, to: draft)
    XCTAssertEqual(applied.draft.accountID, "")
    XCTAssertTrue(applied.showAccountPrompt)
    XCTAssertEqual(applied.accountCandidates.map(\.id), ["acct-everyday", "acct-travel"])
  }

  func testApplyUniqueAccountOverwritesASeededPick() {
    var draft = TransactionDraft()
    draft.accountID = "acct-travel"
    let row = SlipReaderMapping.map(
      [.init(amount: "5", account: "Everyday Account")],
      sentence: "5 on Everyday Account",
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Card"),
      ],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )[0]
    let applied = ComposeParseApply.applying(row, to: draft)
    XCTAssertEqual(applied.draft.accountID, "acct-everyday")
    XCTAssertFalse(applied.showAccountPrompt)
  }

  func testApplyExplicitTravelCardInSentenceOverwritesADifferentSeed() {
    var draft = TransactionDraft()
    draft.accountID = "acct-everyday"
    let row = SlipReaderMapping.map(
      [.init(amount: "5", account: "Travel Card")],
      sentence: "5 on Travel Card",
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Card"),
      ],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )[0]
    let applied = ComposeParseApply.applying(row, to: draft)
    XCTAssertEqual(applied.draft.accountID, "acct-travel")
    XCTAssertFalse(applied.showAccountPrompt)
  }

  func testApplyKeepsSeededAccountWhenSentenceDoesNotNameOne() {
    var draft = TransactionDraft()
    draft.accountID = "acct-travel"
    let row = SlipReaderMapping.map(
      [.init(amount: "5", account: "Everyday Account")],
      sentence: "$5 coffee",
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Card"),
      ],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )[0]
    XCTAssertFalse(row.parsedAccount)
    XCTAssertEqual(row.draft.accountID, "")
    let applied = ComposeParseApply.applying(row, to: draft)
    XCTAssertEqual(applied.draft.accountID, "acct-travel")
    XCTAssertFalse(applied.showAccountPrompt)
    XCTAssertTrue(applied.accountCandidates.isEmpty)
  }

  func testApplyKeepsSeededAccountWhenHallucinatedAmbiguousNameIsAbsentFromSentence() {
    var draft = TransactionDraft()
    draft.accountID = "acct-everyday"
    let row = SlipReaderMapping.map(
      [.init(amount: "5", account: "Account")],
      sentence: "$5 coffee",
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Account"),
      ],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: Self.now
    )[0]
    XCTAssertFalse(row.parsedAccount)
    let applied = ComposeParseApply.applying(row, to: draft)
    XCTAssertEqual(applied.draft.accountID, "acct-everyday")
    XCTAssertFalse(applied.showAccountPrompt)
    XCTAssertTrue(applied.accountCandidates.isEmpty)
  }

  func testPromptPrefixPutsCatalogsBeforeTheSentenceAndOmitsPayees() {
    let prefix = SlipReaderPrompt.prefix(
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-closed", "Closed Card", closed: true),
      ],
      categoryGroups: [Self.everydayGroup]
    )
    XCTAssertTrue(prefix.contains("Accounts: Everyday Account"))
    XCTAssertFalse(prefix.contains("Closed Card"))
    XCTAssertTrue(prefix.contains("Categories: Groceries, Dining Out"))
    XCTAssertFalse(prefix.contains("Payees:"))
    XCTAssertFalse(prefix.contains("FairPrice"))
    XCTAssertTrue(prefix.hasSuffix("Sentence:\n"))
    XCTAssertTrue((prefix + "I spent 5").contains("Sentence:\nI spent 5"))
  }

  func testPromptLeavesAccountEmptyUnlessNamedAndParsesCurrencyAndDates() {
    let text = SlipReaderPrompt.instructions
    XCTAssertFalse(text.contains("when they match"))
    XCTAssertTrue(text.localizedCaseInsensitiveContains("leave account empty unless"))
    XCTAssertTrue(text.contains("S$"))
    XCTAssertTrue(text.localizedCaseInsensitiveContains("schedule"))
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
