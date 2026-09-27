import CryptoKit
import Foundation

// Moving an on-device ledger to a server. The rules here are pure; the
// requests that feed them live in `ServerConnector` and `AppModel`.

/// What a server plan already holds, counted the way `import_snapshot`
/// decides whether a plan is empty.
struct ServerPlanContents: Equatable {
  var accounts = 0
  var hasTransactions = false
  var scheduledTransactions = 0
  var payees = 0
  var categoryGroups = 0
  var categories = 0

  /// Counts live rows. Closed accounts are live: the server's rule is
  /// `deleted = 0`, not "open". The API does not report which categories are
  /// internal (YNAB bookkeeping rows), so every live one counts. Only an
  /// imported YNAB plan has internal rows, and the server refuses to import
  /// into one of those anyway.
  init(
    accounts: [Account],
    hasTransactions: Bool,
    scheduledTransactions: [ScheduledTransaction],
    payees: [Payee],
    categoryGroups: [CategoryGroup]
  ) {
    let liveGroups = categoryGroups.filter { !$0.deleted }
    self.accounts = accounts.filter { !$0.deleted }.count
    self.hasTransactions = hasTransactions
    self.scheduledTransactions = scheduledTransactions.filter { !$0.deleted }.count
    self.payees = payees.filter { $0.deleted != true }.count
    self.categoryGroups = liveGroups.count
    self.categories = liveGroups.flatMap(\.categories).filter { !$0.deleted }.count
  }

  /// A plan the server would accept a snapshot into: no live accounts,
  /// transactions, schedules, payees, categories or category groups.
  var isEmpty: Bool {
    accounts == 0 && !hasTransactions && scheduledTransactions == 0
      && payees == 0 && categoryGroups == 0 && categories == 0
  }
}

enum SnapshotImport {
  /// The same local plan sent to the same server plan always uses the same
  /// key, so a retry after a lost response replays instead of importing
  /// twice. Plan ids can hold characters the key does not allow, so they are
  /// hashed: 8–128 of `A–Z a–z 0–9 . _ : -`.
  static func idempotencyKey(localPlanID: String, serverPlanID: String) -> String {
    let digest = SHA256.hash(data: Data("\(localPlanID)\n\(serverPlanID)".utf8))
    return "snapshot-import:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  /// `{"snapshot": …}` around the snapshot bytes, which are never re-encoded.
  static func requestBody(snapshot: Data) -> Data {
    var body = Data(#"{"snapshot":"#.utf8)
    body.append(snapshot)
    body.append(Data("}".utf8))
    return body
  }

  /// The snapshot object inside an `export_snapshot` response, as bytes.
  static func snapshot(fromExportResponse data: Data) throws -> Data {
    guard
      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let payload = envelope["data"] as? [String: Any],
      let snapshot = payload["snapshot"] as? [String: Any]
    else {
      throw APIClientError.decoding("The export has no snapshot.")
    }
    return try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
  }

  struct Summary: Equatable {
    var accounts: Int
    var transactions: Int
    /// Whether the upload fits the server's request limit.
    var fitsOneRequest: Bool
  }

  static func summary(of snapshot: Data) throws -> Summary {
    guard let object = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] else {
      throw APIClientError.decoding("The snapshot is not an object.")
    }
    func live(_ key: String) -> Int {
      (object[key] as? [[String: Any]] ?? []).filter { ($0["deleted"] as? Bool) != true }.count
    }
    return Summary(
      accounts: live("accounts"),
      transactions: live("transactions"),
      fitsOneRequest: requestBody(snapshot: snapshot).count <= APIClient.snapshotByteLimit
    )
  }

  /// How an import that failed is handled.
  enum Failure: Equatable {
    /// The server plan has a ledger now: offer the choice instead.
    case serverHasData
    /// Look at the server plan again: this key was used for a different
    /// snapshot, or an id already exists on the server.
    case recheck(String)
    case tooLarge
    /// The server will never accept this upload; trying again cannot help.
    case refused(String)
    case failed(String)
  }

  static let ynabMirrorMessage = "This plan was imported from YNAB, so it can’t receive uploads."
  static let ownerRequiredMessage = "Only the plan’s owner can upload to it."

  static func failure(for error: Error) -> Failure {
    switch error {
    case APIClientError.planNotEmpty:
      return .serverHasData
    case APIClientError.ynabMirrorPlan:
      return .refused(ynabMirrorMessage)
    case APIClientError.ownerRequired:
      return .refused(ownerRequiredMessage)
    case APIClientError.conflict(let message):
      return .recheck(message)
    case APIClientError.payloadTooLarge:
      return .tooLarge
    default:
      return .failed(error.localizedDescription)
    }
  }
}

/// The on-device ledger left behind when an install moves to a server. The
/// database file is not moved or changed; this only records where it is.
struct LocalArchive: Codable, Equatable {
  static let userDefaultsKey = "HowMuch.LocalArchive"

