import Foundation
import Observation
import OSLog

/// The reward rows an account register shows under its balance.
struct RegisterRewards {
  var rows: [RewardsCardRow] = []
  var asOf: String?
}

enum LoadPhase: Equatable {
  case idle
  case loading
  case loaded
  case failed(String)

  var errorMessage: String? {
    if case .failed(let message) = self {
      return message
    }
    return nil
  }

  var isLoading: Bool {
    self == .loading
  }
}

private enum AccountUsageScanError: LocalizedError {
  case ledgerChanged

  var errorDescription: String? {
    "Transactions changed while usage was loading. Try again."
  }
}

/// One local delete, kept only while a ledger read that started before it can
/// still land. `removedIDs` are the rows the server tombstoned; `mirror` names
/// the split line the server unlinked on the surviving parent.
private struct LedgerDelete {
  let generation: Int
  let removedIDs: Set<String>
  let mirror: SplitMirrorLink
}

/// One acknowledged outbox write, kept on the same terms as `LedgerDelete`:
/// a read issued before it landed gets this row in place of the one it
/// fetched (or, for a create, gets the row added to its first page).
private struct LedgerWrite {
  let generation: Int
  let row: Transaction
  let isCreate: Bool
}

/// The balance effect of an acknowledged command, and the accounts read
/// sequence at the moment it was acknowledged.
private struct AcknowledgedDelta {
  let sequence: Int
  let deltas: [String: DeleteBalanceDelta.Delta]
}

@MainActor
@Observable
final class AppModel {
  private static let logger = Logger(subsystem: "sg.soon.howmuch", category: "AppModel")

  var settings: APISettings
  let captureAI: CaptureAISettings
  var planSettings: PlanSettings?
  /// The balances on screen: the server's, moved by unsent changes. Setting
  /// it sets the server's copy.
  var accounts: [Account] {
    get { displayedAccounts }
    set { serverAccounts = newValue }
  }
  private var displayedAccounts: [Account] = []
  var categoryGroups: [CategoryGroup] = []
  var payees: [Payee] = [] {
    didSet {
      if !outbox.isEmpty { recomputeDisplayedAccounts() }
    }
  }
  private var serverTransactions: [Transaction] = [] {
    didSet {
      if !outbox.isEmpty { recomputeDisplayedAccounts() }
    }
  }
  private var serverUnapprovedTransactions: [Transaction] = [] {
    didSet {
      if !outbox.isEmpty { recomputeDisplayedAccounts() }
    }
  }
  /// Size of the unapproved queue as the server last reported it, without any
  /// of its rows. The badge is drawn from this so launch never waits on a walk
  /// of the whole queue.
  private(set) var serverUnapprovedCount = 0
  /// Unapproved rows rejected here, mapped to the account they were in. A
  /// rejection removes a row from the queue exactly as an approval does, but no
  /// server count taken before it knows that, so it has to be subtracted the
  /// same way. The account is captured at deletion time, while the row is still
  /// in hand.
  private var rejectedUnapprovedAccounts: [String: String] = [:]
  /// Locally resolved ids as they stood when each scope's count arrived, so a
  /// refetched count is never decremented twice for the same approval -- and so
  /// refreshing one scope cannot rebaseline another and make its badge jump
  /// back up. Keyed by `countScopeKey`.
  private var confirmedWhenCounted: [String: Set<String>] = [:]
  /// Per-account unapproved counts, for registers narrowed to one account. The
  /// plan-wide number would overstate those.
  private var serverUnapprovedCountsByAccount: [String: Int] = [:]
  /// The queue rows themselves, loaded only when the approval flow opens.
  private(set) var unapprovedQueuePhase: LoadPhase = .idle
  /// Which views currently have the approval flow open. The queue is released
  /// only when the last of them goes away -- on iPad two registers can be on
  /// screen at once, and one closing must not pull the rows out from under the
  /// other.
  private var unapprovedQueueViewers: Set<String> = []
  private var approvalSession = RegisterApproval.Session.empty
  /// Imported YNAB schedules remain an immutable source mirror; local edits
  /// and entered occurrences are reflected through HowMuch overlays.
  var scheduledTransactions: [ScheduledTransaction] = []
  private(set) var hasMoreTransactions = false
  private(set) var nextTransactionOffset: Int?
  private(set) var isLoadingOlderTransactions = false
  private(set) var isFillingHorizon = false
  /// Nested plan-wide and focused-account fills share the spinner; each push
  /// must pop, including when a newer `ledgerPageGeneration` aborts the older one.
  private var horizonFillCount = 0
  private(set) var olderTransactionsError: String?
  /// Transaction-frequency counts for the inclusive trailing 30-day window.
  /// This is separate from `transactions`, which is intentionally paged for
  /// the register and may not contain every transaction in that window.
  private(set) var accountUsageLast30Days: [String: Int] = [:]
  /// The last counts a scan loaded, kept across `invalidateAccountUsage()` so
  /// "Most used" groups hold their order while the next scan runs. Read only
  /// alongside observed usage state, which changes whenever this does.
  @ObservationIgnored private var lastLoadedAccountUsage: (planID: String, scope: String?, counts: [String: Int])?

  private var lastLoadedAccountUsageForCurrentScope: [String: Int] {
    guard let last = lastLoadedAccountUsage,
          last.planID == settings.planID,
          last.scope == activeViewPrefsScope
    else {
      return [:]
    }
    return last.counts
  }
  private(set) var accountUsagePhase: LoadPhase = .idle
  /// Invalidates the Accounts view's usage task after a ledger or connection
  /// refresh, so a loaded 30-day ranking never survives changed source data.
  private(set) var accountUsageGeneration = 0

  var spendingBreakdown: SpendingBreakdownReport?
  var incomeVsSpending: IncomeVsSpendingReport?
  var netWorth: NetWorthReport?
  var ageOfMoney: AgeOfMoneyReport?

  var referencePhase: LoadPhase = .idle
  var ledgerPhase: LoadPhase = .idle
  var scheduledTransactionsPhase: LoadPhase = .idle
  private(set) var reportsRefreshGeneration = 0
  private(set) var rewardsRefreshGeneration = 0
  var reportsPhase: LoadPhase = .idle
  /// The Rewards board's last report and the request that produced it. Read
  /// through `rewardsReport(for:)`, so a report is never shown under another
  /// filter's controls.
  private var rewardsReport: RewardsReport?
  private var rewardsReportRequest: RewardsRequest?
  /// Each account register's last reward fetch, read through
  /// `registerRewards(forAccount:)`.
  private var registerRewardsByAccount: [String: RegisterRewards] = [:]
  private(set) var rewardsPhase: LoadPhase = .idle
  var isSubmitting = false
  var lastSaveMessage: SaveMessage?
  var isShowingSettings = false
  /// First run: choose between this iPhone and a server.
  var isShowingWelcome = false
  /// Account registers currently on a navigation stack, deepest last.
  /// Horizon fill uses this stack. Capture origin uses `visibleRegisterAccountID`.
  private(set) var focusedRegisterAccountIDs: [String] = []
  /// Which destination currently owns the visible chrome. A retained Accounts
  /// register must not leak into Rewards/Assistant or Home Screen.
  var activeCaptureSurface: CaptureSurface = .accounts
  private var focusedRegisters: [(surface: CaptureSurface, accountID: String)] = []
  // MARK: Outbox (docs/plans/offline-writes.md P1)

  /// Every transaction write not yet acknowledged by the server, for every
  /// connection, exactly as it is on disk. Only commands stamped for the
  /// current connection are shown or sent (`currentOutbox`).
  private(set) var outbox: [OutboxCommand] = [] {
    didSet {
      syncApprovalPending()
      recomputeDisplayedAccounts()
    }
  }
  @ObservationIgnored private let outboxStore: OutboxStore
  /// The store behind this model, for tests that relaunch on the same file.
  var outboxStoreForTesting: OutboxStore { outboxStore }
  /// Set when the outbox file exists but could not be read. Writes are
  /// refused until a read succeeds, so nothing on disk is overwritten.
  @ObservationIgnored private var outboxLoadFailure: String?
  /// True while a replay pass is running, whoever started it — the outbox
  /// card drives its spinner from this rather than view-local state.
  var isSyncingOutbox = false
  @ObservationIgnored private var needsAnotherDrain = false
  /// How long a new change waits before a pass sends it, so a burst of taps
  /// goes out together. Tests set it to zero.
  @ObservationIgnored var outboxDebounce: Duration = .milliseconds(400)
  /// Balance effects of commands the server has acknowledged, kept until an
  /// accounts read that started after the acknowledgement lands. Without
  /// them a balance would jump back while that read is still out.
  private var acknowledgedBalanceDeltas: [AcknowledgedDelta] = [] {
    didSet { recomputeDisplayedAccounts() }
  }
  /// Bumped when an accounts read starts; see `acknowledgedBalanceDeltas`.
  @ObservationIgnored private var accountsReadSequence = 0
  /// The accounts as the server last sent them. `accounts` adds what the
  /// outbox has not sent yet, and what it sent that no read reflects yet.
  private var serverAccounts: [Account] = [] {
    didSet { recomputeDisplayedAccounts() }
  }
  private var accountsByID: [String: Account] = [:]
  private var categoriesByID: [String: Category] = [:]
  private var payeesByID: [String: Payee] = [:]
  private var viewPrefs: ViewPrefs
  private let legacyViewPrefs: ViewPrefs
  private var scopedViewPrefsStore: ScopedViewPrefsStore
  private var activeViewPrefsScope: String?
  private var saveMessageToken = 0
  /// Invalidates an in-flight older-page response when the first page reloads.
  private(set) var ledgerPageGeneration = 0
  private var referenceGeneration = 0
  private var accountsGeneration = 0
  private var payeesGeneration = 0
  private var scheduledTransactionsGeneration = 0
  private var reportsGeneration = 0
  /// Read-order boundary for local deletes. Every ledger request captures this
  /// when it is issued; a delete advances it and records the rows it tombstoned
  /// and the split line it unlinked. A request issued earlier applies through
  /// those records, so a response fetched before the delete cannot put the
  /// mirror or the parent's obsolete link back on screen, while a page asked
  /// for after it is applied as it came.
  @ObservationIgnored private var ledgerReadGeneration = 0
  /// Ledger requests in flight, by the generation each captured when it was
  /// issued. A delete's record is dropped as soon as no request old enough to
  /// need it is still in flight, so this stays bounded by read order rather
  /// than becoming a session-long blacklist.
  @ObservationIgnored private var inFlightLedgerReads: [Int: Int] = [:]
  @ObservationIgnored private var ledgerDeletes: [LedgerDelete] = []
  /// Account ID → the `generation|planID|startDate` its horizon fill last
  /// completed against. See `fillFocusedAccountHorizon(generation:planID:)`.
  @ObservationIgnored private var completedAccountHorizonFills: [String: String] = [:]
  /// A refreshed account list or replaced ledger invalidates coverage, even
  /// when offsetting external transactions leave balances unchanged. A fill
  /// already in flight must not restore its completion after that refresh.
  @ObservationIgnored private var accountHorizonCompletionEpoch = 0
  @ObservationIgnored private var ledgerWrites: [LedgerWrite] = []
  /// Latest plan cursor seen on a ledger fetch. Changes made on another
  /// device advance it, which is how the reports cache (#180) notices them.
  private(set) var serverKnowledge: Int?
  /// The cursor and local mutation generation in force when the reports last
  /// loaded. Matching values mean a refetch would return what is on screen.
  private var reportsKnowledge: Int?
  private var reportsGenerationAtLastFetch: Int?
  /// Refresh debouncing: one run at a time, with later requests merged into a
  /// single queued request that runs once the in-flight one finishes.
  @ObservationIgnored private var inFlightRefresh: Task<Void, Never>?
  @ObservationIgnored private var queuedRefresh = RefreshRequest.none
  /// The full `refreshAll()` run in flight, keyed on the connection it
  /// started for. A second call that opts in to joining (`joinInFlight: true`)
  /// for the same connection (the capture sheet opening while the launch
  /// refresh is still resolving the plan) awaits it rather than repeating the
  /// whole waterfall. The run is unstructured, so a caller's cancellation
  /// never reaches it: a joiner must not inherit a dead run. A superseded run
  /// finishes, and its writes are discarded by the same fingerprint,
  /// generation, planID and scope guards a plan switch relies on.
  @ObservationIgnored private var inFlightRefreshAll: (fingerprint: String, generation: Int, task: Task<Void, Never>)?
  @ObservationIgnored private var refreshAllGeneration = 0
  /// Serialises preference writes so a slower earlier request cannot overwrite
  /// a newer reorder on the server.
  @ObservationIgnored private var accountPreferencesSyncTask: Task<Void, Never>?
  @ObservationIgnored private var accountPreferenceMutationGenerations: [String: Int] = [:]
  @ObservationIgnored private var accountPreferenceSyncedGenerations: [String: Int] = [:]

  // MARK: - #176: the on-device reference snapshot

  @ObservationIgnored private let snapshotStore: SnapshotStore
  /// The Reflect overview and the default Rewards board, in the same
  /// directory as the reference snapshot and discarded with it.
  @ObservationIgnored private let reportsStore: ReportsSnapshotStore
  /// The default board request's last report. Kept apart from
  /// `rewardsReport`, which may hold a filtered board that is never cached.
  @ObservationIgnored private var cachedRewardsOverview: RewardsReport?
  @ObservationIgnored private var rewardsGeneration = 0
  /// The month the Reflect reports on screen were fetched for (`yyyy-MM`).
  @ObservationIgnored private var reflectMonth: String?
  /// True while the reference set on screen came from the snapshot rather than
  /// from this launch's network refresh. Each area clears its own flag the
  /// moment the network replaces it.
  private(set) var referenceIsProvisional = false
  private(set) var ledgerIsProvisional = false
  private(set) var schedulesIsProvisional = false
  /// The cursor the restored snapshot was tagged with, kept separately from
  /// `serverKnowledge` so a later fetch can ask "is this the same plan state
  /// the provisional rows came from?" without the answer drifting.
  @ObservationIgnored private var snapshotKnowledge: Int?
  /// The first ledger page exactly as the network returned it. The in-memory
  /// `serverTransactions` is not the same thing — a quiet refresh merges, and
  /// local creates insert — so the snapshot is written from this instead.
  @ObservationIgnored private var lastLedgerFirstPage: ReferenceSnapshot.LedgerPage?
  /// The ids the snapshot's first page put on screen, in the order they were
  /// sorted into. They are the rows a network page must displace; anything
  /// else in `serverTransactions` was fetched this session (an older page the
  /// reader scrolled to) and must survive a refresh.
  @ObservationIgnored private var provisionalLedgerRowIDs: [String] = []
  @ObservationIgnored private var lastSyncedAccountPreferences: SyncedAccountPreferences?

  /// Any part of what is on screen still comes from the snapshot.
  var isProvisional: Bool {
    referenceIsProvisional || ledgerIsProvisional || schedulesIsProvisional
  }

  init(
    outboxStore: OutboxStore = .shared,
    settings: APISettings = .load(),
    viewPrefs: ViewPrefs = .load(),
    captureAI: CaptureAISettings? = nil,
    snapshotStore: SnapshotStore = .shared,
    hasSavedSettings: Bool = APISettings.hasSavedSettings()
  ) {
    self.snapshotStore = snapshotStore
    self.outboxStore = outboxStore
    self.reportsStore = ReportsSnapshotStore(directory: snapshotStore.directory)
    var scopedStore = ScopedViewPrefsStore.load()
    let scope = settings.viewPrefsScopeKey
    if scope == nil {
      scopedStore.discardUnscopedLegacyMigration()
    }
    self.settings = settings
    self.captureAI = captureAI ?? CaptureAISettings()
    self.legacyViewPrefs = viewPrefs
    self.scopedViewPrefsStore = scopedStore
    self.activeViewPrefsScope = scope
    self.viewPrefs = scope.map { scopedStore.activate(scope: $0, legacy: viewPrefs) } ?? ViewPrefs()
    self.scopedViewPrefsStore = scopedStore
    // A revoked session is persisted as signed out. Do not let a cold launch
    // fall back to tabs that can only render tokenless API errors. Only an
    // install that has never saved settings sees the welcome screen.
    switch LaunchRoute.resolve(hasSavedSettings: hasSavedSettings, isAuthenticated: settings.isAuthenticated) {
    case .welcome:
      self.isShowingWelcome = true
    case .connection:
      self.isShowingSettings = true
    case .main:
      break
    }
    NotificationCenter.default.addObserver(
      forName: .howMuchAuthenticationExpired,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let expiredSessionToken = notification.object as? String else { return }
      Task { @MainActor [weak self] in
        self?.handleAuthenticationExpiry(expiredSessionToken: expiredSessionToken)
      }
    }
    // Before the snapshot, so the first frame already shows unsent changes.
    loadOutbox()
    // #176: before the first frame, and off the network. A snapshot that does
    // not belong to this connection is deleted rather than shown.
    restoreSnapshot()
    restoreReports()
  }

  /// Puts the last Reflect overview and Rewards board on screen. Each is
  /// revalidated quietly when its view appears: `reportsGenerationAtLastFetch`
  /// stays `nil`, so `ReportsRefreshPolicy` asks for one refetch, and a loaded
  /// phase keeps that refetch free of spinners.
  private func restoreReports() {
    guard let snapshot = reportsStore.load() else {
      return
    }
    guard ReportsSnapshot.rejection(snapshot, settings: settings) == nil else {
      reportsStore.delete()
      return
    }
    if snapshot.hasReflectOverview,
       ReportsSnapshot.reflectIsCurrent(storedMonth: snapshot.reflectMonth, now: .now) {
      reflectMonth = snapshot.reflectMonth
      spendingBreakdown = snapshot.spendingBreakdown
      incomeVsSpending = snapshot.incomeVsSpending
      netWorth = snapshot.netWorth
      ageOfMoney = snapshot.ageOfMoney
      reportsPhase = .loaded
    }
    if let rewards = snapshot.rewards {
      cachedRewardsOverview = rewards
      rewardsReport = rewards
      rewardsReportRequest = .overview(planID: snapshot.planID)
      rewardsPhase = .loaded
    }
  }

  /// The board's report, only when it was produced by exactly this request.
  func rewardsReport(for request: RewardsRequest) -> RewardsReport? {
    rewardsReportRequest == request ? rewardsReport : nil
  }

  /// One account's reward rows for its register: its own last fetch, else its
  /// cards from the cached overview, so the rows are there on arrival while
  /// the fetch runs. The server computes each card's row the same with or
  /// without an account filter.
  func registerRewards(forAccount accountID: String) -> RegisterRewards {
    if let fetched = registerRewardsByAccount[accountID] {
      return fetched
    }
    guard let report = cachedRewardsOverview else { return RegisterRewards() }
    return RegisterRewards(rows: report.cards.filter { $0.accountId == accountID }, asOf: report.asOf)
  }

  /// Fetches one account's reward rows. Returns nil when the fetch fails or
  /// the plan changed under it; the register keeps what it had.
  func fetchRegisterRewards(accountID: String) async -> RegisterRewards? {
    let planID = settings.planID
    guard let report = try? await apiClient.fetchRewards(
      planID: planID,
      from: nil,
      to: nil,
      accountIDs: [accountID],
      group: .flag
    ), planID == settings.planID else {
      return nil
    }
    return RegisterRewards(rows: report.cards.filter { $0.accountId == accountID }, asOf: report.asOf)
  }

  /// Stores a fetch from `fetchRegisterRewards`. Separate so the register can
  /// wrap it in an animation and the List animates the rows in.
  func storeRegisterRewards(_ rewards: RegisterRewards, accountID: String) {
    registerRewardsByAccount[accountID] = rewards
  }

  /// Set while Reflect shows reports its last refresh could not replace, so
  /// the screen can say they may be out of date.
  var reportsStaleMessage: String? {
    guard spendingBreakdown != nil || netWorth != nil else { return nil }
    return reportsPhase.errorMessage
  }

  /// Writes whatever reports are in hand. Each is written as it last loaded;
  /// they share no cursor, so a mixture of ages is fine.
  private func persistReports() {
    guard settings.isAuthenticated,
          !settings.planID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !settings.authenticatedUserID.isEmpty else {
      return
    }
    reportsStore.scheduleWrite(
      ReportsSnapshot(
        connectionFingerprint: settings.connectionFingerprint,
        authenticatedUserID: settings.authenticatedUserID,
        planID: settings.planID,
        spendingBreakdown: spendingBreakdown,
        incomeVsSpending: incomeVsSpending,
        netWorth: netWorth,
        ageOfMoney: ageOfMoney,
        reflectMonth: reflectMonth,
        rewards: cachedRewardsOverview
      )
    )
  }

