import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { configureMoney } from "./money";
import { exposure, falls, gap, sunX, sunY, type Exposure } from "./reward-exposure";
import { projectRow, type RewardsRow } from "./reward-row-projection";

/*
 * The pure Sun Arc mapping (projection to h, v, marker, the sun's x and y, the ridge gap), tested
 * in isolation as docs/frontend/rewards-exposure-card.md "Isolated tests" asks. Two tests only:
 * the mapping walk (the hand-overs, the partial block and a cap that is exceeded, which no
 * fixture can sweep) and the edge-case table (inputs no fixture reaches). Expected values come
 * from the rules in that document, never from the implementation: every figure below is worked
 * out by hand.
 */

const TODAY = "2026-09-23";
const PERIOD: [string, string] = ["2026-09-01", "2026-09-30"];

beforeAll(() => {
  configureMoney({ iso_code: "SGD", decimal_digits: 2, currency_symbol: "$", symbol_first: true, display_symbol: true });
});
afterAll(() => configureMoney());

type Json = Record<string, unknown>;

/** The row the server would send for `calculation` on `card`. */
function rowOf(calculation: Json, card: Json = {}, period: [string, string] = PERIOD): RewardsRow {
  const calc: Json = {
    period: `${period[0]}/${period[1]}`, total_spend: 0, counted_spend: calculation.total_spend ?? 0, eligible_spend: 0,
    reward_earned: 0, reward_earned_dollars: 0, reward_type: "cashback", minimum_spend_met: true, maximum_spend_exceeded: false, flags: [], ...calculation,
  };
  return {
    card: { id: "card", name: "Walk Card", issuer: "Demo", type: calc.reward_type, ynabAccountId: "acct", featured: true, ...card },
    account_id: "acct", account_name: "Walk",
    calculation: { ...calc, periods: [{ start: period[0], end: period[1], calculation: calc }] },
  } as unknown as RewardsRow;
}

function expose(calculation: Json, card: Json = {}, options: { period?: [string, string]; asOf?: string } = {}): Exposure {
  const p = projectRow(rowOf(calculation, card, options.period), options.asOf ?? TODAY, false, TODAY);
  const e = exposure(p);
  if (!e) throw new Error("expected a picture");
  return e;
}

// The sun's geometry is tested for a strip: a target horizon at 42 and a disc of radius 8.
const HORIZON = 42, RADIUS = 8;

