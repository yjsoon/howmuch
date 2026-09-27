import Foundation

/// #176: the reference set as it stood at one observed plan cursor, written to
/// the app container so a warm launch can render the Accounts tab and the
/// register's first page before any network response arrives.
///
/// The five reference GETs carry no `server_knowledge` of their own — only the
/// transaction and schedule payloads do (see `TransactionsPayload`). So the
/// snapshot is tagged with the cursor the *ledger* fetch observed, which is the
/// same cursor `AppModel.serverKnowledge` holds and the reports cache (#180) is
/// keyed on. A snapshot whose cursor equals the one the network returns
/// describes the same plan state, which is what lets the ledger apply be
/// skipped.
/// The identity every on-device cache is tagged with, so one set of rules
/// decides whether a file found on disk belongs to the current connection.
protocol ConnectionScopedSnapshot {
  var schemaVersion: Int { get }
  var connectionFingerprint: String { get }
  var authenticatedUserID: String { get }
  var planID: String { get }
}

struct ReferenceSnapshot: Codable, Equatable, ConnectionScopedSnapshot {
  /// Bumped whenever the stored shape changes. A snapshot written by an older
  /// build is deleted rather than migrated: it can always be refetched.
  ///
  /// 2: carries the plan-wide unapproved count (#181's badge).
  static let currentSchemaVersion = 2

  /// One bounded ledger page, stored exactly as the network returned it.
  /// `TransactionPage` itself is not `Codable` and carries no identity, so the
  /// snapshot keeps its own shape.
  struct LedgerPage: Codable, Equatable {
    var transactions: [Transaction]
    var hasMore: Bool
    var nextOffset: Int?
  }

  var schemaVersion: Int
  /// `APISettings.connectionFingerprint`: endpoint, plan and signed-in user.
  var connectionFingerprint: String
  /// Kept beside the fingerprint so the "never apply another user's data" rule
  /// is checked on its own terms rather than inferred from a joined string.
  var authenticatedUserID: String
  var planID: String
  /// The cursor observed on the ledger fetch that produced `ledgerPage`.
  var serverKnowledge: Int?
  var capturedAt: Date

  var planSettings: PlanSettings?
  var accounts: [Account]
  var categoryGroups: [CategoryGroup]
  var payees: [Payee]
  /// Stored for completeness of the reference set, but deliberately not
  /// applied on restore: `ScopedViewPrefsStore` already persists the device's
  /// account arrangement, and the reconciliation between local and server
  /// revisions belongs to `refreshReferenceData`, which runs moments later.
  var accountPreferences: SyncedAccountPreferences?
  var scheduledTransactions: [ScheduledTransaction]
  var ledgerPage: LedgerPage?
  /// The plan-wide "New" count as the server last reported it (#181). The
  /// queue's rows are deliberately not stored: since #197 they are loaded only
  /// when the approval flow opens, and a count is one small number that keeps
  /// the tile from flashing 0 on a warm launch.
  var unapprovedCount: Int?

  init(
    schemaVersion: Int = ReferenceSnapshot.currentSchemaVersion,
    connectionFingerprint: String,
    authenticatedUserID: String,
    planID: String,
    serverKnowledge: Int?,
    capturedAt: Date = Date(),
    planSettings: PlanSettings?,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee],
    accountPreferences: SyncedAccountPreferences?,
    scheduledTransactions: [ScheduledTransaction],
    ledgerPage: LedgerPage?,
    unapprovedCount: Int? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.connectionFingerprint = connectionFingerprint
    self.authenticatedUserID = authenticatedUserID
    self.planID = planID
    self.serverKnowledge = serverKnowledge
    self.capturedAt = capturedAt
    self.planSettings = planSettings
    self.accounts = accounts
    self.categoryGroups = categoryGroups
    self.payees = payees
    self.accountPreferences = accountPreferences
    self.scheduledTransactions = scheduledTransactions
    self.ledgerPage = ledgerPage
    self.unapprovedCount = unapprovedCount
  }
}

/// The functional core of #176: whether a snapshot found on disk may be put on
/// screen. Pure, so every rejection rule is a unit test rather than a launch.
enum SnapshotPolicy {
  enum Rejection: Equatable {
    case notAuthenticated
    case noPlanSelected
    case schemaMismatch
    case differentConnection
    case differentUser
    case differentPlan
    case empty
  }

