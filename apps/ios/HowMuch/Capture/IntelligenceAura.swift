import SwiftUI

/// Apple Intelligence-style wait: a slow mesh wash and a breathing glow.
/// No sparkles, no badge. Honours Reduce Motion with a still mesh.
struct IntelligenceAura: View {
  var intensity: Double = 1

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if reduceMotion {
        mesh(at: 0)
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
          mesh(at: timeline.date.timeIntervalSinceReferenceDate)
        }
      }
    }
    .opacity(intensity)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func mesh(at time: TimeInterval) -> some View {
    let t = time * 0.35
    return ZStack {
      MeshGradient(
        width: 3,
        height: 3,
        points: points(at: t),
        colors: colors(at: t)
      )
      RadialGradient(
        colors: [
          Color.white.opacity(colorScheme == .dark ? 0.08 : 0.22),
          Color.clear,
        ],
        center: .center,
        startRadius: 20,
        endRadius: 280
      )
      .scaleEffect(reduceMotion ? 1 : 1 + 0.06 * sin(time * 0.9))
    }
  }

  private func points(at t: TimeInterval) -> [SIMD2<Float>] {
    let a = Float(sin(t)) * 0.10
    let b = Float(cos(t * 0.85)) * 0.10
    let c = Float(sin(t * 1.15 + 1.2)) * 0.08
    return [
      SIMD2(0, 0), SIMD2(clamp(0.5 + a * 0.4), 0), SIMD2(1, 0),
      SIMD2(0, clamp(0.5 + b * 0.5)), SIMD2(clamp(0.5 + a), clamp(0.5 + b)), SIMD2(1, clamp(0.5 + c)),
      SIMD2(0, 1), SIMD2(clamp(0.5 + c * 0.4), 1), SIMD2(1, 1),
    ]
  }

  private func clamp(_ value: Float) -> Float {
    min(1, max(0, value))
  }

  private func colors(at t: TimeInterval) -> [Color] {
    let shift = t * 0.22
    return (0..<9).map { index in
      palette(at: Double(index) / 8.0 + shift)
    }
  }

  private func palette(at phase: Double) -> Color {
    let p = phase - floor(phase)
    let stops: [(Double, Color)] = colorScheme == .dark ? Self.darkStops : Self.lightStops
    var lower = stops[0]
    var upper = stops[1]
    for index in 0..<(stops.count - 1) {
      if p >= stops[index].0 && p <= stops[index + 1].0 {
        lower = stops[index]
        upper = stops[index + 1]
        break
      }
    }
    let span = max(upper.0 - lower.0, 0.0001)
    let local = (p - lower.0) / span
    return lower.1.mix(with: upper.1, by: local)
  }

  /// Siri-adjacent wash on HowMuch cream: pink, blurple, cyan, peach.
  private static let lightStops: [(Double, Color)] = [
    (0.00, Color(red: 0.98, green: 0.62, blue: 0.78)),
    (0.18, Color(red: 0.55, green: 0.48, blue: 0.96)),
    (0.38, Color(red: 0.45, green: 0.82, blue: 0.96)),
    (0.55, Color(red: 0.99, green: 0.78, blue: 0.55)),
    (0.72, Color(red: 0.78, green: 0.70, blue: 0.98)),
    (0.88, Color(red: 0.98, green: 0.55, blue: 0.70)),
    (1.00, Color(red: 0.98, green: 0.62, blue: 0.78)),
  ]

  private static let darkStops: [(Double, Color)] = [
    (0.00, Color(red: 0.62, green: 0.22, blue: 0.48)),
    (0.18, Color(red: 0.28, green: 0.24, blue: 0.72)),
    (0.38, Color(red: 0.12, green: 0.48, blue: 0.62)),
    (0.55, Color(red: 0.72, green: 0.42, blue: 0.22)),
    (0.72, Color(red: 0.38, green: 0.28, blue: 0.68)),
    (0.88, Color(red: 0.58, green: 0.20, blue: 0.42)),
    (1.00, Color(red: 0.62, green: 0.22, blue: 0.48)),
  ]
}

private extension Color {
  func mix(with other: Color, by amount: Double) -> Color {
    let t = CGFloat(min(max(amount, 0), 1))
    let from = UIColor(self)
    let to = UIColor(other)
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    from.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    to.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return Color(
      red: Double(r1 + (r2 - r1) * t),
      green: Double(g1 + (g2 - g1) * t),
      blue: Double(b1 + (b2 - b1) * t),
      opacity: Double(a1 + (a2 - a1) * t)
    )
  }
}

struct IntelligenceHalo: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
      let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
      AngularGradient(
        colors: [
          Color(red: 0.98, green: 0.48, blue: 0.72),
          Color(red: 0.45, green: 0.38, blue: 0.95),
          Color(red: 0.40, green: 0.82, blue: 0.96),
          Color(red: 0.99, green: 0.70, blue: 0.48),
          Color(red: 0.98, green: 0.48, blue: 0.72),
        ],
        center: .center,
        angle: .degrees(t * 24)
      )
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
