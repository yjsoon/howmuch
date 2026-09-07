import XCTest
@testable import HowMuch

final class RewardsReportTests: XCTestCase {
  func testRewardGroupByCasesMatchAPIGroupQueryValues() {
    XCTAssertEqual(RewardGroupBy.allCases.map(\.rawValue), ["flag", "payee", "category", "memo"])
    XCTAssertEqual(RewardGroupBy.flag.title, "Flag")
    XCTAssertEqual(RewardGroupBy.payee.title, "Payee")
    XCTAssertEqual(RewardGroupBy.category.title, "Category")
    XCTAssertEqual(RewardGroupBy.memo.title, "Memo")
  }

  func testDecodesMixedKeyRewardsEnvelope() throws {
    let report = try decoder.decode(RewardsReport.self, from: Data(rewardsJSON.utf8))

    XCTAssertEqual(report.groupBy, .payee)
    XCTAssertEqual(report.milesValuation, 0.015)
    XCTAssertEqual(report.totals.spend, 830.8)
    XCTAssertEqual(report.totals.rewardDollars, 12.46)
    XCTAssertEqual(report.cards[0].accountId, "acct-travel")
    XCTAssertEqual(report.cards[0].card.ynabAccountId, "acct-travel")
    XCTAssertEqual(report.cards[0].calculation.totalSpend, 830.8)
    XCTAssertEqual(report.cards[0].calculation.rewardType, .miles)
    XCTAssertEqual(report.cards[0].calculation.flags[0].rewardEarned, 4154)
    XCTAssertEqual(report.cards[0].calculation.flags[0].flagColor, "orange")
    XCTAssertEqual(report.groups[0].flagColor, "orange")
    XCTAssertEqual(report.groups[0].transactionCount, 3)
    XCTAssertEqual(report.groups[0].rewardDollars, 12.46)
  }

  func testTotalsSpendIsCurrencyUnitsNotMilliunits() throws {
    let report = try decoder.decode(RewardsReport.self, from: Data(rewardsJSON.utf8))
    XCTAssertEqual(report.totals.spend, 830.8)
    XCTAssertNotEqual(report.totals.spend, 830_800)
  }

  func testDecodesImportResultSnakeCase() throws {
    let json = """
    {
      "import_session_id": "sess-1",
      "cards": 1,
      "rules": 4,
      "tag_mappings": 2,
      "theme_groups": 1,
      "accounts_upserted": 1,
      "transactions_imported": 0,
      "transactions_updated": 0,
      "flag_names": 3
    }
    """
    let result = try decoder.decode(RewardsTrackerImportResult.self, from: Data(json.utf8))
    XCTAssertEqual(result.importSessionId, "sess-1")
    XCTAssertEqual(result.cards, 1)
    XCTAssertEqual(result.tagMappings, 2)
    XCTAssertEqual(result.themeGroups, 1)
    XCTAssertEqual(result.accountsUpserted, 1)
    XCTAssertEqual(result.transactionsImported, 0)
    XCTAssertEqual(result.flagNames, 3)
  }

  func testDecodesSnapshotCardsWithYnabAccountId() throws {
    let json = """
    {
      "snapshot": { "cards": [{ "id": "card-travel", "name": "Travel Card", "issuer": "DBS", "type": "miles", "ynabAccountId": "acct-travel" }] },
      "cards": [{ "id": "card-travel", "name": "Travel Card", "issuer": "DBS", "type": "miles", "ynabAccountId": "acct-travel" }],
      "imported_at": "2026-05-24T10:00:00Z",
      "updated_at": "2026-05-24T10:00:00Z"
    }
    """
    let snapshot = try decoder.decode(RewardsTrackerSnapshot.self, from: Data(json.utf8))
    XCTAssertEqual(snapshot.cards[0].ynabAccountId, "acct-travel")
    XCTAssertEqual(snapshot.cards[0].name, "Travel Card")
    XCTAssertEqual(snapshot.snapshot?.cards?.first?.ynabAccountId, "acct-travel")
  }

  func testCurrencyUnitsFormatterMatchesMilliunits() {
    let format = CurrencyFormat(
      isoCode: "SGD",
      exampleFormat: "$123,456.78",
      decimalDigits: 2,
      decimalSeparator: ".",
      groupSeparator: ",",
      symbolFirst: true,
      currencySymbol: "$"
    )
    XCTAssertEqual(
      MoneyCodec.displayString(forCurrencyUnits: 830.8, currencyFormat: format),
      MoneyCodec.displayString(for: 830_800, currencyFormat: format)
    )
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }

  private let rewardsJSON = """
  {
    "from": "2026-03-01",
    "to": "2026-05-24",
    "group_by": "payee",
    "miles_valuation": 0.015,
    "totals": {
      "spend": 830.8,
      "reward_dollars": 12.46,
      "cashback": 0,
      "miles": 4154
    },
    "cards": [
      {
        "card": {
          "id": "card-travel",
          "name": "Travel Card",
          "issuer": "DBS",
          "type": "miles",
          "ynabAccountId": "acct-travel",
          "featured": true
        },
        "account_id": "acct-travel",
        "account_name": "Travel Card",
        "calculation": {
          "period": "2026-03-01/2026-05-24",
          "total_spend": 830.8,
          "counted_spend": 830.8,
          "eligible_spend": 830.8,
          "reward_earned": 4154,
          "reward_earned_dollars": 12.46,
          "reward_type": "miles",
          "minimum_spend": null,
          "minimum_spend_met": true,
          "minimum_spend_progress": null,
          "maximum_spend": null,
          "maximum_spend_exceeded": false,
          "maximum_spend_progress": null,
          "flags": [
            {
              "subcategoryId": "dining",
              "name": "Dining",
              "flagColor": "orange",
              "totalSpend": 248.4,
              "eligibleSpend": 248.4,
              "rewardEarned": 1242,
              "rewardEarnedDollars": 3.73,
              "rewardRate": 4
            }
          ]
        }
      }
    ],
    "groups": [
      {
        "key": "candlenut",
        "label": "Candlenut",
        "flag_color": "orange",
        "spend": 188.0,
        "reward": 940,
        "reward_dollars": 12.46,
        "transaction_count": 3
      }
    ]
  }
  """
}
