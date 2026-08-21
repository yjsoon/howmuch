import SwiftUI

struct AccountsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var collapsedGroups: Set<String> = ["closed"]
  @State private var presentedSheet: AccountsSheet?
  @State private var groupPendingDeletion: CustomAccountGroup?

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
        Menu {
          Button {
            presentedSheet = .newGroup(prefilledAccountID: nil)
          } label: {
            Label("New Group…", systemImage: "folder.badge.plus")
          }
          Button {
            presentedSheet = .manageGroups
          } label: {
            Label("Manage Groups…", systemImage: "folder")
          }
          Divider()
          Button {
            presentedSheet = .favourites
          } label: {
            Label("Choose Favourites…", systemImage: "star")
          }
        } label: {
          Image(systemName: "rectangle.grid.1x2")
        }
        .accessibilityLabel("Organise accounts")
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
    .sheet(item: $presentedSheet) { sheet in
      switch sheet {
      case .newGroup(let prefilledAccountID):
        NewCustomAccountGroupSheet(prefilledAccountID: prefilledAccountID)
      case .manageGroups:
        ManageAccountGroupsSheet()
      case .favourites:
        ChooseFavouritesSheet()
      case .memberships(let accountID):
        AccountMembershipSheet(accountID: accountID)
      case .editGroup(let group):
        NavigationStack {
          CustomAccountGroupEditor(group: group)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { presentedSheet = nil }
              }
            }
        }
      case .reorder(let group):
        AccountGroupReorderSheet(group: group)
      }
    }
    .confirmationDialog(
      "Delete \(groupPendingDeletion?.name ?? "this group")?",
      isPresented: isConfirmingGroupDeletion,
      titleVisibility: .visible,
      presenting: groupPendingDeletion
    ) { group in
      Button("Delete Group", role: .destructive) {
        model.deleteCustomAccountGroup(id: group.id)
      }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("The accounts and their transactions will not be deleted.")
    }
  }

  private var isConfirmingGroupDeletion: Binding<Bool> {
    Binding(
      get: { groupPendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          groupPendingDeletion = nil
        }
      }
    )
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
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

        Menu {
          Picker("Sort \(group.title)", selection: groupSortBinding(group.id)) {
            ForEach(AccountGroupSort.allCases) { sort in
              Text(sort.title).tag(sort)
            }
          }
          if model.sortForAccountGroup(group.id) == .manual, group.accounts.count > 1 {
            Divider()
            Button {
              presentedSheet = .reorder(group.managementItem)
            } label: {
              Label("Reorder Accounts…", systemImage: "arrow.up.arrow.down")
            }
          }
          if group.id == "favourites" {
            Divider()
            Button {
              presentedSheet = .favourites
            } label: {
              Label("Choose Favourites…", systemImage: "star")
            }
          }
          if let customGroup = group.customGroup {
            Divider()
            Button {
              presentedSheet = .editGroup(customGroup)
            } label: {
              Label("Edit Group…", systemImage: "pencil")
            }
            Button(role: .destructive) {
              groupPendingDeletion = customGroup
            } label: {
              Label("Delete Group…", systemImage: "trash")
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Options for \(group.title)")
      }

      if model.sortForAccountGroup(group.id) == .mostUsedLast30Days {
        if model.accountUsagePhase == .idle || model.accountUsagePhase.isLoading {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Loading 30-day usage…")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 4)
        } else if case .failed(let message) = model.accountUsagePhase {
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
      }

      if !isCollapsed {
        if group.accounts.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("No accounts yet")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            if let customGroup = group.customGroup {
              Button("Add Accounts") {
                presentedSheet = .editGroup(customGroup)
              }
              .font(.subheadline.weight(.semibold))
            }
          }
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
    HStack(spacing: 0) {
      NavigationLink {
        RegisterView(scope: .account(account.id))
      } label: {
        Group {
          if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
              Text(account.name)
                .foregroundStyle(Theme.textPrimary)
              accountBalance(account)
            }
          } else {
            HStack {
              Text(account.name)
                .foregroundStyle(Theme.textPrimary)
              Spacer()
              accountBalance(account)
            }
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.leading, 16)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .accessibilityActions {
        if !account.closed {
          Button(model.isAccountFavourite(account.id) ? "Remove from Favourites" : "Add to Favourites") {
            model.toggleAccountFavourite(account.id)
          }
        }
        Button("Groups") {
          presentedSheet = .memberships(account.id)
        }
      }

      Menu {
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
          presentedSheet = .memberships(account.id)
        } label: {
          Label("Groups…", systemImage: "folder")
        }
      } label: {
        Image(systemName: "ellipsis")
          .foregroundStyle(.secondary)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Actions for \(account.name)")
    }
    .padding(.trailing, 4)
  }

  private func accountBalance(_ account: Account) -> some View {
    Text(MoneyCodec.displayString(for: account.balance, currencyFormat: model.currencyFormat))
      .monospacedDigit()
      .foregroundStyle(account.balance == 0 ? .secondary : Theme.amountColour(account.balance))
      .fixedSize(horizontal: true, vertical: false)
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
    let customGroup: CustomAccountGroup?

    init(id: String, title: String, accounts: [Account], customGroup: CustomAccountGroup? = nil) {
      self.id = id
      self.title = title
      self.accounts = accounts
      self.customGroup = customGroup
    }

    var total: Int {
      accounts.reduce(0) { $0 + $1.balance }
    }

    var managementItem: AccountGroupManagementItem {
      AccountGroupManagementItem(id: id, title: title)
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
        accounts: model.orderedAccounts(live.filter { group.accountIDs.contains($0.id) }, inGroup: group.id),
        customGroup: group
      )
    }
    return customGroups + systemGroups.filter { !$0.accounts.isEmpty }
  }

  private var groupManagementItems: [AccountGroupManagementItem] {
    [
      AccountGroupManagementItem(id: "favourites", title: "Favourites"),
      AccountGroupManagementItem(id: "cash", title: "Cash"),
      AccountGroupManagementItem(id: "credit", title: "Credit"),
      AccountGroupManagementItem(id: "tracking", title: "Tracking"),
      AccountGroupManagementItem(id: "closed", title: "Closed"),
    ] + model.customAccountGroups.map { group in
      AccountGroupManagementItem(id: group.id, title: group.name)
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
}

private enum AccountsSheet: Identifiable {
  case newGroup(prefilledAccountID: String?)
  case manageGroups
  case favourites
  case memberships(String)
  case editGroup(CustomAccountGroup)
  case reorder(AccountGroupManagementItem)

  var id: String {
    switch self {
    case .newGroup(let accountID): "new-group-\(accountID ?? "none")"
    case .manageGroups: "manage-groups"
    case .favourites: "favourites"
    case .memberships(let accountID): "memberships-\(accountID)"
    case .editGroup(let group): "edit-\(group.id)"
    case .reorder(let group): "reorder-\(group.id)"
    }
  }
}

private struct ManageAccountGroupsSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var isCreatingGroup = false

  var body: some View {
    NavigationStack {
      Group {
        if model.customAccountGroups.isEmpty {
          ContentUnavailableView {
            Label("No Account Groups", systemImage: "folder")
          } description: {
            Text("Create groups such as Travel or Shared, then choose their accounts.")
          } actions: {
            Button("New Group") { isCreatingGroup = true }
              .buttonStyle(.borderedProminent)
          }
        } else {
          List {
            ForEach(model.customAccountGroups) { group in
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
            }
            .onMove(perform: model.moveCustomAccountGroups)
          }
        }
      }
      .navigationTitle("Account Groups")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
          if model.customAccountGroups.count > 1 {
            EditButton()
          }
          Button {
            isCreatingGroup = true
          } label: {
            Label("New Group", systemImage: "plus")
          }
        }
      }
      .sheet(isPresented: $isCreatingGroup) {
        NewCustomAccountGroupSheet(prefilledAccountID: nil)
      }
    }
  }
}

