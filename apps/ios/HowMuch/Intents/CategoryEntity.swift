import AppIntents

struct CategoryEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Category")
  }

  static var defaultQuery = CategoryEntityQuery()

  var id: String
  @Property(title: "Name")
  var name: String
  @Property(title: "Group")
  var groupName: String

  init(id: String, name: String, groupName: String) {
    self.id = id
    self.name = name
    self.groupName = groupName
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: LocalizedStringResource(stringLiteral: name),
      subtitle: LocalizedStringResource(stringLiteral: groupName)
    )
  }
}

struct CategoryNameOptions: DynamicOptionsProvider {
  func results() async throws -> [String] {
    (IntentCatalogStore.shared.loadActive()?.pickerCategories ?? []).map(\.name)
  }
}

struct CategoryEntityQuery: EntityStringQuery {
  func entities(for identifiers: [CategoryEntity.ID]) async throws -> [CategoryEntity] {
    Self.resolved(identifiers, catalog: IntentCatalogStore.shared.loadActive())
  }

  func entities(matching string: String) async throws -> [CategoryEntity] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    let categories = IntentCatalogStore.shared.loadActive()?.pickerCategories ?? []
    guard !trimmed.isEmpty else {
      return try await suggestedEntities()
    }
    return categories
      .filter {
        $0.id == trimmed || $0.name.localizedStandardContains(trimmed)
      }
      .map { CategoryEntity(id: $0.id, name: $0.name, groupName: $0.groupName) }
  }

  static func resolved(
    _ identifiers: [CategoryEntity.ID],
    catalog: IntentCatalogSnapshot?
  ) -> [CategoryEntity] {
    let categories = catalog?.pickerCategories ?? []
    return identifiers.map { id in
      if let live = categories.first(where: {
        $0.id == id || $0.name.caseInsensitiveCompare(id) == .orderedSame
      }) {
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
