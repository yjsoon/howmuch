import XCTest
@testable import HowMuch

final class PlanSettingsSeedTests: XCTestCase {
  private func seed(_ identifier: String) throws -> PlanSettingsSeed {
    try XCTUnwrap(PlanSettingsSeed.from(locale: Locale(identifier: identifier)))
  }

  func testSingapore() throws {
    let seed = try seed("en_SG")
    XCTAssertEqual(seed.currencyFormat.isoCode, "SGD")
    XCTAssertEqual(seed.currencyFormat.currencySymbol, "$")
    XCTAssertEqual(seed.currencyFormat.decimalDigits, 2)
    XCTAssertTrue(seed.currencyFormat.symbolFirst)
    XCTAssertEqual(seed.dateFormat.format, "DD/MM/YYYY")
  }

  func testUnitedStatesPutsTheMonthFirst() throws {
    let seed = try seed("en_US")
    XCTAssertEqual(seed.currencyFormat.isoCode, "USD")
    XCTAssertEqual(seed.currencyFormat.currencySymbol, "$")
    XCTAssertEqual(seed.currencyFormat.exampleFormat, "$123,456.78")
    XCTAssertEqual(seed.dateFormat.format, "MM/DD/YYYY")
  }

  func testUnitedKingdom() throws {
    let seed = try seed("en_GB")
    XCTAssertEqual(seed.currencyFormat.isoCode, "GBP")
    XCTAssertEqual(seed.currencyFormat.currencySymbol, "£")
    XCTAssertEqual(seed.dateFormat.format, "DD/MM/YYYY")
  }

  func testGermanyPutsTheSymbolLastWithCommaDecimals() throws {
    let seed = try seed("de_DE")
    XCTAssertEqual(seed.currencyFormat.isoCode, "EUR")
    XCTAssertEqual(seed.currencyFormat.currencySymbol, "€")
    XCTAssertEqual(seed.currencyFormat.decimalSeparator, ",")
    XCTAssertEqual(seed.currencyFormat.groupSeparator, ".")
    XCTAssertFalse(seed.currencyFormat.symbolFirst)
    // d.M.y has no exact match; day-first is the nearest the backend knows.
    XCTAssertEqual(seed.dateFormat.format, "DD/MM/YYYY")
  }

  func testJapanHasNoMinorUnits() throws {
    let seed = try seed("ja_JP")
    XCTAssertEqual(seed.currencyFormat.isoCode, "JPY")
    XCTAssertEqual(seed.currencyFormat.decimalDigits, 0)
    XCTAssertEqual(seed.dateFormat.format, "YYYY-MM-DD")
  }

  func testSymbolPosition() {
    XCTAssertTrue(PlanSettingsSeed.symbolFirst(in: "¤#,##0.00"))
    XCTAssertTrue(PlanSettingsSeed.symbolFirst(in: "¤ #,##0.00"))
    XCTAssertFalse(PlanSettingsSeed.symbolFirst(in: "#,##0.00 ¤"))
  }

  func testEncodesTheStoredShape() throws {
    let data = try JSONEncoder().encode(try seed("en_US"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let currency = try XCTUnwrap(object["currency_format"] as? [String: Any])
    XCTAssertEqual(
      Set(currency.keys),
      ["iso_code", "example_format", "decimal_digits", "decimal_separator", "symbol_first", "group_separator", "currency_symbol", "display_symbol"]
    )
    XCTAssertEqual((object["date_format"] as? [String: Any])?["format"] as? String, "MM/DD/YYYY")
  }
}
