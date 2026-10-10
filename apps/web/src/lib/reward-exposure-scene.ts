import { COLUMN, lift, sunX, sunY, type Exposure, type Pose } from "./reward-exposure";

/*
 * The Sun Arc scene as plain numbers and path strings (docs/frontend/rewards-exposure-card.md
 * "Geometry"). Pure and mode-independent: colours come from the tokens in styles/tokens.css, so
 * nothing here names one. The component paints this onto its SVG each frame (components/
 * ExposureFace.tsx); the mapping that decides h and v is reward-exposure.ts.
 *
 * Everything is in CSS pixels of the face, y pointing down. The viewBox is the measured size of
 * the face, so a circle is a circle and a 1px stroke is 1px.
 */

export type SceneLayout =
  /** The desktop 3:2 face (and any taller frame): the brand ridge is the target horizon. */
  | { kind: "face"; w: number; h: number }
  /** The phone strip: level horizons placed from the measured bottom of the name and top of the foot. */
  | { kind: "strip"; w: number; h: number; nameBottom: number; footTop: number };

// ------------------------------------------------------------- the brand ridges

type Cubic = [number, number, number, number, number, number];

/** The web's shipped brand paths (viewBox 0 400 1024 624), verbatim: M start, then C segments. */
const BACK_SOURCE = { start: [0, 664] as [number, number], segments: [
  [110, 646, 196, 606, 296, 612], [396, 618, 452, 546, 556, 524], [656, 502, 724, 470, 822, 444], [898, 424, 962, 434, 1024, 402],
] as Cubic[] };
const FRONT_SOURCE = { start: [0, 820] as [number, number], segments: [
  [96, 806, 176, 782, 258, 792], [336, 801, 372, 738, 462, 722], [534, 709, 574, 748, 648, 728], [758, 698, 818, 634, 898, 612], [950, 598, 988, 602, 1024, 584],
] as Cubic[] };

const TABLE_POINTS = 65;

/** Samples a cubic path into `TABLE_POINTS` y values at even x, as a share of the frame height (the brand art sits in the bottom 58%). */
function crestTable(source: { start: [number, number]; segments: Cubic[] }): number[] {
  const dense: Array<[number, number]> = [source.start];
  let [px, py] = source.start;
  for (const [c1x, c1y, c2x, c2y, x, y] of source.segments) {
    for (let step = 1; step <= 64; step++) {
      const t = step / 64, u = 1 - t;
      dense.push([
        u * u * u * px + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x,
        u * u * u * py + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y,
      ]);
    }
    px = x; py = y;
  }
  const table: number[] = [];
  let cursor = 1;
  for (let i = 0; i < TABLE_POINTS; i++) {
    const x = (i / (TABLE_POINTS - 1)) * 1024;
    while (cursor < dense.length - 1 && dense[cursor]![0] < x) cursor++;
    const a = dense[cursor - 1]!, b = dense[cursor]!;
    const f = b[0] === a[0] ? 0 : Math.min(1, Math.max(0, (x - a[0]) / (b[0] - a[0])));
    const y = a[1] + (b[1] - a[1]) * f;
    table.push(0.42 + ((y - 400) / 624) * 0.58);
  }
  return table;
}

/** The brand back and front ridges' crests, 65 points each, as a share of the frame height. */
export const BACK_CREST = crestTable(BACK_SOURCE);
export const FRONT_CREST = crestTable(FRONT_SOURCE);

/** A crest as 0 to 1 over its own range: 1 at its lowest (the left) and 0 at its highest (the right). */
function normalised(table: readonly number[]): number[] {
  const lo = Math.min(...table), hi = Math.max(...table);
  return table.map((y) => (y - lo) / (hi - lo));
}
/** The brand back ridge's rise, 1 at the left edge and 0 at the right: the phone strip's horizons take its shape. */
export const BACK_RISE = normalised(BACK_CREST);

function crestAt(table: readonly number[], x: number): number {
  const f = Math.min(1, Math.max(0, x)) * (table.length - 1);
  const i = Math.min(table.length - 2, Math.floor(f));
  return table[i]! + (table[i + 1]! - table[i]!) * (f - i);
}

// ------------------------------------------------------------------- the scene

