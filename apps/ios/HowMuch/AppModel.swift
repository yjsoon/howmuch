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
  var planSettings: PlanSettings?
  var accounts: [Account] = []
  var categoryGroups: [CategoryGroup] = []
  var payees: [Payee] = []
  private var serverTransactions: [Transaction] = []
  private var serverUnapprovedTransactions: [Transaction] = []
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
  /// Increments after mutations that affect a plan month, so the Plan tab
  /// reloads its locally held monthly snapshot when it becomes visible.
  private(set) var planRefreshGeneration = 0
  private(set) var reportsRefreshGeneration = 0
  var reportsPhase: LoadPhase = .idle
  var isSubmitting = false
  var lastSaveMessage: SaveMessage?
  var isShowingSettings = false
  /// Account registers currently on a navigation stack, deepest last.
  /// Capture prefers the visible register over the last account a save used.
  private(set) var focusedRegisterAccountIDs: [String] = []
  private var pendingTransactions: [PendingTransaction] = OutboxStore.load()
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
  private var ledgerPageGeneration = 0
  private var referenceGeneration = 0
  private var scheduledTransactionsGeneration = 0
  private var reportsGeneration = 0
  /// Serialises preference writes so a slower earlier request cannot overwrite
  /// a newer reorder on the server.
  @ObservationIgnored private var accountPreferencesSyncTask: Task<Void, Never>?
  @ObservationIgnored private var accountPreferenceMutationGenerations: [String: Int] = [:]
  @ObservationIgnored private var accountPreferenceSyncedGenerations: [String: Int] = [:]

  init(settings: APISettings = .load(), viewPrefs: ViewPrefs = .load()) {
    var scopedStore = ScopedViewPrefsStore.load()
    let scope = settings.viewPrefsScopeKey
    if scope == nil {
      scopedStore.discardUnscopedLegacyMigration()
    }
    self.settings = settings
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
    planSettings = nil
    accounts = []
    categoryGroups = []
    payees = []
    serverTransactions = []
    serverUnapprovedTransactions = []
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

  /// The account the + sheet should open on: the register you are looking
  /// at, or the last saved account if you are not inside one.
  var preferredCaptureAccountID: String? {
    let openIDs = Set(openAccounts.map(\.id))
    if let focused = focusedRegisterAccountIDs.last, openIDs.contains(focused) {
      return focused
    }
    if let lastUsed = lastUsedAccountID, openIDs.contains(lastUsed) {
      return lastUsed
    }
    return nil
  }

  func presentCapture(_ request: CaptureRequest) {
    CaptureRouter.shared.enqueue(request)
  }

  func beginFocusedRegisterAccount(_ accountID: String) {
    focusedRegisterAccountIDs.append(accountID)
    Task { await fillFocusedAccountHorizon() }
  }

  func endFocusedRegisterAccount(_ accountID: String) {
    if let index = focusedRegisterAccountIDs.lastIndex(of: accountID) {
      focusedRegisterAccountIDs.remove(at: index)
    }
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
    await refreshLedgerAndInvalidatePlan()
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
      let iconToSend = identity.icon.rawValue == currentIcon ? nil : identity.icon.rawValue
      let updated = try await apiClient.updateAccount(
        planID: settings.planID,
        accountID: accountID,
        name: trimmed,
        icon: iconToSend,
        type: typeToSend
      )
      if let current = accounts.firstIndex(where: { $0.id == accountID }) {
        accounts[current] = updated
        renameTransferPayee(forAccountID: accountID, to: updated.name)
        rebuildLookups()
      }
      publishIntentCatalog()
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
    activeViewPrefsScope = nextScope
    if let nextScope {
      viewPrefs = scopedViewPrefsStore.activate(scope: nextScope, legacy: legacyViewPrefs)
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

  private func rebuildLookups() {
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

  var unapprovedTransactions: [Transaction] {
    overlaying(serverUnapprovedTransactions)
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
    settings = nextSettings
    settings.save()
    if scopeChanged {
      clearConnectionOwnedState()
    }
    switchViewPrefsScope()
    await refreshAll()
  }

  func refreshAll(quiet: Bool = false) async {
    guard await resolvePlanSelection() else {
      return
    }

    // Replay offline captures alongside the fetches rather than before them:
    // an unreachable server must not stall the refresh for a full request
    // timeout. Inserts dedupe by id, so a capture the ledger fetch already
    // returned is never doubled.
    async let outbox: Int = drainOutbox(trigger: .refresh)
    async let reference: Void = refreshReferenceData(quiet: quiet)
    async let ledger: Void = refreshLedger(quiet: quiet)
    async let schedules: Void = refreshScheduledTransactions(quiet: quiet)
    async let reports = refreshReflectOverview(quiet: quiet)
    _ = await (outbox, reference, ledger, schedules, reports)
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
    if !quiet {
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
    if !quiet {
      hasMoreTransactions = false
      nextTransactionOffset = nil
      isLoadingOlderTransactions = false
      isFillingHorizon = false
      horizonFillCount = 0
      olderTransactionsError = nil
      ledgerPhase = .loading
    }
    do {
      async let firstPage = apiClient.fetchTransactions(planID: planID)
      async let approvalQueue = apiClient.fetchAllUnapprovedTransactions(planID: planID)
      let (page, unapproved) = try await (firstPage, approvalQueue)
      guard generation == ledgerPageGeneration, planID == settings.planID else {
        return
      }
      pushHorizonFill()
      // Mutation refreshes must not drop already-loaded rows; List would clamp to top.
      serverTransactions = sortedUniqueTransactions(
        quiet ? page.transactions + serverTransactions : page.transactions
      )
      serverUnapprovedTransactions = sortedUniqueTransactions(unapproved)
      reconcileClearedToggleOverlays()
      applyTransactionPageCursor(page)
      ledgerPhase = .loaded
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
    planSettings = nil
    accounts = []
    categoryGroups = []
    payees = []
    serverTransactions = []
    serverUnapprovedTransactions = []
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
    scheduledTransactionsGeneration &+= 1
    reportsGeneration &+= 1
    planRefreshGeneration &+= 1
    invalidateAccountUsage()
    wipeIntentCatalog()
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
    if !quiet {
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
    showSaveMessage(draft.id == nil ? "Added scheduled transaction" : "Saved scheduled transaction")
  }

  func deleteScheduledTransaction(id: String, idempotencyKey: String) async throws {
    isSubmitting = true
    defer { isSubmitting = false }

    _ = try await apiClient.deleteScheduledTransaction(planID: settings.planID, scheduleID: id, idempotencyKey: idempotencyKey)
    scheduledTransactions.removeAll { $0.id == id }
    scheduledTransactionsPhase = .loaded
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

    await refreshLedgerAndInvalidatePlan()
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

    await refreshLedgerAndInvalidatePlan()

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
    if let last = drafts.last {
      viewPrefs.lastUsedAccountID = last.accountID
      saveViewPrefs()
    }
    if drafts.count == 1, let draft = drafts.first, let transactionID = draft.id {
      applyPendingEdit(draft, transactionID: transactionID)
      return
    }
    let creates = drafts.filter { $0.id == nil }
    for draft in drafts {
      if let transactionID = draft.id {
        applyPendingEdit(draft, transactionID: transactionID)
      }
    }
    guard !creates.isEmpty else {
      return
    }
    try enqueueCreates(creates)
    showSaveMessage(savedMessage(for: creates))
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
      if let existing = serverTransactions.first(where: { $0.id == transactionID })
        ?? serverUnapprovedTransactions.first(where: { $0.id == transactionID }) {
        applySavedTransaction(saved, replacing: existing)
      }
      pendingEdits[transactionID] = nil
      editTasks[transactionID] = nil
      showSaveMessage(savedMessage(for: [draft]))
      Task { await refreshLedgerAndInvalidatePlan() }
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
      Task { await refreshLedgerAndInvalidatePlan() }
    } catch {
      if clearedToggleOverlays[transaction.id] == cleared {
        clearedToggleOverlays[transaction.id] = nil
      }
      await refreshLedger(quiet: true)
      throw error
    }
  }

  private func applySavedTransaction(_ saved: Transaction, replacing existing: Transaction) {
    let next = saved.preservingParent(from: existing)
    if let index = serverTransactions.firstIndex(where: { $0.id == existing.id }) {
      serverTransactions[index] = next
    }
    if let index = serverUnapprovedTransactions.firstIndex(where: { $0.id == existing.id }) {
      serverUnapprovedTransactions[index] = next
    }
  }

  func refreshLedgerAndInvalidatePlan() async {
    async let reference: Void = refreshReferenceData(quiet: true)
    async let ledger: Void = refreshLedger(quiet: true)
    async let schedules: Void = refreshScheduledTransactions(quiet: true)
    _ = await (reference, ledger, schedules)
    planRefreshGeneration &+= 1
    reportsRefreshGeneration &+= 1
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
            continue
          }
          if !serverTransactions.contains(where: { $0.id == saved.id }) {
            serverTransactions.insert(saved, at: 0)
          }
          syncedCount += 1
        } catch let error where error.isOfflineError {
          break
        } catch {
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
      planRefreshGeneration &+= 1
      reportsRefreshGeneration &+= 1
      if effectiveTrigger != .commit {
        showSaveMessage(
          syncedCount == 1 ? "Synced 1 pending transaction" : "Synced \(syncedCount) pending transactions"
        )
      }
      if effectiveTrigger == .commit {
        Task { await refreshLedgerAndInvalidatePlan() }
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
    serverTransactions.removeAll { removedIDs.contains($0.id) }
    serverUnapprovedTransactions.removeAll { removedIDs.contains($0.id) }
    showSaveMessage("Deleted \(transaction.payeeName ?? "transaction")")
    Task { await refreshLedgerAndInvalidatePlan() }
  }

  func approveTransaction(_ transaction: Transaction) async throws {
    try ensureNoPendingEdit(on: transaction)
    guard !transaction.approved else {
      return
    }
    let approved = try await apiClient.approveTransaction(
      planID: settings.planID,
      transactionID: transaction.id
    )
    applySavedTransaction(approved, replacing: transaction)
    showSaveMessage("Approved \(approved.payeeName ?? "transaction")")
    await refreshLedger(quiet: true)
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
