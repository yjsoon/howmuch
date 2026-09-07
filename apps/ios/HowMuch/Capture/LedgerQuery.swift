import Foundation

enum LedgerQueryKind: String, Equatable, Codable, Sendable {
  case spendingThisMonth
  case spending
  case today
  case compareCategory
  case findMerchant
  case unsupported
}

struct LedgerQuerySpec: Equatable, Codable, Sendable {
  var kind: LedgerQueryKind
  var category: String
  var account: String
  var merchant: String
  var from: String
  var to: String
}

enum LedgerQueryError: Error, Equatable, LocalizedError, Sendable {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let text):
      return text
    }
  }
}

struct LedgerQueryResolution: Equatable, Codable, Sendable {
  var spec: LedgerQuerySpec
  var from: String
  var to: String
  var priorFrom: String?
  var priorTo: String?
  var accountIDs: [String]
  var categoryIDs: [String]
  var accountLabel: String
  var categoryLabel: String
  var unresolvedAccount: [SlipCandidate]
  var unresolvedCategory: [SlipCandidate]
  var categoryWasExplicit: Bool
}

struct LedgerQuerySourceRow: Equatable, Codable, Identifiable, Sendable {
  var id: String
  var date: String
  var payee: String
  var amount: Int
  var accountName: String
  var categoryName: String = ""
  var isSplitPortion: Bool = false
}

struct LedgerQueryResult: Equatable, Codable, Identifiable, Sendable {
  var id: UUID
  var title: String
  var detail: String
  var totalMilliunits: Int
  var comparisonMilliunits: Int?
  var from: String
  var to: String
  var comparisonFrom: String?
  var comparisonTo: String?
  var accountLabel: String
  var categoryLabel: String
  var sourceRows: [LedgerQuerySourceRow]
  var sourceCount: Int
  var isPreview: Bool
  var isRecordedSpending: Bool
  var isUnavailable: Bool

  init(
    id: UUID = UUID(),
    title: String,
    detail: String,
    totalMilliunits: Int,
    comparisonMilliunits: Int? = nil,
    from: String,
    to: String,
    comparisonFrom: String? = nil,
    comparisonTo: String? = nil,
    accountLabel: String,
    categoryLabel: String,
    sourceRows: [LedgerQuerySourceRow] = [],
    sourceCount: Int = 0,
    isPreview: Bool = false,
    isRecordedSpending: Bool,
    isUnavailable: Bool
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.totalMilliunits = totalMilliunits
    self.comparisonMilliunits = comparisonMilliunits
    self.from = from
    self.to = to
    self.comparisonFrom = comparisonFrom
    self.comparisonTo = comparisonTo
    self.accountLabel = accountLabel
    self.categoryLabel = categoryLabel
    self.sourceRows = sourceRows
    self.sourceCount = sourceCount
    self.isPreview = isPreview
    self.isRecordedSpending = isRecordedSpending
    self.isUnavailable = isUnavailable
  }
}

enum LedgerQueryPlanner {
  static func capabilityError(for spec: LedgerQuerySpec) -> LedgerQueryError? {
    if spec.kind == .unsupported {
      return .message("I can answer recorded spending for a date range, compare a category with the previous period, or find a merchant’s recent payments. I cannot change saved transactions.")
    }
    let namedMerchant = spec.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
    if !namedMerchant.isEmpty {
      switch spec.kind {
      case .spending, .today, .spendingThisMonth, .compareCategory:
        return .message("I can look up a merchant’s recent payments, but I cannot filter spending reports or category comparisons by merchant.")
      case .findMerchant, .unsupported:
        break
      }
    }
    return nil
  }

