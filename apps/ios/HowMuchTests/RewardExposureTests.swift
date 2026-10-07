import XCTest
@testable import HowMuch

/// The Sun Arc mapping from a projection to the picture values `h` (across,
/// the minimum journey) and `v` (up, the tier and cap journey).
///
/// Only the mapping is isolated here. The fixture cards in the Rewards recipe
/// reach a handful of points on it; these tests reach the hand-overs, the
/// clamps and the partial-block cap that no fixture can sweep. Expected values
/// come from `docs/frontend/rewards-exposure-card.md`, never from the
/// implementation. The failure modes they guard: a tier mixed into the minimum
/// journey, a cap climb measured from zero (a jump at the minimum), a reached
/// tier ignored (a jump at the tier), a further tier sinking the sun, a value
/// that falls as spend grows, a partial-block cap drawn below the top, and
/// amounts that are not finite reaching the picture.
final class RewardExposureTests: XCTestCase {
  // MARK: The walk

  /// The shape of `fixtures/rewards-account-config.json`: a minimum of 100, one
  /// tier at 1,000, a cap of 2,400 at the base level and 2,998 at the tier, and
  /// earning blocks of 5. Spend runs from a refund-heavy -50 to 3,200.
  func testWalkAcrossTheMinimumTheTierAndTheCap() throws {
    var previous: RewardExposure.Pose?
    var seenCap = false
    for dollars in stride(from: -50, through: 3200, by: 1) {
      let spend = Double(dollars)
      let counted = dollars < 0 ? 0 : (spend / 5).rounded(.down) * 5
      let tierReached = dollars >= 1000
      let minimumMet = dollars >= 100
      let cap = minimumMet ? 2998.0 : 2400.0
      var calculation: [String: Any] = [
        "total_spend": spend, "counted_spend": counted,
        "minimum_spend": tierReached ? 1000 : 100, "minimum_spend_met": minimumMet,
        "maximum_spend": cap, "maximum_spend_exceeded": minimumMet && cap - counted < 5,
        "has_next_spending_tier": !tierReached,
      ]
      if tierReached {
        calculation["active_spending_tier_id"] = "tier-1000"
      } else {
        calculation["next_spending_tier_threshold"] = 1000
      }
      let exposure = try XCTUnwrap(
        RewardExposure(try project(calculation, card: Self.fixtureCard)), "No picture at spend \(dollars)")
      let pose = exposure.pose
      let note = "at spend \(dollars)"

      // Every value is finite and in range.
      for value in [pose.h, pose.v, pose.sunX, pose.gap, pose.sunY(horizon: 42, r: 8)] {
        XCTAssertTrue(value.isFinite, "Not finite \(note)")
      }
      XCTAssertTrue((0.0...1.0).contains(pose.h), "h out of range \(note)")
      XCTAssertTrue((0.0...1.0).contains(pose.v), "v out of range \(note)")
      XCTAssertTrue((0.07...0.85).contains(pose.sunX), "Sun column out of range \(note)")
      XCTAssertTrue((0.0...1.0).contains(pose.gap), "Gap out of range \(note)")

      if dollars < 100 {
        let h = max(0, spend / 100)
        XCTAssertEqual(pose.h, h, accuracy: 1e-9, note)
        XCTAssertEqual(pose.v, 0, note)
        XCTAssertEqual(exposure.markerX ?? -1, h, accuracy: 1e-9, note)
        XCTAssertEqual(pose.sunX, min(0.85, max(0.07, h)), accuracy: 1e-9, note)
        XCTAssertEqual(pose.gap, 1 - h, accuracy: 1e-9, note)
      } else if dollars < 1000 {
        XCTAssertEqual(pose.h, 1, note)
        XCTAssertEqual(pose.v, 0.5 * (spend - 100) / 900, accuracy: 1e-9, note)
        XCTAssertNil(exposure.markerX, note)
        XCTAssertEqual(pose.sunX, 0.85, note)
        XCTAssertEqual(pose.gap, 0, note)
      } else if dollars < 2995 {
        XCTAssertEqual(pose.h, 1, note)
        XCTAssertEqual(pose.v, 0.5 + 0.5 * min(1, (counted - 1000) / 1998), accuracy: 1e-9, note)
        XCTAssertNil(exposure.markerX, note)
      }

      // v is exactly 1 exactly when the cap is reached: from counted 2,995 of
      // 2,998, a partial block, to the end of the walk.
      if dollars >= 2995 {
        seenCap = true
        XCTAssertEqual(pose.v, 1, note)
        XCTAssertEqual(pose.h, 1, note)
        XCTAssertEqual(exposure.stage, .capped, note)
      } else {
        XCTAssertLessThan(pose.v, 1, note)
      }

      if let previous {
        // Nothing falls as spend grows, and nothing jumps.
        XCTAssertGreaterThanOrEqual(pose.h, previous.h, note)
        XCTAssertGreaterThanOrEqual(pose.v, previous.v, note)
        XCTAssertLessThanOrEqual(pose.h - previous.h, 0.0101, "h jumped \(note)")
        XCTAssertLessThanOrEqual(pose.v - previous.v, 0.0025, "v jumped \(note)")
      }
      switch dollars {
      case 99, 100:
        // The cap climb starts at the minimum: v is 0 on both sides of it.
        XCTAssertEqual(pose.v, 0, note)
      case 999, 1000, 1001:
        // The reached tier hands over at halfway: within one step of 0.5 on both sides.
        XCTAssertEqual(pose.v, 0.5, accuracy: 0.0013, note)
      default:
        break
      }
      previous = pose
    }
    XCTAssertTrue(seenCap)
  }

