import XCTest
@testable import HowMuch

/// Failure mode: malformed external input. OCR of bank and wallet screenshots
/// is noisy in ways the E2E flows cannot cover exhaustively: two-line rows,
/// header and total lines, foreign amounts, stray glyphs. The expectations are
/// what a person reading each synthetic screenshot would write down, not what
/// the parser happens to return. The worst outcomes guarded against are a
/// foreign amount saved as dollars, a balance saved as a spend, and an amount
/// attached to the wrong payee.
final class IntakeLineParserTests: XCTestCase {
  // MARK: Card statement lines

  func testDBSStyleCardLinesWithLeadingDateAndTrailingAmount() {
    let rows = extract("""
    05 OCT GRAB*A-5X7K9QWE SINGAPORE SG -8.90
    04 OCT KOPITIAM 12345 4.50
    """)
    XCTAssertEqual(rows, [
      Row("GRAB*A-5X7K9QWE SINGAPORE SG", "8.90", .outflow, "5 Oct"),
      Row("KOPITIAM 12345", "4.50", .outflow, "4 Oct"),
    ])
  }

  func testUOBStyleCreditLineIsAnInflow() {
    let rows = extract("""
    06/10 PAYMENT - THANK YOU 250.00 CR
    07/10 SHENG SIONG SUPERMARKE 31.45
    """)
    XCTAssertEqual(rows, [
      Row("PAYMENT - THANK YOU", "250.00", .inflow, "6 Oct"),
      Row("SHENG SIONG SUPERMARKE", "31.45", .outflow, "7 Oct"),
    ])
  }

  func testThousandsSeparatorsAndCurrencyPrefixes() {
    let rows = extract("""
    01 Oct 2026 SINGAPORE AIRLINES 1,234.50
    02 Oct 2026 TAXI S$12.60
    03 Oct 2026 BOOKS SGD 7.00
    """)
    XCTAssertEqual(rows, [
      Row("SINGAPORE AIRLINES", "1234.50", .outflow, "2026-10-01"),
      Row("TAXI", "12.60", .outflow, "2026-10-02"),
      Row("BOOKS", "7.00", .outflow, "2026-10-03"),
    ])
  }

  func testIsoDateAndPlusSignInflow() {
    let rows = extract("2026-10-05 INTEREST EARNED +5.78")
    XCTAssertEqual(rows, [Row("INTEREST EARNED", "5.78", .inflow, "2026-10-05")])
  }

  func testMonthFirstDateAndUnicodeMinus() {
    let rows = extract("Oct 5 COLD STORAGE \u{2212}$9.30")
    XCTAssertEqual(rows, [Row("COLD STORAGE", "9.30", .outflow, "5 Oct")])
  }

  // MARK: OCR look-alikes

  func testCyrillicLookalikesInAMostlyLatinLineAreFolded() {
    // Vision on the simulator read the month as Cyrillic O, S-like C and T.
    let rows = extract("05 \u{041E}\u{0421}\u{0422} KOPITIAM AMK -8.90")
    XCTAssertEqual(rows, [Row("KOPITIAM AMK", "8.90", .outflow, "5 Oct")])
  }

  func testGreekLookalikesInAMostlyLatinLineAreFolded() {
    let rows = extract("05 OC\u{03A4} KOPITIAM AMK 4.50")
    XCTAssertEqual(rows, [Row("KOPITIAM AMK", "4.50", .outflow, "5 Oct")])
  }

  func testGenuinelyCyrillicMerchantsKeepTheirLetters() {
    // More Cyrillic than Latin letters: not OCR confusion, so nothing is folded.
    let magnit = "\u{041C}\u{0410}\u{0413}\u{041D}\u{0418}\u{0422}"
    XCTAssertEqual(
      extract("07 OCT \(magnit) 120.00"),
      [Row(magnit, "120.00", .outflow, "7 Oct")]
    )
    let pyaterochka = "\u{041F}\u{042F}\u{0422}\u{0415}\u{0420}\u{041E}\u{0427}\u{041A}\u{0410}"
    XCTAssertEqual(
      extract("\(pyaterochka) 120.00"),
      [Row(pyaterochka, "120.00", .outflow, nil)]
    )
  }

  // MARK: Wallet two-line rows

  func testWalletRowsWithPayeeAndAmountOnAdjacentLinesUnderADateHeader() {
    let rows = extract("""
    Today
    Grab
    -$8.90
    PayNow to TAN AH KOW
    -$12.60
    Yesterday
    Top up
    +$20.00
    """)
    XCTAssertEqual(rows, [
      Row("Grab", "8.90", .outflow, "today"),
      Row("PayNow to TAN AH KOW", "12.60", .outflow, "today"),
      Row("Top up", "20.00", .inflow, "yesterday"),
    ])
  }

