import AppIntents

struct AccountEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Account")
  }

  static var defaultQuery = AccountEntityQuery()

  var id: String
  var name: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }
}

struct AccountEntityQuery: EntityQuery {
  func entities(for identifiers: [AccountEntity.ID]) async throws -> [AccountEntity] {
    let accounts = IntentCatalogStore.shared.loadActive()?.openAccounts ?? []
    return identifiers.compactMap { id in
      accounts.first { $0.id == id }.map { AccountEntity(id: $0.id, name: $0.name) }
    }
  }

  func suggestedEntities() async throws -> [AccountEntity] {
    (IntentCatalogStore.shared.loadActive()?.openAccounts ?? []).map {
      AccountEntity(id: $0.id, name: $0.name)
    }
  }
}
