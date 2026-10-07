import type { Pose } from "./reward-exposure";

/*
 * The pose tween (docs/frontend/rewards-exposure-card.md "Motion"). Only the pose animates:
 * h and v. The caller recomputes the whole scene from each frame's pose and writes it straight
 * to the DOM, so React never re-renders per frame, the sun rides the horizon in the minimum
 * journey and goes straight up its column in the climb in every browser (Safari cannot
 * transition a path's d), and it never moves diagonally: where both h and v rise, h sweeps over
 * the first 40% of the glide and v rises over the rest.
 *
 * Timings come from the motion tokens (--dur-fill, --stagger, --ease-out), which
 * tokens.css zeroes under Reduce Motion, so a zero duration means "jump".
 */

/** A CSS time token ("600ms", "0.6s", "0") in milliseconds. */
export function cssTime(name: string, fallback: number): number {
  if (typeof document === "undefined") return fallback;
  const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const match = /^(-?[\d.]+)(ms|s)?$/.exec(raw);
  if (!match) return fallback;
  const value = Number(match[1]);
  return Number.isFinite(value) ? (match[2] === "s" ? value * 1000 : value) : fallback;
}

/** A CSS cubic-bezier() token as an easing function of 0..1 progress. */
export function cssEase(name: string): (u: number) => number {
  const raw = typeof document === "undefined" ? "" : getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const match = /^cubic-bezier\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)$/.exec(raw);
  if (!match) return (u) => 1 - Math.pow(1 - u, 3);
  return cubicBezier(Number(match[1]), Number(match[2]), Number(match[3]), Number(match[4]));
}

export function cubicBezier(x1: number, y1: number, x2: number, y2: number): (u: number) => number {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const sampleX = (t: number) => ((ax * t + bx) * t + cx) * t;
  const sampleY = (t: number) => ((ay * t + by) * t + cy) * t;
  const slopeX = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const err = sampleX(t) - x;
      if (Math.abs(err) < 1e-6) return sampleY(t);
      const slope = slopeX(t);
      if (Math.abs(slope) < 1e-6) break;
      t -= err / slope;
    }
    let lo = 0, hi = 1;
    t = x;
    while (lo < hi) {
      const value = sampleX(t);
      if (Math.abs(value - x) < 1e-6) break;
      if (x > value) lo = t; else hi = t;
      t = (hi - lo) / 2 + lo;
      if (hi - lo < 1e-7) break;
    }
    return sampleY(t);
  };
}

const clamp = (x: number) => Math.min(1, Math.max(0, x));
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

/** The pose at eased progress `k` (0..1) of a glide from `from` to `to`. */
export function poseAt(from: Pose, to: Pose, k: number): Pose {
  // When the light and the sun both move, the sweep takes the first 40% and the rise the rest.
  const sequence = to.h > from.h + 1e-6 && to.v > from.v + 1e-6;
  const kh = sequence ? clamp(k / 0.4) : k;
  const kv = sequence ? clamp((k - 0.4) / 0.6) : k;
  return { h: lerp(from.h, to.h, kh), v: lerp(from.v, to.v, kv) };
}

export interface TweenOptions {
  duration: number;
  delay?: number;
  ease: (u: number) => number;
  onFrame: (pose: Pose) => void;
}

/** Starts a glide and returns its cancel. The first frame draws `from`; the last draws `to` exactly. */
export function tweenPose(from: Pose, to: Pose, options: TweenOptions): () => void {
  const { duration, delay = 0, ease, onFrame } = options;
  if (!(duration > 0)) {
    onFrame(to);
    return () => {};
  }
  let raf = 0;
  let start = 0;
  onFrame(from);
  // performance.now(), not the rAF timestamp: after a long task the timestamp can be a vsync older than the
  // moment the glide began, which would swallow most of it.
  const frame = () => {
    const now = performance.now();
    if (!start) start = now + delay;
    const u = clamp((now - start) / duration);
    onFrame(u >= 1 ? to : poseAt(from, to, ease(u)));
    if (u < 1) raf = requestAnimationFrame(frame);
  };
  raf = requestAnimationFrame(frame);
  return () => cancelAnimationFrame(raf);
}
