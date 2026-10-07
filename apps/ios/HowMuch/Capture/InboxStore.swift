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
  /// A source written by a newer build that this build does not know.
  case other

  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = InboxSource(rawValue: raw) ?? .other
  }
}

enum InboxPayloadKind: String, Codable, Equatable, Sendable {
  case text
  case image
  case pdf
}

enum IntakeHint: String, Codable, Equatable, Sendable {
  case auto
  case new
  case fix
  case statement
}

struct InboxSourceFile: Codable, Equatable, Sendable {
  var filename: String
  var kind: InboxPayloadKind
  var bytes: Int
  var sha256: String?

  init(filename: String, kind: InboxPayloadKind, bytes: Int, sha256: String? = nil) {
    self.filename = filename
    self.kind = kind
    self.bytes = bytes
    self.sha256 = sha256
  }
}

enum InboxStoreError: Error, Equatable {
  case payloadTooLarge
  case emptyJob
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

/// One file already on disk, copied into the job without loading it into memory.
struct InboxFileSource: Equatable, Sendable {
  var filename: String
  var kind: InboxPayloadKind
  var fileURL: URL
  var sha256: String?

  init(filename: String, kind: InboxPayloadKind, fileURL: URL, sha256: String? = nil) {
    self.filename = filename
    self.kind = kind
    self.fileURL = fileURL
    self.sha256 = sha256
  }
}

struct InboxFileWrite: Equatable, Sendable {
  var id: UUID
  var source: InboxSource
  var sources: [InboxFileSource]
  var accountID: String?
  var decideAccount: Bool
  var hint: IntakeHint
  var note: String?
  var contentHash: String?
  var createdAt: Date

  init(
    id: UUID = UUID(),
    source: InboxSource,
    sources: [InboxFileSource],
    accountID: String? = nil,
    decideAccount: Bool = false,
    hint: IntakeHint = .auto,
    note: String? = nil,
    contentHash: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.source = source
    self.sources = sources
    self.accountID = accountID
    self.decideAccount = decideAccount
    self.hint = hint
    self.note = note
    self.contentHash = contentHash
    self.createdAt = createdAt
  }
}

struct InboxItem: Equatable, Sendable, Identifiable {
  var id: UUID
  var source: InboxSource
  var sources: [InboxSourceFile]
  var accountID: String?
  var decideAccount: Bool
  var hint: IntakeHint
  var note: String?
  var contentHash: String?
  var directory: URL
  var createdAt: Date

  init(
    id: UUID,
    source: InboxSource,
    sources: [InboxSourceFile],
    accountID: String? = nil,
    decideAccount: Bool = false,
    hint: IntakeHint = .auto,
    note: String? = nil,
    contentHash: String? = nil,
    directory: URL,
    createdAt: Date
  ) {
    self.id = id
    self.source = source
    self.sources = sources
    self.accountID = accountID
    self.decideAccount = decideAccount
    self.hint = hint
    self.note = note
    self.contentHash = contentHash
    self.directory = directory
    self.createdAt = createdAt
  }

  /// The first source, which single-payload callers read.
  var kind: InboxPayloadKind {
    sources.first?.kind ?? .text
  }

  var filename: String {
    sources.first?.filename ?? "payload.bin"
  }

  var payloadURL: URL {
    directory.appendingPathComponent(filename)
  }

  func payloadURL(for file: InboxSourceFile) -> URL {
    directory.appendingPathComponent(file.filename)
  }

  func payloadData() throws -> Data {
    try Data(contentsOf: payloadURL)
  }

  func payloadText() -> String {
    guard kind == .text, let data = try? payloadData() else {
      return ""
    }
    return Self.decodeText(data)
  }

  func text(of file: InboxSourceFile) -> String {
    guard file.kind == .text, let data = try? Data(contentsOf: payloadURL(for: file)) else {
      return ""
    }
    return Self.decodeText(data)
  }

  private static func decodeText(_ data: Data) -> String {
    String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16)
      ?? ""
  }
}

/// Decodes one source, yielding nil (instead of failing the array) for a kind
/// or shape this build does not understand.
private struct LenientSourceFile: Decodable {
  var value: InboxSourceFile?

