import XCTest
@testable import HowMuch

final class RegisterQueryTests: XCTestCase {
  private let format = CurrencyFormat(
    isoCode: "SGD",
    exampleFormat: "$123,456.78",
    decimalDigits: 2,
    decimalSeparator: ".",
    groupSeparator: ",",
    symbolFirst: true,
    currencySymbol: "$"
  )

  func testParsesTypedMoneyPrecision() {
    XCTAssertEqual(RegisterQuery.parse("142", currencyFormat: format)?.amount, range(142_000, 143_000, .any))
    XCTAssertEqual(RegisterQuery.parse("142.30", currencyFormat: format)?.amount, range(142_300, 142_310, .any))
    XCTAssertEqual(RegisterQuery.parse("$142.30", currencyFormat: format)?.amount, range(142_300, 142_310, .any))
    XCTAssertEqual(RegisterQuery.parse("-142.30", currencyFormat: format)?.amount?.sign, .outflow)
  }

  func testMatchesFairPricePayeeAndDisplayedAmounts() throws {
    let fairPrice = try transaction(payee: "FairPrice Finest", amount: -142_300, memo: "weekly shop")
    for raw in ["FairPrice", "142.30", "142", "$142.30"] {
      let query = RegisterQuery.parse(raw, currencyFormat: format)
      XCTAssertNotNil(query)
      XCTAssertTrue(query!.matches(fairPrice.registerSearchFields), raw)
    }
  }

  func testDoesNotTreatMilliunitDigitsAsText() throws {
    let twelve = RegisterQuery.parse("12", currencyFormat: format)!
    XCTAssertFalse(twelve.matches(try transaction(payee: "FairPrice Finest", amount: -142_300).registerSearchFields))
    XCTAssertFalse(twelve.matches(try transaction(payee: "Big Shop", amount: -120_000).registerSearchFields))
    XCTAssertTrue(twelve.matches(try transaction(payee: "Scoot", amount: -12_000).registerSearchFields))
  }

  func testCoverageCopyNamesTheLoadOlderButton() {
    XCTAssertEqual(
      registerSearchStatusCopy(shown: 3, scheduled: 0, hasMore: true, loading: false, error: nil),
      "Showing 3 matches so far. Load older matches to see more."
    )
    XCTAssertFalse(registerSearchStatusCopy(shown: 3, scheduled: 0, hasMore: false, loading: false, error: nil).localizedCaseInsensitiveContains("scroll"))
    XCTAssertFalse(registerSearchStatusCopy(shown: 1600, scheduled: 0, hasMore: true, loading: false, error: nil).localizedCaseInsensitiveContains("loaded"))
  }

  private func range(_ lo: Int, _ hi: Int, _ sign: RegisterQuery.AmountRange.Sign) -> RegisterQuery.AmountRange {
    RegisterQuery.AmountRange(lo: lo, hi: hi, sign: sign)
  }

  private func transaction(payee: String, amount: Int, memo: String? = nil) throws -> Transaction {
    try JSONDecoder().decode(Transaction.self, from: JSONSerialization.data(withJSONObject: [
      "id": "row", "date": "2026-03-05", "amount": amount, "cleared": "uncleared", "approved": true,
      "accountId": "demo", "accountName": "Everyday Account", "payeeName": payee, "memo": memo as Any,
      "deleted": false, "subtransactions": [],
    ]))
  }
}
