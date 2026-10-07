import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import type { RewardsReport } from "../api/types";
import { configureMoney } from "./money";
import { boardSummary, projectRow, roundedUpToCent, rowText, type RewardRowProjection, type RewardsRow } from "./reward-row-projection";

/*
 * A port of RewardRowProjectionTests (apps/ios/HowMuchTests/RewardsReportTests.swift:1018-1417).
 * Each title carries the Swift test name. Expected values are worked out by hand from the
 * fixture numbers (SGD, as of 23 Sep 2026, a 1 to 30 Sep period unless noted), never read back
 * from the projection under test. "today" is pinned to the as-of day so the suite does not
 * depend on the clock.
 */

const TODAY = "2026-09-23";

beforeAll(() => {
  configureMoney({ iso_code: "SGD", decimal_digits: 2, decimal_separator: ".", group_separator: ",", currency_symbol: "$", symbol_first: true, display_symbol: true });
});
// Money formatting is module state: leave it as found for the files that run after this one.
afterAll(() => configureMoney());

type Json = Record<string, unknown>;

function project(calculation: Json, options: {
  name?: string; id?: string; period?: [string, string]; asOf?: string | null; isRange?: boolean; card?: Json; today?: string;
} = {}): RewardRowProjection {
  const { name = "Everyday Card", id = "card", period = ["2026-09-01", "2026-09-30"], asOf = TODAY, isRange = false, card = {}, today = TODAY } = options;
  const calc: Json = {
    period: `${period[0]}/${period[1]}`, total_spend: 0, counted_spend: calculation.total_spend ?? 0,
    eligible_spend: 0, reward_earned: 0, reward_earned_dollars: 0, reward_type: "cashback",
    minimum_spend_met: true, maximum_spend_exceeded: false, flags: [], ...calculation,
  };
  const row = {
    card: { id, name, issuer: "Demo", type: calc.reward_type ?? "cashback", ynabAccountId: `acct-${id}`, featured: true, ...card },
    account_id: `acct-${id}`, account_name: name,
    calculation: { ...calc, periods: [{ start: period[0], end: period[1], calculation: calc }] },
  } as unknown as RewardsRow;
  return projectRow(row, asOf, isRange, today);
}

function flag(name: string, total: number, extra: { maximum?: number; exceeded?: boolean; minimum?: number; minimumMet?: boolean } = {}): Json {
  const out: Json = {
    subcategoryId: name.toLowerCase(), name, flagColor: "red", totalSpend: total, countedSpend: total,
    eligibleSpend: total, rewardEarned: 0, minimumSpendMet: extra.minimumMet ?? true, maximumSpendExceeded: extra.exceeded ?? false,
  };
  if (extra.maximum != null) out.maximumSpend = extra.maximum;
  if (extra.minimum != null) out.minimumSpend = extra.minimum;
  return out;
}

const text = (p: RewardRowProjection, today = TODAY) => rowText(p, today);

describe("RewardRowProjectionTests: minimum", () => {
  test("testBelowMinimumShowsRemainderOnRawSpendWithPeriodDeadline", () => {
    const p = project({ minimum_spend: 800, total_spend: 698, counted_spend: 690, minimum_spend_met: false });
    expect(p.action).toEqual({ kind: "minimum", remaining: 102 });
    expect(p.tone).toBe("needs");
    expect(p.basis).toEqual({ spend: 698, target: 800 });
    expect(p.fill).toBeCloseTo(0.8725, 4);
    // 23 Sep to 30 Sep inclusive.
    expect(p.deadline).toEqual({ end: "2026-09-30", days: 8, kind: "ends" });
    const t = text(p);
    expect(t.amount).toBe("$102.00");
    expect(t.actionLabel).toBe("to minimum");
    expect(t.deadline).toBe("8 days left");
    expect(t.basisLine).toBe("$698.00 / $800.00 · $0.00 earned");
    expect(t.isUrgent).toBe(false);
  });

  test("testExactlyAtMinimumIsNotAmber", () => {
    const p = project({ minimum_spend: 800, total_spend: 800, minimum_spend_met: true });
    expect(text(p).actionLabel).toBe("Minimum met");
    expect(p.tone).toBe("earning");
    expect(p.fill).toBe(1);
    expect(p.basis).toEqual({ spend: 800, target: 800 });
  });

  test("testAboveMinimumMovesToCapHeadroomOnCountedSpend", () => {
    const p = project({ minimum_spend: 500, maximum_spend: 1000, total_spend: 700, counted_spend: 650, minimum_spend_met: true });
    expect(p.action).toEqual({ kind: "capHeadroom", remaining: 350 });
    expect(p.basis).toEqual({ spend: 650, target: 1000 });
    expect(p.tone).toBe("earning");
  });

  test("testRemainderRoundsUpToTheCent", () => {
    const p = project({ minimum_spend: 100, total_spend: 99.996, minimum_spend_met: false });
    expect(text(p).amount).toBe("$0.01");
    expect(roundedUpToCent(102.0000000001)).toBe(102);
    expect(roundedUpToCent(101.001)).toBe(101.01);
  });
});

