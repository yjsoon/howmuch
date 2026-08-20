import SwiftUI

struct AccountsView: View {
  @Environment(AppModel.self) private var model
  @State private var collapsedGroups: Set<String> = ["closed"]
  @State private var isShowingAccountManager = false

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

          NavigationLink {
            ScheduledTransactionsView()
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
              VStack(alignment: .leading, spacing: 2) {
                Text("Scheduled Transactions")
                  .foregroundStyle(Theme.textPrimary)
                if model.scheduledTransactionsPhase == .loaded {
                  let count = model.scheduledTransactions.count
                  Text(count == 1 ? "1 upcoming transaction" : "\(count) upcoming transactions")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else if model.scheduledTransactionsPhase.isLoading {
                  Text("Loading upcoming transactions")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              if model.scheduledTransactionsPhase.isLoading {
                ProgressView()
              } else {
                Image(systemName: "chevron.right")
                  .font(.footnote.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
            }
            .padding(16)
            .ynabCard()
          }
          .buttonStyle(.plain)

          if !favouriteAccounts.isEmpty {
            accountGroupSection(
              AccountGroup(id: "favourites", title: "Favourites", accounts: favouriteAccounts)
            )
          }

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
      ToolbarItem(placement: .topBarLeading) {
        Button("Edit") {
          isShowingAccountManager = true
        }
        .accessibilityLabel("Manage accounts")
        .accessibilityHint("Manage favourites, account groups, and sorting")
      }
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
    .task(id: accountUsageTaskID) {
      guard usesMostUsedSort, model.accountUsagePhase != .loaded else {
        return
      }
      await model.refreshAccountUsageLast30Days()
    }
    .sheet(isPresented: $isShowingAccountManager) {
      AccountManagementSheet()
    }
  }

  private func accountGroupSection(_ group: AccountGroup) -> some View {
    let isCollapsed = collapsedGroups.contains(group.id)
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
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

        Menu {
          Picker("Sort \(group.title)", selection: groupSortBinding(group.id)) {
            ForEach(AccountGroupSort.allCases) { sort in
              Text(sort.title).tag(sort)
            }
          }
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Sort \(group.title)")
      }

      if model.sortForAccountGroup(group.id) == .mostUsedLast30Days,
         case .failed(let message) = model.accountUsagePhase
      {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("30-day usage unavailable: \(message)")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Retry") {
            Task { await model.refreshAccountUsageLast30Days() }
          }
        }
        .padding(.horizontal, 4)
      }

      if !isCollapsed {
        if group.accounts.isEmpty {
          Text("No accounts in this group")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .ynabCard()
        } else {
          VStack(spacing: 0) {
            ForEach(group.accounts.enumerated(), id: \.element.id) { index, account in
              accountRow(account)

              if index < group.accounts.count - 1 {
                Divider().padding(.leading, 16)
              }
            }
          }
          .ynabCard()
        }
      }
    }
  }

  private var favouriteAccounts: [Account] {
    model.orderedAccounts(model.openAccounts.filter { model.isAccountFavourite($0.id) }, inGroup: "favourites")
  }

