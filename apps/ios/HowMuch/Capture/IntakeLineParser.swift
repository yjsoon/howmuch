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
      extract(text, calendar: calendar, now: now),
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
    /// The next text line may replace this payee: it was a heading or category
    /// label, or a date line came after it, and no amount has arrived yet.
    var replaceable = false
  }

  private struct Token {
    var magnitude: String
    var isInflow: Bool
    var isForeign: Bool
  }

  private struct ParsedAmount {
    var text: String
    var magnitude: String
    var isInflow: Bool
    var isForeign: Bool
  }

  private enum AmountResult {
    /// The line ends in no amount.
    case none
    /// The line has amounts but not one that can be trusted (a running balance
    /// that cannot be told from the amount): the row is dropped, not guessed.
    case dropped
    case amount(ParsedAmount)
  }

  static func extract(
    _ text: String,
    calendar: Calendar = .current,
    now: Date = .now
  ) -> [SlipReaderMapping.Extraction] {
    var rows: [SlipReaderMapping.Extraction] = []
    var currentDate: String?
    var pending: Pending?
    // A statement that prints "Posting Date:" under each row: lines between a
    // row's amount and that line are the rest of its descriptor.
    var continuing = false

    let lines = text.components(separatedBy: .newlines)
    let usesPostingDates = lines.contains { matches(postingDate, clean($0)) }

    for rawLine in lines {
      var line = clean(rawLine)
      guard !line.isEmpty else {
        continue
      }
      // A posting date ends a row's descriptor. It is never a date or a payee,
      // and a payee still waiting for its amount keeps waiting.
      if matches(postingDate, line) {
        continuing = false
        continue
      }
      // Status words, reference lines, postcodes and exchange-rate lines sit
      // between a payee and its amount without ending the row.
      if matches(noise, line) {
        continue
      }
      // A category label never replaces or blocks a payee; alone above an amount it is the payee.
      if matches(categoryLabel, line) {
        if pending == nil, !continuing {
          pending = Pending(payee: cleanPayee(line), date: nil, replaceable: true)
        }
        continue
      }
      // Balances, totals and page furniture end any row in progress.
      if matches(ignored, line) {
        pending = nil
        continue
      }
      let leading = leadingDate(line, calendar: calendar, now: now)
      if let leading, leading.rest.isEmpty {
        currentDate = leading.date
        if pending != nil {
          // "Grab / Today / -$8.90": the date belongs to the waiting payee. Without
          // a clock time it may instead be a header, so a text line that comes
          // next may still replace the payee (it may have been chrome).
          pending?.date = leading.date
          if !matches(time, rawLine) {
            pending?.replaceable = true
          }
        }
        continuing = false
        continue
      }
      var rowDate: String?
      if let leading {
        rowDate = leading.date
        line = leading.rest
      }
      if matches(currencyName, line) {
        // A foreign amount in words: the pending row keeps waiting for its SGD figure.
        continue
      }
      let amount: ParsedAmount
      switch parseAmount(line) {
      case .none:
        if continuing {
          continue
        }
        // The first text line of a block is the payee; later lines (the
        // descriptor) do not replace it. A service line ("GrabFood order",
        // "Ride to Changi") is not a merchant: it replaces only a category
        // label, and only an "… order" line gives way to the merchant below it.
        let payee = cleanPayee(line)
        if let existing = pending {
          if matches(serviceDescriptor, payee) {
            if matches(categoryLabel, existing.payee), hasWords(payee) {
              pending = Pending(payee: payee, date: existing.date ?? rowDate)
            }
            continue
          }
          if existing.replaceable || matches(orderLine, existing.payee), hasWords(payee) {
            pending = Pending(payee: payee, date: existing.date ?? rowDate)
          }
        } else if hasWords(payee) {
          pending = Pending(payee: payee, date: rowDate)
        }
        continue
      case .dropped:
        pending = nil
        continue
      case .amount(let parsed):
        amount = parsed
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
      continuing = usesPostingDates
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
    #"^(?:completed|successful|success|paid|pending|approved|declined|posted|cancelled|canceled|refunded|failed|reversed)$|^(?:ref|reference|txn|trans(?:action)? id|card (?:no|number|ending)|account (?:no|number))\b|^(?:singapore|sg|spore)\s*\d{6}$|\bexchange rate\b|\bfx rate\b|^rate\b|\bconversion fee\b|\bcurrency conversion\b|\bforex\b|^(?:credit|debit)\s+[\d\s]+$|^(?:all transactions|recent transactions|recent activity|transactions|transaction history|activity|history|statement|unbilled|current|pending)$"#
  )
  /// A category label under a payee. It is the payee only when it is alone above an amount.
  private static let categoryLabel = regex(
    #"^(?:transportation|transport|groceries|food (?:&|and) drink|dining|shopping|bills|entertainment|travel|health|credit card payments|transfers?)$"#
  )
  /// A service or order line under a wallet row ("GrabFood order", "Ride to Changi").
  /// It describes the row, so it is not a payee when a merchant line follows it.
  private static let serviceDescriptor = regex(
    #"^[A-Za-z]+ order$|^(?:ride|trip|delivery) (?:to|from) .+$"#
  )
  /// The service lines a merchant line below replaces ("GrabFood order" over "Kopitiam").
  private static let orderLine = regex(#"^[A-Za-z]+ order$"#)
  private static let postingDate = regex(
    #"^(?:posting date|posted on|posted|transaction date|trans(?:action)? date|value date)\b"#
  )
  private static let ignored = regex(
    #"\b(?:balance|bal|avail|available|opening|closing|statement|subtotal|total|credit limit|minimum payment|amount due|due date|brought forward|carried forward)\b|\b[bc]/f\b|\bpage \d+(?: of \d+)?\b"#
  )
  /// A line that is a currency written out ("US DOLLAR 15.99", "JAPANESE YEN 1,500").
  private static let currencyName = regex(
    #"^(?:u\.?\s*s\.?\s*dollars?|euros?|japanese yen|pounds? sterling|british pounds?|australian dollars?|malaysian ringgit|ringgit|thai baht|rupiah|renminbi|yuan|korean won)\b\s*[\d,]+(?:\.\d+)?$"#
  )
  /// A code between two amounts ("12.00 USD 16.20"): it belongs to the first,
  /// unless that one carries its own `$`, `S$` or `SGD` prefix, with or without
  /// a sign between the prefix and the number ("S$-21.70 USD 15.99", "S$ - 21.70").
  private static let codeBetweenAmounts = regex(
    #"(?<!\$)(?<!\$ )(?<!SGD)(?<!SGD )(?<!\$[-+\u2212\u2013])(?<!\$ [-+\u2212\u2013])(?<!SGD[-+\u2212\u2013])(?<!SGD [-+\u2212\u2013])(?<!\$[-+\u2212\u2013] )(?<!\$ [-+\u2212\u2013] )(?<!SGD[-+\u2212\u2013] )(?<!SGD [-+\u2212\u2013] )(?<![\d,.])((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{1,2})\s*("# + #"(?:USD|EUR|GBP|AUD|MYR|JPY|HKD|CNY|RMB|THB|IDR|NZD|CAD|CHF|KRW|INR|PHP|TWD|VND)"# + #")\s+(?=(?:[-+−–]\s*)?\d)"#
  )
  private static let time = regex(#"\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?\b"#)
  private static let foreignAmount = regex(
    #"\b(?:USD|EUR|GBP|AUD|MYR|JPY|HKD|CNY|RMB|THB|IDR|NZD|CAD|CHF|KRW|INR|PHP|TWD|VND)\s*[\d,]+(?:\.\d+)?"#
  )

  private static let weekday = #"(?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?"#
  private static let month =
    #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b\.?"#
  private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

  private static let isoDate = regex("^" + weekday + #"(\d{4})-(\d{2})-(\d{2})\b"#)
  private static let dayMonthName = regex("^" + weekday + #"(\d{1,2})[\s-]*"# + month + #"(?:[\s,-]+(\d{4}))?\b"#)
  private static let monthNameDay = regex("^" + weekday + month + #"\s+(\d{1,2})(?:,?\s+(\d{4}))?\b"#)
  private static let slashDate = regex("^" + weekday + #"(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#)
  private static let dottedDate = regex("^" + weekday + #"(\d{1,2})\.(\d{1,2})\.(\d{2,4})\b"#)
  private static let namedDay = regex(#"^(today|yesterday)\b"#)

  private static let currencyPrefix =
    #"(?:S\$|US\$|A\$|HK\$|NT\$|NZ\$|C\$|\$|SGD|USD|EUR|GBP|AUD|MYR|JPY|HKD|CNY|RMB|THB|IDR|NZD|CAD|CHF|KRW|INR|PHP|TWD|VND|RM|Rp|\u20AC|\u00A3|\u00A5|\u20A9|\u0E3F|\u20B9|\u20B1|\u20AB)"#
  private static let currencyCode =
    #"(?:SGD|USD|EUR|GBP|AUD|MYR|JPY|HKD|CNY|RMB|THB|IDR|NZD|CAD|CHF|KRW|INR|PHP|TWD|VND)"#

  /// The last amount on a line: `text`, an optional sign, an optional currency
  /// marker before the number, the number, then an optional `CR`, `DR` or
  /// currency code. The amount must not start inside a word or number.
  private static let amountTail = regex(
    #"^(.*?)(?:(?<![A-Za-z0-9,.])|(?=[\u20AC\u00A3\u00A5\u20A9\u0E3F\u20B9\u20B1\u20AB])|(?=(?:RM|Rp)\d))([-+\u2212\u2013])?\s*("# + currencyPrefix + #")?\s*([-+\u2212\u2013])?\s*((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?)\s*(CR|DR|"#
      + currencyCode + #")?$"#
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
    var text = foldLookalikes(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    text = time.stringByReplacingMatches(in: text, options: [], range: range(text), withTemplate: "")
    text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: CharacterSet(charactersIn: " ,|"))
  }

  /// Latin letters that OCR returns as Cyrillic or Greek look-alikes.
  private static let lookalikes: [Character: Character] = [
    "\u{0410}": "A", "\u{0412}": "B", "\u{0421}": "C", "\u{0415}": "E", "\u{041D}": "H", "\u{041A}": "K",
    "\u{041C}": "M", "\u{041E}": "O", "\u{0420}": "P", "\u{0422}": "T", "\u{0425}": "X", "\u{0423}": "Y",
    "\u{0430}": "a", "\u{0441}": "c", "\u{0435}": "e", "\u{043E}": "o", "\u{0440}": "p", "\u{0445}": "x",
    "\u{0443}": "y", "\u{0456}": "i", "\u{0455}": "s", "\u{0458}": "j",
    "\u{0391}": "A", "\u{0392}": "B", "\u{0395}": "E", "\u{0396}": "Z", "\u{0397}": "H", "\u{0399}": "I",
    "\u{039A}": "K", "\u{039C}": "M", "\u{039D}": "N", "\u{039F}": "O", "\u{03A1}": "P", "\u{03A4}": "T",
    "\u{03A5}": "Y", "\u{03A7}": "X", "\u{03BF}": "o", "\u{03BD}": "v",
  ]

  /// Folds look-alike Cyrillic and Greek letters to ASCII, but only in a line
  /// that is mostly Latin. A line with as many Cyrillic or Greek letters as
  /// Latin ones is real text in that script and is left as read.
  private static func foldLookalikes(_ text: String) -> String {
    var latin = 0
    var other = 0
    for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
      if scalar.isASCII {
        latin += 1
      } else if (0x0370...0x03FF).contains(scalar.value) || (0x0400...0x04FF).contains(scalar.value) {
        other += 1
      }
    }
    guard other > 0, latin > other else {
      return text
    }
    return String(text.map { lookalikes[$0] ?? $0 })
  }

  private static func hasWords(_ text: String) -> Bool {
    text.filter(\.isLetter).count >= 2
  }

  private static func cleanPayee(_ text: String) -> String {
    var payee = foreignAmount.stringByReplacingMatches(
      in: text, options: [], range: range(text), withTemplate: ""
    )
    // Card and account numbers: twelve or more digits, spaced or not.
    payee = payee.replacingOccurrences(
      of: #"\b\d(?:[\s-]?\d){11,}\b"#, with: "", options: .regularExpression
    )
    payee = payee.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return payee.trimmingCharacters(in: CharacterSet(charactersIn: " -:\u{2022}|\u{00B7}*,;"))
  }

  /// A date at the start of the line, as `yyyy-MM-dd` (or `today` /
  /// `yesterday`), and the text after it. A date without a year takes this
  /// year, or last year when that would be more than a week ahead. A year more
  /// than one away from now is not a year: after a day and month name the
  /// digits stay in the text, and anywhere else the line has no date.
  private static func leadingDate(
    _ line: String,
    calendar: Calendar,
    now: Date
  ) -> (date: String, rest: String)? {
    let nowYear = calendar.component(.year, from: now)

    func validDate(_ year: Int, _ month: Int, _ day: Int) -> Date? {
      guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
        return nil
      }
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      return parts.year == year && parts.month == month && parts.day == day ? date : nil
    }

    func iso(day: Int, month: Int, year: Int?) -> String? {
      guard (1...31).contains(day), (1...12).contains(month) else {
        return nil
      }
      var resolved = year ?? nowYear
      if year == nil, let candidate = validDate(resolved, month, day),
         let limit = calendar.date(byAdding: .day, value: 7, to: now), candidate > limit {
        resolved -= 1
      }
      guard validDate(resolved, month, day) != nil else {
        return nil
      }
      return String(format: "%04d-%02d-%02d", resolved, month, day)
    }

    func tail(from index: String.Index) -> String {
      String(line[index...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.-\u{2013}|"))
    }

    func finish(
      _ match: NSTextCheckingResult,
      day: Int?,
      month: Int?,
      yearText: String?,
      yearGroup: Int,
      yearMayBeText: Bool
    ) -> (date: String, rest: String)? {
      guard let day, let month else {
        return nil
      }
      var year: Int?
      var end = Range(match.range, in: line)!.upperBound
      if let yearText, var value = Int(yearText) {
        if yearText.count == 2 { value += 2000 }
        if abs(value - nowYear) <= 1 {
          year = value
        } else if yearMayBeText, let yearRange = Range(match.range(at: yearGroup), in: line) {
          end = yearRange.lowerBound
        } else {
          return nil
        }
      }
      guard let date = iso(day: day, month: month, year: year) else {
        return nil
      }
      return (date, tail(from: end))
    }

    func monthIndex(_ name: String?) -> Int? {
      guard let prefix = name?.lowercased().prefix(3) else {
        return nil
      }
      return monthNames.firstIndex(of: String(prefix)).map { $0 + 1 }
    }

    func number(_ match: NSTextCheckingResult, _ index: Int) -> Int? {
      group(match, index, in: line).flatMap { Int($0) }
    }

    let full = range(line)
    if let match = isoDate.firstMatch(in: line, options: [], range: full) {
      return finish(
        match, day: number(match, 3), month: number(match, 2),
        yearText: group(match, 1, in: line), yearGroup: 1, yearMayBeText: false
      )
    }
    if let match = dayMonthName.firstMatch(in: line, options: [], range: full) {
      return finish(
        match, day: number(match, 1), month: monthIndex(group(match, 2, in: line)),
        yearText: group(match, 3, in: line), yearGroup: 3, yearMayBeText: true
      )
    }
    if let match = monthNameDay.firstMatch(in: line, options: [], range: full) {
      return finish(
        match, day: number(match, 2), month: monthIndex(group(match, 1, in: line)),
        yearText: group(match, 3, in: line), yearGroup: 3, yearMayBeText: true
      )
    }
    if let match = dottedDate.firstMatch(in: line, options: [], range: full) {
      return finish(
        match, day: number(match, 1), month: number(match, 2),
        yearText: group(match, 3, in: line), yearGroup: 3, yearMayBeText: false
      )
    }
    if let match = slashDate.firstMatch(in: line, options: [], range: full) {
      return finish(
        match, day: number(match, 1), month: number(match, 2),
        yearText: group(match, 3, in: line), yearGroup: 3, yearMayBeText: false
      )
    }
    if let match = namedDay.firstMatch(in: line, options: [], range: full), let word = group(match, 1, in: line) {
      return (word.lowercased(), tail(from: Range(match.range, in: line)!.upperBound))
    }
    return nil
  }

  /// Reads the amounts at the end of a line. A whole number counts only with a
  /// currency marker, so a store number or reference is never money.
  ///
  /// - One amount is the amount.
  /// - Two SGD amounts: the first is the transaction and the last a running
  ///   balance. Three or more cannot be told apart, so the row is dropped.
  /// - With a foreign amount present, the single SGD amount is used; none
  ///   leaves a foreign row that waits for one, and several drop the row.
  private static func parseAmount(_ line: String) -> AmountResult {
    var tokens: [Token] = []
    var rest = codeBetweenAmounts.stringByReplacingMatches(
      in: line, options: [], range: range(line), withTemplate: "$1 $2 ; "
    )
    while tokens.count < 4, let match = amountTail.firstMatch(in: rest, options: [], range: range(rest)) {
      guard let number = group(match, 5, in: rest) else {
        break
      }
      let prefix = group(match, 3, in: rest)?.uppercased()
      let marker = group(match, 6, in: rest)?.uppercased()
      if !number.contains("."), prefix == nil {
        break
      }
      let magnitude = number.replacingOccurrences(of: ",", with: "")
      let sgd: Set<String> = ["$", "S$", "SGD"]
      let foreign = (prefix.map { !sgd.contains($0) } ?? false)
        || (marker.map { $0 != "CR" && $0 != "DR" && $0 != "SGD" } ?? false)
      let inflow = group(match, 2, in: rest) == "+" || group(match, 4, in: rest) == "+" || marker == "CR"
      tokens.insert(Token(magnitude: magnitude, isInflow: inflow, isForeign: foreign), at: 0)
      rest = (group(match, 1, in: rest) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
    }
    guard !tokens.isEmpty else {
      return .none
    }

    let local = tokens.filter { !$0.isForeign }
    let hasForeign = local.count != tokens.count
    let chosen: Token
    if local.isEmpty {
      return .amount(ParsedAmount(text: rest, magnitude: tokens[0].magnitude, isInflow: false, isForeign: true))
    } else if hasForeign {
      guard local.count == 1 else {
        return .dropped
      }
      chosen = local[0]
    } else if local.count <= 2 {
      chosen = local[0]
    } else {
      return .dropped
    }
    guard let value = Decimal(string: chosen.magnitude), value > 0 else {
      return .dropped
    }
    return .amount(ParsedAmount(text: rest, magnitude: chosen.magnitude, isInflow: chosen.isInflow, isForeign: false))
  }
}
