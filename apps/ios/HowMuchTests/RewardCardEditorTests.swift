import XCTest
@testable import HowMuch

final class RewardCardEditorTests: XCTestCase {
  func testDisabledRulesSurviveDraftDecodeWriteAndUnrelatedEdit() throws {
    let json = #"{"id":"card","name":"Travel","issuer":"Bank","type":"miles","ynabAccountId":"account","featured":false,"subcategoriesEnabled":false,"subcategories":[{"id":"category-stable","name":"Dining rule","flagColor":"red","rewardValue":4,"priority":2,"active":false,"excludeFromRewards":false,"minimumSpend":10,"maximumSpend":200,"milesBlockSize":5,"createdAt":"created","updatedAt":"updated"}],"flagNames":{"red":"Dining label"},"spendingTiers":[{"id":"tier-stable","spendThreshold":500,"earningRate":2,"maximumSpend":1000,"subcategories":[{"subcategoryId":"category-stable","rewardValue":6,"maximumSpend":100}]}]}"#
    let original = try JSONDecoder().decode(CreditCard.self, from: Data(json.utf8))
    var draft = RewardCardDraft(card: original)
    XCTAssertEqual(try draft.write(), original)
    draft.issuer = "Another bank"
    let written = try draft.write()
    XCTAssertEqual(written.subcategoriesEnabled, false)
    XCTAssertEqual(written.subcategories, original.subcategories)
    XCTAssertEqual(written.spendingTiers, original.spendingTiers)
    draft.subcategoriesEnabled = true
    XCTAssertEqual(try draft.write().subcategoriesEnabled, true)
  }

  func testUnrelatedEditPreservesSignedFinitePriority() throws {
    var draft = RewardCardDraft.empty()
    draft.name = "Card"
    draft.ynabAccountId = "account"
    draft.addFlag(.fresh(priority: "-1.25", name: "Dining", rewardValue: "4"))
    let original = try draft.write()
    draft = RewardCardDraft(card: original)
    draft.issuer = "Another bank"
    XCTAssertEqual(try draft.write().subcategories?.first?.priority, -1.25)
    for priority in ["", "NaN", "Infinity", "-Infinity"] {
      draft.flags[0].priority = priority
      XCTAssertThrowsError(try draft.write(), priority)
    }
  }

  func testRejectsInvalidPeriodsAndNegativeNumbers() throws {
    var valid = RewardCardDraft.empty()
    valid.name = "Card"
    valid.ynabAccountId = "account"
    valid.rewardMonthCount = "2"
    valid.rewardAnchorDate = "2026-02-28"
    valid.rewardMonthlyMinimum = "0"
    for months in ["1", "25", "2.5"] {
      var draft = valid
      draft.rewardMonthCount = months
      XCTAssertThrowsError(try draft.write(), months)
    }
    for date in ["2026-02-29", "2026-04-31", "2026-2-01"] {
      var draft = valid
      draft.rewardAnchorDate = date
      XCTAssertThrowsError(try draft.write(), date)
    }
    for day in ["0", "32", "1.5", ""] {
      var draft = valid
      draft.billingType = .billing
      draft.billingDay = day
      XCTAssertThrowsError(try draft.write(), day)
    }
    var draft = valid
    draft.promoStart = "2026-05-02"
    draft.promoEnd = "2026-05-01"
    XCTAssertThrowsError(try draft.write())
    draft = valid
    draft.earningRate = "-0.1"
    XCTAssertThrowsError(try draft.write())
    valid.rewardMonthCount = "24"
    valid.billingType = .billing
    valid.billingDay = "31"
    XCTAssertNoThrow(try valid.write())
  }

  func testDraftPreservesMultiMonthAndPromotionalConfiguration() throws {
    let json = #"{"id":"card","name":"Card","ynabAccountId":"account","billingCycle":{"type":"billing","dayOfMonth":31},"rewardPeriod":{"monthCount":3,"anchorDate":"2024-02-29","monthlyMinimumSpend":300},"promotionalPeriod":{"startDate":"2026-01-01","endDate":"2026-12-31","description":""},"earningRate":1.5,"earningBlockSize":5,"minimumSpend":100,"maximumSpend":1500,"subcategoriesEnabled":true,"subcategories":[],"spendingTiers":[]}"#
    let card = try JSONDecoder().decode(CreditCard.self, from: Data(json.utf8))
    let written = try RewardCardDraft(card: card).write()
    XCTAssertEqual(written, card)
    let encoded = try JSONSerialization.data(withJSONObject: written.jsonObject(clearMissing: true))
    let decoded = try JSONDecoder().decode(CreditCard.self, from: encoded)
    XCTAssertEqual(decoded.rewardPeriod, card.rewardPeriod)
    XCTAssertEqual(decoded.promotionalPeriod, card.promotionalPeriod)
    XCTAssertEqual(decoded.subcategoriesEnabled, true)
  }

