import Foundation

struct RegisterSearchLine: Equatable {
  var payeeName: String?
  var memo: String?
  var categoryName: String?
  var amountMilli: Int?
}

struct RegisterSearchFields: Equatable {
  var payeeName: String?
  var memo: String?
  var categoryName: String?
  var accountName: String?
  var amountMilli: Int?
  var lines: [RegisterSearchLine] = []
}

struct RegisterQuery: Equatable {
  struct AmountRange: Equatable {
    enum Sign: Equatable {
      case any
      case inflow
      case outflow
    }

    var lo: Int
    var hi: Int
    var sign: Sign
  }

  var raw: String
  var text: String
  var amount: AmountRange?

  static func parse(_ raw: String, currencyFormat: CurrencyFormat?) -> RegisterQuery? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    return RegisterQuery(
      raw: trimmed,
      text: trimmed,
      amount: parseAmountRange(trimmed, currencyFormat: currencyFormat)
    )
  }

  func matches(_ fields: RegisterSearchFields) -> Bool {
    if containsText(fields) {
      return true
    }
    guard let amount else {
      return false
    }
    if amountMatches(amount, amountMilli: fields.amountMilli) {
      return true
    }
    return fields.lines.contains { amountMatches(amount, amountMilli: $0.amountMilli) }
  }

  private func containsText(_ fields: RegisterSearchFields) -> Bool {
    var haystack: [String?] = [fields.payeeName, fields.memo, fields.categoryName, fields.accountName]
    haystack.append(contentsOf: fields.lines.flatMap { [$0.payeeName, $0.memo, $0.categoryName] })
    return haystack.contains { $0?.localizedStandardContains(text) == true }
  }
}

extension Transaction {
  var registerSearchFields: RegisterSearchFields {
    RegisterSearchFields(
      payeeName: payeeName,
      memo: memo,
      categoryName: categoryName,
      accountName: accountName,
      amountMilli: amount,
      lines: subtransactions.map {
        RegisterSearchLine(payeeName: $0.payeeName, memo: $0.memo, categoryName: $0.categoryName, amountMilli: $0.amount)
      }
    )
  }
}

extension PendingRow {
  var registerSearchFields: RegisterSearchFields {
    RegisterSearchFields(
      payeeName: payeeName,
      memo: memo,
      categoryName: categoryName,
      accountName: accountName,
      amountMilli: signedAmount
    )
  }
}

private func parseAmountRange(_ raw: String, currencyFormat: CurrencyFormat?) -> RegisterQuery.AmountRange? {
  var source = raw.replacingOccurrences(of: "\u{2212}", with: "-")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  var sign: RegisterQuery.AmountRange.Sign = .any
  if source.hasPrefix("+") {
    sign = .inflow
    source.removeFirst()
    source = source.trimmingCharacters(in: .whitespacesAndNewlines)
  } else if source.hasPrefix("-") {
    sign = .outflow
    source.removeFirst()
    source = source.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  let symbol = currencyFormat?.currencySymbol ?? "$"
  if !symbol.isEmpty, source.hasPrefix(symbol) {
    source.removeFirst(symbol.count)
    source = source.trimmingCharacters(in: .whitespacesAndNewlines)
  } else if !symbol.isEmpty, source.hasSuffix(symbol) {
    source.removeLast(symbol.count)
    source = source.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  if sign == .any, source.hasPrefix("-") {
    sign = .outflow
    source.removeFirst()
    source = source.trimmingCharacters(in: .whitespacesAndNewlines)
  } else if sign == .any, source.hasPrefix("+") {
    sign = .inflow
    source.removeFirst()
    source = source.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  let groupSeparator = currencyFormat?.groupSeparator ?? ","
  if !groupSeparator.isEmpty {
    source = source.replacingOccurrences(of: groupSeparator, with: "")
  }

  let decimalSeparator = currencyFormat?.decimalSeparator ?? "."
  let parts = source.split(separator: Character(decimalSeparator), omittingEmptySubsequences: false)
  guard parts.count <= 2, let wholePart = parts.first, wholePart.allSatisfy(\.isNumber) else {
    return nil
  }
  if parts.count == 2, !parts[1].allSatisfy(\.isNumber) {
    return nil
  }
  let fraction = parts.count == 2 ? String(parts[1]) : nil
  guard let whole = Int(wholePart) else {
    return nil
  }
  let typedFractionDigits = min(fraction?.count ?? 0, 3)
  let paddedFraction = (fraction ?? "").padding(toLength: 3, withPad: "0", startingAt: 0)
  let fractionValue = Int(paddedFraction.prefix(3)) ?? 0
  let lo = whole * 1000 + fractionValue
  let step = Int(pow(10.0, Double(3 - typedFractionDigits)))
  return RegisterQuery.AmountRange(lo: lo, hi: lo + step, sign: sign)
}

private func amountMatches(_ range: RegisterQuery.AmountRange, amountMilli: Int?) -> Bool {
  guard let amountMilli else {
    return false
  }
  if range.sign == .outflow, amountMilli >= 0 {
    return false
  }
  if range.sign == .inflow, amountMilli <= 0 {
    return false
  }
  let magnitude = abs(amountMilli)
  return magnitude >= range.lo && magnitude < range.hi
}

func registerSearchStatusCopy(shown: Int, scheduled: Int, hasMore: Bool, loading: Bool, error: String?) -> String {
  if loading {
    return "Searching all transactions…"
  }
  if error != nil {
    return "Couldn’t search older transactions. Showing matches from recent transactions."
  }
  if hasMore {
    return "Showing \(shown) matches so far. Load older matches to see more."
  }
  let transactionWord = shown == 1 ? "transaction" : "transactions"
  if scheduled == 0 {
    return "\(shown) matching \(transactionWord)"
  }
  let scheduledWord = scheduled == 1 ? "scheduled transaction" : "scheduled transactions"
  return "\(shown) matching \(transactionWord) and \(scheduled) \(scheduledWord)"
}