  static func resolve(
    spec: LedgerQuerySpec,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    calendar: Calendar = .current,
    now: Date = .now
  ) -> Result<LedgerQueryResolution, LedgerQueryError> {
    let historical = accounts.filter { !$0.deleted }
    let today = calendar.startOfDay(for: now)
    let monthStart = today.startOfMonth(calendar: calendar)
    let formatter = isoFormatter(calendar: calendar)

    if let error = capabilityError(for: spec) {
      return .failure(error)
    }

    let suppliedFrom = parseISO(spec.from, calendar: calendar)
    let suppliedTo = parseISO(spec.to, calendar: calendar)
    if !spec.from.isEmpty && suppliedFrom == nil {
      return .failure(.message("I could not read the start date “\(spec.from)”."))
    }
    if !spec.to.isEmpty && suppliedTo == nil {
      return .failure(.message("I could not read the end date “\(spec.to)”."))
    }
    if let suppliedFrom, let suppliedTo, suppliedFrom > suppliedTo {
      return .failure(.message("The start date is after the end date. Nothing was queried."))
    }

    var from = spec.from
    var to = spec.to
    var priorFrom: String?
    var priorTo: String?

    switch spec.kind {
    case .today:
      let todayText = formatter.string(from: today)
      if let suppliedFrom, formatter.string(from: suppliedFrom) != todayText {
        return .failure(.message("That request mixes today with a different start date. Nothing was queried."))
      }
      if let suppliedTo, formatter.string(from: suppliedTo) != todayText {
        return .failure(.message("That request mixes today with a different end date. Nothing was queried."))
      }
      from = todayText
      to = todayText
    case .spendingThisMonth:
      from = suppliedFrom.map { formatter.string(from: $0) } ?? formatter.string(from: monthStart)
      to = suppliedTo.map { formatter.string(from: $0) } ?? formatter.string(from: today)
    case .spending:
      from = suppliedFrom.map { formatter.string(from: $0) } ?? formatter.string(from: monthStart)
      to = suppliedTo.map { formatter.string(from: $0) } ?? formatter.string(from: today)
    case .compareCategory:
      from = suppliedFrom.map { formatter.string(from: $0) } ?? formatter.string(from: monthStart)
      to = suppliedTo.map { formatter.string(from: $0) } ?? formatter.string(from: today)
    case .findMerchant:
      from = suppliedFrom.map { formatter.string(from: $0) }
        ?? formatter.string(from: calendar.date(byAdding: .month, value: -3, to: today) ?? monthStart)
      to = suppliedTo.map { formatter.string(from: $0) } ?? formatter.string(from: today)
    case .unsupported:
      break
    }

    guard let finalFrom = parseISO(from, calendar: calendar), let finalTo = parseISO(to, calendar: calendar) else {
      return .failure(.message("I could not read those dates. Nothing was queried."))
    }
    if finalFrom > finalTo {
      return .failure(.message("The start date is after the end date. Nothing was queried."))
    }
    from = formatter.string(from: finalFrom)
    to = formatter.string(from: finalTo)

    if spec.kind == .compareCategory {
      let days = calendar.dateComponents([.day], from: finalFrom, to: finalTo).day ?? 0
      let priorEnd = calendar.date(byAdding: .day, value: -1, to: finalFrom) ?? finalFrom
      let priorStart = calendar.date(byAdding: .day, value: -days, to: priorEnd) ?? priorEnd
      priorFrom = formatter.string(from: priorStart)
      priorTo = formatter.string(from: priorEnd)
    }

    let accountMatch = resolveNames(spec.account, in: historical.map { ($0.id, $0.name) })
    if case .unknown(let name) = accountMatch {
      return .failure(.message("I do not recognise the account “\(name)”. Nothing was guessed."))
    }

    var live = categoryGroups.filter { !$0.deleted }.flatMap { group in
      group.categories.filter { !$0.deleted }.map { (id: $0.id, name: $0.name) }
    }
    live.append((id: CategoryGroup.uncategorisedCategoryID, name: "Uncategorised"))
    let categoryMatch = resolveNames(spec.category, in: live)
    if case .unknown(let name) = categoryMatch {
      return .failure(.message("I do not recognise the category “\(name)”. Nothing was guessed."))
    }

    var unresolvedAccount: [SlipCandidate] = []
    var accountIDs: [String] = []
    var accountLabel = "All accounts"
    switch accountMatch {
    case .none:
      break
    case .unique(let id, let name):
      accountIDs = [id]
      accountLabel = name
    case .ambiguous(let candidates):
      unresolvedAccount = candidates
    case .unknown:
      break
    }

    var unresolvedCategory: [SlipCandidate] = []
    var categoryIDs: [String] = []
    var categoryLabel = "Recorded spending"
    switch categoryMatch {
    case .none:
      break
    case .unique(let id, let name):
      categoryIDs = [id]
      categoryLabel = name
    case .ambiguous(let candidates):
      unresolvedCategory = candidates
    case .unknown:
      break
    }

    if spec.kind == .compareCategory && categoryIDs.isEmpty && unresolvedCategory.isEmpty {
      return .failure(.message("Which category should I compare with the previous period?"))
    }
    if spec.kind == .findMerchant && spec.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .failure(.message("Which merchant should I look for?"))
    }