describe("the mapping walk", () => {
  // The shape of fixtures/rewards-account-config.json: a minimum of 100, one tier at 1,000, a cap
  // of 2,400 at the base level and of 2,998 at the tier (the fixture's 3,000, moved off a multiple
  // of the block so the walk crosses a partial-block cap), and earning blocks of 5.
  const TIER = 1000, MINIMUM = 100, BLOCK = 5, BASE_CAP = 2400, TIER_CAP = 2998;
  const card = {
    minimumSpend: MINIMUM, maximumSpend: BASE_CAP, earningBlockSize: BLOCK,
    spendingTiers: [{ id: "tier-1000", spendThreshold: TIER, earningRate: 2, maximumSpend: TIER_CAP }],
  };

  /** What the server reports at `spend`, from the rules in the spec, written independently of the projection. */
  function server(spend: number) {
    const reachedTier = spend >= TIER;
    const minimumMet = spend >= MINIMUM;
    const cap = minimumMet ? TIER_CAP : BASE_CAP;
    const counted = Math.min(Math.max(0, Math.floor(spend / BLOCK) * BLOCK), Math.floor(cap / BLOCK) * BLOCK);
    return {
      calculation: {
        total_spend: spend, counted_spend: counted,
        minimum_spend: reachedTier ? TIER : MINIMUM, minimum_spend_met: minimumMet,
        active_spending_tier_id: reachedTier ? "tier-1000" : null,
        has_next_spending_tier: !reachedTier, next_spending_tier_threshold: reachedTier ? null : TIER,
        maximum_spend: cap, maximum_spend_exceeded: cap - counted < BLOCK,
        should_stop_using: cap - counted < BLOCK,
      } as Json,
      counted,
    };
  }

  test("every step is finite and in range, matches the rules, never falls and never jumps", () => {
    let previous: { spend: number; e: Exposure; y: number } | null = null;
    let firstCapped: number | null = null;
    for (let spend = -50; spend <= 3200; spend += 1) {
      const { calculation, counted } = server(spend);
      const p = projectRow(rowOf(calculation, card), TODAY, false, TODAY);
      const e = exposure(p)!;
      const { h, v } = e.pose;
      const y = sunY(e.pose, HORIZON, RADIUS);
      for (const value of [h, v, sunX(e.pose), y, gap(e.pose)]) expect(Number.isFinite(value)).toBe(true);
      expect(h).toBeGreaterThanOrEqual(0); expect(h).toBeLessThanOrEqual(1);
      expect(v).toBeGreaterThanOrEqual(0); expect(v).toBeLessThanOrEqual(1);
      expect(sunX(e.pose)).toBeGreaterThanOrEqual(0.07); expect(sunX(e.pose)).toBeLessThanOrEqual(0.85);
      expect(y).toBeLessThanOrEqual(HORIZON + 0.08 * RADIUS + 1e-9); expect(y).toBeGreaterThanOrEqual(-1.05 * RADIUS - 1e-9);

      if (spend < MINIMUM) {
        // The way to the minimum: across.
        const expectedH = Math.max(0, spend / MINIMUM);
        expect(h).toBeCloseTo(expectedH, 9);
        expect(v).toBe(0);
        expect(e.stage).toBe("gate");
        expect(e.markerX).toBeCloseTo(expectedH, 9);
        expect(sunX(e.pose)).toBeCloseTo(Math.min(0.85, Math.max(0.07, expectedH)), 9);
        expect(gap(e.pose)).toBeCloseTo(1 - expectedH, 9);
      } else {
        expect(h).toBe(1);
        expect(e.markerX).toBeNull();
        expect(e.hasMarker).toBe(false);
        expect(sunX(e.pose)).toBe(0.85);
        expect(gap(e.pose)).toBe(0);
        if (spend < TIER) {
          // The way to the tier: up to halfway, measured from the minimum.
          expect(v).toBeCloseTo(0.5 * (spend - MINIMUM) / (TIER - MINIMUM), 9);
        } else if (p.action.kind !== "capReached") {
          // After the tier: halfway, then on to the cap, measured from the tier.
          expect(v).toBeCloseTo(0.5 + 0.5 * Math.min(1, Math.max(0, (counted - TIER) / (TIER_CAP - TIER))), 9);
        }
      }

      // v is exactly 1 exactly when the action is capReached.
      expect(v === 1).toBe(p.action.kind === "capReached");
      if (p.action.kind === "capReached" && firstCapped === null) firstCapped = spend;
      if (p.action.kind === "capReached") expect(e.stage).toBe("capped");

      if (previous) {
        // Nothing falls as spend grows, and the sun only ever moves up and to the right.
        expect(h).toBeGreaterThanOrEqual(previous.e.pose.h - 1e-12);
        expect(v).toBeGreaterThanOrEqual(previous.e.pose.v - 1e-12);
        expect(sunX(e.pose)).toBeGreaterThanOrEqual(sunX(previous.e.pose) - 1e-12);
        expect(y).toBeLessThanOrEqual(previous.y + 1e-9);
        expect(falls(e.pose, previous.e.pose)).toBe(false);
      }
      previous = { spend, e, y };
    }
    // The partial block: counted 2,995 of 2,998 is capped.
    expect(firstCapped).toBe(2995);
  });

  test("the hand-overs have no jump: v is 0 either side of the minimum and within a step of 0.5 either side of the tier", () => {
    const at = (spend: number) => exposure(projectRow(rowOf(server(spend).calculation, card), TODAY, false, TODAY))!;
    expect(at(99).pose.v).toBe(0);
    expect(at(100).pose.v).toBe(0);
    expect(at(99).pose.h).toBeCloseTo(0.99, 9);
    expect(at(100).pose.h).toBe(1);
    expect(Math.abs(at(999).pose.v - 0.5)).toBeLessThan(0.5 / 900 + 1e-9);
    expect(at(1000).pose.v).toBe(0.5);
    expect(Math.abs(at(1005).pose.v - 0.5)).toBeLessThan(0.5 / 1998 * 5 + 1e-9);
  });
});