describe("RewardRowProjectionTests: tiers and caps", () => {
  test("testUnmetBaseMinimumOutranksNextTier", () => {
    const p = project({ minimum_spend: 500, total_spend: 300, minimum_spend_met: false, has_next_spending_tier: true, next_spending_tier_threshold: 500 });
    expect(p.action).toEqual({ kind: "minimum", remaining: 200 });
  });

  test("testNextTierUsesTotalSpendAgainstThreshold", () => {
    const p = project({ total_spend: 1340, counted_spend: 1300, maximum_spend: 1600, has_next_spending_tier: true, next_spending_tier_threshold: 1600, reward_earned: 76 });
    expect(p.action).toEqual({ kind: "nextTier", remaining: 260 });
    expect(p.basis).toEqual({ spend: 1340, target: 1600 });
    expect(p.tone).toBe("earning");
    expect(text(p).basisLine).toBe("$1,340.00 / $1,600.00 · $76.00 earned");
  });

  test("testIntermediateCapShowsNextTierWithException", () => {
    const p = project({ total_spend: 1340, maximum_spend: 1000, maximum_spend_exceeded: true, has_next_spending_tier: true, next_spending_tier_threshold: 1600, should_stop_using: false });
    expect(p.action).toEqual({ kind: "nextTier", remaining: 260 });
    expect(p.exceptions).toEqual([{ kind: "tierCapReached" }]);
    // Not complete: the intermediate cap is an exception, not a finish.
    expect(p.tone).not.toBe("complete");
  });

  test("testTerminalCapIsCompleteFullAndReportsSpendBeyondCap", () => {
    const p = project({ total_spend: 2150, counted_spend: 2000, maximum_spend: 2000, maximum_spend_exceeded: true, should_stop_using: true, has_next_spending_tier: false, reward_earned: 80 });
    expect(p.action).toEqual({ kind: "capReached", beyond: 150, terminal: true });
    expect(p.tone).toBe("complete");
    expect(p.fill).toBe(1);
    expect(p.deadline?.kind).toBe("resets");
    const t = text(p);
    expect(t.actionLabel).toBe("Bonus cap reached");
    expect(t.amount).toBeNull();
    expect(t.deadline).toBe("Resets in 8 days");
    expect(t.basisLine).toBe("$2,000.00 / $2,000.00 · $80.00 earned · $150.00 beyond cap");
  });

  test("testTopTierWithoutCardCapIsEarningAndFull", () => {
    // $800 base minimum, $1,600 top tier, caps only on categories with room left.
    const p = project({
      minimum_spend: 1600, total_spend: 1650, counted_spend: 1650, reward_earned: 90, active_spending_tier_id: "level-1600", has_next_spending_tier: false,
      flags: [flag("Dining", 300, { maximum: 375 }), flag("Everywhere else", 1350)],
    }, { card: { minimumSpend: 800, spendingTiers: [{ id: "level-1600", spendThreshold: 1600 }] } });
    expect(p.action).toEqual({ kind: "topTier" });
    expect(p.tone).toBe("earning");
    expect(p.fill).toBe(1);
    expect(p.basis).toBeNull();
    expect(p.deadline?.kind).toBe("resets");
    expect(p.exceptions).toEqual([]);
    const t = text(p);
    expect(t.actionLabel).toBe("Highest tier active");
    expect(t.amount).toBeNull();
    expect(t.basisLine).toBe("$1,650.00 spent · $90.00 earned");
  });

  test("testTopTierWithCardCapStillShowsHeadroom", () => {
    const p = project({ minimum_spend: 1600, maximum_spend: 2000, total_spend: 1650, counted_spend: 1650, has_next_spending_tier: false },
      { card: { spendingTiers: [{ id: "level-1600", spendThreshold: 1600 }] } });
    expect(p.action).toEqual({ kind: "capHeadroom", remaining: 350 });
  });

  test("testUntieredCardWithOnlyCategoryCapsSaysNoCardCap", () => {
    const p = project({ total_spend: 400, flags: [flag("Dining", 100, { maximum: 500 })] });
    expect(p.action).toEqual({ kind: "noTarget", categoryCaps: true });
    expect(p.tone).toBe("neutral");
    expect(text(p).actionLabel).toBe("No card cap");
  });

  test("testOlderServerWithoutStopFlagTreatsExceededCapAsTerminal", () => {
    const p = project({ total_spend: 1000, counted_spend: 1000, maximum_spend: 1000, maximum_spend_exceeded: true });
    expect(p.action).toEqual({ kind: "capReached", beyond: 0, terminal: true });
  });

  test("testPartialBlockHeadroomStillCountsAsCapReached", () => {
    // Less than one block left: the server flags the cap as exceeded.
    const p = project({ total_spend: 996, counted_spend: 995, maximum_spend: 1000, maximum_spend_exceeded: true, should_stop_using: true });
    expect(p.action).toEqual({ kind: "capReached", beyond: 0, terminal: true });
    expect(p.fill).toBe(1);
    expect(p.basis).toEqual({ spend: 995, target: 1000 });
  });

  test("testUnlimitedCardHasNoFabricatedTargetOrFill", () => {
    for (const extra of [{}, { minimum_spend: 0, maximum_spend: 0 }]) {
      const p = project({ ...extra, total_spend: 420, reward_earned: 8.4 });
      expect(p.action).toEqual({ kind: "noTarget", categoryCaps: false });
      expect(p.fill).toBeNull();
      expect(p.basis).toBeNull();
      expect(p.tone).not.toBe("complete");
      expect(text(p).basisLine).toBe("$420.00 spent · $8.40 earned");
    }
  });
});

