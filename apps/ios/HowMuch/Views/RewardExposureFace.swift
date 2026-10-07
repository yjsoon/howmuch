import SwiftUI

// The Rewards Exposure card's picture: a sky, a pair of ridges and a sun, drawn
// in one Canvas pass. The geometry is `ExposureScene` (Support/RewardExposure.swift);
// the rules are in docs/frontend/rewards-exposure-card.md.

extension Theme {
  /// Colours of the Exposure card, from the namespaced `Face` folder in the asset
  /// catalogue. Each set holds its light-mode value (Any), its dark-mode value
  /// (Dark) and, where listed, an Increase Contrast pair, so no colour is chosen
  /// with an `if`. A `Canvas` resolves them in its own environment, which is why
  /// they are `Color` values and never `UIColor(named:)`.
  enum Face {
    private static func named(_ name: String) -> Color { Color("Face/\(name)") }

    static let skyCashback = [named("SkyCashback1"), named("SkyCashback2"), named("SkyCashback3")]
    static let skyMiles = [named("SkyMiles1"), named("SkyMiles2"), named("SkyMiles3")]
    static let skyOvercast = [named("SkyOvercast1"), named("SkyOvercast2"), named("SkyOvercast3")]
    static let skyLit = named("SkyLit")
    static let contrail = named("Contrail")

    static let inkCashback = named("InkCashback")
    static let inkMiles = named("InkMiles")
    static let footInk = named("FootInk")
    static let footInkSoft = named("FootInkSoft")
    static let urgentInk = named("UrgentInk")
    static let failedInk = named("FailedInk")

    static let ridgeBack = named("RidgeBack")
    static let ridgeFront = named("RidgeFront")
    static let crest = named("Crest")

    static let sunDiscTop = named("SunDiscTop")
    static let sunDiscBottom = named("SunDiscBottom")
    static let sunRiseTop = named("SunRiseTop")
    static let sunRiseBottom = named("SunRiseBottom")
    static let sunRim = named("SunRim")
    static let sunCore = named("SunCore")
    /// Inner to outer.
    static let rings = [named("Ring1"), named("Ring2"), named("Ring3"), named("Ring4")]
    static let horizon = named("Horizon")

    static let veilDim = named("VeilDim")
    static let veilGrey = named("VeilGrey")
    static let veilCashback = named("VeilCashback")
    static let veilMiles = named("VeilMiles")
    static let bloom = named("Bloom")

    static let markerCashback = named("MarkerCashback")
    static let markerMiles = named("MarkerMiles")
    static let markerRidge = named("MarkerRidge")
    static let markerEdge = named("MarkerEdge")
  }
}

/// One Canvas, no `Shape` views: a list row needs about ten layers and a Canvas
/// draws them in one immediate-mode pass, kept until its inputs change.
///
/// The pose is the only animated input: `h` and `v` interpolate through
/// `animatableData`, and the scene recomputes the sun, the light, the ridges and
/// the marker from them each frame. Every word on the card is a real `Text`
/// outside the Canvas, so Dynamic Type, Bold Text, VoiceOver and OCR keep working.
struct RewardExposureFace: View, Animatable, Equatable {
  var exposure: RewardExposure
  var layout: ExposureLayout
  /// Animated; `exposure.pose` at rest.
  var pose: RewardExposure.Pose
  var appearance: FaceAppearance

  @Environment(\.displayScale) private var displayScale
  @Environment(\.colorSchemeContrast) private var contrast

  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(pose.h, pose.v) }
    set { pose = RewardExposure.Pose(h: newValue.first, v: newValue.second) }
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.exposure == rhs.exposure && lhs.layout == rhs.layout && lhs.pose == rhs.pose
      && lhs.appearance == rhs.appearance
  }

  var body: some View {
    Canvas { context, size in
      let scene = ExposureScene(
        width: size.width, height: size.height, layout: layout, exposure: exposure, pose: pose,
        appearance: appearance)
      ExposurePainter(scene: scene, increasedContrast: contrast == .increased, scale: displayScale)
        .paint(in: &context)
    }
    .accessibilityHidden(true)
    .accessibilityIgnoresInvertColors(true)
  }
}

