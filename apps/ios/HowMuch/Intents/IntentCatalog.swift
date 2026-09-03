import CryptoKit
import Foundation

struct IntentCatalogAccount: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var name: String
  var onBudget: Bool
  var closed: Bool
}

struct IntentCatalogPayee: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var name: String
  var transferAccountId: String?
  var deleted: Bool?
}

struct IntentCatalogCategory: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var name: String
  var groupName: String
  var isQuiet: Bool
  var deleted: Bool
}

struct IntentCatalogSnapshot: Codable, Equatable, Sendable {
  var connectionFingerprint: String
  var accounts: [IntentCatalogAccount]
  var payees: [IntentCatalogPayee]
  var categories: [IntentCatalogCategory]

  var openAccounts: [IntentCatalogAccount] {
    accounts.filter { !$0.closed }
  }

  var pickerPayees: [IntentCatalogPayee] {
    payees.filter { $0.deleted != true }
  }

  var pickerCategories: [IntentCatalogCategory] {
    let live = categories.filter { !$0.deleted }
    return live.filter { !$0.isQuiet } + live.filter(\.isQuiet)
  }

  static func project(
    fingerprint: String,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee]
  ) -> IntentCatalogSnapshot {
    IntentCatalogSnapshot(
      connectionFingerprint: fingerprint,
      accounts: accounts.map {
        IntentCatalogAccount(id: $0.id, name: $0.name, onBudget: $0.onBudget, closed: $0.closed)
      },
      payees: payees.map {
        IntentCatalogPayee(
          id: $0.id,
          name: $0.name,
          transferAccountId: $0.transferAccountId,
          deleted: $0.deleted
        )
      },
      categories: categoryGroups.flatMap { group in
        group.categories.map { category in
          IntentCatalogCategory(
            id: category.id,
            name: category.name,
            groupName: group.name,
            isQuiet: group.isQuiet,
            deleted: category.deleted || group.deleted
          )
        }
      }
    )
  }
}

final class IntentCatalogStore: @unchecked Sendable {
  static let shared = IntentCatalogStore(directory: IntentCatalogStore.defaultDirectory())

  private let directory: URL
  private let lock = NSLock()
  private let ioQueue = DispatchQueue(label: "sg.soon.howmuch.intent-catalog")
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var generation = 0

  init(directory: URL) {
    self.directory = directory
  }

  static func defaultDirectory() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return root.appendingPathComponent("HowMuch/IntentCatalog", isDirectory: true)
  }

  func scheduleWrite(_ snapshot: IntentCatalogSnapshot) {
    lock.lock()
    let generation = self.generation
    lock.unlock()
    ioQueue.async {
      self.write(snapshot, ifGeneration: generation)
    }
  }

  func waitForPendingWrites() {
    ioQueue.sync {}
  }

  func write(_ snapshot: IntentCatalogSnapshot) {
    lock.lock()
    let generation = self.generation
    lock.unlock()
    write(snapshot, ifGeneration: generation)
  }

  func load(fingerprint: String) -> IntentCatalogSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return loadLocked(fingerprint: fingerprint)
  }

  func loadActive() -> IntentCatalogSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }
    let newest = files.filter { $0.pathExtension == "json" }.max { left, right in
      let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      return leftDate < rightDate
    }
    guard let newest, let data = try? Data(contentsOf: newest) else {
      return nil
    }
    return try? decoder.decode(IntentCatalogSnapshot.self, from: data)
  }

  func wipe(fingerprint: String) {
    lock.lock()
    defer { lock.unlock() }
    generation += 1
    try? FileManager.default.removeItem(at: fileURL(for: fingerprint))
  }

  func wipeAll() {
    lock.lock()
    defer { lock.unlock() }
    generation += 1
    try? FileManager.default.removeItem(at: directory)
  }

  private func write(_ snapshot: IntentCatalogSnapshot, ifGeneration expected: Int) {
    lock.lock()
    defer { lock.unlock() }
    guard expected == generation else {
      return
    }
    let file = fileURL(for: snapshot.connectionFingerprint)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try encoder.encode(snapshot)
      try data.write(to: file, options: .atomic)
    } catch {
      return
    }
  }

  private func loadLocked(fingerprint: String) -> IntentCatalogSnapshot? {
    let file = fileURL(for: fingerprint)
    guard let data = try? Data(contentsOf: file) else {
      return nil
    }
    guard let snapshot = try? decoder.decode(IntentCatalogSnapshot.self, from: data) else {
      return nil
    }
    guard snapshot.connectionFingerprint == fingerprint else {
      return nil
    }
    return snapshot
  }

  private func fileURL(for fingerprint: String) -> URL {
    let digest = SHA256.hash(data: Data(fingerprint.utf8))
    let name = digest.map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent("\(name).json")
  }
}
