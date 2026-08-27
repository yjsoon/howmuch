import Foundation

enum AccountIcon {
  static let fallback = "🏦"
  static let palette = [
    "🏦", "💳", "💰", "💵", "💸", "🏠", "🚗", "✈️",
    "📈", "📉", "💼", "🛒", "🎓", "🏥", "📱", "💻",
    "⭐", "🌴", "☕", "🍔", "🎮", "🐱", "🐶", "🐷",
  ]

  static let defaultsByType: [String: String] = [
    "checking": "🏦",
    "savings": "💰",
    "cash": "💵",
    "creditCard": "💳",
    "lineOfCredit": "💳",
    "otherAsset": "📈",
    "otherLiability": "📉",
    "mortgage": "🏠",
    "autoLoan": "🚗",
    "studentLoan": "🎓",
    "medicalDebt": "🏥",
    "otherLoan": "📄",
  ]

  static func resolved(_ icon: String?, type: String) -> String {
    let trimmed = icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? `default`(for: type) : trimmed
  }

  static func `default`(for type: String) -> String {
    defaultsByType[type] ?? fallback
  }

  static func parse(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 1 else { return nil }
    let hasLetterOrDigit = trimmed.unicodeScalars.contains { scalar in
      CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }
    guard !hasLetterOrDigit else { return nil }
    let isEmoji = trimmed.unicodeScalars.contains { $0.properties.isEmoji }
    return isEmoji ? trimmed : nil
  }
}