/// Draws one frame of the scene, back to front: sky and horizon warmth, the
/// contrail and the light (gold by day, bloom by night), the pour from the top
/// edge, the halo, the two ridges, the ground's gold, the veil, the sun and the
/// marker. Text is never inside the scene.
private struct ExposurePainter {
  let scene: ExposureScene
  let increasedContrast: Bool
  let scale: Double

  private var exposure: RewardExposure { scene.exposure }
  private var pose: RewardExposure.Pose { scene.pose }
  private var width: Double { scene.width }
  private var height: Double { scene.height }
  private var daytime: Bool { scene.appearance == .daytime }
  private var frame: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
  private let samples = 48

  func paint(in context: inout GraphicsContext) {
    if exposure.stage == .failed { context.addFilter(.saturation(0.15)) }
    drawSky(in: &context)
    drawLight(in: &context)
    drawPour(in: &context)
    drawHalo(in: &context)
    drawRidges(in: &context)
    drawGround(in: &context)
    drawVeil(in: &context)
    drawSun(in: &context)
    drawMarker(in: &context)
  }

  // MARK: Paths

  private func line(_ y: (Double) -> Double) -> Path {
    var path = Path()
    for step in 0...samples {
      let u = Double(step) / Double(samples)
      let point = CGPoint(x: u * width, y: y(u))
      if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
  }

  /// Everything below the line.
  private func below(_ y: (Double) -> Double) -> Path {
    var path = line(y)
    path.addLine(to: CGPoint(x: width, y: height))
    path.addLine(to: CGPoint(x: 0, y: height))
    path.closeSubpath()
    return path
  }

  /// Everything above the line.
  private func above(_ y: (Double) -> Double) -> Path {
    var path = line(y)
    path.addLine(to: CGPoint(x: width, y: 0))
    path.addLine(to: CGPoint(x: 0, y: 0))
    path.closeSubpath()
    return path
  }

  // MARK: Sky

  private var skyColours: [Color] {
    if daytime, exposure.stage == .failed { return Theme.Face.skyOvercast }
    return exposure.miles ? Theme.Face.skyMiles : Theme.Face.skyCashback
  }

  private func drawSky(in context: inout GraphicsContext) {
    // 165 degrees, as the web's CSS gradient: down and a little to the right.
    let angle = 165.0 * .pi / 180
    let dx = sin(angle), dy = -cos(angle)
    let half = (abs(width * sin(angle)) + abs(height * cos(angle))) / 2
    let start = CGPoint(x: width / 2 - dx * half, y: height / 2 - dy * half)
    let end = CGPoint(x: width / 2 + dx * half, y: height / 2 + dy * half)
    let colours = skyColours
    let gradient = Gradient(stops: [
      .init(color: colours[0], location: 0), .init(color: colours[1], location: 0.48),
      .init(color: colours[2], location: 1),
    ])
    context.fill(Path(frame), with: .linearGradient(gradient, startPoint: start, endPoint: end))

    // Horizon warmth, rising from the bottom edge. It grows with the climb in dark mode.
    let warmth = Gradient(stops: [
      .init(color: Theme.Face.horizon, location: 0), .init(color: Theme.Face.horizon, location: 0.45),
      .init(color: Theme.Face.horizon.opacity(0), location: 0.8),
    ])
    let up = GraphicsContext.Shading.linearGradient(
      warmth, startPoint: CGPoint(x: 0, y: height), endPoint: CGPoint(x: 0, y: 0))
    context.fill(Path(frame), with: up)
    if !daytime, pose.v > 0 {
      var more = context
      more.opacity = 0.5 * pose.v
      more.fill(Path(frame), with: up)
    }
  }

  // MARK: Light

  /// A wash of `colour` across the whole frame: to the marker in the minimum
  /// journey, with the soft falloff, and end to end from then on.
  private func wash(_ colour: Color, alpha: Double) -> GraphicsContext.Shading {
    let solid = colour.opacity(alpha)
    guard exposure.stage == .gate else {
      return .color(solid)
    }
    // The wash falls to the same colour at zero alpha, never to clear, so the falloff does not pass through grey.
    let lo = min(1, max(0, pose.h - 0.04))
    let hi = min(1, max(0, pose.h + 0.04))
    let gradient = Gradient(stops: [
      .init(color: solid, location: 0), .init(color: solid, location: lo),
      .init(color: colour.opacity(0), location: hi), .init(color: colour.opacity(0), location: 1),
    ])
    return .linearGradient(gradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: width, y: 0))
  }

