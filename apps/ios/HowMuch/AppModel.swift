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
  /// Full ledger, newest first. The local API is fast enough to keep it whole.
  var transactions: [Transaction] = []

  var spendingBreakdown: SpendingBreakdownReport?
  var incomeVsSpending: IncomeVsSpendingReport?
  var netWorth: NetWorthReport?
  var ageOfMoney: AgeOfMoneyReport?

  var referencePhase: LoadPhase = .idle
  var ledgerPhase: LoadPhase = .idle
  var reportsPhase: LoadPhase = .idle
  var isSubmitting = false
  var lastSaveMessage: String?
  var isShowingSettings = false
  var isShowingCapture = false
  private var viewPrefs: ViewPrefs
  private var saveMessageToken = 0

  init(settings: APISettings = .load(), viewPrefs: ViewPrefs = .load()) {
    self.settings = settings
    self.viewPrefs = viewPrefs
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
    referencePhase.errorMessage ?? ledgerPhase.errorMessage ?? reportsPhase.errorMessage
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
    async let reference: Void = refreshReferenceData(quiet: quiet)
    async let ledger: Void = refreshLedger(quiet: quiet)
    async let reports: Void = refreshReflectOverview(quiet: quiet)
    _ = await (reference, ledger, reports)
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
    if !quiet {
      ledgerPhase = .loading
    }
    do {
      let fetched = try await apiClient.fetchTransactions(planID: settings.planID)
      transactions = fetched.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
      ledgerPhase = .loaded
    } catch {
      ledgerPhase = .failed(error.localizedDescription)
    }
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

  @discardableResult
  func saveTransaction(_ draft: TransactionDraft) async throws -> Transaction {
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
      saved = try await apiClient.createTransaction(planID: settings.planID, request: request)
      transactions.insert(saved, at: 0)
    }
    transactions.sort { ($0.date, $0.id) > ($1.date, $1.id) }

    viewPrefs.lastUsedAccountID = request.accountID
    viewPrefs.save()
    showSaveMessage("Saved \(MoneyCodec.displayString(for: saved.amount, currencyFormat: currencyFormat)) — \(saved.payeeName ?? "transaction")")
    Task { await refreshAll(quiet: true) }
    return saved
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
