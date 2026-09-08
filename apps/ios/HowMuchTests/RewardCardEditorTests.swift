import XCTest
@testable import HowMuch

final class RewardCardEditorTests: XCTestCase {
  func testWriteFailsWithoutAccountId() {
    var draft = RewardCardDraft.empty()
    draft.name = "Travel Card"
    draft.issuer = "UOB"
    draft.type = .cashback
    draft.ynabAccountId = ""
    draft.earningRate = "1"

    XCTAssertThrowsError(try draft.write()) { error in
      XCTAssertEqual(error.localizedDescription, "Choose a HowMuch card.")
    }
  }

  func testWriteEncodesLiveAccountId() throws {
    var draft = RewardCardDraft.empty()
    draft.name = "Verify cashback"
    draft.issuer = "UOB"
    draft.type = .cashback
    draft.ynabAccountId = "acct-credit"
    draft.featured = true
    draft.earningRate = "1"
    draft.addFlag(
      RewardFlagDraft.fresh(priority: "1", name: "Dining", flagColor: .unflagged, rewardValue: "4")
    )

    let card = try draft.write()
    let payload = card.jsonObject(clearMissing: false)

    XCTAssertEqual(payload["ynabAccountId"] as? String, "acct-credit")
    XCTAssertEqual(payload["name"] as? String, "Verify cashback")
    XCTAssertEqual(payload["issuer"] as? String, "UOB")
    XCTAssertEqual(payload["type"] as? String, "cashback")
    XCTAssertEqual(payload["featured"] as? Bool, true)
    XCTAssertEqual(payload["earningRate"] as? Double, 1)
    XCTAssertNil(payload["pat"])
    XCTAssertNil(payload["howmuchToken"])
    XCTAssertNil(payload["cachedData"])
    XCTAssertNil(payload["settings"])

    let flags = try XCTUnwrap(payload["subcategories"] as? [[String: Any]])
    XCTAssertEqual(flags.count, 1)
    XCTAssertEqual(flags[0]["name"] as? String, "Dining")
    XCTAssertEqual(flags[0]["flagColor"] as? String, "unflagged")
    XCTAssertEqual(flags[0]["rewardValue"] as? Double, 4)
    XCTAssertEqual(flags[0]["priority"] as? Double, 1)
    XCTAssertEqual(flags[0]["active"] as? Bool, true)
    XCTAssertTrue((flags[0]["id"] as? String)?.hasPrefix("subcat_") == true)
    XCTAssertFalse((flags[0]["createdAt"] as? String ?? "").isEmpty)
    XCTAssertFalse((flags[0]["updatedAt"] as? String ?? "").isEmpty)
  }

  func testSnapshotCardRoundTripsBillingFlagsAndTiers() throws {
    let json = """
    {
      "id": "card-travel",
      "name": "Travel Card",
      "issuer": "DBS",
      "type": "miles",
      "ynabAccountId": "acct-credit",
      "featured": true,
      "billingCycle": { "type": "calendar", "dayOfMonth": 15 },
      "earningRate": 1.2,
      "minimumSpend": 200,
      "subcategoriesEnabled": true,
      "subcategories": [
        {
          "id": "subcat-dining",
          "name": "Dining",
          "flagColor": "red",
          "rewardValue": 4,
          "priority": 1,
          "active": true,
          "createdAt": "2026-01-15T00:00:00.000Z",
          "updatedAt": "2026-01-15T00:00:00.000Z"
        }
      ],
      "spendingTiers": [
        {
          "id": "tier-400",
          "spendThreshold": 400,
          "earningRate": 1.4,
          "subcategories": [
            { "subcategoryId": "subcat-dining", "rewardValue": 5 }
          ]
        }
      ]
    }
    """
    let card = try JSONDecoder().decode(CreditCard.self, from: Data(json.utf8))
    XCTAssertEqual(card.billingCycle?.type, .calendar)
    XCTAssertEqual(card.billingCycle?.dayOfMonth, 15)
    XCTAssertEqual(card.earningRate, 1.2)
    XCTAssertEqual(card.subcategories?.first?.flagColor, .red)
    XCTAssertEqual(card.spendingTiers?.first?.spendThreshold, 400)
    XCTAssertEqual(card.spendingTiers?.first?.subcategories?.first?.subcategoryId, "subcat-dining")

    let payload = card.jsonObject(clearMissing: true)
    XCTAssertEqual((payload["billingCycle"] as? [String: Any])?["dayOfMonth"] as? Double, 15)
    XCTAssertEqual((payload["subcategories"] as? [[String: Any]])?.first?["flagColor"] as? String, "red")
    XCTAssertEqual((payload["spendingTiers"] as? [[String: Any]])?.first?["spendThreshold"] as? Double, 400)
  }

