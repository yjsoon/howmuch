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
    let categories = IntentCatalogStore.shared.loadActive()?.pickerCategories ?? []
    return identifiers.compactMap { id in
      categories.first { $0.id == id }.map {
        CategoryEntity(id: $0.id, name: $0.name, groupName: $0.groupName)
      }
    }
  }

  func suggestedEntities() async throws -> [CategoryEntity] {
    (IntentCatalogStore.shared.loadActive()?.pickerCategories ?? []).map {
      CategoryEntity(id: $0.id, name: $0.name, groupName: $0.groupName)
    }
  }
}