describe("RewardRowProjectionTests: qualification", () => {
  test("testMetMinimumDoesNotImplyTerminalCategoryExhaustionOrQualification", () => {
    const calculation = {
      minimum_spend: 600, total_spend: 796.39, minimum_spend_met: true,
      flags: [flag("Online", 449.72, { maximum: 416, exceeded: true }), flag("Uncapped", 346.67)],
    };
    const qualified = project(calculation);
    expect(qualified.tone).toBe("earning");
    expect(qualified.basis).toEqual({ spend: 796.39, target: 600 });
    expect(qualified.fill).toBe(1);
    expect(qualified.action).not.toMatchObject({ kind: "capReached" });
    expect(text(qualified).actionLabel).toBe("Minimum met");
    expect(text(qualified).exceptionLines).toEqual(["Online over cap"]);
    for (const withheld of [{ minimum_spend_met: false }, { qualification_status: "pending" }]) {
      const p = project({ ...calculation, ...withheld });
      expect(p.tone).not.toBe("earning");
      expect(text(p).actionLabel).not.toBe("Minimum met");
    }
  });

  test("testFailedMonthIsNamedOnlyAfterItClosesIncludingAnchoredMonths", () => {
    const cases: Array<[string, string, string, string]> = [
      ["2026-07-01", "2026-07-31", "July minimum missed", "July 2026 minimum missed"],
      ["2026-07-15", "2026-08-14", "15 Jul–14 Aug minimum missed", "15 Jul 2026–14 Aug 2026 minimum missed"],
    ];
    for (const [start, end, sameYearLabel, otherYearLabel] of cases) {
      const calculation = {
        qualification_status: "failed", minimum_spend_met: false,
        monthly_qualifications: [{ start, end, spend: 200, minimumSpend: 300, status: "failed" }],
      };
      const closed = project(calculation, { period: ["2026-07-01", "2026-09-30"] });
      expect(closed.tone).toBe("failed");
      expect(text(closed).actionLabel).toBe(sameYearLabel);
      // The same card seen from another calendar year names the year.
      expect(rowText(closed, "2027-01-05").actionLabel).toBe(otherYearLabel);
      const historicalEnd = project(calculation, { asOf: end });
      expect(historicalEnd.tone).toBe("failed");
      const open = project(calculation, { period: ["2026-07-01", "2026-09-30"], asOf: start });
      expect(open.tone).toBe("needs");
      expect(open.action).toEqual({ kind: "monthlyMinimum", remaining: 100 });
      const range = project(calculation, { isRange: true });
      expect(range.tone).toBe("neutral");
    }
    // The month ends today: it is still open until tomorrow.
    const current = project({
      qualification_status: "failed", minimum_spend_met: false,
      monthly_qualifications: [{ start: TODAY, end: TODAY, spend: 0, minimumSpend: 300, status: "failed" }],
    }, { asOf: TODAY });
    expect(current.action).toEqual({ kind: "monthlyMinimum", remaining: 300 });
    expect(current.tone).toBe("needs");
  });

  test("testPendingMonthBehindUsesTheMonthAndItsEnd", () => {
    // Anchored three-month period; the month ends before the period does.
    const p = project({
      total_spend: 900, qualification_status: "pending", minimum_spend_met: false,
      monthly_qualifications: [
        { start: "2026-08-01", end: "2026-08-31", spend: 400, minimumSpend: 300, status: "met" },
        { start: "2026-09-01", end: "2026-09-30", spend: 250, minimumSpend: 300, status: "pending" },
      ],
    }, { period: ["2026-08-01", "2026-10-31"] });
    expect(p.action).toEqual({ kind: "monthlyMinimum", remaining: 50 });
    expect(p.basis).toEqual({ spend: 250, target: 300 });
    expect(p.deadline).toEqual({ end: "2026-09-30", days: 8, kind: "ends" });
    expect(text(p).actionLabel).toBe("to monthly minimum");
  });

  test("testPendingMonthAlreadyMetFallsThroughWithLockedException", () => {
    const p = project({
      total_spend: 900, qualification_status: "pending", minimum_spend_met: false,
      monthly_qualifications: [
        { start: "2026-09-01", end: "2026-09-30", spend: 320, minimumSpend: 300, status: "met" },
        { start: "2026-10-01", end: "2026-10-31", spend: 0, minimumSpend: 300, status: "pending" },
      ],
    }, { period: ["2026-09-01", "2026-10-31"] });
    expect(p.action).toEqual({ kind: "noTarget", categoryCaps: false });
    expect(p.exceptions).toEqual([{ kind: "rewardsLocked", until: "2026-10-31" }]);
    expect(text(p).exceptionLines).toEqual(["Rewards unlock after 31 Oct"]);
  });

  test("testFailedQualificationOutranksAMetCardMinimum", () => {
    const p = project({ minimum_spend: 500, total_spend: 700, qualification_status: "failed", minimum_spend_met: false });
    expect(p.action).toEqual({ kind: "qualificationFailed" });
    expect(p.tone).toBe("failed");
    expect(p.fill).toBeNull();
    expect(p.deadline?.kind).toBe("resets");
    expect(p.exceptions).toEqual([]);
  });

  test("testServerMinimumUnmetWithoutARawGapIsFlagged", () => {
    // Spend reached the figure, but a tier minimum still withholds rewards.
    const p = project({ minimum_spend: 500, total_spend: 600, minimum_spend_met: false });
    expect(p.action).toEqual({ kind: "noTarget", categoryCaps: false });
    expect(p.exceptions).toEqual([{ kind: "minimumNotMet" }]);
  });
});

