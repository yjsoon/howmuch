import Foundation

struct AccountIcon: RawRepresentable, Equatable, Hashable, Sendable {
  let rawValue: String

  init?(rawValue: String) {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 1 else { return nil }
    if Self.isKeycap(trimmed) {
      self.rawValue = trimmed
      return
    }
    let hasAsciiDigit = trimmed.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    guard !hasAsciiDigit else { return nil }
    let hasEmoji = trimmed.unicodeScalars.contains { scalar in
      scalar.properties.isEmojiPresentation
        || (scalar.properties.isEmoji && !Self.bareKeycapBases.contains(scalar))
    }
    guard hasEmoji else { return nil }
    self.rawValue = trimmed
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
  }

  private static let bareKeycapBases: Set<Unicode.Scalar> = ["#", "*"]
  private static let keycapBases: Set<Unicode.Scalar> = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "#", "*",
  ]
  private static let variationSelector16 = Unicode.Scalar(0xFE0F)!
  private static let combiningEnclosingKeycap = Unicode.Scalar(0x20E3)!

  private static func isKeycap(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard let base = scalars.first, keycapBases.contains(base) else { return false }
    if scalars.count == 2 {
      return scalars[1] == combiningEnclosingKeycap
    }
    if scalars.count == 3 {
      return scalars[1] == variationSelector16 && scalars[2] == combiningEnclosingKeycap
    }
    return false
  }

  static let fallback = AccountIcon(unchecked: "🏦")

  static let defaultsByType: [String: AccountIcon] = [
    "checking": AccountIcon(unchecked: "🏦"),
    "savings": AccountIcon(unchecked: "💰"),
    "cash": AccountIcon(unchecked: "💵"),
    "creditCard": AccountIcon(unchecked: "💳"),
    "lineOfCredit": AccountIcon(unchecked: "💳"),
    "otherAsset": AccountIcon(unchecked: "📈"),
    "otherLiability": AccountIcon(unchecked: "📉"),
    "mortgage": AccountIcon(unchecked: "🏠"),
    "autoLoan": AccountIcon(unchecked: "🚗"),
    "studentLoan": AccountIcon(unchecked: "🎓"),
    "medicalDebt": AccountIcon(unchecked: "🏥"),
    "otherLoan": AccountIcon(unchecked: "📄"),
  ]

  static func `default`(for accountType: String) -> AccountIcon {
    defaultsByType[accountType] ?? fallback
  }

  static func displayGlyph(stored: String?, accountType: String) -> String {
    let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? `default`(for: accountType).rawValue : trimmed
  }
}

enum AccountIconChoice: Hashable {
  case followsType
  case custom(AccountIcon)

  init(stored: String?, type: String) {
    let typeDefault = AccountIcon.default(for: type)
    guard let stored, let parsed = AccountIcon(rawValue: stored), parsed != typeDefault else {
      self = .followsType
      return
    }
    self = .custom(parsed)
  }

  func resolved(default typeDefault: AccountIcon) -> AccountIcon {
    switch self {
    case .followsType: typeDefault
    case .custom(let icon): icon
    }
  }
}
