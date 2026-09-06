import SwiftUI

enum RegisterScope: Hashable {
  case all
  case account(String)
  case unapproved

  var accountID: String? {
    if case .account(let id) = self {
      return id
    }
    return nil
  }
}

/// One value per render: section headers, counts, totals and empty states all use
/// the same filtered rows instead of re-running the ledger search for each one.
struct RegisterSnapshot {
  enum Mode {
    case ledger
    case inbox
  }

  struct DateSection: Identifiable {
    let date: String
    var pending: [PendingRow] = []
    var transactions: [Transaction] = []
    var schedules: [ScheduledTransaction] = []
    var id: String { date }
  }

  let transactionCount: Int
  let scheduleCount: Int
  let isEmpty: Bool
  let inflow: Int
  let outflow: Int
  let currentDateSections: [DateSection]
  let disclosureDateSections: [DateSection]
  let scheduledDisclosureCount: Int

  init(
    transactions: [Transaction],
    pending: [PendingRow],
    schedules: [ScheduledTransaction],
    today: String,
    mode: Mode = .ledger
  ) {
    transactionCount = transactions.count
    scheduleCount = schedules.count
    isEmpty = transactions.isEmpty && pending.isEmpty && schedules.isEmpty
    var current: [String: DateSection] = [:]
    var upcoming: [String: DateSection] = [:]
    var inflow = 0
    var outflow = 0
    var upcomingCount = schedules.count
    for row in transactions {
      if row.amount > 0 { inflow += row.amount }
      if row.amount < 0 { outflow -= row.amount }
      if mode == .ledger, row.date > today {
        upcoming[row.date, default: DateSection(date: row.date)].transactions.append(row)
        upcomingCount += 1
      } else {
        current[row.date, default: DateSection(date: row.date)].transactions.append(row)
      }
    }
    for row in pending {
      if mode == .ledger, row.isoDate > today {
        upcoming[row.isoDate, default: DateSection(date: row.isoDate)].pending.append(row)
        upcomingCount += 1
      } else {
        current[row.isoDate, default: DateSection(date: row.isoDate)].pending.append(row)
      }
    }
    // Recurrences belong in Scheduled even when their next date is overdue.
    for row in schedules {
      upcoming[row.dateNext, default: DateSection(date: row.dateNext)].schedules.append(row)
    }
    self.inflow = inflow
    self.outflow = outflow
    currentDateSections = current.values.sorted { $0.date > $1.date }
    disclosureDateSections = upcoming.values.sorted { $0.date > $1.date }
    scheduledDisclosureCount = upcomingCount
  }
}

private struct RegisterSearchPage {
  var query = ""
  var transactions: [Transaction] = []
  var hasMore = false
  var nextOffset: Int?
  var loading = false
  var loadingMore = false
  var error: String?
}

struct RegisterView: View {
  @Environment(AppModel.self) private var model
  let scope: RegisterScope
  var categoryID: String?
  var dateRange: ClosedRange<String>?
  var accountIDs: Set<String>?

  @State private var searchText = ""
  @State private var searchPage = RegisterSearchPage()
  @State private var unclearedOnly = false
  @State private var uncategorisedOnly = false
  @State private var unapprovedOnly = false
  @State private var editingTransaction: Transaction?
  @State private var isShowingReconciliation = false
  @State private var editingAccount: Account?
  @State private var membershipsAccount: Account?
  @State private var approvalError: String?
  @State private var statusError: String?
  @State private var transactionPendingDeletion: Transaction?
  @State private var deleteError: String?
  @State private var pendingRowAction: PendingRow?
  @SceneStorage("howmuch.register.scheduledExpanded") private var expandedScheduleAccountIDs = ""
  @State private var editingSchedule: ScheduledTransaction?

  init(
    scope: RegisterScope,
    categoryID: String? = nil,
    dateRange: ClosedRange<String>? = nil,
    accountIDs: Set<String>? = nil
  ) {
    self.scope = scope
    self.categoryID = categoryID
    self.dateRange = dateRange
    self.accountIDs = accountIDs
  }

