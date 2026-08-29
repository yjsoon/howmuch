import SwiftUI

struct ScheduledTransactionsView: View {
  @Environment(AppModel.self) private var model
  @State private var editingSchedule: ScheduledTransaction?
  @State private var isCreatingSchedule = false

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        if model.scheduledTransactions.isEmpty, model.scheduledTransactionsPhase != .loaded {
          PhasePlaceholder(phase: model.scheduledTransactionsPhase) {
            await model.refreshScheduledTransactions()
          }
        } else if model.scheduledTransactions.isEmpty {
          ContentUnavailableView(
            "No Scheduled Transactions",
            systemImage: "calendar",
            description: Text("Recurring and scheduled transactions will appear here.")
          )
          .padding(.top, 72)
        } else {
          Text("Upcoming transactions")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

          ForEach(sections, id: \.date) { section in
            VStack(alignment: .leading, spacing: 6) {
              Text(LedgerDate.friendlyString(fromISO: section.date))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

              VStack(spacing: 0) {
                ForEach(section.schedules.enumerated(), id: \.element.id) { index, schedule in
                  Button {
                    editingSchedule = schedule
                  } label: {
                    ScheduledTransactionRow(schedule: schedule, showsAccount: true)
                  }
                  .buttonStyle(.plain)
                  if index < section.schedules.count - 1 {
                    Divider().padding(.leading, 16)
                  }
                }
              }
              .ynabCard()
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .background(Theme.canvas)
    .navigationTitle("Scheduled")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await model.refreshScheduledTransactions() }
        } label: {
          Label("Refresh scheduled transactions", systemImage: "arrow.clockwise")
        }
        .disabled(model.scheduledTransactionsPhase.isLoading)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          isCreatingSchedule = true
        } label: {
          Label("Add scheduled transaction", systemImage: "plus")
        }
      }
    }
    .refreshable {
      await model.refreshScheduledTransactions()
    }
    .task {
      if model.scheduledTransactionsPhase == .idle {
        await model.refreshScheduledTransactions()
      }
    }
    .sheet(isPresented: $isCreatingSchedule) {
      ScheduledTransactionEditorView()
    }
    .sheet(item: $editingSchedule) { schedule in
      ScheduledTransactionEditorView(schedule: schedule)
    }
  }

  private var sections: [(date: String, schedules: [ScheduledTransaction])] {
    let grouped = Dictionary(grouping: model.scheduledTransactions, by: \.dateNext)
    return grouped.keys.sorted().map { date in
      (date: date, schedules: (grouped[date] ?? []).sorted { $0.id < $1.id })
    }
  }
}

struct ScheduledTransactionRow: View {
  @Environment(AppModel.self) private var model
  let schedule: ScheduledTransaction
  var showsAccount: Bool = true

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(payeeLabel)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Theme.textPrimary)
          .lineLimit(1)
        Text(showsAccount ? "\(accountLabel) · \(categoryLabel)" : categoryLabel)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Label(schedule.recurrenceLabel, systemImage: "arrow.triangle.2.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      Text(MoneyCodec.signedDisplayString(for: schedule.amount, currencyFormat: model.currencyFormat))
        .font(.subheadline.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(Theme.registerAmountColour(schedule.amount))
        .multilineTextAlignment(.trailing)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .flagRail(Theme.flagColour(named: schedule.flagColor))
    .accessibilityElement(children: .combine)
  }

  private var accountLabel: String {
    model.account(withID: schedule.accountID)?.name ?? "Account"
  }

  private var payeeLabel: String {
    if let payeeID = schedule.payeeID,
       let payee = model.payee(withID: payeeID)?.name,
       !payee.isEmpty {
      return payee
    }
    if let transferAccountID = schedule.transferAccountID,
       let destination = model.account(withID: transferAccountID)?.name {
      return "Transfer to \(destination)"
    }
    return schedule.transferAccountID == nil ? "(No payee)" : "Transfer"
  }

  private var categoryLabel: String {
    if schedule.isSplit {
      let names = schedule.activeSubtransactions.compactMap { item in
        model.categoryName(forID: item.categoryID)
      }
      var seen = Set<String>()
      let uniqueNames = names.filter { seen.insert($0).inserted }
      if uniqueNames.isEmpty {
        return "Split (\(schedule.activeSubtransactions.count))"
      }
      let shown = uniqueNames.prefix(2).joined(separator: ", ")
      let remainder = uniqueNames.count - min(uniqueNames.count, 2)
      return remainder > 0 ? "Split · \(shown) +\(remainder)" : "Split · \(shown)"
    }
    if let category = model.categoryName(forID: schedule.categoryID) {
      return category
    }
    return schedule.transferAccountID == nil ? "Uncategorised" : "Transfer"
  }
}
