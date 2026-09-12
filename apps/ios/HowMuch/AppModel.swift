import Foundation
import Observation

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

@MainActor
@Observable
final class AppModel {
  var settings: APISettings
  let captureAI: CaptureAISettings
  var planSettings: PlanSettings?
  var accounts: [Account] = []
  var categoryGroups: [CategoryGroup] = []
  var payees: [Payee] = []
  private var serverTransactions: [Transaction] = []
  private var serverUnapprovedTransactions: [Transaction] = []
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
  /// Increments after mutations that affect a plan month, so the Plan
  /// destination reloads its locally held monthly snapshot when it becomes visible.
  private(set) var planRefreshGeneration = 0
  private(set) var reportsRefreshGeneration = 0
  private(set) var rewardsRefreshGeneration = 0
  var reportsPhase: LoadPhase = .idle
  var isSubmitting = false
  var lastSaveMessage: SaveMessage?
  var isShowingSettings = false
  /// Account registers currently on a navigation stack, deepest last.
  /// Horizon fill uses this stack. Capture origin uses `visibleRegisterAccountID`.
  private(set) var focusedRegisterAccountIDs: [String] = []
  /// Which destination currently owns the visible chrome. A retained Accounts
  /// register must not leak into Rewards/Assistant or Home Screen.
  var activeCaptureSurface: CaptureSurface = .accounts
  private var focusedRegisters: [(surface: CaptureSurface, accountID: String)] = []
  private var pendingTransactions: [PendingTransaction] = OutboxStore.load()
  /// Latest conversation revision for a create that is still sending.
  /// Applied as an edit once the POST lands, or written into the outbox if it fails.
  private var pendingCreateRevisions: [String: TransactionDraft] = [:]
  /// True while a replay pass is running, whoever started it — the outbox
  /// card drives its spinner from this rather than view-local state.
  var isSyncingOutbox = false
  private var pendingEdits: [String: PendingEdit] = [:]
  private var inFlightCreates: Set<PendingRow.ID> = []
  @ObservationIgnored private var editTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var editGenerations: [String: Int] = [:]
  @ObservationIgnored private var clearedTogglesInFlight: Set<String> = []
  /// Flipped cleared values that must survive `refreshLedger` replacing
  /// `serverTransactions` with a fetch that still has the pre-PATCH row.
  private var clearedToggleOverlays: [String: ClearedState] = [:]
  @ObservationIgnored private var needsAnotherDrain = false
  @ObservationIgnored private var coalescedDrainTrigger: OutboxDrainTrigger?
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
  /// Serialises preference writes so a slower earlier request cannot overwrite
  /// a newer reorder on the server.
  @ObservationIgnored private var accountPreferencesSyncTask: Task<Void, Never>?
  @ObservationIgnored private var accountPreferenceMutationGenerations: [String: Int] = [:]
  @ObservationIgnored private var accountPreferenceSyncedGenerations: [String: Int] = [:]

  // MARK: - #176: the on-device reference snapshot