  private func drawLight(in context: inout GraphicsContext) {
    if daytime {
      // The contrail first, so the gold is laid over it and it shows only on the blue.
      if exposure.miles, exposure.stage != .failed { drawContrail(in: &context) }
      if let alpha = scene.litAlpha?.sky {
        context.fill(Path(frame), with: wash(Theme.Face.skyLit, alpha: alpha))
      }
    } else if scene.bloomAlpha > 0 {
      var bloom = context
      bloom.blendMode = exposure.miles ? .screen : .normal
      bloom.fill(Path(frame), with: .color(Theme.Face.bloom.opacity(scene.bloomAlpha)))
    }
  }

  /// Two short parallel hairlines high in the right of the sky, brightest over their middle.
  private func drawContrail(in context: inout GraphicsContext) {
    let x0 = 0.50 * width, x1 = 0.76 * width
    let ceiling = scene.horizonY(at: 0.6) - 4
    let y0 = min(0.30 * height, ceiling), y1 = min(0.20 * height, ceiling)
    let gap = 0.007 * width
    let gradient = Gradient(stops: [
      .init(color: Theme.Face.contrail.opacity(0), location: 0), .init(color: Theme.Face.contrail, location: 0.35),
      .init(color: Theme.Face.contrail, location: 0.7), .init(color: Theme.Face.contrail.opacity(0), location: 1),
    ])
    let shading = GraphicsContext.Shading.linearGradient(
      gradient, startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0))
    for offset in [0.0, gap] {
      var path = Path()
      path.move(to: CGPoint(x: x0, y: y0 + offset))
      path.addLine(to: CGPoint(x: x1, y: y1 + offset))
      context.stroke(path, with: shading, style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
    }
  }

  /// The glow pouring down from a sun that has left the frame, centred on its column at the top edge.
  private func drawPour(in context: inout GraphicsContext) {
    guard let pour = scene.pour else { return }
    var glow = context
    glow.opacity = pour.alpha
    glow.blendMode = scene.glowScreens ? .screen : .normal
    let gradient = Gradient(stops: [
      .init(color: Theme.Face.sunDiscTop, location: 0), .init(color: Theme.Face.sunCore, location: 0.3),
      .init(color: Theme.Face.sunCore.opacity(0), location: 1),
    ])
    glow.fill(
      Path(frame),
      with: .radialGradient(
        gradient, center: CGPoint(x: RewardExposure.column * width, y: 0), startRadius: 0, endRadius: pour.radius))
  }

  // MARK: Halo

  private func drawHalo(in context: inout GraphicsContext) {
    guard let sun = scene.sun else { return }
    var halo = context
    halo.opacity = scene.haloOpacity
    halo.blendMode = scene.glowScreens ? .screen : .normal
    let base = scene.ringRadius
    // Largest first, so each step reads as posterised light rather than a drawn line.
    let rings: [(Double, Color)] = [
      (0.92, Theme.Face.rings[3]), (0.68, Theme.Face.rings[2]), (0.46, Theme.Face.rings[1]),
      (0.27, Theme.Face.rings[0]), (0.15, Theme.Face.sunCore),
    ]
    for (share, colour) in rings {
      let radius = base * share
      halo.fill(
        Path(ellipseIn: CGRect(x: sun.x - radius, y: sun.y - radius, width: 2 * radius, height: 2 * radius)),
        with: .color(colour))
    }
  }

  // MARK: Ridges

  private func drawRidges(in context: inout GraphicsContext) {
    let target = { (u: Double) in scene.horizonY(at: u) }
    let spend = { (u: Double) in scene.spendY(at: u) }
    context.fill(below(target), with: .color(Theme.Face.ridgeBack))
    if !scene.isMerged, !exposure.ridgesApart {
      context.stroke(
        line(target), with: .color(Theme.Face.crest.opacity(increasedContrast ? 0.7 : 0.4)), lineWidth: 1)
    }
    context.fill(below(spend), with: .color(Theme.Face.ridgeFront))
    let crest: Double
    if increasedContrast {
      crest = 1
    } else if scene.isMerged {
      crest = 0.9 + 0.1 * pose.v
    } else {
      crest = 0.75
    }
    context.stroke(line(spend), with: .color(Theme.Face.crest.opacity(crest)), lineWidth: 1.5)
  }

