import SwiftUI

struct RecentTransactionsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Group {
      if model.recentTransactions.isEmpty {
        ContentUnavailableView(
          "No transactions yet",
          systemImage: "tray",
          description: Text("Import or create a transaction, then pull to refresh.")
        )
      } else {
        List(model.recentTransactions) { transaction in
          TransactionRow(transaction: transaction, currencyFormat: model.planSettings?.currencyFormat)
        }
        .listStyle(.plain)
      }
    }
    .navigationTitle("Recent")
    .refreshable {
      await model.refreshRecentTransactions()
    }
  }
}

private struct TransactionRow: View {
  let transaction: Transaction
  let currencyFormat: CurrencyFormat?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(transaction.payeeName ?? "Unknown payee")
          .font(.headline)
        Spacer()
        Text(MoneyCodec.displayString(for: transaction.amount, currencyFormat: currencyFormat))
          .font(.headline.monospacedDigit())
          .foregroundStyle(transaction.amount < 0 ? .red : .green)
      }

      HStack {
        Text(transaction.accountName)
        if let category = transaction.categoryName {
          Text(category)
        }
        Spacer()
        Text(transaction.date)
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)

      if let memo = transaction.memo, !memo.isEmpty {
        Text(memo)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 12) {
        Text(transaction.cleared.title)
        if let flag = transaction.flagColor, !flag.isEmpty {
          Text(flag.capitalized)
        }
      }
      .font(.caption)
      .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 6)
  }
}
