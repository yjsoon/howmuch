import { memo, useEffect, useId, useLayoutEffect, useRef, useState, useSyncExternalStore, type ReactNode, type RefObject } from "react";
import { cssEase, cssTime, tweenPose } from "../lib/exposure-tween";
import { falls, type Exposure, type Pose } from "../lib/reward-exposure";
import { exposureScene, type Scene, type SceneLayout, MEET } from "../lib/reward-exposure-scene";

/*
 * The Rewards card's face: a sky, a pair of ridges and a sun, drawn as one SVG (docs/frontend/
 * rewards-exposure-card.md "Web parity"). React renders the SVG skeleton once. From then on the
 * scene is written to the DOM straight from the pose, so a glide never re-renders React and the
 * sun rides the horizon in the minimum journey and goes straight up its column in the climb.
 * Every colour is a token in styles/tokens.css (html[data-mode] picks the daytime or night
 * faces), and rewards-board.css switches only on data-type and data-stage.
 */

export type FaceVariant = "face" | "strip";
type FaceSize = { w: number; h: number; nameBottom: number; footTop: number };

/** What the first render draws before the face has been measured. */
const FIRST_SIZE: Record<FaceVariant, FaceSize> = {
  face: { w: 450, h: 300, nameBottom: 0, footTop: 0 },
  strip: { w: 361, h: 104, nameBottom: 32, footTop: 56 },
};

/** The last pose each card showed this session, so a row scrolled back into view or remounted does not replay its rise. */
const SHOWN = new Map<string, { target: string; pose: Pose }>();

const useIsoLayoutEffect = typeof window === "undefined" ? useEffect : useLayoutEffect;

function subscribeMode(onChange: () => void): () => void {
  const observer = new MutationObserver(onChange);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-mode"] });
  return () => observer.disconnect();
}
/** html[data-mode] is the resolved mode (set before first paint and kept in step by lib/theme.ts). */
function useResolvedMode(): "light" | "dark" {
  return useSyncExternalStore(subscribeMode, () => (document.documentElement.dataset.mode === "dark" ? "dark" : "light"), () => "light");
}

function layoutOf(variant: FaceVariant, s: FaceSize): SceneLayout {
  return variant === "strip" ? { kind: "strip", w: s.w, h: s.h, nameBottom: s.nameBottom, footTop: s.footTop } : { kind: "face", w: s.w, h: s.h };
}

