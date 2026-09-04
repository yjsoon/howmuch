import AppIntents

struct AccountEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Account")
  }

  static var defaultQuery = AccountEntityQuery()

  var id: String
  @Property(title: "Name")
  var name: String

  init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
  }
}

struct AccountNameOptions: DynamicOptionsProvider {
  func results() async throws -> [String] {
    (IntentCatalogStore.shared.loadActive()?.openAccounts ?? []).map(\.name)
  }
}

struct AccountEntityQuery: EntityStringQuery {
  func entities(for identifiers: [AccountEntity.ID]) async throws -> [AccountEntity] {
    Self.resolved(identifiers, catalog: IntentCatalogStore.shared.loadActive())
  }

  func entities(matching string: String) async throws -> [AccountEntity] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    let accounts = IntentCatalogStore.shared.loadActive()?.openAccounts ?? []
    guard !trimmed.isEmpty else {
      return try await suggestedEntities()
    }
    return accounts
      .filter {
        $0.id == trimmed || $0.name.localizedStandardContains(trimmed)
      }
      .map { AccountEntity(id: $0.id, name: $0.name) }
  }

  /// App Intents drops a parameter when this returns fewer entities than
  /// identifiers. Match id or display name, and never drop a pick.
  static func resolved(
    _ identifiers: [AccountEntity.ID],
    catalog: IntentCatalogSnapshot?
  ) -> [AccountEntity] {
    let accounts = catalog?.openAccounts ?? []
    return identifiers.map { id in
      if let live = accounts.first(where: {
        $0.id == id || $0.name.caseInsensitiveCompare(id) == .orderedSame
      }) {
        return AccountEntity(id: live.id, name: live.name)
      }
      return AccountEntity(id: id, name: id)
    }
  }

  func suggestedEntities() async throws -> [AccountEntity] {
    (IntentCatalogStore.shared.loadActive()?.openAccounts ?? []).map {
      AccountEntity(id: $0.id, name: $0.name)
    }
  }
}
