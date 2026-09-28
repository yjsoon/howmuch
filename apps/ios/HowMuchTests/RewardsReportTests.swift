import SwiftUI
import UIKit
import XCTest
@testable import HowMuch

@MainActor
final class RewardsAccountImportTests: XCTestCase {
  private let file = Data(#"{"format":"rewards-account-config","version":1,"card":{"name":"Synthetic Miles Card","issuer":"Example Bank","type":"miles","minimumSpend":null,"futureRule":{"value":17,"limit":null},"subcategories":[{"id":"dining","minimumSpend":null}]}}"#.utf8)

  func testFilePreflightRejectsWrongFlowAndMalformedEnvelopes() throws {
    let summary = try RewardsImportFile.accountConfig(file)
    XCTAssertEqual(summary.name, "Synthetic Miles Card")
    XCTAssertEqual(summary.issuer, "Example Bank")
    XCTAssertEqual(summary.type, "miles")
    XCTAssertThrowsError(try RewardsImportFile.wholeSettings(file))
    XCTAssertNotNil(try RewardsImportFile.wholeSettings(Data(#"{"cards":[],"settings":{}}"#.utf8)))
    for json in ["not JSON", "[]", "null", #"{"cards":[]}"#,
      #"{"format":"rewards-account-config","version":true,"card":{"name":"Name","issuer":"","type":"miles"}}"#,
      #"{"format":"rewards-account-config","version":2,"card":{"name":"Name","issuer":"","type":"miles"}}"#,
      #"{"format":"rewards-account-config","version":1,"card":{"name":" ","issuer":"","type":"miles"}}"#,
      #"{"format":"rewards-account-config","version":1,"card":[]}"#] {
      XCTAssertThrowsError(try RewardsImportFile.accountConfig(Data(json.utf8)), json)
    }
    let selection = RewardsAccountImportSelection()
    try selection.choose(data: file, fileName: "valid.json")
    XCTAssertThrowsError(try selection.choose(data: Data("[]".utf8), fileName: "bad.json"))
    XCTAssertNil(selection.data)
    XCTAssertNil(selection.sourceName)
    selection.accountID = "old-plan-account"
    selection.success = "Old result"
    selection.reset()
    XCTAssertEqual(selection.accountID, "")
    XCTAssertNil(selection.success)
  }

  func testPasteAcceptsPaddedCurlyQuotedJSONAndRejectsNonJSON() throws {
    let curly = "  \u{201C}format\u{201D}"
    let padded = "\n\t {\(curly): \u{201C}rewards-account-config\u{201D}, \u{201C}version\u{201D}: 1, "
      + "\u{201C}card\u{201D}: {\u{201C}name\u{201D}: \u{201C}Ann\u{2019}s Card\u{201D}, "
      + "\u{201C}issuer\u{201D}: \u{201C}Example Bank\u{201D}, \u{201C}type\u{201D}: \u{201C}cashback\u{201D}}}\n  "
    let selection = RewardsAccountImportSelection()
    try selection.choose(text: padded)
    XCTAssertEqual(selection.fileName, "Pasted JSON")
    XCTAssertEqual(selection.summary?.name, "Ann\u{2019}s Card", "Apostrophes inside values survive")
    XCTAssertEqual(selection.summary?.type, "cashback")

    let other = RewardsAccountImportSelection()
    XCTAssertThrowsError(try other.choose(text: "not JSON"))
    XCTAssertNil(other.data)
  }

  func testPUTPreservesRawConfigurationAndDecodesCard() async throws {
    XCTAssertTrue(URLProtocol.registerClass(RewardsAccountImportProtocol.self))
    defer { URLProtocol.unregisterClass(RewardsAccountImportProtocol.self) }
    var settings = APISettings()
    settings.baseURLString = "https://rewards-account-import.test"
    let card = try await APIClient(settings: settings).importRewardsAccountConfig(
      planID: "destination-plan", accountID: "card / 50%", payloadJSON: file)
    XCTAssertEqual(card.id, "existing-card")
    XCTAssertEqual(card.name, "Destination")
    XCTAssertEqual(card.ynabAccountId, "acct-destination")
    XCTAssertEqual(card.featured, false)
  }

  func testImportSelectionConfirmationSuccessErrorAndPlanResetRender() async throws {
    XCTAssertTrue(URLProtocol.registerClass(RewardsSnapshotProtocol.self))
    defer { URLProtocol.unregisterClass(RewardsSnapshotProtocol.self) }
    let harness = SnapshotHarness.make(baseURLString: "https://rewards-snapshot.test")
    let selection = RewardsAccountImportSelection()
    selection.accountID = "acct-travel"
    try selection.choose(data: file, fileName: "synthetic-miles.json")
    let surface = try XCTUnwrap(SnapshotSurface(
      root: NavigationStack { RewardsAccountImportView(selection: selection) }.environment(harness.model),
      size: CGSize(width: 430, height: 1100)))
    defer { surface.detach() }
    var rendered = await surface.captureUntilOCR(contains: ["Import into One Account", "Travel", "Synthetic Miles Card", "Paste JSON"])
    attach(rendered.image, "account-import-selected")
    XCTAssertTrue(rendered.text.contains("synthetic miles card"), rendered.text)
    await surface.settleNavigation()
    let importButton = try XCTUnwrap(surface.firstControl(label: "Import"))
    XCTAssertTrue(surface.activate(importButton))
    let confirmed = await surface.waitUntil { selection.confirmation != nil }
    XCTAssertTrue(confirmed, "Tapping Import must stage a confirmation before replacing anything")
    let confirmation = try XCTUnwrap(selection.confirmation)
    XCTAssertEqual(confirmation.accountID, "acct-travel")
    XCTAssertEqual(confirmation.planID, "fixture-plan")
    await surface.settleNavigation()
    rendered = await surface.captureUntilOCR(contains: ["Replace Rewards Configuration?", "Synthetic Miles Card", "Travel"])
    attach(rendered.image, "account-import-confirmation")
    XCTAssertTrue(rendered.text.contains("clearing omitted fields"), rendered.text)
    // Drive the import directly: a system confirmationDialog is presented outside
    // the hosted view hierarchy, so the harness cannot reliably reach its buttons.
    let generation = harness.model.rewardsRefreshGeneration
    await selection.importAccount(confirmation, model: harness.model)
    rendered = await surface.captureUntilOCR(contains: ["Imported Synthetic Miles Card into Travel."])
    attach(rendered.image, "account-import-success")
    XCTAssertTrue(rendered.text.contains("imported synthetic miles card into travel"), rendered.text)
    XCTAssertGreaterThan(harness.model.rewardsRefreshGeneration, generation)
    XCTAssertNil(selection.data)
    // Exercise a synthetic server rejection through the same entry point.
    selection.accountID = "acct-everyday"
    try selection.choose(data: file, fileName: "synthetic-miles.json")
    _ = await surface.captureUntilOCR(contains: ["Everyday", "Import"])
    let rejection = RewardsAccountImportSelection.Confirmation(
      planID: harness.model.settings.planID, accountID: "acct-everyday", accountName: "Everyday",
      sourceName: "Synthetic Miles Card", data: file)
    await selection.importAccount(rejection, model: harness.model)
    rendered = await surface.captureUntilOCR(contains: ["multiple rewards cards"])
    attach(rendered.image, "account-import-error")
    XCTAssertTrue(rendered.text.contains("multiple rewards cards"), rendered.text)
    XCTAssertNil(selection.confirmation)
    XCTAssertNotNil(selection.data, "A failed import retains its file for review and retry")
    harness.model.settings.planID = "other-plan"
    let reset = await surface.waitUntil { selection.accountID.isEmpty && selection.error == nil }
    XCTAssertTrue(reset)
  }

  private func attach(_ image: UIImage, _ name: String) {
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

private final class RewardsAccountImportProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "rewards-account-import.test" }
  override class func canInit(with task: URLSessionTask) -> Bool {
    (task.currentRequest ?? task.originalRequest).map(canInit(with:)) ?? false
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    do {
      XCTAssertEqual(request.httpMethod, "PUT")
      let url = try XCTUnwrap(request.url)
      XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
        "/api/rewards/accounts/card%20%2F%2050%25/config")
      var data = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          data.append(buffer, count: count)
        }
      }
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(body["plan_id"] as? String, "destination-plan")
      let payload = try XCTUnwrap(body["payload"] as? [String: Any])
      XCTAssertEqual(payload["format"] as? String, "rewards-account-config")
      XCTAssertEqual(payload["version"] as? Int, 1)
      let card = try XCTUnwrap(payload["card"] as? [String: Any])
      XCTAssertTrue(card["minimumSpend"] is NSNull)
      XCTAssertNil(card["maximumSpend"])
      let future = try XCTUnwrap(card["futureRule"] as? [String: Any])
      XCTAssertEqual(future["value"] as? Int, 17)
      XCTAssertTrue(future["limit"] is NSNull)
      XCTAssertTrue((card["subcategories"] as? [[String: Any]])?.first?["minimumSpend"] is NSNull)
      let response = Data(#"{"data":{"card":{"id":"existing-card","name":"Destination","issuer":"Example Bank","type":"miles","ynabAccountId":"acct-destination","featured":false}}}"#.utf8)
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: response)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
}

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
    filter.asOfDate = try singaporeDate(2025, 4, 10)
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

  private func singaporeDate(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
    try XCTUnwrap(RewardsCalendar.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 0)))
  }

