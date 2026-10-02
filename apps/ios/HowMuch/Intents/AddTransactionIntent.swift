import AppIntents
import Foundation

struct AddTransactionIntent: AppIntent {
  static var title: LocalizedStringResource = "Add Transaction"
  static var description = IntentDescription(
    "Opens Halation with a transaction ready to review and save. Nothing is saved until you tap Save."
  )
  static let supportedModes: IntentModes = .foreground(.immediate)

  @Parameter(title: "Amount")
  var amount: Double?

  @Parameter(title: "Direction", optionsProvider: DirectionNameOptions())
  var direction: String?

  @Parameter(title: "Account", optionsProvider: AccountNameOptions())
  var account: String?

  @Parameter(title: "Payee", optionsProvider: PayeeNameOptions())
  var payee: String?

  @Parameter(title: "Category", optionsProvider: CategoryNameOptions())
  var category: String?

  @Parameter(title: "Date", kind: .date)
  var date: Date?

  @Parameter(title: "Flag", optionsProvider: FlagNameOptions())
  var flag: String?

  @Parameter(title: "Memo")
  var memo: String?

  @Parameter(title: "Cleared")
  var cleared: Bool?

  static var parameterSummary: some ParameterSummary {
    Summary("Add \(\.$amount)") {
      \.$direction
      \.$account
      \.$payee
      \.$category
      \.$date
      \.$flag
      \.$memo
      \.$cleared
    }
  }

  private static func decimal(from amount: Double?) -> Decimal? {
    guard let amount else {
      return nil
    }
    return Decimal(string: String(amount), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(amount)
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    let catalog = IntentCatalogStore.shared.loadActive()
    do {
      let request = try AddTransactionIntentBuilder.request(
        amount: Self.decimal(from: amount),
        direction: AddTransactionIntentBuilder.entryDirection(from: direction),
        accountID: account,
        payee: AddTransactionIntentBuilder.payeeInput(from: payee, catalog: catalog),
        categoryID: category,
        date: date,
        flag: AddTransactionIntentBuilder.flagColour(from: flag),
        memo: memo,
        cleared: cleared,
        catalog: catalog
      )
      CaptureRouter.shared.enqueue(request)
      return .result()
    } catch AddTransactionIntentBuilder.Error.tooManyFractionDigits {
      throw $amount.needsValueError()
    }
  }
}

struct DirectionNameOptions: DynamicOptionsProvider {
  func results() async throws -> [String] {
    ["Outflow", "Inflow"]
  }
}

struct FlagNameOptions: DynamicOptionsProvider {
  func results() async throws -> [String] {
    IntentFlag.allCases.map(\.title)
  }
}

enum IntentFlag: String, CaseIterable {
  case none
  case red
  case orange
  case yellow
  case green
  case blue
  case purple

  var title: String {
    switch self {
    case .none:
      return "None"
    case .red:
      return "Red"
    case .orange:
      return "Orange"
    case .yellow:
      return "Yellow"
    case .green:
      return "Green"
    case .blue:
      return "Blue"
    case .purple:
      return "Purple"
    }
  }

  var flagColour: FlagColour {
    switch self {
    case .none:
      return .none
    case .red:
      return .red
    case .orange:
      return .orange
    case .yellow:
      return .yellow
    case .green:
      return .green
    case .blue:
      return .blue
    case .purple:
      return .purple
    }
  }
}

enum AddTransactionIntentBuilder {
  enum Error: Swift.Error {
    case tooManyFractionDigits
  }

  struct PayeeInput: Equatable {
    var id: String
    var name: String
    var transferAccountId: String?
    var isNew: Bool
  }

  static func entryDirection(from raw: String?) -> EntryDirection? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    if trimmed.localizedCaseInsensitiveContains("inflow") {
      return .inflow
    }
    if trimmed.localizedCaseInsensitiveContains("outflow") {
      return .outflow
    }
    return nil
  }