export interface Scene {
  w: number;
  h: number;
  backFill: string;
  backCrest: string;
  lowerFill: string;
  lowerCrest: string;
  /** The sky above the target horizon: the clip for the sun, the gold, the bloom and the pour. */
  skyClip: string;
  /** One merged ridge: the target horizon and the spend horizon coincide. */
  merged: boolean;
  sun: { visible: boolean; x: number; y: number; r: number; rising: boolean };
  /** `soft`: one smooth glow of radius `rings[0]` in place of the posterised rings (the phone strip). */
  halo: { visible: boolean; opacity: number; soft: boolean; rings: [number, number, number, number]; core: number };
  /** Gold laid over the sky and the ground: peak alphas and the gradient offsets (shares of the width).
   *  `beyond` is the share of the peak kept right of the marker (the strip's lift; 0 elsewhere). */
  gold: { sky: number; ground: number; from: number; to: number; whole: boolean; beyond: number };
  /** The underexposure right of the marker (the minimum journey), or everywhere when failed. `strength` is its
   *  peak, 0 to 1: the strip lets the last of the band light as the sun lifts, so no sliver is left at the edge. */
  veil: { on: boolean; from: number; to: number; whole: boolean; failed: boolean; strength: number };
  /** Dark mode only (the token is transparent in light): the bloom's opacity and the extra horizon warmth. */
  bloom: number;
  horizonBoost: number;
  /** The glow pouring from the top edge as the sun leaves: its centre x, radius and 0 to 1 strength (times the token's peak). */
  pour: { cx: number; radius: number; k: number };
  /** The hairline at x = h × W; `horizon` is the target horizon's y there, where its two tones split. */
  marker: { on: boolean; x: number; segments: Array<[number, number]>; horizon: number };
  contrail: { on: boolean; x0: number; x1: number; lines: [[number, number, number, number], [number, number, number, number]] };
  /** 0 to 1: how far the climb is, for the merged crest's brightening. */
  v: number;
}

export interface SceneOptions {
  /** Night print (dark mode, miles): its pour stops short of the name. */
  nightPrint?: boolean;
}

const SEGMENTS = 96;

function clamp01(x: number): number {
  return Number.isFinite(x) ? Math.min(1, Math.max(0, x)) : 0;
}

function polyline(points: Array<[number, number]>): string {
  return points.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
}

