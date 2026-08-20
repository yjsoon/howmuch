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
  /// True while a replay pass is running, whoever started it — the outbox
  /// card drives its spinner from this rather than view-local state.
  var isSyncingOutbox = false
  private var viewPrefs: ViewPrefs
  private var saveMessageToken = 0
  /// Invalidates an in-flight older-page response when the first page reloads.
  private var ledgerPageGeneration = 0

  init(settings: APISettings = .load(), viewPrefs: ViewPrefs = .load()) {
    self.settings = settings
    self.viewPrefs = viewPrefs
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
    viewPrefs.save()
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
    viewPrefs.save()
  }

  /// Applies the device's manual order while keeping the API's stable name/id
  /// order as the deterministic fallback for accounts not yet moved locally.
  func orderedAccounts(_ source: [Account]) -> [Account] {
    var ranks: [String: Int] = [:]
    for (index, accountID) in viewPrefs.accountOrder.enumerated() {
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
        let nameOrder = first.name.localizedStandardCompare(second.name)
        return nameOrder == .orderedSame ? first.id < second.id : nameOrder == .orderedAscending
      }
    }
  }

  /// Moves an account one position within its current account group. The
  /// resulting order is shared by all account groups and the Favourites view.
  func moveAccount(_ accountID: String, in group: [Account], by offset: Int) {
    let orderedGroup = orderedAccounts(group)
    guard
      let currentIndex = orderedGroup.firstIndex(where: { $0.id == accountID })
    else {
      return
    }

    let destination = currentIndex + offset
    guard destination >= orderedGroup.startIndex, destination < orderedGroup.endIndex else {
      return
    }

    let otherID = orderedGroup[destination].id
    guard otherID != accountID else {
      return
    }

    var globalOrder = orderedAccounts(accounts).map(\.id)
    guard let firstIndex = globalOrder.firstIndex(of: accountID), let secondIndex = globalOrder.firstIndex(of: otherID) else {
      return
    }
    globalOrder.swapAt(firstIndex, secondIndex)
    viewPrefs.accountOrder = globalOrder
    viewPrefs.save()
  }

  var flattenedCategories: [Category] {
    categoryGroups
      .flatMap(\.categories)
      .filter { !$0.deleted }
  }

  var currencyFormat: CurrencyFormat? {
    planSettings?.currencyFormat
  }

  /// The first failure across surfaces, for connection banners.
  var connectionProblem: String? {
    referencePhase.errorMessage ?? ledgerPhase.errorMessage ?? scheduledTransactionsPhase.errorMessage ?? reportsPhase.errorMessage
  }

  func account(withID id: String) -> Account? {
    accounts.first { $0.id == id }
  }

  func categoryName(forID id: String?) -> String? {
    guard let id else {
      return nil
    }
    return flattenedCategories.first { $0.id == id }?.name
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
    settings = nextSettings
    settings.save()
    await refreshAll()
  }

  func refreshAll(quiet: Bool = false) async {
    await resolvePlanSelectionIfNeeded()

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

  /// A fresh app has no local plan identifier. Once an authenticated server
  /// proves that there is exactly one accessible plan, remember it before any
  /// plan-scoped requests begin. This also repairs older installs that kept
  /// the former `local-plan` development default. Multiple accessible plans
  /// are deliberately not guessed: the Connection screen remains the user's
  /// explicit selector in that case.
  private func resolvePlanSelectionIfNeeded() async {
    guard settings.isAuthenticated else {
      return
    }

    do {
      let plans = try await apiClient.fetchPlans()
      guard let selectedPlanID = settings.resolvedPlanID(from: plans), selectedPlanID != settings.planID else {
        return
      }
      settings.planID = selectedPlanID
      settings.save()
    } catch {
      // The normal surface requests retain their own error states. Do not
      // make a transient plan-list failure block an existing saved plan.
    }
  }

  func refreshReferenceData(quiet: Bool = false) async {
    if !quiet {
      referencePhase = .loading
    }
    do {
      let reference = try await apiClient.fetchReferenceData(planID: settings.planID)
      planSettings = reference.planSettings
      accounts = reference.accounts
      categoryGroups = reference.categoryGroups
      payees = reference.payees
      referencePhase = .loaded
    } catch {
      referencePhase = .failed(error.localizedDescription)
    }
  }

  func refreshLedger(quiet: Bool = false) async {
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

  func refreshScheduledTransactions(quiet: Bool = false) async {
    let planID = settings.planID
    if !quiet {
      scheduledTransactionsPhase = .loading
    }
    do {
      let schedules = try await apiClient.fetchScheduledTransactions(planID: planID)
      guard planID == settings.planID else {
        return
      }
      scheduledTransactions = schedules.sorted { ($0.dateNext, $0.id) < ($1.dateNext, $1.id) }
      scheduledTransactionsPhase = .loaded
    } catch {
      guard planID == settings.planID else {
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

    // A materialised occurrence affects the register, account balances,
    // category activity, and the schedule's next date in one server-side
    // operation. Re-fetch rather than trying to reconstruct those effects.
    async let reference: Void = refreshReferenceData(quiet: true)
    async let ledger: Void = refreshLedger(quiet: true)
    async let schedules: Void = refreshScheduledTransactions(quiet: true)
    _ = await (reference, ledger, schedules)
    planRefreshGeneration &+= 1
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

    async let reference: Void = refreshReferenceData(quiet: true)
    async let ledger: Void = refreshLedger(quiet: true)
    _ = await (reference, ledger)

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
    if !quiet {
      reportsPhase = .loading
    }
    do {
      let now = Date.now
      let monthStart = now.startOfMonth()
      let yearStart = Calendar.current.date(byAdding: .month, value: -11, to: monthStart) ?? monthStart
      let today = now.isoDateString

      async let spending = apiClient.fetchSpendingBreakdown(
        planID: settings.planID, from: monthStart.isoDateString, to: today
      )
      async let income = apiClient.fetchIncomeVsSpending(
        planID: settings.planID, from: yearStart.isoDateString, to: today, interval: .month
      )
      async let worth = apiClient.fetchNetWorth(
        planID: settings.planID, from: yearStart.isoDateString, to: today, interval: .month
      )
      async let age = apiClient.fetchAgeOfMoney(planID: settings.planID, interval: .month)

      let (spendingReport, incomeReport, worthReport, ageReport) = try await (spending, income, worth, age)
      spendingBreakdown = spendingReport
      incomeVsSpending = incomeReport
      netWorth = worthReport
      ageOfMoney = ageReport
      reportsPhase = .loaded
    } catch {
      reportsPhase = .failed(error.localizedDescription)
    }
  }

  /// Returns the saved transaction, or nil when the capture was queued
  /// offline. Edits are never queued: replaying a stale update could clobber
  /// changes made from elsewhere while this device was offline.
  @discardableResult
  func saveTransaction(_ draft: TransactionDraft) async throws -> Transaction? {
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
      transactions.insert(saved, at: 0)
    }
    transactions.sort { ($0.date, $0.id) > ($1.date, $1.id) }

    viewPrefs.lastUsedAccountID = request.accountID
    viewPrefs.save()
    showSaveMessage("Saved \(MoneyCodec.displayString(for: saved.amount, currencyFormat: currencyFormat)) — \(saved.payeeName ?? "transaction")")
    Task { await refreshAll(quiet: true) }
    return saved
  }

  /// The server never saw this capture; keep it locally and replay it once a
  /// refresh reaches the server again.
  private func queueOfflineCapture(_ request: TransactionWriteRequest) {
    pendingTransactions.append(PendingTransaction(request: request, connectionFingerprint: settings.connectionFingerprint))
    OutboxStore.save(pendingTransactions)
    viewPrefs.lastUsedAccountID = request.accountID
    viewPrefs.save()
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
      guard item.connectionFingerprint == settings.connectionFingerprint else {
        continue
      }
      guard manual || item.lastSyncError == nil else {
        continue
      }
      do {
        let saved = try await apiClient.createTransaction(planID: settings.planID, request: item.request)
        pendingTransactions.removeAll { $0.id == item.id }
        OutboxStore.save(pendingTransactions)
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
      showSaveMessage(syncedCount == 1 ? "Synced 1 offline transaction" : "Synced \(syncedCount) offline transactions")
    } else if manual, !pendingTransactions.isEmpty {
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
    Task { await refreshAll(quiet: true) }
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