  // MARK: Edge cases

  func testRefundsClampTheMinimumJourneyAtZero() throws {
    let exposure = try picture(["minimum_spend": 500, "total_spend": -40, "minimum_spend_met": false])
    XCTAssertEqual(exposure.pose, .init(h: 0, v: 0))
    XCTAssertEqual(exposure.markerX, 0)
  }

  func testCountedSpendLaggingRawAtTheMinimumNeverDipsBelowZero() throws {
    // Minimum 503, blocks of 10: raw 504 has met it, counted 500 has not caught up.
    let exposure = try picture([
      "minimum_spend": 503, "total_spend": 504, "counted_spend": 500, "maximum_spend": 1000,
    ], card: ["minimumSpend": 503])
    XCTAssertEqual(exposure.pose, .init(h: 1, v: 0))
  }

  func testNegativeMinimumAmountCountsAsNoMinimum() throws {
    let exposure = try picture([
      "minimum_spend": -100, "total_spend": 250, "counted_spend": 250, "maximum_spend": 1000,
    ])
    XCTAssertEqual(exposure.pose.v, 0.25, accuracy: 1e-9)
    XCTAssertFalse(exposure.hasMinimum)
  }

  func testAmountsThatAreNotFiniteNeverReachThePicture() throws {
    // JSON cannot carry NaN, so these rows are built directly.
    let nan = Double.nan
    for action in [
      RewardRowProjection.Action.capHeadroom(remaining: 100), .nextTier(remaining: 100),
    ] {
      let projection = directProjection(
        action: action, basis: .init(spend: nan, target: 1000), minimumAmount: nan, reachedTierThreshold: .infinity)
      let pose = try XCTUnwrap(RewardExposure(projection)).pose
      for value in [pose.h, pose.v] {
        XCTAssertTrue(value.isFinite)
        XCTAssertTrue((0.0...1.0).contains(value))
      }
    }
    let gate = directProjection(action: .minimum(remaining: 1), basis: .init(spend: 1, target: 2), fill: nan)
    XCTAssertEqual(try XCTUnwrap(RewardExposure(gate)).pose, .init(h: 0, v: 0))
  }

