import Testing

@testable import HowMuch

// The live-date Simulator flow cannot exercise February, leap years, or the
// exact anchor boundary. These cases catch rolling (rather than clamping)
// dates, treating the billing day as an end date, and wrong rule precedence.
struct RewardDraftPeriodTests {
  @Test(arguments: [29, 30, 31])
  func shortMonthClampsAndReanchors(day: Int) throws {
    var draft = RewardCardDraft.empty()
    draft.billingType = .billing
    draft.billingDay = String(day)
    let before = try #require(RewardDraftPeriod.make(draft, asOf: "2026-02-27"))
    #expect(before.start == "2026-01-\(day)")
    #expect(before.end == "2026-02-27")
    let boundary = try #require(RewardDraftPeriod.make(draft, asOf: "2026-02-28"))
    #expect(boundary.start == "2026-02-28")
    #expect(boundary.end == "2026-03-\(day - 1)")
  }

  @Test func precedenceAndFutureAnchor() throws {
    var draft = RewardCardDraft.empty()
    draft.billingType = .billing
    draft.billingDay = "15"
    draft.promoStart = "2026-09-10"
    draft.promoEnd = "2026-10-10"
    draft.rewardMonthCount = "3"
    draft.rewardAnchorDate = "2026-09-01"
    draft.rewardMonthlyMinimum = "500"
    var period = try #require(RewardDraftPeriod.make(draft, asOf: "2026-09-26"))
    #expect(period.start == "2026-09-01")
    #expect(period.end == "2026-11-30")
    draft.rewardAnchorDate = "2026-10-01"
    period = try #require(RewardDraftPeriod.make(draft, asOf: "2026-09-26"))
    #expect(period.start == "2026-09-10")
    #expect(period.end == "2026-10-10")
    draft.promoStart = ""
    draft.promoEnd = ""
    period = try #require(RewardDraftPeriod.make(draft, asOf: "2026-09-26"))
    #expect(period.start == "2026-09-15")
    #expect(period.end == "2026-10-14")
    draft.billingType = .calendar
    draft.earningRate = "invalid unrelated value"
    period = try #require(RewardDraftPeriod.make(draft, asOf: "2026-09-26"))
    #expect(period.start == "2026-09-01")
    #expect(period.end == "2026-09-30")
  }

  @Test func anchoredMonthsDoNotDriftAfterFebruary() throws {
    var draft = RewardCardDraft.empty()
    draft.rewardMonthCount = "2"
    draft.rewardAnchorDate = "2024-01-31"
    draft.rewardMonthlyMinimum = "0"
    let before = try #require(RewardDraftPeriod.make(draft, asOf: "2024-03-30"))
    #expect(before.start == "2024-01-31")
    #expect(before.end == "2024-03-30")
    let after = try #require(RewardDraftPeriod.make(draft, asOf: "2024-03-31"))
    #expect(after.start == "2024-03-31")
    #expect(after.end == "2024-05-30")
    draft.rewardAnchorDate = "2026-02-30"
    #expect(RewardDraftPeriod.make(draft, asOf: "2026-09-26") == nil)
  }
}
