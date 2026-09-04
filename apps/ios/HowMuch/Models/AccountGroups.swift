import Foundation

/// YNAB account types the create-account write accepts. Cash / Credit / Tracking
/// on Accounts are derived from these, not from a parallel string set.
enum AccountKind: String, CaseIterable, Identifiable, Hashable {
  case checking
  case savings
  case cash
  case creditCard
  case lineOfCredit
  case mortgage
  case autoLoan
  case studentLoan
  case medicalDebt
  case otherLoan
  case otherAsset
  case otherLiability

  var id: String { rawValue }

  var title: String {
    switch self {
    case .checking: "Checking"
    case .savings: "Savings"
    case .cash: "Cash"
    case .creditCard: "Credit Card"
    case .lineOfCredit: "Line of Credit"
    case .mortgage: "Mortgage"
    case .autoLoan: "Auto Loan"
    case .studentLoan: "Student Loan"
    case .medicalDebt: "Medical Debt"
    case .otherLoan: "Other Loan"
    case .otherAsset: "Other Asset"
    case .otherLiability: "Other Liability"
    }
  }

  enum Group: String, CaseIterable, Identifiable {
    case budget
    case tracking

    var id: String { rawValue }

    var title: String {
      switch self {
      case .budget: "Budget"
      case .tracking: "Tracking"
      }
    }

    var footer: String {
      switch self {
      case .budget: "Cash, savings, and cards on the plan."
      case .tracking: "Loans and assets that sit off the plan."
      }
    }
  }

  var placeholderName: String {
    switch self {
    case .checking: "Everyday Account"
    case .savings: "Rainy Day Saver"
    case .cash: "Wallet"
    case .creditCard: "Travel Card"
    case .lineOfCredit: "Overdraft"
    case .mortgage: "Home Loan"
    case .autoLoan: "Car Loan"
    case .studentLoan: "Student Loan"
    case .medicalDebt: "Medical"
    case .otherLoan: "Loan"
    case .otherAsset: "Investment"
    case .otherLiability: "Liability"
    }
  }

  var defaultIcon: AccountIcon {
    AccountIcon.default(for: rawValue)
  }

  var group: Group {
    switch self {
    case .checking, .savings, .cash, .creditCard, .lineOfCredit:
      .budget
    case .mortgage, .autoLoan, .studentLoan, .medicalDebt, .otherLoan, .otherAsset, .otherLiability:
      .tracking
    }
  }

  var onBudget: Bool {
    group == .budget
  }

  var storesLiability: Bool {
    switch self {
    case .creditCard, .lineOfCredit, .mortgage, .autoLoan, .studentLoan, .medicalDebt, .otherLoan, .otherLiability:
      true
    case .checking, .savings, .cash, .otherAsset:
      false
    }
  }

  var isCash: Bool {
    switch self {
    case .checking, .savings, .cash: true
    default: false
    }
  }

  var isCredit: Bool {
    switch self {
    case .creditCard, .lineOfCredit: true
    default: false
    }
  }

  /// Cards and loans store what you owe as a negative balance. The sheet asks
  /// for the amount owed; this turns that entry into the POST `balance`.
  func openingBalanceMilliunits(fromEntered entered: Int) -> Int {
    storesLiability ? -abs(entered) : entered
  }

  static func kinds(in group: Group) -> [AccountKind] {
    allCases.filter { $0.group == group }
  }
}

/// Create only produces `.kind`. Imported YNAB types without an `AccountKind`
/// (`personalLoan`, `otherDebt`, `payPal`) stay `.imported` until a kind is picked.
enum AccountClassification: Hashable {
  case kind(AccountKind)
  case imported(type: String)

  init(type: String) {
    self = AccountKind(rawValue: type).map(Self.kind) ?? .imported(type: type)
  }

  var type: String {
    switch self {
    case .kind(let kind): kind.rawValue
    case .imported(let type): type
    }
  }

  var kind: AccountKind? {
    if case .kind(let kind) = self { return kind }
    return nil
  }

  var title: String {
    switch self {
    case .kind(let kind):
      kind.title
    case .imported(let type):
      Self.humanized(type)
    }
  }

  var defaultIcon: AccountIcon {
    AccountIcon.default(for: type)
  }

  private static func humanized(_ type: String) -> String {
    type.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }
}

/// Built-in account sections. Favourites is a user collection.
/// Cash, Credit, Tracking, and Closed are a type index.
enum AccountSystemGroup: String, CaseIterable, Identifiable {
  case favourites
  case cash
  case credit
  case tracking
  case closed

  var id: String { rawValue }