  func testACapAtOrBelowTheFootOfTheClimbIsMeasuredFromZero() throws {
    let exposure = try picture([
      "minimum_spend": 500, "total_spend": 600, "counted_spend": 300, "maximum_spend": 400,
    ], card: ["minimumSpend": 500])
    XCTAssertEqual(exposure.pose.v, 0.75, accuracy: 1e-9)
  }

  func testCapExceededPutsTheSunOffTheTopEdgeHoweverFarBeyond() throws {
    for spend in [2150.0, 5000.0] {
      let exposure = try picture([
        "total_spend": spend, "counted_spend": 2000, "maximum_spend": 2000, "maximum_spend_exceeded": true,
        "should_stop_using": true, "has_next_spending_tier": false,
      ])
      XCTAssertEqual(exposure.pose, .init(h: 1, v: 1))
      XCTAssertEqual(exposure.stage, .capped)
      XCTAssertEqual(exposure.pose.sunY(horizon: 42, r: 8), -1.05 * 8, accuracy: 1e-9)
    }
  }

  func testPartialBlockCapIsCappedWhileTheFigureStaysRaw() throws {
    let projection = try project([
      "total_spend": 996, "counted_spend": 995, "maximum_spend": 1000, "maximum_spend_exceeded": true,
      "should_stop_using": true, "has_next_spending_tier": false,
    ])
    XCTAssertEqual(try XCTUnwrap(RewardExposure(projection)).pose, .init(h: 1, v: 1))
    XCTAssertEqual(projection.basis, .init(spend: 995, target: 1000))
  }

  func testCapOnlyClimbsFromZeroWithNoMinimum() throws {
    for (counted, v) in [(0.0, 0.0), (250, 0.25)] {
      let exposure = try picture(["total_spend": counted, "counted_spend": counted, "maximum_spend": 1000])
      XCTAssertEqual(exposure.pose.h, 1)
      XCTAssertEqual(exposure.pose.v, v, accuracy: 1e-9)
      XCTAssertNil(exposure.markerX)
      XCTAssertFalse(exposure.hasMinimum)
    }
  }

  func testTierOnlyClimbsFromZeroWithNoMinimum() throws {
    let exposure = try picture(
      ["total_spend": 315.5, "counted_spend": 315.5, "has_next_spending_tier": true, "next_spending_tier_threshold": 400],
      card: ["spendingTiers": [["id": "t400", "spendThreshold": 400]]])
    XCTAssertEqual(exposure.pose.v, 0.394375, accuracy: 1e-6)
  }

  func testMinimumTierAndCapShareOneClimb() throws {
    let card: [String: Any] = [
      "minimumSpend": 100, "spendingTiers": [["id": "t200", "spendThreshold": 200]],
    ]
    // Approaching the tier: measured from the minimum.
    let approaching = try picture([
      "minimum_spend": 100, "total_spend": 150, "counted_spend": 150,
      "has_next_spending_tier": true, "next_spending_tier_threshold": 200, "maximum_spend": 500,
    ], card: card)
    XCTAssertEqual(approaching.pose.v, 0.25, accuracy: 1e-9)
    // After the tier: halfway, then on to the cap.
    for (counted, v) in [(200.0, 0.5), (350, 0.75), (500, 1)] {
      let exposure = try picture([
        "minimum_spend": 200, "total_spend": counted, "counted_spend": counted, "active_spending_tier_id": "t200",
        "has_next_spending_tier": false, "maximum_spend": 500, "maximum_spend_exceeded": counted >= 500,
      ], card: card)
      XCTAssertEqual(exposure.pose.v, v, accuracy: 1e-9, "counted \(counted)")
    }
  }

