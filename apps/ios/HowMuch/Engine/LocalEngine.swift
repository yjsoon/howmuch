import Foundation
import JavaScriptCore
import OSLog
import Security

/// What the embedded backend needs to know about this install.
struct LocalEngineConfig: Codable, Equatable {
  /// The per-install secret the engine accepts as its API token.
  var apiToken: String
  var defaultPlanId: String
  /// The plan's home time zone, used for the daily schedule catch-up.
  var timeZone: String
  /// Seeds the plan only when `configure` creates it; an existing plan keeps
  /// its settings.
  var newPlanSettings: PlanSettingsSeed? = nil
}

struct LocalEngineResponse: Equatable {
  var status: Int
  var headers: [String: String]
  var body: Data
}

/// Mirrors the Worker cron's count-only summary.
struct ScheduledMaterializationSummary: Decodable, Equatable {
  let throughDate: String
  let occurrenceCount: Int
  let skippedClosedScheduleCount: Int
  let failureCount: Int
  let hasMore: Bool
}

enum LocalEngineError: LocalizedError {
  case missingBundle
  case javaScript(String)
  case unsettled(String)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .missingBundle:
      return "The app is missing its on-device engine."
    case .javaScript(let message):
      return "The on-device engine failed: \(message)"
    case .unsettled(let operation):
      return "The on-device engine did not finish \(operation)."
    case .invalidResponse:
      return "The on-device engine returned an invalid response."
    }
  }
}

/// Runs the HowMuch backend (`apps/api`, bundled as `howmuch-engine.js`) in
/// JavaScriptCore over an on-device SQLite database, so local mode answers the
/// same HTTP contract as the server.
///
/// One serial queue owns the JSContext and the SQLite handle. Both are created
/// lazily on that queue, never on the main thread. Every SQL statement is
/// synchronous, so each request settles within the call that starts it.
final class LocalEngine: @unchecked Sendable {
  /// Requests are routed here as though to a server at this origin.
  static let origin = "https://local.howmuch"

  private static let logger = Logger(subsystem: "sg.soon.howmuch", category: "LocalEngine")
  private static let sharedLock = NSLock()
  private static var sharedEngine: LocalEngine?

  /// The install's engine, over `Application Support/HowMuch/Local/howmuch.sqlite`.
  static var shared: LocalEngine {
    sharedLock.lock()
    defer { sharedLock.unlock() }
    if let sharedEngine {
      return sharedEngine
    }
    let engine = LocalEngine(databaseURL: defaultDatabaseURL)
    sharedEngine = engine
    return engine
  }

  static var defaultDatabaseURL: URL {
    URL.applicationSupportDirectory
      .appending(path: "HowMuch", directoryHint: .isDirectory)
      .appending(path: "Local", directoryHint: .isDirectory)
      .appending(path: "howmuch.sqlite", directoryHint: .notDirectory)
  }

#if DEBUG
  /// Points `shared` at an engine the caller owns, so a test never touches the
  /// installed app's ledger. Returns the previous engine for the test to restore.
  @discardableResult
  static func useShared(_ engine: LocalEngine?) -> LocalEngine? {
    sharedLock.lock()
    defer { sharedLock.unlock() }
    let previous = sharedEngine
    sharedEngine = engine
    return previous
  }
#endif

  let databaseURL: URL
  private let bundle: Bundle
  private let queue = DispatchQueue(label: "sg.soon.howmuch.local-engine", qos: .userInitiated)

  // Confined to `queue`.
  private var database: LocalDatabase?
  private var context: JSContext?
  private var invoke: JSValue?
  private var configured: LocalEngineConfig?
  private var pendingException: String?

  init(databaseURL: URL, bundle: Bundle = .main) {
    self.databaseURL = databaseURL
    self.bundle = bundle
  }

  /// Performs one API request. `path` is percent-encoded and starts with `/`;
  /// `query` is the percent-encoded query string without its `?`.
  func handle(
    config: LocalEngineConfig,
    method: String,
    path: String,
    query: String?,
    headers: [String: String],
    body: Data?
  ) async throws -> LocalEngineResponse {
    let url = Self.origin + path + (query.map { $0.isEmpty ? "" : "?" + $0 } ?? "")
    let headersJSON = String(decoding: try JSONSerialization.data(withJSONObject: headers), as: UTF8.self)
    let bodyText: Any = body.map { String(decoding: $0, as: UTF8.self) } ?? NSNull()
    return try await perform(config: config) { engine in
      let raw = try engine.call("handle", [method, url, headersJSON, bodyText])
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
        let status = object["status"] as? Int
      else {
        throw LocalEngineError.invalidResponse
      }
      return LocalEngineResponse(
        status: status,
        headers: object["headers"] as? [String: String] ?? [:],
        body: Data((object["body"] as? String ?? "").utf8)
      )
    }
  }

  /// Materialises due scheduled transactions, as the Worker's daily cron does.
  func runScheduledMaterialization(config: LocalEngineConfig, now: Date = .now) async throws -> ScheduledMaterializationSummary {
    try await perform(config: config) { engine in
      let raw = try engine.call("runScheduledMaterialization", [now.timeIntervalSince1970 * 1000])
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      return try decoder.decode(ScheduledMaterializationSummary.self, from: Data(raw.utf8))
    }
  }

