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
      Row("GRAB*A-5X7K9QWE SINGAPORE SG", "8.90", .outflow, "2026-10-05"),
      Row("KOPITIAM 12345", "4.50", .outflow, "2026-10-04"),
    ])
  }

  func testUOBStyleCreditLineIsAnInflow() {
    let rows = extract("""
    06/10 PAYMENT - THANK YOU 250.00 CR
    07/10 SHENG SIONG SUPERMARKE 31.45
    """)
    XCTAssertEqual(rows, [
      Row("PAYMENT - THANK YOU", "250.00", .inflow, "2026-10-06"),
      Row("SHENG SIONG SUPERMARKE", "31.45", .outflow, "2026-10-07"),
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
    XCTAssertEqual(rows, [Row("COLD STORAGE", "9.30", .outflow, "2026-10-05")])
  }

  // MARK: OCR look-alikes

  func testCyrillicLookalikesInAMostlyLatinLineAreFolded() {
    // Vision on the simulator read the month as Cyrillic O, S-like C and T.
    let rows = extract("05 \u{041E}\u{0421}\u{0422} KOPITIAM AMK -8.90")
    XCTAssertEqual(rows, [Row("KOPITIAM AMK", "8.90", .outflow, "2026-10-05")])
  }

  func testGreekLookalikesInAMostlyLatinLineAreFolded() {
    let rows = extract("05 OC\u{03A4} KOPITIAM AMK 4.50")
    XCTAssertEqual(rows, [Row("KOPITIAM AMK", "4.50", .outflow, "2026-10-05")])
  }

  func testGenuinelyCyrillicMerchantsKeepTheirLetters() {
    // More Cyrillic than Latin letters: not OCR confusion, so nothing is folded.
    let magnit = "\u{041C}\u{0410}\u{0413}\u{041D}\u{0418}\u{0422}"
    XCTAssertEqual(
      extract("07 OCT \(magnit) 120.00"),
      [Row(magnit, "120.00", .outflow, "2026-10-07")]
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
    XCTAssertEqual(sameLine, [Row("ADOBE", "16.20", .outflow, "2026-10-04")])
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

  // MARK: Running balances

  func testRunningBalanceColumnIsNotTheAmount() {
    XCTAssertEqual(
      extract("05/10/2026 FAST PAYMENT TO JOHN 50.00 1,234.56"),
      [Row("FAST PAYMENT TO JOHN", "50.00", .outflow, "2026-10-05")]
    )
    XCTAssertEqual(
      extract("05/10/2026 FAST PAYMENT TO JOHN 50.00 1,234.56 CR"),
      [Row("FAST PAYMENT TO JOHN", "50.00", .outflow, "2026-10-05")]
    )
  }

  func testThreeAmountsOnOneLineAreAmbiguousAndDropped() {
    XCTAssertEqual(extract("05 OCT SOMETHING 10.00 20.00 1,234.56"), [])
  }

  func testBalanceLinesInTheirCommonSpellingsAreIgnored() {
    for line in ["Avail Bal SGD 1,234.56", "Available balance", "Bal", "Balance B/F", "Closing bal 880.00"] {
      XCTAssertEqual(extract("Grab\n\(line)\n-$8.90"), [], line)
    }
  }

  // MARK: Foreign amounts

  func testForeignSymbolsAndCodesAreNeverReadAsSGD() {
    let foreign = [
      "RM 45.00", "RM45.00", "\u{20AC}12.00", "\u{00A3}12.50", "\u{00A5}1200.00", "\u{20A9}12000.00",
      "\u{0E3F}350.00", "\u{20B9}450.00", "Rp 15000.00", "\u{20B1}450.00", "MYR 45.00", "THB 350.00",
      "IDR 150000.00", "JPY 1200.00", "EUR 12.00", "GBP 12.50", "USD 12.00", "AUD 12.00",
      "12.00 EUR", "45.00 MYR",
    ]
    for amount in foreign {
      XCTAssertEqual(extract("05 OCT KEDAI MAKAN JB \(amount)"), [], amount)
    }
    XCTAssertEqual(extract("ADOBE\n\u{20AC}12.00"), [])
  }

  func testForeignRowIsCompletedByAnSGDFigureOnTheNextLine() {
    XCTAssertEqual(
      extract("HARRODS \u{00A3}12.50\nS$21.70"),
      [Row("HARRODS", "21.70", .outflow, nil)]
    )
  }

  func testForeignExchangeLinesAreIgnoredWithoutLosingThePendingPayee() {
    for line in ["Exchange rate 1.36", "FX rate 1.36", "Rate 1.3567", "Conversion fee 0.50"] {
      XCTAssertEqual(
        extract("NETFLIX.COM USD 15.99\n\(line)\nS$21.70"),
        [Row("NETFLIX.COM", "21.70", .outflow, nil)],
        line
      )
    }
  }

  func testPostcodesAndLoneForeignAmountsDoNotReplaceThePendingPayee() {
    XCTAssertEqual(extract("Grab\nSingapore 238801\n-$8.90"), [Row("Grab", "8.90", .outflow, nil)])
    XCTAssertEqual(extract("Grab\n12.00 USD\n-$8.90"), [Row("Grab", "8.90", .outflow, nil)])
  }

  func testForeignCodeBetweenTwoAmountsMarksTheFirstAsForeign() {
    XCTAssertEqual(
      extract("05 OCT ADOBE 12.00 USD 16.20"),
      [Row("ADOBE", "16.20", .outflow, "2026-10-05")]
    )
  }

  func testCodeAfterAnSGDAmountBelongsToTheForeignAmountThatFollows() {
    for line in ["NETFLIX S$21.70 USD 15.99", "NETFLIX SGD 21.70 USD 15.99"] {
      XCTAssertEqual(
        extract("05 OCT \(line)"),
        [Row("NETFLIX", "21.70", .outflow, "2026-10-05")],
        line
      )
    }
  }

  func testMerchantsThatStartWithACurrencyWordAreNormalRows() {
    XCTAssertEqual(extract("05 OCT YUAN CHUN LOR MEE 5.00"), [Row("YUAN CHUN LOR MEE", "5.00", .outflow, "2026-10-05")])
    XCTAssertEqual(extract("05 OCT EURO SPORTS 45.00"), [Row("EURO SPORTS", "45.00", .outflow, "2026-10-05")])
    XCTAssertEqual(extract("05 OCT RINGGIT CAFE 8.00"), [Row("RINGGIT CAFE", "8.00", .outflow, "2026-10-05")])
  }

  func testCurrencySymbolStuckToTheWordIsStillForeign() {
    for line in ["HARRODS\u{00A3}12.50", "HARRODS\u{20AC}12.50", "SHOP\u{00A5}1200.00", "SHOP\u{20A9}12000.00", "KEDAI JBRM45.00"] {
      XCTAssertEqual(extract("05 OCT \(line)"), [], line)
    }
    // A word that merely ends in RM, with a space before the amount, is SGD.
    XCTAssertEqual(extract("05 OCT FARM 45.00"), [Row("FARM", "45.00", .outflow, "2026-10-05")])
  }

  func testSpelledOutCurrencyLinesAreForeignAmountsNotSGD() {
    for line in ["U. S. DOLLAR 15.99", "US DOLLAR 15.99", "EURO 12.00", "JAPANESE YEN 1,500"] {
      XCTAssertEqual(extract("NETFLIX\n\(line)"), [], line)
      XCTAssertEqual(
        extract("NETFLIX\n\(line)\nS$21.70"),
        [Row("NETFLIX", "21.70", .outflow, nil)],
        line
      )
    }
    XCTAssertEqual(extract("EURO 12.00"), [])
  }

  // MARK: Dates

  func testYearlessDateMoreThanAWeekAheadUsesThePreviousYear() {
    XCTAssertEqual(
      extract("28 Dec GRAB 8.90", now: Self.january),
      [Row("GRAB", "8.90", .outflow, "2026-12-28")]
    )
    XCTAssertEqual(extract("10 OCT GRAB 8.90"), [Row("GRAB", "8.90", .outflow, "2026-10-10")])
    XCTAssertEqual(extract("20 OCT GRAB 8.90"), [Row("GRAB", "8.90", .outflow, "2025-10-20")])
  }

  func testAnImplausibleYearIsTextNotPartOfTheDate() {
    XCTAssertEqual(
      extract("05 OCT 4512 GRAB*TRIP 8.90"),
      [Row("4512 GRAB*TRIP", "8.90", .outflow, "2026-10-05")]
    )
  }

  func testDateHeaderAfterAnUnrelatedTextLineStillDatesTheRow() {
    XCTAssertEqual(
      extract("Transaction history\n5 Oct\nKOPITIAM -8.90"),
      [Row("KOPITIAM", "8.90", .outflow, "2026-10-05")]
    )
  }

  func testDottedShortDateIsADateNotAnAmount() {
    XCTAssertEqual(extract("05.10.26 GRAB 8.90"), [Row("GRAB", "8.90", .outflow, "2026-10-05")])
    XCTAssertEqual(extract("05.10.26\nGRAB -8.90"), [Row("GRAB", "8.90", .outflow, "2026-10-05")])
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

  /// 2026-10-07 and 2027-01-05, UTC.
  private static let october = Date(timeIntervalSince1970: 1_791_331_200)
  private static let january = Date(timeIntervalSince1970: 1_799_107_200)

  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func extract(_ text: String, now: Date = IntakeLineParserTests.october) -> [Row] {
    IntakeLineParser.extract(text, calendar: Self.calendar, now: now).map { extraction in
      Row(
        extraction.payee,
        extraction.amount,
        extraction.mentionedDirection ?? .outflow,
        extraction.date.isEmpty ? nil : extraction.date
      )
    }
  }
}