  var body: some View {
    let snapshot = RegisterSnapshot(
      transactions: visibleTransactions,
      pending: visiblePendingRows,
      schedules: visibleSchedules,
      today: Date.now.isoDateString,
      mode: showingUnapprovedQueue ? .inbox : .ledger
    )
    List {
      workingBalanceSection
      loadingOrFilterSections(snapshot)
      scheduledDisclosureSection(snapshot)
      ForEach(snapshot.currentDateSections) { section in
        dateSection(section)
      }
      searchCoverageSection(snapshot)
      emptyRegisterSection(snapshot)
      olderTransactionsErrorSection
      loadOlderTransactionsSection
    }
    .listStyle(.plain)
    .listSectionSpacing(0)
    .listSectionMargins(.vertical, 0)
    .environment(\.defaultMinListHeaderHeight, 0)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let account = scopedAccount {
        ToolbarItem(placement: .principal) {
          Button {
            editingAccount = account
          } label: {
            HStack(spacing: 6) {
              Text(account.displayIcon)
              Text(account.name)
                .font(.headline)
                .lineLimit(1)
              Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.textPrimary)
          }
          .accessibilityLabel("\(account.displayIcon) \(account.name)")
          .accessibilityHint("Opens the account editor")
        }
      }
      if showingUnapprovedQueue, let approveAllTitle = model.approveAllTitle(for: visibleTransactions) {
        ToolbarItem(placement: .topBarTrailing) {
          Button(approveAllTitle) {
            Task { await model.approveEligible(from: visibleTransactions) }
          }
          .disabled(model.isApprovalInFlight)
        }
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        registerOverflowMenu
      }
    }
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search transactions or amounts")
    .task(id: searchFetchKey) {
      await runRegisterSearch()
    }
    .refreshable {
      await model.refreshAll()
    }
    .sheet(isPresented: $isShowingReconciliation) {
      AccountReconciliationSheet(preferredAccountID: scope.accountID)
        .blocksCapturePresentation()
    }
    .sheet(item: $editingAccount) { account in
      EditAccountSheet(account: account)
        .blocksCapturePresentation()
    }
    .sheet(item: $membershipsAccount) { account in
      AccountMembershipSheet(accountID: account.id)
        .blocksCapturePresentation()
    }
    .sheet(item: $editingTransaction) { transaction in
      TransactionEditorSheet(transaction: transaction)
        .blocksCapturePresentation()
    }
    .sheet(item: $editingSchedule) { schedule in
      ScheduledTransactionEditorView(schedule: schedule)
        .blocksCapturePresentation()
    }
    .alert("Couldn’t approve transaction", isPresented: Binding(
      get: { approvalError != nil },
      set: { if !$0 { approvalError = nil } }
    )) {
      Button("OK", role: .cancel) { approvalError = nil }
    } message: {
      Text(approvalError ?? "Please try again.")
    }
    .alert("Couldn’t update status", isPresented: Binding(
      get: { statusError != nil },
      set: { if !$0 { statusError = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(statusError ?? "Refresh and try again.")
    }
    .binaryConfirm(
      "Delete this transaction?",
      presenting: $transactionPendingDeletion,
      confirm: .destructive("Delete Transaction"),
      message: { transaction in
        if let detail = transaction.deleteConfirmationDetail(
          linkedReconciled: model.hasReconciledLinkedTransfer(ids: transaction.linkedTransferIDs)
        ) {
          Text(detail)
        }
      }
    ) { transaction in
      delete(transaction)
    }
    .alert("Couldn’t delete transaction", isPresented: Binding(
      get: { deleteError != nil },
      set: { if !$0 { deleteError = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(deleteError ?? "Please try again.")
    }
    .confirmationDialog(
      "This transaction hasn’t reached the server.",
      isPresented: Binding(
        get: { pendingRowAction != nil },
        set: { if !$0 { pendingRowAction = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingRowAction
    ) { row in
      Button("Retry") {
        model.retryPending(row.id)
      }
      Button("Discard Transaction", role: .destructive) {
        model.discardPending(row.id)
      }
    }
    .task {
      switch model.scheduledTransactionsPhase {
      case .idle, .failed:
        await model.refreshScheduledTransactions()
      case .loading, .loaded:
        break
      }
    }
    .onAppear {
      if let accountID = scope.accountID {
        model.beginFocusedRegisterAccount(accountID)
      }
    }
    .onDisappear {
      if let accountID = scope.accountID {
        model.endFocusedRegisterAccount(accountID)
      }
    }
  }

  @ViewBuilder
  private var registerOverflowMenu: some View {
    if let account = scopedAccount {
      Menu {
        Button {
          editingAccount = account
        } label: {
          Label("Edit Account", systemImage: "pencil")
        }
        if !account.closed {
          Button {
            model.toggleAccountFavourite(account.id)
          } label: {
            Label(
              model.isAccountFavourite(account.id) ? "Remove from Favourites" : "Add to Favourites",
              systemImage: model.isAccountFavourite(account.id) ? "star.slash" : "star"
            )
          }
        }
        Button {
          membershipsAccount = account
        } label: {
          Label("Groups…", systemImage: "folder")
        }
        if showsRegisterFilterMenu {
          Divider()
          registerFilterMenuItems
        }
        Divider()
        reconcileMenuButton
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .accessibilityLabel("Actions for \(account.name)")
      .accessibilityHint(accountOverflowHint(account))
    } else {
      if showsRegisterFilterMenu {
        Menu {
          registerFilterMenuItems
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Register filters")
        .accessibilityHint("Review new, uncleared, or uncategorised transactions.")
      }
      if scope != .unapproved, !model.accounts.isEmpty {
        Button("Reconcile") {
          isShowingReconciliation = true
        }
        .accessibilityHint("Choose an account, statement date, and statement balance before confirming a reconciliation.")
      }
    }
  }

  private var reconcileMenuButton: some View {
    Button {
      isShowingReconciliation = true
    } label: {
      Label("Reconcile", systemImage: "checkmark.circle")
    }
    .accessibilityHint("Enter a statement date and statement balance before confirming a reconciliation.")
  }

  @ViewBuilder
  private var registerFilterMenuItems: some View {
    if scope != .unapproved, (unapprovedCount > 0 || unapprovedOnly) {
      Toggle(isOn: $unapprovedOnly) {
        Label(reviewNewMenuTitle, systemImage: "tray")
      }
      .menuActionDismissBehavior(.disabled)
    }
    if unclearedCount > 0 || unclearedOnly {
      Toggle(isOn: $unclearedOnly) {
        Label(unclearedMenuTitle, systemImage: "circle")
      }
      .menuActionDismissBehavior(.disabled)
    }
    if uncategorisedCount > 0 || uncategorisedOnly {
      Toggle(isOn: $uncategorisedOnly) {
        Label(uncategorisedMenuTitle, systemImage: "tag.slash")
      }
      .menuActionDismissBehavior(.disabled)
    }
  }

  private func accountOverflowHint(_ account: Account) -> String {
    var parts = ["Edit Account"]
    if !account.closed {
      parts.append("favourites")
    }
    if showsRegisterFilterMenu {
      parts.append("filters")
    }
    parts.append("groups")
    parts.append("reconcile")
    let head = parts.dropLast().joined(separator: ", ")
    return "\(head), and \(parts.last ?? "reconcile")."
  }

  @ViewBuilder
  private var workingBalanceSection: some View {
    if let account = scopedAccount {
      let working = account.balance
      let current = currentBalance(for: account)
      Section {
        VStack(alignment: .leading, spacing: 2) {
          Text(MoneyCodec.displayString(for: current, currencyFormat: model.currencyFormat))
            .font(.title2.weight(.bold))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(current)))
            .animation(.snappy, value: current)
            .foregroundStyle(Theme.textPrimary)
            .accessibilityLabel(headlineAccessibilityLabel(current: current, working: working))
          if current != working {
            Text("Working \(MoneyCodec.displayString(for: working, currencyFormat: model.currencyFormat)) including posted scheduled")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          Button {
            isShowingReconciliation = true
          } label: {
            Text(lastReconciledSubtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(lastReconciledSubtitle)
          .accessibilityHint("Opens reconcile.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      }
    }
  }

  @ViewBuilder
  private func loadingOrFilterSections(_ snapshot: RegisterSnapshot) -> some View {
    if model.transactions.isEmpty, model.ledgerPhase != .loaded {
      Section {
        PhasePlaceholder(phase: model.ledgerPhase) {
          await model.refreshLedger()
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      }
    } else {
      if scope != .unapproved, let summary = activeRegisterFilterSummary {
        Section {
          HStack(spacing: 8) {
            Text(summary)
              .font(.subheadline)
              .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Button("Clear") {
              withAnimation(.snappy) {
                clearRegisterFilters()
              }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Clear filters")
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .listRowInsets(EdgeInsets())
          .listRowBackground(Theme.surfaceMuted)
          .listRowSeparator(.hidden)
        }
      }
      if isNarrowed, snapshot.transactionCount > 0 {
        Section {
          totalsSummary(snapshot)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
      }
    }
  }

  @ViewBuilder
  private func dateSection(_ section: RegisterSnapshot.DateSection) -> some View {
    Section {
      ForEach(section.pending) { row in
        PendingTransactionRow(
          row: row,
          showsAccount: showsAccount,
          currencyFormat: model.currencyFormat,
          onRejectedTap: { pendingRowAction = row }
        )
        .registerRowChrome()
      }
      ForEach(section.transactions) { transaction in
        registerRow(for: transaction)
      }
      ForEach(section.schedules) { schedule in
        scheduleRow(schedule, showsNextDate: false)
      }
    } header: {
      Text(LedgerDate.friendlyString(fromISO: section.date))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.textPrimary)
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.surfaceMuted)
        .listRowInsets(EdgeInsets())
    }
    .listSectionMargins(.vertical, 0)
  }

  private func scheduleRow(_ schedule: ScheduledTransaction, showsNextDate: Bool) -> some View {
    Button {
      editingSchedule = schedule
    } label: {
      ScheduledTransactionRow(schedule: schedule, showsAccount: showsAccount, showsNextDate: showsNextDate)
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens this scheduled transaction.")
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button("Edit") {
        editingSchedule = schedule
      }
    }
    .registerRowChrome()
  }

  private func registerRow(for transaction: Transaction) -> some View {
    TransactionRow(
      transaction: transaction,
      showsAccount: showsAccount,
      currencyFormat: model.currencyFormat,
      isBusy: model.isSubmitting || model.isApprovalInFlight,
      onOpen: { editingTransaction = transaction },
      onChangeStatus: { changeStatus(transaction) }
    )
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      if !transaction.approved {
        Button {
          approve(transaction)
        } label: {
          Label("Approve", systemImage: "checkmark")
        }
        .tint(Theme.inflow)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        transactionPendingDeletion = transaction
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .tint(Theme.cancellation)
      .disabled(model.isSubmitting)
    }
    .contextMenu {
      if !transaction.approved {
        Button {
          approve(transaction)
        } label: {
          Label("Approve", systemImage: "checkmark")
        }
      }
      Button {
        editingTransaction = transaction
      } label: {
        Label("Edit", systemImage: "pencil")
      }
      Button {
        model.presentCapture(
          CaptureRequest(
            kind: .draft(TransactionDraft(duplicating: transaction)),
            connectionFingerprint: model.settings.connectionFingerprint
          )
        )
      } label: {
        Label("Duplicate for Today", systemImage: "plus.square.on.square")
      }
      Button(role: .destructive) {
        transactionPendingDeletion = transaction
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
    .registerRowChrome()
  }

  private var searchQuery: RegisterQuery? {
    RegisterQuery.parse(searchText, currencyFormat: model.currencyFormat)
  }

  private var searchFetchKey: String {
    [
      searchQuery?.raw ?? "",
      scope.accountID ?? "all",
      categoryID ?? "",
      dateRange?.lowerBound ?? "",
      dateRange?.upperBound ?? "",
      showingUnapprovedQueue ? "unapproved" : "",
      model.settings.planID,
    ].joined(separator: "|")
  }

  @ViewBuilder
  private func searchCoverageSection(_ snapshot: RegisterSnapshot) -> some View {
    if searchQuery != nil {
      Section {
        Text(
          registerSearchStatusCopy(
            shown: snapshot.transactionCount,
            scheduled: snapshot.scheduleCount,
            hasMore: searchPage.hasMore,
            loading: searchPage.loading,
            error: searchPage.error
          )
        )
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
      }
    }
  }

  @ViewBuilder
  private func emptyRegisterSection(_ snapshot: RegisterSnapshot) -> some View {
    if snapshot.isEmpty, model.ledgerPhase == .loaded, !model.isFillingHorizon {
      Section {
        Group {
          if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search
          } else if unclearedOnly || uncategorisedOnly || (unapprovedOnly && scope != .unapproved) {
            ContentUnavailableView(
              "Nothing matches",
              systemImage: "line.3.horizontal.decrease",
              description: Text(
                model.hasMoreTransactions && !showingUnapprovedQueue
                  ? "Clear the filter, or load older transactions."
                  : "Clear the filter to see transactions again."
              )
            )
          } else if scope == .unapproved {
            ContentUnavailableView("No new transactions", systemImage: "tray")
          } else if model.hasMoreTransactions {
            ContentUnavailableView(
              "No recent transactions",
              systemImage: "tray",
              description: Text("Load older transactions to see earlier activity.")
            )
          } else {
            ContentUnavailableView(
              "No Transactions",
              systemImage: "tray",
              description: Text("Transactions you add will appear here.")
            )
          }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      }
    }
  }

  @ViewBuilder
  private var olderTransactionsErrorSection: some View {
    if let error = model.olderTransactionsError {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("Couldn’t load older transactions")
            .font(.subheadline.weight(.semibold))
          Text(error)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Button("Try Again") {
            Task { await model.retryIncompleteRegisterFill() }
          }
          .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ynabCard()
        .accessibilityElement(children: .combine)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      }
    }
  }

  @ViewBuilder
  private var loadOlderTransactionsSection: some View {
    if let query = searchQuery, !showingUnapprovedQueue {
      if searchPage.hasMore || searchPage.error != nil {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            if let error = searchPage.error {
              Text("Couldn’t search older transactions")
                .font(.subheadline.weight(.semibold))
              Text(error)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Button {
              Task { await loadOlderSearchMatches(query) }
            } label: {
              HStack(spacing: 8) {
                if searchPage.loadingMore {
                  ProgressView()
                }
                Text(searchPage.loadingMore ? "Loading older matches…" : "Load older matches")
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(searchPage.loadingMore)
            .accessibilityHint("Loads the next page of older matching transactions.")
          }
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }
      }
    } else if model.hasMoreTransactions, !showingUnapprovedQueue, !model.isFillingHorizon, model.ledgerPhase == .loaded {
      Section {
        Button {
          Task { await model.loadOlderTransactions() }
        } label: {
          HStack(spacing: 8) {
            if model.isLoadingOlderTransactions {
              ProgressView()
            }
            Text(model.isLoadingOlderTransactions ? "Loading older transactions…" : "Load older transactions")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isLoadingOlderTransactions)
        .accessibilityHint("Loads the next page of older transactions into this register.")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      }
    }
  }

  private func approve(_ transaction: Transaction) {
    Task {
      do {
        try await model.approveTransaction(transaction)
      } catch {
        approvalError = error.localizedDescription
      }
    }
  }

  private func delete(_ transaction: Transaction) {
    Task {
      do {
        try await model.deleteTransaction(transaction)
      } catch {
        deleteError = error.localizedDescription
      }
    }
  }

  private var title: String {
    if categoryID != nil, let name = model.categoryName(forID: categoryID) {
      return name
    }
    switch scope {
    case .all:
      return "All Transactions"
    case .account(let id):
      return model.account(withID: id)?.name ?? "Account"
    case .unapproved:
      return "New"
    }
  }

  private func changeStatus(_ transaction: Transaction) {
    switch transaction.registerStatus.tap {
    case .approve:
      approve(transaction)
    case .toggleCleared:
      toggleCleared(transaction)
    case nil:
      return
    }
  }

  private func toggleCleared(_ transaction: Transaction) {
    Task {
      do {
        try await model.toggleTransactionCleared(transaction)
      } catch {
        statusError = error.localizedDescription
      }
    }
  }

  private var scopedAccount: Account? {
    guard let id = scope.accountID else {
      return nil
    }
    return model.account(withID: id)
  }

  private var lastReconciledSubtitle: String {
    if let date = lastReconciledISODate {
      return "Last reconciled: \(LedgerDate.friendlyString(fromISO: date))"
    }
    if model.ledgerPhase != .loaded || model.isFillingHorizon {
      return "Last reconciled: …"
    }
    return "Not reconciled yet"
  }

  private func currentBalance(for account: Account) -> Int {
    RegisterCurrent.asOfTodayBalance(
      working: account.balance,
      transactions: model.transactions,
      accountID: account.id,
      today: Date.now.isoDateString
    )
  }

  private func headlineAccessibilityLabel(current: Int, working: Int) -> String {
    let currentText = MoneyCodec.displayString(for: current, currencyFormat: model.currencyFormat)
    guard current != working else {
      return currentText
    }
    let workingText = MoneyCodec.displayString(for: working, currencyFormat: model.currencyFormat)
    return "\(currentText). Working \(workingText) including posted scheduled."
  }

  /// Prefer `last_reconciled_date` from the accounts payload. If that field is
  /// missing (older Worker) or null, use the newest loaded reconciled row so
  /// a YNAB import still shows a date.
  private var lastReconciledISODate: String? {
    if let date = scopedAccount?.lastReconciledDate, !date.isEmpty {
      return date
    }
    guard let accountID = scope.accountID else {
      return nil
    }
    return (model.transactions + model.unapprovedTransactions)
      .filter { $0.accountID == accountID && $0.cleared == .reconciled }
      .map(\.date)
      .max()
  }

  @ViewBuilder
  private func scheduledDisclosureSection(_ snapshot: RegisterSnapshot) -> some View {
    if !showingUnapprovedQueue, showsScheduledFailure, snapshot.disclosureDateSections.isEmpty {
      Section {
        Button {
          Task { await model.refreshScheduledTransactions() }
        } label: {
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Couldn’t load scheduled transactions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
              if let message = model.scheduledTransactionsPhase.errorMessage {
                Text(message)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
            Spacer()
            if model.scheduledTransactionsPhase.isLoading {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Try Again")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Theme.canvas)
        .listRowSeparator(.hidden)
        .accessibilityLabel("Couldn’t load scheduled transactions")
        .accessibilityHint("Double tap to try again.")
      }
    } else if !showingUnapprovedQueue, snapshot.scheduledDisclosureCount > 0 {
      Section {
        Button {
          withAnimation(.snappy) {
            toggleScheduledExpanded()
          }
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(isScheduledExpanded ? 90 : 0))
            Text("Scheduled")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("\(snapshot.scheduledDisclosureCount)")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Theme.canvas)
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Scheduled")
        .accessibilityValue("\(isScheduledExpanded ? "Expanded" : "Collapsed"), \(snapshot.scheduledDisclosureCount)")
        .accessibilityHint(isScheduledExpanded ? "Collapses scheduled transactions." : "Expands scheduled transactions.")
      }
      if isScheduledExpanded {
        ForEach(snapshot.disclosureDateSections) { section in
          dateSection(section)
        }
      }
    }
  }

  private var showsScheduledFailure: Bool {
    model.scheduledTransactionsPhase.errorMessage != nil
  }

  private var scheduledExpansionKey: String {
    scope.accountID ?? "all"
  }

  private var isScheduledExpanded: Bool {
    scheduledExpandedAccountIDs.contains(scheduledExpansionKey)
  }

  private var scheduledExpandedAccountIDs: Set<String> {
    Set(expandedScheduleAccountIDs.split(separator: ",", omittingEmptySubsequences: true).map(String.init))
  }

  private func toggleScheduledExpanded() {
    var ids = scheduledExpandedAccountIDs
    if ids.contains(scheduledExpansionKey) {
      ids.remove(scheduledExpansionKey)
    } else {
      ids.insert(scheduledExpansionKey)
    }
    expandedScheduleAccountIDs = ids.sorted().joined(separator: ",")
  }

  private var accountSchedules: [ScheduledTransaction] {
    model.scheduledTransactions
      .filter { schedule in
        guard !schedule.deleted else {
          return false
        }
        if let accountID = scope.accountID, schedule.accountID != accountID {
          return false
        }
        if let accountIDs, !accountIDs.isEmpty, !accountIDs.contains(schedule.accountID) {
          return false
        }
        return true
      }
      .sorted { left, right in
        if left.dateNext != right.dateNext {
          return left.dateNext < right.dateNext
        }
        return left.id < right.id
      }
  }

  private var visibleSchedules: [ScheduledTransaction] {
    if showingUnapprovedQueue || unclearedOnly || uncategorisedOnly {
      return []
    }
    return accountSchedules.filter { schedule in
      if let categoryID,
         schedule.categoryID != categoryID,
         !schedule.activeSubtransactions.contains(where: { $0.categoryID == categoryID }) {
        return false
      }
      if let dateRange, !dateRange.contains(schedule.dateNext) {
        return false
      }
      return scheduleMatchesSearch(schedule, query: searchQuery)
    }
  }

  private func scheduleMatchesSearch(_ schedule: ScheduledTransaction, query: RegisterQuery?) -> Bool {
    guard let query else {
      return true
    }
    var fields = RegisterSearchFields(
      payeeName: schedule.payeeID.flatMap { model.payee(withID: $0)?.name },
      memo: schedule.memo,
      categoryName: model.categoryName(forID: schedule.categoryID),
      accountName: model.account(withID: schedule.accountID)?.name,
      amountMilli: schedule.amount,
      lines: schedule.activeSubtransactions.map {
        RegisterSearchLine(
          payeeName: nil,
          memo: $0.memo,
          categoryName: model.categoryName(forID: $0.categoryID),
          amountMilli: $0.amount
        )
      }
    )
    if let transferAccountID = schedule.transferAccountID {
      fields.accountName = fields.accountName ?? model.account(withID: transferAccountID)?.name
      if "Transfer".localizedStandardContains(query.text) {
        return true
      }
    }
    return query.matches(fields)
  }

  private var scopedTransactions: [Transaction] {
    scoped(model.transactions)
  }

  private var approvalScopedTransactions: [Transaction] {
    scoped(model.unapprovedTransactions)
  }

  private func scoped(_ transactions: [Transaction]) -> [Transaction] {
    transactions.filter { transaction in
      if let accountID = scope.accountID, transaction.accountID != accountID {
        return false
      }
      if let accountIDs, !accountIDs.isEmpty, !accountIDs.contains(transaction.accountID) {
        return false
      }
      if let categoryID,
         transaction.categoryID != categoryID,
         !transaction.subtransactions.contains(where: { $0.categoryID == categoryID }) {
        return false
      }
      if let dateRange, !dateRange.contains(transaction.date) {
        return false
      }
      return true
    }
  }

  private var isNarrowed: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || unclearedOnly
      || uncategorisedOnly
      || showingUnapprovedQueue
      || categoryID != nil
      || dateRange != nil
      || accountIDs?.isEmpty == false
  }

  private func totalsSummary(_ snapshot: RegisterSnapshot) -> some View {
    let inflow = snapshot.inflow
    let outflow = snapshot.outflow
    let net = inflow - outflow

    return VStack(spacing: 8) {
      Text("\(snapshot.transactionCount) transaction\(snapshot.transactionCount == 1 ? "" : "s")")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        summaryColumn("Money In", MoneyCodec.displayString(for: inflow, currencyFormat: model.currencyFormat), colour: Theme.inflow)
        Spacer()
        summaryColumn("Money Out", MoneyCodec.displayString(for: outflow, currencyFormat: model.currencyFormat), colour: Theme.outflow)
        Spacer()
        summaryColumn("Net", MoneyCodec.signedDisplayString(for: net, currencyFormat: model.currencyFormat), colour: Theme.amountColour(net))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity)
    .ynabCard()
  }

  private func summaryColumn(_ label: String, _ value: String, colour: Color) -> some View {
    VStack(spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.footnote.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(colour)
    }
  }

  private var showsRegisterFilterMenu: Bool {
    (scope != .unapproved && (unapprovedCount > 0 || unapprovedOnly))
      || unclearedCount > 0 || unclearedOnly
      || uncategorisedCount > 0 || uncategorisedOnly
  }

  private var showingUnapprovedQueue: Bool {
    scope == .unapproved || unapprovedOnly
  }

  private var showsAccount: Bool {
    switch scope {
    case .all, .unapproved:
      return true
    case .account:
      return false
    }
  }

  private var reviewNewMenuTitle: String {
    unapprovedCount == 0
      ? "Review new transactions"
      : "Review \(unapprovedCount) new transaction\(unapprovedCount == 1 ? "" : "s")"
  }

  private var unclearedMenuTitle: String {
    unclearedCount == 0
      ? "Show uncleared"
      : "Show \(unclearedCount) uncleared"
  }

  private var uncategorisedMenuTitle: String {
    uncategorisedCount == 0
      ? "Show uncategorised"
      : "Show \(uncategorisedCount) uncategorised"
  }

  private var activeRegisterFilterSummary: String? {
    var parts: [String] = []
    if unapprovedOnly { parts.append("new") }
    if unclearedOnly { parts.append("uncleared") }
    if uncategorisedOnly { parts.append("uncategorised") }
    guard !parts.isEmpty else {
      return nil
    }
    if parts.count == 1 {
      switch parts[0] {
      case "new": return "Showing new transactions"
      case "uncleared": return "Showing uncleared transactions"
      default: return "Showing uncategorised transactions"
      }
    }
    return "Showing \(ListFormatter.localizedString(byJoining: parts)) transactions"
  }

  private func clearRegisterFilters() {
    unapprovedOnly = false
    unclearedOnly = false
    uncategorisedOnly = false
  }

  private var unclearedCount: Int {
    scopedTransactions.count { $0.cleared == .uncleared }
  }

  private var uncategorisedCount: Int {
    scopedTransactions.count(where: \.isUncategorised)
  }

  private var unapprovedCount: Int {
    approvalScopedTransactions.count
  }

  private var visibleTransactions: [Transaction] {
    let source = showingUnapprovedQueue ? approvalScopedTransactions : scopedTransactions
    let local = source.filter { transaction in
      if unclearedOnly, transaction.cleared != .uncleared {
        return false
      }
      if uncategorisedOnly, !transaction.isUncategorised {
        return false
      }
      if showingUnapprovedQueue, transaction.approved {
        return false
      }
      guard let query = searchQuery else {
        return true
      }
      return query.matches(transaction.registerSearchFields)
    }
    guard let query = searchQuery, !showingUnapprovedQueue else {
      return local
    }
    var merged: [String: Transaction] = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
    for hit in model.overlaying(searchPage.transactions) {
      if merged[hit.id] != nil { continue }
      if unclearedOnly, hit.cleared != .uncleared { continue }
      if uncategorisedOnly, !hit.isUncategorised { continue }
      if let accountID = scope.accountID, hit.accountID != accountID { continue }
      if let accountIDs, !accountIDs.isEmpty, !accountIDs.contains(hit.accountID) { continue }
      if let categoryID, hit.categoryID != categoryID,
         !hit.subtransactions.contains(where: { $0.categoryID == categoryID }) {
        continue
      }
      if let dateRange, !dateRange.contains(hit.date) { continue }
      if query.matches(hit.registerSearchFields) {
        merged[hit.id] = hit
      }
    }
    return merged.values.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
  }

  private var scopedPendingRows: [PendingRow] {
    model.pendingRows.filter { row in
      if let accountID = scope.accountID, row.accountID != accountID {
        return false
      }
      if let accountIDs, !accountIDs.isEmpty, !accountIDs.contains(row.accountID) {
        return false
      }
      if let categoryID, !row.matches(categoryID: categoryID) {
        return false
      }
      if let dateRange, !dateRange.contains(row.isoDate) {
        return false
      }
      return true
    }
  }

  private var visiblePendingRows: [PendingRow] {
    return scopedPendingRows.filter { row in
      if showingUnapprovedQueue {
        return false
      }
      if unclearedOnly, row.isCleared {
        return false
      }
      if uncategorisedOnly, row.categoryID != nil || row.splitLineCount > 0 {
        return false
      }
      guard let query = searchQuery else {
        return true
      }
      return query.matches(row.registerSearchFields)
    }
  }

  private func runRegisterSearch() async {
    guard let query = searchQuery, !showingUnapprovedQueue else {
      searchPage = RegisterSearchPage()
      return
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    guard !Task.isCancelled else {
      return
    }
    await fetchSearchPage(query: query, offset: 0, replacing: true)
  }

  private func loadOlderSearchMatches(_ query: RegisterQuery) async {
    guard let offset = searchPage.nextOffset, searchPage.hasMore else {
      return
    }
    await fetchSearchPage(query: query, offset: offset, replacing: false)
  }

  private func fetchSearchPage(query: RegisterQuery, offset: Int, replacing: Bool) async {
    if replacing {
      searchPage.loading = true
      searchPage.error = nil
    } else {
      searchPage.loadingMore = true
      searchPage.error = nil
    }
    do {
      let page = try await model.apiClient.fetchTransactions(
        planID: model.settings.planID,
        accountID: scope.accountID,
        offset: offset,
        sinceDate: dateRange?.lowerBound,
        untilDate: dateRange?.upperBound,
        q: query.raw
      )
      guard !Task.isCancelled else {
        return
      }
      if replacing {
        searchPage.transactions = page.transactions
      } else {
        let existing = Set(searchPage.transactions.map(\.id))
        searchPage.transactions.append(contentsOf: page.transactions.filter { !existing.contains($0.id) })
      }
      searchPage.query = query.raw
      searchPage.hasMore = page.hasMore
      searchPage.nextOffset = page.nextOffset
      searchPage.loading = false
      searchPage.loadingMore = false
      searchPage.error = nil
    } catch {
      guard !Task.isCancelled else {
        return
      }
      searchPage.loading = false
      searchPage.loadingMore = false
      searchPage.error = error.localizedDescription
      if replacing {
        searchPage.hasMore = true
      }
    }
  }
}

private struct AccountReconciliationSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var accountID: String
  @State private var statementDate: String
  @State private var statementBalanceText: String
  @State private var preview: AccountReconciliationPreview?
  @State private var isLoadingPreview = false
  @State private var previewError: String?
  @State private var previewGeneration = 0
  @State private var confirmationChecked = false
  @State private var mismatch: ReconciliationMismatchDetail?
  @State private var errorMessage: String?
  @State private var operationSeed: String

  init(preferredAccountID: String?) {
    _accountID = State(initialValue: preferredAccountID ?? "")
    _statementDate = State(initialValue: Date.now.isoDateString)
    _statementBalanceText = State(initialValue: "")
    _operationSeed = State(initialValue: UUID().uuidString.lowercased())
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Statement") {
          Picker("Account", selection: Binding(get: { accountID }, set: { value in
            markEdited(refreshingPreview: true) {
              accountID = value
            }
          })) {
            Text("Choose account").tag("")
            ForEach(model.accounts.sorted(by: accountSort), id: \.id) { account in
              Text(account.closed ? "\(account.name) (Closed)" : account.name).tag(account.id)
            }
          }
          DatePicker(
            "Statement date",
            selection: Binding(
              get: { Date(isoDateString: statementDate) ?? .now },
              set: { updateStatementDate($0.isoDateString) }
            ),
            displayedComponents: .date
          )
          TextField("Statement balance", text: Binding(get: { statementBalanceText }, set: { value in
            markEdited {
              statementBalanceText = value
            }
          }))
            .keyboardType(.decimalPad)
            .textInputAutocapitalization(.never)
          Text("Enter the exact currency balance shown on your statement, for example 123.45.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section {
          Text("Every cleared transaction dated on or before \(LedgerDate.friendlyString(fromISO: statementDate)) becomes reconciled. Uncleared transactions and later cleared transactions stay unchanged.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section("Review") {
          if isLoadingPreview {
            HStack(spacing: 10) {
              ProgressView()
              Text("Checking cleared transactions…")
                .foregroundStyle(.secondary)
            }
          } else if let preview {
            LabeledContent("Account", value: selectedAccount?.name ?? "Choose account")
            LabeledContent("Statement date", value: LedgerDate.friendlyString(fromISO: statementDate))
            LabeledContent("Current reconciled", value: MoneyCodec.signedDisplayString(for: preview.currentReconciledBalance, currencyFormat: model.currencyFormat))
            LabeledContent("Cleared to add", value: MoneyCodec.signedDisplayString(for: preview.projectedReconciledBalance - preview.currentReconciledBalance, currencyFormat: model.currencyFormat))
            LabeledContent("Projected balance", value: MoneyCodec.signedDisplayString(for: preview.projectedReconciledBalance, currencyFormat: model.currencyFormat))
            LabeledContent("Cleared candidates", value: "\(preview.candidateTransactionCount)")
            LabeledContent("Statement balance", value: reviewBalanceText)
            LabeledContent("Difference", value: reviewDifferenceText)
              .foregroundStyle(isPreviewExact ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.outflow))
            Toggle(isOn: $confirmationChecked) {
              Text("I understand that cleared transactions through this date will be locked in as reconciled.")
                .font(.subheadline)
            }
            .disabled(!isPreviewExact)
            if !isPreviewExact {
              Text(reviewRequirement)
                .font(.footnote)
                .foregroundStyle(Theme.outflow)
            }
            Button("Refresh review") {
              Task { await fetchPreview() }
            }
            .disabled(model.isSubmitting)
          } else {
            Text(previewError ?? "Choose an account and statement date to load the server reconciliation review.")
              .font(.footnote)
              .foregroundStyle(previewError == nil ? .secondary : Theme.outflow)
            Button("Review reconciliation") {
              Task { await fetchPreview() }
            }
            .disabled(accountID.isEmpty || isLoadingPreview || model.isSubmitting)
          }
        }

        if let mismatch {
          Section("Mismatch") {
            Text("Dismiss this sheet or update the statement details, then correct cleared transactions on or before \(LedgerDate.friendlyString(fromISO: statementDate)) before trying again.")
              .font(.footnote)
              .foregroundStyle(.secondary)
            LabeledContent("Already reconciled", value: MoneyCodec.displayString(for: mismatch.currentReconciledBalance, currencyFormat: model.currencyFormat))
            LabeledContent("Projected after this reconciliation", value: MoneyCodec.signedDisplayString(for: mismatch.projectedReconciledBalance, currencyFormat: model.currencyFormat))
            LabeledContent("Statement balance", value: MoneyCodec.signedDisplayString(for: mismatch.statementBalance, currencyFormat: model.currencyFormat))
            LabeledContent("Off by", value: MoneyCodec.signedDisplayString(for: mismatch.difference, currencyFormat: model.currencyFormat))
              .foregroundStyle(mismatch.difference == 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.outflow))
          }
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .font(.footnote)
              .foregroundStyle(Theme.outflow)
          }
        }

        Section {
          Button(model.isSubmitting ? "Reconciling…" : "Confirm reconciliation") {
            Task { await confirm() }
          }
          .disabled(model.isSubmitting || !confirmationChecked || !isPreviewExact)
        }
      }
      .navigationTitle("Reconcile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(model.isSubmitting)
        }
      }
      .task(id: reconcilePreviewInvalidationKey) {
        await fetchPreview()
      }
    }
  }

  private var selectedAccount: Account? {
    model.accounts.first { $0.id == accountID }
  }

  private var reviewBalanceText: String {
    let amount = MoneyCodec.milliunits(from: statementBalanceText) ?? 0
    return MoneyCodec.signedDisplayString(for: amount, currencyFormat: model.currencyFormat)
  }

  private var reviewDifference: Int? {
    guard let preview, let statementBalance = MoneyCodec.milliunits(from: statementBalanceText) else {
      return nil
    }
    return statementBalance - preview.projectedReconciledBalance
  }

  private var reviewDifferenceText: String {
    guard let reviewDifference else { return "Enter statement balance" }
    return MoneyCodec.signedDisplayString(for: reviewDifference, currencyFormat: model.currencyFormat)
  }

  private var isPreviewExact: Bool {
    preview != nil && !isLoadingPreview && previewError == nil && reviewDifference == 0
  }

  private var reviewRequirement: String {
    if MoneyCodec.milliunits(from: statementBalanceText) == nil {
      return "Enter a statement balance with no more than three decimal places."
    }
    return "The statement balance must exactly match the projected balance before confirmation."
  }

  private var reconcilePreviewInvalidationKey: String {
    var hasher = Hasher()
    hasher.combine(accountID)
    hasher.combine(statementDate)
    for transaction in model.transactions where transaction.accountID == accountID {
      hasher.combine(transaction.id)
      hasher.combine(transaction.date)
      hasher.combine(transaction.amount)
      hasher.combine(transaction.cleared)
      hasher.combine(transaction.deleted)
    }
    return String(hasher.finalize())
  }

  private func updateStatementDate(_ value: String) {
    markEdited(refreshingPreview: true) {
      statementDate = value
    }
  }

  private func markEdited(refreshingPreview: Bool = false, _ updates: () -> Void) {
    updates()
    if refreshingPreview {
      preview = nil
      previewError = nil
    }
    confirmationChecked = false
    mismatch = nil
    errorMessage = nil
  }

  private func fetchPreview() async {
    guard !accountID.isEmpty else {
      preview = nil
      previewError = nil
      return
    }
    guard Date(isoDateString: statementDate) != nil else {
      preview = nil
      previewError = "Choose a valid statement date."
      return
    }
    previewGeneration &+= 1
    let generation = previewGeneration
    let requestedAccountID = accountID
    let requestedStatementDate = statementDate
    isLoadingPreview = true
    previewError = nil
    defer {
      if generation == previewGeneration {
        isLoadingPreview = false
      }
    }

    do {
      let response = try await model.fetchAccountReconciliation(
        accountID: requestedAccountID,
        statementDate: requestedStatementDate
      )
      guard generation == previewGeneration,
            requestedAccountID == accountID,
            requestedStatementDate == statementDate else {
        return
      }
      preview = response
    } catch {
      guard generation == previewGeneration else { return }
      preview = nil
      previewError = error.localizedDescription
    }
  }

  private func confirm() async {
    guard isPreviewExact, confirmationChecked else {
      errorMessage = "Wait for an exact server review, then confirm the reconciliation."
      return
    }
    guard let statementBalance = MoneyCodec.milliunits(from: statementBalanceText) else {
      errorMessage = "Enter the exact statement balance with no more than three decimal places."
      return
    }

    do {
      _ = try await model.reconcileAccount(
        accountID: accountID,
        statementDate: statementDate,
        statementBalance: statementBalance,
        idempotencyKey: reconciliationKey(accountID: accountID, statementDate: statementDate, statementBalance: statementBalance)
      )
      dismiss()
    } catch let error as APIClientError {
      switch error {
      case .reconciliationMismatch(let detail):
        mismatch = detail
        errorMessage = nil
        confirmationChecked = false
        await fetchPreview()
      default:
        errorMessage = error.localizedDescription
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func reconciliationKey(accountID: String, statementDate: String, statementBalance: Int) -> String {
    "reconcile-\(operationSeed)-\(stableHash("\(accountID):\(statementDate):\(statementBalance)"))"
  }

  private func stableHash(_ value: String) -> String {
    var hash: UInt32 = 2166136261
    for byte in value.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16777619
    }
    return String(hash, radix: 36)
  }

  private func accountSort(_ left: Account, _ right: Account) -> Bool {
    if left.closed != right.closed {
      return !left.closed && right.closed
    }
    return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
  }
}

enum RegisterStatus: Equatable {
  case new
  case uncleared
  case cleared
  case reconciled

  enum Tap: Equatable {
    case approve
    case toggleCleared
  }

  init(approved: Bool, cleared: ClearedState) {
    if !approved {
      self = .new
      return
    }
    switch cleared {
    case .reconciled:
      self = .reconciled
    case .cleared:
      self = .cleared
    case .uncleared:
      self = .uncleared
    }
  }

  var tap: Tap? {
    switch self {
    case .new:
      return .approve
    case .uncleared, .cleared:
      return .toggleCleared
    case .reconciled:
      return nil
    }
  }
}

extension Transaction {
  var registerStatus: RegisterStatus {
    RegisterStatus(approved: approved, cleared: cleared)
  }
}

private struct PendingTransactionRow: View {
  let row: PendingRow
  let showsAccount: Bool
  let currencyFormat: CurrencyFormat?
  let onRejectedTap: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(payeeDisplay)
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
          Text(detailLine)
            .font(.footnote)
            .foregroundStyle(row.categoryID == nil && row.splitLineCount == 0 ? AnyShapeStyle(Theme.uncategorised) : AnyShapeStyle(.secondary))
            .lineLimit(1)
          if let memo = row.memo, !memo.isEmpty {
            Text(memo)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }

        Spacer()

        Text(MoneyCodec.signedDisplayString(for: row.signedAmount, currencyFormat: currencyFormat))
          .font(.subheadline.weight(.medium))
          .monospacedDigit()
          .foregroundStyle(Theme.registerAmountColour(row.signedAmount))
      }
      .contentShape(Rectangle())
      .frame(maxWidth: .infinity, alignment: .leading)
      .onTapGesture {
        if case .rejected = row.status {
          onRejectedTap()
        }
      }

      statusGlyph
    }
    .padding(.leading, 16)
    .padding(.trailing, 8)
    .padding(.vertical, 10)
    .flagRail(Theme.flagColour(named: row.flag.rawValue))
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(rejectedHint)
  }

  private var payeeDisplay: String {
    if let payee = row.payeeName, !payee.isEmpty {
      return payee
    }
    return "(No payee)"
  }

  private var detailLine: String {
    let category: String
    if row.splitLineCount > 0 {
      category = "Split (\(row.splitLineCount))"
    } else if let name = row.categoryName {
      category = name
    } else {
      category = "Uncategorised"
    }
    if showsAccount, !row.accountName.isEmpty {
      return "\(category) · \(row.accountName)"
    }
    return category
  }

  @ViewBuilder
  private var statusGlyph: some View {
    Group {
      switch row.status {
      case .sending:
        ProgressView()
          .controlSize(.small)
      case .waitingForConnection:
        Image(systemName: "clock")
          .font(.title3)
          .foregroundStyle(.tertiary)
      case .rejected:
        Image(systemName: "exclamationmark.circle")
          .font(.title3)
          .foregroundStyle(Theme.outflow)
      }
    }
    .frame(width: 44, height: 44)
  }

  private var accessibilityLabel: String {
    switch row.status {
    case .sending:
      return "Sending \(payeeDisplay)"
    case .waitingForConnection:
      return "\(payeeDisplay) waiting to sync"
    case .rejected:
      return "\(payeeDisplay) failed to sync"
    }
  }

  private var rejectedHint: String {
    if case .rejected = row.status {
      return "Double tap to retry or discard."
    }
    return ""
  }
}

struct TransactionRow: View {
  let transaction: Transaction
  let showsAccount: Bool
  let currencyFormat: CurrencyFormat?
  let isBusy: Bool
  let onOpen: () -> Void
  let onChangeStatus: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      Button(action: onOpen) {
        HStack(alignment: .center, spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Text(payeeDisplay)
              .font(.body.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
              .lineLimit(1)
            Text(detailLine)
              .font(.footnote)
              .foregroundStyle(transaction.isUncategorised ? AnyShapeStyle(Theme.uncategorised) : AnyShapeStyle(.secondary))
              .lineLimit(1)
            if let memo = transaction.memo, !memo.isEmpty {
              Text(memo)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }

          Spacer()

          Text(MoneyCodec.signedDisplayString(for: transaction.amount, currencyFormat: currencyFormat))
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(Theme.registerAmountColour(transaction.amount))
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .accessibilityHint("Opens this transaction.")

      statusControl
    }
    .padding(.leading, 16)
    .padding(.trailing, 8)
    .padding(.vertical, 10)
    .flagRail(Theme.flagColour(named: transaction.flagColor))
    .contentShape(Rectangle())
  }

  private var payeeDisplay: String {
    if let payee = transaction.payeeName, !payee.isEmpty {
      return payee
    }
    return transaction.transferAccountID != nil ? "Transfer" : "(No payee)"
  }

  private var detailLine: String {
    let category: String
    if transaction.isSplit {
      category = "Split (\(transaction.subtransactions.count))"
    } else if let name = transaction.categoryName {
      category = name
    } else if transaction.transferAccountID != nil {
      category = "Transfer"
    } else {
      category = "Uncategorised"
    }
    if showsAccount {
      return "\(category) · \(transaction.accountName)"
    }
    return category
  }

  @ViewBuilder
  private var statusControl: some View {
    let status = transaction.registerStatus
    switch status.tap {
    case nil:
      statusIcon(status)
        .accessibilityLabel(statusAccessibilityLabel(status))
    case .approve, .toggleCleared:
      statusIcon(status)
        .contentShape(Rectangle())
        .onTapGesture {
          if !isBusy {
            onChangeStatus()
          }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(statusAccessibilityLabel(status))
        .accessibilityHint("Double tap to change this transaction’s status.")
    }
  }

  private func statusIcon(_ status: RegisterStatus) -> some View {
    statusGlyph(status)
      .frame(width: 44, height: 44)
  }

  @ViewBuilder
  private func statusGlyph(_ status: RegisterStatus) -> some View {
    switch status {
    case .new:
      Image(systemName: "circle.fill")
        .font(.title3)
        .foregroundStyle(Theme.newStatus)
    case .uncleared:
      Image(systemName: "checkmark.circle")
        .font(.title3)
        .foregroundStyle(.tertiary)
    case .cleared:
      Image(systemName: "checkmark.circle.fill")
        .font(.title3)
        .foregroundStyle(Theme.inflow)
    case .reconciled:
      Image(systemName: "lock.fill")
        .font(.caption)
        .foregroundStyle(Theme.inflow)
    }
  }

  private func statusAccessibilityLabel(_ status: RegisterStatus) -> String {
    switch status {
    case .new:
      return "Approve \(payeeDisplay)"
    case .uncleared:
      return "Mark \(payeeDisplay) cleared"
    case .cleared:
      return "Mark \(payeeDisplay) uncleared"
    case .reconciled:
      return "Reconciled"
    }
  }
}

private extension View {
  func registerRowChrome() -> some View {
    listRowInsets(EdgeInsets())
      .listRowBackground(Theme.card)
      .listRowSeparator(.hidden)
  }
}