  var title: String {
    switch self {
    case .favourites: "Favourites"
    case .cash: "Cash"
    case .credit: "Credit"
    case .tracking: "Tracking"
    case .closed: "Closed"
    }
  }

  static var cashTypes: Set<String> {
    Set(AccountKind.allCases.filter(\.isCash).map(\.rawValue))
  }

  static var creditTypes: Set<String> {
    Set(AccountKind.allCases.filter(\.isCredit).map(\.rawValue))
  }

  func contains(_ account: Account, favouriteIDs: Set<String>) -> Bool {
    switch self {
    case .favourites:
      return !account.closed && favouriteIDs.contains(account.id)
    case .cash:
      return !account.closed && Self.cashTypes.contains(account.type)
    case .credit:
      return !account.closed && Self.creditTypes.contains(account.type)
    case .tracking:
      return !account.closed && !Self.cashTypes.contains(account.type) && !Self.creditTypes.contains(account.type)
    case .closed:
      return account.closed
    }
  }
}

enum AccountListGroupKind: Equatable {
  case collection
  case index
}

/// One Favourites, custom, or type-index section on Accounts and in pickers.
struct AccountListGroup: Identifiable, Equatable {
  let id: String
  let title: String
  let accounts: [Account]
  let customGroup: CustomAccountGroup?

  init(id: String, title: String, accounts: [Account], customGroup: CustomAccountGroup? = nil) {
    self.id = id
    self.title = title
    self.accounts = accounts
    self.customGroup = customGroup
  }

  var kind: AccountListGroupKind {
    id == AccountSystemGroup.favourites.rawValue || customGroup != nil ? .collection : .index
  }

  var total: Int {
    accounts.reduce(0) { $0 + $1.balance }
  }

  func matching(_ search: String) -> AccountListGroup? {
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let matches = trimmed.isEmpty
      ? accounts
      : accounts.filter { $0.name.localizedStandardContains(trimmed) }
    guard !matches.isEmpty else {
      return nil
    }
    return AccountListGroup(id: id, title: title, accounts: matches, customGroup: customGroup)
  }

  /// Favourites and custom groups, then the Cash / Credit / Tracking / Closed
  /// type index. Empty index sections are omitted unless asked for; empty
  /// custom groups stay visible on Accounts so a new group can receive members.
  static func build(
    accounts: [Account],
    favouriteIDs: Set<String>,
    customGroups: [CustomAccountGroup],
    includeClosed: Bool = true,
    includeEmptySystemGroups: Bool = false,
    includeEmptyCustomGroups: Bool = true,
    orderedAccounts: ([Account], String) -> [Account]
  ) -> [AccountListGroup] {
    var groups: [AccountListGroup] = []

    let systemGroups: [AccountSystemGroup] = includeClosed
      ? AccountSystemGroup.allCases
      : AccountSystemGroup.allCases.filter { $0 != .closed }

    if let favourites = systemGroups.first(where: { $0 == .favourites }) {
      append(
        system: favourites,
        from: accounts,
        favouriteIDs: favouriteIDs,
        includeEmpty: includeEmptySystemGroups,
        orderedAccounts: orderedAccounts,
        into: &groups
      )
    }

    for custom in customGroups {
      let members = accounts.filter { account in
        custom.accountIDs.contains(account.id) && (includeClosed || !account.closed)
      }
      let ordered = orderedAccounts(members, custom.id)
      if includeEmptyCustomGroups || !ordered.isEmpty {
        groups.append(AccountListGroup(id: custom.id, title: custom.name, accounts: ordered, customGroup: custom))
      }
    }

    for system in systemGroups where system != .favourites {
      append(
        system: system,
        from: accounts,
        favouriteIDs: favouriteIDs,
        includeEmpty: includeEmptySystemGroups,
        orderedAccounts: orderedAccounts,
        into: &groups
      )
    }

    return groups
  }

  private static func append(
    system: AccountSystemGroup,
    from accounts: [Account],
    favouriteIDs: Set<String>,
    includeEmpty: Bool,
    orderedAccounts: ([Account], String) -> [Account],
    into groups: inout [AccountListGroup]
  ) {
    let members = orderedAccounts(
      accounts.filter { system.contains($0, favouriteIDs: favouriteIDs) },
      system.id
    )
    if includeEmpty || !members.isEmpty {
      groups.append(AccountListGroup(id: system.id, title: system.title, accounts: members))
    }
  }
}

func accountNameOrder(_ first: Account, _ second: Account) -> Bool {
  let comparison = first.name.localizedStandardCompare(second.name)
  return comparison == .orderedSame ? first.id < second.id : comparison == .orderedAscending
}
