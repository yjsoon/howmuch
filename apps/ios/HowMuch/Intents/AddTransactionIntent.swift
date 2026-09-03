import AppIntents
import Foundation

struct AddTransactionIntent: AppIntent {
  static var title: LocalizedStringResource = "Add Transaction"
  static var description = IntentDescription(
    "Opens HowMuch with a transaction ready to review and save. Nothing is saved until you tap Save."
  )
  static let supportedModes: IntentModes = .foreground(.immediate)

  @Parameter(title: "Amount")
  var amount: Double?

  @Parameter(title: "Direction")
  var direction: EntryDirection?

  @Parameter(title: "Account")
  var account: AccountEntity?

  @Parameter(title: "Payee")
  var payee: PayeeEntity?

  @Parameter(title: "Category")
  var category: CategoryEntity?

  @Parameter(title: "Date", kind: .date)
  var date: Date?

  @Parameter(title: "Flag")
  var flag: IntentFlag?

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
        direction: direction,
        accountID: account?.id,
        payee: payee.map {
          AddTransactionIntentBuilder.PayeeInput(
            id: $0.id,
            name: $0.name,
            transferAccountId: $0.transferAccountId,
            isNew: $0.isNew
          )
        },
        categoryID: category?.id,
        date: date,
        flag: flag?.flagColour,
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

extension EntryDirection: AppEnum {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Direction"

  static let caseDisplayRepresentations: [EntryDirection: DisplayRepresentation] = [
    .outflow: "Outflow",
    .inflow: "Inflow",
  ]
}

enum IntentFlag: String, AppEnum, CaseIterable {
  case none
  case red
  case orange
  case yellow
  case green
  case blue
  case purple

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Flag"

  static let caseDisplayRepresentations: [IntentFlag: DisplayRepresentation] = [
    .none: "None",
    .red: "Red",
    .orange: "Orange",
    .yellow: "Yellow",
    .green: "Green",
    .blue: "Blue",
    .purple: "Purple",
  ]

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
    let isBare = amount == nil
      && accountID == nil
      && payee == nil
      && categoryID == nil
      && date == nil
      && (flag == nil || flag == .none)
      && (memo == nil || memo?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
      && (cleared == nil || cleared == false)
      && (direction == nil || direction == .outflow)
    let fingerprint = catalog?.connectionFingerprint
    if isBare {
      return CaptureRequest(kind: .blank, connectionFingerprint: fingerprint)
    }
    return CaptureRequest(
      kind: .draft(
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
      connectionFingerprint: fingerprint
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

  /// Stale IDs drop only when a catalog is present. A missing catalog must
  /// keep the pick. Shortcuts may also hand a display name instead of an id.
  private static func resolveAccount(_ raw: String, catalog: IntentCatalogSnapshot?) -> String? {
    guard let catalog else {
      return raw
    }
    let accounts = catalog.openAccounts
    if accounts.contains(where: { $0.id == raw }) {
      return raw
    }
    return accounts.first { $0.name.caseInsensitiveCompare(raw) == .orderedSame }?.id
  }

  private static func resolveCategory(_ raw: String, catalog: IntentCatalogSnapshot?) -> String? {
    guard let catalog else {
      return raw
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
