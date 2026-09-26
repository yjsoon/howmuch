import SwiftUI
import UIKit

/// YNAB-inspired palette: warm cream canvas, white cards, blurple accent,
/// lime inflow highlight, ledger red/green for amounts. Dark variants keep the
/// same hues on a deep navy canvas.
enum Theme {
  static let canvas = Color(
    light: Color(red: 0.949, green: 0.937, blue: 0.902),
    dark: Color(red: 0.051, green: 0.063, blue: 0.122)
  )

  static let card = Color(
    light: .white,
    dark: Color(red: 0.106, green: 0.125, blue: 0.208)
  )

  /// Muted surface for keypads, search fields and memo chips.
  static let surfaceMuted = Color(
    light: Color(red: 0.910, green: 0.898, blue: 0.859),
    dark: Color(red: 0.157, green: 0.180, blue: 0.275)
  )

  static let accent = Color(
    light: Color(red: 0.357, green: 0.353, blue: 0.937),
    dark: Color(red: 0.541, green: 0.553, blue: 0.973)
  )

  static let newStatus = accent

  static let textPrimary = Color(
    light: Color(red: 0.106, green: 0.125, blue: 0.227),
    dark: Color(red: 0.922, green: 0.933, blue: 0.961)
  )

  static let outflow = Color(
    light: Color(red: 0.780, green: 0.196, blue: 0.165),
    dark: Color(red: 0.886, green: 0.447, blue: 0.404)
  )

  static let inflow = Color(
    light: Color(red: 0.133, green: 0.545, blue: 0.341),
    dark: Color(red: 0.420, green: 0.780, blue: 0.549)
  )

  /// Uncategorised register detail, tuned for the cream canvas.
  static let uncategorised = Color(
    light: Color(red: 0.690, green: 0.400, blue: 0.110),
    dark: Color(red: 0.945, green: 0.710, blue: 0.400)
  )

  /// System red for destructive swipe and cancellation actions.
  /// The app-wide accent would otherwise recast `role: .destructive` as blurple.
  static let cancellation = Color.red

  /// Lime header behind the amount when entering an inflow.
  static let lime = Color(
    light: Color(red: 0.847, green: 0.949, blue: 0.490),
    dark: Color(red: 0.337, green: 0.420, blue: 0.137)
  )

  /// Deeper lime for the segmented control track on a lime header.
  static let limeDeep = Color(
    light: Color(red: 0.737, green: 0.871, blue: 0.337),
    dark: Color(red: 0.255, green: 0.325, blue: 0.098)
  )

  /// Dot and bar colours for report breakdowns, cycled by index.
  static let chartPalette: [Color] = [
    Color(red: 0.357, green: 0.353, blue: 0.937),
    Color(red: 0.478, green: 0.780, blue: 0.255),
    Color(red: 0.949, green: 0.780, blue: 0.184),
    Color(red: 0.847, green: 0.286, blue: 0.251),
    Color(red: 0.690, green: 0.678, blue: 0.973),
    Color(red: 0.184, green: 0.671, blue: 0.659),
    Color(red: 0.945, green: 0.557, blue: 0.227),
    Color(red: 0.871, green: 0.467, blue: 0.682),
  ]

  static func chartColour(_ index: Int) -> Color {
    chartPalette[index % chartPalette.count]
  }

  /// Register amounts: inflows green, outflows in body text like YNAB.
  static func registerAmountColour(_ milliunits: Int) -> Color {
    milliunits > 0 ? inflow : textPrimary
  }

  /// Balances and report amounts: green positive, red negative.
  static func amountColour(_ milliunits: Int) -> Color {
    milliunits < 0 ? outflow : inflow
  }

  static func flagColour(named name: String?) -> Color? {
    switch name {
    case "red": .red
    case "orange": .orange
    case "yellow": .yellow
    case "green": .green
    case "blue": .blue
    case "purple": .purple
    default: nil
    }
  }
}

