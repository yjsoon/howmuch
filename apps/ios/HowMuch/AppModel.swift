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
  var recentTransactions: [Transaction] = []
  var spendingBreakdown: SpendingBreakdownReport?
  var incomeVsSpending: IncomeVsSpendingReport?
  var netWorth: NetWorthReport?
  var ageOfMoney: AgeOfMoneyReport?
  var reportRange: ReportRange
  var reportInterval: ReportInterval
  var includeQuietSpending: Bool

  var referencePhase: LoadPhase = .idle
  var recentsPhase: LoadPhase = .idle
  var reportsPhase: LoadPhase = .idle
  var isSubmitting = false
  var lastSaveMessage: String?
  var isShowingSettings = false
  var isShowingCapture = false
  var lastUsedAccountID: String?
  var lastUsedCategoryID: String?
  private var settingsRequestedFromCapture = false
  private var saveMessageToken = 0

  init(settings: APISettings = .load(), viewPrefs: ViewPrefs = .load()) {
    self.settings = settings
    self.reportRange = viewPrefs.reportRange
    self.reportInterval = viewPrefs.reportInterval
    self.includeQuietSpending = viewPrefs.includeQuietSpending
    self.lastUsedAccountID = viewPrefs.lastUsedAccountID
    self.lastUsedCategoryID = viewPrefs.lastUsedCategoryID
  }

  /// Snapshot the remembered view options; call after any deliberate change.
  func saveViewPrefs() {
    ViewPrefs(
      reportRange: reportRange,
      reportInterval: reportInterval,
      includeQuietSpending: includeQuietSpending,
      lastUsedAccountID: lastUsedAccountID,
      lastUsedCategoryID: lastUsedCategoryID
    ).save()
  }

  var apiClient: APIClient {
    APIClient(settings: settings)
  }

  var flattenedCategories: [Category] {
    categoryGroups
      .flatMap(\.categories)
      .filter { !$0.deleted }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  var currencyFormat: CurrencyFormat? {
    planSettings?.currencyFormat
  }

  /// The first failure across surfaces, for the capture tab's connection banner.
  var connectionProblem: String? {
    referencePhase.errorMessage ?? recentsPhase.errorMessage ?? reportsPhase.errorMessage
  }

  /// Settings cannot present while the capture sheet is up, so dismiss first
  /// and let `captureDidDismiss` finish the hand-off.
  func requestSettingsFromCapture() {
    settingsRequestedFromCapture = true
    isShowingCapture = false
  }

  func captureDidDismiss() {
    if settingsRequestedFromCapture {
      settingsRequestedFromCapture = false
      isShowingSettings = true
    }
  }

  func applySettings(_ nextSettings: APISettings) async {
    settings = nextSettings
    settings.save()
    await refreshAll()
  }

  func refreshAll() async {
    async let reference: Void = refreshReferenceData()
    async let recents: Void = refreshRecentTransactions()
    async let reports: Void = refreshReports()
    _ = await (reference, recents, reports)
  }

  func refreshReferenceData() async {
    referencePhase = .loading
    do {
      let reference = try await apiClient.fetchReferenceData(planID: settings.planID)
      planSettings = reference.planSettings
      accounts = reference.accounts
      categoryGroups = reference.categoryGroups
      referencePhase = .loaded
    } catch {
      referencePhase = .failed(error.localizedDescription)
    }
  }

  func refreshRecentTransactions() async {
    recentsPhase = .loading
    do {
      let transactions = try await apiClient.fetchTransactions(planID: settings.planID)
      recentTransactions = Array(transactions.sorted { $0.date > $1.date }.prefix(50))
      recentsPhase = .loaded
    } catch {
      recentsPhase = .failed(error.localizedDescription)
    }
  }

  func refreshReports() async {
    reportsPhase = .loading
    do {
      let reports = try await fetchReportBundle()
      spendingBreakdown = reports.spending
      incomeVsSpending = reports.income
      netWorth = reports.netWorth
      ageOfMoney = reports.ageOfMoney
      reportsPhase = .loaded
    } catch {
      reportsPhase = .failed(error.localizedDescription)
    }
  }

  func submitQuickEntry(_ draft: QuickEntryDraft) async throws -> QuickEntryDraft {
    isSubmitting = true
    defer { isSubmitting = false }

    let request = try draft.makeTransactionRequest()
    let created = try await apiClient.createTransaction(planID: settings.planID, request: request)

    lastUsedAccountID = request.accountID
    lastUsedCategoryID = request.categoryID
    saveViewPrefs()
    recentTransactions.insert(created, at: 0)
    if recentTransactions.count > 50 {
      recentTransactions = Array(recentTransactions.prefix(50))
    }

    lastSaveMessage = "Saved \(MoneyCodec.displayString(for: created.amount, currencyFormat: currencyFormat)) — \(created.payeeName ?? "transaction")"
    saveMessageToken += 1
    let token = saveMessageToken
    Task {
      try? await Task.sleep(for: .seconds(3))
      if token == saveMessageToken {
        lastSaveMessage = nil
      }
    }
    await refreshReports()
    return draft.resetAfterSubmit()
  }

  private func fetchReportBundle() async throws -> (
    spending: SpendingBreakdownReport,
    income: IncomeVsSpendingReport,
    netWorth: NetWorthReport,
    ageOfMoney: AgeOfMoneyReport
  ) {
    let dates = reportRange.resolvedDates()

    async let spending = apiClient.fetchSpendingBreakdown(planID: settings.planID, from: dates.from, to: dates.to)
    async let income = apiClient.fetchIncomeVsSpending(planID: settings.planID, from: dates.from, to: dates.to, interval: reportInterval)
    async let netWorth = apiClient.fetchNetWorth(planID: settings.planID, from: dates.from, to: dates.to, interval: reportInterval)
    // Age of money replays income lots from `from`, so a clipped window
    // distorts the number — always measure across the full history.
    async let ageOfMoney = apiClient.fetchAgeOfMoney(planID: settings.planID, interval: reportInterval)

    return try await (spending, income, netWorth, ageOfMoney)
  }
}
