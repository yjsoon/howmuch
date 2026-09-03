import AppIntents

struct PayeeEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Payee")
  }

  static var defaultQuery = PayeeEntityQuery()

  var id: String
  @Property(title: "Name")
  var name: String

  init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  var isNew: Bool {
    PayeeEntityQuery.newPayeeName(from: id) != nil
  }

  var transferAccountId: String? {
    IntentCatalogStore.shared.loadActive()?.pickerPayees.first { $0.id == id }?.transferAccountId
  }

  var displayRepresentation: DisplayRepresentation {
    if isNew {
      return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "Create “\(name)”"))
    }
    if transferAccountId != nil {
      return DisplayRepresentation(
        title: LocalizedStringResource(stringLiteral: name),
        subtitle: "Transfer"
      )
    }
    return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
  }
}

struct PayeeEntityQuery: EntityStringQuery {
  func entities(for identifiers: [PayeeEntity.ID]) async throws -> [PayeeEntity] {
    Self.resolved(identifiers, catalog: IntentCatalogStore.shared.loadActive())
  }

  /// App Intents drops a parameter when this returns fewer entities than
  /// identifiers. Match id or display name, and never drop a pick.
  static func resolved(
    _ identifiers: [PayeeEntity.ID],
    catalog: IntentCatalogSnapshot?
  ) -> [PayeeEntity] {
    let payees = catalog?.pickerPayees ?? []
    return identifiers.map { id in
      if let name = newPayeeName(from: id) {
        return PayeeEntity(id: id, name: name)
      }
      if let live = payees.first(where: {
        $0.id == id || $0.name.caseInsensitiveCompare(id) == .orderedSame
      }) {
        return PayeeEntity(id: live.id, name: live.name)
      }
      return PayeeEntity(id: id, name: id)
    }
  }

  func entities(matching string: String) async throws -> [PayeeEntity] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return try await suggestedEntities()
    }
    let payees = IntentCatalogStore.shared.loadActive()?.pickerPayees ?? []
    var matches = payees
      .filter { $0.name.localizedStandardContains(trimmed) }
      .map { PayeeEntity(id: $0.id, name: $0.name) }
    let hasExact = payees.contains { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    if !hasExact {
      matches.append(
        PayeeEntity(id: PayeeEntityQuery.newPayeeID(for: trimmed), name: trimmed)
      )
    }
    return matches
  }

  func suggestedEntities() async throws -> [PayeeEntity] {
    (IntentCatalogStore.shared.loadActive()?.pickerPayees ?? []).map {
      PayeeEntity(id: $0.id, name: $0.name)
    }
  }

  static func newPayeeID(for name: String) -> String {
    "new:\(name)"
  }

  static func newPayeeName(from id: String) -> String? {
    guard id.hasPrefix("new:") else {
      return nil
    }
    let name = String(id.dropFirst(4))
    return name.isEmpty ? nil : name
  }
}