  /// Light mode: the ground is sunlit to the marker. Dark mode, strip only: a scrim
  /// keeps light ink off a light sky wherever the foot ends up.
  private func drawGround(in context: inout GraphicsContext) {
    if daytime {
      guard let alpha = scene.litAlpha?.ground else { return }
      var ground = context
      ground.clip(to: below { scene.horizonY(at: $0) })
      ground.fill(Path(frame), with: wash(Theme.Face.skyLit, alpha: alpha))
    } else if case .strip(_, let footTop) = scene.layout {
      let top = (footTop ?? 0.54 * height) - 8
      let scrim = Gradient(colors: [Theme.Face.ridgeFront.opacity(0), Theme.Face.ridgeFront.opacity(0.55)])
      context.fill(
        Path(CGRect(x: 0, y: top, width: width, height: max(0, height - top))),
        with: .linearGradient(
          scrim, startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: top + 12)))
    }
  }

  // MARK: Veil

  /// Underexposes the art right of the marker in the minimum journey, and everything when failed.
  private func drawVeil(in context: inout GraphicsContext) {
    guard let edge = scene.veilEdge else { return }
    let failed = exposure.stage == .failed
    let from = CGPoint(x: edge.from, y: 0), to = CGPoint(x: edge.to, y: 0)
    var veil = context
    switch scene.appearance {
    case .print:
      // Half way to grey, then a dusk cast taken from the brand's rose-mauve.
      veil.blendMode = .saturation
      veil.fill(
        Path(frame),
        with: .linearGradient(
          Gradient(colors: [Theme.Face.veilGrey.opacity(0), Theme.Face.veilGrey.opacity(0.5)]),
          startPoint: from, endPoint: to))
      veil.blendMode = .multiply
      let cast = exposure.miles ? Theme.Face.veilMiles : Theme.Face.veilCashback
      veil.fill(
        Path(frame),
        with: .linearGradient(Gradient(colors: [.white, cast]), startPoint: from, endPoint: to))
    case .daytime:
      // A cool dim that never darkens enough to break a floor.
      let alpha = failed ? 0.14 : 0.15
      veil.fill(
        Path(frame),
        with: .linearGradient(
          Gradient(colors: [Theme.Face.veilDim.opacity(0), Theme.Face.veilDim.opacity(alpha)]),
          startPoint: from, endPoint: to))
    }
  }

  // MARK: Sun

  /// The disc is clipped to the sky, so it sits behind the target horizon until it
  /// climbs clear, and it is drawn after the veil so it is never dimmed.
  private func drawSun(in context: inout GraphicsContext) {
    guard let sun = scene.sun else { return }
    var sky = context
    sky.clip(to: above { scene.horizonY(at: $0) })
    let r = scene.sunRadius
    let disc = Path(ellipseIn: CGRect(x: sun.x - r, y: sun.y - r, width: 2 * r, height: 2 * r))
    let colours = exposure.needsMinimum
      ? [Theme.Face.sunRiseTop, Theme.Face.sunRiseBottom] : [Theme.Face.sunDiscTop, Theme.Face.sunDiscBottom]
    sky.fill(
      disc,
      with: .linearGradient(
        Gradient(colors: colours), startPoint: CGPoint(x: sun.x, y: sun.y - r), endPoint: CGPoint(x: sun.x, y: sun.y + r)))
    sky.stroke(disc, with: .color(Theme.Face.sunRim.opacity(0.6)), lineWidth: max(0.75, 0.003 * width))
  }

  // MARK: Marker

  /// The brand mark's hairline at exactly `h × W`: two device pixels wide and snapped to the pixel grid.
  private func drawMarker(in context: inout GraphicsContext) {
    guard let x = scene.markerX(scale: scale) else { return }
    let pixel = 1 / max(scale, 1)
    for segment in scene.markerSegments {
      var path = Path()
      path.move(to: CGPoint(x: x, y: segment.y0))
      path.addLine(to: CGPoint(x: x, y: segment.y1))
      if daytime {
        // A faint dark edge, one device pixel either side, so the one warm white line reads on gold and on blue.
        context.stroke(path, with: .color(Theme.Face.markerEdge), lineWidth: 4 * pixel)
      }
      let tone: Color
      if segment.onSky {
        tone = exposure.miles ? Theme.Face.markerMiles : Theme.Face.markerCashback
      } else {
        tone = Theme.Face.markerRidge
      }
      context.stroke(path, with: .color(tone), lineWidth: 2 * pixel)
    }
  }
}

