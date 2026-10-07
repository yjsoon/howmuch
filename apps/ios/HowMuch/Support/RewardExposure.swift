import Foundation

/// The Rewards Exposure card ("Sun Arc v3", `docs/frontend/rewards-exposure-card.md`):
/// the pure mapping from a projection to what the picture shows, and the scene
/// geometry the Canvas draws. Nothing here prints or speaks; `h` and `v` are
/// picture coordinates, never figures.
///
/// There are two journeys and they never share a value. Across (`h`) is the way
/// to the minimum: the light spreads left to right to a marker and the sun rides
/// the horizon. Up (`v`) is the way past it, through a tier and on to the bonus
/// cap: the sun rises from just above the ground to off the top edge.
struct RewardExposure: Equatable {
  enum Stage: Equatable { case gate, climb, rest, capped, calm, failed }
  enum Light: Equatable { case journey, even, overcast }

  /// The animated picture values, each 0...1.
  struct Pose: Equatable {
    /// Across: the fill of the minimum journey; 1 once it is met or when there is none.
    var h: Double
    /// Up: 0 resting just above the ground, 0.5 halfway, 1 off the top edge.
    var v: Double

    /// A fall (a refund, a new period) crossfades instead of gliding backwards.
    func falls(from old: Pose) -> Bool { h < old.h || v < old.v }
  }

  /// Where the sun rests, as a share of the width.
  static let column = 0.85
  /// Where the sun can ride the marker.
  static let ride = 0.07...0.85

  var stage: Stage
  var pose: Pose
  var miles: Bool
  /// The minimum journey's sun is amber while the tone is needs-minimum.
  var needsMinimum: Bool
  /// Whether the card ever had a minimum journey: where a first showing starts.
  var hasMinimum: Bool
  /// Changes when the target does: another action kind, basis target or deadline end.
  var target: String

  var light: Light { stage == .failed ? .overcast : stage == .calm ? .even : .journey }
  var hasMarker: Bool { stage == .gate }
  var hasSun: Bool { stage != .failed }
  /// The marker's x as a share of the width: exactly the fill, in the minimum journey only.
  var markerX: Double? { stage == .gate ? pose.h : nil }
  /// The brand pair, apart at rest: no journey to show.
  var ridgesApart: Bool { stage == .failed || stage == .calm }

  /// Where a first showing starts: a card with a minimum sweeps across and then rises.
  var journeyStart: Pose {
    switch stage {
    case .gate: return Pose(h: 0, v: 0)
    case .climb, .rest, .capped: return Pose(h: hasMinimum ? 0 : 1, v: 0)
    case .calm, .failed: return pose
    }
  }

  /// Nil for range rows, which draw no picture.
  init?(_ p: RewardRowProjection) {
    let minimum = Self.amount(p.minimumAmount)
    let tier = Self.amount(p.reachedTierThreshold)
    switch p.action {
    case .range:
      return nil
    case .qualificationFailed:
      stage = .failed
      pose = Pose(h: 0, v: 0)
    case .monthlyMinimum, .minimum:
      stage = .gate
      pose = Pose(h: Self.clamp(p.fill ?? 0), v: 0)
    case .nextTier:
      stage = .climb
      // Once a tier is reached the sun stays at halfway: it never sinks towards a further tier.
      var v = tier > 0 ? 0.5 : 0
      if tier == 0, let spend = p.basis?.spend, let next = p.basis?.target {
        let from = minimum < next ? minimum : 0
        v = 0.5 * Self.ratio(spend - from, next - from)
      }
      pose = Pose(h: 1, v: v)
    case .capHeadroom:
      stage = .climb
      let base = tier > 0 ? 0.5 : 0
      var v = base
      if let counted = p.basis?.spend, let cap = p.basis?.target {
        let foot = tier > 0 ? tier : minimum
        let from = cap > foot ? foot : 0
        v = base + (1 - base) * Self.ratio(counted - from, cap - from)
      }
      pose = Pose(h: 1, v: v)
    case .capReached:
      // The partial block and the exceeded cap included: the picture follows the action.
      stage = .capped
      pose = Pose(h: 1, v: 1)
    case .topTier:
      stage = .rest
      pose = Pose(h: 1, v: 0.5)
    case .minimumMet:
      stage = .rest
      pose = Pose(h: 1, v: 0)
    case .noTarget:
      stage = .calm
      pose = Pose(h: 1, v: 0)
    }
    miles = p.rewardType == .miles
    needsMinimum = p.tone == .needsMinimum
    hasMinimum = minimum > 0
    target = "\(Self.kind(p.action))|\(p.basis?.target ?? 0)|\(p.deadline?.end ?? "")"
  }