  func testAFurtherTierNeverSinksTheSun() throws {
    let card: [String: Any] = [
      "minimumSpend": 100,
      "spendingTiers": [["id": "t500", "spendThreshold": 500], ["id": "t1000", "spendThreshold": 1000]],
    ]
    let toFirst = try picture([
      "minimum_spend": 100, "total_spend": 300, "counted_spend": 300,
      "has_next_spending_tier": true, "next_spending_tier_threshold": 500,
    ], card: card)
    XCTAssertEqual(toFirst.pose.v, 0.25, accuracy: 1e-9)
    // The first tier is reached and a second is ahead: halfway, not back towards a quarter.
    let between = try picture([
      "minimum_spend": 500, "total_spend": 750, "counted_spend": 750, "active_spending_tier_id": "t500",
      "has_next_spending_tier": true, "next_spending_tier_threshold": 1000,
    ], card: card)
    XCTAssertEqual(between.pose.v, 0.5, accuracy: 1e-9)
    let top = try picture([
      "minimum_spend": 1000, "total_spend": 1200, "counted_spend": 1200, "active_spending_tier_id": "t1000",
      "has_next_spending_tier": false,
    ], card: card)
    XCTAssertEqual(top.stage, .rest)
    XCTAssertEqual(top.pose.v, 0.5, accuracy: 1e-9)
  }

  func testATierAtTheMinimumIsReachedWithTheMinimum() throws {
    let card: [String: Any] = [
      "minimumSpend": 300, "spendingTiers": [["id": "t300", "spendThreshold": 300]],
    ]
    let top = try picture([
      "minimum_spend": 300, "total_spend": 320, "counted_spend": 320, "active_spending_tier_id": "t300",
      "has_next_spending_tier": false,
    ], card: card)
    XCTAssertEqual(top.pose.v, 0.5, accuracy: 1e-9)
    let capped = try picture([
      "minimum_spend": 300, "total_spend": 650, "counted_spend": 650, "active_spending_tier_id": "t300",
      "has_next_spending_tier": false, "maximum_spend": 1000,
    ], card: card)
    XCTAssertEqual(capped.pose.v, 0.75, accuracy: 1e-9)
  }

  func testMonthlyMinimumThenCapIsMeasuredFromTheCardsMinimumNeverTheMonths() throws {
    let behind = try picture([
      "total_spend": 250, "qualification_status": "pending", "minimum_spend_met": false,
      "monthly_qualifications": [
        ["start": "2026-09-01", "end": "2026-09-30", "spend": 250, "minimumSpend": 300, "status": "pending"],
      ],
    ])
    XCTAssertEqual(behind.stage, .gate)
    XCTAssertEqual(behind.pose.h, 250.0 / 300, accuracy: 1e-9)
    XCTAssertEqual(behind.pose.v, 0)
    XCTAssertNotNil(behind.markerX)
    let met = try picture([
      "total_spend": 650, "counted_spend": 650, "maximum_spend": 1000, "qualification_status": "met",
      "monthly_qualifications": [
        ["start": "2026-09-01", "end": "2026-09-30", "spend": 650, "minimumSpend": 300, "status": "met"],
      ],
    ])
    XCTAssertEqual(met.pose.h, 1)
    XCTAssertEqual(met.pose.v, 0.65, accuracy: 1e-9)
    XCTAssertNil(met.markerX)
  }

  func testSunGeometryOnAHorizonAt42WithADiscOfRadius8() {
    // Across: it rides the marker between 0.07 and 0.85, then lifts clear.
    let across: [(h: Double, x: Double, y: Double)] = [
      (0.03, 0.07, 42.64), (0.5, 0.5, 42.64), (0.9, 0.85, 39.36), (1, 0.85, 32.8),
    ]
    for step in across {
      let pose = RewardExposure.Pose(h: step.h, v: 0)
      XCTAssertEqual(pose.sunX, step.x, accuracy: 1e-9, "x at h \(step.h)")
      XCTAssertEqual(pose.sunY(horizon: 42, r: 8), step.y, accuracy: 0.01, "y at h \(step.h)")
    }
    // Up: from just above the ground to off the top edge.
    for (v, y) in [(0.0, 32.8), (0.5, 12.2), (1.0, -8.4)] {
      XCTAssertEqual(RewardExposure.Pose(h: 1, v: v).sunY(horizon: 42, r: 8), y, accuracy: 0.01, "y at v \(v)")
    }
  }

