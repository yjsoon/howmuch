import SwiftUI

enum RegisterScope: Hashable {
  case all
  case account(String)

  var accountID: String? {
    if case .account(let id) = self {
      return id
    }
    return nil
  }
}

struct RegisterView: View {
  @Environment(AppModel.self) private var model
  let scope: RegisterScope
  /// Optional pre-filter, used when drilling in from a Reflect category row.
  var categoryID: String?
  var dateRange: ClosedRange<String>?
  /// Optional account scoping carried through from a report's account filter.
  var accountIDs: Set<String>?

  @State private var searchText = ""
  @State private var unclearedOnly = false
  @State private var uncategorisedOnly = false
  @State private var unapprovedOnly = false
  @State private var editingTransaction: Transaction?
  @State private var duplicatingDraft: DuplicateDraft?
  @State private var isShowingReconciliation = false
  @State private var approvalError: String?

  /// Identifiable box so sheet(item:) can present a prefilled capture form.
  private struct DuplicateDraft: Identifiable {
    let id = UUID()
    let draft: TransactionDraft
  }

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
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        if let account = scopedAccount {
          VStack(spacing: 2) {
            Text(MoneyCodec.displayString(for: account.balance, currencyFormat: model.currencyFormat))
              .font(.title2.weight(.bold))
              .monospacedDigit()
              .contentTransition(.numericText(value: Double(account.balance)))
              .animation(.snappy, value: account.balance)
              .foregroundStyle(Theme.amountColour(account.balance))
            Text("Working Balance")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity)
          .padding(.top, 4)
        }

        if model.transactions.isEmpty, model.ledgerPhase != .loaded {
          PhasePlaceholder(phase: model.ledgerPhase) {
            await model.refreshLedger()
          }
        } else {
          if unapprovedCount > 0 || unapprovedOnly {
            filterBanner(
              isOn: $unapprovedOnly,
              offLabel: "Review \(unapprovedCount) new transaction\(unapprovedCount == 1 ? "" : "s")",
              onLabel: "Showing new transactions to approve"
            )
          }
          if unclearedCount > 0 || unclearedOnly {
            filterBanner(
              isOn: $unclearedOnly,
              offLabel: "Show \(unclearedCount) uncleared transactions",
              onLabel: "Showing uncleared only"
            )
          }
          if uncategorisedCount > 0 || uncategorisedOnly {
            filterBanner(
              isOn: $uncategorisedOnly,
              offLabel: "Show \(uncategorisedCount) uncategorised transactions",
              onLabel: "Showing uncategorised only"
            )
          }
          if isNarrowed, !visibleTransactions.isEmpty {
            totalsSummary
          }
        }