  /// A plain amount: finite and positive, else 0.
  private static func amount(_ x: Double) -> Double { x.isFinite && x > 0 ? x : 0 }
  private static func clamp(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
  /// Progress over a span; a span that is not positive counts as complete.
  private static func ratio(_ x: Double, _ over: Double) -> Double { over > 0 ? clamp(x / over) : 1 }

  private static func kind(_ action: RewardRowProjection.Action) -> String {
    switch action {
    case .monthlyMinimum: return "monthly"
    case .minimum: return "minimum"
    case .nextTier: return "tier"
    case .capHeadroom, .capReached: return "cap"
    default: return "none"
    }
  }
}

/// Everything else the scene needs, derived from the pose and never stored.
extension RewardExposure.Pose {
  /// How far the sun has lifted clear of the horizon, over h 0.85 to 1.
  var lift: Double { min(1, max(0, (h - 0.85) / 0.15)) }
  /// The sun's x as a share of the width, riding the marker while the minimum journey runs.
  var sunX: Double { h >= 1 ? RewardExposure.column : min(max(h, RewardExposure.ride.lowerBound), RewardExposure.ride.upperBound) }
  /// The share of the full gap between the ridges that is left.
  var gap: Double { 1 - h }
  /// The sun's centre y for a target horizon at `horizon` and a disc of radius `r` (y points down).
  func sunY(horizon: Double, r: Double) -> Double {
    let sit = horizon + 0.08 * r
    let rest = horizon - 1.15 * r
    return h < 1 ? sit + (rest - sit) * lift : rest + (-1.05 * r - rest) * v
  }
}

/// Light mode draws daytime faces; dark mode draws the night and dusk prints.
enum FaceAppearance: Equatable { case daytime, print }

/// Where the scene sits in its row.
enum ExposureLayout: Equatable {
  /// A board row: the ridges follow the measured bottom of the name's line box and
  /// top of the headline, so long names and large text move the ridges rather than
  /// overlap them. Nil falls back to estimates until the first measurement.
  case strip(nameBottom: Double?, footTop: Double?)
  /// The 64pt scene band above the text at accessibility sizes.
  case band
}

/// The scene's geometry for one frame, in points. Pure: the Canvas draws it.
struct ExposureScene {
  let width: Double
  let height: Double
  let layout: ExposureLayout
  let exposure: RewardExposure
  let pose: RewardExposure.Pose
  let appearance: FaceAppearance

  /// The sun's radius.
  var sunRadius: Double {
    switch layout {
    case .strip: return 8
    case .band: return 6
    }
  }

  private var horizonBase: Double {
    switch layout {
    case .strip(let nameBottom, _): return (nameBottom ?? 0.31 * height) + 10
    case .band: return 0.52 * height
    }
  }

  private var floorBase: Double {
    switch layout {
    case .strip(_, let footTop): return (footTop ?? 0.54 * height) - 5
    case .band: return 0.80 * height
    }
  }

  private var wobble: Double {
    switch layout {
    case .strip: return 1
    case .band: return 0.01 * height
    }
  }

  /// The target horizon `U(x)` at `u`, a share of the width: level, give or take a little.
  func horizonY(at u: Double) -> Double { horizonBase + wobble * sin(u * 8.2 + 1.3) }

  /// The spend floor `Fl(x)`, never above the target horizon, so the two cannot cross.
  func floorY(at u: Double) -> Double { max(floorBase + wobble * sin(u * 8.2 + 0.4), horizonY(at: u)) }

  /// The spend horizon: a blend of the floor and the target horizon, lifting as `h` grows.
  /// Failed and untargeted cards draw the pair apart at rest.
  func spendY(at u: Double) -> Double {
    let h = exposure.ridgesApart ? 0 : pose.h
    let floor = floorY(at: u)
    return floor + h * (horizonY(at: u) - floor)
  }

