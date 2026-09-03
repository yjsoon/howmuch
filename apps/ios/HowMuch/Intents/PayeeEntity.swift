import AppIntents

struct PayeeEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Payee")
  }

  static var defaultQuery = PayeeEntityQuery()

  var id: String
  var name: String
  var transferAccountId: String?
  var isNew: Bool

  var displayRepresentation: DisplayRepresentation {
    if isNew {
      return DisplayRepresentation(title: "Create “\(name)”")
    }
    if transferAccountId != nil {
      return DisplayRepresentation(title: "\(name)", subtitle: "Transfer")
    }
    return DisplayRepresentation(title: "\(name)")
  }
}

struct PayeeEntityQuery: EntityStringQuery {
  func entities(for identifiers: [PayeeEntity.ID]) async throws -> [PayeeEntity] {
    identifiers.compactMap { id in
      if let name = PayeeEntityQuery.newPayeeName(from: id) {
        return PayeeEntity(id: id, name: name, transferAccountId: nil, isNew: true)
      }
      return (IntentCatalogStore.shared.loadActive()?.pickerPayees ?? [])
        .first { $0.id == id }
        .map {
          PayeeEntity(id: $0.id, name: $0.name, transferAccountId: $0.transferAccountId, isNew: false)
        }
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
      .map { PayeeEntity(id: $0.id, name: $0.name, transferAccountId: $0.transferAccountId, isNew: false) }
    let hasExact = payees.contains { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    if !hasExact {
      matches.append(
        PayeeEntity(id: PayeeEntityQuery.newPayeeID(for: trimmed), name: trimmed, transferAccountId: nil, isNew: true)
      )
    }
    return matches
  }

  func suggestedEntities() async throws -> [PayeeEntity] {
    (IntentCatalogStore.shared.loadActive()?.pickerPayees ?? []).map {
      PayeeEntity(id: $0.id, name: $0.name, transferAccountId: $0.transferAccountId, isNew: false)
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