describe("RewardRowProjectionTests: category exceptions", () => {
  test("testCategoryOverCapShowsWhenCardCapIsNot", () => {
    const p = project({ total_spend: 400, flags: [flag("Dining", 250, { maximum: 200, exceeded: true }), flag("Groceries", 50, { maximum: 200, exceeded: false })] });
    expect(p.exceptions).toEqual([{ kind: "categoriesAtCap", names: ["Dining"], over: true }]);
    expect(text(p).exceptionLines).toEqual(["Dining over cap"]);
  });

  test("testCategoryExactlyAtCapSaysAtCap", () => {
    const p = project({ total_spend: 400, flags: [flag("Dining", 200, { maximum: 200, exceeded: true }), flag("Travel", 150, { maximum: 150, exceeded: true })] });
    expect(text(p).exceptionLines).toEqual(["2 categories at cap"]);
  });

  test("testCardCapExceededSuppressesCategoryCapException", () => {
    const p = project({ total_spend: 1000, maximum_spend: 1000, maximum_spend_exceeded: true, should_stop_using: true, flags: [flag("Dining", 250, { maximum: 200, exceeded: true })] });
    expect(p.exceptions).toEqual([]);
  });

  test("testCategoryBelowItsMinimumOnceCardMinimumIsMet", () => {
    const p = project({ total_spend: 400, flags: [flag("Dining", 120, { minimum: 200, minimumMet: false })] });
    expect(p.exceptions).toEqual([{ kind: "categoriesBelowMinimum", names: ["Dining"] }]);
  });

  test("testMoreThanTwoExceptionsCollapseIntoAMoreLine", () => {
    const p = project({
      total_spend: 1340, maximum_spend: 1000, maximum_spend_exceeded: false, has_next_spending_tier: true, next_spending_tier_threshold: 1600,
      flags: [flag("Dining", 250, { maximum: 200, exceeded: true }), flag("Travel", 20, { minimum: 100, minimumMet: false })],
      qualification_status: "pending",
      monthly_qualifications: [{ start: "2026-09-01", end: "2026-09-30", spend: 400, minimumSpend: 300, status: "met" }],
    });
    expect(p.exceptions.length).toBe(3);
    const lines = text(p).exceptionLines;
    expect(lines.length).toBe(3);
    expect(lines.at(-1)).toBe("+1 more");
  });
});