/// Rewards row tones: track behind the row, leading progress fill, and ink
/// for the icon, urgent deadline and fill-edge tick. Text colours never change
/// across the fill, so every track and fill stays light (or dark) enough for
/// `textPrimary` and `rowSecondary`.
struct RewardTonePalette {
  let track: Color
  let fill: Color
  let ink: Color

  static func palette(for tone: RewardRowProjection.Tone) -> RewardTonePalette {
    switch tone {
    case .needsMinimum:
      return RewardTonePalette(
        track: Color(light: 0xFFF7EC, dark: 0x262117),
        fill: Color(light: 0xFBE2C2, dark: 0x46351A, increasedLight: 0xF5CB94, increasedDark: 0x5E4720),
        ink: Color(light: 0x9A5410, dark: 0xF1B566)
      )
    case .earning:
      return RewardTonePalette(
        track: Color(light: 0xF0F9F3, dark: 0x17261F),
        fill: Color(light: 0xCBEBD7, dark: 0x1F4631, increasedLight: 0xA9DDBD, increasedDark: 0x2A5E42),
        ink: Color(light: 0x1A6E44, dark: 0x6BC78C)
      )
    case .complete:
      return RewardTonePalette(
        track: Color(light: 0xF5F4FB, dark: 0x1F1E33),
        fill: Color(light: 0xE2E0F5, dark: 0x322F58, increasedLight: 0xCBC7EE, increasedDark: 0x45407A),
        ink: Color(light: 0x5A578F, dark: 0xB9B6F0)
      )
    case .failed:
      return RewardTonePalette(track: Theme.card, fill: .clear, ink: Theme.outflow)
    case .neutral:
      return RewardTonePalette(track: Theme.card, fill: .clear, ink: Theme.accent)
    }
  }
}

extension Theme {
  /// Corner radii, all drawn with continuous corners. Nest smaller radii
  /// inside larger ones so inner shapes stay concentric with their card.
  enum Radius {
    /// Swatches, thumbnails and tags that sit inside a card.
    static let inset: CGFloat = 8
    /// Buttons, fields and bubbles inside a card.
    static let control: CGFloat = 12
    /// Opaque content cards: account groups, report cards, capture drafts.
    static let card: CGFloat = 16
    /// Large floating glass panels such as the keypad, and the hero preview
    /// on the inbox reading screen.
    static let panel: CGFloat = 28
  }

  /// Shared motion vocabulary so every surface moves the same way.
  enum Motion {
    /// State changes the user asked for: expand, collapse, select, filter.
    static let standard: Animation = .snappy(duration: 0.32)
    /// Content that arrives on its own: loaded data, toasts, new rows.
    static let arrive: Animation = .smooth(duration: 0.4)
    /// Charts and progress fills growing into place.
    static let chart: Animation = .smooth(duration: 0.6)
    /// Touch-down feedback on pressable cards and tiles.
    static let press: Animation = .snappy(duration: 0.18)
  }
}

extension Theme {
  /// Secondary text on tinted Rewards rows. `.secondary` drops to about 2.7:1
  /// on the amber fill; this stays above 5.4:1 on every track and fill.
  static let rowSecondary = Color(light: 0x4E5468, dark: 0xB3B8C9)
}

extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }

  /// Light/dark hex pair, with optional stronger values for Increase Contrast.
  init(light: UInt32, dark: UInt32, increasedLight: UInt32? = nil, increasedDark: UInt32? = nil) {
    let lightColour = UIColor(Color(hex: light))
    let darkColour = UIColor(Color(hex: dark))
    let increasedLightColour = UIColor(Color(hex: increasedLight ?? light))
    let increasedDarkColour = UIColor(Color(hex: increasedDark ?? dark))
    self.init(uiColor: UIColor { traits in
      let increased = traits.accessibilityContrast == .high
      if traits.userInterfaceStyle == .dark {
        return increased ? increasedDarkColour : darkColour
      }
      return increased ? increasedLightColour : lightColour
    })
  }

  init(light: Color, dark: Color) {
    self.init(uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
    })
  }
}