  init(from decoder: Decoder) throws {
    value = try? InboxSourceFile(from: decoder)
  }
}

/// Version 2 manifest. A v1 manifest (no `version`, top-level `kind` and
/// `filename`) decodes as a single source. Unknown keys are ignored.
private struct InboxManifest: Codable, Equatable {
  static let currentVersion = 2

  var version: Int
  var id: UUID
  var source: InboxSource
  var sources: [InboxSourceFile]
  var accountID: String?
  var decideAccount: Bool
  var hint: IntakeHint
  var note: String?
  var contentHash: String?
  var createdAt: Date

  init(
    id: UUID,
    source: InboxSource,
    sources: [InboxSourceFile],
    accountID: String? = nil,
    decideAccount: Bool = false,
    hint: IntakeHint = .auto,
    note: String? = nil,
    contentHash: String? = nil,
    createdAt: Date
  ) {
    version = Self.currentVersion
    self.id = id
    self.source = source
    self.sources = sources
    self.accountID = accountID
    self.decideAccount = decideAccount
    self.hint = hint
    self.note = note
    self.contentHash = contentHash
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case version, id, source, kind, filename, sources
    case accountID, decideAccount, hint, note, contentHash, createdAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    id = try container.decode(UUID.self, forKey: .id)
    source = try container.decode(InboxSource.self, forKey: .source)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    let decoded = (try? container.decodeIfPresent([LenientSourceFile].self, forKey: .sources))?
      .compactMap(\.value) ?? []
    if !decoded.isEmpty {
      sources = decoded
    } else {
      let kind = try container.decode(InboxPayloadKind.self, forKey: .kind)
      let filename = try container.decode(String.self, forKey: .filename)
      sources = [InboxSourceFile(filename: filename, kind: kind, bytes: 0)]
    }
    accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    decideAccount = try container.decodeIfPresent(Bool.self, forKey: .decideAccount) ?? false
    hint = (try? container.decodeIfPresent(IntakeHint.self, forKey: .hint)) ?? .auto
    note = try container.decodeIfPresent(String.self, forKey: .note)
    contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
  }

  /// Also writes the first source's `kind` and `filename` so an older build
  /// that meets a v2 manifest can still read the first payload.
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(id, forKey: .id)
    try container.encode(source, forKey: .source)
    try container.encodeIfPresent(sources.first?.kind, forKey: .kind)
    try container.encodeIfPresent(sources.first?.filename, forKey: .filename)
    try container.encode(sources, forKey: .sources)
    try container.encodeIfPresent(accountID, forKey: .accountID)
    try container.encode(decideAccount, forKey: .decideAccount)
    try container.encode(hint, forKey: .hint)
    try container.encodeIfPresent(note, forKey: .note)
    try container.encodeIfPresent(contentHash, forKey: .contentHash)
    try container.encode(createdAt, forKey: .createdAt)
  }
}

final class InboxStore: @unchecked Sendable {
  static let shared = InboxStore(container: InboxStore.defaultContainer())
  static let maxPayloadBytes = 12 * 1024 * 1024
  static let maxJobBytes = 24 * 1024 * 1024

  let inboxDirectory: URL
  let readingDirectory: URL
  let quarantineDirectory: URL

  private let fileManager: FileManager
  private let lock = NSLock()
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(container: URL, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    inboxDirectory = container.appendingPathComponent("Inbox", isDirectory: true)
    readingDirectory = container.appendingPathComponent("Reading", isDirectory: true)
    quarantineDirectory = container.appendingPathComponent("Quarantine", isDirectory: true)
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

  static func sanitizedFilename(_ raw: String) -> String {
    let name = URL(fileURLWithPath: raw).lastPathComponent
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    guard !name.isEmpty,
          name != "manifest.json",
          name != ".",
          name != "..",
          !name.hasPrefix("."),
          name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      return "payload.bin"
    }
    return name
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
    let filename = Self.sanitizedFilename(write.filename)
    try publish(id: write.id) { partial in
      try write.data.write(to: partial.appendingPathComponent(filename), options: .atomic)
      return InboxManifest(
        id: write.id,
        source: write.source,
        sources: [InboxSourceFile(filename: filename, kind: write.kind, bytes: write.data.count)],
        createdAt: write.createdAt
      )
    }
  }

