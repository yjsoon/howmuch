import XCTest
@testable import HowMuch

/// Expectations are the fixtures in `apps/api/src/payee-names.test.ts`, not the
/// Swift port's output. Failure modes this guards: the port drifting from the
/// TypeScript cleaner (regex or Unicode differences, off-by-one in word
/// lengths) so the matcher scores merchants differently from the server.
final class PayeeNamesTests: XCTestCase {
  func testStripsCodesRailsProcessorsSuffixesAndPlaces() {
    let cases: [(String, [String])] = [
      ("GRAB*A-5X7K9QWE SINGAPORE SG", ["grab"]),
      ("GRABFOOD*ORDER 8812", ["grabfood", "order"]),
      ("NETS QR KOPITIAM 12345", ["kopitiam"]),
      ("-4821 KOUFU PTE LTD SINGAPORE SG", ["koufu"]),
      ("SQ *COMMON MAN COFFEE", ["common", "man", "coffee"]),
      ("PAYPAL *NETFLIX 4029357733", ["netflix"]),
      ("KrisPay*Tai Cheong", ["tai", "cheong"]),
      ("NET*HOTBAKE 24/7", ["hotbake"]),
      ("APPLE.COM/BILL 866-712-7753 IE", ["apple"]),
      ("Mcdonald's-Tampines Mall", ["mcdonalds", "tampines", "mall"]),
      ("Caf\u{00E9} Nero", ["cafe", "nero"]),
      ("MERLE &amp; CO SINGAPORE", ["merle"]),
      ("TAN AH KOW (Mobile ending 1234)", ["tan", "kow"]),
      ("GlobalE /Gray Parka ServiSINGAPORE", ["gray", "parka", "servi"]),
      ("NOVOTEL JB - FRONT DESK JOHOR BAHRU", ["novotel", "front", "desk"]),
      ("Swee Yee Food Sdn Bhd", ["swee", "yee", "food"]),
      ("7-11", ["seveneleven"]),
      ("7 ELEVEN-TAMPINES CENTR", ["seveneleven", "tampines", "centr"]),
      ("4FINGERS CRISPY CHICKE", ["four", "fingers", "crispy", "chicke"]),
      ("676 Woodlands Teochew", ["woodlands", "teochew"]),
      ("KTMB", ["ktmb"]),
      ("FAST PAYMENT via PayNow-Mobile to TAN AH KOW OTHR 123456", ["tan", "kow"]),
      ("PayPal", ["paypal"]),
      ("1234 5678", []),
    ]
    for (name, tokens) in cases {
      XCTAssertEqual(PayeeNames.tokens(name), tokens, name)
    }
    XCTAssertEqual(PayeeNames.tokens(nil), [])
  }

  func testRecognisesOneMerchantUnderDifferentSpellingsCodesAndBranches() {
    XCTAssertEqual(similarity("GRAB*A-5X7K9QWE SINGAPORE SG", "Grab"), 1, accuracy: 1e-9)
    XCTAssertEqual(similarity("Grab Malaysia", "Grab"), 1, accuracy: 1e-9)
    XCTAssertEqual(similarity("NETS QR KOPITIAM 12345", "Kopitiam @ Bishan"), 0.83, accuracy: 0.005)
    XCTAssertEqual(similarity("-4821 KOUFU PTE LTD SINGAPORE SG", "Koufu"), 1, accuracy: 1e-9)
    XCTAssertEqual(similarity("7-11", "7-Eleven"), 1, accuracy: 1e-9)
    XCTAssertGreaterThanOrEqual(similarity("7 ELEVEN-TAMPINES CENTR", "7-Eleven"), 0.7)
    XCTAssertEqual(similarity("4FINGERS CRISPY CHICKE", "Four Fingers"), 0.8, accuracy: 0.005)
    XCTAssertEqual(similarity("DIANXIAOERGROUPPTELTD +6500000000", "Dian Xiao Er"), 0.9, accuracy: 1e-9)
    XCTAssertEqual(similarity("fp*Food Panda", "Foodpanda subscription"), 0.9, accuracy: 1e-9)
    XCTAssertEqual(similarity("SP DIGITAL PL-UTIL-RE", "SP Digital PL-Utilitie"), 0.83, accuracy: 0.005)
    XCTAssertEqual(similarity("Sheng Siong Supermarke", "Sheng Siong"), 0.875, accuracy: 1e-9)
  }

  func testKeepsDifferentMerchantsApart() {
    XCTAssertEqual(similarity("Sushiro", "Genki Sushi"), 0, accuracy: 1e-9)
    XCTAssertEqual(similarity("Sheng Siong", "Fong Sheng Hao"), 0, accuracy: 1e-9)
    XCTAssertEqual(similarity("Mcdonald's-Tampines Mall", "Tampines Mall Carpark"), 0, accuracy: 1e-9)
    XCTAssertEqual(similarity("Toast Box", "TWENTY LOAF TOASTIES"), 0, accuracy: 1e-9)
    XCTAssertEqual(similarity("Grabfood", "Grab"), 0.5, accuracy: 1e-9)
    XCTAssertLessThan(similarity("FairPrice Group Hawker", "FairPrice"), similarity("FairPrice", "Fairprice"))
    XCTAssertEqual(
      similarity("TAN AH KOW (Mobile ending 1234)", "LIM BEE LENG (Mobile ending 5678)"),
      0,
      accuracy: 1e-9
    )
  }

  func testSearchStemIsShortStemOfMerchantWord() {
    XCTAssertEqual(PayeeNames.searchStem(PayeeNames.tokens("GRABFOOD*ORDER 8812")), "grab")
    XCTAssertEqual(PayeeNames.searchStem(PayeeNames.tokens("NETS QR KOPITIAM 12345")), "kopi")
    XCTAssertNil(PayeeNames.searchStem([]))
  }

  private func similarity(_ a: String, _ b: String) -> Double {
    PayeeNames.similarity(PayeeNames.tokens(a), PayeeNames.tokens(b))
  }
}