// MARK: - Motion

/// The last pose shown per card, for this session only. A lazy `List` creates rows
/// again as they scroll, so `onAppear` alone would replay the rise: a row that
/// appears starts from the remembered pose when its target is the same.
@MainActor
final class ExposureMemory {
  static let shared = ExposureMemory()

  private var shown: [String: (target: String, pose: RewardExposure.Pose)] = [:]

  /// Where a row starts: its journey's start the first time, the remembered pose when the
  /// target is unchanged, and in place when the target changed while the row was off screen.
  func startPose(for key: String, exposure: RewardExposure) -> RewardExposure.Pose {
    guard let last = shown[key] else { return exposure.journeyStart }
    return last.target == exposure.target ? last.pose : exposure.pose
  }

  func remember(_ exposure: RewardExposure, key: String) {
    shown[key] = (exposure.target, exposure.pose)
  }
}

/// Moves a face from where it was to where it is. Only the pose animates.
///
/// - First shown: the lit edge sweeps right and the sun rides the marker; a card with a
///   minimum sweeps first and then rises, and one without it climbs straight up.
/// - New figures, same target: the pose glides. Across in the minimum journey, up in the climb.
/// - A fall (a new period or month) or a change of light: the face crossfades. The marker
///   never glides backwards and the sun never sinks.
/// - Reduce Motion: the pose jumps.
@MainActor
struct RewardExposureAnimator: View {
  let exposure: RewardExposure
  let layout: ExposureLayout
  /// Scope and card, so the same card shown in two places remembers each separately.
  let key: String
  var index = 0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @State private var shown: RewardExposure.Pose
  /// Changes only when a target change falls or relights.
  @State private var faceID: String
  @State private var glideTask: Task<Void, Never>?

  init(exposure: RewardExposure, layout: ExposureLayout, key: String, index: Int = 0) {
    self.exposure = exposure
    self.layout = layout
    self.key = key
    self.index = index
    _shown = State(initialValue: ExposureMemory.shared.startPose(for: key, exposure: exposure))
    _faceID = State(initialValue: exposure.target)
  }

  var body: some View {
    RewardExposureFace(
      exposure: exposure, layout: layout, pose: reduceMotion ? exposure.pose : shown,
      appearance: colorScheme == .dark ? .print : .daytime
    )
    .equatable()
    .id(faceID)
    .transition(.opacity)
    .onAppear {
      ExposureMemory.shared.remember(exposure, key: key)
      glide(to: exposure.pose, after: Double(min(index, 12)) * 0.028)
    }
    .onChange(of: exposure) { old, new in
      ExposureMemory.shared.remember(new, key: key)
      if new.target != old.target, new.pose.falls(from: old.pose) || new.light != old.light {
        glideTask?.cancel()
        withAnimation(reduceMotion ? nil : Theme.Motion.standard) {
          faceID = new.target
          shown = new.pose
        }
      } else {
        glide(to: new.pose, after: 0)
      }
    }
    .onDisappear { glideTask?.cancel() }
  }

  private func glide(to target: RewardExposure.Pose, after delay: Double) {
    glideTask?.cancel()
    let from = shown
    guard !reduceMotion, from != target else {
      shown = target
      return
    }
    if target.h > from.h + 1e-6, target.v > from.v + 1e-6 {
      // The light sweeps in the first 40% of the glide and the sun rises in the rest, so
      // the sun never moves diagonally. Two writes in one transaction would be merged,
      // so the second waits for the first.
      let sweep = 0.6 * 0.4
      withAnimation(Animation.smooth(duration: sweep).delay(delay)) {
        shown = RewardExposure.Pose(h: target.h, v: from.v)
      }
      glideTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(delay + sweep))
        guard !Task.isCancelled else { return }
        withAnimation(.smooth(duration: 0.6 - sweep)) { shown = target }
      }
    } else {
      withAnimation(Theme.Motion.chart.delay(delay)) { shown = target }
    }
  }
}