  private func accountRow(_ account: Account) -> some View {
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
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func groupSortBinding(_ groupID: String) -> Binding<AccountGroupSort> {
    Binding(
      get: { model.sortForAccountGroup(groupID) },
      set: { model.setSort($0, forAccountGroup: groupID) }
    )
  }

  /// Offline captures waiting to reach the server, with retry and discard.
  private struct OutboxCard: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDiscard: PendingTransaction?

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: "wifi.slash")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text(title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
            Text("Shown here until synced")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            Task {
              if await model.syncOutbox(manual: true) > 0 {
                // Bring the balances under this card back in line.
                await model.refreshAll(quiet: true)
              }
            }
          } label: {
            if model.isSyncingOutbox {
              ProgressView()
            } else {
              Text("Sync Now")
                .font(.subheadline.weight(.semibold))
            }
          }
          .tint(Theme.accent)
          .disabled(model.isSyncingOutbox)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        ForEach(model.pendingTransactions) { item in
          Divider().padding(.leading, 16)
          pendingRow(item)
        }
      }
      .ynabCard()
      .confirmationDialog(
        "Discard this offline transaction? It hasn’t reached the server.",
        isPresented: isConfirmingDiscard,
        titleVisibility: .visible,
        presenting: pendingDiscard
      ) { item in
        Button("Discard Transaction", role: .destructive) {
          model.discardPending(item)
        }
      }
    }

    private var isConfirmingDiscard: Binding<Bool> {
      Binding(
        get: { pendingDiscard != nil },
        set: { isPresented in
          if !isPresented {
            pendingDiscard = nil
          }
        }
      )
    }

    private var title: String {
      let count = model.pendingTransactions.count
      return count == 1 ? "1 transaction waiting to sync" : "\(count) transactions waiting to sync"
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
          if item.connectionFingerprint != model.settings.connectionFingerprint {
            Text("Captured against a different connection")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else if let error = item.lastSyncError {
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
          pendingDiscard = item
        } label: {
          Image(systemName: "trash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Discard \(item.request.payeeName ?? "offline transaction")")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
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
    let systemGroups: [AccountGroup] = [
      AccountGroup(id: "cash", title: "Cash", accounts: model.orderedAccounts(open.filter { cashTypes.contains($0.type) }, inGroup: "cash")),
      AccountGroup(id: "credit", title: "Credit", accounts: model.orderedAccounts(open.filter { creditTypes.contains($0.type) }, inGroup: "credit")),
      AccountGroup(
        id: "tracking",
        title: "Tracking",
        accounts: model.orderedAccounts(open.filter { !cashTypes.contains($0.type) && !creditTypes.contains($0.type) }, inGroup: "tracking")
      ),
      AccountGroup(id: "closed", title: "Closed", accounts: model.orderedAccounts(live.filter(\.closed), inGroup: "closed")),
    ]
    let customGroups = model.customAccountGroups.map { group in
      AccountGroup(
        id: group.id,
        title: group.name,
        accounts: model.orderedAccounts(live.filter { group.accountIDs.contains($0.id) }, inGroup: group.id)
      )
    }
    return systemGroups.filter { !$0.accounts.isEmpty } + customGroups
  }

  private var groupManagementItems: [AccountGroupManagementItem] {
    [
      AccountGroupManagementItem(id: "favourites", title: "Favourites", isCustom: false),
      AccountGroupManagementItem(id: "cash", title: "Cash", isCustom: false),
      AccountGroupManagementItem(id: "credit", title: "Credit", isCustom: false),
      AccountGroupManagementItem(id: "tracking", title: "Tracking", isCustom: false),
      AccountGroupManagementItem(id: "closed", title: "Closed", isCustom: false),
    ] + model.customAccountGroups.map { group in
      AccountGroupManagementItem(id: group.id, title: group.name, isCustom: true)
    }
  }

  private var usesMostUsedSort: Bool {
    groupManagementItems.contains { model.sortForAccountGroup($0.id) == .mostUsedLast30Days }
  }

  private var accountUsageTaskID: String {
    "\(usesMostUsedSort)-\(model.accountUsageGeneration)"
  }
}

private struct AccountGroupManagementItem: Identifiable {
  let id: String
  let title: String
  let isCustom: Bool
}

private struct AccountManagementSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var newGroupName = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Favourites") {
          Text("Favourites are always shown first on Accounts.")
            .font(.footnote)
            .foregroundStyle(.secondary)
          ForEach(model.openAccounts.sorted(by: nameOrder)) { account in
            Toggle(account.name, isOn: favouriteBinding(account.id))
          }
        }

        Section("Group sorting") {
          ForEach(groups) { group in
            NavigationLink {
              AccountGroupSortingEditor(group: group)
            } label: {
              LabeledContent(group.title, value: model.sortForAccountGroup(group.id).title)
            }
          }
          if usesMostUsedSort, model.accountUsagePhase.isLoading {
            LabeledContent("Most-used sorting") { ProgressView() }
          } else if usesMostUsedSort, case .failed(let message) = model.accountUsagePhase {
            VStack(alignment: .leading, spacing: 8) {
              Text("Most-used sorting will use alphabetical tie-breaks until usage can be refreshed: \(message)")
                .font(.footnote)
                .foregroundStyle(.secondary)
              Button("Retry Usage Refresh") {
                Task { await model.refreshAccountUsageLast30Days() }
              }
            }
          }
        }

        Section("Custom groups") {
          if model.customAccountGroups.isEmpty {
            Text("Create groups such as Travel or Shared accounts, then choose their members.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          ForEach(model.customAccountGroups) { group in
            HStack {
              NavigationLink {
                CustomAccountGroupEditor(group: group)
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(group.name)
                  Text("\(group.accountIDs.count) account\(group.accountIDs.count == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              HStack(spacing: 0) {
                Button {
                  model.moveCustomAccountGroup(id: group.id, by: -1)
                } label: {
                  Image(systemName: "chevron.up")
                    .frame(width: 44, height: 44)
                }
                .disabled(model.customAccountGroups.first?.id == group.id)
                .accessibilityLabel("Move \(group.name) up")
                Button {
                  model.moveCustomAccountGroup(id: group.id, by: 1)
                } label: {
                  Image(systemName: "chevron.down")
                    .frame(width: 44, height: 44)
                }
                .disabled(model.customAccountGroups.last?.id == group.id)
                .accessibilityLabel("Move \(group.name) down")
              }
              .buttonStyle(.borderless)
              .foregroundStyle(Theme.accent)
            }
          }
        }

        Section("New custom group") {
          TextField("Group name", text: $newGroupName)
          if let newGroupNameError {
            Text(newGroupNameError)
              .font(.footnote)
              .foregroundStyle(.red)
          } else {
            Text("Names must be unique and cannot use a built-in group name.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          Button("Add Group") {
            if model.addCustomAccountGroup(named: newGroupName) {
              newGroupName = ""
            }
          }
          .disabled(newGroupNameError != nil)
        }
      }
      .navigationTitle("Manage Accounts")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task(id: accountUsageTaskID) {
        guard usesMostUsedSort, model.accountUsagePhase != .loaded else {
          return
        }
        await model.refreshAccountUsageLast30Days()
      }
    }
  }

  private var groups: [AccountGroupManagementItem] {
    [
      AccountGroupManagementItem(id: "favourites", title: "Favourites", isCustom: false),
      AccountGroupManagementItem(id: "cash", title: "Cash", isCustom: false),
      AccountGroupManagementItem(id: "credit", title: "Credit", isCustom: false),
      AccountGroupManagementItem(id: "tracking", title: "Tracking", isCustom: false),
      AccountGroupManagementItem(id: "closed", title: "Closed", isCustom: false),
    ] + model.customAccountGroups.map { group in
      AccountGroupManagementItem(id: group.id, title: group.name, isCustom: true)
    }
  }

  private var newGroupNameError: String? {
    model.customAccountGroupNameError(newGroupName)
  }

  private var usesMostUsedSort: Bool {
    groups.contains { model.sortForAccountGroup($0.id) == .mostUsedLast30Days }
  }

  private var accountUsageTaskID: String {
    "\(usesMostUsedSort)-\(model.accountUsageGeneration)"
  }

  private func favouriteBinding(_ accountID: String) -> Binding<Bool> {
    Binding(
      get: { model.isAccountFavourite(accountID) },
      set: { selected in
        if selected != model.isAccountFavourite(accountID) {
          model.toggleAccountFavourite(accountID)
        }
      }
    )
  }

  private func nameOrder(_ first: Account, _ second: Account) -> Bool {
    let comparison = first.name.localizedStandardCompare(second.name)
    return comparison == .orderedSame ? first.id < second.id : comparison == .orderedAscending
  }
}

