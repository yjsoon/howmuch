import SwiftUI

struct RecentTransactionsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Group {
      if model.recentTransactions.isEmpty {
        emptyState
      } else {
        transactionList
      }
    }
    .navigationTitle("Recents")
    .refreshable {
      await model.refreshRecentTransactions()
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    if model.recentsPhase.isLoading {
      ProgressView("Loading transactions…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let message = model.recentsPhase.errorMessage {
      ContentUnavailableView {
        Label("Cannot load transactions", systemImage: "wifi.exclamationmark")
      } description: {
        Text(message)
      } actions: {
        Button("Try again") {
          Task { await model.refreshRecentTransactions() }
        }
        .buttonStyle(.bordered)
        Button("Check settings") {
          model.isShowingSettings = true
        }
      }
    } else {
      ContentUnavailableView {
        Label("No transactions yet", systemImage: "tray")
      } description: {
        Text("Capture a spend from the first tab, or import history on the server, then pull to refresh.")
      }
    }
  }

  private var transactionList: some View {
    List {
      ForEach(groupedByDate, id: \.date) { group in
        Section {
          ForEach(group.transactions) { transaction in
            TransactionRow(transaction: transaction, currencyFormat: model.currencyFormat)
          }
        } header: {
          HStack {
            Text(LedgerDate.friendlyString(fromISO: group.date))
            Spacer()
            Text(MoneyCodec.signedDisplayString(for: group.total, currencyFormat: model.currencyFormat))
              .monospacedDigit()
          }
        }
      }
    }
    .listStyle(.grouped)
  }

  private var groupedByDate: [(date: String, total: Int, transactions: [Transaction])] {
    let groups = Dictionary(grouping: model.recentTransactions, by: \.date)
    return groups.keys.sorted(by: >).map { date in
      let transactions = groups[date] ?? []
      return (date: date, total: transactions.reduce(0) { $0 + $1.amount }, transactions: transactions)
    }
  }
}

private struct TransactionRow: View {
  let transaction: Transaction
  let currencyFormat: CurrencyFormat?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if let flag = Theme.flagColour(named: transaction.flagColor) {
          Image(systemName: "flag.fill")
            .font(.caption2)
            .foregroundStyle(flag)
        }

        Text(transaction.payeeName ?? "Unknown payee")
          .font(.body.weight(.medium))
          .lineLimit(1)

        Spacer(minLength: 12)

        Text(MoneyCodec.signedDisplayString(for: transaction.amount, currencyFormat: currencyFormat))
          .font(.body.weight(.semibold).monospacedDigit())
          .foregroundStyle(Theme.amountColour(transaction.amount))
      }

      HStack(spacing: 4) {
        Text(transaction.categoryName ?? "Uncategorised")
          .foregroundStyle(transaction.categoryName == nil ? .tertiary : .secondary)
        Text("·")
          .foregroundStyle(.tertiary)
        Text(transaction.accountName)
          .foregroundStyle(.secondary)

        Spacer(minLength: 12)

        if transaction.cleared == .uncleared {
          Text("Uncleared")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(.tertiarySystemFill)))
            .foregroundStyle(.secondary)
        }
      }
      .font(.subheadline)
      .lineLimit(1)

      if let memo = transaction.memo, !memo.isEmpty {
        Text(memo)
          .font(.footnote)
          .foregroundStyle(.tertiary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 2)
  }
}