  /// Both ridges are one: the minimum is met, so the spend horizon has met the target.
  var isMerged: Bool { !exposure.ridgesApart && pose.h >= 0.999 }

  /// The sun's centre, nil when there is none.
  var sun: (x: Double, y: Double)? {
    guard exposure.hasSun else { return nil }
    let u = pose.sunX
    return (u * width, pose.sunY(horizon: horizonY(at: u), r: sunRadius))
  }

  /// The rings' base radius `R`: grows with the climb, capped by the frame's height.
  var ringRadius: Double {
    min((0.14 + 0.24 * pose.v) * width, (0.42 + 0.6 * pose.v) * height)
  }

  var haloOpacity: Double { 0.4 + 0.6 * pose.v }

  /// The veil's soft edge, in points: full light to the left of `from`, full veil right of `to`.
  /// A failed card is veiled everywhere. Nil once there is no minimum journey to show.
  var veilEdge: (from: Double, to: Double)? {
    if exposure.stage == .failed { return (-0.08 * width, 0) }
    guard exposure.hasMarker else { return nil }
    return ((pose.h - 0.04) * width, (pose.h + 0.04) * width)
  }

  /// Light mode: the gold over the sky and the ground as peak alphas, or nil when there is none.
  var litAlpha: (sky: Double, ground: Double)? {
    guard appearance == .daytime else { return nil }
    switch exposure.light {
    case .overcast: return nil
    case .even: return (0.42, 0.16)
    case .journey: return (0.76 + 0.16 * pose.v, 0.24 + 0.12 * pose.v)
    }
  }

  /// Dark mode: the bloom's alpha over the sky.
  var bloomAlpha: Double {
    appearance == .print && exposure.light == .journey ? 0.3 * pose.v : 0
  }

  /// The pour from the top edge: its alpha and radius (in points). Fades in from `v` 0.4.
  var pour: (alpha: Double, radius: Double)? {
    guard exposure.hasSun, exposure.light == .journey else { return nil }
    let night = appearance == .print && exposure.miles
    let peak = appearance == .print && !exposure.miles ? 0.55 : 0.65
    let alpha = peak * min(1, max(0, (pose.v - 0.4) / 0.6))
    guard alpha > 0 else { return nil }
    return (alpha, (night ? 0.35 : 0.62) * width)
  }

  /// Rings and glow add light by screen blend, except on the dusk print.
  var glowScreens: Bool { appearance == .daytime || exposure.miles }

  /// One piece of the marker's hairline.
  struct MarkerSegment: Equatable {
    var y0: Double
    var y1: Double
    /// Above the target horizon: dark mode tints the sky part and the ridge part differently.
    var onSky: Bool
  }

  /// The marker's x in points, snapped to the device pixel grid so its two-pixel line stays crisp.
  func markerX(scale: Double) -> Double? {
    guard let x = exposure.markerX, scale > 0 else { return nil }
    return (x * width * scale).rounded() / scale
  }

  /// The marker runs from 0.06 of the height to the bottom edge and breaks across the sun's disc,
  /// as in the brand mark. Dark mode also splits it at the target horizon.
  var markerSegments: [MarkerSegment] {
    guard let x = exposure.markerX else { return [] }
    let top = 0.06 * height
    var pieces: [(Double, Double)] = [(top, height)]
    if let sun, abs(x * width - sun.x) < sunRadius + 0.004 * width {
      let clear = 0.003 * width
      let lo = sun.y - sunRadius - clear
      let hi = sun.y + sunRadius + clear
      pieces = [(top, min(height, lo)), (max(top, hi), height)].filter { $0.1 > $0.0 }
    }
    let split = horizonY(at: x)
    var segments: [MarkerSegment] = []
    for (y0, y1) in pieces {
      if y0 < split, y1 > split {
        segments.append(MarkerSegment(y0: y0, y1: split, onSky: true))
        segments.append(MarkerSegment(y0: split, y1: y1, onSky: false))
      } else {
        segments.append(MarkerSegment(y0: y0, y1: y1, onSky: y1 <= split))
      }
    }
    return segments
  }
}