  static func flagColour(from raw: String?) -> FlagColour? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return IntentFlag.allCases.first(where: {
      $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
        || $0.title.caseInsensitiveCompare(trimmed) == .orderedSame
    })?.flagColour
  }

  static func payeeInput(from raw: String?, catalog: IntentCatalogSnapshot?) -> PayeeInput? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    if let name = PayeeEntityQuery.newPayeeName(from: trimmed) {
      return PayeeInput(id: trimmed, name: name, transferAccountId: nil, isNew: true)
    }
    let name = unwrapCreatedPayeeName(trimmed)
    if let live = catalog?.pickerPayees.first(where: {
      $0.id == name || $0.name.caseInsensitiveCompare(name) == .orderedSame
    }) {
      return PayeeInput(
        id: live.id,
        name: live.name,
        transferAccountId: live.transferAccountId,
        isNew: false
      )
    }
    return PayeeInput(
      id: PayeeEntityQuery.newPayeeID(for: name),
      name: name,
      transferAccountId: nil,
      isNew: true
    )
  }

  static func unwrapCreatedPayeeName(_ raw: String) -> String {
    if raw.hasPrefix("Create “"), raw.hasSuffix("”") {
      return String(raw.dropFirst(8).dropLast(1))
    }
    if raw.hasPrefix("Create \""), raw.hasSuffix("\"") {
      return String(raw.dropFirst(8).dropLast(1))
    }
    return raw
  }

  static func request(
    amount: Decimal?,
    direction: EntryDirection?,
    accountID: String?,
    payee: PayeeInput?,
    categoryID: String?,
    date: Date?,
    flag: FlagColour?,
    memo: String?,
    cleared: Bool?,
    catalog: IntentCatalogSnapshot?
  ) throws -> CaptureRequest {
    return CaptureRequest(
      kind: .manual(
        try draft(
          amount: amount,
          direction: direction,
          accountID: accountID,
          payee: payee,
          categoryID: categoryID,
          date: date,
          flag: flag,
          memo: memo,
          cleared: cleared,
          catalog: catalog
        )
      ),
      connectionFingerprint: catalog?.connectionFingerprint,
      origin: accountID == nil ? .lastUsedOpen : .presetDraft
    )
  }

  static func draft(
    amount: Decimal?,
    direction: EntryDirection?,
    accountID: String?,
    payee: PayeeInput?,
    categoryID: String?,
    date: Date?,
    flag: FlagColour?,
    memo: String?,
    cleared: Bool?,
    catalog: IntentCatalogSnapshot?
  ) throws -> TransactionDraft {
    var draft = TransactionDraft()
    draft.direction = direction ?? .outflow
    if let amount {
      guard let milli = MoneyCodec.milliunits(from: amount) else {
        throw Error.tooManyFractionDigits
      }
      draft.amountMagnitudeMilli = milli
    }
    if let accountID, let resolved = Self.resolveAccount(accountID, catalog: catalog) {
      draft.accountID = resolved
    }
    if let date {
      draft.date = date
    }
    draft.flag = flag ?? .none
    if let memo {
      draft.memo = memo
    }
    draft.isCleared = cleared ?? false

    applyPayee(payee, to: &draft, catalog: catalog)
    if draft.transferAccountID == nil,
       let categoryID,
       let resolved = Self.resolveCategory(categoryID, catalog: catalog) {
      draft.categoryID = resolved
    }
    return draft
  }

  /// Shortcuts hands display names. Without a catalog those names are not
  /// ledger IDs — leaving them on the draft would enable Save on Choose Account.
  private static func resolveAccount(_ raw: String, catalog: IntentCatalogSnapshot?) -> String? {
    guard let catalog else {
      return nil
    }
    let accounts = catalog.openAccounts
    if accounts.contains(where: { $0.id == raw }) {
      return raw
    }
    return accounts.first { $0.name.caseInsensitiveCompare(raw) == .orderedSame }?.id
  }

  private static func resolveCategory(_ raw: String, catalog: IntentCatalogSnapshot?) -> String? {
    guard let catalog else {
      return nil
    }
    let categories = catalog.pickerCategories
    if categories.contains(where: { $0.id == raw }) {
      return raw
    }
    return categories.first { $0.name.caseInsensitiveCompare(raw) == .orderedSame }?.id
  }

  private static func applyPayee(
    _ payee: PayeeInput?,
    to draft: inout TransactionDraft,
    catalog: IntentCatalogSnapshot?
  ) {
    guard let payee else {
      return
    }
    if payee.isNew || PayeeEntityQuery.newPayeeName(from: payee.id) != nil {
      let name = PayeeEntityQuery.newPayeeName(from: payee.id) ?? payee.name
      draft.payeeName = name
      draft.payeeID = nil
      return
    }
    guard let live = catalog?.pickerPayees.first(where: {
      $0.id == payee.id
        || $0.name.caseInsensitiveCompare(payee.name) == .orderedSame
        || $0.name.caseInsensitiveCompare(payee.id) == .orderedSame
    }) else {
      guard catalog == nil else {
        return
      }
      draft.payeeID = payee.id
      draft.payeeName = payee.name
      draft.transferAccountID = payee.transferAccountId
      if payee.transferAccountId == draft.accountID {
        draft.transferAccountID = nil
        draft.payeeID = nil
        draft.payeeName = ""
      }
      return
    }
    draft.payeeID = live.id
    draft.payeeName = live.name
    draft.transferAccountID = live.transferAccountId
    guard let transferAccountID = live.transferAccountId else {
      return
    }
    if transferAccountID == draft.accountID {
      draft.transferAccountID = nil
      draft.payeeID = nil
      draft.payeeName = ""
      return
    }
    if bothOnBudget(draft.accountID, transferAccountID, catalog: catalog) {
      draft.categoryID = nil
    }
  }

  private static func bothOnBudget(
    _ firstID: String,
    _ secondID: String,
    catalog: IntentCatalogSnapshot?
  ) -> Bool {
    guard
      let first = catalog?.accounts.first(where: { $0.id == firstID }),
      let second = catalog?.accounts.first(where: { $0.id == secondID })
    else {
      return false
    }
    return first.onBudget && second.onBudget
  }
}
