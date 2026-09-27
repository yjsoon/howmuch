import Foundation

/// The categories a new on-device plan starts with. Categories only tag
/// spending; the user can rename or hide them later.
enum StarterCategories {
  struct Group: Equatable {
    let name: String
    let categories: [String]
  }

  static let groups: [Group] = [
    Group(name: "Everyday", categories: ["Groceries", "Eating out", "Transport", "Shopping"]),
    Group(name: "Bills", categories: ["Housing", "Utilities", "Phone and internet", "Insurance"]),
    Group(name: "Life", categories: ["Health", "Entertainment", "Travel", "Gifts"]),
    Group(name: "Income", categories: ["Salary", "Other income"]),
  ]

  /// One create request of the starter set.
  enum Step: Equatable {
    case group(id: String, name: String)
    case category(id: String, groupID: String, name: String)
  }

  /// The starter set for a plan, groups before their categories. Ids are
  /// derived from the plan and the names, so a re-run asks for the same
  /// entities: the server answers a repeat as a replay or "already exists",
  /// never as a second copy, and a starter the user deleted keeps its id and
  /// is not made again. Category ids are unique across plans, hence the plan id.
  static func steps(planID: String) -> [Step] {
    groups.flatMap { group -> [Step] in
      let groupID = "starter:\(planID):grp:\(slug(group.name))"
      return [.group(id: groupID, name: group.name)] + group.categories.map { name in
        .category(id: "starter:\(planID):cat:\(slug(name))", groupID: groupID, name: name)
      }
    }
  }

  static func slug(_ name: String) -> String {
    name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
  }

  /// Whether a create failed only because the entity is already there.
  static func isAlreadyPresent(_ error: Error) -> Bool {
    if case APIClientError.conflict = error {
      return true
    }
    return false
  }

  static func completionKey(planID: String) -> String {
    "HowMuch.StarterCategoriesSeeded.\(planID)"
  }

  /// Creates whatever part of the starter set is missing, through the API so
  /// the engine applies the same rules as a server. Once every step has
  /// succeeded the plan is marked complete and never seeded again, so later
  /// deletions stay deleted. A failure leaves it incomplete for the next run.
  static func seedIfNeeded(client: APIClient, planID: String, defaults: UserDefaults = .standard) async throws {
    let key = completionKey(planID: planID)
    guard !defaults.bool(forKey: key) else {
      return
    }
    for step in steps(planID: planID) {
      do {
        switch step {
        case .group(let id, let name):
          try await client.createCategoryGroup(planID: planID, id: id, name: name)
        case .category(let id, let groupID, let name):
          try await client.createCategory(planID: planID, id: id, groupID: groupID, name: name)
        }
      } catch where isAlreadyPresent(error) {
        continue
      }
    }
    defaults.set(true, forKey: key)
  }
}
