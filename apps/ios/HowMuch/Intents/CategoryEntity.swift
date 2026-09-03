import AppIntents

struct CategoryEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Category")
  }

  static var defaultQuery = CategoryEntityQuery()

  var id: String
  var name: String
  var groupName: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(groupName)")
  }
}

struct CategoryEntityQuery: EntityQuery {
  func entities(for identifiers: [CategoryEntity.ID]) async throws -> [CategoryEntity] {
    Self.resolved(identifiers, catalog: IntentCatalogStore.shared.loadActive())
  }

  static func resolved(
    _ identifiers: [CategoryEntity.ID],
    catalog: IntentCatalogSnapshot?
  ) -> [CategoryEntity] {
    let categories = catalog?.pickerCategories ?? []
    return identifiers.map { id in
      if let live = categories.first(where: { $0.id == id }) {
        return CategoryEntity(id: live.id, name: live.name, groupName: live.groupName)
      }
      return CategoryEntity(id: id, name: id, groupName: "")
    }
  }

  func suggestedEntities() async throws -> [CategoryEntity] {
    (IntentCatalogStore.shared.loadActive()?.pickerCategories ?? []).map {
      CategoryEntity(id: $0.id, name: $0.name, groupName: $0.groupName)
    }
  }
}
