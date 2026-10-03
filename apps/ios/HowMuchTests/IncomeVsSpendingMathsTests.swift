import XCTest
@testable import HowMuch

final class IncomeVsSpendingMathsTests: XCTestCase {
  func testYearToDateNetSumsOnlyCurrentYearKeysAndIgnoresCumulative() {
    let periods = [
      period("2025-11", income: 100, spending: 40, net: 60, cumulative: 60),
      period("2025-12", income: 80, spending: 90, net: -10, cumulative: 50),
      period("2026-01", income: 50, spending: 10, net: 40, cumulative: 90),
      period("2026-02", income: 20, spending: 5, net: 15, cumulative: 105),
    ]
    XCTAssertEqual(IncomeVsSpendingMaths.yearToDateNet(periods: periods, year: 2026), 55)
    XCTAssertEqual(IncomeVsSpendingMaths.yearToDateNet(periods: periods, year: 2027), 0)
    XCTAssertFalse(IncomeVsSpendingMaths.hasActivity(periods: periods, matching: "2027"))
    XCTAssertTrue(IncomeVsSpendingMaths.hasActivity(periods: periods, matching: "2026"))
  }

  func testFirstJanuaryYearSumIsZeroWhenCachedPeriodsAreLastYear() {
    let trailing = [
      period("2025-02", income: 10, spending: 0, net: 10, cumulative: 10),
      period("2025-12", income: 10, spending: 0, net: 10, cumulative: 20),
    ]
    XCTAssertEqual(IncomeVsSpendingMaths.yearToDateNet(periods: trailing, year: 2026), 0)
    XCTAssertFalse(IncomeVsSpendingMaths.hasActivity(periods: trailing, matching: "2026"))
  }

  func testSavingsRateAndZeroIncomeDash() {
    XCTAssertEqual(IncomeVsSpendingMaths.savingsRateLabel(net: 1_750_000, income: 8_200_000), "21.3%")
    XCTAssertEqual(IncomeVsSpendingMaths.savingsRateLabel(net: -450_000, income: 3_630_000), "-12.4%")
    XCTAssertEqual(IncomeVsSpendingMaths.savingsRateLabel(net: -100, income: 0), "—")
  }

  func testZeroFillInsertsEmptyMonthsBetweenFirstAndLastInRange() {
    let periods = [
      period("2026-01", income: 10, spending: 2, net: 8, cumulative: 8),
      period("2026-03", income: 4, spending: 1, net: 3, cumulative: 11),
    ]
    let rows = IncomeVsSpendingMaths.zeroFill(
      periods: periods,
      interval: .month,
      from: "2026-01-01",
      to: "2026-03-31"
    )
    XCTAssertEqual(rows.map(\.period), ["2026-01", "2026-02", "2026-03"])
    XCTAssertEqual(rows[1].isEmpty, true)
    XCTAssertEqual(rows[1].income, 0)
    XCTAssertEqual(rows[1].spending, 0)
    XCTAssertEqual(rows[0].from, "2026-01-01")
    XCTAssertEqual(rows[0].to, "2026-01-31")
    XCTAssertEqual(rows[2].from, "2026-03-01")
    XCTAssertEqual(rows[2].to, "2026-03-31")
  }

  func testZeroFillLeavesACompletelyEmptyReportEmpty() {
    let rows = IncomeVsSpendingMaths.zeroFill(
      periods: [],
      interval: .month,
      from: "2026-01-01",
      to: "2026-12-31"
    )
    XCTAssertTrue(rows.isEmpty)
  }

  func testSqliteWeekKeysMatchKnownSQLiteValues() {
    XCTAssertEqual(IncomeVsSpendingMaths.sqliteWeekKey(for: "2026-01-01"), "2026-W00")
    XCTAssertEqual(IncomeVsSpendingMaths.sqliteWeekKey(for: "2026-01-05"), "2026-W01")
    XCTAssertEqual(IncomeVsSpendingMaths.sqliteWeekKey(for: "2026-06-08"), "2026-W23")
    XCTAssertEqual(IncomeVsSpendingMaths.sqliteWeekKey(for: "2026-12-31"), "2026-W52")
  }

  func testYearSectionsNewestYearFirstWhenRowsAreNewestFirst() {
    let rows = IncomeVsSpendingMaths.zeroFill(
      periods: [
        period("2025-12", income: 10, spending: 0, net: 10, cumulative: 10),
        period("2026-01", income: 4, spending: 1, net: 3, cumulative: 13),
      ],
      interval: .month,
      from: "2025-12-01",
      to: "2026-01-31"
    ).reversed()
    let sections = IncomeVsSpendingMaths.yearSections(rows: Array(rows))
    XCTAssertEqual(sections.map(\.year), ["2026", "2025"])
    XCTAssertEqual(sections[0].net, 3)
    XCTAssertEqual(sections[1].net, 10)
  }