  /// `nil` means the snapshot may be applied.
  static func rejection(
    snapshot: ReferenceSnapshot,
    settings: APISettings,
    schemaVersion: Int = ReferenceSnapshot.currentSchemaVersion
  ) -> Rejection? {
    if let rejection = connectionRejection(snapshot: snapshot, settings: settings, schemaVersion: schemaVersion) {
      return rejection
    }
    // A snapshot with no accounts renders the same empty placeholder a cold
    // launch does, so it buys nothing and is not worth the risk of showing.
    guard !snapshot.accounts.isEmpty else {
      return .empty
    }
    return nil
  }

  /// The rules every connection-scoped cache shares: signed in, a plan
  /// chosen, the current schema, and the same endpoint, user and plan.
  static func connectionRejection(
    snapshot: some ConnectionScopedSnapshot,
    settings: APISettings,
    schemaVersion: Int
  ) -> Rejection? {
    guard settings.isAuthenticated else {
      return .notAuthenticated
    }
    guard !settings.planID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .noPlanSelected
    }
    guard snapshot.schemaVersion == schemaVersion else {
      return .schemaMismatch
    }
    guard snapshot.connectionFingerprint == settings.connectionFingerprint else {
      return .differentConnection
    }
    // The fingerprint already joins these two in, but a snapshot that named a
    // different user or plan must never be applied on the strength of one
    // string comparison against a joined value.
    guard snapshot.authenticatedUserID == settings.authenticatedUserID,
          !snapshot.authenticatedUserID.isEmpty else {
      return .differentUser
    }
    guard snapshot.planID == settings.planID else {
      return .differentPlan
    }
    return nil
  }

  static func shouldApply(
    snapshot: ReferenceSnapshot,
    settings: APISettings,
    schemaVersion: Int = ReferenceSnapshot.currentSchemaVersion
  ) -> Bool {
    rejection(snapshot: snapshot, settings: settings, schemaVersion: schemaVersion) == nil
  }

  /// Whether the ledger page the network just returned can be skipped because
  /// the rows already on screen came from a snapshot taken at the same cursor.
  ///
  /// Both tests are required, and each catches what the other cannot:
  ///
  /// - **Equal cursors** prove the plan is at the revision the snapshot was
  ///   taken at, so the *contents* of those rows cannot have changed. Ids
  ///   alone would not: editing a memo leaves the page's ids identical while
  ///   the rows differ.
  /// - **Equal ids, in order** prove the response covers the same window.
  ///   The cursor alone would not: `APIClient.transactionPageSize` is a
  ///   compile-time constant that is not part of the snapshot's schema
  ///   version, so a build that widens the page returns rows at the same
  ///   cursor that the snapshot never held. Skipping then would lose them for
  ///   the session.
  ///
  /// A `nil` cursor on either side proves nothing and never skips.
  static func ledgerApplyIsRedundant(
    isProvisional: Bool,
    snapshotKnowledge: Int?,
    responseKnowledge: Int?,
    snapshotRowIDs: [String],
    responseRowIDs: [String]
  ) -> Bool {
    guard isProvisional,
          let snapshotKnowledge,
          let responseKnowledge,
          snapshotKnowledge == responseKnowledge else {
      return false
    }
    return snapshotRowIDs == responseRowIDs
  }
}

/// Load / save / delete for one snapshot file. The directory is injectable so
/// tests never touch the real Application Support container.
class SnapshotFile<Value: Codable>: @unchecked Sendable {
  let directory: URL
  let fileName: String

  private let fileManager: FileManager
  private let lock = NSLock()
  /// Internal rather than private so tests can hold the writer while they
  /// queue several writes.
  let ioQueue: DispatchQueue
  private let encoder: JSONEncoder
  /// Used only on `ioQueue`, so the synchronous `save` never shares an encoder
  /// with a background drain.
  private let backgroundEncoder: JSONEncoder
  private let decoder: JSONDecoder
  /// Bumped by `delete()`, so a write already queued behind a sign-out cannot
  /// land after it and resurrect the file.
  private var generation = 0
  /// The latest value waiting for `ioQueue`, with the generation it was
  /// scheduled under. Guarded by `lock`. A newer schedule replaces an older
  /// one that has not been encoded yet, so a burst of refresh slices costs one
  /// encode and one write rather than one each.
  private var pendingWrite: (value: Value, generation: Int)?
  private var isDrainQueued = false
  /// Files written, guarded by `lock`; lets tests see that queued writes coalesce.
  private var writtenCount = 0

