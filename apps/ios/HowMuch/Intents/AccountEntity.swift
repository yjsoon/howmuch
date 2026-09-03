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
    Self.resolved(identifiers, catalog: IntentCatalogStore.shared.loadActive())
  }

  /// App Intents drops a parameter when this returns fewer entities than
  /// identifiers. The intent daemon may resolve IDs without Application
  /// Support, so a missing catalog must still keep the pick.
  static func resolved(
    _ identifiers: [AccountEntity.ID],
    catalog: IntentCatalogSnapshot?
  ) -> [AccountEntity] {
    let accounts = catalog?.openAccounts ?? []
    return identifiers.map { id in
      if let live = accounts.first(where: { $0.id == id }) {
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