        ForEach(sections, id: \.date) { section in
          VStack(alignment: .leading, spacing: 6) {
            Text(LedgerDate.friendlyString(fromISO: section.date))
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 4)

            VStack(spacing: 0) {
              ForEach(section.transactions.enumerated(), id: \.element.id) { index, transaction in
                Button {
                  editingTransaction = transaction
                } label: {
                  TransactionRow(
                    transaction: transaction,
                    showsAccount: scope == .all,
                    currencyFormat: model.currencyFormat
                  )
                }
                .buttonStyle(.plain)
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
                    duplicatingDraft = DuplicateDraft(draft: TransactionDraft(duplicating: transaction))
                  } label: {
                    Label("Duplicate for Today", systemImage: "plus.square.on.square")
                  }
                }

                if index < section.transactions.count - 1 {
                  Divider().padding(.leading, 16)
                }
              }
            }
            .ynabCard()
          }
        }

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("Searches the \(model.transactions.count) transactions loaded on this device.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Searches the \(model.transactions.count) transactions loaded on this device. Load older transactions to extend the search.")
        }

        if visibleTransactions.isEmpty, model.ledgerPhase == .loaded {
          if searchText.isEmpty {
            ContentUnavailableView(
              "No Transactions",
              systemImage: "tray",
              description: Text("Transactions you add or import will appear here.")
            )
          } else {
            ContentUnavailableView.search
          }
        }

        if let error = model.olderTransactionsError {
          VStack(alignment: .leading, spacing: 8) {
            Text("Couldn’t load older transactions")
              .font(.subheadline.weight(.semibold))
            Text(error)
              .font(.footnote)
              .foregroundStyle(.secondary)
            Button("Try Again") {
              Task { await model.loadOlderTransactions() }
            }
            .buttonStyle(.bordered)
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .ynabCard()
          .accessibilityElement(children: .combine)
        }

        if model.hasMoreTransactions {
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
          .accessibilityHint("Loads the next 100 older transactions into this register.")
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .background(Theme.canvas)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if !model.accounts.isEmpty {
          Button("Reconcile") {
            isShowingReconciliation = true
          }
          .accessibilityHint("Choose an account, statement date, and statement balance before confirming a reconciliation.")
        }
      }
    }
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search Transactions")
    .refreshable {
      await model.refreshAll()
    }
    .sheet(isPresented: $isShowingReconciliation) {
      AccountReconciliationSheet(preferredAccountID: scope.accountID)
    }
    .sheet(item: $editingTransaction) { transaction in
      TransactionEditorSheet(transaction: transaction)
    }
    .sheet(item: $duplicatingDraft) { duplicate in
      TransactionFormView(draft: duplicate.draft, isEditing: false)
    }
    .alert("Couldn’t approve transaction", isPresented: Binding(
      get: { approvalError != nil },
      set: { if !$0 { approvalError = nil } }
    )) {
      Button("OK", role: .cancel) { approvalError = nil }
    } message: {
      Text(approvalError ?? "Please try again.")
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

  private var title: String {
    if categoryID != nil, let name = model.categoryName(forID: categoryID) {
      return name
    }
    switch scope {
    case .all:
      return "All Transactions"
    case .account(let id):
      return model.account(withID: id)?.name ?? "Account"
    }
  }

  private var scopedAccount: Account? {
    guard let id = scope.accountID else {
      return nil
    }
    return model.account(withID: id)
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
      // A split matches when any of its lines carries the category, as on the web.
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

  /// True whenever the visible rows are a deliberate slice of the register —
  /// a search, a filter banner, or a report drill-down.
  private var isNarrowed: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || unclearedOnly
      || uncategorisedOnly
      || unapprovedOnly
      || categoryID != nil
      || dateRange != nil
      || accountIDs?.isEmpty == false
  }

  /// Money in / money out / net across the visible rows, as in the web
  /// register header.
  private var totalsSummary: some View {
    let rows = visibleTransactions
    let inflow = rows.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
    let outflow = rows.filter { $0.amount < 0 }.reduce(0) { $0 + abs($1.amount) }
    let net = inflow - outflow

    return VStack(spacing: 8) {
      Text("\(rows.count) transaction\(rows.count == 1 ? "" : "s")")
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

  private func filterBanner(isOn: Binding<Bool>, offLabel: String, onLabel: String) -> some View {
    Button {
      withAnimation(.snappy) {
        isOn.wrappedValue.toggle()
      }
    } label: {
      HStack {
        Text(isOn.wrappedValue ? onLabel : offLabel)
          .font(.subheadline)
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        Image(systemName: isOn.wrappedValue ? "xmark.circle.fill" : "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .ynabCard()
    }
    .buttonStyle(.plain)
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
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = unapprovedOnly ? approvalScopedTransactions : scopedTransactions
    return source.filter { transaction in
      if unclearedOnly, transaction.cleared != .uncleared {
        return false
      }
      if uncategorisedOnly, !transaction.isUncategorised {
        return false
      }
      if unapprovedOnly, transaction.approved {
        return false
      }
      guard !query.isEmpty else {
        return true
      }
      let haystack = [
        transaction.payeeName,
        transaction.categoryName,
        transaction.memo,
        transaction.accountName,
      ]
      return haystack.contains { $0?.localizedStandardContains(query) == true }
    }
  }

  private var sections: [(date: String, transactions: [Transaction])] {
    let grouped = Dictionary(grouping: visibleTransactions, by: \.date)
    return grouped.keys.sorted(by: >).map { date in
      (date: date, transactions: grouped[date] ?? [])
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

struct TransactionRow: View {
  let transaction: Transaction
  let showsAccount: Bool
  let currencyFormat: CurrencyFormat?

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      if let flag = Theme.flagColour(named: transaction.flagColor) {
        RoundedRectangle(cornerRadius: 2)
          .fill(flag)
          .frame(width: 4, height: 34)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(payeeDisplay)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Theme.textPrimary)
          .lineLimit(1)
        Text(detailLine)
          .font(.footnote)
          .foregroundStyle(transaction.isUncategorised ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
          .lineLimit(1)
        if let memo = transaction.memo, !memo.isEmpty {
          Text(memo)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
      }

      Spacer()

      HStack(spacing: 6) {
        if !transaction.approved {
          Text("New")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.accent, in: Capsule())
            .accessibilityLabel("Needs approval")
        }
        Text(MoneyCodec.signedDisplayString(for: transaction.amount, currencyFormat: currencyFormat))
          .font(.subheadline.weight(.medium))
          .monospacedDigit()
          .foregroundStyle(Theme.registerAmountColour(transaction.amount))
        clearedBadge
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
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
  private var clearedBadge: some View {
    switch transaction.cleared {
    case .reconciled:
      Image(systemName: "lock.fill")
        .font(.caption)
        .foregroundStyle(Theme.inflow)
        .accessibilityLabel("Reconciled")
    case .cleared:
      Image(systemName: "c.circle.fill")
        .font(.footnote)
        .foregroundStyle(Theme.inflow)
        .accessibilityLabel("Cleared")
    case .uncleared:
      Image(systemName: "c.circle")
        .font(.footnote)
        .foregroundStyle(.tertiary)
        .accessibilityLabel("Uncleared")
    }
  }
}