  init(directory: URL, fileName: String, fileManager: FileManager = .default) {
    self.directory = directory
    self.fileName = fileName
    self.fileManager = fileManager
    self.ioQueue = DispatchQueue(label: "sg.soon.howmuch.snapshot.\(fileName)")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder
    let backgroundEncoder = JSONEncoder()
    backgroundEncoder.dateEncodingStrategy = .iso8601
    self.backgroundEncoder = backgroundEncoder
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  var fileURL: URL {
    directory.appendingPathComponent(fileName)
  }

  /// Synchronous by design: `AppModel.init` runs before the first frame, and a
  /// few hundred KB of JSON decodes in milliseconds. A corrupt or unreadable
  /// file deletes itself rather than being retried on every launch.
  func load() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try? Data(contentsOf: fileURL) else {
      return nil
    }
    guard let value = try? decoder.decode(Value.self, from: data) else {
      deleteLocked()
      return nil
    }
    return value
  }

  /// Encodes and writes on `ioQueue`, off the main actor that calls this after
  /// every refresh slice and save. The stored values are trees of plain
  /// values, so the copy handed over cannot change underneath the encoder.
  func scheduleWrite(_ value: Value) {
    lock.lock()
    pendingWrite = (value: value, generation: generation)
    let needsDrain = !isDrainQueued
    isDrainQueued = true
    lock.unlock()
    guard needsDrain else {
      return
    }
    ioQueue.async { [weak self] in
      self?.drainPendingWrite()
    }
  }

  private func drainPendingWrite() {
    lock.lock()
    let pending = pendingWrite
    pendingWrite = nil
    isDrainQueued = false
    lock.unlock()
    guard let pending, let data = try? backgroundEncoder.encode(pending.value) else {
      return
    }
    write(data, ifGeneration: pending.generation)
  }

  /// Same write, synchronously — used by tests and by any caller that needs
  /// the file on disk before it returns.
  @discardableResult
  func save(_ value: Value) -> Bool {
    guard let data = try? encoder.encode(value) else {
      return false
    }
    lock.lock()
    let generation = self.generation
    lock.unlock()
    return write(data, ifGeneration: generation)
  }

  func delete() {
    lock.lock()
    defer { lock.unlock() }
    generation &+= 1
    pendingWrite = nil
    deleteLocked()
  }

  func waitForPendingWrites() {
    ioQueue.sync {}
  }

  var completedWriteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return writtenCount
  }

  /// Byte size of the file on disk, or `nil` when there is none. Used to keep
  /// an eye on the cost of the cache.
  func fileSize() -> Int? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path) else {
      return nil
    }
    return attributes[.size] as? Int
  }

  @discardableResult
  private func write(_ data: Data, ifGeneration expected: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard expected == generation else {
      return false
    }
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      excludeDirectoryFromBackupLocked()
      // `.atomic` writes a temporary file and renames it into place, so a
      // launch reading while this runs sees either the whole previous
      // snapshot or the whole new one, never a half-written file.
      try data.write(to: fileURL, options: .atomic)
      writtenCount += 1
      return true
    } catch {
      return false
    }
  }

  private func deleteLocked() {
    try? fileManager.removeItem(at: fileURL)
  }

  /// Set on the directory rather than the file: an atomic write replaces the
  /// file's inode, which would drop a per-file flag.
  private func excludeDirectoryFromBackupLocked() {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var url = directory
    try? url.setResourceValues(values)
  }
}

/// The reference snapshot's file.
///
/// One file, not two: the reference set and the ledger page are validated by
/// the same cursor and the same fingerprint, so splitting them would create a
/// state where the two halves disagree about which plan revision they describe,
/// and would need two atomic replaces to stay consistent. One atomic write
/// keeps the whole restore all-or-nothing.
final class SnapshotStore: SnapshotFile<ReferenceSnapshot>, @unchecked Sendable {
  static let shared = SnapshotStore(directory: SnapshotStore.defaultDirectory())

  init(directory: URL, fileManager: FileManager = .default) {
    super.init(directory: directory, fileName: "reference.json", fileManager: fileManager)
  }