  func testAsOfDateIsTheSingaporeDayWhateverTheDeviceZone() throws {
    let original = NSTimeZone.default
    defer { NSTimeZone.default = original }
    for zone in ["America/Los_Angeles", "Pacific/Kiritimati", "Asia/Singapore"] {
      NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
      var filter = RewardsReportFilter()
      // Midnight 10 April in Singapore is still 9 April in Los Angeles.
      filter.asOfDate = try singaporeDate(2025, 4, 10)
      filter.useAsOfDate = true
      XCTAssertEqual(filter.to, "2025-04-10", zone)
      XCTAssertEqual(RewardsCalendar.days(from: "2026-03-07", to: "2026-03-09"), 2, zone)
    }
    // 17:30 UTC on 22 Sep is 01:30 on 23 Sep in Singapore.
    XCTAssertEqual(RewardsCalendar.isoString(Date(timeIntervalSince1970: 1_790_098_200)), "2026-09-23")
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
    // Reordering a subset swaps it within the slots it held: c and b stay put,
    // no card is unhidden, and other preferences survive.
    preferences.reorder(["new", "a"], within: ["a", "b", "c", "new"])
    XCTAssertEqual(preferences.orderedIDs(["a", "b", "c", "new"]), ["c", "b", "new", "a"])
    XCTAssertEqual(preferences.hiddenCardIDs, ["b"])
    XCTAssertEqual(preferences.collapsedGroups, ["miles"])
  }

  func testReorderingAFilteredSubsetKeepsCardsOutsideItInPlace() {
    var preferences = RewardsBoardPreferences(cardOrder: ["a", "b", "c", "d"])
    // Only b and d are visible (say, Featured); move d above b.
    preferences.reorder(["d", "b"], within: ["b", "d"])
    XCTAssertEqual(preferences.orderedIDs(["a", "b", "c", "d"]), ["a", "d", "c", "b"])
  }