  func testRunningNetStopsAtSelectedPeriod() {
    let rows = [
      IncomeVsSpendingMaths.PeriodRow(period: "2026-01", from: "2026-01-01", to: "2026-01-31", income: 10, spending: 2, net: 8, isEmpty: false),
      IncomeVsSpendingMaths.PeriodRow(period: "2026-02", from: "2026-02-01", to: "2026-02-28", income: 4, spending: 1, net: 3, isEmpty: false),
      IncomeVsSpendingMaths.PeriodRow(period: "2026-03", from: "2026-03-01", to: "2026-03-31", income: 1, spending: 6, net: -5, isEmpty: false),
    ]
    XCTAssertEqual(IncomeVsSpendingMaths.runningNet(rows: rows, through: "2026-02"), 11)
  }

  func testFilterLineAndInProgressCaption() {
    XCTAssertEqual(IncomeVsSpendingMaths.filterLine(accountCount: 2, categoryCount: 3), "Filtered: 2 accounts, 3 categories")
    XCTAssertEqual(IncomeVsSpendingMaths.filterLine(accountCount: 1, categoryCount: 0), "Filtered: 1 account")
    XCTAssertNil(IncomeVsSpendingMaths.filterLine(accountCount: 0, categoryCount: 0))
    XCTAssertEqual(IncomeVsSpendingMaths.inProgressCaption(from: "2026-10-01", to: "2026-10-03"), "1–3 Oct so far")
  }

  func testRegisterFilterExcludesPlainTransfersAndRespectsSign() throws {
    let salary = try transaction(id: "in", amount: 8_000, categoryID: "salary", payeeID: "acme")
    let coffee = try transaction(id: "out", amount: -2_000, categoryID: "dining", payeeID: "cafe")
    let transfer = try transaction(
      id: "xfer", amount: -1_000, categoryID: nil, payeeID: nil,
      transferAccountID: "savings", transferTransactionID: "mirror"
    )
    let uncategorised = try transaction(id: "misc", amount: -500, categoryID: nil, payeeID: nil)

    XCTAssertTrue(RegisterReportFilter.include(salary, amountFilter: .income, excludePlainTransfers: true))
    XCTAssertFalse(RegisterReportFilter.include(salary, amountFilter: .spending, excludePlainTransfers: true))
    XCTAssertTrue(RegisterReportFilter.include(coffee, amountFilter: .spending, excludePlainTransfers: true))
    XCTAssertFalse(RegisterReportFilter.include(transfer, amountFilter: .spending, excludePlainTransfers: true))
    XCTAssertTrue(RegisterReportFilter.include(
      uncategorised,
      categoryID: CategoryGroup.uncategorisedCategoryID,
      amountFilter: .spending,
      excludePlainTransfers: true
    ))
    XCTAssertFalse(RegisterReportFilter.include(
      transfer,
      categoryID: CategoryGroup.uncategorisedCategoryID,
      amountFilter: .spending,
      excludePlainTransfers: true
    ))
    XCTAssertTrue(RegisterReportFilter.include(salary, payeeID: "acme", amountFilter: .income, excludePlainTransfers: true))
    XCTAssertTrue(RegisterReportFilter.include(uncategorised, missingPayee: true, amountFilter: .spending, excludePlainTransfers: true))
    XCTAssertFalse(RegisterReportFilter.include(salary, missingPayee: true, amountFilter: .income, excludePlainTransfers: true))
  }

  private func period(_ key: String, income: Int, spending: Int, net: Int, cumulative: Int) -> IncomeVsSpendingPeriod {
    IncomeVsSpendingPeriod(period: key, income: income, spending: spending, net: net, cumulativeNet: cumulative)
  }

  private func transaction(
    id: String,
    amount: Int,
    categoryID: String?,
    payeeID: String?,
    transferAccountID: String? = nil,
    transferTransactionID: String? = nil
  ) throws -> Transaction {
    var object: [String: Any] = [
      "id": id, "date": "2026-06-10", "amount": amount, "cleared": "uncleared", "approved": true,
      "accountId": "cash", "accountName": "Cash", "deleted": false, "subtransactions": [],
    ]
    if let categoryID { object["categoryId"] = categoryID }
    if let payeeID { object["payeeId"] = payeeID }
    if let transferAccountID { object["transferAccountId"] = transferAccountID }
    if let transferTransactionID { object["transferTransactionId"] = transferTransactionID }
    return try JSONDecoder().decode(Transaction.self, from: JSONSerialization.data(withJSONObject: object))
  }
}