describe("RewardRowProjectionTests: dates", () => {
  test("testLastDayAndResetTomorrowWording", () => {
    const ends = project({ minimum_spend: 100, total_spend: 10 }, { period: ["2026-02-01", "2026-02-28"], asOf: "2026-02-28" });
    expect(ends.deadline?.days).toBe(1);
    const endsText = text(ends);
    expect(endsText.deadline).toBe("Last day");
    expect(endsText.isUrgent).toBe(true);
    const resets = project({ total_spend: 10 }, { period: ["2026-02-01", "2026-02-28"], asOf: "2026-02-28" });
    expect(text(resets).deadline).toBe("Resets tomorrow");
    // A deadline in the past (days below one) reads "Period ended".
    const ended: RewardRowProjection = { ...ends, deadline: { end: "2026-02-28", days: 0, kind: "ends" } };
    expect(text(ended).deadline).toBe("Period ended");
  });

  test("testHistoricalAsOfCountsDaysFromThatDate", () => {
    const p = project({ minimum_spend: 800, total_spend: 100 }, { asOf: "2026-09-10" });
    expect(p.deadline?.days).toBe(21);
  });

  test("testDaysLeftDoNotDependOnTheDeviceZone", () => {
    // Across the March DST change in the US and the UK. The suite also runs under
    // TZ=America/Los_Angeles and TZ=Pacific/Kiritimati (see the module's header).
    const p = project({ minimum_spend: 800, total_spend: 100 }, { period: ["2026-03-01", "2026-03-31"], asOf: "2026-03-07" });
    expect(p.deadline?.days).toBe(25);
    const lastDay = project({ minimum_spend: 800, total_spend: 100 }, { period: ["2026-03-01", "2026-03-31"], asOf: "2026-03-31" });
    expect(lastDay.deadline?.days).toBe(1);
    const leap = project({ minimum_spend: 800, total_spend: 100 }, { period: ["2028-02-01", "2028-02-29"], asOf: "2028-02-01" });
    expect(leap.deadline?.days).toBe(29);
  });

  test("testMissingAsOfLeavesNoDeadline", () => {
    const p = project({ minimum_spend: 800, total_spend: 100 }, { asOf: null });
    expect(p.deadline).toBeNull();
    expect(p.action).toEqual({ kind: "minimum", remaining: 700 });
  });
});

