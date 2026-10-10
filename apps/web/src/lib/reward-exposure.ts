import type { Action, RewardRowProjection } from "./reward-row-projection";

/*
 * The Sun Arc mapping (docs/frontend/rewards-exposure-card.md "The mapping"): one pure function
 * from a RewardRowProjection to a stage and two picture values, both 0 to 1.
 *
 *   h  across: the share of the way to the minimum (the fill of the minimum or monthly-minimum
 *      basis). 1 once the minimum is met, or when the card has none.
 *   v  up: how far the sun has climbed in its column. 0 resting just above the ground, 0.5
 *      halfway, 1 off the top edge. Measured from the minimum (or the reached tier), so the
 *      climb starts on the day the minimum is met and nothing jumps.
 *
 * The journeys never share a value: while h is below 1, v is 0, and while v is above 0, h is 1.
 * These are picture coordinates, never printed, spoken or turned into words. It mirrors
 * RewardExposure on iOS (the sketch in the spec); the scene geometry is in reward-exposure-scene.ts.
 */

export type Stage = "gate" | "climb" | "rest" | "capped" | "calm" | "failed";
export type Light = "journey" | "even" | "overcast";
export interface Pose { h: number; v: number }

/** Where the sun rests, as a share of the width. */
export const COLUMN = 0.85;
/** Where the sun can ride the marker, as a share of the width. */
export const RIDE_MIN = 0.07;
export const RIDE_MAX = 0.85;

export interface Exposure {
  stage: Stage;
  pose: Pose;
  miles: boolean;
  /** Whether the card ever had a minimum journey: where a first showing starts. */
  hasMinimum: boolean;
  /** Changes when the target does: another action kind, basis target or deadline end. */
  target: string;
  light: Light;
  hasMarker: boolean;
  hasSun: boolean;
  /** The marker's x as a share of the width: exactly the fill, in the minimum journey only. */
  markerX: number | null;
  /** The brand pair, apart at rest: no journey to show. */
  ridgesApart: boolean;
  /** Where a first showing starts: a card with a minimum sweeps across and then rises. */
  journeyStart: Pose;
}

/** A plain amount: finite and positive, else 0. */
function amount(x: number): number {
  return Number.isFinite(x) && x > 0 ? x : 0;
}
function clamp(x: number): number {
  return Number.isFinite(x) ? Math.min(1, Math.max(0, x)) : 0;
}
/** Progress over a span; a span that is not positive counts as complete. */
function ratio(x: number, over: number): number {
  return over > 0 ? clamp(x / over) : 1;
}

function kind(action: Action): string {
  switch (action.kind) {
    case "monthlyMinimum": return "monthly";
    case "minimum": return "minimum";
    case "nextTier": return "tier";
    case "capHeadroom":
    case "capReached": return "cap";
    default: return "none";
  }
}

/** Null for range rows, which draw no picture. */
export function exposure(p: RewardRowProjection): Exposure | null {
  if (p.action.kind === "range") return null;
  const minimum = amount(p.minimumAmount);
  const tier = amount(p.reachedTierThreshold);
  let stage: Stage;
  let pose: Pose;
  switch (p.action.kind) {
    case "qualificationFailed":
      stage = "failed"; pose = { h: 0, v: 0 }; break;
    case "monthlyMinimum":
    case "minimum":
      stage = "gate"; pose = { h: clamp(p.fill ?? 0), v: 0 }; break;
    case "nextTier": {
      stage = "climb";
      // Once a tier is reached the sun stays at halfway: it never sinks towards a further tier.
      let v = tier > 0 ? 0.5 : 0;
      if (tier === 0 && p.basis) {
        const next = p.basis.target;
        const from = minimum < next ? minimum : 0;
        v = 0.5 * ratio(p.basis.spend - from, next - from);
      }
      pose = { h: 1, v };
      break;
    }
    case "capHeadroom": {
      stage = "climb";
      const base = tier > 0 ? 0.5 : 0;
      let v = base;
      if (p.basis) {
        const cap = p.basis.target;
        const foot = tier > 0 ? tier : minimum;
        const from = cap > foot ? foot : 0;
        v = base + (1 - base) * ratio(p.basis.spend - from, cap - from);
      }
      pose = { h: 1, v };
      break;
    }
    case "capReached":
      stage = "capped"; pose = { h: 1, v: 1 }; break; // the partial block and the exceeded cap included
    case "topTier":
      stage = "rest"; pose = { h: 1, v: 0.5 }; break;
    case "minimumMet":
      stage = "rest"; pose = { h: 1, v: 0 }; break;
    case "noTarget":
      stage = "calm"; pose = { h: 1, v: 0 }; break;
  }
  const hasMinimum = minimum > 0;
  const journeyStart: Pose = stage === "gate" ? { h: 0, v: 0 }
    : stage === "climb" || stage === "rest" || stage === "capped" ? { h: hasMinimum ? 0 : 1, v: 0 }
    : pose;
  return {
    stage,
    pose,
    miles: p.rewardType === "miles",
    hasMinimum,
    target: `${kind(p.action)}|${p.basis?.target ?? 0}|${p.deadline?.end ?? ""}`,
    light: stage === "failed" ? "overcast" : stage === "calm" ? "even" : "journey",
    hasMarker: stage === "gate",
    hasSun: stage !== "failed",
    markerX: stage === "gate" ? pose.h : null,
    ridgesApart: stage === "failed" || stage === "calm",
    journeyStart,
  };
}

/** What a range row draws in place of a picture: a still sky and the brand ridges, apart, with no sun and no marker. */
export function stillExposure(miles: boolean): Exposure {
  return {
    stage: "calm", pose: { h: 1, v: 0 }, miles, hasMinimum: false, target: "range", light: "even",
    hasMarker: false, hasSun: false, markerX: null, ridgesApart: true, journeyStart: { h: 1, v: 0 },
  };
}

/** A pose falls when either value drops: such a change crossfades instead of gliding backwards. */
export function falls(pose: Pose, from: Pose): boolean {
  return pose.h < from.h || pose.v < from.v;
}

/** How far the sun has lifted clear of the horizon, over h 0.85 to 1. */
export function lift(pose: Pose): number {
  return clamp((pose.h - 0.85) / 0.15);
}

/** The sun's x as a share of the width, riding the marker while the minimum journey runs. */
export function sunX(pose: Pose): number {
  return pose.h >= 1 ? COLUMN : Math.min(Math.max(pose.h, RIDE_MIN), RIDE_MAX);
}

/** The share of the full gap between the ridges that is left. */
export function gap(pose: Pose): number {
  return 1 - pose.h;
}

/**
 * The sun's centre y for a target horizon at `horizon` and a disc of radius `r` (y points down).
 * `seat` is how far below the horizon the disc's centre sits while it rides it, as a share of `r`:
 * a hair below on the face, and exactly on it on the phone strip, where the disc is a clean half-sun.
 */
export function sunY(pose: Pose, horizon: number, r: number, seat = 0.08): number {
  const sit = horizon + seat * r;
  const rest = horizon - 1.15 * r;
  return pose.h < 1 ? sit + (rest - sit) * lift(pose) : rest + (-1.05 * r - rest) * pose.v;
}
