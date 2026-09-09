import SwiftUI
import UIKit
import XCTest
@testable import HowMuch

final class RewardsReportTests: XCTestCase {
  func testCurrentPeriodsOmitRangeButRetainAccountScopeAndOptionalAsOf() throws {
    var filter = RewardsReportFilter()
    XCTAssertEqual(filter.mode, .current)
    XCTAssertNil(filter.from)
    XCTAssertNil(filter.to)
    XCTAssertEqual(filter.accountIDs, [])
    filter.range.mode = .custom
    filter.range.customFrom = try date(2025, 3, 1)
    filter.range.customTo = try date(2025, 5, 24)
    filter.scope.accountIDs = ["b", "a"]
    XCTAssertEqual(filter.accountIDs, ["a", "b"])
    XCTAssertNil(filter.from)
    XCTAssertNil(filter.to)
    filter.asOfDate = try date(2025, 4, 10)
    filter.useAsOfDate = true
    XCTAssertNil(filter.from)
    XCTAssertEqual(filter.to, "2025-04-10")
    filter.mode = .historical
    XCTAssertEqual(filter.from, "2025-03-01")
    XCTAssertEqual(filter.to, "2025-05-24")
    filter.mode = .current
    XCTAssertEqual(filter.to, "2025-04-10")
    XCTAssertEqual(filter.accountIDs, ["a", "b"])
  }

  func testHistoricalMonthPresetCustomAndAllTimeRequestBounds() throws {
    var filter = RewardsReportFilter(mode: .historical)
    filter.range.monthAnchor = try date(2025, 2, 15)
    XCTAssertEqual(filter.from, "2025-02-01")
    XCTAssertEqual(filter.to, "2025-02-28")
    filter.range.mode = .preset
    filter.range.preset = .lastThreeMonths
    XCTAssertEqual(filter.from, filter.range.fromISO)
    XCTAssertEqual(filter.to, filter.range.toISO)
    XCTAssertNotNil(filter.from)
    filter.range.preset = .allTime
    XCTAssertNil(filter.range.fromISO)
    XCTAssertEqual(filter.from, "0001-01-01", "nil would silently select current card periods")
    XCTAssertNil(filter.to)
    filter.range.mode = .custom
    filter.range.customFrom = try date(2025, 5, 24)
    filter.range.customTo = try date(2025, 3, 1)
    XCTAssertEqual(filter.from, "2025-03-01")
    XCTAssertEqual(filter.to, "2025-05-24")
  }

  func testRequestKeyTracksModesRangeAsOfAndScope() throws {
    var filter = RewardsReportFilter()
    var key = filter.key
    filter.mode = .historical
    XCTAssertNotEqual(filter.key, key)
    key = filter.key
    filter.range.mode = .custom
    filter.range.customFrom = try date(2025, 3, 1)
    XCTAssertNotEqual(filter.key, key)
    key = filter.key
    filter.scope.accountIDs = ["a", "b"]
    XCTAssertNotEqual(filter.key, key)
    key = filter.key
    filter.scope.accountIDs = ["b", "a"]
    XCTAssertEqual(filter.key, key)
    filter.useAsOfDate = true
    XCTAssertNotEqual(filter.key, key)
    key = filter.key
    filter.asOfDate = try date(2025, 4, 10)
    XCTAssertNotEqual(filter.key, key)
  }

  private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
    try XCTUnwrap(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
  }