  func testDateAndTimeBetweenPayeeAndAmountBelongToThatRow() {
    let rows = extract("""
    Kopitiam
    5 Oct 2026, 12:30 PM
    -$4.50
    """)
    XCTAssertEqual(rows, [Row("Kopitiam", "4.50", .outflow, "2026-10-05")])
  }

  func testStatusAndReferenceLinesDoNotBecomePayees() {
    let rows = extract("""
    Grab
    Completed
    Ref: 123456789012
    -$8.90
    """)
    XCTAssertEqual(rows, [Row("Grab", "8.90", .outflow, nil)])
  }

  // MARK: Things that must not become spends

  func testForeignAmountWithoutASGDFigureIsSkipped() {
    XCTAssertEqual(extract("04 OCT NETFLIX USD 12.00"), [])
    XCTAssertEqual(extract("04 OCT ADOBE 12.00 EUR"), [])
  }

  func testForeignAmountIsCompletedByTheSGDFigureThatFollows() {
    let sameLine = extract("04 OCT ADOBE USD 12.00 S$16.20")
    XCTAssertEqual(sameLine, [Row("ADOBE", "16.20", .outflow, "4 Oct")])
    let nextLine = extract("""
    AMAZON USD 12.00
    SGD 16.20
    """)
    XCTAssertEqual(nextLine, [Row("AMAZON", "16.20", .outflow, nil)])
  }

  func testBalancesTotalsHeadersAndFootersAreIgnored() {
    let rows = extract("""
    STATEMENT OF ACCOUNT
    Opening Balance 1,000.00
    Total 120.00
    Available balance 880.00
    Closing balance 880.00
    Minimum payment 50.00
    Page 1 of 3
    """)
    XCTAssertEqual(rows, [])
  }

  func testGarbageLinesAreSkippedWithoutLosingNeighbouringRows() {
    let rows = extract("""
    |||
    05 OCT GRAB -8.90
    @@
    `
    06 OCT KOPITIAM 4.50
    ~ .
    """)
    XCTAssertEqual(rows.map(\.payee), ["GRAB", "KOPITIAM"])
  }

  func testAmountWithNoPayeeAnywhereIsSkipped() {
    XCTAssertEqual(extract("-$8.90"), [])
  }

  func testWholeNumbersWithoutCurrencyAreCodesNotAmounts() {
    // A store number or reference is not money.
    XCTAssertEqual(extract("05 OCT KOPITIAM 12345"), [])
  }

  func testTotalBetweenRowsDoesNotStealOrLeakAPayee() {
    let rows = extract("""
    Grab
    Total 120.00
    -$8.90
    """)
    XCTAssertEqual(rows, [])
  }

  // MARK: Mapping

  func testInterpretMapsDatesAndDirectionThroughTheSharedReaderMapping() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_791_331_200) // 2026-10-07
    let mapped = IntakeLineParser.interpret(
      text: "05 OCT GRAB -8.90\n06 OCT PAYMENT 250.00 CR",
      accounts: [],
      categoryGroups: [],
      payees: [],
      calendar: calendar,
      now: now
    )
    XCTAssertEqual(mapped.map(\.draft.amountMagnitudeMilli), [8_900, 250_000])
    XCTAssertEqual(mapped.map(\.draft.direction), [.outflow, .inflow])
    XCTAssertEqual(mapped.map(\.parsedDate), [true, true])
    XCTAssertEqual(mapped.map { calendar.component(.day, from: $0.draft.date) }, [5, 6])
    XCTAssertEqual(mapped.map { calendar.component(.month, from: $0.draft.date) }, [10, 10])
  }

  // MARK: Helpers

  private struct Row: Equatable {
    var payee: String
    var amount: String
    var direction: EntryDirection
    var date: String?

    init(_ payee: String, _ amount: String, _ direction: EntryDirection, _ date: String?) {
      self.payee = payee
      self.amount = amount
      self.direction = direction
      self.date = date
    }
  }

  private func extract(_ text: String) -> [Row] {
    IntakeLineParser.extract(text).map { extraction in
      Row(
        extraction.payee,
        extraction.amount,
        extraction.mentionedDirection ?? .outflow,
        extraction.date.isEmpty ? nil : extraction.date
      )
    }
  }
}
