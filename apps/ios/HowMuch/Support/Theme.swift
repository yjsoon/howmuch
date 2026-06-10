import SwiftUI
import UIKit

/// Editorial-ledger palette shared with the web app: ledger red for outflows,
/// racing green for inflows, both lifted slightly in dark mode for contrast.
enum Theme {
  static let outflow = Color(
    light: Color(red: 0.659, green: 0.196, blue: 0.165),
    dark: Color(red: 0.851, green: 0.447, blue: 0.404)
  )

  static let inflow = Color(
    light: Color(red: 0.165, green: 0.400, blue: 0.282),
    dark: Color(red: 0.420, green: 0.690, blue: 0.541)
  )

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
