import Foundation

/// When and as which job a payload was shared.
struct IntakeHashEntry: Codable, Equatable, Sendable {
  var jobID: UUID
  var sharedAt: Date
}

/// What a share matched in the index.
struct IntakeHashMatch: Equatable, Sendable {
  var jobID: UUID
  var sharedAt: Date
  /// True when the whole share (every item together) was shared before. False
  /// when only some of its items were.
  var isWholeShare: Bool
}

/// Recent shares by hash, in the app group, so the share extension can warn
/// before the same document is sent twice. The app writes it (replacing the
/// whole file from its jobs); the extension only reads it. Foundation only:
/// both targets compile this file.
///
/// `{appGroup}/Intake/hashes.json`:
/// `{"content": {"<contentHash>": {"jobID", "sharedAt"}}, "sources": {"<sha256>": {...}}}`
/// Writes are atomic, so the extension reads the old file or the new one.
struct IntakeHashIndex: Sendable {
  /// Entries older than this are not kept and never match.
  static let window: TimeInterval = 30 * 24 * 3600

  struct Contents: Codable, Equatable, Sendable {
    var content: [String: IntakeHashEntry] = [:]
    var sources: [String: IntakeHashEntry] = [:]
  }

  let fileURL: URL

  init(container: URL = InboxStore.defaultContainer()) {
    fileURL = container
      .appendingPathComponent("Intake", isDirectory: true)
      .appendingPathComponent("hashes.json")
  }

  static let shared = IntakeHashIndex()

  func read() -> Contents {
    guard let data = try? Data(contentsOf: fileURL) else {
      return Contents()
    }
    return (try? Self.decoder().decode(Contents.self, from: data)) ?? Contents()
  }

  /// Replaces the file with these entries, dropping any older than the window.
  /// Skips the write when nothing changed.
  func replace(_ contents: Contents, now: Date = Date()) {
    let cutoff = now.addingTimeInterval(-Self.window)
    var next = Contents()
    // Whole seconds, as ISO 8601 stores them, so an unchanged index compares equal.
    func kept(_ entries: [String: IntakeHashEntry]) -> [String: IntakeHashEntry] {
      var result: [String: IntakeHashEntry] = [:]
      for (hash, entry) in entries where !hash.isEmpty && entry.sharedAt >= cutoff {
        let seconds = Date(timeIntervalSince1970: entry.sharedAt.timeIntervalSince1970.rounded(.down))
        result[hash] = IntakeHashEntry(jobID: entry.jobID, sharedAt: seconds)
      }
      return result
    }
    next.content = kept(contents.content)
    next.sources = kept(contents.sources)
    guard next != read() else {
      return
    }
    guard let data = try? Self.encoder().encode(next) else {
      return
    }
    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try? data.write(to: fileURL, options: .atomic)
  }

  /// The most recent earlier share of this payload, if any within the window.
  /// A whole-share match wins over a match on one item.
  func lookup(contentHash: String?, sourceHashes: [String], now: Date = Date()) -> IntakeHashMatch? {
    let cutoff = now.addingTimeInterval(-Self.window)
    let contents = read()
    if let contentHash, !contentHash.isEmpty,
       let entry = contents.content[contentHash], entry.sharedAt >= cutoff {
      return IntakeHashMatch(jobID: entry.jobID, sharedAt: entry.sharedAt, isWholeShare: true)
    }
    var latest: IntakeHashEntry?
    for hash in sourceHashes where !hash.isEmpty {
      guard let entry = contents.sources[hash], entry.sharedAt >= cutoff else {
        continue
      }
      if latest == nil || entry.sharedAt > latest!.sharedAt {
        latest = entry
      }
    }
    return latest.map { IntakeHashMatch(jobID: $0.jobID, sharedAt: $0.sharedAt, isWholeShare: false) }
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