  func testQualificationAndAttributedRewardsDecodeWithOlderServerFallback() throws {
    let old = try decoder.decode(RewardsReport.self, from: Data(rewardsJSON.utf8))
    XCTAssertNil(old.transactionRewards)
    XCTAssertNil(old.cards.first?.calculation.qualificationStatus)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rewardsJSON.utf8)) as? [String: Any])
    json["as_of"] = "2026-05-24"
    json["transaction_rewards"] = ["tx_one": ["reward": 7.5, "reward_dollars": 0.1125]]
    var cards = try XCTUnwrap(json["cards"] as? [[String: Any]])
    var calculation = try XCTUnwrap(cards[0]["calculation"] as? [String: Any])
    calculation["qualification_status"] = "pending"
    calculation["monthly_minimum_spend"] = 300
    calculation["monthly_qualifications"] = [["start": "2026-05-01", "end": "2026-05-31", "spend": 248.4, "minimumSpend": 300, "status": "pending"]]
    calculation["active_spending_tier_id"] = "tier-500"
    calculation["has_next_spending_tier"] = true
    calculation["next_spending_tier_threshold"] = 1000
    calculation["should_stop_using"] = false
    var fullPeriod = calculation
    fullPeriod["total_spend"] = 1200
    calculation["periods"] = [["start": "2026-05-01", "end": "2026-05-31", "calculation": fullPeriod]]
    cards[0]["calculation"] = calculation
    json["cards"] = cards
    let report = try decoder.decode(RewardsReport.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(report.asOf, "2026-05-24")
    XCTAssertEqual(report.transactionRewards?["tx_one"]?.reward, 7.5)
    XCTAssertEqual(report.transactionRewards?["tx_one"]?.rewardDollars, 0.1125)
    let calc = try XCTUnwrap(report.cards.first?.calculation)
    XCTAssertEqual(calc.qualificationStatus, "pending")
    XCTAssertEqual(calc.monthlyMinimumSpend, 300)
    XCTAssertEqual(calc.monthlyQualifications?.first?.minimumSpend, 300)
    XCTAssertEqual(calc.monthlyQualifications?.first?.spend, 248.4)
    XCTAssertEqual(calc.activeSpendingTierId, "tier-500")
    XCTAssertEqual(calc.hasNextSpendingTier, true)
    XCTAssertEqual(calc.nextSpendingTierThreshold, 1000)
    XCTAssertEqual(calc.shouldStopUsing, false)
    XCTAssertEqual(calc.periods?.first?.start, "2026-05-01")
    XCTAssertEqual(calc.periods?.first?.end, "2026-05-31")
    XCTAssertEqual(calc.periods?.first?.calculation.totalSpend, 1200)
    XCTAssertEqual(calc.totalSpend, 830.8)
    XCTAssertNil(calc.periods?.first?.calculation.periods)
  }

  func testExportUsesLiveCardsPreservesConfigurationAndSanitizesCredentials() throws {
    let json = #"{"snapshot":{"cards":[{"id":"stale"}],"ynab":{"pat":"REMOVE_ME","selectedBudgetId":"plan"},"rules":[{"id":"rule","rewardRate":4}],"tagMappings":[{"categoryId":"category","flagColor":"red"}],"settings":{"milesValuation":0.015,"cloudSyncMnemonic":"REMOVE_ME","statementFormatter":{"apiKeys":{"provider":"REMOVE_ME"},"format":"csv"},"howmuch_token":"REMOVE_ME"},"cachedData":{"transactions":[{"id":"private"}]}},"cards":[{"id":"live","name":"Card","ynabAccountId":"account","subcategoriesEnabled":false}]}"#
    let snapshot = try decoder.decode(RewardsTrackerSnapshot.self, from: Data(json.utf8))
    let data = try snapshot.configurationData()
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.contains("REMOVE_ME"))
    XCTAssertFalse(text.contains("cachedData"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual((object["cards"] as? [[String: Any]])?.first?["id"] as? String, "live")
    XCTAssertEqual((object["settings"] as? [String: Any])?["milesValuation"] as? Double, 0.015)
    XCTAssertEqual((object["tagMappings"] as? [[String: Any]])?.first?["categoryId"] as? String, "category")
    XCTAssertEqual((object["rules"] as? [[String: Any]])?.first?["rewardRate"] as? Int, 4)
    XCTAssertEqual((object["ynab"] as? [String: Any])?["selectedBudgetId"] as? String, "plan")
  }

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
    XCTAssertEqual(report.totals.miles, 4154)
    XCTAssertEqual(report.cards[0].accountId, "acct-travel")
    XCTAssertEqual(report.cards[0].card.ynabAccountId, "acct-travel")
    XCTAssertEqual(report.cards[0].calculation.totalSpend, 830.8)
    XCTAssertEqual(report.cards[0].calculation.rewardType, .miles)
    XCTAssertEqual(report.cards[0].calculation.rewardEarned, 4154)
    XCTAssertEqual(report.cards[0].calculation.flags[0].rewardEarned, 1242)
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

  func testSkipsAMalformedCardWithoutDroppingSiblings() throws {
    let json = """
    {
      "from": null,
      "to": null,
      "group_by": "flag",
      "miles_valuation": 0.01,
      "totals": { "spend": 830.8, "reward_dollars": 8.31, "cashback": 8.31, "miles": 0 },
      "cards": [
        {
          "account_id": "acct-junk",
          "account_name": "Broken",
          "calculation": { "not": "valid" }
        },
        {
          "card": {
            "id": "card-travel",
            "name": "Travel Card",
            "issuer": "DBS",
            "type": "miles",
            "ynabAccountId": "acct-credit",
            "featured": true
          },
          "account_id": "acct-credit",
          "account_name": "Travel Card",
          "calculation": {
            "period": "all",
            "total_spend": 830.8,
            "counted_spend": 830.8,
            "eligible_spend": 830.8,
            "reward_earned": 8.308,
            "reward_earned_dollars": 8.308,
            "reward_type": "cashback",
            "minimum_spend_met": true,
            "maximum_spend_exceeded": false,
            "flags": []
          }
        }
      ],
      "groups": []
    }
    """
    let report = try decoder.decode(RewardsReport.self, from: Data(json.utf8))
    XCTAssertEqual(report.cards.count, 1)
    XCTAssertEqual(report.cards[0].card.name, "Travel Card")
    XCTAssertEqual(report.cards[0].accountId, "acct-credit")
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

final class RewardsBoardPreferencesTests: XCTestCase {
  func testOrderRetainsHiddenCardsAppendsNewCardsAndIgnoresStaleIDs() {
    var preferences = RewardsBoardPreferences(
      hiddenCardIDs: ["b"], cardOrder: ["removed", "c", "b", "c"], collapsedGroups: ["miles"]
    )
    XCTAssertEqual(preferences.orderedIDs(["a", "b", "c", "new"]), ["c", "b", "a", "new"])
    // Reordering one type must not erase another type or unhide any card.
    preferences.reorder(["new", "a"])
    XCTAssertEqual(preferences.orderedIDs(["a", "b", "c", "new"]), ["new", "a", "c", "b"])
    XCTAssertEqual(preferences.hiddenCardIDs, ["b"])
    XCTAssertEqual(preferences.collapsedGroups, ["miles"])
  }

  func testPreferencesPersistIndependentlyPerPlanAndResetLocally() throws {
    let suite = "RewardsBoardPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = RewardsBoardPreferences(hiddenCardIDs: ["card"], cardOrder: ["b", "a"], collapsedGroups: ["cashback"])
    let second = RewardsBoardPreferences(hiddenCardIDs: [], cardOrder: ["a", "b"], collapsedGroups: ["miles"])
    first.save(planID: "first", to: defaults)
    second.save(planID: "second", to: defaults)
    XCTAssertEqual(RewardsBoardPreferences.load(planID: "first", from: defaults), first)
    XCTAssertEqual(RewardsBoardPreferences.load(planID: "second", from: defaults), second)
    XCTAssertEqual(RewardsBoardPreferences.load(planID: "new-plan", from: defaults), RewardsBoardPreferences())
    RewardsBoardPreferences().save(planID: "first", to: defaults)
    XCTAssertEqual(RewardsBoardPreferences.load(planID: "first", from: defaults), RewardsBoardPreferences())
    XCTAssertEqual(RewardsBoardPreferences.load(planID: "second", from: defaults), second)
    defaults.set(Data("bad JSON".utf8), forKey: RewardsBoardPreferences.storageKey(planID: "first"))
    XCTAssertEqual(RewardsBoardPreferences.load(planID: "first", from: defaults), RewardsBoardPreferences())
  }
}

@MainActor
final class RewardsSnapshotTests: XCTestCase {
  func testHistoricalAccountFilteredBoardShowsFullPeriodMinimum() async throws {
    XCTAssertTrue(URLProtocol.registerClass(RewardsSnapshotProtocol.self))
    defer { URLProtocol.unregisterClass(RewardsSnapshotProtocol.self) }
    let harness = SnapshotHarness.make(baseURLString: "https://rewards-snapshot.test")
    harness.model.settings.planID = "rewards-historical-\(UUID().uuidString)"
    var filter = RewardsReportFilter(mode: .historical)
    filter.range.mode = .custom
    let selectedDate = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 12)))
    filter.range.customFrom = selectedDate
    filter.range.customTo = selectedDate
    filter.scope.accountIDs = ["acct-travel"]
    let surface = try XCTUnwrap(SnapshotSurface(
      root: NavigationStack { RewardsView(filter: filter) }.environment(harness.model).environment(RootChromeState()),
      size: CGSize(width: 430, height: 1800)
    ))
    defer { surface.detach() }
    let expected = ["Historical range", "20 May 2026", "1 Account", "Travel Fixture", "$100.00", "$6.00", "Full-period minimum met", "$700.00 / $500.00"]
    let rendered = await surface.captureUntilOCR(contains: expected, timeoutNanoseconds: 5_000_000_000)
    attach(rendered.image, "rewards-historical-account-filtered")
    for text in expected { XCTAssertTrue(rendered.text.contains(text.lowercased()), "Missing \(text): \(rendered.text)") }
    XCTAssertFalse(rendered.text.contains("cash fixture"), rendered.text)
    XCTAssertFalse(rendered.text.contains("$9,999.00"), rendered.text)
  }

  func testRewardsTabInCompactRootRenders() async throws {
    XCTAssertTrue(URLProtocol.registerClass(RewardsSnapshotProtocol.self))
    defer { URLProtocol.unregisterClass(RewardsSnapshotProtocol.self) }
    let harness = SnapshotHarness.make(baseURLString: "https://rewards-snapshot.test")
    let chrome = RootChromeState()
    chrome.tab = .rewards
    let surface = try XCTUnwrap(SnapshotSurface(
      root: RootTabView(chrome: chrome, usesSidebar: false, workspace: harness.workspace)
        .environment(harness.model).environment(chrome)
        .environment(\.horizontalSizeClass, .compact),
      size: CGSize(width: 430, height: 932)
    ))
    defer { surface.detach() }
    // Filter labels appear before the report loads; require the populated root.
    let expected = ["Accounts", "Rewards", "Reflect", "Display preferences", "0 hidden", "Current card periods", "All Accounts",
      "As of 2026-05-24", "$1,661.60", "$99.70"]
    let rendered = await surface.captureUntilOCR(contains: expected, timeoutNanoseconds: 5_000_000_000)
    attach(rendered.image, "rewards-compact-root")
    for text in expected { XCTAssertTrue(rendered.text.contains(text.lowercased()), "Missing \(text): \(rendered.text)") }
    XCTAssertEqual(chrome.tab, .rewards)
    XCTAssertEqual(chrome.compactBarTab, .rewards)
  }

  func testBoardPeriodQualificationAndTierRender() async throws {
    XCTAssertTrue(URLProtocol.registerClass(RewardsSnapshotProtocol.self))
    defer { URLProtocol.unregisterClass(RewardsSnapshotProtocol.self) }
    let harness = SnapshotHarness.make(baseURLString: "https://rewards-snapshot.test")
    harness.model.settings.planID = "rewards-render-\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: RewardsBoardPreferences.storageKey(planID: harness.model.settings.planID)) }
    let surface = try XCTUnwrap(SnapshotSurface(
      root: NavigationStack { RewardsView() }.environment(harness.model).environment(RootChromeState()),
      size: CGSize(width: 430, height: 2000)
    ))
    defer { surface.detach() }
    // Pixel assertions establish rendering independently of the in-process AX
    // traversal used by other tests; they do not establish accessibility.
    let expected = ["Travel Fixture", "Cash Fixture", "As of 2026-05-24", "2026-05-01", "2026-05-31",
      "Qualification: pending", "Active tier threshold", "$500.00", "Next tier at", "$1,000.00", "$830.80", "0.015"]
    let board = await surface.captureUntilOCR(contains: expected, timeoutNanoseconds: 5_000_000_000)
    attach(board.image, "rewards-board-qualification-tier")
    for text in expected { XCTAssertTrue(board.text.contains(text.lowercased()), "Missing \(text): \(board.text)") }
  }

  func testHiddenCollapsedBoardAndDisabledEditorRender() async throws {
    XCTAssertTrue(URLProtocol.registerClass(RewardsSnapshotProtocol.self))
    defer { URLProtocol.unregisterClass(RewardsSnapshotProtocol.self) }
    let harness = SnapshotHarness.make(baseURLString: "https://rewards-snapshot.test")
    harness.model.settings.planID = "rewards-disabled-\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: RewardsBoardPreferences.storageKey(planID: harness.model.settings.planID)) }
    RewardsBoardPreferences(hiddenCardIDs: ["cash"], cardOrder: ["travel", "cash"], collapsedGroups: ["miles"])
      .save(planID: harness.model.settings.planID)
    let board = try XCTUnwrap(SnapshotSurface(
      root: NavigationStack { RewardsView() }.environment(harness.model).environment(RootChromeState()),
      size: CGSize(width: 430, height: 932)
    ))
    let hidden = await board.captureUntilOCR(contains: ["1 hidden", "Miles", "$99.70"], timeoutNanoseconds: 5_000_000_000)
    attach(hidden.image, "rewards-hidden-collapsed")
    XCTAssertTrue(hidden.text.contains("1 hidden"), hidden.text)
    XCTAssertTrue(hidden.text.contains("$99.70"), "Hidden cards must still count in totals: \(hidden.text)")
    XCTAssertFalse(hidden.text.contains("travel fixture"), hidden.text)
    XCTAssertFalse(hidden.text.contains("cash fixture"), hidden.text)
    board.detach()

    let editor = try XCTUnwrap(SnapshotSurface(
      root: RewardCardEditorView(cardID: "travel").environment(harness.model).environment(RootChromeState()),
      size: CGSize(width: 430, height: 932)
    ))
    defer { editor.detach() }
    let header = await editor.captureUntilOCR(contains: ["Travel Fixture"], timeoutNanoseconds: 5_000_000_000)
    XCTAssertTrue(header.text.contains("travel fixture"), header.text)
    // Scroll the real form, rather than capturing only its category-add input.
    var ruleText = ""
    for offset in stride(from: 600, through: 2000, by: 200) {
      let scrolled = await editor.setMainScrollOffsetY(CGFloat(offset))
      XCTAssertTrue(scrolled, editor.scrollGeometryDiagnostics())
      let rule = await editor.captureUntilOCR(contains: ["Active", "Disabled Dining", "4.0"])
      ruleText = rule.text
      if rule.text.contains("active") && rule.text.contains("disabled dining") {
        attach(rule.image, "rewards-disabled-editor-rule")
        break
      }
    }
    XCTAssertTrue(ruleText.contains("disabled dining"), ruleText)
    XCTAssertTrue(ruleText.contains("active"), ruleText)
    XCTAssertTrue(ruleText.contains("4.0"), ruleText)
    // The retained disabled switches are visually inspected in this attachment;
    // this test does not claim tap interaction or AX traversal coverage.
  }

  private func attach(_ image: UIImage, _ name: String) {
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

private final class RewardsSnapshotProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "rewards-snapshot.test"
  }
  override class func canInit(with task: URLSessionTask) -> Bool {
    (task.currentRequest ?? task.originalRequest).map(canInit(with:)) ?? false
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    let card: [String: Any] = [
      "id": "travel", "name": "Travel Fixture", "type": "miles", "issuer": "Demo",
      "ynabAccountId": "acct-travel", "featured": true, "earningRate": 4,
      "subcategoriesEnabled": false,
      "subcategories": [["id": "dining", "name": "Disabled Dining", "flagColor": "red", "rewardValue": 4, "active": false]],
      "spendingTiers": [["id": "tier-500", "spendThreshold": 500, "earningRate": 4, "maximumSpend": 900]],
    ]
    var cash = card
    cash["id"] = "cash"
    cash["name"] = "Cash Fixture"
    cash["type"] = "cashback"
    cash["ynabAccountId"] = "acct-everyday"
    var calculation: [String: Any] = [
      "period": "2026-05-01/2026-05-31", "total_spend": 830.8,
      "counted_spend": 830.8, "eligible_spend": 830.8, "reward_earned": 3323.2,
      "reward_earned_dollars": 49.848, "reward_type": "miles", "minimum_spend_met": true,
      "maximum_spend_exceeded": false, "qualification_status": "pending",
      "monthly_minimum_spend": 1000,
      "monthly_qualifications": [["start": "2026-05-01", "end": "2026-05-31", "spend": 830.8, "minimumSpend": 1000, "status": "pending"]],
      "active_spending_tier_id": "tier-500", "has_next_spending_tier": true,
      "next_spending_tier_threshold": 1000, "flags": [],
    ]
    calculation["periods"] = [["start": "2026-05-01", "end": "2026-05-31", "calculation": calculation]]
    var cashCalculation = calculation
    cashCalculation["reward_type"] = "cashback"
    cashCalculation["reward_earned"] = 49.848
    let payload: [String: Any]
    switch request.url!.path {
    case "/api/reports/rewards":
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
      if value("plan_id")?.hasPrefix("rewards-historical-") == true {
        // Reject a current-period or unscoped request instead of letting a static
        // fixture mask missing parameters in RewardsView.fetch().
        guard value("from") == "2026-05-20", value("to") == "2026-05-20",
          value("account_ids") == "acct-travel", value("group") == "flag" else {
          client?.urlProtocol(self, didFailWithError: URLError(.badURL))
          return
        }
        calculation["period"] = "2026-05-20:2026-05-20"
        calculation["total_spend"] = 100
        calculation["reward_earned"] = 400
        calculation["reward_earned_dollars"] = 6
        calculation["minimum_spend"] = 500
        calculation["minimum_spend_met"] = true
        calculation["minimum_spend_progress"] = 100
        calculation.removeValue(forKey: "periods")
        var full = calculation
        full["total_spend"] = 700
        var oldPromotion = full
        oldPromotion["total_spend"] = 9999
        calculation["periods"] = [
          ["start": "2026-05-01", "end": "2026-05-31", "calculation": full],
          ["start": "2026-05-10", "end": "2026-05-15", "calculation": oldPromotion],
        ]
        payload = ["from": "2026-05-20", "to": "2026-05-20", "as_of": "2026-05-20", "group_by": "flag", "miles_valuation": 0.015,
          "totals": ["spend": 100, "reward_dollars": 6, "cashback": 0, "miles": 400],
          "cards": [["card": card, "account_id": "acct-travel", "account_name": "Travel", "calculation": calculation]],
          "groups": [], "transaction_rewards": [:]]
      } else {
        payload = ["as_of": "2026-05-24", "group_by": "flag", "miles_valuation": 0.015,
          "totals": ["spend": 1661.6, "reward_dollars": 99.696, "cashback": 49.848, "miles": 3323.2],
          "cards": [["card": card, "account_id": "acct-travel", "account_name": "Travel", "calculation": calculation],
                    ["card": cash, "account_id": "acct-everyday", "account_name": "Everyday", "calculation": cashCalculation]],
          "groups": [], "transaction_rewards": [:]]
      }
    case "/api/import/rewards-tracker":
      payload = ["cards": [card, cash]]
    default:
      payload = ["transactions": [], "has_more": false]
    }
    do {
      let data = try JSONSerialization.data(withJSONObject: ["data": payload])
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
}