  /// Relative to Application Support where possible, because the app's
  /// container path changes between installs and updates.
  var path: String
  var planID: String
  var archivedAt: Date

  init(databaseURL: URL, planID: String, archivedAt: Date) {
    let base = URL.applicationSupportDirectory.standardizedFileURL.path + "/"
    let full = databaseURL.standardizedFileURL.path
    self.path = full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full
    self.planID = planID
    self.archivedAt = archivedAt
  }

  var databaseURL: URL {
    path.hasPrefix("/")
      ? URL(fileURLWithPath: path)
      : URL.applicationSupportDirectory.appending(path: path, directoryHint: .notDirectory)
  }

  /// Settings that reach the archived ledger through the engine, without
  /// being saved: a fresh engine token and the archive's plan.
  var engineSettings: APISettings {
    APISettings(
      baseURLString: APISettings.localBaseURL,
      sessionToken: APISettings.randomEngineToken(),
      authenticatedUserID: APISettings.localUserID,
      planID: planID,
      mode: .local
    )
  }

  static func load(from defaults: UserDefaults = .standard) -> LocalArchive? {
    defaults.data(forKey: userDefaultsKey).flatMap { try? JSONDecoder().decode(LocalArchive.self, from: $0) }
  }

  /// The recorded archive, if its database is still on the device.
  static func existing(in defaults: UserDefaults = .standard) -> LocalArchive? {
    guard let archive = load(from: defaults),
          FileManager.default.fileExists(atPath: archive.databaseURL.path)
    else {
      return nil
    }
    return archive
  }

  func save(to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.userDefaultsKey)
    }
  }

  static func clear(in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: userDefaultsKey)
  }
}

/// Saving the switch between the on-device ledger and a server.
enum ConnectionSwitch {
  struct Adoption: Equatable {
    var settings: APISettings
    /// A session for the same server that this one replaced in the Keychain.
    /// The caller signs it out.
    var supersededToken: String?
  }

  /// Moves to the server and records the on-device ledger as an archive.
  static func adoptServer(
    _ server: APISettings,
    leaving local: APISettings,
    databaseURL: URL,
    in defaults: UserDefaults = .standard,
    now: Date = .now
  ) -> Adoption {
    let previous = APISettings.savedSessionToken(forBaseURL: server.baseURLString)
    LocalArchive(databaseURL: databaseURL, planID: local.planID, archivedAt: now).save(to: defaults)
    server.save(to: defaults)
    return Adoption(settings: server, supersededToken: previous == server.sessionToken ? nil : previous)
  }

  /// Returns to the archived ledger and forgets the server session. The
  /// caller signs that session out; connecting again means signing in.
  static func returnToArchive(leaving server: APISettings, in defaults: UserDefaults = .standard) -> APISettings? {
    guard let archive = LocalArchive.load(from: defaults) else {
      return nil
    }
    defaults.set(archive.planID, forKey: APISettings.localPlanIDKey)
    let local = APISettings.local(in: defaults)
    local.save(to: defaults)
    APISettings.forgetSavedSession(forBaseURL: server.baseURLString)
    LocalArchive.clear(in: defaults)
    return local
  }

  /// Why the app cannot leave this server yet, if it can't: changes saved
  /// while offline are still waiting to be sent, and local mode would hide them.
  /// Counts every command for this server, whichever user or plan stamped
  /// it: a session that expired changes the fingerprint, but its changes still
  /// wait for this server and local mode would hide them just the same.
  static func blockReason(outbox: [OutboxCommand], settings: APISettings) -> String? {
    let endpoints = [settings.normalizedBaseURLString, settings.trimmedBaseURL]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .map { $0 + "|" }
    let unsent = outbox.filter { command in
      settings.matchesCurrentOrLegacyOutboxStamp(command.connectionFingerprint)
        || endpoints.contains { command.connectionFingerprint.hasPrefix($0) }
    }.count
    guard unsent > 0 else {
      return nil
    }
    let noun = unsent == 1 ? "change hasn’t" : "changes haven’t"
    return "\(unsent) \(noun) reached the server yet. Connect to the internet and try again."
  }
}