    return .success(
      LedgerQueryResolution(
        spec: spec,
        from: from,
        to: to,
        priorFrom: priorFrom,
        priorTo: priorTo,
        accountIDs: accountIDs,
        categoryIDs: categoryIDs,
        accountLabel: accountLabel,
        categoryLabel: categoryLabel,
        unresolvedAccount: unresolvedAccount,
        unresolvedCategory: unresolvedCategory,
        categoryWasExplicit: !spec.category.isEmpty
      )
    )
  }

  static func recordedSpendingTotal(
    from report: SpendingBreakdownReport,
    includeQuiet: Bool,
    explicitCategoryIDs: [String] = []
  ) -> Int {
    if !explicitCategoryIDs.isEmpty {
      return report.groups
        .filter { explicitCategoryIDs.contains($0.categoryID) }
        .reduce(0) { $0 + abs($1.amount) }
    }
    let split = ReflectMaths.split(report.groups)
    let rows = includeQuiet ? split.primary + split.quiet : split.primary
    return rows.reduce(0) { $0 + abs($1.amount) }
  }

  static func sourceRows(
    from transactions: [Transaction],
    resolution: LedgerQueryResolution,
    categoryGroups: [CategoryGroup],
    includeQuiet: Bool,
    merchant: String = ""
  ) -> [LedgerQuerySourceRow] {
    let quietNames = Set(
      categoryGroups.filter(\.isQuiet).flatMap { $0.categories.map(\.id) }
    )
    let categoryByID = Dictionary(
      uniqueKeysWithValues: categoryGroups.flatMap(\.categories).map { ($0.id, $0) }
    )
    var rows: [LedgerQuerySourceRow] = []
    for transaction in transactions {
      if transaction.deleted {
        continue
      }
      let liveSubs = transaction.subtransactions.filter { !$0.deleted }
      let lines: [(amount: Int, categoryID: String?, payee: String?, transferAccountID: String?, transferTransactionID: String?, isSplit: Bool)]
      if liveSubs.isEmpty {
        lines = [(
          transaction.amount,
          transaction.categoryID,
          transaction.payeeName ?? transaction.importPayeeName,
          transaction.transferAccountID,
          transaction.transferTransactionID,
          false
        )]
      } else {
        lines = liveSubs.map {
          (
            $0.amount,
            $0.categoryID ?? transaction.categoryID,
            $0.payeeName ?? transaction.payeeName ?? transaction.importPayeeName,
            $0.transferAccountID ?? transaction.transferAccountID,
            $0.transferTransactionID ?? transaction.transferTransactionID,
            true
          )
        }
      }
      for (offset, line) in lines.enumerated() {
        let isUncategorisedTransfer = line.categoryID == nil
          && (line.transferAccountID != nil || line.transferTransactionID != nil)
        if isUncategorisedTransfer {
          continue
        }
        if line.amount >= 0 {
          continue
        }
        if !resolution.accountIDs.isEmpty, !resolution.accountIDs.contains(transaction.accountID) {
          continue
        }
        if !resolution.categoryIDs.isEmpty {
          let wantsUncategorised = resolution.categoryIDs.contains(CategoryGroup.uncategorisedCategoryID)
          let matchesExplicit = line.categoryID.map { resolution.categoryIDs.contains($0) } ?? false
          let matchesUncategorised = wantsUncategorised && line.categoryID == nil
          guard matchesExplicit || matchesUncategorised else {
            continue
          }
        } else if !includeQuiet, let categoryID = line.categoryID, quietNames.contains(categoryID) {
          continue
        }
        if !merchant.isEmpty {
          let hay = "\(line.payee ?? "") \(transaction.payeeName ?? "") \(transaction.importPayeeName ?? "")"
          guard hay.localizedStandardContains(merchant) else {
            continue
          }
        }
        rows.append(
          LedgerQuerySourceRow(
            id: "\(transaction.id)-\(offset)",
            date: transaction.date,
            payee: line.payee ?? transaction.payeeName ?? transaction.importPayeeName ?? "(No payee)",
            amount: line.amount,
            accountName: transaction.accountName,
            categoryName: line.categoryID.flatMap { categoryByID[$0]?.name } ?? "Uncategorised",
            isSplitPortion: line.isSplit
          )
        )
      }
    }
    return rows
  }

  private enum NameMatch {
    case none
    case unique(id: String, name: String)
    case ambiguous([SlipCandidate])
    case unknown(String)
  }

  private static func resolveNames(_ query: String, in items: [(id: String, name: String)]) -> NameMatch {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .none
    }
    let exact = items.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    let matches = exact.isEmpty
      ? items.filter { $0.name.localizedStandardContains(trimmed) }
      : exact
    if matches.count == 1 {
      return .unique(id: matches[0].id, name: matches[0].name)
    }
    if matches.count >= 2 {
      return .ambiguous(matches.prefix(12).map { SlipCandidate(id: $0.id, name: $0.name) })
    }
    return .unknown(trimmed)
  }

  static func isoFormatter(calendar: Calendar) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }

  static func parseISO(_ raw: String, calendar: Calendar) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    guard trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
      return nil
    }
    let parts = trimmed.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2])
    else {
      return nil
    }
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    guard let date = calendar.date(from: components) else {
      return nil
    }
    let rebuilt = calendar.dateComponents([.year, .month, .day], from: date)
    guard rebuilt.year == year, rebuilt.month == month, rebuilt.day == day else {
      return nil
    }
    return calendar.startOfDay(for: date)
  }

  static func applyingChosenIdentities(
    to resolution: LedgerQueryResolution,
    account: SlipCandidate? = nil,
    category: SlipCandidate? = nil
  ) -> LedgerQueryResolution {
    var next = resolution
    if let account {
      next.accountIDs = [account.id]
      next.accountLabel = account.name
      next.unresolvedAccount = []
    }
    if let category {
      next.categoryIDs = [category.id]
      next.categoryLabel = category.name
      next.unresolvedCategory = []
    }
    return next
  }
}