describe("RewardRowProjectionTests: range, summary", () => {
  test("testRangeRowsHaveNoFillDeadlineOrExceptions", () => {
    const p = project({
      total_spend: 1000, maximum_spend: 500, maximum_spend_exceeded: true, reward_earned: 40,
      flags: [flag("Dining", 250, { maximum: 200, exceeded: true })],
    }, { isRange: true });
    expect(p.action).toEqual({ kind: "range" });
    expect(p.fill).toBeNull();
    expect(p.deadline).toBeNull();
    expect(p.exceptions).toEqual([]);
    const t = text(p);
    expect(t.amount).toBe("$40.00");
    expect(t.basisLine).toBe("$1,000.00 spent");
  });

  test("testSummaryCountsLabelledStatusesAndApproximatesOnlyValuedMiles", () => {
    const below = project({ minimum_spend: 800, total_spend: 100 });
    const failed = project({ qualification_status: "failed" });
    const capped = project({ maximum_spend: 100, total_spend: 100, counted_spend: 100, maximum_spend_exceeded: true, should_stop_using: true });
    const plain = project({ total_spend: 10 });
    const report = (miles: number, cashback: number, rewardDollars: number, valuation: number) => ({
      group_by: "flag", miles_valuation: valuation, totals: { spend: 0, reward_dollars: rewardDollars, cashback, miles }, cards: [], groups: [],
    }) as unknown as RewardsReport;
    const valued = boardSummary(report(1300, 50, 69.5, 0.015), [below, failed, capped, plain]);
    expect(valued.line).toBe("≈ $69.50 earned · 1 below minimum · 1 failed · 1 capped");
    expect(valued.statusCounts).toEqual(["1 below minimum", "1 failed", "1 capped"]);
    expect(boardSummary(report(1300, 50, 50, 0), [plain]).line).toBe("$50.00 cashback · 1,300 miles");
    expect(boardSummary(report(0, 50, 50, 0.015), []).line).toBe("$50.00 earned");
  });

  test("testAccessibilityValueStatesTargetProgressAndDeadline", () => {
    const p = project({ minimum_spend: 500, total_spend: 300, reward_earned: 1300, reward_type: "miles" });
    expect(text(p).accessibilityValue).toBe("$200.00 to minimum. $300.00 of $500.00, 60 per cent. 8 days left, ends 30 Sep. 1,300 miles earned");
  });
});

describe("Rewards Exposure spec: the state tables' words (card text and VoiceOver value)", () => {
  // Rows 3, 5, 6, 7, 9, 11, 12 of the spec's "State table: words and VoiceOver".
  test("next tier, cap headroom, minimum met, top tier, terminal cap, failed month and no cap", () => {
    const tier = project({ total_spend: 1340, counted_spend: 1300, maximum_spend: 1600, has_next_spending_tier: true, next_spending_tier_threshold: 1600, reward_earned: 76 });
    expect(text(tier).accessibilityValue).toBe("$260.00 to next tier. $1,340.00 of $1,600.00, 84 per cent. 8 days left, ends 30 Sep. $76.00 earned");
    const cap = project({ minimum_spend: 500, maximum_spend: 1000, total_spend: 700, counted_spend: 650, minimum_spend_met: true });
    expect(text(cap).accessibilityValue).toBe("$350.00 left before bonus cap. $650.00 of $1,000.00, 65 per cent. 8 days left, ends 30 Sep. $0.00 earned");
    const met = project({ minimum_spend: 800, total_spend: 800 });
    expect(text(met).accessibilityValue).toBe("Minimum met. $800.00 of $800.00, 100 per cent. Resets in 8 days, period ends 30 Sep. $0.00 earned");
    const top = project({ minimum_spend: 1600, total_spend: 1650, counted_spend: 1650, reward_earned: 90, active_spending_tier_id: "t", has_next_spending_tier: false },
      { card: { minimumSpend: 800, spendingTiers: [{ id: "t", spendThreshold: 1600 }] } });
    expect(text(top).accessibilityValue).toBe("Highest tier active. $1,650.00 spent · $90.00 earned. Resets in 8 days, period ends 30 Sep. $90.00 earned");
    const none = project({ total_spend: 420, reward_earned: 8.4 });
    expect(text(none).accessibilityValue).toBe("No cap. $420.00 spent · $8.40 earned. Resets in 8 days, period ends 30 Sep. $8.40 earned");
    const failed = project({
      qualification_status: "failed", minimum_spend_met: false,
      monthly_qualifications: [{ start: "2026-07-01", end: "2026-07-31", spend: 200, minimumSpend: 300, status: "failed" }],
    }, { period: ["2026-07-01", "2026-09-30"] });
    expect(text(failed).accessibilityValue).toBe("July minimum missed. $0.00 spent · $0.00 earned. Resets in 8 days, period ends 30 Sep. $0.00 earned");
  });

  test("miles earned read as a rounded, grouped figure with the word miles", () => {
    const p = project({ minimum_spend: 200, total_spend: 315.5, reward_earned: 1033.4, reward_type: "miles" });
    expect(text(p).basisLine).toBe("$315.50 / $200.00 · 1,033 miles earned");
  });
});
