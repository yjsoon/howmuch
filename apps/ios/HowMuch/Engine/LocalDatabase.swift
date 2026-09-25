import Foundation
import SQLite3

/// One schema migration shipped in the app bundle, copied verbatim from
/// `apps/api/d1-migrations` by `bun run build:ios-engine`.
struct LocalMigration: Equatable {
  let name: String
  let sql: String

  /// The migrations still to apply, in the order D1 applies them.
  static func pending(available: [LocalMigration], applied: Set<String>) -> [LocalMigration] {
    available
      .filter { !applied.contains($0.name) }
      .sorted { $0.name < $1.name }
  }

  static func bundled(in bundle: Bundle = .main) throws -> [LocalMigration] {
    guard let directory = bundle.url(forResource: "migrations", withExtension: nil) else {
      throw LocalDatabaseError.missingResource("migrations")
    }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "sql" }
      .map { LocalMigration(name: $0.lastPathComponent, sql: try String(contentsOf: $0, encoding: .utf8)) }
      .sorted { $0.name < $1.name }
  }
}

enum LocalDatabaseError: LocalizedError {
  case missingResource(String)
  case sqlite(String)
  case migration(name: String, message: String)

  var errorDescription: String? {
    switch self {
    case .missingResource(let name):
      return "The app is missing its \(name) resource."
    case .sqlite(let message):
      return "The on-device database failed: \(message)"
    case .migration(let name, let message):
      return "Couldn’t update the on-device database (\(name)): \(message)"
    }
  }
}

/// The on-device SQLite database that stands in for D1. Not thread-safe: the
/// `LocalEngine` queue is its only user.
final class LocalDatabase {
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  private var handle: OpaquePointer?

  init(url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // App intents and background work run before the first unlock completes
    // only rarely, but after it they must be able to read the ledger.
    try? FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: directory.path
    )
    var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
#if os(iOS)
    flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
#endif
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      sqlite3_close(handle)
      handle = nil
      throw LocalDatabaseError.sqlite(message)
    }
    try execute("PRAGMA journal_mode = WAL")
    try execute("PRAGMA foreign_keys = ON")
    try execute("PRAGMA busy_timeout = 5000")
  }

  deinit {
    sqlite3_close_v2(handle)
  }

  /// Applies every bundled migration this database has not recorded, each in
  /// its own transaction. Returns the names applied.
  ///
  /// Foreign keys are switched off around each migration, as SQLite's
  /// table-rebuild procedure requires (the pragma is a no-op inside a
  /// transaction), and `foreign_key_check` must pass before the commit.
  @discardableResult
  func migrate(_ available: [LocalMigration]) throws -> [String] {
    try execute("CREATE TABLE IF NOT EXISTS _local_migrations (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL DEFAULT (unixepoch()))")
    let applied = Set(try query("SELECT name FROM _local_migrations").compactMap { $0["name"] as? String })
    var names: [String] = []
    for migration in LocalMigration.pending(available: available, applied: applied) {
      try execute("PRAGMA foreign_keys = OFF")
      defer { try? execute("PRAGMA foreign_keys = ON") }
      try execute("BEGIN IMMEDIATE")
      do {
        try execute(migration.sql)
        try query("INSERT INTO _local_migrations(name) VALUES(?)", [migration.name])
        if let violation = try query("PRAGMA foreign_key_check").first {
          throw LocalDatabaseError.sqlite("foreign key check failed on \(violation["table"] ?? "a table")")
        }
        try execute("COMMIT")
      } catch {
        try? execute("ROLLBACK")
        throw LocalDatabaseError.migration(name: migration.name, message: error.localizedDescription)
      }
      names.append(migration.name)
    }
    return names
  }

  /// The bridge the engine's D1 binding calls: one statement, JSON parameters
  /// in, `{"rows":[...],"changes":n}` or `{"error":"..."}` out.
  func execJSON(_ sql: String, parametersJSON: String) -> String {
    do {
      let parameters = try JSONSerialization.jsonObject(with: Data(parametersJSON.utf8)) as? [Any] ?? []
      let (rows, changes) = try run(sql, parameters)
      return Self.json(["rows": rows, "changes": changes])
    } catch {
      let message = (error as? LocalDatabaseError).flatMap {
        if case .sqlite(let message) = $0 { return message }
        return nil
      } ?? error.localizedDescription
      return Self.json(["error": message])
    }
  }

  func execute(_ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
      let text = message.map { String(cString: $0) } ?? lastError
      sqlite3_free(message)
      throw LocalDatabaseError.sqlite(text)
    }
  }

  @discardableResult
  func query(_ sql: String, _ parameters: [Any] = []) throws -> [[String: Any]] {
    try run(sql, parameters).rows
  }

  private var lastError: String {
    String(cString: sqlite3_errmsg(handle))
  }

  private func run(_ sql: String, _ parameters: [Any]) throws -> (rows: [[String: Any]], changes: Int) {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw LocalDatabaseError.sqlite(lastError)
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in parameters.enumerated() {
      try bind(value, at: Int32(offset + 1), in: statement)
    }
    var rows: [[String: Any]] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE {
        break
      }
      guard code == SQLITE_ROW else {
        throw LocalDatabaseError.sqlite(lastError)
      }
      rows.append(row(of: statement))
    }
    // A read leaves `sqlite3_changes` at the previous write's count.
    let changes = sqlite3_stmt_readonly(statement) != 0 ? 0 : Int(sqlite3_changes(handle))
    return (rows, changes)
  }

  private func bind(_ value: Any, at index: Int32, in statement: OpaquePointer?) throws {
    let code: Int32
    switch value {
    case is NSNull:
      code = sqlite3_bind_null(statement, index)
    case let text as String:
      code = sqlite3_bind_text(statement, index, text, -1, Self.transient)
    case let number as NSNumber:
      let double = number.doubleValue
      if CFNumberIsFloatType(number) == false || (double == double.rounded() && abs(double) < 9_007_199_254_740_992) {
        code = sqlite3_bind_int64(statement, index, number.int64Value)
      } else {
        code = sqlite3_bind_double(statement, index, double)
      }
    default:
      let data = try JSONSerialization.data(withJSONObject: value)
      code = sqlite3_bind_text(statement, index, String(decoding: data, as: UTF8.self), -1, Self.transient)
    }
    guard code == SQLITE_OK else {
      throw LocalDatabaseError.sqlite(lastError)
    }
  }

  private func row(of statement: OpaquePointer?) -> [String: Any] {
    var row: [String: Any] = [:]
    for column in 0 ..< sqlite3_column_count(statement) {
      let name = String(cString: sqlite3_column_name(statement, column))
      switch sqlite3_column_type(statement, column) {
      case SQLITE_INTEGER:
        row[name] = sqlite3_column_int64(statement, column)
      case SQLITE_FLOAT:
        row[name] = sqlite3_column_double(statement, column)
      case SQLITE_TEXT:
        let count = Int(sqlite3_column_bytes(statement, column))
        if let bytes = sqlite3_column_text(statement, column) {
          row[name] = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        } else {
          row[name] = ""
        }
      case SQLITE_BLOB:
        let count = Int(sqlite3_column_bytes(statement, column))
        let bytes = sqlite3_column_blob(statement, column)?.assumingMemoryBound(to: UInt8.self)
        row[name] = bytes.map { Array(UnsafeBufferPointer(start: $0, count: count)).map(Int.init) } ?? []
      default:
        row[name] = NSNull()
      }
    }
    return row
  }

  private static func json(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
      return #"{"error":"The database returned a value that is not JSON"}"#
    }
    return String(decoding: data, as: UTF8.self)
  }
}