describe("the edge cases", () => {
  const cases: Array<{ name: string; run: () => void }> = [
    { name: "clamping: refunds. Minimum 500, spend -40", run: () => {
      const e = expose({ minimum_spend: 500, total_spend: -40, minimum_spend_met: false });
      expect(e.pose).toEqual({ h: 0, v: 0 });
      expect(e.markerX).toBe(0);
    } },
    { name: "clamping: counted spend lags raw at the minimum. Minimum 503, blocks of 10, cap 1,000: raw 504, counted 500", run: () => {
      const e = expose({ minimum_spend: 503, total_spend: 504, counted_spend: 500, maximum_spend: 1000 });
      expect(e.pose.v).toBe(0);
      expect(e.pose.h).toBe(1);
    } },
    { name: "clamping: amounts that are not finite are treated as 0 and no output is NaN", run: () => {
      const bad = [
        expose({ minimum_spend: Number.NaN, total_spend: 50, counted_spend: 50, maximum_spend: 100 }),
        expose({ minimum_spend: -5, total_spend: 50, counted_spend: 50, maximum_spend: 100 }),
        expose({ minimum_spend: 100, total_spend: 150, counted_spend: Number.NaN, maximum_spend: 1000 }),
        expose({ minimum_spend: 100, total_spend: Number.NaN, minimum_spend_met: false }),
      ];
      for (const e of bad) {
        for (const value of [e.pose.h, e.pose.v, sunX(e.pose), sunY(e.pose, HORIZON, RADIUS), gap(e.pose)]) expect(Number.isFinite(value)).toBe(true);
      }
      // A minimum that is not a number or is negative is no minimum: the cap climb is measured from 0.
      expect(bad[0]!.hasMinimum).toBe(false);
      expect(bad[0]!.pose).toEqual({ h: 1, v: 0.5 });
      expect(bad[1]!.hasMinimum).toBe(false);
      expect(bad[2]!.pose.v).toBe(0);
    } },
    { name: "clamping: a cap at or below the foot. Minimum 500, cap 400: raw 600, counted 300", run: () => {
      const e = expose({ minimum_spend: 500, total_spend: 600, counted_spend: 300, maximum_spend: 400 });
      expect(e.pose.v).toBeCloseTo(0.75, 9);
    } },
    { name: "cap exceeded. Cap 2,000, spend 2,150, counted 2,000, capReached", run: () => {
      for (const spend of [2150, 9000]) {
        const e = expose({ total_spend: spend, counted_spend: 2000, maximum_spend: 2000, maximum_spend_exceeded: true, should_stop_using: true });
        expect(e.pose).toEqual({ h: 1, v: 1 });
        expect(sunY(e.pose, HORIZON, RADIUS)).toBeCloseTo(-1.05 * RADIUS, 9);
        expect(e.stage).toBe("capped");
      }
    } },
    { name: "partial-block cap. Cap 1,000, blocks of 5: raw 996, counted 995, exceeded flag", run: () => {
      const e = expose({ total_spend: 996, counted_spend: 995, maximum_spend: 1000, maximum_spend_exceeded: true, should_stop_using: true });
      expect(e.pose.v).toBe(1);
      expect(e.stage).toBe("capped");
    } },
    { name: "no minimum, cap only. Cap 1,000; counted 0, then 250", run: () => {
      const zero = expose({ total_spend: 0, counted_spend: 0, maximum_spend: 1000 });
      expect(zero.pose).toEqual({ h: 1, v: 0 });
      expect(zero.markerX).toBeNull();
      expect(zero.hasMinimum).toBe(false);
      const quarter = expose({ total_spend: 250, counted_spend: 250, maximum_spend: 1000 });
      expect(quarter.pose.v).toBeCloseTo(0.25, 9);
    } },
    { name: "no minimum, tier only. One tier at 400; spend 315.50", run: () => {
      const e = expose({ total_spend: 315.5, has_next_spending_tier: true, next_spending_tier_threshold: 400 });
      expect(e.pose.v).toBeCloseTo(0.394, 3);
    } },
    { name: "minimum, tier and cap. Minimum 100, tier 200, cap 500", run: () => {
      const card = { minimumSpend: 100, spendingTiers: [{ id: "t200", spendThreshold: 200 }] };
      const climb = (calculation: Json) => expose({ minimum_spend: 100, maximum_spend: 500, has_next_spending_tier: false, ...calculation }, card);
      const approaching = expose({ minimum_spend: 100, total_spend: 150, counted_spend: 150, maximum_spend: 500, has_next_spending_tier: true, next_spending_tier_threshold: 200 }, card);
      expect(approaching.pose.v).toBeCloseTo(0.25, 9);
      const reached = { minimum_spend: 200, active_spending_tier_id: "t200" };
      expect(climb({ ...reached, total_spend: 200, counted_spend: 200 }).pose.v).toBeCloseTo(0.5, 9);
      expect(climb({ ...reached, total_spend: 350, counted_spend: 350 }).pose.v).toBeCloseTo(0.75, 9);
      expect(climb({ ...reached, total_spend: 500, counted_spend: 500, maximum_spend_exceeded: true, should_stop_using: true }).pose.v).toBe(1);
    } },
    { name: "a further tier. Minimum 100, tiers 500 and 1,000: spend 300, then 750, then topTier at 1,200", run: () => {
      const card = { minimumSpend: 100, spendingTiers: [{ id: "t500", spendThreshold: 500 }, { id: "t1000", spendThreshold: 1000 }] };
      const first = expose({ minimum_spend: 100, total_spend: 300, has_next_spending_tier: true, next_spending_tier_threshold: 500 }, card);
      expect(first.pose.v).toBeCloseTo(0.25, 9);
      // The first tier reached: the one threshold the projection carries is that tier's, so the sun holds at halfway.
      const second = expose({ minimum_spend: 500, total_spend: 750, active_spending_tier_id: "t500", has_next_spending_tier: true, next_spending_tier_threshold: 1000 }, card);
      expect(second.pose.v).toBe(0.5);
      const top = expose({ minimum_spend: 1000, total_spend: 1200, active_spending_tier_id: "t1000", has_next_spending_tier: false }, card);
      expect(top.stage).toBe("rest");
      expect(top.pose.v).toBe(0.5);
    } },
    { name: "a tier at the minimum. Minimum 300, one tier at 300: topTier; then a cap of 1,000 with counted 650", run: () => {
      const card = { minimumSpend: 300, spendingTiers: [{ id: "t300", spendThreshold: 300 }] };
      const top = expose({ minimum_spend: 300, total_spend: 320, counted_spend: 320, active_spending_tier_id: "t300", has_next_spending_tier: false }, card);
      expect(top.stage).toBe("rest");
      expect(top.pose).toEqual({ h: 1, v: 0.5 });
      const capped = expose({ minimum_spend: 300, total_spend: 650, counted_spend: 650, maximum_spend: 1000, active_spending_tier_id: "t300", has_next_spending_tier: false }, card);
      expect(capped.pose.v).toBeCloseTo(0.75, 9);
    } },
    { name: "monthly minimum, then a cap. No card minimum, monthly minimum 300", run: () => {
      const pending = expose({
        total_spend: 250, counted_spend: 250, qualification_status: "pending", minimum_spend_met: false, monthly_minimum_spend: 300,
        monthly_qualifications: [{ start: "2026-09-01", end: "2026-09-30", spend: 250, minimumSpend: 300, status: "pending" }],
      });
      expect(pending.stage).toBe("gate");
      expect(pending.pose.h).toBeCloseTo(250 / 300, 9);
      expect(pending.pose.v).toBe(0);
      expect(pending.markerX).toBeCloseTo(250 / 300, 9);
      // The month is met, with a cap of 1,000 and counted spend of 650: measured from the card's minimum (0), never the month's.
      const met = expose({
        total_spend: 650, counted_spend: 650, maximum_spend: 1000, qualification_status: "met", monthly_minimum_spend: 300,
        monthly_qualifications: [{ start: "2026-09-01", end: "2026-09-30", spend: 650, minimumSpend: 300, status: "met" }],
      });
      expect(met.pose.h).toBe(1);
      expect(met.pose.v).toBeCloseTo(0.65, 9);
      expect(met.hasMarker).toBe(false);
    } },
    { name: "the sun's geometry. A horizon at 42 and r 8", run: () => {
      const xs = [0.03, 0.5, 0.9, 1].map((h) => sunX({ h, v: 0 }));
      expect(xs[0]).toBeCloseTo(0.07, 9); expect(xs[1]).toBeCloseTo(0.5, 9); expect(xs[2]).toBeCloseTo(0.85, 9); expect(xs[3]).toBeCloseTo(0.85, 9);
      const ys = [0.03, 0.5, 0.9, 1].map((h) => sunY({ h, v: 0 }, HORIZON, RADIUS));
      expect(ys[0]).toBeCloseTo(42.64, 6); expect(ys[1]).toBeCloseTo(42.64, 6); expect(ys[2]).toBeCloseTo(39.36, 6); expect(ys[3]).toBeCloseTo(32.8, 6);
      const climb = [0, 0.5, 1].map((v) => sunY({ h: 1, v }, HORIZON, RADIUS));
      expect(climb[0]).toBeCloseTo(32.8, 6); expect(climb[1]).toBeCloseTo(12.2, 6); expect(climb[2]).toBeCloseTo(-8.4, 6);
    } },
    { name: "failed: no sun, no marker, the ridges apart", run: () => {
      const e = expose({
        qualification_status: "failed", minimum_spend_met: false, minimum_spend: 100, total_spend: 830.8,
        monthly_qualifications: [{ start: "2026-07-01", end: "2026-07-31", spend: 20, minimumSpend: 100, status: "failed" }],
      });
      expect(e.stage).toBe("failed");
      expect(e.pose).toEqual({ h: 0, v: 0 });
      expect(e.hasSun).toBe(false);
      expect(e.hasMarker).toBe(false);
      expect(e.markerX).toBeNull();
      expect(e.ridgesApart).toBe(true);
      expect(e.light).toBe("overcast");
    } },
    { name: "no target, also with rewards locked: calm, the sun resting, the ridges apart, an even light", run: () => {
      const open = expose({ total_spend: 315.5 });
      const locked = expose({
        total_spend: 900, qualification_status: "pending", minimum_spend_met: false,
        monthly_qualifications: [
          { start: "2026-09-01", end: "2026-09-30", spend: 320, minimumSpend: 300, status: "met" },
          { start: "2026-10-01", end: "2026-10-31", spend: 0, minimumSpend: 300, status: "pending" },
        ],
      }, {}, { period: ["2026-09-01", "2026-10-31"] });
      for (const e of [open, locked]) {
        expect(e.stage).toBe("calm");
        expect(e.pose).toEqual({ h: 1, v: 0 });
        expect(e.hasMarker).toBe(false);
        expect(e.hasSun).toBe(true);
        expect(e.ridgesApart).toBe(true);
        expect(e.light).toBe("even");
      }
    } },
    { name: "a range row draws no picture", run: () => {
      const p = projectRow(rowOf({ total_spend: 100, maximum_spend: 500 }), TODAY, true, TODAY);
      expect(exposure(p)).toBeNull();
    } },
    { name: "journey start: a card with a minimum sweeps then rises, one without starts resting so the sun climbs straight up", run: () => {
      const withMinimum = expose({ minimum_spend: 200, total_spend: 315.5, maximum_spend: 1000 });
      expect(withMinimum.journeyStart).toEqual({ h: 0, v: 0 });
      const gate = expose({ minimum_spend: 500, total_spend: 315.5, minimum_spend_met: false });
      expect(gate.journeyStart).toEqual({ h: 0, v: 0 });
      const capped = expose({ total_spend: 300, counted_spend: 300, maximum_spend: 300, maximum_spend_exceeded: true, should_stop_using: true });
      expect(capped.journeyStart).toEqual({ h: 1, v: 0 });
      const calm = expose({ total_spend: 315.5 });
      expect(calm.journeyStart).toEqual(calm.pose);
    } },
    { name: "target: changes with the action kind, the basis target or the deadline end, not with spend", run: () => {
      const a = expose({ minimum_spend: 500, total_spend: 315.5, minimum_spend_met: false });
      const sameTarget = expose({ minimum_spend: 500, total_spend: 400, minimum_spend_met: false });
      const otherCard = expose({ minimum_spend: 600, total_spend: 315.5, minimum_spend_met: false });
      const otherPeriod = expose({ minimum_spend: 500, total_spend: 315.5, minimum_spend_met: false }, {}, { period: ["2026-09-26", "2026-10-25"], asOf: TODAY });
      expect(sameTarget.target).toBe(a.target);
      expect(otherCard.target).not.toBe(a.target);
      expect(otherPeriod.target).not.toBe(a.target);
      const met = expose({ minimum_spend: 500, total_spend: 600 });
      expect(met.target).not.toBe(a.target);
    } },
    { name: "falls: a pose falls when h or v drops, not when both hold or rise", run: () => {
      expect(falls({ h: 0.4, v: 0 }, { h: 0.5, v: 0 })).toBe(true);
      expect(falls({ h: 1, v: 0.3 }, { h: 1, v: 0.5 })).toBe(true);
      expect(falls({ h: 1, v: 0.5 }, { h: 1, v: 0.5 })).toBe(false);
      expect(falls({ h: 1, v: 0.6 }, { h: 0.8, v: 0 })).toBe(false);
    } },
  ];
  for (const { name, run } of cases) test(name, run);
});
