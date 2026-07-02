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
  @State private var editingTransaction: Transaction?

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
              ForEach(Array(section.transactions.enumerated()), id: \.element.id) { index, transaction in
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

                if index < section.transactions.count - 1 {
                  Divider().padding(.leading, 16)
                }
              }
            }
            .ynabCard()
          }
        }

        if visibleTransactions.isEmpty, model.ledgerPhase == .loaded {
          VStack(spacing: 8) {
            Image(systemName: "tray")
              .font(.title2)
              .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No transactions yet." : "No matches for “\(searchText)”.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 40)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .background(Theme.canvas)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search Transactions")
    .refreshable {
      await model.refreshAll()
    }
    .sheet(item: $editingTransaction) { transaction in
      TransactionEditorSheet(transaction: transaction)
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
    model.transactions.filter { transaction in
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
    scopedTransactions.filter { $0.cleared == .uncleared }.count
  }

  private var uncategorisedCount: Int {
    scopedTransactions.filter(\.isUncategorised).count
  }

  private var visibleTransactions: [Transaction] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return scopedTransactions.filter { transaction in
      if unclearedOnly, transaction.cleared != .uncleared {
        return false
      }
      if uncategorisedOnly, !transaction.isUncategorised {
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
      return haystack.contains { $0?.lowercased().contains(query) == true }
    }
  }

  private var sections: [(date: String, transactions: [Transaction])] {
    let grouped = Dictionary(grouping: visibleTransactions, by: \.date)
    return grouped.keys.sorted(by: >).map { date in
      (date: date, transactions: grouped[date] ?? [])
    }
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
        .font(.caption2)
        .foregroundStyle(Theme.inflow)
    case .cleared:
      Image(systemName: "c.circle.fill")
        .font(.footnote)
        .foregroundStyle(Theme.inflow)
    case .uncleared:
      Image(systemName: "c.circle")
        .font(.footnote)
        .foregroundStyle(.tertiary)
    }
  }
}
