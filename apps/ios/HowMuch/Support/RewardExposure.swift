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
  /// `seat` is how far below the horizon the centre sits while the sun rides it, as a share of `r`:
  /// a hair below on the hero, and exactly on it on the phone strip, where the disc is a clean half-sun.
  func sunY(horizon: Double, r: Double, seat: Double = 0.08) -> Double {
    let sit = horizon + seat * r
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

/// The brand ridges' rise (the app icon's two slopes), sampled at 65 even x from the web's shipped
/// paths (`reward-exposure-scene.ts` BACK_RISE) and kept in step with them: 1 at the
/// left edge, where the ridge is lowest, and 0 at the right, where it is highest. The phone's
/// horizons take this shape.
enum BrandRise {
  static let back: [Double] = [1, 0.989, 0.977, 0.964, 0.95, 0.935, 0.92, 0.905, 0.889, 0.874, 0.859, 0.845, 0.833, 0.822, 0.813, 0.806, 0.801, 0.799, 0.8, 0.803, 0.801, 0.795, 0.783, 0.766, 0.744, 0.719, 0.69, 0.659, 0.627, 0.596, 0.567, 0.539, 0.515, 0.494, 0.476, 0.462, 0.448, 0.433, 0.416, 0.399, 0.38, 0.361, 0.341, 0.321, 0.3, 0.28, 0.259, 0.24, 0.22, 0.201, 0.183, 0.166, 0.151, 0.138, 0.127, 0.119, 0.111, 0.104, 0.097, 0.089, 0.08, 0.067, 0.05, 0.028, 0]

  /// The rise at `u`, a share of the width, interpolated between samples.
  static func at(_ table: [Double], _ u: Double) -> Double {
    let f = min(1, max(0, u)) * Double(table.count - 1)
    let i = min(table.count - 2, Int(f))
    return table[i] + (table[i + 1] - table[i]) * (f - Double(i))
  }
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
    case .strip: return 10
    case .band: return 7
    }
  }

  /// The target horizon's range: the brand back ridge's rise, from `low` at the left edge to
  /// `high` at the right, where the sun's column is. On the strip it runs from 14pt under the
  /// name to 2pt under it.
  private var horizonRange: (high: Double, low: Double) {
    switch layout {
    case .strip(let nameBottom, _):
      let name = nameBottom ?? 0.28 * height
      return (name + 2, name + 14)
    case .band: return (0.42 * height, 0.56 * height)
    }
  }

  /// How far below the target horizon the spend floor runs: the floor is the horizon's own shape, as far
  /// down as the words allow (3pt above the foot at its lowest, the left edge), so the two slopes start
  /// equidistant and converge as the minimum fills.
  private var floorGap: Double {
    switch layout {
    case .strip(_, let footTop):
      let foot = footTop ?? 0.58 * height
      return max(4, foot - 3 - horizonRange.low)
    case .band: return 0.26 * height
    }
  }

  /// The target horizon `U(x)` at `u`, a share of the width: the icon's back slope.
  func horizonY(at u: Double) -> Double {
    let range = horizonRange
    return range.high + (range.low - range.high) * BrandRise.at(BrandRise.back, u)
  }

  /// The spend floor `Fl(x)`: the target horizon's shape, `floorGap` below it.
  func floorY(at u: Double) -> Double { horizonY(at: u) + floorGap }

  /// How far the spend horizon has lifted: the fill of the minimum journey. Failed and untargeted
  /// cards, and cards with no minimum, keep the pair apart: the convergence is the minimum's own read.
  private var across: Double { exposure.ridgesApart || !exposure.hasMinimum ? 0 : pose.h }

  /// The spend horizon: a blend of the floor and the target horizon, lifting as `h` grows.
  func spendY(at u: Double) -> Double {
    let floor = floorY(at: u)
    return floor + across * (horizonY(at: u) - floor)
  }

  /// Both ridges are one: the minimum is met, so the spend horizon has met the target.
  var isMerged: Bool { across >= 0.999 }

  /// The sun's centre, nil when there is none. On the phone it sits exactly on the horizon, a clean
  /// half-sun, and lifts clear from there.
  var sun: (x: Double, y: Double)? {
    guard exposure.hasSun else { return nil }
    let u = pose.sunX
    return (u * width, pose.sunY(horizon: horizonY(at: u), r: sunRadius, seat: 0))
  }

  /// The glow's radius `R`: grows with the climb, capped by the frame's height. The phone draws one
  /// smooth falloff rather than the posterised rings, which a short frame clips into arcs.
  var ringRadius: Double {
    min((0.14 + 0.24 * pose.v) * width, (0.42 + 0.6 * pose.v) * height)
  }

  /// How far the sun has lifted clear of the horizon. The phone has no room for a hairline marker or
  /// an unlit sliver at the edge, so the last of the band lights as the sun lifts.
  var lifted: Double { pose.lift }

  var haloOpacity: Double { 0.4 + 0.6 * pose.v }

  /// The light is still spreading towards the marker. This follows the animated pose, not
  /// the stage, so when the minimum is met the lit edge sweeps to the right edge and the
  /// marker goes with it, instead of the whole band lighting at once.
  var inMinimumJourney: Bool { exposure.light == .journey && pose.h < 0.999 }

  /// The veil's soft edge, in points: full light to the left of `from`, full veil right of `to`.
  /// A failed card is veiled everywhere. Nil once there is no minimum journey to show.
  var veilEdge: (from: Double, to: Double)? {
    if exposure.stage == .failed { return (-0.08 * width, 0) }
    guard inMinimumJourney else { return nil }
    return ((pose.h - 0.04) * width, (pose.h + 0.04) * width)
  }

  /// The veil's peak, 0 to 1: full while the sun rides, fading as it lifts; a failed card keeps it.
  var veilStrength: Double { exposure.stage == .failed ? 1 : 1 - lifted }

  /// Light mode: the gold over the sky and the ground as peak alphas, or nil when there is none.
  var litAlpha: (sky: Double, ground: Double)? {
    guard appearance == .daytime else { return nil }
    switch exposure.light {
    case .overcast: return nil
    case .even: return (0.3, 0.12)
    case .journey: return (0.5 + 0.12 * pose.v, 0.16 + 0.08 * pose.v)
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
}