private struct ChooseFavouritesSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(model.openAccounts.sorted(by: accountNameOrder)) { account in
            Toggle(account.name, isOn: favouriteBinding(account.id))
          }
        } footer: {
          Text("Favourites are shown first on Accounts. Closed accounts are excluded.")
        }
      }
      .navigationTitle("Choose Favourites")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
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
}

private struct NewCustomAccountGroupSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var accountIDs: Set<String>
  @FocusState private var isNameFocused: Bool

  init(prefilledAccountID: String?) {
    _accountIDs = State(initialValue: Set(prefilledAccountID.map { [$0] } ?? []))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Group") {
          TextField("Name", text: $name)
            .focused($isNameFocused)
          if !name.isEmpty, let nameError {
            Text(nameError)
              .font(.footnote)
              .foregroundStyle(.red)
          } else {
            Text("Names must be unique and cannot use a built-in group name.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        AccountSelectionSections(accountIDs: $accountIDs)
      }
      .navigationTitle("New Group")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            if model.addCustomAccountGroup(named: name, accountIDs: orderedAccountIDs) {
              dismiss()
            }
          }
          .disabled(nameError != nil)
        }
      }
      .task {
        await Task.yield()
        isNameFocused = true
      }
    }
  }

  private var nameError: String? {
    model.customAccountGroupNameError(name)
  }

  private var orderedAccountIDs: [String] {
    model.accounts.map(\.id).filter(accountIDs.contains)
  }
}

