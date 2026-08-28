import Foundation

struct AccountIcon: RawRepresentable, Equatable, Hashable, Sendable {
  let rawValue: String

  init?(rawValue: String) {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 1 else { return nil }
    let hasLetterOrDigit = trimmed.unicodeScalars.contains { scalar in
      CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }
    guard !hasLetterOrDigit else { return nil }
    let hasEmoji = trimmed.unicodeScalars.contains { scalar in
      scalar.properties.isEmojiPresentation
        || (
          scalar.properties.isEmoji
            && scalar.value != 0x23
            && scalar.value != 0x2A
        )
    }
    guard hasEmoji else { return nil }
    self.rawValue = trimmed
  }

  private init(unchecked rawValue: String) {
    self.rawValue = rawValue
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
