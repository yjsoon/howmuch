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

extension Color {
  init(light: Color, dark: Color) {
    self.init(uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
    })
  }
}