  /// Copies each file into the job folder (never into memory), then renames
  /// the `.partial` folder into place. The caller keeps ownership of the
  /// source files and removes them afterwards.
  func write(_ job: InboxFileWrite) throws {
    guard !job.sources.isEmpty else {
      throw InboxStoreError.emptyJob
    }
    var sizes: [Int] = []
    for source in job.sources {
      let attributes = try fileManager.attributesOfItem(atPath: source.fileURL.path)
      sizes.append((attributes[.size] as? NSNumber)?.intValue ?? 0)
    }
    guard sizes.allSatisfy({ $0 <= Self.maxPayloadBytes }),
          sizes.reduce(0, +) <= Self.maxJobBytes else {
      throw InboxStoreError.payloadTooLarge
    }
    var used = Set<String>()
    var files: [InboxSourceFile] = []
    var names: [String] = []
    for (index, source) in job.sources.enumerated() {
      let base = Self.sanitizedFilename(source.filename)
      var name = base
      var prefix = index + 1
      while used.contains(name) {
        name = "\(prefix)-\(base)"
        prefix += 1
      }
      used.insert(name)
      names.append(name)
      files.append(InboxSourceFile(
        filename: name, kind: source.kind, bytes: sizes[index], sha256: source.sha256
      ))
    }
    try publish(id: job.id) { partial in
      for (index, source) in job.sources.enumerated() {
        try fileManager.copyItem(
          at: source.fileURL, to: partial.appendingPathComponent(names[index])
        )
      }
      return InboxManifest(
        id: job.id,
        source: job.source,
        sources: files,
        accountID: job.accountID,
        decideAccount: job.decideAccount,
        hint: job.hint,
        note: job.note,
        contentHash: job.contentHash,
        createdAt: job.createdAt
      )
    }
  }

  private func publish(id: UUID, build: (URL) throws -> InboxManifest) throws {
    lock.lock()
    defer { lock.unlock() }
    try fileManager.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
    let folderName = id.uuidString
    let partial = inboxDirectory.appendingPathComponent("\(folderName).partial", isDirectory: true)
    let ready = inboxDirectory.appendingPathComponent(folderName, isDirectory: true)
    if fileManager.fileExists(atPath: partial.path) {
      try fileManager.removeItem(at: partial)
    }
    try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
    do {
      let manifest = try build(partial)
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
    sweepStalePartialsLocked()
    var claimed: [InboxItem] = []
    for url in readyInboxURLsLocked() {
      let destination = readingDirectory.appendingPathComponent(url.lastPathComponent)
      if fileManager.fileExists(atPath: destination.path) {
        continue
      }
      guard loadItemLocked(at: url) != nil else {
        quarantineLocked(url)
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
    guard loadItemLocked(at: inboxURL) != nil else {
      quarantineLocked(inboxURL)
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

  /// A folder whose manifest cannot be decoded is kept for inspection, out of
  /// the way of both Inbox and Reading.
  private func quarantineLocked(_ url: URL) {
    try? fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
    var destination = quarantineDirectory.appendingPathComponent(url.lastPathComponent)
    if fileManager.fileExists(atPath: destination.path) {
      destination = quarantineDirectory.appendingPathComponent(
        "\(url.lastPathComponent)-\(Int(Date().timeIntervalSince1970))"
      )
    }
    try? fileManager.moveItem(at: url, to: destination)
  }

  /// An extension killed mid-write leaves a `.partial` folder behind.
  private func sweepStalePartialsLocked() {
    let cutoff = Date().addingTimeInterval(-3600)
    let urls = (try? fileManager.contentsOfDirectory(
      at: inboxDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: []
    )) ?? []
    for url in urls where url.lastPathComponent.hasSuffix(".partial") {
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
      if let modified, modified < cutoff {
        try? fileManager.removeItem(at: url)
      }
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
      sources: manifest.sources,
      accountID: manifest.accountID,
      decideAccount: manifest.decideAccount,
      hint: manifest.hint,
      note: manifest.note,
      contentHash: manifest.contentHash,
      directory: directory,
      createdAt: manifest.createdAt
    )
  }
}