private struct AccountGroupSortingEditor: View {
  @Environment(AppModel.self) private var model
  let group: AccountGroupManagementItem

  var body: some View {
    Form {
      Section("Sorting") {
        Picker("Order", selection: sortBinding) {
          ForEach(AccountGroupSort.allCases) { sort in
            Text(sort.title).tag(sort)
          }
        }
      }

      if model.sortForAccountGroup(group.id) == .manual {
        Section("Manual order") {
          if accounts.isEmpty {
            Text("No accounts in this group")
              .foregroundStyle(.secondary)
          }
          ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
            HStack {
              Text(account.name)
              Spacer()
              Button {
                model.moveAccount(account.id, in: accounts, groupID: group.id, by: -1)
              } label: {
                Image(systemName: "chevron.up")
                  .frame(width: 44, height: 44)
              }
              .disabled(index == 0)
              .accessibilityLabel("Move \(account.name) up")
              Button {
                model.moveAccount(account.id, in: accounts, groupID: group.id, by: 1)
              } label: {
                Image(systemName: "chevron.down")
                  .frame(width: 44, height: 44)
              }
              .disabled(index == accounts.count - 1)
              .accessibilityLabel("Move \(account.name) down")
            }
            .buttonStyle(.borderless)
          }
        }
      } else if model.sortForAccountGroup(group.id) == .mostUsedLast30Days {
        Section {
          if model.accountUsagePhase.isLoading {
            LabeledContent("Refreshing 30-day usage") { ProgressView() }
          } else if case .failed(let message) = model.accountUsagePhase {
            VStack(alignment: .leading, spacing: 8) {
              Text("Usage could not be refreshed: \(message)")
                .font(.footnote)
                .foregroundStyle(.secondary)
              Button("Retry") {
                Task { await model.refreshAccountUsageLast30Days() }
              }
            }
          } else {
            Text("Counts every transaction in the last 30 days, including pages not loaded in the register.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .navigationTitle("Sort \(group.title)")
    .task(id: model.sortForAccountGroup(group.id)) {
      guard model.sortForAccountGroup(group.id) == .mostUsedLast30Days,
            model.accountUsagePhase != .loaded
      else {
        return
      }
      await model.refreshAccountUsageLast30Days()
    }
  }

  private var sortBinding: Binding<AccountGroupSort> {
    Binding(
      get: { model.sortForAccountGroup(group.id) },
      set: { model.setSort($0, forAccountGroup: group.id) }
    )
  }

  private var accounts: [Account] {
    let all = model.accounts
    let open = model.openAccounts
    let cashTypes: Set<String> = ["checking", "savings", "cash"]
    let creditTypes: Set<String> = ["creditCard", "lineOfCredit"]
    let source: [Account]
    switch group.id {
    case "favourites":
      source = open.filter { model.isAccountFavourite($0.id) }
    case "cash":
      source = open.filter { cashTypes.contains($0.type) }
    case "credit":
      source = open.filter { creditTypes.contains($0.type) }
    case "tracking":
      source = open.filter { !cashTypes.contains($0.type) && !creditTypes.contains($0.type) }
    case "closed":
      source = all.filter(\.closed)
    default:
      let ids = Set(model.customAccountGroups.first(where: { $0.id == group.id })?.accountIDs ?? [])
      source = all.filter { ids.contains($0.id) }
    }
    return model.orderedAccounts(source, inGroup: group.id)
  }
}

private struct CustomAccountGroupEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let group: CustomAccountGroup
  @State private var name: String
  @State private var accountIDs: Set<String>
  @State private var isConfirmingDelete = false

  init(group: CustomAccountGroup) {
    self.group = group
    _name = State(initialValue: group.name)
    _accountIDs = State(initialValue: Set(group.accountIDs))
  }

  var body: some View {
    Form {
      Section("Group") {
        TextField("Name", text: $name)
        if let nameError {
          Text(nameError)
            .font(.footnote)
            .foregroundStyle(.red)
        } else {
          Text("Names must be unique and cannot use a built-in group name.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      Section("Accounts") {
        ForEach(model.accounts.sorted(by: nameOrder)) { account in
          Toggle(account.name, isOn: membershipBinding(account.id))
        }
      }
      Section {
        Button("Delete Group", role: .destructive) {
          isConfirmingDelete = true
        }
      }
    }
    .navigationTitle("Edit Group")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          if model.updateCustomAccountGroup(
            CustomAccountGroup(id: group.id, name: name, accountIDs: orderedAccountIDs)
          ) {
            dismiss()
          }
        }
        .disabled(nameError != nil)
      }
    }
    .confirmationDialog(
      "Delete \(group.name)?",
      isPresented: $isConfirmingDelete,
      titleVisibility: .visible
    ) {
      Button("Delete Group", role: .destructive) {
        model.deleteCustomAccountGroup(id: group.id)
        dismiss()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The accounts and their transactions will not be deleted.")
    }
  }

  private var orderedAccountIDs: [String] {
    let availableIDs = Set(model.accounts.map(\.id))
    let currentGroupIDs = model.customAccountGroups.first(where: { $0.id == group.id })?.accountIDs ?? []
    let unavailableIDs = currentGroupIDs.filter { !availableIDs.contains($0) }
    return unavailableIDs + model.accounts.map(\.id).filter(accountIDs.contains)
  }

  private var nameError: String? {
    model.customAccountGroupNameError(name, excluding: group.id)
  }

  private func membershipBinding(_ accountID: String) -> Binding<Bool> {
    Binding(
      get: { accountIDs.contains(accountID) },
      set: { included in
        if included {
          accountIDs.insert(accountID)
        } else {
          accountIDs.remove(accountID)
        }
      }
    )
  }

  private func nameOrder(_ first: Account, _ second: Account) -> Bool {
    let comparison = first.name.localizedStandardCompare(second.name)
    return comparison == .orderedSame ? first.id < second.id : comparison == .orderedAscending
  }
}
