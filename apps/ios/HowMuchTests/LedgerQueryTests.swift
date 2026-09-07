import XCTest
@testable import HowMuch

final class LedgerQueryTests: XCTestCase {
  func testThisMonthUsesCompleteLocalMonthBounds() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spendingThisMonth, category: "", account: "", merchant: "", from: "", to: ""),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected bounds")
    }
    XCTAssertEqual(value.from, "2025-05-01")
    XCTAssertEqual(value.to, "2025-05-04")
    XCTAssertEqual(value.accountLabel, "All accounts")
  }

  func testSuppliedDatesArePreservedForSpendingThisMonth() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spendingThisMonth, category: "", account: "", merchant: "", from: "2025-04-01", to: "2025-04-02"),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected supplied dates")
    }
    XCTAssertEqual(value.from, "2025-04-01")
    XCTAssertEqual(value.to, "2025-04-02")
  }

  func testTodayUsesLocalCalendarDay() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .today, category: "", account: "", merchant: "", from: "", to: ""),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected today")
    }
    XCTAssertEqual(value.from, "2025-05-04")
    XCTAssertEqual(value.to, "2025-05-04")
  }

  func testReversedDatesAreRejected() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spending, category: "", account: "", merchant: "", from: "2025-05-04", to: "2025-05-01"),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .failure = resolved else {
      return XCTFail("expected reversed dates to fail")
    }
  }

  func testCompareLabelsEqualLengthPriorPeriod() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .compareCategory, category: "Dining Out", account: "", merchant: "", from: "", to: ""),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected comparison")
    }
    XCTAssertEqual(value.from, "2025-05-01")
    XCTAssertEqual(value.to, "2025-05-04")
    XCTAssertEqual(value.priorFrom, "2025-04-27")
    XCTAssertEqual(value.priorTo, "2025-04-30")
  }

  func testCompareCategoryUsesPriorCompleteMonth() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .compareCategory, category: "Dining Out", account: "", merchant: "", from: "", to: ""),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected comparison")
    }
    XCTAssertEqual(value.from, "2025-05-01")
    XCTAssertEqual(value.to, "2025-05-04")
    XCTAssertEqual(value.priorFrom, "2025-04-27")
    XCTAssertEqual(value.priorTo, "2025-04-30")
    XCTAssertEqual(value.categoryIDs, ["cat-dining"])
  }

  func testAmbiguousAccountDoesNotFallback() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spendingThisMonth, category: "", account: "Account", merchant: "", from: "", to: ""),
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Account"),
      ],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected ambiguity")
    }
    XCTAssertTrue(value.accountIDs.isEmpty)
    XCTAssertEqual(value.unresolvedAccount.map(\.id), ["acct-everyday", "acct-travel"])
  }

  func testUnknownMerchantIsHonest() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .findMerchant, category: "", account: "", merchant: "", from: "", to: ""),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .failure(let error) = resolved else {
      return XCTFail("expected missing merchant")
    }
    XCTAssertTrue((error.localizedDescription ?? "").contains("merchant"))
  }

  func testRecordedSpendingTotalUsesReportIntegersNotQuietRows() {
    let report = SpendingBreakdownReport(
      total: 40_000,
      groups: [
        SpendingBreakdownGroup(
          categoryID: "cat-dining",
          categoryName: "Dining Out",
          categoryGroupID: "grp-spend",
          categoryGroupName: "Everyday",
          amount: -12_000,
          share: 0.3,
          transactionCount: 2
        ),
        SpendingBreakdownGroup(
          categoryID: "cat-hidden",
          categoryName: "Hidden",
          categoryGroupID: "grp-hidden",
          categoryGroupName: "Hidden Categories",
          amount: -28_000,
          share: 0.7,
          transactionCount: 1
        ),
      ]
    )
    XCTAssertEqual(LedgerQueryPlanner.recordedSpendingTotal(from: report, includeQuiet: false), 12_000)
    XCTAssertEqual(LedgerQueryPlanner.recordedSpendingTotal(from: report, includeQuiet: true), 40_000)
  }

  func testFetchCollectsMultiplePagesAndDedupes() async throws {
    let pages = [
      TransactionPage(transactions: [Self.transaction(id: "t1", payee: "A", amount: -1_000)], hasMore: true, nextOffset: 1, serverKnowledge: 7),
      TransactionPage(transactions: [Self.transaction(id: "t1", payee: "A", amount: -1_000), Self.transaction(id: "t2", payee: "B", amount: -2_000)], hasMore: false, nextOffset: nil, serverKnowledge: 7),
    ]
    let rows = try await LedgerQueryRunner.fetchAllTransactions(
      fetchPage: { offset in pages[offset] }
    )
    XCTAssertEqual(Set(rows.map(\.id)), ["t1", "t2"])
  }

  func testFetchFailsOnRepeatedOffset() async {
    do {
      _ = try await LedgerQueryRunner.fetchAllTransactions(
        fetchPage: { _ in
          TransactionPage(transactions: [Self.transaction(id: "t1", payee: "A", amount: -1_000)], hasMore: true, nextOffset: 0, serverKnowledge: 1)
        }
      )
      XCTFail("expected repeated offset")
    } catch {
      XCTAssertEqual(error as? LedgerQueryFetchError, .repeatedOffset)
    }
  }

  func testFetchFailsWhenHasMoreWithoutNextOffset() async {
    do {
      _ = try await LedgerQueryRunner.fetchAllTransactions(
        fetchPage: { _ in
          TransactionPage(transactions: [Self.transaction(id: "t1", payee: "A", amount: -1_000)], hasMore: true, nextOffset: nil, serverKnowledge: 1)
        }
      )
      XCTFail("expected missing offset")
    } catch {
      XCTAssertEqual(error as? LedgerQueryFetchError, .missingNextOffset)
    }
  }

  func testFetchRestartsWhenServerKnowledgeChanges() async throws {
    var calls = 0
    let rows = try await LedgerQueryRunner.fetchAllTransactions(
      fetchPage: { offset in
        calls += 1
        if calls == 1 {
          XCTAssertEqual(offset, 0)
          return TransactionPage(transactions: [Self.transaction(id: "old", payee: "A", amount: -1_000)], hasMore: true, nextOffset: 1, serverKnowledge: 1)
        }
        if calls == 2 {
          XCTAssertEqual(offset, 1)
          return TransactionPage(transactions: [Self.transaction(id: "stale", payee: "B", amount: -2_000)], hasMore: true, nextOffset: 2, serverKnowledge: 2)
        }
        XCTAssertEqual(offset, 0)
        return TransactionPage(transactions: [Self.transaction(id: "final", payee: "C", amount: -3_000)], hasMore: false, nextOffset: nil, serverKnowledge: 2)
      }
    )
    XCTAssertEqual(rows.map(\.id), ["final"])
    XCTAssertFalse(rows.contains { $0.id == "old" || $0.id == "stale" })
  }

  func testFetchHonoursCancellation() async {
    do {
      _ = try await LedgerQueryRunner.fetchAllTransactions(
        fetchPage: { _ in
          TransactionPage(transactions: [], hasMore: false, nextOffset: nil, serverKnowledge: 1)
        },
        isCancelled: { true }
      )
      XCTFail("expected cancellation")
    } catch {
      XCTAssertEqual(error as? LedgerQueryFetchError, .cancelled)
    }
  }

  func testExactAccountNameBeatsSubstring() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spending, category: "", account: "Everyday", merchant: "", from: "", to: ""),
      accounts: [
        Self.account("acct-everyday", "Everyday"),
        Self.account("acct-travel", "Everyday Travel"),
      ],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected exact match")
    }
    XCTAssertEqual(value.accountIDs, ["acct-everyday"])
    XCTAssertTrue(value.unresolvedAccount.isEmpty)
  }

  func testFourAccountMatchesStayAmbiguous() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spendingThisMonth, category: "", account: "Card", merchant: "", from: "", to: ""),
      accounts: [
        Self.account("a", "Card One"),
        Self.account("b", "Card Two"),
        Self.account("c", "Card Three"),
        Self.account("d", "Card Four"),
      ],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected ambiguity")
    }
    XCTAssertTrue(value.accountIDs.isEmpty)
    XCTAssertEqual(value.unresolvedAccount.count, 4)
  }

  func testYesterdayRangeIsPreservedAndNotRewrittenToThisMonth() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spending, category: "", account: "", merchant: "", from: "2025-05-03", to: "2025-05-03"),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected yesterday")
    }
    XCTAssertEqual(value.from, "2025-05-03")
    XCTAssertEqual(value.to, "2025-05-03")
    XCTAssertNotEqual(value.from, "2025-05-01")
  }

  func testLocalYesterdayMapsInReaderCalendar() {
    let date = SlipReaderMapping.date(from: "yesterday", calendar: Self.calendar, now: Self.now)
    XCTAssertEqual(LedgerQueryPlanner.isoFormatter(calendar: Self.calendar).string(from: date!), "2025-05-03")
  }

  func testExplicitQuietCategoryIsKeptInTotal() {
    let report = SpendingBreakdownReport(
      total: 40_000,
      groups: [
        SpendingBreakdownGroup(
          categoryID: "cat-dining",
          categoryName: "Dining Out",
          categoryGroupID: "grp-spend",
          categoryGroupName: "Everyday",
          amount: -12_000,
          share: 0.3,
          transactionCount: 2
        ),
        SpendingBreakdownGroup(
          categoryID: "cat-hidden",
          categoryName: "Hidden",
          categoryGroupID: "grp-hidden",
          categoryGroupName: "Hidden Categories",
          amount: -28_000,
          share: 0.7,
          transactionCount: 1
        ),
      ]
    )
    XCTAssertEqual(
      LedgerQueryPlanner.recordedSpendingTotal(
        from: report,
        includeQuiet: false,
        explicitCategoryIDs: ["cat-hidden"]
      ),
      28_000
    )
  }

  func testSourceRowsFollowReportScopeAndExcludeTransfers() {
    let dining = Self.transaction(id: "t-dining", payee: "Cafe", amount: -5_000, categoryID: "cat-dining")
    let grocery = Self.transaction(id: "t-grocery", payee: "FairPrice", amount: -8_000, categoryID: "cat-grocery")
    let transfer = Transaction(
      id: "t-transfer",
      date: "2025-05-03",
      amount: -9_000,
      memo: nil,
      cleared: .uncleared,
      approved: true,
      flagColor: nil,
      flagName: nil,
      accountID: "acct-everyday",
      accountName: "Everyday",
      payeeID: nil,
      payeeName: "Transfer : Savings",
      categoryID: nil,
      categoryName: nil,
      transferAccountID: "acct-savings",
      transferTransactionID: "t-mirror",
      parentTransactionID: nil,
      matchedTransactionID: nil,
      importID: nil,
      importPayeeName: nil,
      importPayeeNameOriginal: nil,
      deleted: false,
      subtransactions: []
    )
    let split = Transaction(
      id: "t-split",
      date: "2025-05-03",
      amount: -15_000,
      memo: nil,
      cleared: .uncleared,
      approved: true,
      flagColor: nil,
      flagName: nil,
      accountID: "acct-everyday",
      accountName: "Everyday",
      payeeID: nil,
      payeeName: "Market",
      categoryID: nil,
      categoryName: nil,
      transferAccountID: nil,
      transferTransactionID: nil,
      parentTransactionID: nil,
      matchedTransactionID: nil,
      importID: nil,
      importPayeeName: nil,
      importPayeeNameOriginal: nil,
      deleted: false,
      subtransactions: [
        Subtransaction(
          id: "s1",
          transactionID: "t-split",
          amount: -5_000,
          memo: nil,
          payeeID: nil,
          payeeName: "Cafe line",
          categoryID: "cat-dining",
          categoryName: "Dining Out",
          transferAccountID: nil,
          transferTransactionID: nil,
          deleted: false
        ),
        Subtransaction(
          id: "s2",
          transactionID: "t-split",
          amount: -10_000,
          memo: nil,
          payeeID: nil,
          payeeName: "Grocery line",
          categoryID: "cat-grocery",
          categoryName: "Groceries",
          transferAccountID: nil,
          transferTransactionID: nil,
          deleted: false
        ),
      ]
    )
    let groups = [
      Self.everydayGroup,
      CategoryGroup(
        id: "grp-food",
        name: "Food",
        hidden: false,
        deleted: false,
        categories: [
          Category(id: "cat-grocery", categoryGroupID: "grp-food", name: "Groceries", deleted: false),
        ]
      ),
    ]
    let resolution = LedgerQueryResolution(
      spec: LedgerQuerySpec(kind: .spending, category: "Dining Out", account: "", merchant: "", from: "2025-05-01", to: "2025-05-04"),
      from: "2025-05-01",
      to: "2025-05-04",
      priorFrom: nil,
      priorTo: nil,
      accountIDs: [],
      categoryIDs: ["cat-dining"],
      accountLabel: "All accounts",
      categoryLabel: "Dining Out",
      unresolvedAccount: [],
      unresolvedCategory: [],
      categoryWasExplicit: true
    )
    let rows = LedgerQueryPlanner.sourceRows(
      from: [dining, grocery, transfer, split],
      resolution: resolution,
      categoryGroups: groups,
      includeQuiet: false
    )
    XCTAssertEqual(Set(rows.map(\.payee)), ["Cafe", "Cafe line"])
    XCTAssertTrue(rows.contains { $0.isSplitPortion && $0.categoryName == "Dining Out" })
    XCTAssertFalse(rows.contains { $0.payee.contains("FairPrice") || $0.payee.contains("Transfer") })
  }

  func testEmptyFromAndEarlierToAreRejectedAfterDefaults() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spending, category: "", account: "", merchant: "", from: "", to: "2025-04-01"),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .failure = resolved else {
      return XCTFail("expected reversed defaulted bounds to fail")
    }
  }

  func testInvalidCalendarDateAndExtraTimeAreRejected() {
    let invalid = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spending, category: "", account: "", merchant: "", from: "2025-02-31", to: "2025-03-01"),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .failure = invalid else {
      return XCTFail("expected invalid calendar date to fail")
    }
    let timed = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spending, category: "", account: "", merchant: "", from: "2025-05-01T12:00", to: "2025-05-02"),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .failure = timed else {
      return XCTFail("expected extra time to fail")
    }
  }

  func testTodayDoesNotOverrideContradictoryExplicitDates() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .today, category: "", account: "", merchant: "", from: "2025-04-01", to: "2025-04-02"),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .failure = resolved else {
      return XCTFail("expected today plus contradictory dates to fail")
    }
  }

  func testClosedHistoricalAccountIsQueryable() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spending, category: "", account: "Old Card", merchant: "", from: "2025-05-01", to: "2025-05-04"),
      accounts: [
        Self.account("acct-everyday", "Everyday"),
        Self.account("acct-old", "Old Card", closed: true),
      ],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected closed account")
    }
    XCTAssertEqual(value.accountIDs, ["acct-old"])
  }

  func testChosenIdentityKeepsDuplicateNamesDistinct() {
    let resolution = LedgerQueryResolution(
      spec: LedgerQuerySpec(kind: .spending, category: "Dining", account: "Card", merchant: "", from: "2025-05-01", to: "2025-05-04"),
      from: "2025-05-01",
      to: "2025-05-04",
      priorFrom: nil,
      priorTo: nil,
      accountIDs: [],
      categoryIDs: [],
      accountLabel: "All accounts",
      categoryLabel: "Recorded spending",
      unresolvedAccount: [
        SlipCandidate(id: "acct-a", name: "Card"),
        SlipCandidate(id: "acct-b", name: "Card"),
      ],
      unresolvedCategory: [
        SlipCandidate(id: "cat-a", name: "Dining"),
        SlipCandidate(id: "cat-b", name: "Dining"),
      ],
      categoryWasExplicit: true
    )
    let afterAccount = LedgerQueryPlanner.applyingChosenIdentities(
      to: resolution,
      account: SlipCandidate(id: "acct-b", name: "Card")
    )
    XCTAssertEqual(afterAccount.accountIDs, ["acct-b"])
    XCTAssertTrue(afterAccount.unresolvedAccount.isEmpty)
    XCTAssertEqual(afterAccount.unresolvedCategory.map(\.id), ["cat-a", "cat-b"])
    let afterBoth = LedgerQueryPlanner.applyingChosenIdentities(
      to: afterAccount,
      category: SlipCandidate(id: "cat-a", name: "Dining")
    )
    XCTAssertEqual(afterBoth.categoryIDs, ["cat-a"])
    XCTAssertTrue(afterBoth.unresolvedCategory.isEmpty)
  }

  func testUncategorisedScopeIsPreserved() {
    let resolved = LedgerQueryPlanner.resolve(
      spec: LedgerQuerySpec(kind: .spending, category: "Uncategorised", account: "", merchant: "", from: "2025-05-01", to: "2025-05-04"),
      accounts: [Self.account("acct-everyday", "Everyday")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected uncategorised")
    }
    XCTAssertEqual(value.categoryIDs, [CategoryGroup.uncategorisedCategoryID])
  }

  func testSourceRowsUseParentFallbackAndSkipDeletedChildAndQuiet() {
    let split = Transaction(
      id: "t-split",
      date: "2025-05-03",
      amount: -15_000,
      memo: nil,
      cleared: .uncleared,
      approved: true,
      flagColor: nil,
      flagName: nil,
      accountID: "acct-everyday",
      accountName: "Everyday",
      payeeID: nil,
      payeeName: "Market",
      categoryID: "cat-dining",
      categoryName: "Dining Out",
      transferAccountID: nil,
      transferTransactionID: nil,
      parentTransactionID: nil,
      matchedTransactionID: nil,
      importID: nil,
      importPayeeName: nil,
      importPayeeNameOriginal: nil,
      deleted: false,
      subtransactions: [
        Subtransaction(
          id: "s-live",
          transactionID: "t-split",
          amount: -5_000,
          memo: nil,
          payeeID: nil,
          payeeName: nil,
          categoryID: nil,
          categoryName: nil,
          transferAccountID: nil,
          transferTransactionID: nil,
          deleted: false
        ),
        Subtransaction(
          id: "s-dead",
          transactionID: "t-split",
          amount: -10_000,
          memo: nil,
          payeeID: nil,
          payeeName: "Deleted line",
          categoryID: "cat-dining",
          categoryName: "Dining Out",
          transferAccountID: nil,
          transferTransactionID: nil,
          deleted: true
        ),
      ]
    )
    let transferSplit = Transaction(
      id: "t-transfer-split",
      date: "2025-05-03",
      amount: -8_000,
      memo: nil,
      cleared: .uncleared,
      approved: true,
      flagColor: nil,
      flagName: nil,
      accountID: "acct-everyday",
      accountName: "Everyday",
      payeeID: nil,
      payeeName: "Market",
      categoryID: nil,
      categoryName: nil,
      transferAccountID: "acct-savings",
      transferTransactionID: "t-mirror",
      parentTransactionID: nil,
      matchedTransactionID: nil,
      importID: nil,
      importPayeeName: nil,
      importPayeeNameOriginal: nil,
      deleted: false,
      subtransactions: [
        Subtransaction(
          id: "s-transfer",
          transactionID: "t-transfer-split",
          amount: -8_000,
          memo: nil,
          payeeID: nil,
          payeeName: nil,
          categoryID: nil,
          categoryName: nil,
          transferAccountID: nil,
          transferTransactionID: nil,
          deleted: false
        ),
      ]
    )
    let quiet = Self.transaction(id: "t-quiet", payee: "Hidden shop", amount: -4_000, categoryID: "cat-hidden")
    let deadParent = Transaction(
      id: "t-tombstone",
      date: "2025-05-03",
      amount: -3_000,
      memo: nil,
      cleared: .uncleared,
      approved: true,
      flagColor: nil,
      flagName: nil,
      accountID: "acct-everyday",
      accountName: "Everyday",
      payeeID: nil,
      payeeName: "Gone",
      categoryID: "cat-dining",
      categoryName: "Dining Out",
      transferAccountID: nil,
      transferTransactionID: nil,
      parentTransactionID: nil,
      matchedTransactionID: nil,
      importID: nil,
      importPayeeName: nil,
      importPayeeNameOriginal: nil,
      deleted: true,
      subtransactions: []
    )
    let groups = [
      Self.everydayGroup,
      CategoryGroup(
        id: "grp-hidden",
        name: "Hidden Categories",
        hidden: false,
        deleted: false,
        categories: [Category(id: "cat-hidden", categoryGroupID: "grp-hidden", name: "Hidden", deleted: false)]
      ),
    ]
    let resolution = LedgerQueryResolution(
      spec: LedgerQuerySpec(kind: .spending, category: "", account: "", merchant: "", from: "2025-05-01", to: "2025-05-04"),
      from: "2025-05-01",
      to: "2025-05-04",
      priorFrom: nil,
      priorTo: nil,
      accountIDs: [],
      categoryIDs: [],
      accountLabel: "All accounts",
      categoryLabel: "Recorded spending",
      unresolvedAccount: [],
      unresolvedCategory: [],
      categoryWasExplicit: false
    )
    let rows = LedgerQueryPlanner.sourceRows(
      from: [split, transferSplit, quiet, deadParent],
      resolution: resolution,
      categoryGroups: groups,
      includeQuiet: false
    )
    XCTAssertEqual(rows.map(\.payee), ["Market"])
    XCTAssertEqual(rows.first?.categoryName, "Dining Out")
    XCTAssertTrue(rows.first?.isSplitPortion == true)
    XCTAssertFalse(rows.contains { $0.payee == "Deleted line" || $0.payee == "Hidden shop" || $0.payee == "Gone" })
  }

  func testMerchantMatchUsesPayeeNotRegisterCache() {
    let rows = [
      Self.transaction(id: "t1", payee: "Starbucks Orchard", amount: -5_000),
      Self.transaction(id: "t2", payee: "FairPrice", amount: -8_000),
    ]
    XCTAssertEqual(LedgerQueryRunner.matchingMerchant(rows, query: "starbucks").map(\.id), ["t1"])
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

  private static func transaction(id: String, payee: String, amount: Int, categoryID: String = "cat-dining") -> Transaction {
    Transaction(
      id: id,
      date: "2025-05-03",
      amount: amount,
      memo: nil,
      cleared: .uncleared,
      approved: true,
      flagColor: nil,
      flagName: nil,
      accountID: "acct-everyday",
      accountName: "Everyday",
      payeeID: nil,
      payeeName: payee,
      categoryID: categoryID,
      categoryName: categoryID == "cat-dining" ? "Dining Out" : "Groceries",
      transferAccountID: nil,
      transferTransactionID: nil,
      parentTransactionID: nil,
      matchedTransactionID: nil,
      importID: nil,
      importPayeeName: nil,
      importPayeeNameOriginal: nil,
      deleted: false,
      subtransactions: []
    )
  }
}
