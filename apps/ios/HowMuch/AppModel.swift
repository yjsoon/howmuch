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
  /// Loaded portion of the ledger, newest first. Older pages append on demand.
  var transactions: [Transaction] = []
  /// Imported YNAB schedules remain an immutable source mirror; local edits
  /// and entered occurrences are reflected through HowMuch overlays.
  var scheduledTransactions: [ScheduledTransaction] = []
  private(set) var hasMoreTransactions = false
  private(set) var nextTransactionOffset: Int?
  private(set) var isLoadingOlderTransactions = false
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
  var reportsPhase: LoadPhase = .idle
  var isSubmitting = false
  var lastSaveMessage: String?
  var isShowingSettings = false
  var isShowingCapture = false
  /// Captures made while the server was unreachable, oldest first.
  var pendingTransactions: [PendingTransaction] = OutboxStore.load()
  var pendingTransactionsForLiveConnection: [PendingTransaction] {
    pendingTransactions.filter { settings.matchesCurrentOrLegacyOutboxStamp($0.connectionFingerprint) }
  }
  /// True while a replay pass is running, whoever started it — the outbox
  /// card drives its spinner from this rather than view-local state.
  var isSyncingOutbox = false
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
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleAuthenticationExpiry()
      }
    }
  }

  /// Clears all authenticated and cached state after a server-side session
  /// revocation. Keeping stale accounts visible while another request reports
  /// "Invalid credentials" is misleading and can invite writes with a dead
  /// session, so the connection screen is made the single next step.
  private func handleAuthenticationExpiry() {
    guard settings.isAuthenticated else {
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
    transactions = []
    scheduledTransactions = []
    spendingBreakdown = nil
    incomeVsSpending = nil
    netWorth = nil
    ageOfMoney = nil
    invalidateAccountUsage()
    rebuildLookups()
    referencePhase = .idle
    ledgerPhase = .idle
    scheduledTransactionsPhase = .idle
    reportsPhase = .idle
    ledgerPageGeneration += 1
    isShowingSettings = true
  }

  var lastUsedAccountID: String? {
    viewPrefs.lastUsedAccountID
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

  private func accountNameOrder(_ first: Account, _ second: Account) -> Bool {
    let nameOrder = first.name.localizedStandardCompare(second.name)
    return nameOrder == .orderedSame ? first.id < second.id : nameOrder == .orderedAscending
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
    scopedViewPrefsStore.set(viewPrefs, for: scope)
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
    async let outbox: Int = syncOutbox()
    async let reference: Void = refreshReferenceData(quiet: quiet)
    async let ledger: Void = refreshLedger(quiet: quiet)
    async let schedules: Void = refreshScheduledTransactions(quiet: quiet)
    async let reports: Void = refreshReflectOverview(quiet: quiet)
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
      pruneViewPrefs(using: reference.accounts)
      referencePhase = .loaded
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
    hasMoreTransactions = false
    nextTransactionOffset = nil
    isLoadingOlderTransactions = false
    olderTransactionsError = nil
    if !quiet {
      ledgerPhase = .loading
    }
    do {
      let page = try await apiClient.fetchTransactions(planID: planID)
      guard generation == ledgerPageGeneration, planID == settings.planID else {
        return
      }
      transactions = sortedUniqueTransactions(page.transactions)
      hasMoreTransactions = page.hasMore && page.nextOffset != nil
      nextTransactionOffset = hasMoreTransactions ? page.nextOffset : nil
      ledgerPhase = .loaded
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
    transactions = []
    scheduledTransactions = []
    spendingBreakdown = nil
    incomeVsSpending = nil
    netWorth = nil
    ageOfMoney = nil
    hasMoreTransactions = false
    nextTransactionOffset = nil
    isLoadingOlderTransactions = false
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

  /// Appends one older page to the current, unfiltered ledger cursor. Register
  /// scopes and drill-downs filter this common ordered page locally, so their
  /// navigation cannot leave a separate filter-specific offset behind.
  func loadOlderTransactions() async {
    guard
      ledgerPhase == .loaded,
      hasMoreTransactions,
      let offset = nextTransactionOffset,
      !isLoadingOlderTransactions
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
      transactions = sortedUniqueTransactions(transactions + page.transactions)
      hasMoreTransactions = page.hasMore && page.nextOffset != nil
      nextTransactionOffset = hasMoreTransactions ? page.nextOffset : nil
    } catch {
      guard generation == ledgerPageGeneration, planID == settings.planID else {
        return
      }
      olderTransactionsError = error.localizedDescription
    }
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
  func refreshReflectOverview(quiet: Bool = false) async {
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
        return
      }
      spendingBreakdown = spendingReport
      incomeVsSpending = incomeReport
      netWorth = worthReport
      ageOfMoney = ageReport
      reportsPhase = .loaded
    } catch {
      guard generation == reportsGeneration,
            planID == settings.planID,
            scope == activeViewPrefsScope
      else {
        return
      }
      reportsPhase = .failed(error.localizedDescription)
    }
  }

  /// Returns the saved transaction, or nil when the capture was queued
  /// offline. Edits are never queued: replaying a stale update could clobber
  /// changes made from elsewhere while this device was offline.
  @discardableResult
  func saveTransaction(_ draft: TransactionDraft) async throws -> Transaction? {
    guard !isSubmitting else {
      throw APIClientError.validation("A save is already in progress.")
    }
    isSubmitting = true
    defer { isSubmitting = false }

    guard draft.canSave else {
      throw APIClientError.validation("Enter an amount and pick an account.")
    }

    let request = draft.writeRequest()
    let saved: Transaction
    if let id = draft.id {
      saved = try await apiClient.updateTransaction(planID: settings.planID, transactionID: id, request: request)
      if let index = transactions.firstIndex(where: { $0.id == id }) {
        transactions[index] = saved
      }
    } else {
      do {
        saved = try await apiClient.createTransaction(planID: settings.planID, request: request)
      } catch let error where error.isOfflineError {
        queueOfflineCapture(request)
        return nil
      }
      if let index = transactions.firstIndex(where: { $0.id == saved.id }) {
        transactions[index] = saved
      } else {
        transactions.insert(saved, at: 0)
      }
    }
    transactions.sort { ($0.date, $0.id) > ($1.date, $1.id) }

    viewPrefs.lastUsedAccountID = request.accountID
    saveViewPrefs()
    showSaveMessage("Saved \(MoneyCodec.displayString(for: saved.amount, currencyFormat: currencyFormat)) — \(saved.payeeName ?? "transaction")")
    Task { await refreshLedgerAndInvalidatePlan() }
    return saved
  }

  func refreshLedgerAndInvalidatePlan() async {
    async let reference: Void = refreshReferenceData(quiet: true)
    async let ledger: Void = refreshLedger(quiet: true)
    async let schedules: Void = refreshScheduledTransactions(quiet: true)
    _ = await (reference, ledger, schedules)
    planRefreshGeneration &+= 1
  }

  /// The server never saw this capture; keep it locally and replay it once a
  /// refresh reaches the server again.
  private func queueOfflineCapture(_ request: TransactionWriteRequest) {
    pendingTransactions.append(PendingTransaction(request: request, connectionFingerprint: settings.connectionFingerprint))
    OutboxStore.save(pendingTransactions)
    viewPrefs.lastUsedAccountID = request.accountID
    saveViewPrefs()
    showSaveMessage("Saved offline — will sync on next refresh")
  }

  /// Replays offline captures oldest-first, returning how many synced. Only
  /// captures made against the current connection are attempted, and only a
  /// manual pass retries entries the server has already rejected once. The
  /// queue is persisted after every state change so a kill mid-pass cannot
  /// replay an already-synced capture. A transport failure ends the pass.
  @discardableResult
  func syncOutbox(manual: Bool = false) async -> Int {
    guard !pendingTransactions.isEmpty, !isSyncingOutbox else {
      return 0
    }
    isSyncingOutbox = true
    defer { isSyncingOutbox = false }

    var syncedCount = 0
    for item in pendingTransactions {
      let connectionFingerprint = settings.connectionFingerprint
      guard settings.matchesCurrentOrLegacyOutboxStamp(item.connectionFingerprint) else {
        continue
      }
      guard manual || item.lastSyncError == nil else {
        continue
      }
      do {
        let planID = settings.planID
        let client = apiClient
        var request = item.request
        if request.importID == nil {
          request.importID = item.id.uuidString.lowercased()
        }
        let saved = try await client.createTransaction(planID: planID, request: request)
        pendingTransactions.removeAll { $0.id == item.id }
        OutboxStore.save(pendingTransactions)
        guard connectionFingerprint == settings.connectionFingerprint else {
          continue
        }
        if !transactions.contains(where: { $0.id == saved.id }) {
          transactions.insert(saved, at: 0)
        }
        syncedCount += 1
      } catch let error where error.isOfflineError {
        break
      } catch {
        markSyncError(error.localizedDescription, for: item.id)
        OutboxStore.save(pendingTransactions)
      }
    }
    if syncedCount > 0 {
      transactions.sort { ($0.date, $0.id) > ($1.date, $1.id) }
      invalidateAccountUsage()
      planRefreshGeneration &+= 1
      showSaveMessage(syncedCount == 1 ? "Synced 1 offline transaction" : "Synced \(syncedCount) offline transactions")
    } else if manual, !pendingTransactionsForLiveConnection.isEmpty {
      showSaveMessage("Couldn’t sync — will retry on the next refresh")
    }
    return syncedCount
  }

  func discardPending(_ item: PendingTransaction) {
    pendingTransactions.removeAll { $0.id == item.id }
    OutboxStore.save(pendingTransactions)
  }

  private func markSyncError(_ message: String, for id: UUID) {
    if let index = pendingTransactions.firstIndex(where: { $0.id == id }) {
      pendingTransactions[index].lastSyncError = message
    }
  }

  func deleteTransaction(_ transaction: Transaction) async throws {
    isSubmitting = true
    defer { isSubmitting = false }

    _ = try await apiClient.deleteTransaction(planID: settings.planID, transactionID: transaction.id)
    transactions.removeAll { $0.id == transaction.id }
    showSaveMessage("Deleted \(transaction.payeeName ?? "transaction")")
    Task { await refreshLedgerAndInvalidatePlan() }
  }

  private func showSaveMessage(_ message: String) {
    lastSaveMessage = message
    saveMessageToken += 1
    let token = saveMessageToken
    Task {
      try? await Task.sleep(for: .seconds(3))
      if token == saveMessageToken {
        lastSaveMessage = nil
      }
    }
  }
}