private struct AccountMembershipSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let accountID: String
  @State private var isCreatingGroup = false

  var body: some View {
    NavigationStack {
      Group {
        if model.customAccountGroups.isEmpty {
          ContentUnavailableView {
            Label("No Account Groups", systemImage: "folder")
          } description: {
            Text("Create a group and this account will be selected for you.")
          } actions: {
            Button("New Group") { isCreatingGroup = true }
              .buttonStyle(.borderedProminent)
          }
        } else {
          List {
            Section {
              ForEach(model.customAccountGroups) { group in
                Toggle(group.name, isOn: membershipBinding(group.id))
              }
            } footer: {
              Text("An account can belong to more than one group.")
            }
          }
        }
      }
      .navigationTitle("Groups for \(accountName)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            isCreatingGroup = true
          } label: {
            Label("New Group", systemImage: "plus")
          }
        }
      }
      .sheet(isPresented: $isCreatingGroup) {
        NewCustomAccountGroupSheet(prefilledAccountID: accountID)
      }
    }
  }

  private var accountName: String {
    model.account(withID: accountID)?.name ?? "Account"
  }

  private func membershipBinding(_ groupID: String) -> Binding<Bool> {
    Binding(
      get: {
        model.customAccountGroups.first(where: { $0.id == groupID })?.accountIDs.contains(accountID) == true
      },
      set: { included in
        model.setAccount(accountID, included: included, inCustomGroup: groupID)
      }
    )
  }
}

private struct AccountGroupReorderSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let group: AccountGroupManagementItem
  @State private var editMode: EditMode = .active

  var body: some View {
    NavigationStack {
      List {
        ForEach(accounts) { account in
          Text(account.name)
        }
        .onMove { source, destination in
          model.moveAccounts(in: accounts, groupID: group.id, fromOffsets: source, toOffset: destination)
        }
      }
      .environment(\.editMode, $editMode)
      .navigationTitle("Reorder \(group.title)")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom) {
        Text("Drag the handles to set this group’s manual order.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var accounts: [Account] {
    accountsForGroup(group, in: model)
  }
}

private struct AccountSelectionSections: View {
  @Environment(AppModel.self) private var model
  @Binding var accountIDs: Set<String>

  var body: some View {
    Section("Open Accounts") {
      if openAccounts.isEmpty {
        Text("No open accounts")
          .foregroundStyle(.secondary)
      }
      ForEach(openAccounts) { account in
        Toggle(account.name, isOn: membershipBinding(account.id))
      }
    }
    if !closedAccounts.isEmpty {
      Section("Closed Accounts") {
        ForEach(closedAccounts) { account in
          Toggle(account.name, isOn: membershipBinding(account.id))
        }
      }
    }
  }

  private var openAccounts: [Account] {
    model.openAccounts.sorted(by: accountNameOrder)
  }

  private var closedAccounts: [Account] {
    model.accounts.filter(\.closed).sorted(by: accountNameOrder)
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
}

@MainActor
private func accountsForGroup(_ group: AccountGroupManagementItem, in model: AppModel) -> [Account] {
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

private func accountNameOrder(_ first: Account, _ second: Account) -> Bool {
  let comparison = first.name.localizedStandardCompare(second.name)
  return comparison == .orderedSame ? first.id < second.id : comparison == .orderedAscending
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
      AccountSelectionSections(accountIDs: $accountIDs)
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
}