  @ObservationIgnored private let snapshotStore: SnapshotStore
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
    settings: APISettings = .load(),
    viewPrefs: ViewPrefs = .load(),
    captureAI: CaptureAISettings? = nil,
    snapshotStore: SnapshotStore = .shared
  ) {
    self.snapshotStore = snapshotStore
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
    // fall back to tabs that can only render tokenless API errors.
    self.isShowingSettings = !settings.isAuthenticated
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
    // #176: before the first frame, and off the network. A snapshot that does
    // not belong to this connection is deleted rather than shown.
    restoreSnapshot()
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
    // number with no rows behind it, and `unapprovedBadgeCount` already
    // subtracts anything approved since — which, on a launch, is nothing.
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
  /// coalesces and encodes off the main actor.
  private func persistSnapshot() {
    guard settings.isAuthenticated,
          !settings.planID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !settings.authenticatedUserID.isEmpty,
          !accounts.isEmpty,
          // Never write a mixture of this launch's data and the last one's:
          // the file is tagged with a single cursor, so every part of it must
          // have come from the network at that cursor. The slice that clears
          // the final provisional flag is the one that writes.
          !isProvisional else {
      return
    }
    snapshotStore.scheduleWrite(
      ReferenceSnapshot(
        connectionFingerprint: settings.connectionFingerprint,
        authenticatedUserID: settings.authenticatedUserID,
        planID: settings.planID,
        serverKnowledge: serverKnowledge,
        planSettings: planSettings,
        accounts: accounts,
        categoryGroups: categoryGroups,
        payees: payees,
        accountPreferences: lastSyncedAccountPreferences,
        scheduledTransactions: scheduledTransactions,
        ledgerPage: lastLedgerFirstPage,
        unapprovedCount: serverUnapprovedCount
      )
    )
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
    clearedToggleOverlays.removeAll()
    clearedTogglesInFlight.removeAll()
    scheduledTransactions = []
    spendingBreakdown = nil
    incomeVsSpending = nil
    netWorth = nil
    ageOfMoney = nil
    cancelPendingEdits()
    invalidateAccountUsage()
    rebuildLookups()
    referencePhase = .idle
    ledgerPhase = .idle
    scheduledTransactionsPhase = .idle
    reportsPhase = .idle
    ledgerPageGeneration += 1
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
    if !accounts.contains(where: { $0.id == created.id }) {
      accounts.append(created)
      rebuildLookups()
    }
    await refresh(after: .accountCreated)
    showSaveMessage("Added \(created.name)")
    return created
  }

  func updateAccount(_ identity: AccountIdentity, for accountID: String) async throws {
    let trimmed = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw APIClientError.validation("Name cannot be empty")
    }
    guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
      throw APIClientError.validation("Account not found")
    }
    let previous = accounts[index]
    let previousPayees = payees
    let next = AccountIdentity(name: trimmed, classification: identity.classification, icon: identity.icon)
    accounts[index] = previous.with(next)
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
      if let current = accounts.firstIndex(where: { $0.id == accountID }) {
        accounts[current] = updated
        renameTransferPayee(forAccountID: accountID, to: updated.name)
        rebuildLookups()
      }
      publishIntentCatalog()
      scheduleRefresh(after: .accountUpdated)
    } catch {
      if let current = accounts.firstIndex(where: { $0.id == accountID }) {
        accounts[current] = previous
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
      return source.sorted { first, second in
        let firstUsage = accountUsageLast30Days[first.id, default: 0]
        let secondUsage = accountUsageLast30Days[second.id, default: 0]
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
      snapshotMostUsedAccountOrders()
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

  private func snapshotMostUsedAccountOrders() {
    var changed = false
    for group in accountListGroups(includeEmptySystemGroups: true, includeEmptyCustomGroups: true)
    where sortForAccountGroup(group.id) == .mostUsedLast30Days {
      let order = group.accounts.map(\.id)
      if viewPrefs.accountOrderByGroup[group.id] != order {
        viewPrefs.accountOrderByGroup[group.id] = order
        changed = true
      }
    }
    if changed {
      saveViewPrefs()
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

  func overlaying(_ rows: [Transaction]) -> [Transaction] {
    overlayingClearedToggles(on: overlayingPendingEdits(on: rows))
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
    return since.count { id in
      // A rejected row is gone from both arrays, so its account was recorded.
      if let rejectedFrom = rejectedUnapprovedAccounts[id] {
        return rejectedFrom == accountID
      }
      let row = serverTransactions.first { $0.id == id }
        ?? serverUnapprovedTransactions.first { $0.id == id }
      return row?.accountID == accountID
    }
  }

  var unapprovedTransactions: [Transaction] {
    overlaying(serverUnapprovedTransactions).filter { row in
      !row.deleted && !row.approved && !approvalSession.confirmed.contains(row.id)
    }
  }

  var isApprovalInFlight: Bool {
    !approvalSession.pending.isEmpty
  }

  func approveAllTitle(for rows: [Transaction]) -> String? {
    let count = eligibleApprovalCount(in: rows)
    return count == 0 ? nil : RegisterApproval.approveAllLabel(count)
  }

  var pendingRows: [PendingRow] {
    guard !pendingTransactions.isEmpty else { return [] }
    let serverImportIDs = Set(serverTransactions.compactMap(\.importID))
    return pendingTransactions.compactMap { pending in
      guard settings.matchesCurrentOrLegacyOutboxStamp(pending.connectionFingerprint) else {
        return nil
      }
      if let importID = pending.request.importID, serverImportIDs.contains(importID) {
        return nil
      }
      return pendingRow(from: pending)
    }
  }

  func hasPendingCreate(importID: String?) -> Bool {
    guard let importID, !importID.isEmpty else {
      return false
    }
    return pendingTransactions.contains { $0.request.importID == importID }
  }

  func reviseConversationCapture(_ item: CaptureDraftItem) {
    if applyRevisionToExistingServerRow(item) {
      return
    }
    replacePendingCreate(importID: item.id, draft: item.draft)
    _ = applyRevisionToExistingServerRow(item)
  }

  private func matchingServerRow(importID: String, accountID: String) -> Transaction? {
    let match: (Transaction) -> Bool = { row in
      row.importID == importID && (accountID.isEmpty || row.accountID == accountID)
    }
    return serverTransactions.first(where: match)
      ?? serverUnapprovedTransactions.first(where: match)
  }

  @discardableResult
  private func applyRevisionToExistingServerRow(_ item: CaptureDraftItem) -> Bool {
    guard let existing = matchingServerRow(importID: item.id, accountID: item.draft.accountID) else {
      return false
    }
    pendingCreateRevisions[item.id] = nil
    var draft = item.draft
    draft.id = existing.id
    applyPendingEdit(draft, transactionID: existing.id)
    return true
  }

  private func replacePendingCreate(importID: String, draft: TransactionDraft) {
    switch CaptureOutboxRevision.action(
      importID: importID,
      pending: pendingTransactions,
      inFlightIDs: inFlightCreates
    ) {
    case .queueUntilCreateSettles:
      pendingCreateRevisions[importID] = draft
    case .replaceOutbox(let index):
      pendingCreateRevisions[importID] = nil
      replaceOutboxRequest(at: index, draft: draft)
    }
  }

  private func replaceOutboxRequest(at index: Int, draft: TransactionDraft) {
    let old = pendingTransactions[index]
    var next = pendingTransactions
    next[index] = old.replacing(request: draft.writeRequest(includeCleared: draft.shouldWriteCleared))
    do {
      try OutboxStore.save(next)
      pendingTransactions = next
    } catch {
      showSaveMessage("Couldn’t save changes — \(error.localizedDescription)", kind: .failure)
    }
  }

  private func applyQueuedCreateRevision(importID: String?, transactionID: String) {
    guard let importID, var revision = pendingCreateRevisions.removeValue(forKey: importID) else {
      return
    }
    revision.id = transactionID
    applyPendingEdit(revision, transactionID: transactionID)
  }

  private func writeQueuedRevisionIntoOutbox(_ item: PendingTransaction) {
    guard let importID = item.request.importID,
          let revision = pendingCreateRevisions.removeValue(forKey: importID),
          let index = pendingTransactions.firstIndex(where: { $0.id == item.id })
    else {
      return
    }
    replaceOutboxRequest(at: index, draft: revision)
  }

  private func overlayingPendingEdits(on rows: [Transaction]) -> [Transaction] {
    guard !pendingEdits.isEmpty else {
      return rows
    }
    return rows.map { row in
      pendingEdits[row.id]?.applied(to: row) ?? row
    }
    .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
  }

  private func overlayingClearedToggles(on rows: [Transaction]) -> [Transaction] {
    guard !clearedToggleOverlays.isEmpty else {
      return rows
    }
    return rows.map { row in
      guard let cleared = clearedToggleOverlays[row.id] else {
        return row
      }
      return row.withCleared(cleared)
    }
  }

  /// Keep an in-flight (or just-acked) flip when a fetch still has the old
  /// `cleared` value. Drop it once the server snapshot matches, but never
  /// while the PATCH is still outstanding.
  private func reconcileClearedToggleOverlays() {
    guard !clearedToggleOverlays.isEmpty else {
      return
    }
    for (id, cleared) in clearedToggleOverlays {
      if clearedTogglesInFlight.contains(id) {
        continue
      }
      let snapshots = [serverTransactions, serverUnapprovedTransactions].compactMap { rows in
        rows.first { $0.id == id }
      }
      if snapshots.isEmpty {
        continue
      }
      if snapshots.allSatisfy({ $0.cleared == cleared }) {
        clearedToggleOverlays[id] = nil
      }
    }
  }

  private func pendingRow(from pending: PendingTransaction) -> PendingRow {
    let request = pending.request
    let status: PendingRow.Status
    if inFlightCreates.contains(pending.id) {
      status = .sending
    } else if let error = pending.lastSyncError {
      status = .rejected(error)
    } else {
      status = .waitingForConnection
    }
    return PendingRow(
      pending: pending,
      status: status,
      accountName: account(withID: request.accountID)?.name ?? "",
      categoryName: categoryName(forID: request.categoryID),
      payeeName: request.payeeName ?? request.payeeID.flatMap { payee(withID: $0)?.name }
    )
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

  func refreshAll(quiet: Bool = false) async {
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
    async let outbox: Int = drainOutbox(trigger: .refresh)
    async let reference: Void = refreshReferenceData(quiet: quiet)
    async let ledger: Void = refreshLedger(quiet: quiet)
    async let schedules: Void = refreshScheduledTransactions(quiet: quiet)
    _ = await (outbox, reference, ledger, schedules)
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
      planRefreshGeneration &+= 1
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
    async let outbox: Int = request.quiet ? 0 : drainOutbox(trigger: .refresh)
    async let accountsSlice: Void = run(.accounts, in: request)
    async let payeesSlice: Void = run(.payees, in: request)
    async let referenceSlice: Void = run(.referenceData, in: request)
    async let ledgerSlice: Void = run(.ledger, in: request)
    async let schedulesSlice: Void = run(.schedules, in: request)
    async let reportsSlice: Void = run(.reports, in: request)
    _ = await (
      outbox, accountsSlice, payeesSlice, referenceSlice, ledgerSlice, schedulesSlice, reportsSlice
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
      accounts = fetched
      rebuildLookups()
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
      planSettings = reference.planSettings
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
      let page = try await apiClient.fetchTransactions(planID: planID)
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
            page.transactions + serverTransactions.filter { !displaced.contains($0.id) }
          )
        } else {
          serverTransactions = sortedUniqueTransactions(
            quiet ? page.transactions + serverTransactions : page.transactions
          )
        }
      }
      reconcileClearedToggleOverlays()
      applyTransactionPageCursor(page)
      ledgerPhase = .loaded
      ledgerIsProvisional = false
      provisionalLedgerRowIDs = []
      lastLedgerFirstPage = ReferenceSnapshot.LedgerPage(
        transactions: page.transactions,
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
          let older = try await apiClient.fetchTransactions(planID: planID, offset: offset)
          guard
            generation == ledgerPageGeneration,
            planID == settings.planID,
            nextTransactionOffset == offset
          else {
            return
          }
          applyOlderTransactionPage(older)
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
    guard let count = try? await apiClient.fetchUnapprovedCount(planID: planID, accountID: accountID) else { return }
    guard generation == ledgerPageGeneration, planID == settings.planID else { return }
    if let accountID {
      serverUnapprovedCountsByAccount[accountID] = count
    } else {
      serverUnapprovedCount = count
      // The count lands after the ledger page that spawned it, so the snapshot
      // written there carries the previous number. Rewrite it with this one.
      persistSnapshot()
    }
    confirmedWhenCounted[countScopeKey(accountID)] = locallyResolvedUnapprovedIDs
  }

  /// Rows this session has taken off the queue: approved, or rejected.
  private var locallyResolvedUnapprovedIDs: Set<String> {
    approvalSession.confirmed.union(rejectedUnapprovedAccounts.keys)
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
    unapprovedQueuePhase = .loading
    do {
      let unapproved = try await apiClient.fetchAllUnapprovedTransactions(planID: planID)
      guard generation == ledgerPageGeneration, planID == settings.planID else { return }
      guard stillWantsUnapprovedQueue() else { return }
      replaceUnapprovedQueue(with: unapproved)
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
    clearedToggleOverlays.removeAll()
    clearedTogglesInFlight.removeAll()
    scheduledTransactions = []
    spendingBreakdown = nil
    incomeVsSpending = nil
    netWorth = nil
    ageOfMoney = nil
    cancelPendingEdits()
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
    // A cursor and a reports cache belong to one plan; carrying them across a
    // connection change would serve the previous plan's reports.
    serverKnowledge = nil
    reportsKnowledge = nil
    reportsGenerationAtLastFetch = nil
    queuedRefresh = .none
    planRefreshGeneration &+= 1
    // ReflectView's only trigger is `.task(id: reportsRefreshGeneration)`, so
    // without this a plan switch made while Reflect is visible leaves it
    // sitting on an empty placeholder.
    reportsRefreshGeneration &+= 1
    rewardsRefreshGeneration &+= 1
    invalidateAccountUsage()
    wipeIntentCatalog()
  }

  func noteRewardsBoardChanged() {
    rewardsRefreshGeneration &+= 1
  }

  func noteRewardsImport() async {
    noteRewardsBoardChanged()
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
    await refresh(after: .scheduledOccurrenceEntered(isTransfer: isTransfer(result.transaction)))
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

    let result = try await apiClient.reconcileAccount(
      planID: settings.planID,
      accountID: accountID,
      idempotencyKey: idempotencyKey,
      statementDate: statementDate,
      statementBalance: statementBalance
    )

    // The response already carries the account with its new balances.
    if let index = accounts.firstIndex(where: { $0.id == result.account.id }) {
      accounts[index] = result.account
      rebuildLookups()
    }
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

    let horizon = RegisterHorizon.standard
    let startDate = horizon.startDate()
    var loaded = serverTransactions.filter { $0.accountID == accountID }
    var offset = 0
    var hasMore = true

    while horizon.shouldFetchMore(
      oldestLoadedDate: RegisterHorizon.coverageOldestDate(in: loaded, accountID: accountID),
      hasMore: hasMore,
      rowCount: loaded.count
    ) {
      do {
        let page = try await apiClient.fetchTransactions(
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
        loaded = sortedUniqueTransactions(loaded + page.transactions).filter { $0.accountID == accountID }
        serverTransactions = sortedUniqueTransactions(serverTransactions + page.transactions)
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
      let page = try await apiClient.fetchTransactions(planID: planID, offset: offset)
      guard
        generation == ledgerPageGeneration,
        planID == settings.planID,
        nextTransactionOffset == offset
      else {
        return
      }
      applyOlderTransactionPage(page)
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

  private func applyOlderTransactionPage(_ page: TransactionPage) {
    serverTransactions = sortedUniqueTransactions(serverTransactions + page.transactions)
    reconcileClearedToggleOverlays()
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
      reportsPhase = .loaded
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
    if drafts.count == 1, let draft = drafts.first, let transactionID = draft.id {
      applyPendingEdit(draft, transactionID: transactionID)
      rememberLastUsedAccount(from: drafts)
      return
    }
    let creates = drafts.filter { $0.id == nil }
    for draft in drafts {
      if let transactionID = draft.id {
        applyPendingEdit(draft, transactionID: transactionID)
      }
    }
    guard !creates.isEmpty else {
      rememberLastUsedAccount(from: drafts)
      return
    }
    try enqueueCreates(creates)
    rememberLastUsedAccount(from: creates)
    showSaveMessage(savedMessage(for: creates))
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

  func retryPending(_ id: PendingRow.ID) {
    guard pendingTransactions.contains(where: { $0.id == id }) else {
      return
    }
    Task { await drainOutbox(trigger: .manual) }
  }

  func discardPending(_ id: PendingRow.ID) {
    guard !inFlightCreates.contains(id) else {
      showSaveMessage("This transaction is still sending. Wait for it to finish.", kind: .failure)
      return
    }
    let next = pendingTransactions.filter { $0.id != id }
    do {
      try OutboxStore.save(next)
      pendingTransactions = next
    } catch {
      showSaveMessage("Couldn’t discard this transaction. Try again.", kind: .failure)
    }
  }

  private func enqueueCreates(_ drafts: [TransactionDraft]) throws {
    let next = OutboxBatch.appending(
      drafts,
      onto: pendingTransactions,
      fingerprint: settings.connectionFingerprint,
      isCurrentConnection: { settings.matchesCurrentOrLegacyOutboxStamp($0) }
    )
    do {
      try OutboxStore.save(next)
      pendingTransactions = next
    } catch {
      throw CommitRejection.persistFailed
    }
    Task { await drainOutbox(trigger: .commit) }
  }

  private func applyPendingEdit(_ draft: TransactionDraft, transactionID: String) {
    editTasks[transactionID]?.cancel()
    editGenerations[transactionID, default: 0] += 1
    let generation = editGenerations[transactionID] ?? 1
    let existing = serverTransactions.first { $0.id == transactionID }
      ?? serverUnapprovedTransactions.first { $0.id == transactionID }
    if let existing {
      pendingEdits[transactionID] = PendingEdit(
        draft: draft,
        existing: existing,
        accountName: account(withID: draft.accountID)?.name ?? existing.accountName,
        categoryName: categoryName(forID: draft.categoryID),
        payeeName: draft.payeeName.trimmedNil ?? draft.payeeID.flatMap { payee(withID: $0)?.name }
      )
    }
    let destination = EditDestination(
      planID: settings.planID,
      connectionFingerprint: settings.connectionFingerprint,
      client: apiClient
    )
    editTasks[transactionID] = Task {
      await pushEdit(draft, transactionID: transactionID, generation: generation, destination: destination)
    }
  }

  private func pushEdit(
    _ draft: TransactionDraft,
    transactionID: String,
    generation: Int,
    destination: EditDestination
  ) async {
    let request = draft.writeRequest(includeCleared: draft.shouldWriteCleared)
    do {
      let saved = try await destination.client.updateTransaction(
        planID: destination.planID,
        transactionID: transactionID,
        request: request
      )
      guard isCurrentEdit(transactionID, generation: generation, destination: destination) else {
        return
      }
      let existingRow = serverTransactions.first(where: { $0.id == transactionID })
        ?? serverUnapprovedTransactions.first(where: { $0.id == transactionID })
      if let existingRow {
        applySavedTransaction(saved, replacing: existingRow)
      }
      pendingEdits[transactionID] = nil
      editTasks[transactionID] = nil
      showSaveMessage(savedMessage(for: [draft]))
      let movedAccount = existingRow.map { $0.accountID != saved.accountID } ?? true
      let touchesTransfer = isTransfer(saved) || (existingRow.map(isTransfer) ?? false)
      let mutation = MutationKind.transactionEdited(
        changesAccount: movedAccount,
        touchesTransfer: touchesTransfer,
        hasNewPayee: isUnknownPayee(saved)
      )
      scheduleRefresh(after: mutation)
    } catch {
      guard isCurrentEdit(transactionID, generation: generation, destination: destination) else {
        return
      }
      pendingEdits[transactionID] = nil
      editTasks[transactionID] = nil
      showSaveMessage("Couldn’t save changes — \(error.localizedDescription)", kind: .failure)
      await refreshLedger(quiet: true)
    }
  }

  private func isCurrentEdit(
    _ transactionID: String,
    generation: Int,
    destination: EditDestination
  ) -> Bool {
    !Task.isCancelled
      && editGenerations[transactionID] == generation
      && destination.planID == settings.planID
      && destination.connectionFingerprint == settings.connectionFingerprint
  }

  private func cancelPendingEdits() {
    for task in editTasks.values {
      task.cancel()
    }
    editTasks.removeAll()
    editGenerations.removeAll()
    pendingEdits.removeAll()
    pendingCreateRevisions.removeAll()
  }

  private func ensureNoPendingEdit(on transaction: Transaction) throws {
    guard pendingEdits[transaction.id] == nil, editTasks[transaction.id] == nil else {
      throw APIClientError.validation("This transaction has unsaved changes syncing.")
    }
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

  func toggleTransactionCleared(_ transaction: Transaction) async throws {
    try ensureNoPendingEdit(on: transaction)
    guard !isSubmitting else {
      throw APIClientError.validation("Another transaction change is already in progress.")
    }
    guard transaction.cleared != .reconciled else {
      throw APIClientError.validation("Reconciled transactions stay locked.")
    }
    guard !clearedTogglesInFlight.contains(transaction.id) else {
      return
    }

    let cleared: ClearedState = transaction.cleared == .cleared ? .uncleared : .cleared
    clearedTogglesInFlight.insert(transaction.id)
    clearedToggleOverlays[transaction.id] = cleared
    defer { clearedTogglesInFlight.remove(transaction.id) }
    do {
      let saved = try await apiClient.updateTransactionCleared(
        planID: settings.planID,
        transactionID: transaction.id,
        expectedCleared: transaction.cleared,
        cleared: cleared
      )
      applySavedTransaction(saved, replacing: transaction)
      showSaveMessage(cleared == .cleared ? "Marked transaction cleared" : "Marked transaction uncleared")
      scheduleRefresh(after: .clearedToggled)
    } catch {
      if clearedToggleOverlays[transaction.id] == cleared {
        clearedToggleOverlays[transaction.id] = nil
      }
      await refreshLedger(quiet: true)
      throw error
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
  }

  private func eligibleApprovalCount(in rows: [Transaction]) -> Int {
    RegisterApproval.eligibleIDs(
      in: rows.filter { pendingEdits[$0.id] == nil }.map(\.approvalRow),
      session: approvalSession
    ).count
  }

  private enum ApprovalSuccessCopy {
    case bulk
    case single(Transaction)
  }

  private func runApproval(from rows: [Transaction], success: ApprovalSuccessCopy) async throws {
    let candidates = rows.filter { pendingEdits[$0.id] == nil && editTasks[$0.id] == nil }
    guard let plan = RegisterApproval.plan(
      submitted: candidates.map(\.approvalRow),
      session: approvalSession
    ) else {
      return
    }
    guard let started = RegisterApproval.begin(approvalSession, ids: plan.ids) else {
      return
    }
    approvalSession = started
    var approvedCount = 0
    do {
      for chunk in plan.chunks {
        do {
          try await apiClient.approveTransactionBatch(
            planID: settings.planID,
            transactionIDs: chunk.ids
          )
          approvedCount += chunk.count
          applyApprovedIDs(Set(chunk.ids))
        } catch {
          throw BulkApprovalError(approvedCount: approvedCount, underlying: error)
        }
      }
      approvalSession = RegisterApproval.finish(approvalSession, ids: plan.ids)
      switch success {
      case .bulk:
        showSaveMessage(RegisterApproval.approvedToast(approvedCount))
      case .single(let row):
        showSaveMessage("Approved \(row.payeeName ?? "transaction")")
      }
      // Approval moves no money and the approved ids are applied locally, so
      // this plans no fetch; the failure path below still re-reads the ledger
      // because a partial batch leaves the queue uncertain.
      await refresh(after: .transactionsApproved)
    } catch let error as BulkApprovalError {
      approvalSession = RegisterApproval.fail(
        approvalSession,
        ids: plan.ids,
        approvedCount: error.approvedCount
      )
      if error.approvedCount > 0 {
        showSaveMessage(
          RegisterApproval.interruptedToast(
            approvedCount: error.approvedCount,
            uncertainCount: max(0, plan.ids.count - error.approvedCount)
          ),
          kind: .failure
        )
      }
      await refreshLedger(quiet: true)
      throw error
    }
  }

  @discardableResult
  func drainOutbox(trigger: OutboxDrainTrigger) async -> Int {
    guard !pendingTransactions.isEmpty else {
      return 0
    }
    if isSyncingOutbox {
      coalescedDrainTrigger = coalescedDrainTrigger.map { mergeDrainTrigger($0, with: trigger) } ?? trigger
      needsAnotherDrain = true
      return 0
    }

    isSyncingOutbox = true
    defer {
      isSyncingOutbox = false
      inFlightCreates.removeAll()
    }

    var syncedCount = 0
    // A transfer's mirror row and a payee created by name are the only parts
    // of a create the POST response cannot hand back.
    var syncedTransfer = false
    var syncedNewPayee = false
    var effectiveTrigger = trigger
    repeat {
      needsAnotherDrain = false
      let retryRejected = effectiveTrigger == .manual
      for item in pendingTransactions {
        let connectionFingerprint = settings.connectionFingerprint
        guard settings.matchesCurrentOrLegacyOutboxStamp(item.connectionFingerprint) else {
          continue
        }
        guard retryRejected || item.lastSyncError == nil else {
          continue
        }
        inFlightCreates.insert(item.id)
        defer { inFlightCreates.remove(item.id) }
        do {
          let client = apiClient
          let planID = settings.planID
          var request = item.request
          if request.importID == nil {
            request.importID = item.id.uuidString.lowercased()
          }
          let saved = try await client.createTransaction(planID: planID, request: request)
          removePending(item.id)
          guard connectionFingerprint == settings.connectionFingerprint else {
            pendingCreateRevisions.removeAll()
            continue
          }
          if !serverTransactions.contains(where: { $0.id == saved.id }) {
            serverTransactions.insert(saved, at: 0)
          }
          syncedTransfer = syncedTransfer || isTransfer(saved)
          syncedNewPayee = syncedNewPayee || isUnknownPayee(saved)
          applyQueuedCreateRevision(
            importID: saved.importID ?? request.importID ?? item.request.importID,
            transactionID: saved.id
          )
          syncedCount += 1
        } catch let error where error.isOfflineError {
          writeQueuedRevisionIntoOutbox(item)
          break
        } catch {
          writeQueuedRevisionIntoOutbox(item)
          markSyncError(error.localizedDescription, for: item.id)
        }
      }
      if let pending = coalescedDrainTrigger {
        coalescedDrainTrigger = nil
        effectiveTrigger = mergeDrainTrigger(effectiveTrigger, with: pending)
      }
    } while needsAnotherDrain

    if syncedCount > 0 {
      serverTransactions = sortedUniqueTransactions(serverTransactions)
      invalidateAccountUsage()
      // Balances moved whichever trigger got here, including a drain running
      // inside a pull: `scheduleRefresh` merges into that pass's queue rather
      // than awaiting the pass it is running inside.
      scheduleRefresh(
        after: .transactionsCreated(hasTransfer: syncedTransfer, hasNewPayee: syncedNewPayee)
      )
      if effectiveTrigger != .commit {
        showSaveMessage(
          syncedCount == 1 ? "Synced 1 pending transaction" : "Synced \(syncedCount) pending transactions"
        )
      }
    } else if effectiveTrigger == .manual, !pendingRows.isEmpty {
      showSaveMessage("Couldn’t sync — will retry on the next refresh", kind: .failure)
    }
    return syncedCount
  }

  private func mergeDrainTrigger(
    _ current: OutboxDrainTrigger,
    with incoming: OutboxDrainTrigger
  ) -> OutboxDrainTrigger {
    switch (current, incoming) {
    case (.manual, _), (_, .manual):
      return .manual
    case (.refresh, _), (_, .refresh):
      return .refresh
    case (.commit, .commit):
      return .commit
    }
  }

  private func removePending(_ id: UUID) {
    let next = pendingTransactions.filter { $0.id != id }
    pendingTransactions = next
    try? OutboxStore.save(next)
  }

  private func markSyncError(_ message: String, for id: UUID) {
    var next = pendingTransactions
    guard let index = next.firstIndex(where: { $0.id == id }) else {
      return
    }
    next[index].lastSyncError = message
    do {
      try OutboxStore.save(next)
      pendingTransactions = next
    } catch {
      pendingTransactions = next
    }
  }

  func deleteTransaction(_ transaction: Transaction) async throws {
    try ensureNoPendingEdit(on: transaction)
    isSubmitting = true
    defer { isSubmitting = false }

    _ = try await apiClient.deleteTransaction(
      planID: settings.planID,
      transactionID: transaction.id,
      expectedApproved: transaction.approved ? nil : false
    )
    var removedIDs: Set<String> = [transaction.id]
    if let linkedID = transaction.transferTransactionID {
      removedIDs.insert(linkedID)
    }
    for subtransaction in transaction.subtransactions {
      if let linkedID = subtransaction.transferTransactionID {
        removedIDs.insert(linkedID)
      }
    }
    // Rejecting a row awaiting approval takes it off the "New" badge, the same
    // as approving it would. Recorded before the arrays are cleared, and also
    // from the row in hand -- with the queue lazy it is usually not in them.
    for row in serverUnapprovedTransactions where removedIDs.contains(row.id) {
      rejectedUnapprovedAccounts[row.id] = row.accountID
    }
    if !transaction.approved {
      rejectedUnapprovedAccounts[transaction.id] = transaction.accountID
    }
    serverTransactions.removeAll { removedIDs.contains($0.id) }
    serverUnapprovedTransactions.removeAll { removedIDs.contains($0.id) }
    showSaveMessage("Deleted \(transaction.payeeName ?? "transaction")")
    scheduleRefresh(after: .transactionDeleted)
  }

  func approveEligible(from rows: [Transaction]) async {
    do {
      try await runApproval(from: rows, success: .bulk)
    } catch let error as BulkApprovalError {
      if error.approvedCount == 0 {
        showSaveMessage(error.localizedDescription, kind: .failure)
      }
    } catch {
      showSaveMessage(error.localizedDescription, kind: .failure)
    }
  }

  func approveTransaction(_ transaction: Transaction) async throws {
    try ensureNoPendingEdit(on: transaction)
    guard !transaction.approved else {
      return
    }
    try await runApproval(from: [transaction], success: .single(transaction))
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

private struct EditDestination {
  let planID: String
  let connectionFingerprint: String
  let client: APIClient
}