  func testFailedHasNoSunNoMarkerAndTheRidgesApart() throws {
    let exposure = try picture([
      "qualification_status": "failed", "minimum_spend_met": false,
      "monthly_qualifications": [
        ["start": "2026-07-01", "end": "2026-07-31", "spend": 200, "minimumSpend": 300, "status": "failed"],
      ],
    ], period: ("2026-07-01", "2026-09-30"))
    XCTAssertEqual(exposure.stage, .failed)
    XCTAssertEqual(exposure.pose, .init(h: 0, v: 0))
    XCTAssertFalse(exposure.hasSun)
    XCTAssertNil(exposure.markerX)
    XCTAssertTrue(exposure.ridgesApart)
    XCTAssertEqual(exposure.light, .overcast)
  }

  func testNoTargetRestsEvenlyLitWithTheRidgesApart() throws {
    let plain = try picture([:])
    let locked = try picture([
      "total_spend": 900, "qualification_status": "pending", "minimum_spend_met": false,
      "monthly_qualifications": [
        ["start": "2026-09-01", "end": "2026-09-30", "spend": 320, "minimumSpend": 300, "status": "met"],
        ["start": "2026-10-01", "end": "2026-10-31", "spend": 0, "minimumSpend": 300, "status": "pending"],
      ],
    ], period: ("2026-09-01", "2026-10-31"))
    for exposure in [plain, locked] {
      XCTAssertEqual(exposure.stage, .calm)
      XCTAssertEqual(exposure.pose, .init(h: 1, v: 0))
      XCTAssertNil(exposure.markerX)
      XCTAssertTrue(exposure.hasSun)
      XCTAssertTrue(exposure.ridgesApart)
      XCTAssertEqual(exposure.light, .even)
    }
  }

  func testRangeRowsDrawNoPicture() throws {
    XCTAssertNil(RewardExposure(try project(["total_spend": 1000], isRange: true)))
  }

  // MARK: Helpers

  private static let fixtureCard: [String: Any] = [
    "minimumSpend": 100, "spendingTiers": [["id": "tier-1000", "spendThreshold": 1000]],
  ]

  private func picture(
    _ calculation: [String: Any],
    period: (String, String) = ("2026-09-01", "2026-09-30"),
    card: [String: Any] = [:]
  ) throws -> RewardExposure {
    try XCTUnwrap(RewardExposure(try project(calculation, period: period, card: card)))
  }

  private func project(
    _ calculation: [String: Any],
    period: (String, String) = ("2026-09-01", "2026-09-30"),
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
        "id": "card", "name": "Exposure Card", "issuer": "Demo", "type": "cashback", "ynabAccountId": "acct-card",
        "featured": true,
      ] as [String: Any]).merging(card) { $1 },
      "account_id": "acct-card", "account_name": "Exposure Card", "calculation": withPeriod,
    ]
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let row = try decoder.decode(RewardsCardRow.self, from: JSONSerialization.data(withJSONObject: json))
    return .make(row: row, asOf: "2026-09-23", isRange: isRange)
  }

  private func directProjection(
    action: RewardRowProjection.Action,
    basis: RewardRowProjection.Basis? = nil,
    fill: Double? = 1,
    minimumAmount: Double = 0,
    reachedTierThreshold: Double = 0
  ) -> RewardRowProjection {
    RewardRowProjection(
      cardID: "card", accountID: "acct-card", title: "Exposure Card", rewardType: .cashback, action: action,
      tone: .earning, basis: basis, fill: fill, deadline: nil, totalSpend: 0, earned: 0, exceptions: [],
      missedMinimumPeriod: nil, minimumAmount: minimumAmount, reachedTierThreshold: reachedTierThreshold)
  }
}