  /// Puts the last written reference set on screen so a warm launch renders
  /// the Accounts tab and the register's first page immediately. Everything it
  /// sets is replaced by the network refresh `HowMuchApp`'s launch task starts
  /// moments later; nothing here is treated as authoritative.
  private func restoreSnapshot() {
    guard let snapshot = snapshotStore.load() else {
      return
    }
    guard SnapshotPolicy.shouldApply(snapshot: snapshot, settings: settings) else {
      // Wrong user, wrong plan, wrong endpoint or an older schema: it can
      // never be applied, so there is no reason to keep reading it.
      snapshotStore.delete()
      return
    }
    planSettings = snapshot.planSettings
    accounts = snapshot.accounts
    categoryGroups = snapshot.categoryGroups
    payees = snapshot.payees
    scheduledTransactions = snapshot.scheduledTransactions
    lastSyncedAccountPreferences = snapshot.accountPreferences
    serverKnowledge = snapshot.serverKnowledge
    snapshotKnowledge = snapshot.serverKnowledge
    // #181's badge: the tile shows the last count the server gave rather than
    // flashing 0 while `refreshUnapprovedCount` is in flight. It is a plain
    // number with no rows behind it. The restored outbox supplies pending
    // approvals/deletes, which `unapprovedBadgeCount` subtracts once.
    // Per-account counts are not restored: a narrowed register fetches its own
    // when it opens, and a stale per-account number has no tile to sit on.
    if let unapprovedCount = snapshot.unapprovedCount {
      serverUnapprovedCount = unapprovedCount
    }
    referenceIsProvisional = true
    schedulesIsProvisional = true
    referencePhase = .loaded
    scheduledTransactionsPhase = .loaded
    if let page = snapshot.ledgerPage {
      serverTransactions = sortedUniqueTransactions(page.transactions)
      provisionalLedgerRowIDs = serverTransactions.map(\.id)
      hasMoreTransactions = page.hasMore && page.nextOffset != nil
      nextTransactionOffset = hasMoreTransactions ? page.nextOffset : nil
      lastLedgerFirstPage = page
      ledgerIsProvisional = true
      ledgerPhase = .loaded
    }
    rebuildLookups()
    // `publishIntentCatalog()` is deliberately not called: the intent catalog
    // is its own file, written from the same data and keyed on the same
    // fingerprint, so it already holds exactly what this restore would write.
    // The network refresh publishes it again as soon as it lands.
  }

  /// Writes the current reference set, tagged with the cursor the last ledger
  /// fetch observed. Called from every slice's success path; the store
  /// coalesces queued writes and encodes off the main actor. Returns false
  /// when nothing was written, so a caller that must not leave the old file
  /// behind can delete it.
  @discardableResult
  private func persistSnapshot() -> Bool {
    guard settings.isAuthenticated,
          !settings.planID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !settings.authenticatedUserID.isEmpty,
          !accounts.isEmpty,
          // Never write a mixture of this launch's data and the last one's:
          // the file is tagged with a single cursor, so every part of it must
          // have come from the network at that cursor. The slice that clears
          // the final provisional flag is the one that writes.
          !isProvisional else {
      return false
    }
    snapshotStore.scheduleWrite(
      ReferenceSnapshot(
        connectionFingerprint: settings.connectionFingerprint,
        authenticatedUserID: settings.authenticatedUserID,
        planID: settings.planID,
        serverKnowledge: serverKnowledge,
        planSettings: planSettings,
        // The server's balances plus what it has acknowledged since: a
        // restore adds back only what is still in the outbox.
        accounts: acknowledgedAccounts,
        categoryGroups: categoryGroups,
        payees: payees,
        accountPreferences: lastSyncedAccountPreferences,
        scheduledTransactions: scheduledTransactions,
        ledgerPage: lastLedgerFirstPage,
        // Keep acknowledged-only adjustments, but undo durable pending ones:
        // the restored outbox will subtract those again on the first frame.
        unapprovedCount: unapprovedBadgeCount + approvalSession.pending.union(queuedUnapprovedRejections.keys).count
      )
    )
    return true
  }

  /// Reports a launch that never reached the plan-scoped requests against the
  /// phases the snapshot had claimed were loaded. Without this an offline warm
  /// launch would sit on restored data with all three phases `.loaded` and no
  /// failure anywhere — the app would look freshly loaded when nothing had
  /// been validated. The data stays on screen behind the failure UI, which is
  /// what a failed refresh over in-memory data does today.
  private func failProvisionalPhases(_ message: String) {
    if referenceIsProvisional {
      referencePhase = .failed(message)
    }
    if ledgerIsProvisional {
      ledgerPhase = .failed(message)
    }
    if schedulesIsProvisional {
      scheduledTransactionsPhase = .failed(message)
    }
  }

  /// Drops both the file and every provisional marker. The snapshot belongs to
  /// one endpoint, user and plan, so any change to those discards it outright.
  private func discardSnapshot() {
    snapshotStore.delete()
    // The reports cache belongs to the same endpoint, user and plan.
    reportsStore.delete()
    cachedRewardsOverview = nil
    reflectMonth = nil
    referenceIsProvisional = false
    ledgerIsProvisional = false
    schedulesIsProvisional = false
    snapshotKnowledge = nil
    provisionalLedgerRowIDs = []
    lastLedgerFirstPage = nil
    lastSyncedAccountPreferences = nil
  }

  /// Clears all authenticated and cached state after a server-side session
  /// revocation. Keeping stale accounts visible while another request reports
  /// "Invalid credentials" is misleading and can invite writes with a dead
  /// session, so the connection screen is made the single next step.
  private func handleAuthenticationExpiry(expiredSessionToken: String) {
    // The on-device engine has no session to revoke. Signing it out would
    // leave local mode on a server sign-in screen with no way back.
    guard !settings.isLocal else {
      Self.logger.notice("Ignored an authentication expiry in local mode")
      return
    }
    guard settings.isAuthenticated, settings.sessionToken == expiredSessionToken else {
      return
    }

    settings.sessionToken = ""
    settings.authenticatedUserID = ""
    settings.save()
    switchViewPrefsScope()
    // #176: a revoked session is a sign-out. The snapshot belongs to it.
    discardSnapshot()
    planSettings = nil
    accounts = []
    categoryGroups = []
    payees = []
    serverTransactions = []
    serverUnapprovedTransactions = []
    serverUnapprovedCount = 0
    serverUnapprovedCountsByAccount = [:]
    confirmedWhenCounted = [:]
    rejectedUnapprovedAccounts = [:]
    unapprovedQueuePhase = .idle
    unapprovedQueueViewers = []
    approvalSession = .empty
    syncApprovalPending()
    scheduledTransactions = []
    spendingBreakdown = nil
    incomeVsSpending = nil
    netWorth = nil
    ageOfMoney = nil
    clearRewards()
    // The outbox itself stays: it is keyed by connection, and its commands
    // wait for this connection to sign in again.
    drainScheduleToken &+= 1
    isDrainScheduled = false
    acknowledgedBalanceDeltas = []
    invalidateAccountUsage()
    rebuildLookups()
    referencePhase = .idle
    ledgerPhase = .idle
    scheduledTransactionsPhase = .idle
    reportsPhase = .idle
    ledgerPageGeneration += 1
    ledgerReadGeneration &+= 1
    inFlightLedgerReads.removeAll()
    ledgerDeletes.removeAll()
    ledgerWrites.removeAll()
    isShowingSettings = true
    wipeIntentCatalog()
  }

  var lastUsedAccountID: String? {
    viewPrefs.lastUsedAccountID
  }

  /// Last-used OPEN account only. Capture admission uses `CaptureOrigin`
  /// instead of this, so a leftover visible register cannot leak into
  /// Home Screen or overview entry.
  var preferredCaptureAccountID: String? {
    lastUsedOpenAccountID
  }

  var lastUsedOpenAccountID: String? {
    let openIDs = Set(openAccounts.map(\.id))
    if let lastUsed = lastUsedAccountID, openIDs.contains(lastUsed) {
      return lastUsed
    }
    return nil
  }

  func presentCapture(_ request: CaptureRequest) {
    CaptureRouter.shared.enqueue(request)
  }

  func presentAddTransactions(origin: CaptureOrigin) {
    presentCapture(
      CaptureRequest(
        kind: .blank,
        connectionFingerprint: settings.connectionFingerprint,
        origin: origin
      )
    )
  }

  func presentManualTransaction(origin: CaptureOrigin) {
    presentCapture(
      CaptureRequest(
        kind: .manual(TransactionDraft()),
        connectionFingerprint: settings.connectionFingerprint,
        origin: origin
      )
    )
  }

  func beginFocusedRegisterAccount(_ accountID: String) {
    focusedRegisterAccountIDs.append(accountID)
    focusedRegisters.append((activeCaptureSurface, accountID))
    Task { await fillFocusedAccountHorizon() }
  }

  func endFocusedRegisterAccount(_ accountID: String) {
    if let index = focusedRegisterAccountIDs.lastIndex(of: accountID) {
      focusedRegisterAccountIDs.remove(at: index)
    }
    if let index = focusedRegisters.lastIndex(where: {
      $0.accountID == accountID && $0.surface == activeCaptureSurface
    }) {
      focusedRegisters.remove(at: index)
    } else if let index = focusedRegisters.lastIndex(where: { $0.accountID == accountID }) {
      focusedRegisters.remove(at: index)
    }
  }

  /// The account-scoped register actually on the visible destination.
  var visibleRegisterAccountID: String? {
    focusedRegisters.last(where: { $0.surface == activeCaptureSurface })?.accountID
  }

  func addTransactionsOrigin() -> CaptureOrigin {
    if let accountID = visibleRegisterAccountID {
      return .visibleRegister(accountID: accountID)
    }
    return .lastUsedOpen
  }

  /// Web parity: the spending report hides bookkeeping groups until asked.
  var includeQuietSpending: Bool {
    viewPrefs.includeQuietSpending ?? false
  }

  func setIncludeQuietSpending(_ include: Bool) {
    viewPrefs.includeQuietSpending = include
    saveViewPrefs()
  }

  var apiClient: APIClient {
    APIClient(settings: settings)
  }

  /// The id `HowMuchApp` keys its launch `.task(id:)` on. See
  /// `APISettings.launchFingerprint` for why this must exclude `planID`.
  var launchRefreshTaskID: String {
    settings.launchFingerprint
  }

  var openAccounts: [Account] {
    accounts.filter { !$0.closed }
  }

  var favouriteAccountIDs: Set<String> {
    Set(viewPrefs.favouriteAccountIDs)
  }

  func isAccountFavourite(_ accountID: String) -> Bool {
    favouriteAccountIDs.contains(accountID)
  }

  func toggleAccountFavourite(_ accountID: String) {
    if let index = viewPrefs.favouriteAccountIDs.firstIndex(of: accountID) {
      viewPrefs.favouriteAccountIDs.remove(at: index)
    } else {
      viewPrefs.favouriteAccountIDs.append(accountID)
    }
    saveViewPrefs()
  }

