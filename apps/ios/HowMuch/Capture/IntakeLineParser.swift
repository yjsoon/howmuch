import Foundation

/// A deterministic reader for the text of bank and wallet screenshots and
/// statements, used when `SlipReader` returns nothing (no Apple Intelligence on
/// this device, or the model declined). It produces the same extractions the
/// model would, so `SlipReaderMapping.map` keeps account, category, payee and
/// date handling identical.
///
/// It reads three layouts: `05 OCT PAYEE -8.90` on one line, payee and amount
/// on adjacent lines, and date header lines ("Today", "5 Oct 2026") that apply
/// to the rows below. Balances, totals and page furniture are ignored. A foreign
/// amount ("USD 12.00") is never read as dollars: the row waits for an SGD
/// figure and is dropped without one. Direction is an outflow unless the amount
/// carries `+` or `CR`.
enum IntakeLineParser {
  static func interpret(
    text: String,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee],
    calendar: Calendar = .current,
    now: Date = .now
  ) -> [SlipMappedDraft] {
    SlipReaderMapping.map(
      extract(text),
      sentence: text,
      accounts: accounts,
      categoryGroups: categoryGroups,
      payees: payees,
      calendar: calendar,
      now: now
    )
  }

  private struct Pending {
    var payee: String
    var date: String?
  }

  private struct ParsedAmount {
    var text: String
    var magnitude: String
    var isInflow: Bool
    var isForeign: Bool
  }

  static func extract(_ text: String) -> [SlipReaderMapping.Extraction] {
    var rows: [SlipReaderMapping.Extraction] = []
    var currentDate: String?
    var pending: Pending?

    for rawLine in text.components(separatedBy: .newlines) {
      var line = clean(rawLine)
      guard !line.isEmpty else {
        continue
      }
      // Status words and reference lines sit between a payee and its amount.
      if matches(noise, line) {
        continue
      }
      // Balances, totals and page furniture end any row in progress.
      if matches(ignored, line) {
        pending = nil
        continue
      }
      if let header = leadingDate(line), header.rest.isEmpty {
        if pending != nil {
          pending?.date = header.date
        } else {
          currentDate = header.date
        }
        continue
      }
      var rowDate: String?
      if let leading = leadingDate(line) {
        rowDate = leading.date
        line = leading.rest
      }
      guard let amount = parseAmount(line) else {
        let payee = cleanPayee(line)
        if hasWords(payee) {
          pending = Pending(payee: payee, date: rowDate)
        }
        continue
      }
      let payee = cleanPayee(amount.text)
      if amount.isForeign {
        // Wait for the SGD figure; never save a foreign amount as dollars.
        if hasWords(payee) {
          pending = Pending(payee: payee, date: rowDate)
        }
        continue
      }
      let name: String
      let date: String?
      if hasWords(payee) {
        name = payee
        date = rowDate ?? currentDate
      } else if let waiting = pending {
        name = waiting.payee
        date = rowDate ?? waiting.date ?? currentDate
      } else {
        continue
      }
      pending = nil
      rows.append(SlipReaderMapping.Extraction(
        amount: amount.magnitude,
        payee: name,
        date: date ?? "",
        isInflow: amount.isInflow,
        direction: amount.isInflow ? "inflow" : "outflow"
      ))
    }
    return rows
  }

  // MARK: Patterns

  private static func regex(_ pattern: String) -> NSRegularExpression {
    do {
      return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    } catch {
      preconditionFailure("Invalid intake pattern \(pattern): \(error)")
    }
  }

  private static let noise = regex(
    #"^(?:completed|successful|success|paid|pending|approved|declined|posted)$|^(?:ref|reference|txn|trans(?:action)? id|card (?:no|number|ending)|account (?:no|number))\b"#
  )
  private static let ignored = regex(
    #"\b(?:balance|total|available|opening|closing|statement|subtotal|credit limit|minimum payment|amount due|due date|brought forward|carried forward)\b|\bpage \d+(?: of \d+)?\b"#
  )
  private static let time = regex(#"\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?\b"#)
  private static let foreignAmount = regex(
    #"\b(?:USD|EUR|GBP|AUD|MYR|JPY|HKD|CNY|RMB|THB|IDR|NZD|CAD|CHF|KRW|INR)\s*[\d,]+(?:\.\d+)?"#
  )

  private static let weekday = #"(?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?"#
  private static let month =
    #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b\.?"#
  private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

  private static let isoDate = regex("^" + weekday + #"(\d{4})-(\d{2})-(\d{2})\b"#)
  private static let dayMonthName = regex("^" + weekday + #"(\d{1,2})[\s-]*"# + month + #"(?:[\s,-]+(\d{4}))?\b"#)
  private static let monthNameDay = regex("^" + weekday + month + #"\s+(\d{1,2})(?:,?\s+(\d{4}))?\b"#)
  private static let slashDate = regex("^" + weekday + #"(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#)
  private static let namedDay = regex(#"^(today|yesterday)\b"#)

  private static let amountPattern = regex(
    #"^(.*?)\s*([-+−–])?\s*(S\$|US\$|A\$|HK\$|NT\$|\$|SGD|USD|EUR|GBP|AUD|MYR|JPY|HKD|CNY|RMB|THB|IDR|NZD|CAD|CHF|KRW|INR)?\s*([-+−–])?\s*((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?)\s*(CR|DR)?$"#
  )

  // MARK: Parsing

  private static func range(_ text: String) -> NSRange {
    NSRange(text.startIndex..., in: text)
  }

  private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
    expression.firstMatch(in: text, options: [], range: range(text)) != nil
  }

  private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
    let found = match.range(at: index)
    guard found.location != NSNotFound, let swiftRange = Range(found, in: text) else {
      return nil
    }
    return String(text[swiftRange])
  }

  /// Trims, drops clock times, and collapses runs of spaces.
  private static func clean(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    text = time.stringByReplacingMatches(in: text, options: [], range: range(text), withTemplate: "")
    text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: CharacterSet(charactersIn: " ,|"))
  }

  private static func hasWords(_ text: String) -> Bool {
    text.filter(\.isLetter).count >= 2
  }

  private static func cleanPayee(_ text: String) -> String {
    var payee = foreignAmount.stringByReplacingMatches(
      in: text, options: [], range: range(text), withTemplate: ""
    )
    payee = payee.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return payee.trimmingCharacters(in: CharacterSet(charactersIn: " -:\u{2022}|\u{00B7}*,"))
  }

  /// A date at the start of the line, normalised for `SlipReaderMapping.date`
  /// (`yyyy-MM-dd` with a year, `d MMM` without, or `today`/`yesterday`), and
  /// the text after it.
  private static func leadingDate(_ line: String) -> (date: String, rest: String)? {
    func result(_ match: NSTextCheckingResult, day: Int?, month: Int?, year: String?) -> (date: String, rest: String)? {
      guard let day, let month, (1...31).contains(day), (1...12).contains(month) else {
        return nil
      }
      let tail = String(line[Range(match.range, in: line)!.upperBound...])
        .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-\u{2013}|"))
      if var year {
        if year.count == 2 { year = "20" + year }
        guard let value = Int(year) else {
          return nil
        }
        return (String(format: "%04d-%02d-%02d", value, month, day), tail)
      }
      return ("\(day) \(monthNames[month - 1].capitalized)", tail)
    }

    func monthIndex(_ name: String?) -> Int? {
      guard let prefix = name?.lowercased().prefix(3) else {
        return nil
      }
      return monthNames.firstIndex(of: String(prefix)).map { $0 + 1 }
    }

    let full = range(line)
    if let match = isoDate.firstMatch(in: line, options: [], range: full) {
      return result(
        match,
        day: group(match, 3, in: line).flatMap { Int($0) },
        month: group(match, 2, in: line).flatMap { Int($0) },
        year: group(match, 1, in: line)
      )
    }
    if let match = dayMonthName.firstMatch(in: line, options: [], range: full) {
      return result(
        match,
        day: group(match, 1, in: line).flatMap { Int($0) },
        month: monthIndex(group(match, 2, in: line)),
        year: group(match, 3, in: line)
      )
    }
    if let match = monthNameDay.firstMatch(in: line, options: [], range: full) {
      return result(
        match,
        day: group(match, 2, in: line).flatMap { Int($0) },
        month: monthIndex(group(match, 1, in: line)),
        year: group(match, 3, in: line)
      )
    }
    if let match = slashDate.firstMatch(in: line, options: [], range: full) {
      return result(
        match,
        day: group(match, 1, in: line).flatMap { Int($0) },
        month: group(match, 2, in: line).flatMap { Int($0) },
        year: group(match, 3, in: line)
      )
    }
    if let match = namedDay.firstMatch(in: line, options: [], range: full), let word = group(match, 1, in: line) {
      let tail = String(line[Range(match.range, in: line)!.upperBound...])
        .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-\u{2013}|"))
      return (word.lowercased(), tail)
    }
    return nil
  }

  /// A trailing amount: whole numbers count only with a currency marker, so a
  /// store number or reference is never money.
  private static func parseAmount(_ line: String) -> ParsedAmount? {
    guard let match = amountPattern.firstMatch(in: line, options: [], range: range(line)) else {
      return nil
    }
    let text = group(match, 1, in: line) ?? ""
    let leadingSign = group(match, 2, in: line)
    let currency = group(match, 3, in: line)?.uppercased()
    let trailingSign = group(match, 4, in: line)
    guard let number = group(match, 5, in: line) else {
      return nil
    }
    let marker = group(match, 6, in: line)?.uppercased()
    if !number.contains("."), currency == nil {
      return nil
    }
    let magnitude = number.replacingOccurrences(of: ",", with: "")
    guard let value = Decimal(string: magnitude), value > 0 else {
      return nil
    }
    let inflow = leadingSign == "+" || trailingSign == "+" || marker == "CR"
    let sgd: Set<String> = ["$", "S$", "SGD"]
    let foreign = currency.map { !sgd.contains($0) } ?? false
    return ParsedAmount(text: text, magnitude: magnitude, isInflow: inflow, isForeign: foreign)
  }
}
