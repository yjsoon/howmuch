import Foundation

enum HowMuchAppGroup {
  static let identifier = "group.sg.soon.howmuch"

  static func containerURL(fileManager: FileManager = .default) -> URL? {
    fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
  }
}


enum InboxSource: String, Codable, Equatable, Sendable {
  case shareSheet
  case appIntent
  case detectedScreenshot
}

enum InboxPayloadKind: String, Codable, Equatable, Sendable {
  case text
  case image
}

enum InboxStoreError: Error, Equatable {
  case payloadTooLarge
}

struct InboxWrite: Equatable, Sendable {
  var id: UUID
  var source: InboxSource
  var kind: InboxPayloadKind
  var filename: String
  var data: Data
  var createdAt: Date

  init(
    id: UUID = UUID(),
    source: InboxSource,
    kind: InboxPayloadKind,
    filename: String,
    data: Data,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.source = source
    self.kind = kind
    self.filename = filename
    self.data = data
    self.createdAt = createdAt
  }
}

struct InboxItem: Equatable, Sendable, Identifiable {
  var id: UUID
  var source: InboxSource
  var kind: InboxPayloadKind
  var filename: String
  var directory: URL
  var createdAt: Date

  var payloadURL: URL {
    directory.appendingPathComponent(filename)
  }

  func payloadData() throws -> Data {
    try Data(contentsOf: payloadURL)
  }

  func payloadText() -> String {
    guard kind == .text, let data = try? payloadData() else {
      return ""
    }
    return String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16)
      ?? ""
  }
}

private struct InboxManifest: Codable, Equatable {
  var id: UUID
  var source: InboxSource
  var kind: InboxPayloadKind
  var filename: String
  var createdAt: Date
}

final class InboxStore: @unchecked Sendable {
  static let shared = InboxStore(container: InboxStore.defaultContainer())
  static let maxPayloadBytes = 12 * 1024 * 1024

  let inboxDirectory: URL
  let readingDirectory: URL

  private let fileManager: FileManager
  private let lock = NSLock()
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(container: URL, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    inboxDirectory = container.appendingPathComponent("Inbox", isDirectory: true)
    readingDirectory = container.appendingPathComponent("Reading", isDirectory: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  static func defaultContainer() -> URL {
    if let container = HowMuchAppGroup.containerURL() {
      return container
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("HowMuch", isDirectory: true)
  }

  func hasReadyInboxItems() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !readyInboxURLsLocked().isEmpty
  }

  func hasReadingItems() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !readingURLsLocked().isEmpty
  }

  func hasPendingWork() -> Bool {
    hasReadyInboxItems() || hasReadingItems()
  }

  func write(_ write: InboxWrite) throws {
    guard write.data.count <= Self.maxPayloadBytes else {
      throw InboxStoreError.payloadTooLarge
    }
    lock.lock()
    defer { lock.unlock() }
    try fileManager.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
    let folderName = write.id.uuidString
    let partial = inboxDirectory.appendingPathComponent("\(folderName).partial", isDirectory: true)
    let ready = inboxDirectory.appendingPathComponent(folderName, isDirectory: true)
    if fileManager.fileExists(atPath: partial.path) {
      try fileManager.removeItem(at: partial)
    }
    try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
    do {
      try write.data.write(to: partial.appendingPathComponent(write.filename), options: .atomic)
      let manifest = InboxManifest(
        id: write.id,
        source: write.source,
        kind: write.kind,
        filename: write.filename,
        createdAt: write.createdAt
      )
      let manifestData = try encoder.encode(manifest)
      try manifestData.write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)
      if fileManager.fileExists(atPath: ready.path) {
        try fileManager.removeItem(at: ready)
      }
      try fileManager.moveItem(at: partial, to: ready)
    } catch {
      try? fileManager.removeItem(at: partial)
      throw error
    }
  }

  /// Moves ready `Inbox/{id}/` directories into `Reading/{id}/`.
  /// Directories still named `*.partial` are ignored. A second claim of an
  /// id already in Reading is a no-op and is not returned again.
  @discardableResult
  func claimInbox() throws -> [InboxItem] {
    lock.lock()
    defer { lock.unlock() }
    try fileManager.createDirectory(at: readingDirectory, withIntermediateDirectories: true)
    var claimed: [InboxItem] = []
    for url in readyInboxURLsLocked() {
      let destination = readingDirectory.appendingPathComponent(url.lastPathComponent)
      if fileManager.fileExists(atPath: destination.path) {
        continue
      }
      try fileManager.moveItem(at: url, to: destination)
      if let item = loadItemLocked(at: destination) {
        claimed.append(item)
      }
    }
    return claimed.sorted { $0.createdAt < $1.createdAt }
  }

  func claim(_ id: UUID) throws -> InboxItem? {
    lock.lock()
    defer { lock.unlock() }
    let inboxURL = inboxDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    let readingURL = readingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    if fileManager.fileExists(atPath: readingURL.path) {
      return nil
    }
    guard fileManager.fileExists(atPath: inboxURL.path) else {
      return nil
    }
    try fileManager.createDirectory(at: readingDirectory, withIntermediateDirectories: true)
    try fileManager.moveItem(at: inboxURL, to: readingURL)
    return loadItemLocked(at: readingURL)
  }

  func loadReading() -> [InboxItem] {
    lock.lock()
    defer { lock.unlock() }
    return readingURLsLocked().compactMap { loadItemLocked(at: $0) }
      .sorted { $0.createdAt < $1.createdAt }
  }

  func discardReading(_ id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    discardReadingLocked(id)
  }

  func discardReading(ids: [UUID]) {
    lock.lock()
    defer { lock.unlock() }
    for id in ids {
      discardReadingLocked(id)
    }
  }

  private func discardReadingLocked(_ id: UUID) {
    let url = readingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    try? fileManager.removeItem(at: url)
  }

  private func readyInboxURLsLocked() -> [URL] {
    directoryContents(inboxDirectory).filter { url in
      url.hasDirectoryPath && !url.lastPathComponent.hasSuffix(".partial")
    }
  }

  private func readingURLsLocked() -> [URL] {
    directoryContents(readingDirectory).filter(\.hasDirectoryPath)
  }

  private func directoryContents(_ directory: URL) -> [URL] {
    (try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []
  }

  private func loadItemLocked(at directory: URL) -> InboxItem? {
    let manifestURL = directory.appendingPathComponent("manifest.json")
    guard
      let data = try? Data(contentsOf: manifestURL),
      let manifest = try? decoder.decode(InboxManifest.self, from: data)
    else {
      return nil
    }
    return InboxItem(
      id: manifest.id,
      source: manifest.source,
      kind: manifest.kind,
      filename: manifest.filename,
      directory: directory,
      createdAt: manifest.createdAt
    )
  }
}
