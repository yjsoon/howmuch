import SwiftUI

struct AccountsView: View {
  @Environment(AppModel.self) private var model
  @State private var collapsedGroups: Set<String> = ["closed"]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ScreenTitle("Accounts")

        // Offline captures outrank everything else here: they are the user's
        // money data that has not reached the server yet.
        if !model.pendingTransactions.isEmpty {
          OutboxCard()
        }

        if model.accounts.isEmpty, model.referencePhase != .loaded {
          PhasePlaceholder(phase: model.referencePhase) {
            await model.refreshReferenceData()
          }
        } else {
          NavigationLink {
            RegisterView(scope: .all)
          } label: {
            HStack {
              Text("All Transactions")
                .foregroundStyle(Theme.textPrimary)
              Spacer()
              Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .padding(16)
            .ynabCard()
          }
          .buttonStyle(.plain)

          ForEach(accountGroups) { group in
            accountGroupSection(group)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .background(Theme.canvas)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          model.isShowingSettings = true
        } label: {
          Label("Connection settings", systemImage: "ellipsis.circle")
        }
        .tint(Theme.accent)
      }
    }
    .refreshable {
      await model.refreshAll()
    }
  }

  private func accountGroupSection(_ group: AccountGroup) -> some View {
    let isCollapsed = collapsedGroups.contains(group.id)
    return VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(.snappy) {
          if isCollapsed {
            collapsedGroups.remove(group.id)
          } else {
            collapsedGroups.insert(group.id)
          }
        }
      } label: {
        HStack {
          Image(systemName: "chevron.down")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
          Text(group.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
          Spacer()
          Text(MoneyCodec.displayString(for: group.total, currencyFormat: model.currencyFormat))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if !isCollapsed {
        VStack(spacing: 0) {
          ForEach(group.accounts.enumerated(), id: \.element.id) { index, account in
            NavigationLink {
              RegisterView(scope: .account(account.id))
            } label: {
              HStack {
                Text(account.name)
                  .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(MoneyCodec.displayString(for: account.balance, currencyFormat: model.currencyFormat))
                  .monospacedDigit()
                  .foregroundStyle(account.balance == 0 ? .secondary : Theme.amountColour(account.balance))
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 13)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if index < group.accounts.count - 1 {
              Divider().padding(.leading, 16)
            }
          }
        }
        .ynabCard()
      }
    }
  }

  /// Offline captures waiting to reach the server, with retry and discard.
  private struct OutboxCard: View {
    @Environment(AppModel.self) private var model
    @State private var isSyncing = false

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: "wifi.slash")
            .foregroundStyle(.secondary)
          Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
          Spacer()
          Button {
            isSyncing = true
            Task {
              await model.syncOutbox()
              isSyncing = false
            }
          } label: {
            if isSyncing {
              ProgressView()
            } else {
              Text("Sync Now")
                .font(.subheadline.weight(.semibold))
            }
          }
          .tint(Theme.accent)
          .disabled(isSyncing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        ForEach(model.pendingTransactions) { item in
          Divider().padding(.leading, 16)
          pendingRow(item)
        }
      }
      .ynabCard()
    }

    private var title: String {
      let count = model.pendingTransactions.count
      return count == 1 ? "1 expense waiting to sync" : "\(count) expenses waiting to sync"
    }

    private func pendingRow(_ item: PendingTransaction) -> some View {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(item.request.payeeName ?? "Transaction")
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
          Text(LedgerDate.friendlyString(fromISO: item.request.date))
            .font(.footnote)
            .foregroundStyle(.secondary)
          if let error = item.lastSyncError {
            Text(error)
              .font(.footnote)
              .foregroundStyle(Theme.outflow)
              .lineLimit(2)
          }
        }
        Spacer()
        Text(MoneyCodec.signedDisplayString(for: item.request.amount, currencyFormat: model.currencyFormat))
          .monospacedDigit()
          .foregroundStyle(Theme.registerAmountColour(item.request.amount))
        Button {
          model.discardPending(item)
        } label: {
          Image(systemName: "trash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Discard offline expense")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
    }
  }

  private struct AccountGroup: Identifiable {
    let id: String
    let title: String
    let accounts: [Account]

    var total: Int {
      accounts.reduce(0) { $0 + $1.balance }
    }
  }

  private var accountGroups: [AccountGroup] {
    let live = model.accounts
    let cashTypes: Set<String> = ["checking", "savings", "cash"]
    let creditTypes: Set<String> = ["creditCard", "lineOfCredit"]

    let open = live.filter { !$0.closed }
    let groups: [AccountGroup] = [
      AccountGroup(id: "cash", title: "Cash", accounts: open.filter { cashTypes.contains($0.type) }),
      AccountGroup(id: "credit", title: "Credit", accounts: open.filter { creditTypes.contains($0.type) }),
      AccountGroup(
        id: "tracking",
        title: "Tracking",
        accounts: open.filter { !cashTypes.contains($0.type) && !creditTypes.contains($0.type) }
      ),
      AccountGroup(id: "closed", title: "Closed", accounts: live.filter(\.closed)),
    ]
    return groups.filter { !$0.accounts.isEmpty }
  }
}