  func testPreferencesSavedBeforeNewFieldsStillDecode() throws {
    let legacy = #"{"hiddenCardIDs":["x"],"cardOrder":["b","a"],"collapsedGroups":["miles"]}"#
    let decoded = try JSONDecoder().decode(RewardsBoardPreferences.self, from: Data(legacy.utf8))
    XCTAssertEqual(decoded.hiddenCardIDs, ["x"])
    XCTAssertEqual(decoded.cardOrder, ["b", "a"])
    XCTAssertNil(decoded.featuredOnly)
    XCTAssertFalse(decoded.groupsByType)
    var updated = decoded
    updated.featuredOnly = false
    updated.groupsByType = true
    let roundTrip = try JSONDecoder().decode(RewardsBoardPreferences.self, from: JSONEncoder().encode(updated))
    XCTAssertEqual(roundTrip, updated)
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
  private func categoryFixture(values: [(String, String, Double, Double)]? = nil, minimumSpend: Double = 0) throws -> RewardsCardRow {
    let values = values ?? [
      ("Telcos", "blue", 60.51, 375), ("Groceries", "gray", 695.63, 500),
      ("Gas", "green", 105.15, 375), ("Food", "yellow", 343.94, 375),
      ("Transport", "purple", 234.46, 375), ("MYRIDR", "orange", 203.79, 375),
      ("Excluded", "red", 21, 375),
    ]
    let flags = values.map { name, colour, spend, cap in
      ["subcategoryId": name, "name": name, "flagColor": colour, "totalSpend": spend,
       "countedSpend": min(spend, cap), "eligibleSpend": min(spend, cap),
       "maximumSpend": cap, "rewardEarned": 0] as [String: Any]
    }
    let json: [String: Any] = [
      "card": ["id": "maybank", "name": "Maybank Mine 8008", "issuer": "Demo", "type": "cashback",
        "subcategories": [["id": "Excluded", "name": "Excluded", "flagColor": "red", "rewardValue": 0,
          "priority": 0, "active": true, "excludeFromRewards": true, "createdAt": "", "updatedAt": ""]]],
      "account_id": "demo", "account_name": "Maybank",
      "calculation": ["period": "2026-09", "total_spend": 1643.48, "counted_spend": 1447.85,
        "eligible_spend": 1447.85, "reward_earned": 105.83, "reward_earned_dollars": 105.83,
        "reward_type": "cashback", "minimum_spend": minimumSpend, "minimum_spend_met": true,
        "maximum_spend_exceeded": false, "flags": flags],
    ]
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(RewardsCardRow.self, from: JSONSerialization.data(withJSONObject: json))
  }

  func testCategoryUsageUsesActualSpendAndClampsOnlyFill() throws {
    let categories = RewardCategoryUsage.make(row: try categoryFixture())
    XCTAssertEqual(categories.map(\.id), ["Groceries", "Food", "Transport", "MYRIDR", "Gas", "Telcos", "Excluded"])
    XCTAssertEqual(categories[0].spend, 695.63)
    XCTAssertEqual(try XCTUnwrap(categories[0].ratio), 1.39126, accuracy: 0.00001)
    XCTAssertEqual(categories[0].fill, 1)
    XCTAssertTrue(categories[0].warning)
    XCTAssertTrue(categories[1].warning)
    XCTAssertFalse(categories[2].warning)
    XCTAssertEqual(categories[2].fill, 234.46 / 375, accuracy: 0.00001)
    XCTAssertTrue(categories[6].excluded)
    XCTAssertNil(categories[6].cap)
    XCTAssertNil(categories[6].ratio)
    XCTAssertFalse(categories[6].warning)
    XCTAssertEqual(categories[6].fill, 1)
    XCTAssertEqual(categories[6].spend, 21)
    var uncappedFlag = categories[6].flag
    uncappedFlag.maximumSpend = nil
    let uncapped = RewardCategoryUsage(flag: uncappedFlag, excluded: false)
    XCTAssertNil(uncapped.cap)
    XCTAssertFalse(uncapped.warning)
    let boundaries = RewardCategoryUsage.make(row: try categoryFixture(values: [
      ("Below", "blue", 89.99, 100), ("At", "blue", 90, 100),
    ]))
    XCTAssertTrue(boundaries[0].warning)
    XCTAssertFalse(boundaries[1].warning)
    let refunded = RewardsFlagRow(subcategoryId: "refund", name: "Refund", flagColor: "blue",
      totalSpend: -20, eligibleSpend: 0, rewardEarned: 0, rewardEarnedDollars: nil, rewardRate: nil,
      maximumSpend: 100)
    XCTAssertEqual(RewardCategoryUsage(flag: refunded, excluded: false).fill, 0)
  }

  func testCategorySheetRendersDarkLightAndLargeText() async throws {
    let harness = SnapshotHarness.make(baseURLString: "https://rewards-snapshot.test")
    let row = try categoryFixture()
    for (name, scheme, size) in [("dark", ColorScheme.dark, DynamicTypeSize.large),
      ("light", .light, .large), ("large-text", .dark, .accessibility1)] {
      let surface = try XCTUnwrap(SnapshotSurface(
        root: RewardCardDetailSheet(row: row, asOf: nil, icon: "🟣", currencyFormat: harness.model.currencyFormat,
          canOpenAccount: false, onEdit: {}, onOpenAccount: {})
          .environment(harness.model).environment(\.dynamicTypeSize, size).preferredColorScheme(scheme),
        size: CGSize(width: 430, height: size.isAccessibilitySize ? 1500 : 932)
      ))
      let expected = ["Groceries", "$695.63", "139%", "Food", "92%", "MYRIDR", "Excluded", "$21.00"]
      let rendered = await surface.captureUntilOCR(contains: expected, timeoutNanoseconds: 5_000_000_000)
      attach(rendered.image, "reward-categories-\(name)")
      for text in expected { XCTAssertTrue(rendered.text.contains(text.lowercased()), "Missing \(text): \(rendered.text)") }
      surface.detach()
    }
  }

  func testCategoryDetailFitsContentAndScrollsOnlyWhenNecessary() async throws {
    XCTAssertTrue(URLProtocol.registerClass(RewardsSnapshotProtocol.self))
    defer { URLProtocol.unregisterClass(RewardsSnapshotProtocol.self) }
    let harness = SnapshotHarness.make(baseURLString: "https://rewards-snapshot.test")
    let row = try categoryFixture()
    let short = try categoryFixture(values: [("Groceries", "gray", 695.63, 500)])
    let targets = try categoryFixture(minimumSpend: 800)
    var heights: [String: CGFloat] = [:]
    for (name, fixture, textSize, width) in [
      ("short", short, DynamicTypeSize.large, CGFloat(430)),
      ("seven", row, .large, 430), ("targets", targets, .large, 430),
      ("narrow", row, .large, 320), ("overflow", row, .accessibility3, 430),
    ] {
      let surface = try XCTUnwrap(SnapshotSurface(
        root: NavigationStack { RewardsView() }
          .sheet(isPresented: .constant(true)) {
            RewardCardDetailSheet(row: fixture, asOf: nil, icon: "🟣", currencyFormat: harness.model.currencyFormat,
              canOpenAccount: true, onEdit: {}, onOpenAccount: {})
              .environment(\.dynamicTypeSize, textSize)
          }
          .environment(harness.model).environment(RootChromeState())
          .environment(\.dynamicTypeSize, textSize).preferredColorScheme(.dark),
        size: CGSize(width: width, height: 932)
      ))
      defer { surface.detach() }
      // Let presentation and content-driven detent layout settle before measuring.
      _ = await surface.captureUntilOCR(contains: ["Done", "Edit"])
      try await Task.sleep(nanoseconds: 600_000_000)
      let frame = try XCTUnwrap(surface.presentedSheetFrame())
      let scroll = try XCTUnwrap(surface.presentedContentScrollView())
      let visible = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
      heights[name] = frame.height
      print("Adaptive reward sheet \(name): frame=\(frame), content=\(scroll.contentSize.height), visible=\(visible)")
      XCTAssertLessThanOrEqual(frame.height, surface.windowBounds.height)
      if name == "overflow" {
        XCTAssertGreaterThan(frame.height, surface.windowBounds.height * 0.85)
        XCTAssertGreaterThan(scroll.contentSize.height, visible + 100)
        attach(surface.captureVisible(), "reward-adaptive-overflow")
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        let bottom = await surface.captureUntilOCR(contains: ["Excluded", "$21.00"], timeoutNanoseconds: 3_000_000_000)
        attach(bottom.image, "reward-adaptive-overflow-scrolled")
        XCTAssertTrue(bottom.text.contains("excluded"), bottom.text)
        XCTAssertTrue(bottom.text.contains("$21.00"), bottom.text)
      } else {
        XCTAssertLessThanOrEqual(scroll.contentSize.height, visible + 2, "\(name) must fit without scrolling")
        var expected = ["Done", "Edit", "Groceries", "$695.63", "139%"]
        if name != "short" { expected += ["Food", "Transport", "MYRIDR", "Gas", "Telcos", "Excluded", "$21.00"] }
        if name == "targets" { expected += ["Targets", "Minimum met"] }
        let rendered = await surface.captureUntilOCR(contains: expected, timeoutNanoseconds: 3_000_000_000)
        attach(rendered.image, "reward-adaptive-\(name)")
        for text in expected { XCTAssertTrue(rendered.text.contains(text.lowercased()), "\(name) missing \(text): \(rendered.text)") }
      }
    }
    XCTAssertLessThan(try XCTUnwrap(heights["short"]), 600)
    XCTAssertGreaterThan(try XCTUnwrap(heights["seven"]), try XCTUnwrap(heights["short"]) + 150)
    XCTAssertGreaterThan(try XCTUnwrap(heights["targets"]), try XCTUnwrap(heights["seven"]) + 40)
    XCTAssertGreaterThan(try XCTUnwrap(heights["narrow"]), try XCTUnwrap(heights["seven"]))
  }

  func testNarrowCategoryRowsKeepLargeAmountsWhole() async throws {
    let harness = SnapshotHarness.make(baseURLString: "https://rewards-snapshot.test")
    let row = try categoryFixture(values: [("Quarterly groceries and dining", "purple", 12345.67, 10000)])
    for (name, size) in [("xxxlarge", DynamicTypeSize.xxxLarge), ("ax3", .accessibility3)] {
      let surface = try XCTUnwrap(SnapshotSurface(
        root: RewardCategoryBreakdown(row: row, currencyFormat: harness.model.currencyFormat)
          .padding(32).environment(\.dynamicTypeSize, size).preferredColorScheme(.light),
        size: CGSize(width: 375, height: 932)
      ))
      let expected = ["Quarterly groceries and dining", "$12,345.67", "/$10,000.00", "123%"]
      let rendered = await surface.captureUntilOCR(contains: expected, timeoutNanoseconds: 3_000_000_000)
      attach(rendered.image, "reward-categories-narrow-\(name)")
      for text in expected { XCTAssertTrue(rendered.text.contains(text.lowercased()), "Missing \(text): \(rendered.text)") }
      surface.detach()
    }
  }

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
      root: NavigationStack { RewardsReportScreen(filter: filter, allowsRange: true) }
        .environment(harness.model).environment(RootChromeState()),
      size: CGSize(width: 430, height: 1800)
    ))
    defer { surface.detach() }
    // A range is totals plus unfilled rows: spend and earned, never progress.
    let expected = ["Range Report", "20 May 2026", "1 Account", "Travel Fixture", "$100.00", "$6.00", "400 miles", "earned"]
    let rendered = await surface.captureUntilOCR(contains: expected, timeoutNanoseconds: 5_000_000_000)
    attach(rendered.image, "rewards-historical-account-filtered")
    for text in expected { XCTAssertTrue(rendered.text.contains(text.lowercased()), "Missing \(text): \(rendered.text)") }
    XCTAssertFalse(rendered.text.contains("cash fixture"), rendered.text)
    XCTAssertFalse(rendered.text.contains("$9,999.00"), rendered.text)
    XCTAssertFalse(rendered.text.contains("days left"), rendered.text)
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
    // The date menu shows only its calendar icon in the toolbar.
    let expected = ["Accounts", "Rewards", "Reflect", "Featured", "$99.70 earned", "2 below minimum",
      "Travel Fixture", "$169.20", "8 days left"]
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
    // Pending monthly qualification, $830.80 of $1,000 in May, as of 24 May:
    // $169.20 to go and eight days (24–31 May) left.
    let expected = ["Travel Fixture", "Cash Fixture", "$169.20", "monthly minimum", "8 days left",
      "$830.80 / $1,000.00", "3,323 miles earned", "$49.85 earned"]
    let board = await surface.captureUntilOCR(contains: expected, timeoutNanoseconds: 5_000_000_000)
    attach(board.image, "rewards-board-filled-rows")
    for text in expected { XCTAssertTrue(board.text.contains(text.lowercased()), "Missing \(text): \(board.text)") }
  }

  func testCardDetailSheetShowsTargetsTiersAndQualification() async throws {
    let harness = SnapshotHarness.make(baseURLString: "https://rewards-snapshot.test")
    let json = """
    {"card":{"id":"travel","name":"Travel Fixture","issuer":"Demo","type":"miles","ynabAccountId":"acct-travel","featured":true,
      "earningRate":4,"spendingTiers":[{"id":"tier-500","spendThreshold":500,"earningRate":4,"maximumSpend":900},
      {"id":"tier-1000","spendThreshold":1000,"earningRate":6}]},
     "account_id":"acct-travel","account_name":"Travel",
     "calculation":{"period":"2026-05-01/2026-05-31","total_spend":830.8,"counted_spend":830.8,"eligible_spend":830.8,
      "reward_earned":3323.2,"reward_earned_dollars":49.848,"reward_type":"miles","minimum_spend_met":true,
      "maximum_spend_exceeded":false,"qualification_status":"pending","monthly_minimum_spend":1000,
      "monthly_qualifications":[{"start":"2026-05-01","end":"2026-05-31","spend":830.8,"minimumSpend":1000,"status":"pending"}],
      "active_spending_tier_id":"tier-500","has_next_spending_tier":true,"next_spending_tier_id":"tier-1000",
      "next_spending_tier_threshold":1000,
      "periods":[{"start":"2026-05-01","end":"2026-05-31","calculation":{"period":"2026-05","total_spend":830.8,
        "counted_spend":830.8,"eligible_spend":830.8,"reward_earned":3323.2,"reward_earned_dollars":49.848,
        "reward_type":"miles","minimum_spend_met":true,"maximum_spend_exceeded":false,"flags":[]}}],
      "flags":[{"subcategoryId":"dining","name":"Dining","flagColor":"red","totalSpend":250,"countedSpend":250,
        "eligibleSpend":250,"rewardEarned":1000,"rewardRate":4,"minimumSpendMet":true,"maximumSpend":200,
        "maximumSpendExceeded":true}]}}
    """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let row = try decoder.decode(RewardsCardRow.self, from: Data(json.utf8))
    let surface = try XCTUnwrap(SnapshotSurface(
      root: RewardCardDetailSheet(
        row: row, asOf: "2026-05-24", icon: "💳", currencyFormat: harness.model.currencyFormat,
        canOpenAccount: true, onEdit: {}, onOpenAccount: {}
      )
      .environment(harness.model),
      size: CGSize(width: 430, height: 1600)
    ))
    defer { surface.detach() }
    let expected = ["Travel Fixture", "Dining over cap", "Edit", "View Transactions", "Targets",
      "This month's minimum", "Next tier", "Tiers", "From $500.00", "Active", "Qualification", "Categories",
      "$250.00", "/$200.00", "125%"]
    let rendered = await surface.captureUntilOCR(contains: expected, timeoutNanoseconds: 5_000_000_000)
    attach(rendered.image, "rewards-card-detail")
    for text in expected { XCTAssertTrue(rendered.text.contains(text.lowercased()), "Missing \(text): \(rendered.text)") }
  }

  func testHiddenCollapsedBoardAndDisabledEditorRender() async throws {
    XCTAssertTrue(URLProtocol.registerClass(RewardsSnapshotProtocol.self))
    defer { URLProtocol.unregisterClass(RewardsSnapshotProtocol.self) }
    let harness = SnapshotHarness.make(baseURLString: "https://rewards-snapshot.test")
    harness.model.settings.planID = "rewards-disabled-\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: RewardsBoardPreferences.storageKey(planID: harness.model.settings.planID)) }
    RewardsBoardPreferences(hiddenCardIDs: ["cash"], cardOrder: ["travel", "cash"], collapsedGroups: ["miles"], groupsByType: true)
      .save(planID: harness.model.settings.planID)
    let board = try XCTUnwrap(SnapshotSurface(
      root: NavigationStack { RewardsView() }.environment(harness.model).environment(RootChromeState()),
      size: CGSize(width: 430, height: 932)
    ))
    let hidden = await board.captureUntilOCR(contains: ["1 hidden", "Miles", "$99.70", "showing 1 of 2"], timeoutNanoseconds: 5_000_000_000)
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
    let header = await editor.captureUntilOCR(contains: ["Edit Rewards", "Travel", "Rewards settings"], timeoutNanoseconds: 5_000_000_000)
    for text in ["edit rewards", "travel", "rewards settings"] {
      XCTAssertTrue(header.text.contains(text), header.text)
    }
    // Main now keeps advanced rules on child screens. Exercise those links,
    // rather than expecting the old inline editor below the main form.
    for label in ["Flag-based rewards", "Disabled Dining"] {
      var opened = false
      for offset in stride(from: 0, through: 2000, by: 200) {
        _ = await editor.setMainScrollOffsetY(CGFloat(offset))
        _ = await editor.captureUntilOCR(contains: [label], timeoutNanoseconds: 300_000_000)
        if let control = editor.firstControl(labelContains: label), editor.activate(control) {
          opened = true
          break
        }
      }
      XCTAssertTrue(opened, "Could not open \(label): \(editor.accessibilityLabels())")
      _ = await editor.captureUntilOCR(contains: [label == "Flag-based rewards" ? "Colour names" : "Active"])
    }
    let rule = await editor.captureUntilOCR(contains: ["Active", "Disabled Dining", "Reward value", "miles / USD"])
    attach(rule.image, "rewards-disabled-editor-rule")
    XCTAssertTrue(rule.text.contains("disabled dining"), rule.text)
    XCTAssertTrue(rule.text.contains("active"), rule.text)
    XCTAssertTrue(editor.controls(labelContains: "reward value").contains {
      $0.object.accessibilityValue == "4"
    }, "The retained rule must still earn 4 miles: \(editor.accessibilityLabels())")
    // The retained disabled switch is visually inspected in this attachment;
    // navigating to it does not claim switch-toggle or save coverage.
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
    case "/api/rewards/accounts/acct-travel/config":
      payload = ["card": card]
    case "/api/rewards/accounts/acct-everyday/config":
      let data = Data(#"{"error":{"id":"400.1","name":"validation_error","detail":"This account has multiple rewards cards; resolve them before exchanging configuration."}}"#.utf8)
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
      return
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

/// Expected values are worked out by hand from the fixture numbers, never read
/// back from the projection under test.
final class RewardRowProjectionTests: XCTestCase {
  private let sgd = CurrencyFormat(
    isoCode: "SGD", exampleFormat: "$123,456.78", decimalDigits: 2,
    decimalSeparator: ".", groupSeparator: ",", symbolFirst: true, currencySymbol: "$"
  )

  // MARK: Minimum

  func testBelowMinimumShowsRemainderOnRawSpendWithPeriodDeadline() throws {
    let projection = try project(["minimum_spend": 800, "total_spend": 698, "counted_spend": 690, "minimum_spend_met": false])
    XCTAssertEqual(projection.action, .minimum(remaining: 102))
    XCTAssertEqual(projection.tone, .needsMinimum)
    XCTAssertEqual(projection.basis, .init(spend: 698, target: 800))
    XCTAssertEqual(try XCTUnwrap(projection.fill), 0.8725, accuracy: 0.0001)
    // 23 Sep to 30 Sep inclusive.
    XCTAssertEqual(projection.deadline, .init(end: "2026-09-30", days: 8, kind: .ends))
    let text = RewardRowText(projection, currencyFormat: sgd)
    XCTAssertEqual(text.amount, "$102.00")
    XCTAssertEqual(text.actionLabel, "to minimum")
    XCTAssertEqual(text.deadline, "8 days left")
    XCTAssertEqual(text.basisLine, "$698.00 / $800.00 · $0.00 earned")
    XCTAssertFalse(text.isUrgent)
  }

  func testExactlyAtMinimumIsNotAmber() throws {
    let projection = try project(["minimum_spend": 800, "total_spend": 800, "minimum_spend_met": true])
    XCTAssertEqual(RewardRowText(projection, currencyFormat: sgd).actionLabel, "Minimum met")
    XCTAssertEqual(projection.tone, .earning)
    XCTAssertEqual(projection.fill, 1)
    XCTAssertEqual(projection.basis, .init(spend: 800, target: 800))
  }

  func testAboveMinimumMovesToCapHeadroomOnCountedSpend() throws {
    let projection = try project([
      "minimum_spend": 500, "maximum_spend": 1000, "total_spend": 700, "counted_spend": 650, "minimum_spend_met": true,
    ])
    XCTAssertEqual(projection.action, .capHeadroom(remaining: 350))
    XCTAssertEqual(projection.basis, .init(spend: 650, target: 1000))
    XCTAssertEqual(projection.tone, .earning)
  }

  func testRemainderRoundsUpToTheCent() throws {
    let projection = try project(["minimum_spend": 100, "total_spend": 99.996, "minimum_spend_met": false])
    XCTAssertEqual(RewardRowText(projection, currencyFormat: sgd).amount, "$0.01")
    XCTAssertEqual(RewardRowText.roundedUpToCent(102.0000000001), 102)
    XCTAssertEqual(RewardRowText.roundedUpToCent(101.001), 101.01)
  }

  // MARK: Tiers and caps

  func testUnmetBaseMinimumOutranksNextTier() throws {
    let projection = try project([
      "minimum_spend": 500, "total_spend": 300, "minimum_spend_met": false,
      "has_next_spending_tier": true, "next_spending_tier_threshold": 500,
    ])
    XCTAssertEqual(projection.action, .minimum(remaining: 200))
  }

  func testNextTierUsesTotalSpendAgainstThreshold() throws {
    let projection = try project([
      "total_spend": 1340, "counted_spend": 1300, "maximum_spend": 1600,
      "has_next_spending_tier": true, "next_spending_tier_threshold": 1600, "reward_earned": 76,
    ])
    XCTAssertEqual(projection.action, .nextTier(remaining: 260))
    XCTAssertEqual(projection.basis, .init(spend: 1340, target: 1600))
    XCTAssertEqual(projection.tone, .earning)
    XCTAssertEqual(RewardRowText(projection, currencyFormat: sgd).basisLine, "$1,340.00 / $1,600.00 · $76.00 earned")
  }

  func testIntermediateCapShowsNextTierWithException() throws {
    let projection = try project([
      "total_spend": 1340, "maximum_spend": 1000, "maximum_spend_exceeded": true,
      "has_next_spending_tier": true, "next_spending_tier_threshold": 1600, "should_stop_using": false,
    ])
    XCTAssertEqual(projection.action, .nextTier(remaining: 260))
    XCTAssertEqual(projection.exceptions, [.tierCapReached])
    XCTAssertFalse(projection.isTerminalCap)
  }

  func testTerminalCapIsCompleteFullAndReportsSpendBeyondCap() throws {
    let projection = try project([
      "total_spend": 2150, "counted_spend": 2000, "maximum_spend": 2000, "maximum_spend_exceeded": true,
      "should_stop_using": true, "has_next_spending_tier": false, "reward_earned": 80,
    ])
    XCTAssertEqual(projection.action, .capReached(beyond: 150, terminal: true))
    XCTAssertEqual(projection.tone, .complete)
    XCTAssertEqual(projection.fill, 1)
    XCTAssertEqual(projection.deadline?.kind, .resets)
    let text = RewardRowText(projection, currencyFormat: sgd)
    XCTAssertEqual(text.actionLabel, "Bonus cap reached")
    XCTAssertNil(text.amount)
    XCTAssertEqual(text.deadline, "Resets in 8 days")
    XCTAssertEqual(text.basisLine, "$2,000.00 / $2,000.00 · $80.00 earned · $150.00 beyond cap")
  }

  func testTopTierWithoutCardCapIsEarningAndFull() throws {
    // $800 base minimum, $1,600 top tier, caps only on categories with room left.
    let projection = try project([
      "minimum_spend": 1600, "total_spend": 1650, "counted_spend": 1650, "reward_earned": 90,
      "active_spending_tier_id": "level-1600", "has_next_spending_tier": false,
      "flags": [flag("Dining", total: 300, maximum: 375), flag("Everywhere else", total: 1350)],
    ], card: ["minimumSpend": 800, "spendingTiers": [["id": "level-1600", "spendThreshold": 1600]]])
    XCTAssertEqual(projection.action, .topTier)
    XCTAssertEqual(projection.tone, .earning)
    XCTAssertEqual(projection.fill, 1)
    XCTAssertNil(projection.basis)
    XCTAssertEqual(projection.deadline?.kind, .resets)
    XCTAssertTrue(projection.exceptions.isEmpty)
    XCTAssertFalse(projection.isTerminalCap)
    let text = RewardRowText(projection, currencyFormat: sgd)
    XCTAssertEqual(text.actionLabel, "Highest tier active")
    XCTAssertNil(text.amount)
    XCTAssertEqual(text.basisLine, "$1,650.00 spent · $90.00 earned")
  }

  func testTopTierWithCardCapStillShowsHeadroom() throws {
    let projection = try project([
      "minimum_spend": 1600, "maximum_spend": 2000, "total_spend": 1650, "counted_spend": 1650,
      "has_next_spending_tier": false,
    ], card: ["spendingTiers": [["id": "level-1600", "spendThreshold": 1600]]])
    XCTAssertEqual(projection.action, .capHeadroom(remaining: 350))
  }

  func testUntieredCardWithOnlyCategoryCapsSaysNoCardCap() throws {
    let projection = try project(["total_spend": 400, "flags": [flag("Dining", total: 100, maximum: 500)]])
    XCTAssertEqual(projection.action, .noTarget(categoryCaps: true))
    XCTAssertEqual(projection.tone, .neutral)
    XCTAssertEqual(RewardRowText(projection, currencyFormat: sgd).actionLabel, "No card cap")
  }

  func testOlderServerWithoutStopFlagTreatsExceededCapAsTerminal() throws {
    let projection = try project(["total_spend": 1000, "counted_spend": 1000, "maximum_spend": 1000, "maximum_spend_exceeded": true])
    XCTAssertEqual(projection.action, .capReached(beyond: 0, terminal: true))
  }

  func testPartialBlockHeadroomStillCountsAsCapReached() throws {
    // Less than one block left: the server flags the cap as exceeded.
    let projection = try project([
      "total_spend": 996, "counted_spend": 995, "maximum_spend": 1000, "maximum_spend_exceeded": true, "should_stop_using": true,
    ])
    XCTAssertEqual(projection.action, .capReached(beyond: 0, terminal: true))
    XCTAssertEqual(projection.fill, 1)
    XCTAssertEqual(projection.basis, .init(spend: 995, target: 1000))
  }

  func testUnlimitedCardHasNoFabricatedTargetOrFill() throws {
    let extras: [[String: Any]] = [[:], ["minimum_spend": 0, "maximum_spend": 0]]
    for extra in extras {
      let projection = try project(extra.merging(["total_spend": 420, "reward_earned": 8.4]) { $1 })
      XCTAssertEqual(projection.action, .noTarget(categoryCaps: false))
      XCTAssertNil(projection.fill)
      XCTAssertNil(projection.basis)
      XCTAssertNotEqual(projection.tone, .complete)
      XCTAssertEqual(RewardRowText(projection, currencyFormat: sgd).basisLine, "$420.00 spent · $8.40 earned")
    }
  }

  // MARK: Qualification

  // A happy-path rendered row cannot catch false qualification from withheld
  // server flags, or treating finite category caps as the whole card's limit.
  func testMetMinimumDoesNotImplyTerminalCategoryExhaustionOrQualification() throws {
    let calculation: [String: Any] = [
      "minimum_spend": 600, "total_spend": 796.39, "minimum_spend_met": true,
      "flags": [flag("Online", total: 449.72, maximum: 416, exceeded: true),
        flag("Uncapped", total: 346.67)],
    ]
    let qualified = try project(calculation)
    XCTAssertEqual(qualified.tone, .earning)
    XCTAssertEqual(qualified.basis, .init(spend: 796.39, target: 600))
    XCTAssertEqual(qualified.fill, 1)
    XCTAssertFalse(qualified.isTerminalCap)
    XCTAssertEqual(RewardRowText(qualified, currencyFormat: sgd).actionLabel, "Minimum met")
    XCTAssertEqual(RewardRowText(qualified, currencyFormat: sgd).exceptionLines, ["Online over cap"])
    for withheld in [["minimum_spend_met": false] as [String: Any], ["qualification_status": "pending"]] {
      let projection = try project(calculation.merging(withheld) { $1 })
      XCTAssertNotEqual(projection.tone, .earning)
      XCTAssertNotEqual(RewardRowText(projection, currencyFormat: sgd).actionLabel, "Minimum met")
    }
  }

  func testFailedMonthIsNamedOnlyAfterItClosesIncludingAnchoredMonths() throws {
    let fixtureIsCurrentYear = RewardsCalendar.today().hasPrefix("2026-")
    let july = fixtureIsCurrentYear ? "July minimum missed" : "July 2026 minimum missed"
    let anchored = fixtureIsCurrentYear ? "15 Jul–14 Aug minimum missed" : "15 Jul 2026–14 Aug 2026 minimum missed"
    for (start, end, label) in [("2026-07-01", "2026-07-31", july),
      ("2026-07-15", "2026-08-14", anchored)] {
      let calculation: [String: Any] = [
        "qualification_status": "failed", "minimum_spend_met": false,
        "monthly_qualifications": [["start": start, "end": end, "spend": 200,
          "minimumSpend": 300, "status": "failed"]],
      ]
      let closed = try project(calculation, period: ("2026-07-01", "2026-09-30"))
      XCTAssertEqual(closed.tone, .failed)
      XCTAssertEqual(RewardRowText(closed, currencyFormat: sgd).actionLabel, label)
      let historicalEnd = try project(calculation, asOf: end)
      XCTAssertEqual(historicalEnd.tone, .failed)
      let open = try project(calculation, period: ("2026-07-01", "2026-09-30"), asOf: start)
      XCTAssertEqual(open.tone, .needsMinimum)
      XCTAssertEqual(open.action, .monthlyMinimum(remaining: 100))
      let range = try project(calculation, isRange: true)
      XCTAssertEqual(range.tone, .neutral)
    }
    let today = RewardsCalendar.today()
    let current = try project([
      "qualification_status": "failed", "minimum_spend_met": false,
      "monthly_qualifications": [["start": today, "end": today, "spend": 0,
        "minimumSpend": 300, "status": "failed"]],
    ], asOf: today)
    XCTAssertEqual(current.action, .monthlyMinimum(remaining: 300))
    XCTAssertEqual(current.tone, .needsMinimum)
  }

  func testPendingMonthBehindUsesTheMonthAndItsEnd() throws {
    // Anchored three-month period; the month ends before the period does.
    let projection = try project([
      "total_spend": 900, "qualification_status": "pending", "minimum_spend_met": false,
      "monthly_qualifications": [
        ["start": "2026-08-01", "end": "2026-08-31", "spend": 400, "minimumSpend": 300, "status": "met"],
        ["start": "2026-09-01", "end": "2026-09-30", "spend": 250, "minimumSpend": 300, "status": "pending"],
      ],
    ], period: ("2026-08-01", "2026-10-31"))
    XCTAssertEqual(projection.action, .monthlyMinimum(remaining: 50))
    XCTAssertEqual(projection.basis, .init(spend: 250, target: 300))
    XCTAssertEqual(projection.deadline, .init(end: "2026-09-30", days: 8, kind: .ends))
    XCTAssertEqual(RewardRowText(projection, currencyFormat: sgd).actionLabel, "to monthly minimum")
  }

  func testPendingMonthAlreadyMetFallsThroughWithLockedException() throws {
    let projection = try project([
      "total_spend": 900, "qualification_status": "pending", "minimum_spend_met": false,
      "monthly_qualifications": [
        ["start": "2026-09-01", "end": "2026-09-30", "spend": 320, "minimumSpend": 300, "status": "met"],
        ["start": "2026-10-01", "end": "2026-10-31", "spend": 0, "minimumSpend": 300, "status": "pending"],
      ],
    ], period: ("2026-09-01", "2026-10-31"))
    XCTAssertEqual(projection.action, .noTarget(categoryCaps: false))
    XCTAssertEqual(projection.exceptions, [.rewardsLocked(until: "2026-10-31")])
    XCTAssertEqual(RewardRowText(projection, currencyFormat: sgd).exceptionLines, ["Rewards unlock after 31 Oct"])
  }

  func testFailedQualificationOutranksAMetCardMinimum() throws {
    let projection = try project([
      "minimum_spend": 500, "total_spend": 700, "qualification_status": "failed", "minimum_spend_met": false,
    ])
    XCTAssertEqual(projection.action, .qualificationFailed)
    XCTAssertEqual(projection.tone, .failed)
    XCTAssertNil(projection.fill)
    XCTAssertEqual(projection.deadline?.kind, .resets)
    XCTAssertTrue(projection.exceptions.isEmpty)
  }

  func testServerMinimumUnmetWithoutARawGapIsFlagged() throws {
    // Spend reached the figure, but a tier minimum still withholds rewards.
    let projection = try project(["minimum_spend": 500, "total_spend": 600, "minimum_spend_met": false])
    XCTAssertEqual(projection.action, .noTarget(categoryCaps: false))
    XCTAssertEqual(projection.exceptions, [.minimumNotMet])
  }

  // MARK: Category exceptions

  func testCategoryOverCapShowsWhenCardCapIsNot() throws {
    let projection = try project(["total_spend": 400, "flags": [
      flag("Dining", total: 250, maximum: 200, exceeded: true),
      flag("Groceries", total: 50, maximum: 200, exceeded: false),
    ]])
    XCTAssertEqual(projection.exceptions, [.categoriesAtCap(names: ["Dining"], over: true)])
    XCTAssertEqual(RewardRowText(projection, currencyFormat: sgd).exceptionLines, ["Dining over cap"])
  }

  func testCategoryExactlyAtCapSaysAtCap() throws {
    let projection = try project(["total_spend": 400, "flags": [
      flag("Dining", total: 200, maximum: 200, exceeded: true),
      flag("Travel", total: 150, maximum: 150, exceeded: true),
    ]])
    XCTAssertEqual(RewardRowText(projection, currencyFormat: sgd).exceptionLines, ["2 categories at cap"])
  }

  func testCardCapExceededSuppressesCategoryCapException() throws {
    let projection = try project([
      "total_spend": 1000, "maximum_spend": 1000, "maximum_spend_exceeded": true, "should_stop_using": true,
      "flags": [flag("Dining", total: 250, maximum: 200, exceeded: true)],
    ])
    XCTAssertTrue(projection.exceptions.isEmpty)
  }

  func testCategoryBelowItsMinimumOnceCardMinimumIsMet() throws {
    let projection = try project(["total_spend": 400, "flags": [
      flag("Dining", total: 120, minimum: 200, minimumMet: false),
    ]])
    XCTAssertEqual(projection.exceptions, [.categoriesBelowMinimum(names: ["Dining"])])
  }

  func testMoreThanTwoExceptionsCollapseIntoAMoreLine() throws {
    let projection = try project([
      "total_spend": 1340, "maximum_spend": 1000, "maximum_spend_exceeded": false,
      "has_next_spending_tier": true, "next_spending_tier_threshold": 1600,
      "flags": [
        flag("Dining", total: 250, maximum: 200, exceeded: true),
        flag("Travel", total: 20, minimum: 100, minimumMet: false),
      ],
      "qualification_status": "pending",
      "monthly_qualifications": [["start": "2026-09-01", "end": "2026-09-30", "spend": 400, "minimumSpend": 300, "status": "met"]],
    ])
    XCTAssertEqual(projection.exceptions.count, 3)
    let lines = RewardRowText(projection, currencyFormat: sgd).exceptionLines
    XCTAssertEqual(lines.count, 3)
    XCTAssertEqual(lines.last, "+1 more")
  }

  // MARK: Dates

  func testLastDayAndResetTomorrowWording() throws {
    let ends = try project(["minimum_spend": 100, "total_spend": 10], period: ("2026-02-01", "2026-02-28"), asOf: "2026-02-28")
    XCTAssertEqual(ends.deadline?.days, 1)
    let endsText = RewardRowText(ends, currencyFormat: sgd)
    XCTAssertEqual(endsText.deadline, "Last day")
    XCTAssertTrue(endsText.isUrgent)
    let resets = try project(["total_spend": 10], period: ("2026-02-01", "2026-02-28"), asOf: "2026-02-28")
    XCTAssertEqual(RewardRowText(resets, currencyFormat: sgd).deadline, "Resets tomorrow")
    XCTAssertEqual(RewardRowText.deadlineText(.init(end: "2026-02-28", days: 0, kind: .ends)), "Period ended")
  }

  func testHistoricalAsOfCountsDaysFromThatDate() throws {
    let projection = try project(["minimum_spend": 800, "total_spend": 100], asOf: "2026-09-10")
    XCTAssertEqual(projection.deadline?.days, 21)
  }

  func testDaysLeftDoNotDependOnTheDeviceZone() throws {
    let original = NSTimeZone.default
    defer { NSTimeZone.default = original }
    for zone in ["America/Los_Angeles", "Europe/London", "Pacific/Kiritimati"] {
      NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
      // Across the March DST change in the US and the UK.
      let projection = try project(["minimum_spend": 800, "total_spend": 100], period: ("2026-03-01", "2026-03-31"), asOf: "2026-03-07")
      XCTAssertEqual(projection.deadline?.days, 25, zone)
    }
  }

  func testMissingAsOfLeavesNoDeadline() throws {
    let projection = try project(["minimum_spend": 800, "total_spend": 100], asOf: nil)
    XCTAssertNil(projection.deadline)
    XCTAssertEqual(projection.action, .minimum(remaining: 700))
  }

  // MARK: Range, summary, ordering

  func testRangeRowsHaveNoFillDeadlineOrExceptions() throws {
    let projection = try project([
      "total_spend": 1000, "maximum_spend": 500, "maximum_spend_exceeded": true, "reward_earned": 40,
      "flags": [flag("Dining", total: 250, maximum: 200, exceeded: true)],
    ], isRange: true)
    XCTAssertEqual(projection.action, .range)
    XCTAssertNil(projection.fill)
    XCTAssertNil(projection.deadline)
    XCTAssertTrue(projection.exceptions.isEmpty)
    let text = RewardRowText(projection, currencyFormat: sgd)
    XCTAssertEqual(text.amount, "$40.00")
    XCTAssertEqual(text.basisLine, "$1,000.00 spent")
  }

  func testSummaryCountsLabelledStatusesAndApproximatesOnlyValuedMiles() throws {
    let below = try project(["minimum_spend": 800, "total_spend": 100])
    let failed = try project(["qualification_status": "failed"])
    let capped = try project(["maximum_spend": 100, "total_spend": 100, "counted_spend": 100, "maximum_spend_exceeded": true, "should_stop_using": true])
    let plain = try project(["total_spend": 10])
    let valued = try report(miles: 1300, cashback: 50, rewardDollars: 69.5, valuation: 0.015)
    let summary = RewardsBoardSummary(report: valued, projections: [below, failed, capped, plain], currencyFormat: sgd)
    XCTAssertEqual(summary.line, "≈ $69.50 earned · 1 below minimum · 1 failed · 1 capped")
    let unvalued = try report(miles: 1300, cashback: 50, rewardDollars: 50, valuation: 0)
    XCTAssertEqual(
      RewardsBoardSummary(report: unvalued, projections: [plain], currencyFormat: sgd).line,
      "$50.00 cashback · 1,300 miles"
    )
    let cashOnly = try report(miles: 0, cashback: 50, rewardDollars: 50, valuation: 0.015)
    XCTAssertEqual(RewardsBoardSummary(report: cashOnly, projections: [], currencyFormat: sgd).line, "$50.00 earned")
  }

  func testFallbackOrderIsNearestDeadlineThenName() throws {
    let late = try project(["minimum_spend": 800], name: "Alpha", id: "late", period: ("2026-09-01", "2026-10-15"))
    let soonB = try project(["minimum_spend": 800], name: "Bravo", id: "soon-b")
    let soonA = try project(["minimum_spend": 800], name: "apple", id: "soon-a")
    let none = try project(["minimum_spend": 800], name: "Aardvark", id: "none", asOf: nil)
    XCTAssertEqual(RewardsBoardOrdering.fallbackOrder([late, none, soonB, soonA]), ["soon-a", "soon-b", "late", "none"])
  }

  func testFallbackOrderPutsCardsNeedingSpendBeforeCappedOnes() throws {
    // The capped card resets in 5 days (23–27 Sep); the minimum card has 8.
    let capped = try project(["maximum_spend": 2000, "total_spend": 2000, "counted_spend": 2000, "maximum_spend_exceeded": true,
      "should_stop_using": true], name: "Capped", id: "capped", period: ("2026-09-01", "2026-09-27"))
    let minimum = try project(["minimum_spend": 800], name: "Minimum", id: "minimum")
    let unlimited = try project([:], name: "Unlimited", id: "unlimited", period: ("2026-09-01", "2026-09-24"))
    XCTAssertEqual(RewardsBoardOrdering.fallbackOrder([capped, unlimited, minimum]), ["minimum", "unlimited", "capped"])
  }

  func testAccessibilityValueStatesTargetProgressAndDeadline() throws {
    let projection = try project(["minimum_spend": 500, "total_spend": 300, "reward_earned": 1300, "reward_type": "miles"])
    let value = RewardRowText(projection, currencyFormat: sgd).accessibilityValue
    XCTAssertEqual(value, "$200.00 to minimum. $300.00 of $500.00, 60 per cent. 8 days left, ends 30 Sep. 1,300 miles earned")
  }

  // MARK: Fixtures

  @MainActor
  func testStatusRowsRenderLightDarkAndLargeText() async throws {
    let dcs = try project([
      "minimum_spend": 600, "total_spend": 796.39, "reward_earned": 35,
      "flags": [flag("Online", total: 449.72, maximum: 416, exceeded: true),
        flag("FCY", total: 210.77, maximum: 325), flag("Tap", total: 135.90, maximum: 416)],
    ], name: "DCS Flex", id: "dcs")
    let maybank = try project([
      "minimum_spend": 1600, "total_spend": 1650, "reward_earned": 90, "has_next_spending_tier": false,
      "flags": [flag("Groceries", total: 450, maximum: 400, exceeded: true), flag("Other", total: 1200)],
    ], name: "Maybank", id: "maybank", card: ["spendingTiers": [["id": "top", "spendThreshold": 1600]]])
    let unmet = try project(["minimum_spend": 600, "total_spend": 0, "minimum_spend_met": false],
      name: "New monthly period", id: "unmet")
    let capped = try project([
      "maximum_spend": 2000, "total_spend": 2150, "counted_spend": 2000,
      "maximum_spend_exceeded": true, "should_stop_using": true, "reward_earned": 80,
    ], name: "Card-wide cap", id: "capped")
    let failed = try project([
      "qualification_status": "failed", "minimum_spend_met": false, "total_spend": 700,
      "monthly_qualifications": [["start": "2026-07-01", "end": "2026-07-31", "spend": 200,
        "minimumSpend": 300, "status": "failed"]],
    ], name: "Quarterly qualification", id: "failed", period: ("2026-07-01", "2026-09-30"))
    let next = try project([
      "total_spend": 1340, "maximum_spend": 1000, "maximum_spend_exceeded": true,
      "has_next_spending_tier": true, "next_spending_tier_threshold": 1600, "should_stop_using": false,
    ], name: "Intermediate tier cap", id: "next")
    let headroom = try project(["total_spend": 700, "maximum_spend": 1000], name: "Bonus headroom", id: "headroom")
    let pending = try project([
      "minimum_spend": 600, "total_spend": 900, "qualification_status": "pending", "minimum_spend_met": false,
      "monthly_qualifications": [["start": "2026-09-01", "end": "2026-09-30", "spend": 900,
        "minimumSpend": 300, "status": "met"]],
    ], name: "Pending qualification", id: "pending")
    let unlimited = try project(["total_spend": 420, "reward_earned": 8.4], name: "No minimum or cap", id: "unlimited")
    let range = try project(["total_spend": 420, "reward_earned": 8.4], name: "Historical aggregate", id: "range", isRange: true)
    let withheld = try project(["minimum_spend": 500, "total_spend": 600, "minimum_spend_met": false],
      name: "Withheld minimum", id: "withheld")
    let mixed = try project([
      "total_spend": 1340, "qualification_status": "pending",
      "flags": [flag("Online", total: 450, maximum: 416, exceeded: true),
        flag("Travel", total: 20, minimum: 100, minimumMet: false)],
    ], name: "Mixed warnings", id: "mixed")
    // Unlike the mixed row, this warning is visible on a full green surface.
    // Amber footnote text failed contrast on increased-contrast mint fills.
    let categoryMinimum = try project([
      "minimum_spend": 600, "total_spend": 800,
      "flags": [flag("Dining", total: 120, minimum: 200, minimumMet: false),
        flag("Uncapped", total: 680)],
    ], name: "Category minimum outstanding", id: "category-minimum")
    let july = RewardsCalendar.today().hasPrefix("2026-") ? "July minimum missed" : "July 2026 minimum missed"
    let groups: [(String, [RewardRowProjection], [String])] = [
      ("main", [dcs, maybank, unmet, capped, failed],
        ["Minimum met", "Online over cap", "Highest tier active", "Groceries over cap", "to minimum", "Bonus cap reached", july]),
      ("boundaries", [next, headroom, pending, unlimited, range, withheld, mixed],
        ["to next tier", "left before bonus cap", "Rewards unlock after", "No cap", "Historical aggregate",
          "Minimum not yet met", "+1 more"]),
      ("category-minimum", [categoryMinimum], ["Minimum met", "Dining below its minimum"]),
    ]
    for (group, rows, expected) in groups {
      for (appearance, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large),
        ("dark", .dark, .large), ("large-text", .dark, .accessibility1),
        ("light-increased", .light, .large), ("dark-increased", .dark, .large)] {
        let surface = try XCTUnwrap(SnapshotSurface(
          root: VStack(spacing: 12) {
            ForEach(rows, id: \.cardID) { projection in
              RewardFilledRow(projection: projection, currencyFormat: self.sgd)
            }
          }
          .padding(16).frame(maxHeight: .infinity, alignment: .top).background(Theme.canvas)
          .environment(\.dynamicTypeSize, size).preferredColorScheme(scheme),
          size: CGSize(width: 430, height: size.isAccessibilitySize ? 2400 : 1400)
        ))
        let window = try XCTUnwrap(surface.firstDescendant(UIView.self)?.window)
        window.traitOverrides.accessibilityContrast = appearance.hasSuffix("increased") ? .high : .normal
        let rendered = await surface.captureUntilOCR(contains: expected, timeoutNanoseconds: 5_000_000_000)
        let attachment = XCTAttachment(image: rendered.image)
        attachment.name = "reward-status-\(group)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
        for text in expected {
          XCTAssertTrue(rendered.text.contains(text.lowercased()), "Missing \(text): \(rendered.text)")
        }
        for row in rows { XCTAssertTrue(surface.accessibilityLabels().contains(row.title)) }
        surface.detach()
      }
    }
  }

  private func project(
    _ calculation: [String: Any],
    name: String = "Everyday Card",
    id: String = "card",
    period: (String, String) = ("2026-09-01", "2026-09-30"),
    asOf: String? = "2026-09-23",
    isRange: Bool = false,
    card: [String: Any] = [:]
  ) throws -> RewardRowProjection {
    var calc: [String: Any] = [
      "period": "\(period.0)/\(period.1)", "total_spend": 0, "counted_spend": calculation["total_spend"] ?? 0,
      "eligible_spend": 0, "reward_earned": 0, "reward_earned_dollars": 0, "reward_type": "cashback",
      "minimum_spend_met": true, "maximum_spend_exceeded": false, "flags": [],
    ]
    calc.merge(calculation) { $1 }
    var withPeriod = calc
    withPeriod["periods"] = [["start": period.0, "end": period.1, "calculation": calc]]
    let json: [String: Any] = [
      "card": ([
        "id": id, "name": name, "issuer": "Demo", "type": calc["reward_type"] ?? "cashback", "ynabAccountId": "acct-\(id)", "featured": true,
      ] as [String: Any]).merging(card) { $1 },
      "account_id": "acct-\(id)", "account_name": name, "calculation": withPeriod,
    ]
    let row = try decoder.decode(RewardsCardRow.self, from: JSONSerialization.data(withJSONObject: json))
    return .make(row: row, asOf: asOf, isRange: isRange)
  }

  private func flag(
    _ name: String,
    total: Double,
    maximum: Double? = nil,
    exceeded: Bool = false,
    minimum: Double? = nil,
    minimumMet: Bool = true
  ) -> [String: Any] {
    var flag: [String: Any] = [
      "subcategoryId": name.lowercased(), "name": name, "flagColor": "red", "totalSpend": total, "countedSpend": total,
      "eligibleSpend": total, "rewardEarned": 0, "minimumSpendMet": minimumMet, "maximumSpendExceeded": exceeded,
    ]
    if let maximum { flag["maximumSpend"] = maximum }
    if let minimum { flag["minimumSpend"] = minimum }
    return flag
  }

  private func report(miles: Double, cashback: Double, rewardDollars: Double, valuation: Double) throws -> RewardsReport {
    let json: [String: Any] = [
      "group_by": "flag", "miles_valuation": valuation,
      "totals": ["spend": 0, "reward_dollars": rewardDollars, "cashback": cashback, "miles": miles],
      "cards": [], "groups": [],
    ]
    return try decoder.decode(RewardsReport.self, from: JSONSerialization.data(withJSONObject: json))
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }
}
