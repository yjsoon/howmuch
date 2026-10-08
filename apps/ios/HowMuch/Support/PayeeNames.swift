import Foundation

/// Swift port of `apps/api/src/payee-names.ts`. Payee names as banks print them
/// are full of noise (reference codes, rails, processor prefixes, company
/// suffixes, branches, places). These helpers reduce a name to its merchant
/// words so "GRAB*A-5X7K9 SINGAPORE SG" and "Grab" read as the same merchant.
/// Keep the two files in step: `PayeeNamesTests` repeats the TypeScript fixtures.
enum PayeeNames {
  /// Words that identify a rail, processor, legal form or place rather than a merchant.
  private static let noiseWords: Set<String> = [
    // Payment rails and statement boilerplate
    "pos", "nets", "qr", "fast", "payment", "payments", "pay", "paynow", "mobile", "via", "to", "from", "othr", "trf",
    "transfer", "ibg", "giro", "bill", "bills", "debit", "credit", "card", "visa", "mastercard", "amex", "purchase",
    "ref", "inv", "invoice", "online", "ecom", "recurring", "contactless", "wallet",
    // Processor and wallet prefixes
    "sq", "tst", "paypal", "stripe", "sumup", "zettle", "adyen", "ipay", "eghl", "mktp", "mp", "krispay", "globale",
    // Legal forms (Singapore and Malaysia) and web boilerplate
    "pte", "ltd", "limited", "inc", "llc", "corp", "co", "company", "group", "holdings", "the", "and", "sdn", "bhd",
    "restoran", "kedai", "www", "com", "net", "org", "http", "https",
    // Places that appear on almost every local or cross-border statement line
    "sg", "sgp", "sin", "singapore", "spore", "intl", "international", "malaysia", "mys", "johor", "bahru",
  ]

  private static let digitWords = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

  private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
    // Patterns are literals in this file; a failure is a programming error.
    do {
      return try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    } catch {
      preconditionFailure("Invalid payee-name pattern \(pattern): \(error)")
    }
  }

  private static let ampersand = regex("&(amp|#38);", caseInsensitive: true)
  private static let apostropheEntity = regex("&(#39|apos|rsquo);", caseInsensitive: true)
  private static let otherEntity = regex("&[a-z]+;|&#\\d+;", caseInsensitive: true)
  private static let mobileEnding = regex("\\(\\s*mobile ending\\s*\\d*\\s*\\)", caseInsensitive: true)
  private static let gluedPlace = regex("([a-z])([A-Z]{4,})(?=[^A-Za-z]|$)")
  private static let combiningMarks = regex("[\\u0300-\\u036F]")
  private static let sevenEleven = regex("\\b7\\s*-?\\s*(?:11|eleven)\\b")
  private static let apostrophes = regex("['\u{2019}`]")
  private static let leadingDigitWord = regex("^[1-9][a-z]{3,}$")
  private static let wordCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")

  private static func replacing(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
    expression.stringByReplacingMatches(
      in: text,
      options: [],
      range: NSRange(text.startIndex..., in: text),
      withTemplate: template
    )
  }

  private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
    expression.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
  }

  /// Merchant words of a payee name, in order, lowercase.
  static func tokens(_ name: String?) -> [String] {
    guard let name, !name.isEmpty else {
      return []
    }
    var text = name
    text = replacing(ampersand, in: text, with: "&")
    text = replacing(apostropheEntity, in: text, with: "'")
    text = replacing(otherEntity, in: text, with: " ")
    // PayNow payees: "TAN AH KOW (Mobile ending 1234)".
    text = replacing(mobileEnding, in: text, with: " ")
    // A place glued onto a truncated name: "Parka ServiSINGAPORE".
    text = replacing(gluedPlace, in: text, with: "$1 $2")
    text = text.decomposedStringWithCompatibilityMapping
    text = replacing(combiningMarks, in: text, with: "")
    text = text.lowercased()
    // One chain, three spellings: "7-11", "7-Eleven", "7 ELEVEN-SENGKANG".
    text = replacing(sevenEleven, in: text, with: "seveneleven")
    text = replacing(apostrophes, in: text, with: "")
    var chunks: [String] = []
    for chunk in text.components(separatedBy: wordCharacters.inverted) where !chunk.isEmpty {
      // "4FINGERS" is "Four Fingers"; longer numbers stay codes.
      if matches(leadingDigitWord, chunk), let digit = chunk.first?.wholeNumberValue {
        chunks.append(digitWords[digit])
        chunks.append(String(chunk.dropFirst()))
      } else {
        chunks.append(chunk)
      }
    }
    // Anything else with a digit is a code, card number, date, store number or phone number.
    let words = chunks.filter { chunk in
      !chunk.contains(where: \.isNumber) && chunk.count >= 3 && !looksLikeCode(chunk)
    }
    let merchant = words.filter { !noiseWords.contains($0) }
    // A payee that is only noise ("PayPal") keeps its leading word rather than nothing.
    return merchant.isEmpty ? Array(words.prefix(1)) : merchant
  }

  /// Letter-only codes: long runs without vowels, such as "bxkqr". Short ones ("KTMB", "KKH") are real names.
  private static func looksLikeCode(_ word: String) -> Bool {
    word.count >= 5 && !word.contains { "aeiouy".contains($0) }
  }

  /// Short stem of the first merchant word, for a substring search wide enough
  /// to catch other spellings ("grabfood" searches "grab", finding "Grab" too).
  static func searchStem(_ tokens: [String]) -> String? {
    guard let first = tokens.first else {
      return nil
    }
    return String(first.prefix(4))
  }

  /// How closely two payee names' merchant words match, from 0 to 1. Symmetric:
  /// the average of how well each name's words are covered by the other's.
  static func similarity(_ a: [String], _ b: [String]) -> Double {
    (coverage(a, b) + coverage(b, a)) / 2
  }

  /// Similarity of two raw payee names.
  static func similarity(_ a: String?, _ b: String?) -> Double {
    similarity(tokens(a), tokens(b))
  }

  /// How well `target`'s words are covered by `candidate`'s. The first words
  /// must match for any coverage at all and carry double weight; names that run
  /// together or split differently are also compared joined up.
  private static func coverage(_ target: [String], _ candidate: [String]) -> Double {
    guard let targetFirst = target.first, let candidateFirst = candidate.first else {
      return 0
    }
    let first = wordScore(targetFirst, candidateFirst)
    var joined = 0.0
    if first < 1 {
      let targetJoined = target.joined()
      let candidateJoined = candidate.joined()
      if targetJoined == candidateJoined {
        return 1
      }
      let shorter = min(targetJoined.count, candidateJoined.count)
      if shorter >= 6, targetJoined.hasPrefix(candidateJoined) || candidateJoined.hasPrefix(targetJoined) {
        joined = 0.9
      }
    }
    if first == 0 {
      return joined
    }
    var matched = 2 * first
    var total = 2.0
    for word in target.dropFirst() {
      total += 1
      matched += candidate.map { wordScore(word, $0) }.max() ?? 0
    }
    return max(joined, matched / total)
  }

  private static func wordScore(_ a: String, _ b: String) -> Double {
    if a == b {
      return 1
    }
    let (short, long) = a.count <= b.count ? (a, b) : (b, a)
    return short.count >= 4 && long.hasPrefix(short) ? 0.5 : 0
  }
}