  /// The app's own container, not the app group: the snapshot is the app's
  /// render cache and no extension reads it.
  static func defaultDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("HowMuch/ReferenceSnapshot", isDirectory: true)
  }
}

// MARK: - Reports (stale-while-revalidate)

/// The Reflect overview and the default Rewards board as they last loaded, so
/// both render at once on the next launch while a quiet refresh runs behind.
///
/// A file of its own beside the reference snapshot rather than a field of it:
/// the reports are not tied to the ledger's cursor, load on their own schedule,
/// and must never hold up or invalidate the reference write.
struct ReportsSnapshot: Codable, ConnectionScopedSnapshot {
  /// Bumped whenever the stored shape changes; an older file is deleted.
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var connectionFingerprint: String
  var authenticatedUserID: String
  var planID: String
  var capturedAt: Date

  var spendingBreakdown: SpendingBreakdownReport?
  var incomeVsSpending: IncomeVsSpendingReport?
  var netWorth: NetWorthReport?
  var ageOfMoney: AgeOfMoneyReport?
  /// The month the four Reflect reports were fetched for (`yyyy-MM`).
  var reflectMonth: String?
  /// Only the board's default request: current card periods, today, every
  /// account. A filtered board is always fetched fresh.
  var rewards: RewardsReport?

  init(
    schemaVersion: Int = ReportsSnapshot.currentSchemaVersion,
    connectionFingerprint: String,
    authenticatedUserID: String,
    planID: String,
    capturedAt: Date = Date(),
    spendingBreakdown: SpendingBreakdownReport?,
    incomeVsSpending: IncomeVsSpendingReport?,
    netWorth: NetWorthReport?,
    ageOfMoney: AgeOfMoneyReport?,
    reflectMonth: String?,
    rewards: RewardsReport?
  ) {
    self.schemaVersion = schemaVersion
    self.connectionFingerprint = connectionFingerprint
    self.authenticatedUserID = authenticatedUserID
    self.planID = planID
    self.capturedAt = capturedAt
    self.spendingBreakdown = spendingBreakdown
    self.incomeVsSpending = incomeVsSpending
    self.netWorth = netWorth
    self.ageOfMoney = ageOfMoney
    self.reflectMonth = reflectMonth
    self.rewards = rewards
  }

  /// The four Reflect reports load together, so a restore applies all or none.
  var hasReflectOverview: Bool {
    spendingBreakdown != nil && incomeVsSpending != nil && netWorth != nil && ageOfMoney != nil
  }

  /// `nil` means the file may be applied: the reference snapshot's identity
  /// rules, without its "must have accounts" rule.
  static func rejection(
    _ snapshot: ReportsSnapshot,
    settings: APISettings,
    schemaVersion: Int = ReportsSnapshot.currentSchemaVersion
  ) -> SnapshotPolicy.Rejection? {
    SnapshotPolicy.connectionRejection(snapshot: snapshot, settings: settings, schemaVersion: schemaVersion)
  }

  /// The month the Reflect overview was fetched for, as `yyyy-MM`.
  static func month(of date: Date) -> String {
    String(date.startOfMonth().isoDateString.prefix(7))
  }

  /// The overview is "this month" on screen: the spending card is labelled
  /// with the current month and the trends end at it. One cached in an earlier
  /// month (or before the month was recorded) is not restored at all.
  static func reflectIsCurrent(storedMonth: String?, now: Date) -> Bool {
    storedMonth == month(of: now)
  }
}

/// One Rewards board request. A report is only ever shown under the request
/// that produced it, so a board never shows one filter's numbers under
/// another filter's controls.
struct RewardsRequest: Equatable, Sendable {
  var planID: String
  var from: String?
  var to: String?
  var accountIDs: [String]

  /// Current card periods, as of today, every account: the only request
  /// that is cached for the next launch.
  static func overview(planID: String) -> RewardsRequest {
    RewardsRequest(planID: planID, from: nil, to: nil, accountIDs: [])
  }

  var isOverview: Bool {
    from == nil && to == nil && accountIDs.isEmpty
  }
}

/// The reports file. It lives in the reference snapshot's directory, so every
/// test's temporary store isolates it too.
final class ReportsSnapshotStore: SnapshotFile<ReportsSnapshot>, @unchecked Sendable {
  init(directory: URL, fileManager: FileManager = .default) {
    super.init(directory: directory, fileName: "reports.json", fileManager: fileManager)
  }
}