  func testWriteFailsWithoutAccountId() {
    var draft = RewardCardDraft.empty()
    draft.name = "Travel Card"
    draft.issuer = "UOB"
    draft.type = .cashback
    draft.ynabAccountId = ""
    draft.earningRate = "1"

    XCTAssertThrowsError(try draft.write()) { error in
      XCTAssertEqual(error.localizedDescription, "Choose a Halation account.")
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

    let written = try RewardCardDraft(card: card).write()
    XCTAssertEqual(written, card)
    let payload = written.jsonObject(clearMissing: true)
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

  func testAccountChoicesIncludeOpenOnBudgetCheckingAccounts() {
    let travel = Account(id: "acct-credit", name: "Travel Card", icon: nil, type: "creditCard", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
    let loc = Account(id: "acct-loc", name: "Overdraft", icon: nil, type: "lineOfCredit", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
    let everyday = Account(id: "acct-everyday", name: "Everyday Account", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
    let ids = RewardCardAccounts.choices(
      accounts: [everyday, loc, travel],
      takenIDs: ["acct-credit"],
      keepingID: nil
    ).map(\.id)
    XCTAssertEqual(ids, ["acct-everyday", "acct-loc"])
    let editing = RewardCardAccounts.choices(
      accounts: [everyday, loc, travel],
      takenIDs: ["acct-credit"],
      keepingID: "acct-credit"
    ).map(\.id)
    XCTAssertEqual(editing, ["acct-everyday", "acct-loc", "acct-credit"])
  }

  func testAccountChoicesExcludeClosedOffBudgetAndDeletedButRetainCurrentLink() {
    let closed = Account(id: "closed", name: "Closed", icon: nil, type: "checking", onBudget: true, closed: true, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
    let offBudget = Account(id: "off", name: "Off budget", icon: nil, type: "checking", onBudget: false, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
    let deleted = Account(id: "deleted", name: "Deleted", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: true)
    let accounts = [closed, offBudget, deleted]
    XCTAssertTrue(RewardCardAccounts.choices(accounts: accounts, takenIDs: [], keepingID: nil).isEmpty)
    XCTAssertEqual(RewardCardAccounts.choices(accounts: accounts, takenIDs: ["closed"], keepingID: "closed").map(\.id), ["closed"])
    XCTAssertEqual(RewardCardAccounts.choices(accounts: accounts, takenIDs: ["off"], keepingID: "off").map(\.id), ["off"])
    XCTAssertTrue(RewardCardAccounts.choices(accounts: accounts, takenIDs: [], keepingID: "deleted").isEmpty)
  }

  func testCategoryAndOverrideRatesAreRequiredNumbers() throws {
    XCTAssertThrowsError(try JSONDecoder().decode(CardSubcategory.self, from: Data(#"{"id":"category","rewardValue":null}"#.utf8)))
    XCTAssertThrowsError(try JSONDecoder().decode(SpendingTierSubcategory.self, from: Data(#"{"subcategoryId":"category","rewardValue":null}"#.utf8)))
    var draft = RewardCardDraft.empty()
    draft.name = "Card"
    draft.ynabAccountId = "account"
    draft.addFlag(.fresh(name: "Dining", rewardValue: ""))
    XCTAssertThrowsError(try draft.write())
    draft.flags[0].rewardValue = "0"
    XCTAssertNoThrow(try draft.write())
    draft.addTier()
    draft.tiers[0].spendThreshold = "0"
    draft.tiers[0].overrides = [RewardTierOverrideDraft(subcategoryId: draft.flags[0].id)]
    XCTAssertThrowsError(try draft.write())
    draft.tiers[0].overrides[0].rewardValue = "0"
    XCTAssertNoThrow(try draft.write())
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

  func testWriteEncodesAccountColourNames() throws {
    var draft = RewardCardDraft.empty()
    draft.name = "Travel Card"
    draft.issuer = "UOB"
    draft.type = .cashback
    draft.ynabAccountId = "acct-credit"
    draft.earningRate = "1"
    draft.flagNames = [.red: "Dining", .blue: " Online "]
    draft.addFlag(
      RewardFlagDraft.fresh(priority: "1", name: "Dining Out", flagColor: .red, rewardValue: "4")
    )

    let card = try draft.write()
    let payload = card.jsonObject(clearMissing: false)
    XCTAssertEqual(card.flagNames?["red"], "Dining")
    XCTAssertEqual(card.flagNames?["blue"], "Online")
    XCTAssertEqual(card.subcategories?.first?.name, "Dining")
    XCTAssertEqual((payload["flagNames"] as? [String: String])?["red"], "Dining")
    XCTAssertEqual((payload["flagNames"] as? [String: String])?["blue"], "Online")
  }

  func testClearMissingEncodesEmptyColourNames() {
    let card = CreditCard(
      id: "card-travel",
      name: "Travel Card",
      issuer: "UOB",
      type: .cashback,
      ynabAccountId: "acct-credit",
      featured: true
    )
    let payload = card.jsonObject(clearMissing: true)
    let names = payload["flagNames"] as? [String: String]
    XCTAssertEqual(names ?? [:], [:])
  }

  func testColourNamesOverlayLedgerTitles() throws {
    let json = """
    {
      "id": "card-travel",
      "name": "Travel Card",
      "issuer": "DBS",
      "type": "miles",
      "ynabAccountId": "acct-credit",
      "featured": true,
      "subcategories": [
        {
          "id": "subcat-dining",
          "name": "Dining Out",
          "flagColor": "red",
          "rewardValue": 4,
          "priority": 1,
          "active": true,
          "createdAt": "2026-01-15T00:00:00.000Z",
          "updatedAt": "2026-01-15T00:00:00.000Z"
        }
      ],
      "flagNames": { "red": "Dining", "blue": "Online" }
    }
    """
    let card = try JSONDecoder().decode(CreditCard.self, from: Data(json.utf8))
    XCTAssertEqual(card.flagNames?["red"], "Dining")
    XCTAssertEqual(card.flagNames?["blue"], "Online")

    let draft = RewardCardDraft(card: card)
    XCTAssertEqual(draft.flagNames[.red], "Dining")
    XCTAssertEqual(draft.flagNames[.blue], "Online")
    XCTAssertEqual(draft.ledgerTitle(for: .red), "Dining")
    XCTAssertEqual(draft.ledgerTitle(for: .blue), "Online")
    XCTAssertEqual(draft.ledgerTitle(for: .green), "Green")
    XCTAssertEqual(draft.ledgerTitle(for: .none), "None")
    XCTAssertEqual(draft.displayName(for: draft.flags[0]), "Dining")
  }
}
