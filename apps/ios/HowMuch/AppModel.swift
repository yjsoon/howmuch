import Foundation
import Observation

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
  var reportWindow: ReportWindow = .threeMonths
  var reportInterval: ReportInterval = .month
  var isRefreshing = false
  var isSubmitting = false
  var lastErrorMessage: String?
  var lastSaveMessage: String?

  init(settings: APISettings = .load()) {
    self.settings = settings
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

  var hasConnectionDetails: Bool {
    settings.isConfigured
  }

  func applySettings(_ nextSettings: APISettings) async {
    settings = nextSettings
    settings.save()
    await refreshAll()
  }

  func refreshAll() async {
    guard hasConnectionDetails else {
      lastErrorMessage = "Enter the local API URL before refreshing."
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }

    do {
      async let referenceData = apiClient.fetchReferenceData(planID: settings.planID)
      async let transactions = apiClient.fetchTransactions(planID: settings.planID)
      async let reportBundle = fetchReportBundle()

      let reference = try await referenceData
      planSettings = reference.planSettings
      accounts = reference.accounts
      categoryGroups = reference.categoryGroups
      recentTransactions = Array(try await transactions.prefix(20))
      let reports = try await reportBundle
      spendingBreakdown = reports.spending
      incomeVsSpending = reports.income
      netWorth = reports.netWorth
      ageOfMoney = reports.ageOfMoney
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func refreshRecentTransactions() async {
    guard hasConnectionDetails else { return }
    do {
      recentTransactions = Array(try await apiClient.fetchTransactions(planID: settings.planID).prefix(20))
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func refreshReports() async {
    guard hasConnectionDetails else { return }
    do {
      let reports = try await fetchReportBundle()
      spendingBreakdown = reports.spending
      incomeVsSpending = reports.income
      netWorth = reports.netWorth
      ageOfMoney = reports.ageOfMoney
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func submitQuickEntry(_ draft: QuickEntryDraft) async throws -> QuickEntryDraft {
    guard hasConnectionDetails else {
      throw APIClientError.validation("Enter the API settings before saving.")
    }

    isSubmitting = true
    defer { isSubmitting = false }

    let request = try draft.makeTransactionRequest()
    let created = try await apiClient.createTransaction(planID: settings.planID, request: request)

    recentTransactions.insert(created, at: 0)
    if recentTransactions.count > 20 {
      recentTransactions = Array(recentTransactions.prefix(20))
    }

    lastSaveMessage = "Saved \(MoneyCodec.displayString(for: created.amount, currencyFormat: planSettings?.currencyFormat)) for \(created.payeeName ?? "transaction")."
    lastErrorMessage = nil
    await refreshReports()
    return draft.resetAfterSubmit()
  }

  private func fetchReportBundle() async throws -> (
    spending: SpendingBreakdownReport,
    income: IncomeVsSpendingReport,
    netWorth: NetWorthReport,
    ageOfMoney: AgeOfMoneyReport
  ) {
    let endDate = Date()
    let from = reportWindow.startDate(from: endDate).isoDateString
    let to = endDate.isoDateString

    async let spending = apiClient.fetchSpendingBreakdown(planID: settings.planID, from: from, to: to)
    async let income = apiClient.fetchIncomeVsSpending(planID: settings.planID, from: from, to: to, interval: reportInterval)
    async let netWorth = apiClient.fetchNetWorth(planID: settings.planID, from: from, to: to, interval: reportInterval)
    async let ageOfMoney = apiClient.fetchAgeOfMoney(planID: settings.planID, from: from, to: to, interval: reportInterval)

    return try await (spending, income, netWorth, ageOfMoney)
  }
}
