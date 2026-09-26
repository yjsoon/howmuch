// The outbox on disk. See docs/plans/offline-writes.md P1.
//
// One JSON file holds every write that has not reached the server yet. It is
// written synchronously and atomically on every change, before the change is
// shown, so a write the app accepted survives a crash or a kill. Nothing here
// ever deletes a command it could not read: a file that fails to decode is
// set aside under a new name, and the legacy UserDefaults queue is removed
// only once its contents are safely in the file.

import Foundation

enum OutboxStoreError: LocalizedError, Equatable {
  /// The file exists but could not be read (for example, the device has not
  /// been unlocked since it restarted). Writing now would replace commands
  /// that are still on disk, so every write is refused until a read succeeds.
  case unreadable(String)

  var errorDescription: String? {
    switch self {
    case .unreadable(let message):
      return "Unsent changes couldn’t be read: \(message)"
    }
  }
}

final class OutboxStore: @unchecked Sendable {
  static let fileName = "outbox.json"
  /// Where the create-only queue lived before the outbox moved to a file.
  static let legacyDefaultsKey = "HowMuch.Outbox"
  static let shared = OutboxStore(directory: OutboxStore.defaultDirectory())

  private struct Envelope: Codable {
    let version: Int
    let commands: [OutboxCommand]
  }

  private static let currentVersion = 1

  let directory: URL
  private let defaults: UserDefaults
  private let fileManager: FileManager
  private let now: () -> Date
  /// Replaces the atomic write in tests that need a write to fail.
  private let writeData: (Data, URL) throws -> Void
  private let lock = NSLock()
  /// False until a load has seen the file (or its absence). A store that has
  /// never read its file must not write it.
  private var hasLoaded = false
  /// True when the last load set part of the outbox aside as unreadable.
  private(set) var quarantinedOnLastLoad = false

  init(
    directory: URL,
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default,
    now: @escaping () -> Date = Date.init,
    writeData: ((Data, URL) throws -> Void)? = nil
  ) {
    self.directory = directory
    self.defaults = defaults
    self.fileManager = fileManager
    self.now = now
    self.writeData = writeData ?? { data, url in
      try data.write(to: url, options: .atomic)
    }
  }

  /// The app's own container. Unlike the reference snapshot this file is not
  /// excluded from backup: it holds changes that exist nowhere else yet.
  static func defaultDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("HowMuch/Outbox", isDirectory: true)
  }

  var fileURL: URL {
    directory.appendingPathComponent(Self.fileName)
  }

  /// Reads the outbox, moving in anything still queued in UserDefaults.
  ///
  /// Commands that were on the wire when the app last stopped come back as
  /// queued: every command is safe to send twice (creates dedupe by import
  /// id, edits are full-body, status changes and deletes are compare-and-set).
  func load() throws -> [OutboxCommand] {
    lock.lock()
    defer { lock.unlock() }

    var commands: [OutboxCommand] = []
    var needsWrite = false
    quarantinedOnLastLoad = false
    if let data = try readFileLocked() {
      if let envelope = try? decoder.decode(Envelope.self, from: data) {
        commands = envelope.commands
      } else {
        // Keep the bytes for a person to look at, and start empty. Never
        // delete what could not be read.
        try quarantineLocked(data, reason: "corrupt")
        quarantinedOnLastLoad = true
      }
    }
    hasLoaded = true

    for index in commands.indices where commands[index].isInFlight {
      commands[index].state = .queued
      commands[index].attempted = true
      needsWrite = true
    }

    let legacy = legacyCommandsLocked(after: commands)
    if legacy.migrated {
      commands += legacy.commands
      needsWrite = true
    }
    if needsWrite {
      do {
        try writeLocked(commands)
      } catch {
        // The legacy key stays until a later launch manages the write. The
        // commands are still returned so they show and sync this session.
        return commands
      }
    }
    if legacy.migrated || legacy.quarantined {
      defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }
    return commands
  }

  /// Replaces the file with `commands`, atomically, before returning.
  func save(_ commands: [OutboxCommand]) throws {
    lock.lock()
    defer { lock.unlock() }
    guard hasLoaded else {
      throw OutboxStoreError.unreadable("The outbox has not been read yet.")
    }
    try writeLocked(commands)
  }

  /// What the file holds right now, without migrating or rewriting anything.
  /// Nil when there is no file or it cannot be decoded.
  func peek() -> [OutboxCommand]? {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try? Data(contentsOf: fileURL) else {
      return nil
    }
    return (try? decoder.decode(Envelope.self, from: data))?.commands
  }

  /// The files set aside because they could not be decoded, oldest first.
  func quarantinedFiles() -> [URL] {
    let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    return names
      .filter { $0.hasPrefix("outbox.") && $0.hasSuffix(".quarantine.json") }
      .sorted()
      .map { directory.appendingPathComponent($0) }
  }

  // MARK: - Private

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private var decoder: JSONDecoder {
    JSONDecoder()
  }

  private func readFileLocked() throws -> Data? {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return nil
    }
    do {
      return try Data(contentsOf: fileURL)
    } catch {
      hasLoaded = false
      throw OutboxStoreError.unreadable(error.localizedDescription)
    }
  }

  private func writeLocked(_ commands: [OutboxCommand]) throws {
    let data = try encoder.encode(Envelope(version: Self.currentVersion, commands: commands))
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try writeData(data, fileURL)
  }

  private func quarantineLocked(_ data: Data, reason: String) throws {
    let stamp = Self.stampFormatter.string(from: now())
    let suffix = UUID().uuidString.prefix(8).lowercased()
    let url = directory.appendingPathComponent("outbox.\(stamp)-\(suffix).\(reason).quarantine.json")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try writeData(data, url)
  }

  private static let stampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter
  }()

  /// The UserDefaults queue as create commands, in their original order.
  /// Each keeps its UUID as the command id, so a migration that ran before
  /// (with the key left behind) is recognised rather than queued twice.
  private func legacyCommandsLocked(
    after existing: [OutboxCommand]
  ) -> (commands: [OutboxCommand], migrated: Bool, quarantined: Bool) {
    guard let data = defaults.data(forKey: Self.legacyDefaultsKey) else {
      return ([], false, false)
    }
    guard let pending = try? decoder.decode([PendingTransaction].self, from: data) else {
      do {
        try quarantineLocked(data, reason: "legacy-corrupt")
        quarantinedOnLastLoad = true
        return ([], false, true)
      } catch {
        return ([], false, false)
      }
    }
    let knownIDs = Set(existing.map(\.id))
    var seq = existing.map(\.seq).max() ?? 0
    var commands: [OutboxCommand] = []
    for item in pending where !knownIDs.contains(item.id) {
      seq += 1
      var request = item.request
      if request.importID == nil {
        // The legacy drain derived this key the same way when it sent.
        request.importID = item.id.uuidString.lowercased()
      }
      request.id = nil
      commands.append(
        OutboxCommand(
          id: item.id,
          seq: seq,
          transactionID: OutboxCommand.mintTransactionID(),
          connectionFingerprint: item.connectionFingerprint,
          createdAt: item.capturedAt,
          kind: .create(request),
          // Retried like every other queued capture, as the old drain did on
          // a refresh. The old build may already have sent it, without an
          // id, so nothing is folded into it.
          state: .queued,
          attempted: true
        )
      )
    }
    return (commands, true, false)
  }
}

extension OutboxCommand {
  /// The same shape as the server's own ids (`createId("txn")`).
  static func mintTransactionID() -> String {
    "txn_\(UUID().uuidString.lowercased())"
  }
}