  func createAccount(
    name: String,
    kind: AccountKind,
    enteredBalance: Int,
    icon: AccountIcon?
  ) async throws -> Account {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw APIClientError.validation("Name cannot be empty")
    }
    let created = try await apiClient.createAccount(
      planID: settings.planID,
      name: trimmed,
      type: kind.rawValue,
      balance: kind.openingBalanceMilliunits(fromEntered: enteredBalance),
      icon: icon?.rawValue,
      onBudget: kind.onBudget
    )
    if !serverAccounts.contains(where: { $0.id == created.id }) {
      serverAccounts.append(created)
      rebuildLookups()
    }
    // The new account is already applied, so the sheet need not wait for the
    // follow-up read (as with `updateAccount`).
    scheduleRefresh(after: .accountCreated)
    showSaveMessage("Added \(created.name)")
    return created
  }

  func updateAccount(_ identity: AccountIdentity, for accountID: String) async throws {
    let trimmed = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw APIClientError.validation("Name cannot be empty")
    }
    guard let index = serverAccounts.firstIndex(where: { $0.id == accountID }) else {
      throw APIClientError.validation("Account not found")
    }
    let previous = serverAccounts[index]
    let previousPayees = payees
    let next = AccountIdentity(name: trimmed, classification: identity.classification, icon: identity.icon)
    serverAccounts[index] = previous.with(next)
    renameTransferPayee(forAccountID: accountID, to: trimmed)
    rebuildLookups()
    do {
      let typeToSend: String?
      if case .kind(let kind) = identity.classification, kind.rawValue != previous.type {
        typeToSend = kind.rawValue
      } else {
        typeToSend = nil
      }
      let currentIcon = previous.icon ?? previous.displayIcon
      let followsNewType = typeToSend.map { identity.icon == AccountIcon.default(for: $0) } ?? false
      let iconToSend = followsNewType || identity.icon.rawValue == currentIcon
        ? nil
        : identity.icon.rawValue
      let updated = try await apiClient.updateAccount(
        planID: settings.planID,
        accountID: accountID,
        name: trimmed,
        icon: iconToSend,
        type: typeToSend
      )
      if let typeToSend, updated.type != typeToSend {
        throw APIClientError.validation("The server did not save the account type.")
      }
      if let current = serverAccounts.firstIndex(where: { $0.id == accountID }) {
        serverAccounts[current] = updated
        renameTransferPayee(forAccountID: accountID, to: updated.name)
        rebuildLookups()
      }
      publishIntentCatalog()
      scheduleRefresh(after: .accountUpdated)
    } catch {
      if let current = serverAccounts.firstIndex(where: { $0.id == accountID }) {
        serverAccounts[current] = previous
        payees = previousPayees
        rebuildLookups()
      }
      throw error
    }
  }

  /// Keep the local "Transfer : …" payee in step with a renamed account so
  /// the payee picker does not keep showing the previous name.
  private func renameTransferPayee(forAccountID accountID: String, to accountName: String) {
    let expectedName = "Transfer : \(accountName)"
    payees = payees.map { payee in
      guard payee.transferAccountId == accountID, payee.name.hasPrefix("Transfer : ") else {
        return payee
      }
      return payee.withName(expectedName)
    }
  }

  var customAccountGroups: [CustomAccountGroup] {
    viewPrefs.customAccountGroups
  }

  func sortForAccountGroup(_ groupID: String) -> AccountGroupSort {
    viewPrefs.accountGroupSorts[groupID] ?? .manual
  }

  func setSort(_ sort: AccountGroupSort, forAccountGroup groupID: String) {
    viewPrefs.accountGroupSorts[groupID] = sort
    saveViewPrefs()
  }

  func customAccountGroupNameError(_ name: String, excluding groupID: String? = nil) -> String? {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      return "Enter a group name."
    }
    let nameKey = CustomAccountGroup.normalisedNameKey(trimmedName)
    if CustomAccountGroup.reservedNameKeys.contains(nameKey) {
      return "That name is reserved for a built-in group."
    }
    if viewPrefs.customAccountGroups.contains(where: {
      $0.id != groupID && CustomAccountGroup.normalisedNameKey($0.name) == nameKey
    }) {
      return "A custom group already uses that name."
    }
    return nil
  }

  @discardableResult
  func addCustomAccountGroup(named name: String, accountIDs: [String] = []) -> Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard customAccountGroupNameError(trimmedName) == nil else {
      return false
    }
    var groupID: String
    repeat {
      groupID = "custom-\(UUID().uuidString)"
    } while viewPrefs.customAccountGroups.contains(where: { $0.id == groupID })
    viewPrefs.customAccountGroups.append(
      CustomAccountGroup(id: groupID, name: trimmedName, accountIDs: uniqueAccountIDs(accountIDs))
    )
    saveViewPrefs()
    return true
  }

  @discardableResult
  func updateCustomAccountGroup(_ group: CustomAccountGroup) -> Bool {
    guard let index = viewPrefs.customAccountGroups.firstIndex(where: { $0.id == group.id }) else {
      return false
    }
    let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard customAccountGroupNameError(name, excluding: group.id) == nil else {
      return false
    }
    viewPrefs.customAccountGroups[index] = CustomAccountGroup(
      id: group.id,
      name: name,
      accountIDs: uniqueAccountIDs(group.accountIDs)
    )
    saveViewPrefs()
    return true
  }

  func setAccount(_ accountID: String, included: Bool, inCustomGroup groupID: String) {
    guard
      !accountID.isEmpty,
      let index = viewPrefs.customAccountGroups.firstIndex(where: { $0.id == groupID })
    else {
      return
    }
    var group = viewPrefs.customAccountGroups[index]
    if included {
      if !group.accountIDs.contains(accountID) {
        group.accountIDs.append(accountID)
      }
    } else {
      group.accountIDs.removeAll { $0 == accountID }
    }
    viewPrefs.customAccountGroups[index] = group
    saveViewPrefs()
  }

  func deleteCustomAccountGroup(id: String) {
    viewPrefs.customAccountGroups.removeAll { $0.id == id }
    viewPrefs.accountGroupSorts[id] = nil
    viewPrefs.accountOrderByGroup[id] = nil
    saveViewPrefs()
  }

  func moveCustomAccountGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
    let current = viewPrefs.customAccountGroups
    guard !source.isEmpty, source.allSatisfy(current.indices.contains) else {
      return
    }
    viewPrefs.customAccountGroups = moving(current, fromOffsets: source, toOffset: destination)
    saveViewPrefs()
  }

  /// Favourites and custom groups, then the Cash / Credit / Tracking / Closed
  /// type index. Same sections as the Accounts tab and the capture account picker.
  func accountListGroups(
    includeClosed: Bool = true,
    includeEmptySystemGroups: Bool = false,
    includeEmptyCustomGroups: Bool = true
  ) -> [AccountListGroup] {
    AccountListGroup.build(
      accounts: accounts,
      favouriteIDs: favouriteAccountIDs,
      customGroups: customAccountGroups,
      includeClosed: includeClosed,
      includeEmptySystemGroups: includeEmptySystemGroups,
      includeEmptyCustomGroups: includeEmptyCustomGroups,
      orderedAccounts: { [self] accounts, groupID in
        self.orderedAccounts(accounts, inGroup: groupID)
      }
    )
  }

  func accounts(inGroupID groupID: String) -> [Account] {
    if let system = AccountSystemGroup(rawValue: groupID) {
      return orderedAccounts(
        accounts.filter { system.contains($0, favouriteIDs: favouriteAccountIDs) },
        inGroup: groupID
      )
    }
    let ids = Set(customAccountGroups.first(where: { $0.id == groupID })?.accountIDs ?? [])
    return orderedAccounts(accounts.filter { ids.contains($0.id) }, inGroup: groupID)
  }

  /// Applies a group's selected sort while retaining the old global order as
  /// the backward-compatible fallback for pre-groups installs.
  func orderedAccounts(_ source: [Account], inGroup groupID: String) -> [Account] {
    switch sortForAccountGroup(groupID) {
    case .manual:
      return manualOrderedAccounts(source, groupID: groupID)
    case .alphabetical:
      return source.sorted(by: accountNameOrder)
    case .mostUsedLast30Days:
      // Every ledger refresh drops the counts and rescans them. Until they are
      // back, rank by the last counts this plan and scope loaded rather than
      // flashing the group into name order and back. Never the manual drag
      // order in `accountOrderByGroup`.
      let usage = accountUsagePhase == .loaded ? accountUsageLast30Days : lastLoadedAccountUsageForCurrentScope
      return source.sorted { first, second in
        let firstUsage = usage[first.id, default: 0]
        let secondUsage = usage[second.id, default: 0]
        if firstUsage != secondUsage {
          return firstUsage > secondUsage
        }
        return accountNameOrder(first, second)
      }
    }
  }

  private func manualOrderedAccounts(_ source: [Account], groupID: String) -> [Account] {
    let order = viewPrefs.accountOrderByGroup[groupID] ?? viewPrefs.accountOrder
    var ranks: [String: Int] = [:]
    for (index, accountID) in order.enumerated() {
      ranks[accountID] = ranks[accountID] ?? index
    }
    return source.sorted { first, second in
      switch (ranks[first.id], ranks[second.id]) {
      case let (firstRank?, secondRank?) where firstRank != secondRank:
        return firstRank < secondRank
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        return accountNameOrder(first, second)
      }
    }
  }

  /// Moves accounts within only the displayed group, leaving every other
  /// group's manual order intact.
  func moveAccounts(in group: [Account], groupID: String, fromOffsets source: IndexSet, toOffset destination: Int) {
    let orderedGroup = manualOrderedAccounts(group, groupID: groupID)
    guard !source.isEmpty, source.allSatisfy(orderedGroup.indices.contains) else {
      return
    }
    let moved = moving(orderedGroup, fromOffsets: source, toOffset: destination)
    viewPrefs.accountOrderByGroup[groupID] = moved.map(\.id)
    saveViewPrefs()
  }

  private func uniqueAccountIDs(_ source: [String]) -> [String] {
    var result: [String] = []
    for id in source where !id.isEmpty && !result.contains(id) {
      result.append(id)
    }
    return result
  }

  private func moving<Element>(_ source: [Element], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [Element] {
    let moving = offsets.sorted().map { source[$0] }
    let remaining = source.enumerated().compactMap { offsets.contains($0.offset) ? nil : $0.element }
    let removedBeforeDestination = offsets.filter { $0 < destination }.count
    let insertion = min(max(0, destination - removedBeforeDestination), remaining.count)
    return Array(remaining[..<insertion]) + moving + Array(remaining[insertion...])
  }

  private func saveViewPrefs() {
    guard let scope = activeViewPrefsScope else {
      return
    }
    viewPrefs = viewPrefs.structurallyNormalised()
    let previousAccountPreferences = scopedViewPrefsStore.scopes[scope].map(AccountPresentationPreferences.init)
    let preferences = AccountPresentationPreferences(viewPrefs)
    if previousAccountPreferences != preferences,
       scopedViewPrefsStore.syncedAccountPreferences[scope] == nil {
      // Persist the true pre-edit baseline even before first hydration. This
      // distinguishes a user mutation from untouched legacy preferences.
      let baseline = previousAccountPreferences ?? AccountPresentationPreferences(ViewPrefs())
      scopedViewPrefsStore.markAccountPreferencesSynced(
        SyncedAccountPreferences(preferences: baseline, revision: 0),
        for: scope
      )
    }
    scopedViewPrefsStore.set(viewPrefs, for: scope)
    if previousAccountPreferences != preferences {
      accountPreferenceMutationGenerations[scope, default: 0] &+= 1
      enqueueAccountPreferencesSync()
    }
  }

  private func enqueueAccountPreferencesSync() {
    guard let scope = activeViewPrefsScope, settings.isAuthenticated else {
      return
    }
    let previous = accountPreferencesSyncTask
    let client = apiClient
    let planID = settings.planID
    accountPreferencesSyncTask = Task {
      await previous?.value
      guard !Task.isCancelled else { return }
      let syncGeneration = accountPreferenceMutationGenerations[scope, default: 0]
      var baseline = scopedViewPrefsStore.syncedAccountPreferences[scope]
      guard var scopedPreferences = scopedViewPrefsStore.scopes[scope] else { return }
      var preferences = AccountPresentationPreferences(scopedPreferences)
      guard baseline?.preferences != preferences else {
        accountPreferenceSyncedGenerations[scope] = syncGeneration
        return
      }
      for _ in 0 ..< 3 {
        do {
          let saved = try await client.updateAccountPreferences(
            planID: planID,
            preferences: preferences,
            expectedRevision: baseline?.revision ?? 0
          )
          scopedViewPrefsStore.markAccountPreferencesSynced(saved, for: scope)
          accountPreferenceSyncedGenerations[scope] = syncGeneration
          return
        } catch APIClientError.accountPreferencesConflict {
          do {
            let remote = try await client.fetchAccountPreferences(planID: planID)
              ?? SyncedAccountPreferences(preferences: AccountPresentationPreferences(ViewPrefs()), revision: 0)
            let latestScopedPreferences = scopedViewPrefsStore.scopes[scope] ?? scopedPreferences
            let latestBaseline = scopedViewPrefsStore.syncedAccountPreferences[scope] ?? baseline
            if latestBaseline == nil {
              // A revision-zero conflict without a persisted pre-edit baseline
              // is untouched legacy state from a later upgraded device.
              scopedPreferences = remote.preferences.applying(to: latestScopedPreferences)
              scopedViewPrefsStore.set(scopedPreferences, for: scope)
              if activeViewPrefsScope == scope { viewPrefs = scopedPreferences }
              scopedViewPrefsStore.markAccountPreferencesSynced(remote, for: scope)
              accountPreferenceSyncedGenerations[scope] = syncGeneration
              return
            }
            guard let baselinePreferences = latestBaseline?.preferences else { return }
            preferences = AccountPresentationPreferences.merging(
              baseline: baselinePreferences,
              local: AccountPresentationPreferences(latestScopedPreferences),
              remote: remote.preferences
            )
            scopedPreferences = preferences.applying(to: latestScopedPreferences)
            preferences = AccountPresentationPreferences(scopedPreferences)
            scopedViewPrefsStore.set(scopedPreferences, for: scope)
            if activeViewPrefsScope == scope {
              viewPrefs = scopedPreferences
            }
            scopedViewPrefsStore.markAccountPreferencesSynced(remote, for: scope)
            baseline = remote
          } catch {
            return
          }
        } catch {
          // Keep the local value different from the synced baseline. A later
          // refresh retries it instead of applying an older server snapshot.
          return
        }
      }
    }
  }

  /// Switches the in-memory preference view whenever endpoint, user, or plan
  /// changes. Signed-out state is deliberately blank while saved scopes stay
  /// in the store for the next authenticated session.
  private func switchViewPrefsScope() {
    let nextScope = settings.viewPrefsScopeKey
    guard nextScope != activeViewPrefsScope else {
      return
    }
    invalidateAccountUsage()
    let previousScope = activeViewPrefsScope
    CaptureWorkspace.shared.dropForScopeChange()
    if previousScope.map(CaptureWorkspaceStore.isPersistableScope) == true {
      CaptureRouter.shared.dropForSignOut()
    }
    activeViewPrefsScope = nextScope
    if let nextScope {
      viewPrefs = scopedViewPrefsStore.activate(scope: nextScope, legacy: legacyViewPrefs)
      CaptureWorkspace.shared.activate(scopeKey: nextScope)
    } else {
      viewPrefs = ViewPrefs()
    }
  }

  /// Removes stale account references only after the API has authoritatively
  /// returned the complete account list for the active scope.
  private func pruneViewPrefs(using authoritativeAccounts: [Account]) {
    let validIDs = Set(authoritativeAccounts.map(\.id))
    let original = viewPrefs
    viewPrefs.favouriteAccountIDs.removeAll { !validIDs.contains($0) }
    viewPrefs.accountOrder.removeAll { !validIDs.contains($0) }
    viewPrefs.accountOrderByGroup = viewPrefs.accountOrderByGroup.mapValues { order in
      order.filter(validIDs.contains)
    }
    viewPrefs.customAccountGroups = viewPrefs.customAccountGroups.map { group in
      CustomAccountGroup(
        id: group.id,
        name: group.name,
        accountIDs: group.accountIDs.filter(validIDs.contains)
      )
    }
    if let lastUsed = viewPrefs.lastUsedAccountID, !validIDs.contains(lastUsed) {
      viewPrefs.lastUsedAccountID = nil
    }
    viewPrefs = viewPrefs.structurallyNormalised()
    if viewPrefs != original {
      saveViewPrefs()
    }
  }

  /// Reads every page for the date-filtered ledger instead of using the
  /// register cache. The progress guard turns a malformed cursor into a
  /// recoverable error rather than an endless request loop.
  func refreshAccountUsageLast30Days() async {
    guard !accountUsagePhase.isLoading else {
      return
    }
    let planID = settings.planID
    let scope = activeViewPrefsScope
    let generation = accountUsageGeneration
    let calendar = Calendar.current
    let now = Date.now
    let today = now.isoDateString
    let from = (calendar.date(byAdding: .day, value: -29, to: now) ?? now).isoDateString
    let client = apiClient
    accountUsagePhase = .loading

    do {
      var counts: [String: Int]?
      for attempt in 0 ... 1 {
        do {
          counts = try await scanAccountUsage(
            client: client,
            planID: planID,
            sinceDate: from,
            untilDate: today,
            generation: generation,
            scope: scope
          )
          break
        } catch AccountUsageScanError.ledgerChanged where attempt == 0 {
          continue
        }
      }
      guard
        let counts,
        planID == settings.planID,
        scope == activeViewPrefsScope,
        generation == accountUsageGeneration
      else {
        return
      }
      accountUsageLast30Days = counts
      lastLoadedAccountUsage = (planID: planID, scope: scope, counts: counts)
      accountUsagePhase = .loaded
    } catch {
      guard
        planID == settings.planID,
        scope == activeViewPrefsScope,
        generation == accountUsageGeneration
      else {
        return
      }
      accountUsagePhase = .failed(error.localizedDescription)
    }
  }

  private func scanAccountUsage(
    client: APIClient,
    planID: String,
    sinceDate: String,
    untilDate: String,
    generation: Int,
    scope: String?
  ) async throws -> [String: Int] {
    var counts: [String: Int] = [:]
    var transactionIDs: Set<String> = []
    var offset = 0
    var requestedOffsets: Set<Int> = []
    var expectedKnowledge: Int?
    var hasExpectedKnowledge = false
    let maximumPages = 250

    while true {
      guard
        planID == settings.planID,
        scope == activeViewPrefsScope,
        generation == accountUsageGeneration
      else {
        throw CancellationError()
      }
      guard requestedOffsets.insert(offset).inserted else {
        throw APIClientError.decoding("The transaction usage cursor repeated.")
      }
      guard requestedOffsets.count <= maximumPages else {
        throw APIClientError.decoding("The transaction usage scan exceeded its safe page limit.")
      }
      let page = try await client.fetchTransactions(
        planID: planID,
        offset: offset,
        sinceDate: sinceDate,
        untilDate: untilDate
      )
      if hasExpectedKnowledge, page.serverKnowledge != expectedKnowledge {
        throw AccountUsageScanError.ledgerChanged
      }
      expectedKnowledge = page.serverKnowledge
      hasExpectedKnowledge = true

      if page.hasMore, page.serverKnowledge == nil {
        throw AccountUsageScanError.ledgerChanged
      }

      for transaction in page.transactions
      where transaction.date >= sinceDate
        && transaction.date <= untilDate
        && transactionIDs.insert(transaction.id).inserted {
        counts[transaction.accountID, default: 0] += 1
      }
      guard page.hasMore else {
        return counts
      }
      guard !page.transactions.isEmpty else {
        throw APIClientError.decoding("The transaction usage page was empty before the final page.")
      }
      guard let next = page.nextOffset, next > offset else {
        throw APIClientError.decoding("The transaction usage cursor did not advance.")
      }
      offset = next
    }
  }

  var flattenedCategories: [Category] {
    categoryGroups
      .flatMap(\.categories)
      .filter { !$0.deleted }
  }

  func rebuildLookups() {
    accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    categoriesByID = Dictionary(
      flattenedCategories.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    payeesByID = Dictionary(payees.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  var currencyFormat: CurrencyFormat? {
    planSettings?.currencyFormat
  }

  /// The first failure across surfaces, for connection banners.
  var connectionProblem: String? {
    referencePhase.errorMessage ?? ledgerPhase.errorMessage ?? scheduledTransactionsPhase.errorMessage ?? reportsPhase.errorMessage
  }

  func account(withID id: String) -> Account? {
    accountsByID[id]
  }

  func categoryName(forID id: String?) -> String? {
    guard let id else {
      return nil
    }
    return categoriesByID[id]?.name
  }

  func payee(withID id: String) -> Payee? {
    payeesByID[id]
  }

  @ObservationIgnored private var payeesSortedByNameCache: (source: [Payee], locale: String, sorted: [Payee])?

  /// `payees` in picker order, sorted once per change rather than on every
  /// picker render and keystroke. Reading `payees` keeps observation intact,
  /// and an unchanged array compares equal by identity without a scan. The
  /// comparison is locale-aware, so a language or region change re-sorts.
  var payeesSortedByName: [Payee] {
    let source = payees
    let locale = Locale.current.identifier
    if let cache = payeesSortedByNameCache, cache.locale == locale, cache.source == source {
      return cache.sorted
    }
    let sorted = source.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    payeesSortedByNameCache = (source: source, locale: locale, sorted: sorted)
    return sorted
  }

  /// `rows` as they will be once every unsent change lands: edits, status
  /// changes and approvals applied, deletes hidden.
  func overlaying(_ rows: [Transaction]) -> [Transaction] {
    let commands = currentOutbox
    let overlaid = commands.isEmpty ? rows : OutboxOverlay.apply(commands, to: rows, names: overlayNames)
    return overlayingApproval(on: overlaid)
  }

  var transactions: [Transaction] {
    overlaying(serverTransactions)
  }

  /// The number on the "New" tile, for the whole plan.
  var unapprovedBadgeCount: Int {
    unapprovedBadgeCount(forAccountID: nil)
  }

  /// The "New" count for a register scoped to `accountID` (`nil` = whole plan).
  /// Once the queue is loaded it is row-exact and wins outright; before that the
  /// matching server count stands in, less whatever has been approved here since
  /// it was taken.
  func unapprovedBadgeCount(forAccountID accountID: String?) -> Int {
    if unapprovedQueuePhase == .loaded {
      guard let accountID else { return unapprovedTransactions.count }
      return unapprovedTransactions.count { $0.accountID == accountID }
    }
    let counted = accountID.map { serverUnapprovedCountsByAccount[$0] ?? 0 } ?? serverUnapprovedCount
    return max(0, counted - resolvedSinceCount(forAccountID: accountID))
  }

  /// Rows approved here since the matching count was taken. Scoped counts only
  /// move for rows in their own account.
  private func resolvedSinceCount(forAccountID accountID: String?) -> Int {
    // A row approved and then dropped from both arrays is not subtracted here;
    // the next count of this scope reconciles it.
    let since = locallyResolvedUnapprovedIDs.subtracting(confirmedWhenCounted[countScopeKey(accountID)] ?? [])
    guard let accountID else { return since.count }
    guard !since.isEmpty else { return 0 }
    let queuedRejections = queuedUnapprovedRejections
    // One pass over the rows instead of a linear search per resolved ID. The
    // ledger's row wins over the queue's, as the old `first ?? first` did, and
    // an outbox command's saved row is the last resort.
    var accountByID: [String: String] = [:]
    for row in serverUnapprovedTransactions where since.contains(row.id) {
      accountByID[row.id] = accountByID[row.id] ?? row.accountID
    }
    var ledgerSeen = Set<String>()
    for row in serverTransactions where since.contains(row.id) && ledgerSeen.insert(row.id).inserted {
      accountByID[row.id] = row.accountID
    }
    for command in currentOutbox where since.contains(command.transactionID) {
      accountByID[command.transactionID] = accountByID[command.transactionID] ?? command.baseSnapshot?.accountID
    }
    return since.count { id in
      // A rejected row is gone from both arrays, so its account was recorded.
      if let rejectedFrom = rejectedUnapprovedAccounts[id] ?? queuedRejections[id] {
        return rejectedFrom == accountID
      }
      return accountByID[id] == accountID
    }
  }

  var unapprovedTransactions: [Transaction] {
    overlaying(serverUnapprovedTransactions).filter { row in
      !row.deleted && !row.approved
    }
  }

  /// True while an approval is on the wire. Queued approvals already show as
  /// approved, so they do not hold anything up.
  var isApprovalInFlight: Bool {
    currentOutbox.contains { $0.isInFlight && $0.carriesApproval }
  }

  func isApprovalPending(_ transactionID: String) -> Bool {
    approvalSession.pending.contains(transactionID)
  }

  func approveAllTitle(for rows: [Transaction]) -> String? {
    let count = eligibleApprovalCount(in: rows)
    return count == 0 ? nil : RegisterApproval.approveAllLabel(count)
  }

  // MARK: - Outbox: what is on screen

  /// The commands this connection owns. Commands stamped for another
  /// connection stay on disk, untouched, until that connection is back.
  var currentOutbox: [OutboxCommand] {
    outbox.filter { settings.matchesCurrentOrLegacyOutboxStamp($0.connectionFingerprint) }
  }

  /// How many changes have not reached the server.
  var unsentChangeCount: Int {
    currentOutbox.count
  }

  /// New transactions waiting to be sent, as the register shows them.
  var pendingRows: [PendingRow] {
    let commands = currentOutbox
    guard commands.contains(where: { if case .create = $0.kind { return true }; return false }) else {
      return []
    }
    let serverImportIDs = Set(serverTransactions.compactMap(\.importID))
    let serverIDs = Set(serverTransactions.map(\.id))
    return commands.compactMap { command in
      guard case .create(let request) = command.kind,
            !serverIDs.contains(command.transactionID) else {
        return nil
      }
      if let importID = request.importID, serverImportIDs.contains(importID) {
        return nil
      }
      return PendingRow(
        id: command.id,
        transactionID: command.transactionID,
        request: request,
        status: rowStatus(command),
        accountName: account(withID: request.accountID)?.name ?? "",
        categoryName: categoryName(forID: request.categoryID),
        payeeName: request.payeeName ?? request.payeeID.flatMap { payee(withID: $0)?.name }
      )
    }
  }

  /// The glyph a row with unsent changes carries, or nil when it has none.
  func syncStatus(forTransactionID transactionID: String) -> PendingRow.Status? {
    let commands = currentOutbox.filter { $0.transactionID == transactionID }
    if let rejected = commands.first(where: { if case .rejected = $0.state { return true }; return false }) {
      return rowStatus(rejected)
    }
    if commands.contains(where: \.isInFlight) {
      return .sending
    }
    return commands.isEmpty ? nil : .waitingForConnection
  }

  /// Every unsent change, for the outbox card: rejected ones first.
  var outboxItems: [OutboxItem] {
    let items = currentOutbox.map { command -> OutboxItem in
      let row = serverTransactions.first { $0.id == command.transactionID }
        ?? serverUnapprovedTransactions.first { $0.id == command.transactionID }
        ?? command.baseSnapshot
      let action: String
      var payeeName = row?.payeeName
      var isoDate = row?.date
      var amount = row?.amount
      switch command.kind {
      case .create(let request), .update(let request):
        action = command.kind.isCreate ? "New" : "Edit"
        payeeName = request.payeeName ?? request.payeeID.flatMap { payee(withID: $0)?.name } ?? payeeName
        isoDate = request.date
        amount = request.amount
      case .cleared(_, let cleared, _):
        action = cleared == .cleared ? "Cleared" : "Uncleared"
      case .approve:
        action = "Approve"
      case .delete:
        action = "Delete"
      }
      return OutboxItem(
        id: command.id,
        transactionID: command.transactionID,
        action: action,
        payeeName: payeeName,
        isoDate: isoDate,
        signedAmount: amount,
        status: rowStatus(command)
      )
    }
    return items.filter { if case .rejected = $0.status { return true }; return false }
      + items.filter { if case .rejected = $0.status { return false }; return true }
  }

  /// Why Reconcile must wait, or nil when it can go ahead. The server checks
  /// the statement against what it holds, so every change touching the
  /// account has to reach it first.
  func reconcileBlockReason(accountID: String) -> String? {
    let commands = currentOutbox
    guard !commands.isEmpty else {
      return nil
    }
    let deltaAccounts = Set(
      OutboxPlanner.balanceDeltas(
        commands,
        rowsByID: rowsForBalanceDeltas(commands),
        transferAccountIDsByPayeeID: transferAccountIDsByPayeeID
      ).keys
    )
    let waiting = commands.filter { command in
      command.touchedAccountIDs.contains(accountID)
        || serverRow(command.transactionID)?.accountID == accountID
    }.count
    guard waiting > 0 || deltaAccounts.contains(accountID) else {
      return nil
    }
    let count = max(waiting, 1)
    return count == 1
      ? "1 change to this account hasn’t reached the server yet. Send or discard it before reconciling."
      : "\(count) changes to this account haven’t reached the server yet. Send or discard them before reconciling."
  }

  private func rowStatus(_ command: OutboxCommand) -> PendingRow.Status {
    switch command.state {
    case .inFlight:
      return .sending
    case .queued:
      return .waitingForConnection
    case .rejected(let message, _):
      return .rejected(message)
    }
  }

  private var overlayNames: OutboxOverlay.Names {
    OutboxOverlay.Names(
      accountName: { [accountsByID] in accountsByID[$0]?.name },
      categoryName: { [categoriesByID] in categoriesByID[$0]?.name },
      payeeName: { [payeesByID] in payeesByID[$0]?.name },
      transferAccountID: { [payeesByID] in payeesByID[$0]?.transferAccountId }
    )
  }

  private var transferAccountIDsByPayeeID: [String: String] {
    var result: [String: String] = [:]
    for payee in payees {
      if let accountID = payee.transferAccountId {
        result[payee.id] = accountID
      }
    }
    return result
  }

  /// The server rows a balance calculation needs: each command's row and the
  /// far sides of its transfers.
  private func rowsForBalanceDeltas(_ commands: [OutboxCommand]) -> [String: Transaction] {
    var wanted = Set(commands.map(\.transactionID))
    for command in commands {
      if let base = command.baseSnapshot {
        wanted.formUnion(base.linkedTransferIDs)
      }
    }
    var rows: [String: Transaction] = [:]
    for row in serverUnapprovedTransactions + serverTransactions where wanted.contains(row.id) {
      rows[row.id] = row
      wanted.formUnion(row.linkedTransferIDs)
    }
    // Far sides named only by a row found above.
    for row in serverUnapprovedTransactions + serverTransactions where wanted.contains(row.id) && rows[row.id] == nil {
      rows[row.id] = row
    }
    return rows
  }

  private func serverRow(_ transactionID: String) -> Transaction? {
    serverTransactions.first { $0.id == transactionID }
      ?? serverUnapprovedTransactions.first { $0.id == transactionID }
  }

  /// The row as the register shows it now.
  private func displayedRow(_ transactionID: String) -> Transaction? {
    guard let row = serverRow(transactionID) else {
      return nil
    }
    return overlaying([row]).first
  }

  /// The server's accounts plus what it has acknowledged since they were read.
  private var acknowledgedAccounts: [Account] {
    let deltas = acknowledgedBalanceDeltas.reduce(into: [String: DeleteBalanceDelta.Delta]()) { sum, entry in
      Self.add(entry.deltas, into: &sum)
    }
    return deltas.isEmpty ? serverAccounts : DeleteBalanceDelta.applying(deltas, to: serverAccounts)
  }

  private func recomputeDisplayedAccounts() {
    var deltas = acknowledgedBalanceDeltas.reduce(into: [String: DeleteBalanceDelta.Delta]()) { sum, entry in
      Self.add(entry.deltas, into: &sum)
    }
    let commands = currentOutbox
    if !commands.isEmpty {
      Self.add(
        OutboxPlanner.balanceDeltas(
          commands,
          rowsByID: rowsForBalanceDeltas(commands),
          transferAccountIDsByPayeeID: transferAccountIDsByPayeeID
        ),
        into: &deltas
      )
    }
    let next = deltas.isEmpty ? serverAccounts : DeleteBalanceDelta.applying(deltas, to: serverAccounts)
    guard next != displayedAccounts else {
      return
    }
    displayedAccounts = next
    accountsByID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  private static func add(_ deltas: [String: DeleteBalanceDelta.Delta], into sum: inout [String: DeleteBalanceDelta.Delta]) {
    for (accountID, delta) in deltas {
      var total = sum[accountID, default: DeleteBalanceDelta.Delta()]
      total.balance += delta.balance
      total.cleared += delta.cleared
      total.uncleared += delta.uncleared
      sum[accountID] = total
    }
  }

  /// Queued approvals count as approved on the badge and in the register,
  /// including after a relaunch, because the outbox is their record.
  private func syncApprovalPending() {
    let pending = Set(currentOutbox.filter(\.carriesApproval).map(\.transactionID))
    if approvalSession.pending != pending {
      approvalSession.pending = pending
    }
  }

  /// Unapproved rows with a queued delete, by the account they sit in.
  private var queuedUnapprovedRejections: [String: String] {
    var result: [String: String] = [:]
    for command in currentOutbox {
      guard case .delete = command.kind,
            let base = command.baseSnapshot ?? serverRow(command.transactionID),
            !base.approved else {
        continue
      }
      result[command.transactionID] = base.accountID
    }
    return result
  }

  func hasPendingCreate(importID: String?) -> Bool {
    guard let importID, !importID.isEmpty else {
      return false
    }
    return currentOutbox.contains { command in
      if case .create(let request) = command.kind {
        return request.importID == importID
      }
      return false
    }
  }

  /// A conversation revision of something already saved. The row may be on
  /// the server already, or still in the outbox (queued or on the wire); the
  /// revision becomes an edit of whichever it is, and the planner folds it
  /// into a create that has not been sent.
  func reviseConversationCapture(_ item: CaptureDraftItem) {
    let transactionID: String
    let base: Transaction?
    if let existing = matchingServerRow(importID: item.id, accountID: item.draft.accountID) {
      transactionID = existing.id
      base = existing
    } else if let create = currentOutbox.first(where: { command in
      if case .create(let request) = command.kind { return request.importID == item.id }
      return false
    }) {
      transactionID = create.transactionID
      base = nil
    } else {
      return
    }
    var draft = item.draft
    draft.id = transactionID
    do {
      try enqueueOutbox([editCommand(draft, transactionID: transactionID, base: base)])
    } catch {
      showSaveMessage("Couldn’t save changes — \(error.localizedDescription)", kind: .failure)
    }
  }

  private func matchingServerRow(importID: String, accountID: String) -> Transaction? {
    let match: (Transaction) -> Bool = { row in
      row.importID == importID && (accountID.isEmpty || row.accountID == accountID)
    }
    return serverTransactions.first(where: match)
      ?? serverUnapprovedTransactions.first(where: match)
  }

  /// `RegisterApproval.looksApproved` per row, with the session's union taken once.
  /// Rows the server already reports approved need no copy, so once they all
  /// do, reads return the array as is.
  private func overlayingApproval(on rows: [Transaction]) -> [Transaction] {
    let resolved = RegisterApproval.resolvedIDs(approvalSession)
    guard !resolved.isEmpty,
          rows.contains(where: { !$0.approved && resolved.contains($0.id) })
    else {
      return rows
    }
    return rows.map { row in
      !row.approved && resolved.contains(row.id) ? row.withApproved(true) : row
    }
  }

  /// True when both ids resolve to on-budget accounts; such transfers carry
  /// no category (YNAB semantics).
  func accountsBothOnBudget(_ firstAccountID: String?, _ secondAccountID: String?) -> Bool {
    guard
      let firstAccountID,
      let secondAccountID,
      let first = account(withID: firstAccountID),
      let second = account(withID: secondAccountID)
    else {
      return false
    }
    return first.onBudget && second.onBudget
  }

  /// YNAB-style: picking a payee pre-fills the category it was last used with.
  func suggestedCategoryID(forPayeeID payeeID: String) -> String? {
    transactions.first { $0.payeeID == payeeID && $0.categoryID != nil && $0.transferAccountID == nil }?.categoryID
  }

  func applySettings(_ nextSettings: APISettings) async {
    let scopeChanged = nextSettings.viewPrefsScopeKey != activeViewPrefsScope
    // A change to the launch identity (endpoint or signed-in user) is picked
    // up by HowMuchApp's `.task(id: model.launchRefreshTaskID)`, which
    // restarts and calls `refreshAll()` on its own once this assignment is
    // observed. Calling it again here would run the whole launch waterfall
    // twice (e.g. once per sign-in), so only call it explicitly when the
    // identity is unchanged and no task restart will happen — such as
    // switching plans, or saving unrelated settings. A plan switch that lands
    // while an earlier launch refresh is still in flight does not cancel
    // that refresh either way: `launchRefreshTaskID` does not change, so
    // there is no task restart, and each fetch's generation/planID guard
    // (e.g. `refreshLedger`'s `planID == settings.planID` check) discards
    // the stale run's writes once it completes. Only the wasted requests are
    // a cost, not correctness.
    let launchIdentityChanged = nextSettings.launchFingerprint != settings.launchFingerprint
    settings = nextSettings
    settings.save()
    if scopeChanged {
      clearConnectionOwnedState()
    }
    switchViewPrefsScope()
    if !launchIdentityChanged {
      await refreshAll()
    }
  }

  // MARK: - Local mode

  /// "Start on this iPhone": creates the on-device plan, gives it starter
  /// categories, then switches to it. Nothing is saved until the engine has
  /// answered, so a failure leaves the welcome screen as it was.
  func startOnThisDevice() async throws {
    // Read before `prepare`, which creates the plan it is configured with:
    // an install that lost its preferences keeps the ledger already on disk.
    let local = APISettings.local(livePlanIDs: try await LocalEngine.shared.livePlanIDs())
    try await LocalEngine.shared.prepare(config: local.localEngineConfig)
    await completeStarterCategories(settings: local)
    isShowingWelcome = false
    isShowingSettings = false
    await applySettings(local)
  }

  /// Starter categories are a convenience: an empty list is still a working
  /// plan. A seed cut short finishes on a later launch.
  func completeStarterCategories(settings: APISettings? = nil) async {
    let settings = settings ?? self.settings
    guard settings.isLocal, settings.isAuthenticated else {
      return
    }
    do {
      try await StarterCategories.seedIfNeeded(client: APIClient(settings: settings), planID: settings.planID)
    } catch {
      Self.logger.error("Starter categories incomplete: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// "Connect to a server" on the welcome screen: today's sign-in.
  func showConnectionFromWelcome() {
    isShowingWelcome = false
    isShowingSettings = true
  }

  /// Sign-in started from the welcome screen can go back to it until a
  /// connection has been saved.
  var canReturnToWelcome: Bool {
    LaunchRoute.resolve(
      hasSavedSettings: APISettings.hasSavedSettings(),
      isAuthenticated: settings.isAuthenticated
    ) == .welcome
  }

  func returnToWelcome() {
    isShowingSettings = false
    isShowingWelcome = true
  }

  // MARK: - Connecting a local install to a server

  /// Moves this install to a signed-in server. The on-device database stays
  /// where it is, untouched, and is recorded as an archive.
  func adoptServerConnection(_ server: APISettings) async {
    guard settings.isLocal, !server.isLocal, server.isAuthenticated else {
      return
    }
    let adoption = ConnectionSwitch.adoptServer(server, leaving: settings, databaseURL: LocalEngine.shared.databaseURL)
    isShowingSettings = false
    await applySettings(adoption.settings)
    if let supersededToken = adoption.supersededToken {
      var previous = server
      previous.sessionToken = supersededToken
      try? await APIClient(settings: previous).logout()
    }
  }

  /// True while the connect flow waits on the network. Settings cannot be
  /// swiped away then, so a result never lands after the flow has gone.
  var isConnectingToServer = false

  /// "Keep using this iPhone only": ends the server session the connect flow
  /// opened. Local mode is untouched.
  func discardServerSession(_ server: APISettings) async {
    APISettings.forgetSavedSession(forBaseURL: server.baseURLString)
    try? await APIClient(settings: server).logout()
  }

  /// The ledger this install used before it connected to a server, if its
  /// database is still on the device.
  var localArchive: LocalArchive? {
    LocalArchive.existing()
  }

  /// Returns to the archived on-device ledger and signs out of the server.
  /// Refused while offline changes still wait to be sent: local mode would
  /// hide them.
  func switchToLocalArchive() async throws {
    guard !settings.isLocal, let archive = localArchive else {
      return
    }
    if let reason = ConnectionSwitch.blockReason(outbox: outbox, settings: settings) {
      throw APIClientError.validation(reason)
    }
    let server = settings
    // Local mode always runs on the shared engine's database, so only an
    // archive of that file can become live again.
    guard archive.databaseURL.standardizedFileURL == LocalEngine.shared.databaseURL.standardizedFileURL else {
      throw APIClientError.validation("The records from before you connected are not where Halation expects them.")
    }
    // Opens the database before anything is saved, so a failure leaves
    // server mode exactly as it was.
    try await LocalEngine.shared.prepare(config: archive.engineSettings.localEngineConfig)
    guard let local = ConnectionSwitch.returnToArchive(leaving: server) else {
      return
    }
    isShowingSettings = false
    await applySettings(local)
    try? await APIClient(settings: server).logout()
  }

  /// The archived ledger as a `howmuch-plan-snapshot` JSON file.
  func exportLocalArchive() async throws -> Data {
    guard let archive = localArchive else {
      throw APIClientError.validation("The records from before you connected are no longer on this device.")
    }
    return try await ServerConnector.exportArchive(archive)
  }

  /// Local mode has no cron, so the daily schedule catch-up runs on launch
  /// and whenever the app returns to the foreground.
  func runLocalScheduledTransactions(refreshAfter: Bool = true) async {
    guard settings.isLocal, settings.isAuthenticated else {
      return
    }
    guard let summary = try? await LocalEngine.shared.runScheduledMaterialization(config: settings.localEngineConfig),
          summary.occurrenceCount > 0,
          refreshAfter
    else {
      return
    }
    await refresh(slices: [.accounts, .payees, .ledger, .schedules])
  }

  /// A successful read means the server is reachable: send what waits.
  private func drainOutboxIfQueued() {
    guard !isSyncingOutbox, !isDrainScheduled,
          currentOutbox.contains(where: { $0.state == .queued }) else {
      return
    }
    scheduleOutboxDrain()
  }

  /// The app came back to the foreground.
  func sceneDidBecomeActive() {
    drainOutboxIfQueued()
  }

  /// True while a `refreshAll()` run is in flight, including the plan
  /// resolution that precedes any phase change. Not observable: poll it.
  var isRefreshingAll: Bool {
    inFlightRefreshAll != nil
  }

  /// Runs the whole launch waterfall: plan resolution, then reference data,
  /// ledger and schedules.
  ///
  /// - Parameter joinInFlight: when true, a run already in flight for the same
  ///   connection fingerprint is awaited instead of starting a second
  ///   waterfall. Only the capture-admission path opts in: it just needs the
  ///   reference data another path is already loading. Callers that have
  ///   changed server state (a rewards import, a settings save) must start a
  ///   fresh run, because a run that began before their write finished would
  ///   not see it.
  func refreshAll(quiet: Bool = false, joinInFlight: Bool = false) async {
    let fingerprint = settings.connectionFingerprint
    if joinInFlight, let inFlight = inFlightRefreshAll, inFlight.fingerprint == fingerprint {
      await inFlight.task.value
      return
    }
    refreshAllGeneration &+= 1
    let generation = refreshAllGeneration
    let task = Task { @MainActor [weak self] () -> Void in
      await self?.performRefreshAll(quiet: quiet)
      // The run clears its own record as its last step, so a caller that
      // arrives once the work finished but before the starting caller's
      // `await task.value` resumes never waits on an already-finished task.
      // A plan switch may have started a newer run meanwhile; the generation
      // guard keeps this run from clearing the newer run's record.
      if let self, self.inFlightRefreshAll?.generation == generation {
        self.inFlightRefreshAll = nil
      }
    }
    inFlightRefreshAll = (fingerprint, generation, task)
    await task.value
  }

  private func performRefreshAll(quiet: Bool) async {
    guard await resolvePlanSelection() else {
      return
    }

    // Replay offline captures alongside the fetches rather than before them:
    // an unreachable server must not stall the refresh for a full request
    // timeout. Inserts dedupe by id, so a capture the ledger fetch already
    // returned is never doubled.
    // The four Reflect reports are deliberately absent (#180): they are the
    // most expensive requests the app makes and nothing on launch shows them.
    // ReflectView fetches them when it appears, through
    // `refreshReportsIfNeeded()`.
    async let sent: Int = drainOutbox(trigger: .refresh)
    async let reference: Void = refreshReferenceData(quiet: quiet)
    async let ledger: Void = refreshLedger(quiet: quiet)
    async let schedules: Void = refreshScheduledTransactions(quiet: quiet)
    _ = await (sent, reference, ledger, schedules)
  }

  // MARK: - Narrow refreshes (#179)

  /// Refreshes only the slices a write could not reproduce locally, and marks
  /// the plan and reports stale when the write can have changed them.
  func refresh(after mutation: MutationKind) async {
    await scheduleRefresh(after: mutation)?.value
  }

  /// The same decision without waiting for it. Callers that are themselves
  /// inside a refresh — the outbox drain during a pull — must use this: it
  /// merges into the queue the running pass will drain, rather than awaiting
  /// the pass it is running inside.
  @discardableResult
  func scheduleRefresh(after mutation: MutationKind) -> Task<Void, Never>? {
    if RefreshPlanner.invalidatesPlanAndReports(after: mutation) {
      reportsRefreshGeneration &+= 1
    }
    return enqueue(RefreshRequest(slices: RefreshPlanner.slices(after: mutation)))
  }

  func refresh(slices: Set<RefreshSlice>, quiet: Bool = true, force: Bool = false) async {
    await refresh(RefreshRequest(slices: slices, quiet: quiet, force: force))
  }

  /// Debounce: a request that arrives while another refresh is running is
  /// merged into one queued request (union of slices, loudest intent) which
  /// runs exactly once after the current one finishes, so back-to-back
  /// mutations and repeated pulls collapse into a single extra pass.
  func refresh(_ request: RefreshRequest) async {
    guard !request.isEmpty else {
      return
    }
    await enqueue(request)?.value
  }

  /// Merges the request into the queue and returns the pass that will run it:
  /// the one already in flight, or a new one.
  @discardableResult
  private func enqueue(_ request: RefreshRequest) -> Task<Void, Never>? {
    guard !request.isEmpty else {
      return inFlightRefresh
    }
    queuedRefresh = queuedRefresh.merging(request)
    if let inFlight = inFlightRefresh {
      return inFlight
    }
    let task = Task { @MainActor [weak self] () -> Void in
      await self?.drainRefreshQueue()
    }
    inFlightRefresh = task
    return task
  }

  private func drainRefreshQueue() async {
    defer { inFlightRefresh = nil }
    // No suspension between emptying the queue and the loop's next test, so
    // a request enqueued by another caller is always either picked up here or
    // starts its own run against a cleared `inFlightRefresh`.
    while !queuedRefresh.isEmpty {
      let request = queuedRefresh
      queuedRefresh = .none
      await perform(request)
    }
  }

  private func perform(_ request: RefreshRequest) async {
    // A pull-to-refresh must still replay offline captures, as the launch
    // refresh does. Quiet passes are the ones that follow a write, which
    // already had its chance to send. An empty outbox issues no request.
    async let sent: Int = request.quiet ? 0 : drainOutbox(trigger: .refresh)
    async let accountsSlice: Void = run(.accounts, in: request)
    async let payeesSlice: Void = run(.payees, in: request)
    async let referenceSlice: Void = run(.referenceData, in: request)
    async let ledgerSlice: Void = run(.ledger, in: request)
    async let schedulesSlice: Void = run(.schedules, in: request)
    async let reportsSlice: Void = run(.reports, in: request)
    _ = await (
      sent, accountsSlice, payeesSlice, referenceSlice, ledgerSlice, schedulesSlice, reportsSlice
    )
  }

  private func run(_ slice: RefreshSlice, in request: RefreshRequest) async {
    guard request.slices.contains(slice) else {
      return
    }
    switch slice {
    case .accounts:
      await refreshAccounts(quiet: request.quiet)
    case .payees:
      await refreshPayees()
    case .referenceData:
      await refreshReferenceData(quiet: request.quiet)
    case .ledger:
      await refreshLedger(quiet: request.quiet)
    case .schedules:
      await refreshScheduledTransactions(quiet: request.quiet)
    case .reports:
      await refreshReportsIfNeeded(force: request.force)
    }
  }

  /// One GET for every balance. Deliberately narrower than
  /// `refreshReferenceData`: it does not touch categories, payees, plan
  /// settings, or the account-preferences sync, none of which a balance
  /// change can affect.
  func refreshAccounts(quiet: Bool = true) async {
    accountsGeneration &+= 1
    let generation = accountsGeneration
    let planID = settings.planID
    let scope = activeViewPrefsScope
    let readSequence = beginAccountsRead()
    // This slice fetches accounts alone, so it must never move
    // `referencePhase` to `.loaded`: categories, payees and plan settings
    // would still be missing behind that claim. A pull that arrives while the
    // reference batch is unloaded asks for the batch instead — see
    // `TabRefresh.accounts(referencePhase:)`.
    do {
      let fetched = try await apiClient.fetchAccounts(planID: planID)
      guard generation == accountsGeneration, planID == settings.planID, scope == activeViewPrefsScope
      else {
        return
      }
      if Set(accounts.map(\.id)) != Set(fetched.map(\.id)) {
        invalidateAccountUsage()
        pruneViewPrefs(using: fetched)
      }
      invalidateAccountHorizonFills()
      finishAccountsRead(readSequence)
      accounts = fetched
      rebuildLookups()
      drainOutboxIfQueued()
      persistSnapshot()
      publishIntentCatalog()
    } catch {
      guard generation == accountsGeneration, planID == settings.planID, scope == activeViewPrefsScope
      else {
        return
      }
      // Only a phase that was claiming loaded data can honestly be turned
      // into a failure by this fetch; an idle or already-failed reference
      // phase says more than "the balances did not come back".
      if !quiet, referencePhase == .loaded {
        referencePhase = .failed(error.localizedDescription)
      }
    }
  }

  /// One GET for the payee list, for writes that provision a payee server-side
  /// (a new account's transfer payee, a transaction saved with a new name).
  func refreshPayees() async {
    payeesGeneration &+= 1
    let generation = payeesGeneration
    let planID = settings.planID
    let scope = activeViewPrefsScope
    guard let fetched = try? await apiClient.fetchPayees(planID: planID) else {
      return
    }
    guard generation == payeesGeneration, planID == settings.planID, scope == activeViewPrefsScope
    else {
      return
    }
    payees = fetched
    rebuildLookups()
    persistSnapshot()
    publishIntentCatalog()
  }

  /// #180 (iOS half): fetch the reports when Reflect appears, and skip the
  /// refetch when neither the plan cursor nor this device's own writes have
  /// moved since the last successful fetch.
  func refreshReportsIfNeeded(force: Bool = false) async {
    guard ReportsRefreshPolicy.shouldFetch(
      phase: reportsPhase,
      force: force,
      lastKnowledge: reportsKnowledge,
      currentKnowledge: serverKnowledge,
      lastMutationGeneration: reportsGenerationAtLastFetch,
      currentMutationGeneration: reportsRefreshGeneration
    ) else {
      return
    }
    // Stamp what was true when the fetch started: a write that lands while it
    // is in flight must leave the cached reports looking stale.
    let knowledgeAtStart = serverKnowledge
    let generationAtStart = reportsRefreshGeneration
    if await refreshReflectOverview(quiet: reportsPhase == .loaded) {
      reportsKnowledge = knowledgeAtStart
      reportsGenerationAtLastFetch = generationAtStart
    }
  }

  /// Validates the saved plan against the authenticated plan list before any
  /// plan-scoped request begins. A sole plan is adopted automatically;
  /// ambiguous, empty, and unavailable lists return to Connection instead.
  private func resolvePlanSelection() async -> Bool {
    guard settings.isAuthenticated else {
      return false
    }

    let connectionFingerprint = settings.connectionFingerprint
    let client = apiClient
    do {
      let plans = try await client.fetchPlans()
      guard !Task.isCancelled, settings.connectionFingerprint == connectionFingerprint else {
        return false
      }
      guard let selectedPlanID = settings.resolvedPlanID(from: plans) else {
        if !settings.planID.isEmpty {
          clearConnectionOwnedState()
          settings.planID = ""
          settings.save()
          switchViewPrefsScope()
        }
        isShowingSettings = true
        return false
      }
      if selectedPlanID != settings.planID {
        clearConnectionOwnedState()
        settings.planID = selectedPlanID
        settings.save()
        switchViewPrefsScope()
      }
      return true
    } catch {
      guard !Task.isCancelled, settings.connectionFingerprint == connectionFingerprint else {
        return false
      }
      // #176: this returns before any slice runs, so nothing else will report
      // the failure against the phases a restored snapshot set to `.loaded`.
      failProvisionalPhases(error.localizedDescription)
      isShowingSettings = true
      return false
    }
  }

  func refreshReferenceData(quiet: Bool = false) async {
    referenceGeneration &+= 1
    let generation = referenceGeneration
    let planID = settings.planID
    let scope = activeViewPrefsScope
    let accountPreferencesAtStart = AccountPresentationPreferences(viewPrefs)
    let readSequence = beginAccountsRead()
    // #176: a launch refresh is loud, but blanking a snapshot the reader is
    // already looking at would undo the whole point of having one. The rows
    // stay until this fetch replaces them.
    if !quiet, !referenceIsProvisional {
      referencePhase = .loading
    }
    do {
      let reference = try await apiClient.fetchReferenceData(planID: planID)
      guard generation == referenceGeneration, planID == settings.planID, scope == activeViewPrefsScope else {
        return
      }
      if Set(accounts.map(\.id)) != Set(reference.accounts.map(\.id)) {
        invalidateAccountUsage()
      }
      invalidateAccountHorizonFills()
      planSettings = reference.planSettings
      finishAccountsRead(readSequence)
      accounts = reference.accounts
      categoryGroups = reference.categoryGroups
      payees = reference.payees
      rebuildLookups()
      let localAccountPreferences = AccountPresentationPreferences(viewPrefs)
      let lastSynced = scope.flatMap { scopedViewPrefsStore.syncedAccountPreferences[$0] }
      let localChangedDuringRefresh = localAccountPreferences != accountPreferencesAtStart
      let responseIsStale = reference.accountPreferences.map { response in
        response.revision < (lastSynced?.revision ?? 0)
      } ?? false
      let hasUnsyncedLocalArrangement = lastSynced.map {
        localAccountPreferences != $0.preferences
      } ?? false
      let hasPendingLocalMutation = scope.map {
        accountPreferenceSyncedGenerations[$0, default: 0]
          < accountPreferenceMutationGenerations[$0, default: 0]
      } ?? false
      if localChangedDuringRefresh || responseIsStale || hasUnsyncedLocalArrangement
        || hasPendingLocalMutation {
        enqueueAccountPreferencesSync()
      } else if let accountPreferences = reference.accountPreferences {
        viewPrefs = accountPreferences.preferences.applying(to: viewPrefs)
        if let scope = activeViewPrefsScope {
          scopedViewPrefsStore.set(viewPrefs, for: scope)
          scopedViewPrefsStore.markAccountPreferencesSynced(accountPreferences, for: scope)
        }
      } else {
        // First sync migrates an existing device-local arrangement instead of
        // replacing it with an empty server default.
        enqueueAccountPreferencesSync()
      }
      pruneViewPrefs(using: reference.accounts)
      referencePhase = .loaded
      // The network has replaced every reference row, so nothing older than
      // this response is on screen any more (#144).
      referenceIsProvisional = false
      drainOutboxIfQueued()
      lastSyncedAccountPreferences = reference.accountPreferences
      persistSnapshot()
      publishIntentCatalog()
    } catch {
      guard generation == referenceGeneration, planID == settings.planID, scope == activeViewPrefsScope else {
        return
      }
      referencePhase = .failed(error.localizedDescription)
    }
  }

  func refreshLedger(quiet: Bool = false) async {
    invalidateAccountUsage()
    ledgerPageGeneration += 1
    let generation = ledgerPageGeneration
    let planID = settings.planID
    // #176: provisional rows are already on screen; a loud refresh must not
    // replace them with a spinner. They are replaced, not merged, below.
    if !quiet, !ledgerIsProvisional {
      hasMoreTransactions = false
      nextTransactionOffset = nil
      isLoadingOlderTransactions = false
      isFillingHorizon = false
      horizonFillCount = 0
      olderTransactionsError = nil
      ledgerPhase = .loading
    }
    do {
      // The register is ready when its first page lands. The unapproved queue
      // used to be awaited here too, which made launch cost a full serial walk
      // of that queue before a single row could be shown.
      let page = try await fetchLedgerPage(planID: planID)
      guard generation == ledgerPageGeneration, planID == settings.planID else {
        return
      }
      pushHorizonFill()
      // The plan cursor the reports cache is keyed on (#180).
      if let knowledge = page.serverKnowledge {
        serverKnowledge = knowledge
      }
      // #176: when the rows on screen came from a snapshot taken at this very
      // cursor, the page just fetched is row-for-row what is already there, so
      // the assignment (and the re-render it triggers) is skipped. A cursor
      // that differs by even one always applies.
      let fetchedFirstPage = sortedUniqueTransactions(page.transactions)
      let applyIsRedundant = SnapshotPolicy.ledgerApplyIsRedundant(
        isProvisional: ledgerIsProvisional,
        snapshotKnowledge: snapshotKnowledge,
        responseKnowledge: page.serverKnowledge,
        snapshotRowIDs: provisionalLedgerRowIDs,
        responseRowIDs: fetchedFirstPage.map(\.id)
      )
      if !applyIsRedundant {
        // Rows are replaced below, so a fill that completed (or is still
        // running) under this generation no longer describes them.
        invalidateAccountHorizonFills()
        // Mutation refreshes must not drop already-loaded rows; List would clamp to top.
        // Provisional rows are the exception, in both directions: the response
        // must displace every row the snapshot put up (merging would keep rows
        // the server has since deleted, the staleness #144 forbids), while
        // older pages the reader scrolled to in this session came from the
        // network and must survive. A loud refresh replaces outright, as it
        // always has.
        if quiet, ledgerIsProvisional {
          let displaced = Set(provisionalLedgerRowIDs)
          serverTransactions = sortedUniqueTransactions(
            fetchedFirstPage + serverTransactions.filter { !displaced.contains($0.id) }
          )
        } else {
          serverTransactions = sortedUniqueTransactions(
            quiet ? fetchedFirstPage + serverTransactions : fetchedFirstPage
          )
        }
      }
      applyTransactionPageCursor(page)
      ledgerPhase = .loaded
      ledgerIsProvisional = false
      provisionalLedgerRowIDs = []
      lastLedgerFirstPage = ReferenceSnapshot.LedgerPage(
        transactions: fetchedFirstPage,
        hasMore: page.hasMore,
        nextOffset: page.nextOffset
      )
      persistSnapshot()
      // The badge, and the rows only if the approval flow is already open. Both
      // run alongside the horizon fill below rather than in front of it.
      Task { await self.refreshUnapprovedCount(generation: generation, planID: planID) }
      if unapprovedQueuePhase == .loaded || unapprovedQueuePhase.isLoading {
        Task { await self.loadUnapprovedQueue(generation: generation, planID: planID) }
      }
      defer {
        if generation == ledgerPageGeneration, planID == settings.planID {
          popHorizonFill()
        }
      }
      while RegisterHorizon.standard.shouldFetchMore(
        oldestLoadedDate: RegisterHorizon.coverageOldestDate(in: serverTransactions, accountID: nil),
        hasMore: hasMoreTransactions,
        rowCount: serverTransactions.count
      ) {
        guard let offset = nextTransactionOffset else {
          break
        }
        do {
          let older = try await fetchLedgerPage(planID: planID, offset: offset)
          guard
            generation == ledgerPageGeneration,
            planID == settings.planID,
            nextTransactionOffset == offset
          else {
            return
          }
          applyOlderTransactionPage(older, generation: generation)
        } catch {
          guard generation == ledgerPageGeneration, planID == settings.planID else {
            return
          }
          hasMoreTransactions = true
          break
        }
      }
      if focusedRegisterAccountIDs.last != nil {
        await fillFocusedAccountHorizon(generation: generation, planID: planID)
      }
    } catch {
      guard generation == ledgerPageGeneration, planID == settings.planID else {
        return
      }
      ledgerPhase = .failed(error.localizedDescription)
    }
  }

  /// Refreshes the "New" badge. One bounded request; failure leaves the previous
  /// number in place rather than blanking the tile.
  private func refreshUnapprovedCount(generation: Int, planID: String) async {
    await refreshUnapprovedCount(generation: generation, planID: planID, accountID: nil)
  }

  /// Refreshes a register's "New" count. A narrowed register asks for its own
  /// account, since the plan-wide number would overstate it. Failure leaves the
  /// previous number in place rather than blanking the badge.
  func refreshUnapprovedCount(forAccountID accountID: String?) async {
    await refreshUnapprovedCount(generation: ledgerPageGeneration, planID: settings.planID, accountID: accountID)
  }

  private func refreshUnapprovedCount(generation: Int, planID: String, accountID: String?) async {
    // What the count can already reflect is what was resolved before it was
    // asked for. A row approved or rejected while the request is out may land
    // either side of the server's count, so it stays subtracted until the next
    // count rather than being assumed counted.
    let resolvedAtRequest = unapprovedIDsTheServerMayReflect
    guard let count = try? await apiClient.fetchUnapprovedCount(planID: planID, accountID: accountID) else { return }
    guard generation == ledgerPageGeneration, planID == settings.planID else { return }
    if let accountID {
      serverUnapprovedCountsByAccount[accountID] = count
    } else {
      serverUnapprovedCount = count
    }
    confirmedWhenCounted[countScopeKey(accountID)] = resolvedAtRequest
    if accountID == nil {
      // The count lands after the ledger page that spawned it, so the snapshot
      // written there carries the previous number. Rewrite it with this one,
      // once the rows it already reflects are no longer subtracted from it.
      persistSnapshot()
    }
  }

  /// Rows this session has taken off the queue: approved, or rejected.
  private var locallyResolvedUnapprovedIDs: Set<String> {
    RegisterApproval.resolvedIDs(approvalSession)
      .union(rejectedUnapprovedAccounts.keys)
      .union(queuedUnapprovedRejections.keys)
  }

  /// The resolved rows a count asked for now may already reflect: those the
  /// server has acknowledged, and those on the wire. A change still waiting
  /// in the outbox cannot be in any count, so it is always subtracted.
  private var unapprovedIDsTheServerMayReflect: Set<String> {
    let inFlight = currentOutbox.filter(\.isInFlight).map(\.transactionID)
    return approvalSession.confirmed
      .union(rejectedUnapprovedAccounts.keys)
      .union(locallyResolvedUnapprovedIDs.intersection(inFlight))
  }

  /// One key per counted scope: the plan, or a single account.
  private func countScopeKey(_ accountID: String?) -> String {
    accountID.map { "account:\($0)" } ?? "plan"
  }

  /// Loads the unapproved rows. Called when the approval flow opens, and again
  /// on later refreshes while it stays open -- never on the launch path.
  /// Called by a view opening the approval flow. `viewer` identifies that view
  /// so a sibling register closing cannot release rows this one is showing.
  func openUnapprovedQueue(viewer: String) async {
    unapprovedQueueViewers.insert(viewer)
    // `.failed` is retried: otherwise the flow shows its error with no way out
    // short of a pull-to-refresh.
    guard unapprovedQueuePhase == .idle || unapprovedQueuePhase.errorMessage != nil else { return }
    await loadUnapprovedQueue(generation: ledgerPageGeneration, planID: settings.planID)
  }

  /// Called when a view closes the approval flow. The queue is released only
  /// once no view is showing it, so later refreshes stop paying for the walk --
  /// without that, opening the flow once would re-arm it for the session.
  func closeUnapprovedQueue(viewer: String) {
    unapprovedQueueViewers.remove(viewer)
    guard unapprovedQueueViewers.isEmpty else { return }
    unapprovedQueuePhase = .idle
  }

  private func loadUnapprovedQueue(generation: Int, planID: String) async {
    // The client walks this queue's pages internally, so the fence covers the
    // walk rather than one request. That stays safe: a page asked for after a
    // delete cannot name the rows it removed or the line it unlinked, and a
    // line that has since been relinked names a different mirror, which
    // `linksSplitMirror` refuses to unlink.
    let readGeneration = beginLedgerRead()
    defer { endLedgerRead(readGeneration) }
    unapprovedQueuePhase = .loading
    do {
      let unapproved = try await apiClient.fetchAllUnapprovedTransactions(planID: planID)
      guard generation == ledgerPageGeneration, planID == settings.planID else { return }
      guard stillWantsUnapprovedQueue() else { return }
      let repaired = repairingStaleRead(unapproved, startedAt: readGeneration)
      replaceUnapprovedQueue(with: repaired)
      unapprovedQueuePhase = .loaded
    } catch {
      guard generation == ledgerPageGeneration, planID == settings.planID else { return }
      guard stillWantsUnapprovedQueue() else { return }
      unapprovedQueuePhase = .failed(error.localizedDescription)
    }
  }

  /// The flow can close while a load is in flight. Landing `.loaded` behind it
  /// would leave the queue loaded with nobody showing it, and every later ledger
  /// refresh would walk it again.
  private func stillWantsUnapprovedQueue() -> Bool {
    if unapprovedQueueViewers.isEmpty {
      unapprovedQueuePhase = .idle
      return false
    }
    return true
  }

  private func invalidateAccountUsage() {
    guard accountUsagePhase != .idle || !accountUsageLast30Days.isEmpty else {
      return
    }
    accountUsageLast30Days = [:]
    accountUsagePhase = .idle
    accountUsageGeneration &+= 1
  }

  /// Prevents one server, user, or plan from remaining visible while a newly
  /// selected connection is loading or has failed to load.
  private func clearConnectionOwnedState() {
    // #176: every caller of this is a change of endpoint, user or plan, which
    // is exactly when a snapshot may no longer be shown.
    discardSnapshot()
    planSettings = nil
    accounts = []
    categoryGroups = []
    payees = []
    serverTransactions = []
    serverUnapprovedTransactions = []
    serverUnapprovedCount = 0
    serverUnapprovedCountsByAccount = [:]
    confirmedWhenCounted = [:]
    rejectedUnapprovedAccounts = [:]
    unapprovedQueuePhase = .idle
    unapprovedQueueViewers = []
    approvalSession = .empty
    syncApprovalPending()
    scheduledTransactions = []
    spendingBreakdown = nil
    incomeVsSpending = nil
    netWorth = nil
    ageOfMoney = nil
    clearRewards()
    // The outbox itself stays: it is keyed by connection, and its commands
    // wait for this connection to sign in again.
    drainScheduleToken &+= 1
    isDrainScheduled = false
    acknowledgedBalanceDeltas = []
    hasMoreTransactions = false
    nextTransactionOffset = nil
    isLoadingOlderTransactions = false
    isFillingHorizon = false
    horizonFillCount = 0
    olderTransactionsError = nil
    referencePhase = .idle
    ledgerPhase = .idle
    scheduledTransactionsPhase = .idle
    reportsPhase = .idle
    rebuildLookups()
    ledgerPageGeneration &+= 1
    referenceGeneration &+= 1
    accountsGeneration &+= 1
    payeesGeneration &+= 1
    scheduledTransactionsGeneration &+= 1
    reportsGeneration &+= 1
    // A delete's records and the reads that needed them belong to one
    // connection: nothing from the old scope can land after this, and a row in
    // the new plan that happens to share a deleted id is its own row.
    ledgerReadGeneration &+= 1
    inFlightLedgerReads.removeAll()
    ledgerDeletes.removeAll()
    ledgerWrites.removeAll()
    // A cursor and a reports cache belong to one plan; carrying them across a
    // connection change would serve the previous plan's reports.
    serverKnowledge = nil
    reportsKnowledge = nil
    reportsGenerationAtLastFetch = nil
    queuedRefresh = .none
    // ReflectView's only trigger is `.task(id: reportsRefreshGeneration)`, so
    // without this a plan switch made while Reflect is visible leaves it
    // sitting on an empty placeholder.
    reportsRefreshGeneration &+= 1
    rewardsRefreshGeneration &+= 1
    invalidateAccountUsage()
    wipeIntentCatalog()
  }

  private func clearRewards() {
    rewardsReport = nil
    rewardsReportRequest = nil
    rewardsPhase = .idle
    rewardsGeneration &+= 1
    registerRewardsByAccount = [:]
  }

  /// Loads the Rewards board for one request. Only the latest call may land,
  /// so a filter changed mid-flight cannot be overwritten by the one before
  /// it. The overview request is cached for the next launch; a filtered one
  /// is not. Returns the report when it landed, for the view's own follow-up.
  @discardableResult
  func refreshRewards(_ request: RewardsRequest) async -> RewardsReport? {
    rewardsGeneration &+= 1
    let generation = rewardsGeneration
    rewardsPhase = .loading
    do {
      let next = try await apiClient.fetchRewards(
        planID: request.planID,
        from: request.from,
        to: request.to,
        accountIDs: request.accountIDs,
        group: .flag
      )
      guard generation == rewardsGeneration, request.planID == settings.planID else {
        return nil
      }
      rewardsReport = next
      rewardsReportRequest = request
      rewardsPhase = .loaded
      if request.isOverview {
        cachedRewardsOverview = next
        persistReports()
      }
      return next
    } catch {
      guard generation == rewardsGeneration, request.planID == settings.planID else {
        return nil
      }
      // Leaving the tab cancels the view's task. That is not a failure, and a
      // phase stuck at `.loading` would spin forever: settle it as Reflect does.
      if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
        rewardsPhase = rewardsReport(for: request) == nil ? .idle : .loaded
        return nil
      }
      rewardsPhase = .failed(error.localizedDescription)
      return nil
    }
  }

  func noteRewardsBoardChanged() {
    rewardsRefreshGeneration &+= 1
  }

  func noteRewardsImport() async {
    noteRewardsBoardChanged()
    // The import has just written server state, so it must not join a run
    // that started before the import finished and would miss it.
    await refreshAll(quiet: true)
  }

  func publishIntentCatalog(using store: IntentCatalogStore = .shared) {
    let snapshot = IntentCatalogSnapshot.project(
      fingerprint: settings.connectionFingerprint,
      accounts: accounts,
      categoryGroups: categoryGroups,
      payees: payees
    )
    store.scheduleWrite(snapshot)
  }

  func wipeIntentCatalog(using store: IntentCatalogStore = .shared) {
    store.wipeAll()
  }

  func refreshScheduledTransactions(quiet: Bool = false) async {
    scheduledTransactionsGeneration &+= 1
    let generation = scheduledTransactionsGeneration
    let planID = settings.planID
    let scope = activeViewPrefsScope
    let client = apiClient
    // #176: as with the ledger, a snapshot already on screen is replaced by
    // this fetch rather than blanked while it runs.
    if !quiet, !schedulesIsProvisional {
      scheduledTransactionsPhase = .loading
    }
    do {
      let schedules = try await client.fetchScheduledTransactions(planID: planID)
      guard generation == scheduledTransactionsGeneration,
            planID == settings.planID,
            scope == activeViewPrefsScope
      else {
        return
      }
      scheduledTransactions = schedules.sorted { ($0.dateNext, $0.id) < ($1.dateNext, $1.id) }
      scheduledTransactionsPhase = .loaded
      schedulesIsProvisional = false
      persistSnapshot()
    } catch {
      guard generation == scheduledTransactionsGeneration,
            planID == settings.planID,
            scope == activeViewPrefsScope
      else {
        return
      }
      scheduledTransactionsPhase = .failed(error.localizedDescription)
    }
  }

  func saveScheduledTransaction(_ draft: ScheduledTransactionDraft) async throws {
    guard let request = draft.writeRequest() else {
      throw APIClientError.validation("Choose an account, enter an amount, and keep the next date on or after the first date.")
    }
    isSubmitting = true
    defer { isSubmitting = false }

    let saved: ScheduledTransaction
    let idempotencyKey = draft.idempotencyKey(for: request)
    if let id = draft.id {
      saved = try await apiClient.updateScheduledTransaction(planID: settings.planID, scheduleID: id, idempotencyKey: idempotencyKey, request: request)
    } else {
      saved = try await apiClient.createScheduledTransaction(planID: settings.planID, idempotencyKey: idempotencyKey, request: request)
    }
    scheduledTransactions.removeAll { $0.id == saved.id }
    if !saved.deleted {
      scheduledTransactions.append(saved)
      scheduledTransactions.sort { ($0.dateNext, $0.id) < ($1.dateNext, $1.id) }
    }
    scheduledTransactionsPhase = .loaded
    scheduleRefresh(after: .scheduleSaved)
    showSaveMessage(draft.id == nil ? "Added scheduled transaction" : "Saved scheduled transaction")
  }

  func deleteScheduledTransaction(id: String, idempotencyKey: String) async throws {
    isSubmitting = true
    defer { isSubmitting = false }

    _ = try await apiClient.deleteScheduledTransaction(planID: settings.planID, scheduleID: id, idempotencyKey: idempotencyKey)
    scheduledTransactions.removeAll { $0.id == id }
    scheduledTransactionsPhase = .loaded
    scheduleRefresh(after: .scheduleDeleted)
    showSaveMessage("Deleted scheduled transaction")
  }

  func enterScheduledOccurrence(
    scheduleID: String,
    occurrenceDate: String,
    enteredDate: String,
    idempotencyKey: String
  ) async throws -> ScheduledOccurrencePayload {
    isSubmitting = true
    defer { isSubmitting = false }

    let result = try await apiClient.materializeScheduledOccurrence(
      planID: settings.planID,
      scheduleID: scheduleID,
      idempotencyKey: idempotencyKey,
      occurrenceDate: occurrenceDate,
      enteredDate: enteredDate
    )

    // The response carries both halves of the write, so apply them rather
    // than re-reading the ledger and the schedule list to find them.
    serverTransactions = sortedUniqueTransactions([result.transaction] + serverTransactions)
    if !result.transaction.approved {
      serverUnapprovedTransactions = sortedUniqueTransactions(
        [result.transaction] + serverUnapprovedTransactions
      )
    }
    scheduledTransactions.removeAll { $0.id == result.scheduledTransaction.id }
    if !result.scheduledTransaction.deleted {
      scheduledTransactions.append(result.scheduledTransaction)
      scheduledTransactions.sort { ($0.dateNext, $0.id) < ($1.dateNext, $1.id) }
    }
    // Both halves are applied above; the follow-up read runs behind the dismissal.
    scheduleRefresh(after: .scheduledOccurrenceEntered(isTransfer: isTransfer(result.transaction)))
    showSaveMessage(result.completed ? "Entered final scheduled transaction" : "Entered scheduled transaction")
    return result
  }

  func reconcileAccount(
    accountID: String,
    statementDate: String,
    statementBalance: Int,
    idempotencyKey: String
  ) async throws -> AccountReconciliationPayload {
    isSubmitting = true
    defer { isSubmitting = false }
    // The server checks the statement against what it holds, so the changes
    // to this account go first.
    if reconcileBlockReason(accountID: accountID) != nil {
      await waitForOutboxDrain()
      await drainOutbox(trigger: .manual)
    }
    if let reason = reconcileBlockReason(accountID: accountID) {
      throw APIClientError.validation(reason)
    }

    let result = try await apiClient.reconcileAccount(
      planID: settings.planID,
      accountID: accountID,
      idempotencyKey: idempotencyKey,
      statementDate: statementDate,
      statementBalance: statementBalance
    )

    // The response already carries the account with its new balances, and
    // every acknowledged change to it (Reconcile waits for the outbox).
    if let index = serverAccounts.firstIndex(where: { $0.id == result.account.id }) {
      acknowledgedBalanceDeltas = acknowledgedBalanceDeltas.map { entry in
        AcknowledgedDelta(sequence: entry.sequence, deltas: entry.deltas.filter { $0.key != result.account.id })
      }
      serverAccounts[index] = result.account
      rebuildLookups()
    }
    // Waits, unlike the other saves: until the read lands, rows would still
    // show as merely cleared (and tappable) and any adjustment would be missing.
    await refresh(after: .accountReconciled)

    let accountName = result.account.name
    let count = result.reconciledTransactionCount
    showSaveMessage("\(accountName) reconciled through \(LedgerDate.friendlyString(fromISO: result.statementDate)). \(count) cleared transaction\(count == 1 ? "" : "s") matched \(MoneyCodec.displayString(for: result.statementBalance, currencyFormat: currencyFormat)).")
    return result
  }

  func fetchAccountReconciliation(accountID: String, statementDate: String) async throws -> AccountReconciliationPreview {
    try await apiClient.fetchAccountReconciliation(
      planID: settings.planID,
      accountID: accountID,
      statementDate: statementDate
    )
  }

  /// Account registers filter the shared cache locally, but a busy plan-wide
  /// first page can hide a quieter account's last two months. Fill that
  /// account's own cursor (bounded by `since_date`) and merge it in. Leave
  /// the plan-wide Load older offset alone.
  func fillFocusedAccountHorizon() async {
    await fillFocusedAccountHorizon(generation: ledgerPageGeneration, planID: settings.planID)
  }

  private func invalidateAccountHorizonFills() {
    completedAccountHorizonFills.removeAll()
    accountHorizonCompletionEpoch &+= 1
  }

  func retryIncompleteRegisterFill() async {
    olderTransactionsError = nil
    if focusedRegisterAccountIDs.last != nil {
      await fillFocusedAccountHorizon()
      if olderTransactionsError != nil {
        return
      }
    }
    await loadOlderTransactions()
  }

  private func fillFocusedAccountHorizon(generation: Int, planID: String) async {
    guard let accountID = focusedRegisterAccountIDs.last else {
      return
    }
    let horizon = RegisterHorizon.standard
    let startDate = horizon.startDate()
    // A quiet account's rows all sit inside the horizon, so the loop below
    // would refetch it on every appearance. Reuse its completed fill until a
    // ledger or account-list refresh invalidates it; new balances may include
    // external transactions that the register has not loaded yet.
    let fillKey = "\(generation)|\(planID)|\(startDate)"
    if completedAccountHorizonFills[accountID] == fillKey {
      // Reappearing still clears a stale error, as a fresh fill would.
      olderTransactionsError = nil
      return
    }
    let completionEpochAtStart = accountHorizonCompletionEpoch
    let ownsFill = horizonFillCount == 0
    if ownsFill {
      pushHorizonFill()
    }
    defer {
      if ownsFill, generation == ledgerPageGeneration {
        popHorizonFill()
      }
    }

    olderTransactionsError = nil

    var loaded = serverTransactions.filter { $0.accountID == accountID }
    var offset = 0
    var hasMore = true

    while horizon.shouldFetchMore(
      oldestLoadedDate: RegisterHorizon.coverageOldestDate(in: loaded, accountID: accountID),
      hasMore: hasMore,
      rowCount: loaded.count
    ) {
      do {
        let page = try await fetchLedgerPage(
          planID: planID,
          accountID: accountID,
          offset: offset,
          sinceDate: startDate
        )
        guard
          generation == ledgerPageGeneration,
          planID == settings.planID,
          focusedRegisterAccountIDs.last == accountID
        else {
          return
        }
        loaded = sortedUniqueTransactions(page.transactions + loaded).filter { $0.accountID == accountID }
        // Fetched rows win, as for older pages: the read is already fenced.
        serverTransactions = sortedUniqueTransactions(page.transactions + serverTransactions)
        offset = page.nextOffset ?? loaded.count
        hasMore = page.hasMore && page.nextOffset != nil
      } catch {
        guard generation == ledgerPageGeneration, planID == settings.planID else {
          return
        }
        olderTransactionsError = error.localizedDescription
        return
      }
    }
    if generation == ledgerPageGeneration,
       planID == settings.planID,
       completionEpochAtStart == accountHorizonCompletionEpoch {
      completedAccountHorizonFills[accountID] = fillKey
    }
  }

  private func pushHorizonFill() {
    horizonFillCount += 1
    isFillingHorizon = true
  }

  private func popHorizonFill() {
    horizonFillCount = max(0, horizonFillCount - 1)
    isFillingHorizon = horizonFillCount > 0
  }

  /// Appends one older page to the current, unfiltered ledger cursor. Register
  /// scopes and drill-downs filter this common ordered page locally, so their
  /// navigation cannot leave a separate filter-specific offset behind.
  func loadOlderTransactions() async {
    guard
      ledgerPhase == .loaded,
      hasMoreTransactions,
      let offset = nextTransactionOffset,
      !isLoadingOlderTransactions,
      !isFillingHorizon
    else {
      return
    }

    let generation = ledgerPageGeneration
    let planID = settings.planID
    isLoadingOlderTransactions = true
    olderTransactionsError = nil
    defer {
      if generation == ledgerPageGeneration, planID == settings.planID {
        isLoadingOlderTransactions = false
      }
    }

    do {
      let page = try await fetchLedgerPage(planID: planID, offset: offset)
      guard
        generation == ledgerPageGeneration,
        planID == settings.planID,
        nextTransactionOffset == offset
      else {
        return
      }
      applyOlderTransactionPage(page, generation: generation)
    } catch {
      guard generation == ledgerPageGeneration, planID == settings.planID else {
        return
      }
      olderTransactionsError = error.localizedDescription
    }
  }

  private func applyTransactionPageCursor(_ page: TransactionPage) {
    hasMoreTransactions = page.hasMore && page.nextOffset != nil
    nextTransactionOffset = hasMoreTransactions ? page.nextOffset : nil
  }

  private func applyOlderTransactionPage(_ page: TransactionPage, generation: Int) {
    // The page is the server's word on its rows: `fetchLedgerPage` has
    // already repaired it against any write acknowledged since it was asked
    // for, and unsent changes are an overlay, so a fetched row replaces the
    // copy already loaded.
    serverTransactions = sortedUniqueTransactions(page.transactions + serverTransactions)
    applyTransactionPageCursor(page)
  }

  private func sortedUniqueTransactions(_ rows: [Transaction]) -> [Transaction] {
    var byID: [String: Transaction] = [:]
    for transaction in rows where byID[transaction.id] == nil {
      byID[transaction.id] = transaction
    }
    return byID.values.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
  }

  /// Reflect overview: current month for the spending breakdown, trailing
  /// twelve months by month for the trend reports.
  @discardableResult
  func refreshReflectOverview(quiet: Bool = false) async -> Bool {
    reportsGeneration &+= 1
    let generation = reportsGeneration
    let planID = settings.planID
    let scope = activeViewPrefsScope
    let client = apiClient
    if !quiet {
      reportsPhase = .loading
    }
    do {
      let now = Date.now
      let monthStart = now.startOfMonth()
      let yearStart = Calendar.current.date(byAdding: .month, value: -11, to: monthStart) ?? monthStart
      let today = now.isoDateString

      async let spending = client.fetchSpendingBreakdown(
        planID: planID, from: monthStart.isoDateString, to: today
      )
      async let income = client.fetchIncomeVsSpending(
        planID: planID, from: yearStart.isoDateString, to: today, interval: .month
      )
      async let worth = client.fetchNetWorth(
        planID: planID, from: yearStart.isoDateString, to: today, interval: .month
      )
      async let age = client.fetchAgeOfMoney(planID: planID, interval: .month)

      let (spendingReport, incomeReport, worthReport, ageReport) = try await (spending, income, worth, age)
      guard generation == reportsGeneration,
            planID == settings.planID,
            scope == activeViewPrefsScope
      else {
        return false
      }
      spendingBreakdown = spendingReport
      incomeVsSpending = incomeReport
      netWorth = worthReport
      ageOfMoney = ageReport
      reflectMonth = ReportsSnapshot.month(of: monthStart)
      reportsPhase = .loaded
      persistReports()
      return true
    } catch {
      guard generation == reportsGeneration,
            planID == settings.planID,
            scope == activeViewPrefsScope
      else {
        return false
      }
      // The first fetch now runs from ReflectView's own task, so leaving the
      // tab cancels it. That is not a failure the reader should be shown, and
      // leaving the phase at `.loading` would lock the gate against ever
      // retrying: return it to `.idle` so the next appearance fetches again.
      if Task.isCancelled {
        if reportsPhase == .loading {
          reportsPhase = .idle
        }
        return false
      }
      reportsPhase = .failed(error.localizedDescription)
      return false
    }
  }

  // MARK: - Transaction writes (docs/plans/offline-writes.md P1)
  //
  // Every transaction write goes into the outbox first: it is on disk before
  // it is on screen, and on screen before any request is made. Replay sends it
  // later, in batches, and the overlay shows it until the server has it.

  func commit(_ draft: TransactionDraft) throws {
    try commit([draft])
  }

  func commit(_ drafts: [TransactionDraft]) throws {
    guard !drafts.isEmpty else {
      return
    }
    for draft in drafts {
      try CommitRejection.check(draft)
    }
    var commands: [OutboxCommand] = []
    var creates: [TransactionDraft] = []
    var seenImportIDs: Set<String> = []
    for draft in drafts {
      if let transactionID = draft.id {
        commands.append(editCommand(draft, transactionID: transactionID, base: serverRow(transactionID)))
        continue
      }
      var request = draft.writeRequest(includeCleared: draft.shouldWriteCleared)
      let importID = request.importID ?? UUID().uuidString.lowercased()
      request.importID = importID
      request.id = nil
      // A capture saved twice is still one transaction.
      guard !hasPendingCreate(importID: importID), seenImportIDs.insert(importID).inserted else {
        continue
      }
      commands.append(
        makeCommand(transactionID: OutboxCommand.mintTransactionID(), kind: .create(request), base: nil)
      )
      creates.append(draft)
    }
    do {
      try enqueueOutbox(commands)
    } catch let refusal as OutboxEnqueueRefusal {
      throw refusal
    } catch {
      throw CommitRejection.persistFailed
    }
    rememberLastUsedAccount(from: drafts)
    showSaveMessage(savedMessage(for: creates.isEmpty ? drafts : creates))
  }

  private func rememberLastUsedAccount(from drafts: [TransactionDraft]) {
    guard let last = drafts.last, !last.accountID.isEmpty else {
      return
    }
    viewPrefs.lastUsedAccountID = last.accountID
    saveViewPrefs()
  }

  private func savedMessage(for drafts: [TransactionDraft]) -> String {
    if drafts.count == 1, let draft = drafts.first {
      let payee = draft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Saved \(MoneyCodec.displayString(for: draft.signedMilliunits, currencyFormat: currencyFormat)) — \(payee.isEmpty ? "transaction" : payee)"
    }
    return "Saved \(drafts.count) transactions"
  }

  func toggleTransactionCleared(_ transaction: Transaction) async throws {
    // The compare-and-set guard is the status the server will hold when this
    // is sent: the row as shown, which already includes anything on the wire.
    let current = displayedRow(transaction.id) ?? transaction
    guard current.cleared != .reconciled else {
      throw APIClientError.validation("Reconciled transactions stay locked.")
    }
    let cleared: ClearedState = current.cleared == .cleared ? .uncleared : .cleared
    try enqueueOutbox([
      makeCommand(
        transactionID: transaction.id,
        kind: .cleared(expected: current.cleared, cleared: cleared, approve: false),
        base: serverRow(transaction.id) ?? transaction
      ),
    ])
    showSaveMessage(cleared == .cleared ? "Marked transaction cleared" : "Marked transaction uncleared")
  }

  func deleteTransaction(_ transaction: Transaction) async throws {
    let current = displayedRow(transaction.id) ?? transaction
    try enqueueOutbox([
      makeCommand(
        transactionID: transaction.id,
        kind: .delete(expectedApproved: current.approved ? nil : false),
        base: serverRow(transaction.id) ?? transaction
      ),
    ])
    showSaveMessage("Deleted \(transaction.payeeName ?? "transaction")")
  }

  func approveEligible(from rows: [Transaction]) {
    startApproval(from: rows, success: .bulk)
  }

  func approveTransaction(_ transaction: Transaction) {
    guard !transaction.approved else {
      return
    }
    startApproval(from: [transaction], success: .single(transaction))
  }

  private func startApproval(from rows: [Transaction], success: ApprovalSuccessCopy) {
    guard let plan = RegisterApproval.plan(
      submitted: rows.map(\.approvalRow),
      session: approvalSession
    ) else {
      return
    }
    let commands = plan.ids.map { id in
      makeCommand(transactionID: id, kind: .approve, base: serverRow(id) ?? rows.first { $0.id == id })
    }
    do {
      try enqueueOutbox(commands)
    } catch {
      showSaveMessage("Couldn’t approve — \(error.localizedDescription)", kind: .failure)
      return
    }
    showSaveMessage(Self.successToast(success, plannedCount: plan.ids.count))
  }

  func hasReconciledLinkedTransfer(ids: [String]) -> Bool {
    guard !ids.isEmpty else {
      return false
    }
    let rows = transactions + unapprovedTransactions
    return ids.contains { id in
      rows.contains { $0.id == id && $0.cleared == .reconciled }
    }
  }

  /// Sends a rejected change again.
  func retryPending(_ id: PendingRow.ID) {
    guard let index = outbox.firstIndex(where: { $0.id == id }) else {
      return
    }
    if case .rejected(_, let code) = outbox[index].state {
      var next = outbox
      next[index].state = .queued
      if code == Self.deletedElsewhereCode, outbox[index].kind.isCreate {
        // The user chose to add it again. The old id may belong to a row
        // deleted on another device, so the new row gets a new one, and the
        // changes queued behind it follow.
        let oldKey = outbox[index].rowKey
        let newID = OutboxCommand.mintTransactionID()
        for other in next.indices where next[other].rowKey == oldKey && !next[other].isInFlight {
          next[other].transactionID = newID
        }
        next[index].attempted = false
        next[index].sentWithClientID = false
      }
      do {
        try outboxStore.save(next)
      } catch {
        showSaveMessage("Couldn’t retry this change. Try again.", kind: .failure)
        return
      }
      outbox = next
    }
    // Only this change was retried: a plain pass, not "Sync Now".
    Task { await drainOutbox(trigger: .refresh) }
  }

  /// Drops an unsent change. The row goes back to what the server has.
  func discardPending(_ id: PendingRow.ID) {
    guard let command = outbox.first(where: { $0.id == id }) else {
      return
    }
    guard !command.isInFlight else {
      showSaveMessage("This change is still sending. Wait for it to finish.", kind: .failure)
      return
    }
    // Discarding a create discards the row: the changes queued behind it
    // have nothing to apply to.
    let next = outbox.filter { other in
      if other.id == id { return false }
      return !(command.kind.isCreate && other.rowKey == command.rowKey && !other.isInFlight)
    }
    do {
      try outboxStore.save(next)
    } catch {
      showSaveMessage("Couldn’t discard this change. Try again.", kind: .failure)
      return
    }
    outbox = next
    if let base = command.baseSnapshot, !command.kind.isCreate, serverRow(base.id) == nil {
      serverTransactions = sortedUniqueTransactions([base] + serverTransactions)
    }
    if case .rejected = command.state {
      // The server refused it, so its copy may differ from ours.
      enqueue(RefreshRequest(slices: [.ledger, .accounts]))
    }
  }

  private func editCommand(_ draft: TransactionDraft, transactionID: String, base: Transaction?) -> OutboxCommand {
    var request = draft.writeRequest(includeCleared: draft.shouldWriteCleared)
    request.importID = nil
    request.id = nil
    return makeCommand(transactionID: transactionID, kind: .update(request), base: base)
  }

  private func makeCommand(
    transactionID: String,
    kind: OutboxCommand.Kind,
    base: Transaction?
  ) -> OutboxCommand {
    OutboxCommand(
      id: UUID(),
      transactionID: transactionID,
      connectionFingerprint: settings.connectionFingerprint,
      createdAt: .now,
      kind: kind,
      baseSnapshot: base
    )
  }

  // MARK: - Outbox: storage

  private func loadOutbox() {
    do {
      outbox = try outboxStore.load()
      outboxLoadFailure = nil
      adoptLegacyOutboxStamps()
    } catch {
      outboxLoadFailure = error.localizedDescription
      Self.logger.error("Outbox unreadable: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Commands are matched to a row by connection and id, so a create moved
  /// from the old queue under this connection's older stamp is restamped
  /// with the current one before anything is folded into it or sent.
  private func adoptLegacyOutboxStamps() {
    let current = settings.connectionFingerprint
    guard outbox.contains(where: {
      $0.connectionFingerprint != current && settings.matchesCurrentOrLegacyOutboxStamp($0.connectionFingerprint)
    }) else {
      return
    }
    let next = outbox.map { command -> OutboxCommand in
      guard command.connectionFingerprint != current,
            settings.matchesCurrentOrLegacyOutboxStamp(command.connectionFingerprint) else {
        return command
      }
      return OutboxCommand(
        id: command.id, seq: command.seq, transactionID: command.transactionID,
        connectionFingerprint: current, createdAt: command.createdAt, kind: command.kind,
        state: command.state, baseSnapshot: command.baseSnapshot, attempted: command.attempted,
        sentWithClientID: command.sentWithClientID
      )
    }
    // Only the stamp changes, and a later write carries it; the old stamp
    // still matches this connection if this write fails.
    outbox = next
    try? outboxStore.save(next)
  }

  /// Folds `commands` into the outbox and writes it, before anything is
  /// shown. Throws, leaving the outbox as it was, when the write fails.
  private func enqueueOutbox(_ commands: [OutboxCommand]) throws {
    guard !commands.isEmpty else {
      return
    }
    if outboxLoadFailure != nil {
      loadOutbox()
      if let failure = outboxLoadFailure {
        throw OutboxStoreError.unreadable(failure)
      }
    }
    adoptLegacyOutboxStamps()
    // The planner ignores a change to a row that is on its way out. Say so
    // rather than show "Saved" for something that will never be sent.
    let deleting = Set(currentOutbox.filter { command in
      if case .delete = command.kind { return true }
      return false
    }.map(\.transactionID))
    if commands.contains(where: { deleting.contains($0.transactionID) }) {
      throw OutboxEnqueueRefusal.rowIsBeingDeleted
    }
    let next = commands.reduce(outbox) { OutboxPlanner.enqueue($1, onto: $0) }
    try outboxStore.save(next)
    outbox = next
    scheduleOutboxDrain()
  }

  /// A note for the outbox card when the file could not be read, or part of
  /// it had to be set aside.
  var outboxNotice: String? {
    if outboxLoadFailure != nil {
      return "Unsent changes couldn’t be read yet. They are kept on this iPhone, and new changes can’t be saved until they can be read."
    }
    if outboxStore.quarantinedOnLastLoad {
      return "Some unsent changes couldn’t be read; a copy was kept on this iPhone."
    }
    return nil
  }

  /// Replay's own bookkeeping. A failed write here is not fatal: every
  /// command is safe to send again, so the worst case is a repeat after a
  /// relaunch.
  private func storeOutbox(_ next: [OutboxCommand]) {
    outbox = next
    do {
      try outboxStore.save(next)
    } catch {
      Self.logger.error("Outbox write failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func updateOutbox(_ transform: (inout [OutboxCommand]) -> Void) {
    var next = outbox
    transform(&next)
    storeOutbox(next)
  }

  private func setState(_ state: OutboxCommand.State, for ids: Set<UUID>) {
    updateOutbox { queue in
      for index in queue.indices where ids.contains(queue[index].id) {
        queue[index].state = state
      }
    }
  }

  // MARK: - Outbox: replay

  @ObservationIgnored private var drainScheduleToken = 0
  @ObservationIgnored private var isDrainScheduled = false

  /// Starts a pass once `outboxDebounce` has passed without another change.
  func scheduleOutboxDrain() {
    drainScheduleToken &+= 1
    let token = drainScheduleToken
    // The on-device engine is never offline, so local mode sends at once.
    let delay = settings.isLocal ? .zero : outboxDebounce
    isDrainScheduled = true
    Task { [weak self] in
      if delay > .zero {
        try? await Task.sleep(for: delay)
      }
      guard let self, token == self.drainScheduleToken else {
        return
      }
      self.isDrainScheduled = false
      await self.drainOutbox(trigger: .commit)
    }
  }

  /// Returns once no pass is scheduled or running.
  func waitForOutboxDrain() async {
    while isDrainScheduled || isSyncingOutbox {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  private enum WireResult {
    /// The server has what the command asked for; the row when it sent one.
    case done(Transaction?)
    /// A delete found the row already gone.
    case gone
    /// A status change found the row changed underneath; the row as it is.
    case conflict(Transaction?)
    /// The request provably never reached the server.
    case notSent
    /// Refused for a reason the planner's status mapping would misread.
    case refused(message: String, code: Int)
    case failed(OutboxPlanner.ServerResult)

    /// True when the answer shows the server did not apply the command, so
    /// it is no more "attempted" than it was before this send.
    var provesNotApplied: Bool {
      switch self {
      case .notSent, .refused, .conflict:
        return true
      case .failed(.status(let code, _)):
        return (400 ..< 500).contains(code) && code != 408
      case .done, .gone, .failed:
        return false
      }
    }
  }

  static let deletedElsewhereCode = 410
  private static let deletedElsewhereMessage =
    "This may have been deleted on another device. Retry to add it again, or Discard it."


  private enum StepResult {
    case progressed
    case rejected
    case stop
  }

  private struct DrainTally {
    var sent = 0
    var rejected = 0
    var created = 0
    var createdTransfer = false
    var createdNewPayee = false
    var edited = false
    var editedMovedAccount = false
    var editedTransfer = false
    var editedNewPayee = false
    var cleared = false
    var deleted = false
    var approved = false
  }

  /// Sends what the outbox holds for this connection, in the planner's order,
  /// until it is empty or the server cannot be reached. Returns how many
  /// commands the server acknowledged.
  @discardableResult
  func drainOutbox(trigger: OutboxDrainTrigger) async -> Int {
    // This pass covers whatever a scheduled one was waiting to send.
    drainScheduleToken &+= 1
    isDrainScheduled = false
    if trigger == .manual, outboxLoadFailure == nil {
      // "Sync Now" asks for everything, refused changes included.
      let refused = Set(currentOutbox.filter { command in
        if case .rejected = command.state { return true }
        return false
      }.map(\.id))
      if !refused.isEmpty {
        setState(.queued, for: refused)
      }
    }
    guard settings.isAuthenticated,
          outboxLoadFailure == nil,
          currentOutbox.contains(where: { $0.state == .queued }) else {
      return 0
    }
    if isSyncingOutbox {
      needsAnotherDrain = true
      return 0
    }
    isSyncingOutbox = true
    defer { isSyncingOutbox = false }
    adoptLegacyOutboxStamps()

    let fingerprint = settings.connectionFingerprint
    let planID = settings.planID
    let client = apiClient
    var tally = DrainTally()

    passes: while true {
      needsAnotherDrain = false
      guard settings.connectionFingerprint == fingerprint else {
        break
      }
      let plan = OutboxPlanner.plan(currentOutbox)
      guard !plan.batches.isEmpty else {
        break
      }
      var progressed = false
      for batch in plan.batches {
        if batch.stage == .approve {
          var start = 0
          while start < batch.commands.count {
            let chunk = Array(batch.commands[start ..< min(start + RegisterApproval.batchLimit, batch.commands.count)])
            start += RegisterApproval.batchLimit
            switch await sendApprovals(chunk, client: client, planID: planID, fingerprint: fingerprint, tally: &tally) {
            case .stop:
              break passes
            case .progressed:
              progressed = true
            case .rejected:
              break
            }
          }
          continue
        }
        for planned in batch.commands {
          guard settings.connectionFingerprint == fingerprint else {
            break passes
          }
          // Folded, discarded or retried while earlier commands were out.
          guard let command = outbox.first(where: { $0.id == planned.id }),
                command.state == .queued,
                OutboxPlanner.stage(of: command.kind) == batch.stage else {
            needsAnotherDrain = true
            continue
          }
          guard markSending([command], resolvingLegacyCreate: command.isUnresolvedLegacyCreate) else {
            break passes
          }
          let result = await send(command, client: client, planID: planID)
          if result.provesNotApplied {
            restoreAttempt(of: [command])
          }
          guard settings.connectionFingerprint == fingerprint else {
            break passes
          }
          switch settle(command, result: result, tally: &tally) {
          case .stop:
            break passes
          case .progressed:
            progressed = true
          case .rejected:
            break
          }
        }
      }
      if !(progressed || needsAnotherDrain) {
        break
      }
    }

    // A pass cut short leaves its command marked as on the wire. It was
    // either sent or not; either way it is safe to send again.
    let stranded = Set(outbox.filter(\.isInFlight).map(\.id))
    if !stranded.isEmpty {
      setState(.queued, for: stranded)
    }
    finishDrain(tally, trigger: trigger)
    return tally.sent
  }

  /// Marks commands as on the wire and as attempted, on disk, before any
  /// byte is sent: from here on the server may hold them. Returns false,
  /// changing nothing, when that write fails; the caller must not send.
  /// Otherwise a create the server committed could look unsent after a
  /// crash, take later edits folded into it, and lose them to the import-id
  /// dedupe on replay.
  private func markSending(_ commands: [OutboxCommand], resolvingLegacyCreate: Bool = false) -> Bool {
    let ids = Set(commands.map(\.id))
    var next = outbox
    for index in next.indices where ids.contains(next[index].id) {
      next[index].state = .inFlight
      next[index].attempted = true
      // A legacy lookup is only a read. A crash or timeout during it must
      // leave recovery looking for the old server id, not our new client id.
      if next[index].kind.isCreate && !resolvingLegacyCreate {
        next[index].sentWithClientID = true
      }
    }
    do {
      try outboxStore.save(next)
    } catch {
      Self.logger.error("Outbox write failed; not sending: \(error.localizedDescription, privacy: .public)")
      return false
    }
    outbox = next
    return true
  }

  /// Puts back the attempt flags a send set, once its answer proves the
  /// server did not apply it.
  private func restoreAttempt(of commands: [OutboxCommand]) {
    let before = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
    updateOutbox { queue in
      for index in queue.indices {
        guard let original = before[queue[index].id] else { continue }
        queue[index].attempted = original.attempted
        queue[index].sentWithClientID = original.sentWithClientID
      }
    }
  }

  /// True for the server's answer to a transaction it does not have, and
  /// only that: a plan the session can no longer see is also a 404.
  private static func isTransactionNotFound(_ reply: OutboxReply) -> Bool {
    reply.status == 404 && reply.message == "Transaction not found"
  }

  private func send(_ command: OutboxCommand, client: APIClient, planID: String) async -> WireResult {
    do {
      switch command.kind {
      case .create(let request):
        if command.isUnresolvedLegacyCreate {
          // From the old queue: it may be on the server under an id we never
          // learned, and may since have been deleted there. Send it only
          // once no row, live or deleted, carries its import id.
          guard let importID = request.importID else {
            return .refused(message: Self.deletedElsewhereMessage, code: Self.deletedElsewhereCode)
          }
          switch try await client.outboxRows(importID: importID, planID: planID) {
          case .unknown:
            // Nothing was sent; try again on a later pass.
            return .notSent
          case .rows(let rows) where !rows.isEmpty:
            if let live = rows.first(where: { !$0.deleted && $0.accountID == request.accountID })
              ?? rows.first(where: { !$0.deleted }) {
              return .done(live)
            }
            return .refused(message: Self.deletedElsewhereMessage, code: Self.deletedElsewhereCode)
          case .rows:
            // Only now can a POST with our id occur. Recheck ownership after
            // the awaited lookup and make that attempt durable before sending.
            guard settings.connectionFingerprint == command.connectionFingerprint,
                  outbox.contains(where: { $0.id == command.id && $0.isInFlight }),
                  markSending([command]) else {
              return .notSent
            }
          }
        } else if command.attempted, command.sentWithClientID {
          // It may be on the server already. A replay would be answered by
          // the import-id check, which ignores deleted rows, so look it up
          // by id first rather than risk bringing back a deleted row.
          let lookup = try await client.outboxFetch(planID: planID, transactionID: command.transactionID)
          if lookup.isSuccess, let row = client.outboxTransaction(in: lookup), !row.deleted {
            return .done(row)
          }
          if lookup.isSuccess || Self.isTransactionNotFound(lookup) {
            return .refused(message: Self.deletedElsewhereMessage, code: Self.deletedElsewhereCode)
          }
          return .failed(.status(lookup.status, message: lookup.message))
        }
        var body = request
        body.id = command.transactionID
        let reply = try await client.outboxCreate(planID: planID, request: body)
        if reply.isSuccess {
          return .done(client.outboxTransaction(in: reply))
        }
        // A replay can meet its own earlier success in a form the import-id
        // check does not catch. If the row is there, the create landed.
        if reply.status == 409 || reply.status >= 500,
           let row = try await fetchLive(command.transactionID, client: client, planID: planID) {
          return .done(row)
        }
        return .failed(.status(reply.status, message: reply.message))

      case .update(let request):
        var body = request
        body.id = nil
        body.importID = nil
        let reply = try await client.outboxUpdate(planID: planID, transactionID: command.transactionID, request: body)
        return reply.isSuccess
          ? .done(client.outboxTransaction(in: reply))
          : .failed(.status(reply.status, message: reply.message))

      case .cleared(let expected, let cleared, _):
        let reply = try await client.outboxCleared(
          planID: planID,
          transactionID: command.transactionID,
          expectedCleared: expected,
          cleared: cleared
        )
        if reply.isSuccess {
          return .done(client.outboxTransaction(in: reply))
        }
        if reply.status == 409 {
          // A replay of a toggle that landed, or a change made elsewhere.
          let row = try await fetchLive(command.transactionID, client: client, planID: planID)
          if let row, row.cleared == cleared {
            return .done(row)
          }
          return .conflict(row)
        }
        return .failed(.status(reply.status, message: reply.message))

      case .delete(let expectedApproved):
        let reply = try await client.outboxDelete(
          planID: planID,
          transactionID: command.transactionID,
          expectedApproved: expectedApproved
        )
        if reply.isSuccess {
          return .done(client.outboxTransaction(in: reply))
        }
        if Self.isTransactionNotFound(reply) {
          return .gone
        }
        if reply.status == 404 {
          // Not this row: the plan is gone or out of reach. Not a success.
          return .refused(message: reply.message, code: 404)
        }
        // Older servers answer a replayed delete of a removed row with a 500.
        if reply.status >= 500, try await fetchLive(command.transactionID, client: client, planID: planID) == nil {
          return .gone
        }
        return .failed(.status(reply.status, message: reply.message))

      case .approve:
        // Sent in batches by `sendApprovals`.
        return .failed(.offline)
      }
    } catch {
      return error.isOfflineError ? .notSent : .failed(.offline)
    }
  }

  /// The row as the server has it now, or nil when it has none (404 or a
  /// tombstone). Throws when the server cannot be reached or gives no answer.
  private func fetchLive(_ transactionID: String, client: APIClient, planID: String) async throws -> Transaction? {
    let reply = try await client.outboxFetch(planID: planID, transactionID: transactionID)
    if Self.isTransactionNotFound(reply) {
      return nil
    }
    guard reply.isSuccess, let row = client.outboxTransaction(in: reply) else {
      throw APIClientError.httpStatus(reply.status)
    }
    return row.deleted ? nil : row
  }

  private func settle(_ command: OutboxCommand, result: WireResult, tally: inout DrainTally) -> StepResult {
    switch result {
    case .done(let row):
      acknowledge(command, row: row, tally: &tally)
      return .progressed
    case .gone:
      acknowledgeDelete(command, deleted: nil, tally: &tally)
      return .progressed
    case .conflict(let row):
      if let row, let existing = serverRow(row.id) {
        applySavedTransaction(row, replacing: existing)
      }
      reject(
        [command],
        message: "This transaction changed on another device. Discard to keep that version, or Retry.",
        code: 409,
        tally: &tally
      )
      return .rejected
    case .notSent:
      setState(.queued, for: [command.id])
      return .stop
    case .refused(let message, let code):
      reject([command], message: message, code: code, tally: &tally)
      return .rejected
    case .failed(let serverResult):
      switch OutboxPlanner.action(for: command.kind, result: serverResult) {
      case .complete:
        acknowledgeDelete(command, deleted: nil, tally: &tally)
        return .progressed
      case .continueAs, .refetchAndCompare:
        // Mapped to `.done` and `.conflict` in `send`; never reached.
        setState(.queued, for: [command.id])
        return .stop
      case .retryLater:
        setState(.queued, for: [command.id])
        return .stop
      case .reject(let message, let code):
        reject([command], message: message, code: code, tally: &tally)
        return .rejected
      }
    }
  }

  private func reject(_ commands: [OutboxCommand], message: String, code: Int?, tally: inout DrainTally) {
    let ids = Set(commands.map(\.id))
    setState(.rejected(message: message, code: code), for: ids)
    tally.rejected += commands.count
  }

  /// The server has the command. Its balance effect is frozen until an
  /// accounts read catches up, its row replaces ours, and the command leaves
  /// the outbox (or, for a status change carrying an approval, becomes that
  /// approval).
  private func acknowledge(_ command: OutboxCommand, row: Transaction?, tally: inout DrainTally) {
    if case .delete = command.kind {
      acknowledgeDelete(command, deleted: row, tally: &tally)
      return
    }
    tally.sent += 1
    freezeBalanceEffect(of: command)
    let existing = serverRow(command.transactionID)
    let next = OutboxPlanner.action(for: command.kind, result: .succeeded)
    updateOutbox { queue in
      guard let index = queue.firstIndex(where: { $0.id == command.id }) else {
        return
      }
      if case .continueAs(let kind) = next {
        queue[index].kind = kind
        queue[index].state = .queued
      } else {
        queue.remove(at: index)
      }
      // A replayed create can come back as a row the server made earlier
      // under another id. Later changes follow the row the server has.
      if let row, row.id != command.transactionID {
        for other in queue.indices where queue[other].rowKey == command.rowKey {
          queue[other].transactionID = row.id
          if queue[other].baseSnapshot == nil {
            queue[other].baseSnapshot = row
          }
        }
      }
    }
    guard let row else {
      // Acknowledged without a readable row: read back what the response
      // could not tell us.
      switch command.kind {
      case .create:
        tally.created += 1
        tally.createdTransfer = true
      case .update:
        tally.edited = true
        tally.editedMovedAccount = true
      case .cleared:
        tally.cleared = true
      case .approve, .delete:
        break
      }
      return
    }
    switch command.kind {
    case .create:
      tally.created += 1
      tally.createdTransfer = tally.createdTransfer || isTransfer(row)
      tally.createdNewPayee = tally.createdNewPayee || isUnknownPayee(row)
      serverTransactions = sortedUniqueTransactions([row] + serverTransactions.filter { $0.id != row.id })
      if !row.approved {
        serverUnapprovedTransactions = sortedUniqueTransactions([row] + serverUnapprovedTransactions)
      }
      recordLedgerWrite(row, isCreate: true)
    case .update:
      tally.edited = true
      tally.editedMovedAccount = tally.editedMovedAccount || existing.map { $0.accountID != row.accountID } ?? true
      tally.editedTransfer = tally.editedTransfer || isTransfer(row) || (existing.map(isTransfer) ?? false)
      tally.editedNewPayee = tally.editedNewPayee || isUnknownPayee(row)
      applyAcknowledgedRow(row, replacing: existing)
    case .cleared:
      tally.cleared = true
      applyAcknowledgedRow(row, replacing: existing)
    case .approve, .delete:
      break
    }
  }

  private func applyAcknowledgedRow(_ row: Transaction, replacing existing: Transaction?) {
    let saved = existing.map { row.preservingParent(from: $0) } ?? row
    if let existing {
      applySavedTransaction(saved, replacing: existing)
    }
    recordLedgerWrite(saved, isCreate: false)
  }

  private func acknowledgeDelete(_ command: OutboxCommand, deleted: Transaction?, tally: inout DrainTally) {
    tally.sent += 1
    tally.deleted = true
    // The row is gone from the server. Anything else still held for it --
    // a refused create or edit included -- must not be sent again, or Sync
    // Now could bring the row back.
    updateOutbox { queue in
      queue.removeAll { $0.id == command.id || ($0.rowKey == command.rowKey && !$0.isInFlight) }
    }
    let fallback = serverRow(command.transactionID) ?? command.baseSnapshot ?? deleted
    guard let fallback else {
      return
    }
    applyDeletedTransaction(deleted ?? fallback, fallback: fallback)
  }

  /// Keeps an acknowledged command's effect on the balances until an
  /// accounts read that started after now has landed.
  private func freezeBalanceEffect(of command: OutboxCommand) {
    let deltas = OutboxPlanner.balanceDeltas(
      [command],
      rowsByID: rowsForBalanceDeltas([command]),
      transferAccountIDsByPayeeID: transferAccountIDsByPayeeID
    )
    retainAcknowledged(deltas)
  }

  private func retainAcknowledged(_ deltas: [String: DeleteBalanceDelta.Delta]) {
    guard !deltas.isEmpty else {
      return
    }
    acknowledgedBalanceDeltas.append(AcknowledgedDelta(sequence: accountsReadSequence, deltas: deltas))
  }

  /// Called when an accounts read starts. Returns its sequence number.
  private func beginAccountsRead() -> Int {
    accountsReadSequence &+= 1
    return accountsReadSequence
  }

  /// Called when an accounts read that started at `sequence` lands: every
  /// acknowledgement it can reflect is now in the server's balances.
  private func finishAccountsRead(_ sequence: Int) {
    if acknowledgedBalanceDeltas.contains(where: { $0.sequence < sequence }) {
      acknowledgedBalanceDeltas.removeAll { $0.sequence < sequence }
    }
  }

  private func sendApprovals(
    _ chunk: [OutboxCommand],
    client: APIClient,
    planID: String,
    fingerprint: String,
    tally: inout DrainTally
  ) async -> StepResult {
    let commands = chunk.compactMap { planned in
      outbox.first { $0.id == planned.id && $0.state == .queued && $0.kind == .approve }
    }
    guard !commands.isEmpty else {
      return .rejected
    }
    let ids = commands.map(\.transactionID)
    guard markSending(commands) else {
      return .stop
    }
    let reply: OutboxReply
    do {
      reply = try await client.outboxApprove(planID: planID, transactionIDs: ids)
    } catch {
      if error.isOfflineError {
        restoreAttempt(of: commands)
      }
      setState(.queued, for: Set(commands.map(\.id)))
      return .stop
    }
    if !reply.isSuccess, (400 ..< 500).contains(reply.status), reply.status != 408 {
      restoreAttempt(of: commands)
    }
    guard settings.connectionFingerprint == fingerprint else {
      return .stop
    }
    if reply.isSuccess {
      let returned = client.outboxTransactions(in: reply) ?? []
      let graphIDs = (try? await approvedGraphIDs(
        from: returned,
        submitted: Set(ids),
        client: client,
        planID: planID
      )) ?? Set(ids)
      guard settings.connectionFingerprint == fingerprint else {
        return .stop
      }
      // Rows the server had unapproved, whether or not they are loaded: the
      // badge keeps subtracting them until its next count.
      let knownUnapproved = locallyUnapprovedIDs(in: graphIDs)
        .union(commands.filter { $0.baseSnapshot?.approved == false }.map(\.transactionID))
      applyApprovedIDs(graphIDs)
      approvalSession.confirmed.formUnion(knownUnapproved)
      let done = Set(commands.map(\.id))
      updateOutbox { queue in
        queue.removeAll { done.contains($0.id) }
      }
      tally.sent += commands.count
      tally.approved = true
      return .progressed
    }
    let action = OutboxPlanner.action(for: .approve, result: .status(reply.status, message: reply.message))
    if case .reject = action, commands.count > 1 {
      // A refusal does not say which row it was about. Send each on its own
      // so one bad row does not hold the rest back.
      setState(.queued, for: Set(commands.map(\.id)))
      var result = StepResult.rejected
      for command in commands {
        switch await sendApprovals([command], client: client, planID: planID, fingerprint: fingerprint, tally: &tally) {
        case .stop:
          return .stop
        case .progressed:
          result = .progressed
        case .rejected:
          break
        }
      }
      return result
    }
    switch action {
    case .reject(let message, let code):
      reject(commands, message: message, code: code, tally: &tally)
      return .rejected
    default:
      setState(.queued, for: Set(commands.map(\.id)))
      return .stop
    }
  }

  private func finishDrain(_ tally: DrainTally, trigger: OutboxDrainTrigger) {
    if tally.created > 0 || tally.deleted {
      invalidateAccountUsage()
    }
    if tally.created > 0 {
      scheduleRefresh(after: .transactionsCreated(hasTransfer: tally.createdTransfer, hasNewPayee: tally.createdNewPayee))
    }
    if tally.edited {
      scheduleRefresh(
        after: .transactionEdited(
          changesAccount: tally.editedMovedAccount,
          touchesTransfer: tally.editedTransfer,
          hasNewPayee: tally.editedNewPayee
        )
      )
    }
    if tally.cleared {
      scheduleRefresh(after: .clearedToggled)
    }
    if tally.deleted {
      scheduleRefresh(after: .transactionDeleted)
    }
    if tally.approved {
      scheduleRefresh(after: .transactionsApproved)
    }
    if tally.rejected > 0 {
      showSaveMessage(
        tally.rejected == 1
          ? "The server refused 1 change. See Accounts to retry or discard it."
          : "The server refused \(tally.rejected) changes. See Accounts to retry or discard them.",
        kind: .failure
      )
    } else if tally.sent > 0, trigger != .commit {
      showSaveMessage(tally.sent == 1 ? "Synced 1 pending change" : "Synced \(tally.sent) pending changes")
    } else if tally.sent == 0, trigger == .manual, !currentOutbox.isEmpty {
      showSaveMessage("Couldn’t sync — will retry on the next refresh", kind: .failure)
    }
  }

  /// True when the row is, or has become, one half of a transfer pair. The
  /// mirror row lives on another account and no single-transaction response
  /// returns it, so these writes need the ledger slice.
  private func isTransfer(_ transaction: Transaction) -> Bool {
    if transaction.transferAccountID != nil || transaction.transferTransactionID != nil {
      return true
    }
    return transaction.subtransactions.contains {
      $0.transferAccountID != nil || $0.transferTransactionID != nil
    }
  }

  /// True when the saved row names a payee the local list has never seen,
  /// which means the server provisioned it during this write.
  private func isUnknownPayee(_ transaction: Transaction) -> Bool {
    guard let payeeID = transaction.payeeID else {
      return false
    }
    return payee(withID: payeeID) == nil
  }

  private func applySavedTransaction(_ saved: Transaction, replacing existing: Transaction) {
    let next = saved.preservingParent(from: existing)
    if let index = serverTransactions.firstIndex(where: { $0.id == existing.id }) {
      serverTransactions[index] = next
    }
    if next.approved {
      serverUnapprovedTransactions.removeAll { $0.id == existing.id }
    } else if let index = serverUnapprovedTransactions.firstIndex(where: { $0.id == existing.id }) {
      serverUnapprovedTransactions[index] = next
    }
  }

  private func replaceUnapprovedQueue(with fetched: [Transaction]) {
    let live = fetched.filter { !$0.approved && !$0.deleted }
    let stillUnapproved = Set(live.map(\.id))
    var session = approvalSession
    session.confirmed.formIntersection(stillUnapproved)
    approvalSession = session
    serverUnapprovedTransactions = sortedUniqueTransactions(
      live.filter { !approvalSession.confirmed.contains($0.id) }
    )
  }

  private func applyApprovedIDs(_ ids: Set<String>) {
    guard !ids.isEmpty else {
      return
    }
    serverUnapprovedTransactions.removeAll { ids.contains($0.id) }
    serverTransactions = serverTransactions.map { ids.contains($0.id) ? $0.withApproved(true) : $0 }
    if let page = lastLedgerFirstPage {
      lastLedgerFirstPage = ReferenceSnapshot.LedgerPage(
        transactions: page.transactions.map { ids.contains($0.id) ? $0.withApproved(true) : $0 },
        hasMore: page.hasMore,
        nextOffset: page.nextOffset
      )
    }
  }

  /// The batch endpoint returns the requested rows, not every row its split
  /// approval cascaded to. Resolve each returned row to its split parent so
  /// loaded mirrors disappear immediately. A mirror can be visible while its
  /// (older) parent is not, so fetch that parent rather than assuming a first
  /// page reload would find it.
  private func approvedGraphIDs(
    from returned: [Transaction],
    submitted: Set<String>,
    client: APIClient,
    planID: String
  ) async throws -> Set<String> {
    var graphIDs = Set(returned.map(\.id)).union(submitted)
    for row in returned {
      let parentID = row.parentTransactionID ?? row.id
      let parent: Transaction
      if let loaded = returned.first(where: { $0.id == parentID })
        ?? serverTransactions.first(where: { $0.id == parentID })
        ?? serverUnapprovedTransactions.first(where: { $0.id == parentID }) {
        parent = loaded
      } else {
        parent = try await client.fetchTransaction(planID: planID, transactionID: parentID)
      }
      graphIDs.insert(parent.id)
      graphIDs.formUnion(parent.linkedTransferIDs)
    }
    return graphIDs
  }

  /// Only rows observed unapproved before the write belong in badge and queue
  /// bookkeeping. A graph may contain an already-approved transfer companion;
  /// treating every graph id as new would decrement the badge twice.
  private func locallyUnapprovedIDs(in ids: Set<String>) -> Set<String> {
    Set((serverTransactions + serverUnapprovedTransactions).lazy.filter {
      ids.contains($0.id) && !$0.approved && !$0.deleted
    }.map(\.id))
  }

  private func eligibleApprovalCount(in rows: [Transaction]) -> Int {
    RegisterApproval.eligibleIDs(in: rows.map(\.approvalRow), session: approvalSession).count
  }

  private enum ApprovalSuccessCopy {
    case bulk
    case single(Transaction)
  }

  private static func successToast(_ success: ApprovalSuccessCopy, plannedCount: Int) -> String {
    switch success {
    case .bulk:
      return RegisterApproval.approvedToast(plannedCount)
    case .single(let row):
      return "Approved \(row.payeeName ?? "transaction")"
    }
  }

  /// Applies a delete from the row the server returned, falling back to the row
  /// in hand for the link metadata an older response may omit. The server
  /// tombstones the target -- and, for a whole transfer, its other side -- but
  /// leaves a split parent in place and only clears the matching line's transfer
  /// link (web: `unlinkSplitMirrorParent`), so the parent must survive here too.
  private func applyDeletedTransaction(_ deleted: Transaction, fallback: Transaction) {
    let mirror = SplitMirrorLink(
      id: deleted.id,
      parentTransactionID: deleted.parentTransactionID ?? fallback.parentTransactionID,
      transferTransactionID: deleted.transferTransactionID ?? fallback.transferTransactionID
    )
    var removedIDs: Set<String> = [mirror.id, fallback.id]
    if mirror.parentTransactionID == nil {
      // A split mirror's own transfer id names the parent's subtransaction, not
      // a transaction, and the server removes only the mirror row: the parent
      // and its other lines stay. Every other delete cascades to the ids the
      // response names -- a transfer's other half, or a parent's mirrored lines.
      let links = Set(deleted.linkedTransferIDs)
      removedIDs.formUnion(links.isEmpty ? Set(fallback.linkedTransferIDs) : links)
    }
    // Rejecting a row awaiting approval takes it off the "New" badge, the same
    // as approving it would. Recorded before the arrays are cleared, and also
    // from the row in hand -- with the queue lazy it is usually not in them.
    for row in serverUnapprovedTransactions where removedIDs.contains(row.id) {
      rejectedUnapprovedAccounts[row.id] = row.accountID
    }
    if !fallback.approved {
      rejectedUnapprovedAccounts[fallback.id] = fallback.accountID
    }
    // The removed rows come off their accounts from the rows as they stood
    // before the delete. The effect is held with the other acknowledged
    // writes until an accounts read that started after it lands, so the
    // balances on screen and in the snapshot below are right even when that
    // read fails -- and a read already in flight cannot put them back.
    var knownRows: [String: Transaction] = [:]
    for row in serverUnapprovedTransactions + serverTransactions where removedIDs.contains(row.id) {
      knownRows[row.id] = row
    }
    retainAcknowledged(DeleteBalanceDelta.deltas(deleted: fallback, removedIDs: removedIDs, knownRows: knownRows))
    serverTransactions = SplitMirrorUnlink.applying(
      mirror,
      to: serverTransactions.filter { !removedIDs.contains($0.id) }
    )
    serverUnapprovedTransactions = SplitMirrorUnlink.applying(
      mirror,
      to: serverUnapprovedTransactions.filter { !removedIDs.contains($0.id) }
    )
    // The snapshot is written from the first page as the network returned it, so
    // it has to lose the mirror too: the next accounts refresh persists it, and
    // a cold launch would otherwise restore a row this delete removed.
    if let page = lastLedgerFirstPage {
      lastLedgerFirstPage = ReferenceSnapshot.LedgerPage(
        transactions: SplitMirrorUnlink.applying(
          mirror,
          to: page.transactions.filter { !removedIDs.contains($0.id) }
        ),
        hasMore: page.hasMore,
        nextOffset: page.nextOffset
      )
    }
    provisionalLedgerRowIDs.removeAll { removedIDs.contains($0) }
    recordLedgerDelete(removedIDs: removedIDs, mirror: mirror)
    // Persist the repaired page now rather than waiting on the follow-up
    // refresh, which can fail: the next launch then starts warm, without the
    // deleted row. The write queues behind any pre-delete one, so it lands
    // last. Provisional data cannot be persisted, so while the launch refresh
    // is still out the old file is deleted instead -- a queued pre-delete
    // write included -- and a later successful refresh persists the repair.
    if !persistSnapshot() {
      snapshotStore.delete()
    }
  }

  // MARK: - Read-order ownership for acknowledged writes

  /// One HTTP page of the ledger, with the read-order fence captured for that
  /// request alone and applied before the page leaves this function. A page
  /// asked for after a write landed is therefore handed over untouched even
  /// when it belongs to a walk that started before it -- the later page of a
  /// horizon fill, or of a register's older-page load. A page asked for before
  /// it is repaired against what the write changed.
  private func fetchLedgerPage(
    planID: String,
    accountID: String? = nil,
    offset: Int = 0,
    sinceDate: String? = nil
  ) async throws -> TransactionPage {
    let generation = beginLedgerRead()
    defer { endLedgerRead(generation) }
    let page = try await apiClient.fetchTransactions(
      planID: planID,
      accountID: accountID,
      offset: offset,
      sinceDate: sinceDate
    )
    return TransactionPage(
      transactions: repairingStaleRead(
        page.transactions,
        startedAt: generation,
        addingCreates: offset == 0 ? { row in
          (accountID == nil || row.accountID == accountID) && (sinceDate.map { row.date >= $0 } ?? true)
        } : nil
      ),
      hasMore: page.hasMore,
      nextOffset: page.nextOffset,
      serverKnowledge: page.serverKnowledge
    )
  }

  /// Registers one request as a read. Every call must be paired with
  /// `endLedgerRead` once its rows have been repaired.
  private func beginLedgerRead() -> Int {
    let generation = ledgerReadGeneration
    inFlightLedgerReads[generation, default: 0] += 1
    return generation
  }

  private func endLedgerRead(_ generation: Int) {
    if let count = inFlightLedgerReads[generation], count > 1 {
      inFlightLedgerReads[generation] = count - 1
    } else {
      inFlightLedgerReads[generation] = nil
    }
    pruneLedgerDeletes()
  }

  /// Drops records no in-flight request can still need. A request needs the
  /// record of every write newer than the generation it captured when it was
  /// issued.
  private func pruneLedgerDeletes() {
    guard let oldestInFlight = inFlightLedgerReads.keys.min() else {
      ledgerDeletes.removeAll()
      ledgerWrites.removeAll()
      return
    }
    ledgerDeletes.removeAll { oldestInFlight >= $0.generation }
    ledgerWrites.removeAll { oldestInFlight >= $0.generation }
  }

  /// Records a delete for the requests that were issued before it, then advances
  /// the read-order boundary so every later request applies untouched.
  private func recordLedgerDelete(removedIDs: Set<String>, mirror: SplitMirrorLink) {
    ledgerReadGeneration &+= 1
    ledgerDeletes.append(
      LedgerDelete(generation: ledgerReadGeneration, removedIDs: removedIDs, mirror: mirror)
    )
    pruneLedgerDeletes()
  }

  /// The same for an acknowledged create, edit or status change: a read
  /// issued before it cannot put the old row back on screen.
  private func recordLedgerWrite(_ row: Transaction, isCreate: Bool) {
    if let page = lastLedgerFirstPage {
      var rows = page.transactions
      if let index = rows.firstIndex(where: { $0.id == row.id }) {
        rows[index] = row
      } else if isCreate {
        rows = sortedUniqueTransactions([row] + rows)
      }
      lastLedgerFirstPage = ReferenceSnapshot.LedgerPage(
        transactions: rows,
        hasMore: page.hasMore,
        nextOffset: page.nextOffset
      )
    }
    guard !inFlightLedgerReads.isEmpty else {
      return
    }
    ledgerReadGeneration &+= 1
    ledgerWrites.append(LedgerWrite(generation: ledgerReadGeneration, row: row, isCreate: isCreate))
  }

  /// Repairs rows a request issued before a write could know about: the rows
  /// a delete tombstoned are dropped, any surviving parent row forgets the
  /// link the server cleared, an edited row is replaced by the saved one, and
  /// a first page gains the rows created since. A request issued at the
  /// current generation needs no repair.
  private func repairingStaleRead(
    _ rows: [Transaction],
    startedAt generation: Int,
    addingCreates includes: ((Transaction) -> Bool)? = nil
  ) -> [Transaction] {
    let staleDeletes = ledgerDeletes.filter { $0.generation > generation }
    let staleWrites = ledgerWrites.filter { $0.generation > generation }
    guard !staleDeletes.isEmpty || !staleWrites.isEmpty else {
      return rows
    }
    var repaired = rows
    var events: [(generation: Int, apply: ([Transaction]) -> [Transaction])] = []
    for delete in staleDeletes {
      events.append((delete.generation, { rows in
        SplitMirrorUnlink.applying(delete.mirror, to: rows.filter { !delete.removedIDs.contains($0.id) })
      }))
    }
    for write in staleWrites {
      events.append((write.generation, { rows in
        if let index = rows.firstIndex(where: { $0.id == write.row.id }) {
          var next = rows
          next[index] = write.row
          return next
        }
        if write.isCreate, includes?(write.row) == true {
          return rows + [write.row]
        }
        return rows
      }))
    }
    for event in events.sorted(by: { $0.generation < $1.generation }) {
      repaired = event.apply(repaired)
    }
    return repaired
  }

  private func showSaveMessage(_ text: String, kind: SaveMessage.Kind = .success) {
    saveMessageToken += 1
    lastSaveMessage = SaveMessage(id: saveMessageToken, text: text, kind: kind)
    let token = saveMessageToken
    Task {
      try? await Task.sleep(for: .seconds(3))
      if token == saveMessageToken {
        lastSaveMessage = nil
      }
    }
  }
}