  func testUnknownFlagColourDecodesAsUnflagged() throws {
    let json = Data(#"{ "flagColor": "magenta" }"#.utf8)
    struct FlagColourBox: Decodable {
      let flagColor: RewardFlagColour
    }
    let box = try JSONDecoder().decode(FlagColourBox.self, from: json)
    XCTAssertEqual(box.flagColor, .unflagged)
  }

  func testUnknownRewardKindDecodesAsCashback() throws {
    let json = """
    {
      "id": "card-points",
      "name": "Legacy points",
      "issuer": "UOB",
      "type": "points",
      "ynabAccountId": "acct-credit",
      "featured": true
    }
    """
    let card = try JSONDecoder().decode(CreditCard.self, from: Data(json.utf8))
    XCTAssertEqual(card.type, .cashback)
    XCTAssertEqual(card.name, "Legacy points")
  }

  func testSparseSubcategoryDoesNotFailTheCard() throws {
    let json = """
    {
      "id": "card-travel",
      "name": "Travel Card",
      "issuer": "DBS",
      "type": "miles",
      "ynabAccountId": "acct-credit",
      "featured": true,
      "subcategories": [
        { "id": "subcat-dining", "name": "Dining", "flagColor": "red", "rewardValue": 4 },
        { "not": "a subcategory" }
      ]
    }
    """
    let card = try JSONDecoder().decode(CreditCard.self, from: Data(json.utf8))
    XCTAssertEqual(card.subcategories?.count, 1)
    XCTAssertEqual(card.subcategories?.first?.name, "Dining")
    XCTAssertEqual(card.subcategories?.first?.flagColor, .red)
    XCTAssertEqual(card.subcategories?.first?.rewardValue, 4)
    XCTAssertEqual(card.subcategories?.first?.priority, 0)
    XCTAssertEqual(card.subcategories?.first?.active, true)
  }

  func testRewardFlagColoursAreTheLedgerTags() {
    XCTAssertEqual(Set(FlagColour.allCases.map(\.rawValue)), Set(["", "red", "orange", "yellow", "green", "blue", "purple"]))
    XCTAssertEqual(RewardFlagColour.red.ledgerColour, .red)
    XCTAssertEqual(RewardFlagColour.unflagged.ledgerColour, .none)
    XCTAssertEqual(RewardFlagColour(ledgerColour: .none), .unflagged)
    XCTAssertEqual(RewardFlagColour(ledgerColour: .blue), .blue)
    XCTAssertEqual(RewardFlagColour(ledgerColour: .red).rawValue, FlagColour.red.rawValue)
    for colour in FlagColour.allCases where colour != .none {
      XCTAssertNotNil(Theme.flagColour(named: colour.rawValue))
      XCTAssertEqual(
        Theme.flagColour(named: RewardFlagColour(ledgerColour: colour).rawValue),
        Theme.flagColour(named: colour.rawValue)
      )
    }
    XCTAssertNil(Theme.flagColour(named: RewardFlagColour.unflagged.rawValue))
    XCTAssertNil(Theme.flagColour(named: FlagColour.none.rawValue))
  }

  func testAccountChoicesAreExistingCreditCards() {
    let travel = Account(id: "acct-credit", name: "Travel Card", icon: nil, type: "creditCard", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
    let loc = Account(id: "acct-loc", name: "Overdraft", icon: nil, type: "lineOfCredit", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
    let everyday = Account(id: "acct-everyday", name: "Everyday Account", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
    let ids = RewardCardAccounts.choices(
      accounts: [everyday, loc, travel],
      takenIDs: ["acct-credit"],
      keepingID: nil
    ).map(\.id)
    XCTAssertEqual(ids, ["acct-loc"])
    let editing = RewardCardAccounts.choices(
      accounts: [everyday, loc, travel],
      takenIDs: ["acct-credit"],
      keepingID: "acct-credit"
    ).map(\.id)
    XCTAssertEqual(editing, ["acct-loc", "acct-credit"])
  }

  func testSelectingAHowMuchCardFillsTheName() {
    var draft = RewardCardDraft.empty()
    let travel = Account(id: "acct-credit", name: "Travel Card", icon: nil, type: "creditCard", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
    draft.selectAccount(id: "acct-credit", from: [travel])
    XCTAssertEqual(draft.ynabAccountId, "acct-credit")
    XCTAssertEqual(draft.name, "Travel Card")
    draft.name = "Verify cashback"
    let loc = Account(id: "acct-loc", name: "Overdraft", icon: nil, type: "lineOfCredit", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
    draft.selectAccount(id: "acct-loc", from: [travel, loc])
    XCTAssertEqual(draft.name, "Verify cashback")
  }
}