enum LedgerQueryFetchError: Error, Equatable, LocalizedError, Sendable {
  case repeatedOffset
  case missingNextOffset
  case ledgerChanged
  case cancelled
  case emptyPage

  var errorDescription: String? {
    switch self {
    case .repeatedOffset:
      return "The transaction cursor repeated."
    case .missingNextOffset:
      return "More pages were indicated but no next offset was provided."
    case .ledgerChanged:
      return "The ledger changed while this query was loading."
    case .cancelled:
      return "This query was cancelled."
    case .emptyPage:
      return "A transaction page was empty before the final page."
    }
  }
}

enum LedgerQueryRunner {
  static func fetchAllTransactions(
    fetchPage: (Int) async throws -> TransactionPage,
    isCancelled: () -> Bool = { false }
  ) async throws -> [Transaction] {
    var collected: [String: Transaction] = [:]
    var offset = 0
    var seenOffsets = Set<Int>()
    var expectedKnowledge: Int?
    var attempts = 0
    while attempts < 3 {
      if isCancelled() {
        throw LedgerQueryFetchError.cancelled
      }
      guard seenOffsets.insert(offset).inserted else {
        throw LedgerQueryFetchError.repeatedOffset
      }
      let page = try await fetchPage(offset)
      if let knownKnowledge = expectedKnowledge, page.serverKnowledge != knownKnowledge {
        attempts += 1
        collected.removeAll()
        offset = 0
        seenOffsets.removeAll()
        expectedKnowledge = nil
        continue
      }
      if page.hasMore, page.serverKnowledge == nil {
        throw LedgerQueryFetchError.ledgerChanged
      }
      expectedKnowledge = page.serverKnowledge
      for transaction in page.transactions {
        collected[transaction.id] = transaction
      }
      if !page.hasMore {
        return collected.values.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
      }
      guard !page.transactions.isEmpty else {
        throw LedgerQueryFetchError.emptyPage
      }
      guard let next = page.nextOffset else {
        throw LedgerQueryFetchError.missingNextOffset
      }
      guard next > offset else {
        throw LedgerQueryFetchError.repeatedOffset
      }
      offset = next
    }
    throw LedgerQueryFetchError.ledgerChanged
  }

  static func fetchAllTransactions(
    client: APIClient,
    planID: String,
    accountID: String?,
    sinceDate: String,
    untilDate: String,
    isCancelled: () -> Bool = { false }
  ) async throws -> [Transaction] {
    try await fetchAllTransactions(
      fetchPage: { offset in
        try await client.fetchTransactions(
          planID: planID,
          accountID: accountID,
          offset: offset,
          sinceDate: sinceDate,
          untilDate: untilDate
        )
      },
      isCancelled: isCancelled
    )
  }

  static func matchingMerchant(_ transactions: [Transaction], query: String) -> [Transaction] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else {
      return []
    }
    return transactions.filter { transaction in
      (transaction.payeeName ?? "").localizedStandardContains(needle)
        || (transaction.importPayeeName ?? "").localizedStandardContains(needle)
    }
  }
}