  /// The live plans already in the on-device database, read without starting
  /// the engine (configuring it creates its plan). Empty when there is no
  /// database yet.
  func livePlanIDs() async throws -> [String] {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        continuation.resume(with: Swift.Result {
          if let database = self.database {
            return try Self.livePlanIDs(in: database)
          }
          guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
            return []
          }
          return try Self.livePlanIDs(in: LocalDatabase(url: self.databaseURL))
        })
      }
    }
  }

  private static func livePlanIDs(in database: LocalDatabase) throws -> [String] {
    let hasPlans = try database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'plans'")
    guard !hasPlans.isEmpty else {
      return []
    }
    return try database.query("SELECT id FROM plans WHERE deleted = 0 ORDER BY id").compactMap { $0["id"] as? String }
  }

  /// Opens the database, applies migrations and evaluates the bundle ahead of
  /// the first request.
  func prepare(config: LocalEngineConfig) async throws {
    try await perform(config: config) { _ in () }
  }

  private func perform<Result>(
    config: LocalEngineConfig,
    _ work: @escaping (LocalEngine) throws -> Result
  ) async throws -> Result {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        continuation.resume(with: Swift.Result {
          try self.ensureConfigured(config)
          return try work(self)
        })
      }
    }
  }

  // MARK: - Queue-confined

  private func ensureConfigured(_ config: LocalEngineConfig) throws {
    if context == nil {
      try start()
    }
    guard configured != config else {
      return
    }
    let configJSON = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
    _ = try call("configure", [configJSON])
    configured = config
  }

  private func start() throws {
    let started = Date.now
    let database = try LocalDatabase(url: databaseURL)
    let applied = try database.migrate(try LocalMigration.bundled(in: bundle))
    guard
      let sourceURL = bundle.url(forResource: "howmuch-engine", withExtension: "js"),
      let source = try? String(contentsOf: sourceURL, encoding: .utf8),
      let context = JSContext()
    else {
      throw LocalEngineError.missingBundle
    }
    context.name = "HowMuch engine"
    context.exceptionHandler = { [weak self] _, exception in
      let message = exception?.toString() ?? "unknown error"
      let stack = exception?.objectForKeyedSubscript("stack")?.toString() ?? ""
      self?.pendingException = stack.isEmpty ? message : "\(message)\n\(stack)"
    }

    let log: @convention(block) (String) -> Void = { message in
      Self.logger.debug("\(message, privacy: .private)")
    }
    context.setObject(log, forKeyedSubscript: "__log" as NSString)
    context.evaluateScript("""
      var console = { log: function () { __log(Array.prototype.map.call(arguments, String).join(" ")); } };
      console.info = console.warn = console.error = console.debug = console.log;
      """)

    let exec: @convention(block) (String, String) -> String = { sql, parameters in
      database.execJSON(sql, parametersJSON: parameters)
    }
    let sqlite = JSValue(newObjectIn: context)
    sqlite?.setObject(exec, forKeyedSubscript: "exec" as NSString)
    context.setObject(sqlite, forKeyedSubscript: "__sqlite" as NSString)

    let random: @convention(block) (Int) -> [Int] = { count in
      var bytes = [UInt8](repeating: 0, count: max(0, count))
      if !bytes.isEmpty {
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      }
      return bytes.map(Int.init)
    }
    context.setObject(random, forKeyedSubscript: "__random" as NSString)

    pendingException = nil
    context.evaluateScript(source, withSourceURL: sourceURL)
    if let exception = pendingException {
      throw LocalEngineError.javaScript(exception)
    }
    // Settles a promise-returning engine call into a plain box. Microtasks
    // drain when the host call returns, so a synchronous backend has always
    // settled by then.
    invoke = context.evaluateScript("""
      (function (name, args) {
        var box = { done: false };
        var fail = function (error) { box.done = true; box.error = String((error && error.stack) || error); };
        try {
          Promise.resolve(__howmuch[name].apply(null, args)).then(function (value) {
            box.done = true;
            box.value = JSON.stringify(value === undefined ? null : value);
          }, fail);
        } catch (error) {
          fail(error);
        }
        return box;
      })
      """)
    guard invoke?.isObject == true else {
      throw LocalEngineError.missingBundle
    }
    self.database = database
    self.context = context
    Self.logger.info("Local engine ready in \(Int(Date.now.timeIntervalSince(started) * 1000)) ms; applied \(applied.count) migrations")
  }

  private func call(_ name: String, _ arguments: [Any]) throws -> String {
    guard let context, let invoke else {
      throw LocalEngineError.missingBundle
    }
    pendingException = nil
    guard let box = invoke.call(withArguments: [name, arguments]) else {
      throw LocalEngineError.invalidResponse
    }
    if box.objectForKeyedSubscript("done")?.toBool() != true {
      // Belt and braces: give the microtask queue one more turn.
      context.evaluateScript("void 0")
    }
    if let exception = pendingException {
      throw LocalEngineError.javaScript(exception)
    }
    guard box.objectForKeyedSubscript("done")?.toBool() == true else {
      throw LocalEngineError.unsettled(name)
    }
    if let error = box.objectForKeyedSubscript("error"), !error.isUndefined {
      throw LocalEngineError.javaScript(error.toString() ?? "unknown error")
    }
    return box.objectForKeyedSubscript("value")?.toString() ?? "null"
  }
}