export function ExposureFace({ exposure, variant, index, memoryKey, children }: {
  exposure: Exposure;
  variant: FaceVariant;
  /** Position in its group: the first rise is staggered by it. */
  index: number;
  /** Plan and card: the session memory that stops a rise replaying. */
  memoryKey?: string;
  children: ReactNode;
}) {
  const uid = useId().replace(/[^a-zA-Z0-9_-]/g, "");
  const faceRef = useRef<HTMLDivElement>(null);
  const svgRef = useRef<SVGSVGElement>(null);
  const cache = useRef<Record<string, SVGElement> | null>(null);
  const [size, setSize] = useState<FaceSize>(FIRST_SIZE[variant]);
  const sizeRef = useRef(size);
  const mode = useResolvedMode();
  const modeRef = useRef(mode);
  modeRef.current = mode;
  const exposureRef = useRef(exposure);
  exposureRef.current = exposure;
  // The pose the scene is at (or gliding to), whatever the size of the face.
  const poseRef = useRef<Pose>(exposure.pose);
  const seen = useRef(false);
  const cancel = useRef<() => void>(() => {});
  const lastTarget = useRef(exposure.target);
  const lastLight = useRef(exposure.light);

  const draw = (ex: Exposure, pose: Pose) => {
    poseRef.current = pose;
    const svg = svgRef.current;
    const s = sizeRef.current;
    if (!svg || s.w <= 0 || s.h <= 0) return;
    cache.current ??= collect(svg);
    const scene = exposureScene(layoutOf(variant, s), ex, pose, { nightPrint: modeRef.current === "dark" && ex.miles });
    paint(cache.current, svg, scene, uid, window.devicePixelRatio || 1);
  };

  // Measure the face (and, on the strip, the name and the foot the ridges are placed from).
  useIsoLayoutEffect(() => {
    const face = faceRef.current;
    if (!face) return;
    const measure = () => {
      const name = face.querySelector<HTMLElement>("[data-rw='name']");
      const foot = face.querySelector<HTMLElement>("[data-rw='foot']");
      const w = face.clientWidth, h = face.clientHeight;
      // Estimates until the text is laid out: about 0.31 and 0.54 of the row's height.
      const next: FaceSize = {
        w, h,
        nameBottom: name ? name.offsetTop + name.offsetHeight : 0.31 * h,
        footTop: foot ? foot.offsetTop : 0.54 * h,
      };
      const prev = sizeRef.current;
      if (Math.abs(prev.w - next.w) < 0.5 && Math.abs(prev.h - next.h) < 0.5 && Math.abs(prev.nameBottom - next.nameBottom) < 0.5 && Math.abs(prev.footTop - next.footTop) < 0.5) return;
      sizeRef.current = next;
      setSize(next);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(face);
    face.querySelectorAll("[data-rw]").forEach((el) => observer.observe(el));
    return () => observer.disconnect();
  }, [variant]);

  // The pose: the first showing rises from the journey's start; a changed target glides, or crossfades where it would fall.
  useIsoLayoutEffect(() => {
    const target = exposure.pose;
    const first = !seen.current;
    const remembered = memoryKey ? SHOWN.get(memoryKey) : undefined;
    // Never glide backwards or sink the sun: a new target that falls, or relights, swaps the face.
    // A changed light always swaps (failed, calm and journey can share a target string); a changed target only where it would fall.
    const crossfade = !first
      && (exposure.light !== lastLight.current || (exposure.target !== lastTarget.current && falls(target, poseRef.current)));
    let start: Pose;
    if (first) start = remembered ? (remembered.target === exposure.target ? remembered.pose : target) : exposure.journeyStart;
    else start = crossfade ? target : poseRef.current;
    seen.current = true;
    lastTarget.current = exposure.target;
    lastLight.current = exposure.light;
    if (memoryKey) SHOWN.set(memoryKey, { target: exposure.target, pose: target });
    cancel.current();
    if (crossfade) {
      draw(exposure, target);
      const fade = cssTime("--dur-standard", 320);
      if (fade > 0) svgRef.current?.animate?.([{ opacity: 0 }, { opacity: 1 }], { duration: fade, easing: "ease-out" });
      return;
    }
    if (start.h === target.h && start.v === target.v) {
      draw(exposure, target);
      return;
    }
    cancel.current = tweenPose(start, target, {
      duration: cssTime("--dur-fill", 600),
      delay: first ? Math.min(index, 12) * cssTime("--stagger", 28) : 0,
      ease: cssEase("--ease-out"),
      onFrame: (pose) => draw(exposureRef.current, pose),
    });
    return () => cancel.current();
    // The scene is drawn from these alone; index and the key only matter on the first showing.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [exposure.target, exposure.stage, exposure.light, exposure.miles, exposure.pose.h, exposure.pose.v, variant]);

  // The face resized, or the mode switched: draw the pose it is at.
  useIsoLayoutEffect(() => {
    draw(exposureRef.current, poseRef.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [size, mode]);

  return (
    <div className="rw-face" data-variant={variant} ref={faceRef}>
      <SceneSvg uid={uid} svgRef={svgRef} w={size.w} h={size.h} />
      {children}
    </div>
  );
}

// ------------------------------------------------------------------ the markup

const stops = (prefix: string, colour: string) =>
  [0, 1, 2, 3].map((i) => <stop key={i} data-p={`${prefix}${i}`} style={{ stopColor: colour }} offset="0" stopOpacity="0" />);

const SceneSvg = memo(function SceneSvg({ uid, svgRef, w, h }: { uid: string; svgRef: RefObject<SVGSVGElement | null>; w: number; h: number }) {
  const ref = (name: string) => `url(#${uid}-${name})`;
  return (
    <svg ref={svgRef} className="rw-scene" viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" aria-hidden="true" focusable="false">
      <defs>
        <linearGradient id={`${uid}-hz`} x1="0" y1="1" x2="0" y2="0">
          <stop offset="0" style={{ stopColor: "var(--face-horizon)" }} />
          <stop offset="0.45" style={{ stopColor: "var(--face-horizon)" }} />
          <stop offset="0.8" style={{ stopColor: "var(--face-horizon)" }} stopOpacity="0" />
        </linearGradient>
        <linearGradient id={`${uid}-sd`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" style={{ stopColor: "var(--sun-disc-1)" }} /><stop offset="1" style={{ stopColor: "var(--sun-disc-2)" }} />
        </linearGradient>
        <linearGradient id={`${uid}-sr`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" style={{ stopColor: "var(--sun-rise-1)" }} /><stop offset="1" style={{ stopColor: "var(--sun-rise-2)" }} />
        </linearGradient>
        <linearGradient id={`${uid}-gs`} gradientUnits="userSpaceOnUse" x1="0" y1="0" data-p="gsGrad" x2="1" y2="0">{stops("gs", "var(--face-lit)")}</linearGradient>
        <linearGradient id={`${uid}-gg`} gradientUnits="userSpaceOnUse" x1="0" y1="0" data-p="ggGrad" x2="1" y2="0">{stops("gg", "var(--face-lit)")}</linearGradient>
        <linearGradient id={`${uid}-vd`} gradientUnits="userSpaceOnUse" x1="0" y1="0" data-p="vdGrad" x2="1" y2="0">{stops("vd", "var(--face-veil-dim)")}</linearGradient>
        <linearGradient id={`${uid}-vg`} gradientUnits="userSpaceOnUse" x1="0" y1="0" data-p="vgGrad" x2="1" y2="0">{stops("vg", "var(--face-veil-grey)")}</linearGradient>
        <linearGradient id={`${uid}-vm`} gradientUnits="userSpaceOnUse" x1="0" y1="0" data-p="vmGrad" x2="1" y2="0">{stops("vm", "var(--rw-veil-multiply)")}</linearGradient>
        {/* The strip's glow: the rings' palette as one smooth falloff, so nothing clips into arcs on a short frame. */}
        <radialGradient id={`${uid}-glow`} cx="0.5" cy="0.5" r="0.5">
          <stop offset="0" style={{ stopColor: "var(--face-ring-1)" }} /><stop offset="0.3" style={{ stopColor: "var(--face-ring-2)" }} />
          <stop offset="0.6" style={{ stopColor: "var(--face-ring-3)" }} /><stop offset="0.82" style={{ stopColor: "var(--face-ring-4)" }} />
          <stop offset="1" style={{ stopColor: "var(--face-ring-4)" }} stopOpacity="0" />
        </radialGradient>
        <radialGradient id={`${uid}-pour`} gradientUnits="userSpaceOnUse" data-p="pourGrad" cx="0" cy="0" r="1">
          <stop offset="0" style={{ stopColor: "var(--sun-disc-1)" }} /><stop offset="0.3" style={{ stopColor: "var(--sun-core)" }} />
          <stop offset="1" style={{ stopColor: "var(--sun-core)" }} stopOpacity="0" />
        </radialGradient>
        <linearGradient id={`${uid}-trail`} gradientUnits="userSpaceOnUse" data-p="trailGrad" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" style={{ stopColor: "var(--face-contrail)" }} stopOpacity="0" /><stop offset="0.35" style={{ stopColor: "var(--face-contrail)" }} />
          <stop offset="0.7" style={{ stopColor: "var(--face-contrail)" }} /><stop offset="1" style={{ stopColor: "var(--face-contrail)" }} stopOpacity="0" />
        </linearGradient>
        <clipPath id={`${uid}-sky`}><path data-p="skyClip" d="" /></clipPath>
        <clipPath id={`${uid}-ground`}><path data-p="groundClip" d="" /></clipPath>
      </defs>
      <rect data-p="hz" width={w} height={h} fill={ref("hz")} />
      <rect data-p="hz2" width={w} height={h} fill={ref("hz")} />
      <g data-p="trail" className="rw-trail" fill="none" strokeWidth="1.4" strokeLinecap="round" style={{ stroke: ref("trail") }}>
        <path data-p="trail0" d="" /><path data-p="trail1" d="" />
      </g>
      <g clipPath={ref("sky")}>
        <rect data-p="goldSky" className="rw-gold" width={w} height={h} fill={ref("gs")} />
        <rect data-p="bloom" className="rw-bloom" width={w} height={h} />
        <rect data-p="pour" className="rw-pour" width={w} height={h} fill={ref("pour")} />
      </g>
      <g data-p="halo" className="rw-halo">
        <g data-p="haloAt">
          <circle data-p="glow" className="rw-glow" r="0" fill={ref("glow")} />
          <circle data-p="ring0" className="rw-ring-4" r="0" /><circle data-p="ring1" className="rw-ring-3" r="0" />
          <circle data-p="ring2" className="rw-ring-2" r="0" /><circle data-p="ring3" className="rw-ring-1" r="0" />
          <circle data-p="core" className="rw-core" r="0" />
        </g>
      </g>
      <path data-p="back" className="rw-ridge-back" d="" />
      <path data-p="bcrest" className="rw-crest-target" d="" />
      <path data-p="front" className="rw-ridge-front" d="" />
      <path data-p="crest" className="rw-crest" d="" />
      <g clipPath={ref("ground")}><rect data-p="goldGround" className="rw-gold" width={w} height={h} fill={ref("gg")} /></g>
      <rect data-p="vDim" className="rw-veil-dim" width={w} height={h} fill={ref("vd")} />
      <rect data-p="vGrey" className="rw-veil-grey" width={w} height={h} fill={ref("vg")} />
      <rect data-p="vMult" className="rw-veil-multiply" width={w} height={h} fill={ref("vm")} />
      <g clipPath={ref("sky")}>
        <g data-p="sun"><circle data-p="sunDisc" className="rw-sun" r="0" fill={ref("sd")} /></g>
      </g>
      <g data-p="marker" className="rw-marker">
        {[0, 1, 2, 3].map((i) => <line key={`e${i}`} data-p={`mkE${i}`} className="rw-mk-edge" strokeLinecap="butt" />)}
        {[0, 1, 2, 3].map((i) => <line key={`l${i}`} data-p={`mk${i}`} className="rw-mk" strokeLinecap="butt" />)}
      </g>
    </svg>
  );
});

// -------------------------------------------------------------------- painting

function collect(svg: SVGSVGElement): Record<string, SVGElement> {
  const out: Record<string, SVGElement> = {};
  svg.querySelectorAll<SVGElement>("[data-p]").forEach((el) => { out[el.dataset.p!] = el; });
  return out;
}

const n = (x: number) => (Number.isFinite(x) ? x.toFixed(2) : "0");

function setStops(els: Record<string, SVGElement>, prefix: string, offsets: number[], opacities: number[]) {
  for (let i = 0; i < 4; i++) {
    const stop = els[`${prefix}${i}`]!;
    stop.setAttribute("offset", n(offsets[i]!));
    stop.setAttribute("stop-opacity", n(opacities[i]!));
  }
}

function paint(e: Record<string, SVGElement>, svg: SVGSVGElement, s: Scene, uid: string, dpr: number): void {
  const set = (name: string, attr: string, value: string) => e[name]!.setAttribute(attr, value);
  const show = (name: string, on: boolean) => e[name]!.setAttribute("display", on ? "inline" : "none");

  // Ridges.
  set("back", "d", s.backFill);
  set("bcrest", "d", s.backCrest);
  set("front", "d", s.lowerFill);
  set("crest", "d", s.lowerCrest);
  set("skyClip", "d", s.skyClip);
  set("groundClip", "d", s.backFill);
  svg.toggleAttribute("data-merged", s.merged);
  (e.crest as SVGElement).style.setProperty("--crest-k", n(s.v));

  // The sun, its rings and the glow pouring from the top edge.
  set("sun", "transform", `translate(${n(s.sun.x)} ${n(s.sun.y)})`);
  set("sunDisc", "r", n(s.sun.r));
  set("sunDisc", "stroke-width", n(Math.max(1, s.w * 0.003)));
  set("sunDisc", "fill", `url(#${uid}-${s.sun.rising ? "sr" : "sd"})`);
  show("sun", s.sun.visible);
  show("halo", s.halo.visible);
  set("haloAt", "transform", `translate(${n(s.sun.x)} ${n(s.sun.y)})`);
  (e.halo as SVGElement).style.opacity = n(s.halo.opacity);
  show("glow", s.halo.soft);
  set("glow", "r", n(s.halo.rings[0]));
  s.halo.rings.forEach((r, i) => { show(`ring${i}`, !s.halo.soft); set(`ring${i}`, "r", n(r)); });
  set("core", "r", n(s.halo.core));
  set("pourGrad", "cx", n(s.pour.cx));
  set("pourGrad", "r", n(s.pour.radius));
  (e.pour as SVGElement).style.setProperty("--pour-k", n(s.pour.k));
  (e.bloom as SVGElement).style.opacity = n(s.bloom);
  (e.hz2 as SVGElement).style.opacity = n(s.horizonBoost);

  // Light: gold to the marker (daytime) and the underexposure beyond it.
  const g = s.gold;
  const goldOffsets = [0, g.from, g.to, 1];
  const pastSky = g.whole ? 1 : g.beyond.sky, pastGround = g.whole ? 1 : g.beyond.ground;
  setStops(e, "gs", goldOffsets, [g.sky, g.sky, g.sky * pastSky, g.sky * pastSky]);
  setStops(e, "gg", goldOffsets, [g.ground, g.ground, g.ground * pastGround, g.ground * pastGround]);
  for (const name of ["gsGrad", "ggGrad", "vdGrad", "vgGrad", "vmGrad"]) set(name, "x2", n(s.w));
  const v = s.veil;
  const veilOffsets = [0, v.from, v.to, 1];
  const ramp = (v.whole ? [1, 1, 1, 1] : [0, 0, 1, 1]).map((k) => k * v.strength);
  // The daytime dim meets the gold the same way: a tenth of it on the lit side, nine tenths beyond.
  const dim = (v.whole ? [1, 1, 1, 1] : [MEET.sky, MEET.sky, 1 - MEET.sky, 1 - MEET.sky]).map((k) => k * v.strength);
  setStops(e, "vd", veilOffsets, dim.map((k) => k * (v.failed ? 14 / 15 : 1)));
  setStops(e, "vg", veilOffsets, ramp.map((k) => k * 0.5));
  setStops(e, "vm", veilOffsets, ramp);
  show("vDim", v.on); show("vGrey", v.on); show("vMult", v.on);

  // The contrail: static, high in the right of the sky; the tokens leave it transparent in dark mode.
  show("trail", s.contrail.on);
  s.contrail.lines.forEach(([x0, y0, x1, y1], i) => set(`trail${i}`, "d", `M${n(x0)},${n(y0)} L${n(x1)},${n(y1)}`));
  set("trailGrad", "x1", n(s.contrail.x0));
  set("trailGrad", "x2", n(s.contrail.x1));

  // The marker: two device pixels wide, snapped to the pixel grid, in two tones split at the target horizon.
  show("marker", s.marker.on);
  if (s.marker.on) {
    const x = Math.round(s.marker.x * dpr) / dpr;
    const pieces: Array<{ a: number; b: number; ridge: boolean }> = [];
    for (const [a, b] of s.marker.segments) {
      const hy = s.marker.horizon;
      if (a < hy) pieces.push({ a, b: Math.min(b, hy), ridge: false });
      if (b > hy) pieces.push({ a: Math.max(a, hy), b, ridge: true });
    }
    for (let i = 0; i < 4; i++) {
      const piece = pieces[i];
      for (const prefix of ["mkE", "mk"]) {
        const line = e[`${prefix}${i}`]!;
        if (!piece) { line.setAttribute("display", "none"); continue; }
        line.setAttribute("display", "inline");
        line.setAttribute("x1", n(x)); line.setAttribute("x2", n(x));
        line.setAttribute("y1", n(piece.a)); line.setAttribute("y2", n(piece.b));
        line.setAttribute("stroke-width", n((prefix === "mkE" ? 4 : 2) / dpr));
        if (piece.ridge) line.setAttribute("data-ridge", ""); else line.removeAttribute("data-ridge");
      }
    }
  }
}
