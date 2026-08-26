import Foundation

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

  static let cashTypes: Set<String> = ["checking", "savings", "cash"]
  static let creditTypes: Set<String> = ["creditCard", "lineOfCredit"]

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