export function exposureScene(layout: SceneLayout, ex: Exposure, pose: Pose, options: SceneOptions = {}): Scene {
  const { w, h: H } = layout;
  const strip = layout.kind === "strip";
  const r = strip ? 10 : 0.045 * w;
  const wiggle = (ux: number) => Math.sin(ux * 8.2 + 0.4);
  // Upper line: the target horizon. The brand back ridge on the face; on the strip the same rise, 12pt
  // deep, from 14pt under the name at the left to 2pt under it at the right, where the sun's column is.
  const upper = strip
    ? (ux: number) => layout.nameBottom + 2 + 12 * crestAt(BACK_RISE, ux)
    : (ux: number) => H * crestAt(BACK_CREST, ux);
  // The floor the spend horizon lifts from: level on the face (or the brand front ridge for a card with
  // no journey). On the strip it is the target horizon's own shape, as far down as the words allow (3pt
  // above the foot at its lowest, the left edge), so the two slopes start equidistant and converge.
  const stripGap = strip ? Math.max(4, layout.footTop - 3 - (layout.nameBottom + 14)) : 0;
  const level = strip
    ? (ux: number) => upper(ux) + stripGap
    : (ux: number) => H * (0.8 + 0.01 * wiggle(ux));
  const floor = ex.ridgesApart && !strip ? (ux: number) => H * crestAt(FRONT_CREST, ux) : level;
  // On the strip a card with no minimum keeps the pair apart: the convergence is the minimum's own read.
  const across = ex.ridgesApart || (strip && !ex.hasMinimum) ? 0 : pose.h;

  // On the strip the lower slope is anchored at the left, as low as the words allow, and only its far end
  // rises: with the fill, until the minimum is met, when it meets the target where in the period that
  // happened (metAt) and runs with it from there. So the meeting point reads as when the minimum was met.
  const metAt = across >= 1 ? Math.max(0, Math.min(1, ex.metAt ?? 1)) : 1;
  const stripLower = (ux: number, up: number, fl: number) =>
    across <= 0 ? fl
      : across < 1 ? fl - (fl - up) * across * ux
      : metAt <= 0 ? up
      : fl - (fl - up) * Math.min(1, ux / metAt);
  const backPts: Array<[number, number]> = [];
  const lowerPts: Array<[number, number]> = [];
  for (let i = 0; i <= SEGMENTS; i++) {
    const ux = i / SEGMENTS;
    const up = upper(ux), fl = floor(ux);
    backPts.push([ux * w, up]);
    lowerPts.push([ux * w, strip ? stripLower(ux, up, fl) : fl + across * (up - fl)]);
  }
  const closed = (pts: Array<[number, number]>, edge: number) => `${polyline(pts)} L${w},${edge} L0,${edge} Z`;
  const merged = across >= 1;

  // The sun.
  const column = sunX(pose);
  const horizon = upper(column);
  // On the strip the disc sits exactly on the horizon, a clean half-sun, and lifts clear from there.
  const sunPx = { x: column * w, y: sunY(pose, horizon, r, strip ? 0 : 0.08) };
  const v = clamp01(pose.v);
  // The strip has no room for a hairline or a sliver: the sun is the marker, and the last of the band
  // lights as the sun lifts.
  const lifted = strip ? lift(pose) : 0;

  // Rings grow continuously with v; on the strip they are also capped by the frame's height.
  let R = (0.14 + 0.24 * v) * w;
  if (strip) R = Math.min(R, (0.42 + 0.6 * v) * H);

  // Light: lit from the left edge to the marker and underexposed to its right, with a 4% falloff either side.
  const gate = ex.stage === "gate";
  const failed = ex.stage === "failed";
  const even = ex.light === "even";
  const from = clamp01(pose.h - 0.04), to = clamp01(pose.h + 0.04);
  const whole = !gate;
  const gold = failed ? { sky: 0, ground: 0 }
    : even ? { sky: 0.3, ground: 0.12 }
    : { sky: 0.5 + 0.12 * v, ground: 0.16 + 0.08 * v };

  const sunOn = ex.hasSun;
  const markerOn = ex.hasMarker && pose.h < 1 && !strip;
  const mx = pose.h * w;
  const pad = Math.max(1, w * 0.003);
  const onDisc = Math.abs(mx - sunPx.x) < r + 4;
  const top = 0.06 * H;
  const segments: Array<[number, number]> = onDisc
    ? [[top, Math.max(top, sunPx.y - r - pad)], [Math.min(H, sunPx.y + r + pad), H]]
    : [[top, H]];

  const trail = strip ? [0.5, 0.3, 0.76, 0.2] as const : [0.56, 0.3, 0.8, 0.21] as const;
  const trailGap = strip ? 0.007 * w : 0.004 * w;
  const tl: [number, number, number, number] = [trail[0] * w, trail[1] * H, trail[2] * w, trail[3] * H];

  return {
    w, h: H,
    backFill: closed(backPts, H),
    backCrest: polyline(backPts),
    lowerFill: closed(lowerPts, H),
    lowerCrest: polyline(lowerPts),
    skyClip: `M0,0 ${backPts.map(([x, y]) => `L${x.toFixed(1)},${y.toFixed(1)}`).join(" ")} L${w},0 Z`,
    merged,
    sun: { visible: sunOn, x: sunPx.x, y: sunPx.y, r, rising: gate },
    halo: { visible: sunOn, opacity: 0.4 + 0.6 * v, soft: strip, rings: [R * 0.92, R * 0.68, R * 0.46, R * 0.27], core: R * 0.15 },
    gold: { ...gold, from: whole ? 0 : from, to: whole ? 1 : to, whole, beyond: lifted },
    veil: { on: gate || failed, from, to, whole: failed, failed, strength: failed ? 1 : 1 - lifted },
    bloom: sunOn ? 0.3 * v : 0,
    horizonBoost: sunOn ? 0.5 * v : 0,
    pour: {
      cx: COLUMN * w,
      radius: (options.nightPrint ? 0.35 : strip ? 0.62 : 0.78) * w,
      k: sunOn ? clamp01((v - 0.4) / 0.6) : 0,
    },
    marker: { on: markerOn, x: mx, segments, horizon: upper(pose.h) },
    contrail: {
      on: ex.miles && !failed,
      x0: tl[0], x1: tl[2],
      lines: [tl, [tl[0], tl[1] + trailGap, tl[2], tl[3] + trailGap]],
    },
    v,
  };
}
