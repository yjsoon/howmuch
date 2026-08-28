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

        if !model.pendingRows.isEmpty {
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

          if !collectionGroups.isEmpty {
            accountListBandLabel("Your groups")
            ForEach(collectionGroups) { group in
              accountGroupSection(group)
            }
          }
          if !indexGroups.isEmpty {
            accountListBandLabel("By type")
            ForEach(indexGroups) { group in
              accountGroupSection(group)
            }
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
      case .icon(let account):
        AccountIdentityEditorSheet(account: account)
      }
    }
    .binaryConfirm(
      "Delete \(groupPendingDeletion?.name ?? "this group")?",
      presenting: $groupPendingDeletion,
      confirm: .destructive("Delete Group"),
      message: { _ in
        Text("The accounts and their transactions will not be deleted.")
      }
    ) { group in
      model.deleteCustomAccountGroup(id: group.id)
    }
  }

  private func accountGroupSection(_ group: AccountListGroup) -> some View {
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
              .font(group.kind == .index ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
              .foregroundStyle(group.kind == .index ? Color.secondary : Theme.textPrimary)
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
              presentedSheet = .reorder(AccountGroupManagementItem(id: group.id, title: group.title))
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

  private func accountRow(_ account: Account) -> some View {
    HStack(alignment: .center, spacing: 4) {
      Button {
        presentedSheet = .icon(account)
      } label: {
        Text(account.displayIcon)
          .font(.title3)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Change icon for \(account.name)")
      .accessibilityHint("Opens the name and icon editor")

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
    }
    .padding(.horizontal, 12)
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
      Button("Change icon") {
        presentedSheet = .icon(account)
      }
    }
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

  private struct OutboxCard: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDiscard: PendingRow?

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: "arrow.triangle.2.circlepath")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text(title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
            Text("Shown here until they reach the server")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            Task {
              if await model.drainOutbox(trigger: .manual) > 0 {
                await model.refreshLedgerAndInvalidatePlan()
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

        ForEach(model.pendingRows) { row in
          Divider().padding(.leading, 16)
          pendingRow(row)
        }
      }
      .ynabCard()
      .binaryConfirm(
        "Discard this transaction? It hasn’t reached the server.",
        presenting: $pendingDiscard,
        confirm: .destructive("Discard Transaction")
      ) { row in
        model.discardPending(row.id)
      }
    }

    private var title: String {
      let count = model.pendingRows.count
      return count == 1 ? "1 transaction waiting to sync" : "\(count) transactions waiting to sync"
    }

    private func pendingRow(_ row: PendingRow) -> some View {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.payeeName ?? "Transaction")
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
          Text(LedgerDate.friendlyString(fromISO: row.isoDate))
            .font(.footnote)
            .foregroundStyle(.secondary)
          if case .rejected(let error) = row.status {
            Text(error)
              .font(.footnote)
              .foregroundStyle(Theme.outflow)
              .lineLimit(2)
          } else if row.status == .sending {
            Text("Sending…")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Text(MoneyCodec.signedDisplayString(for: row.signedAmount, currencyFormat: model.currencyFormat))
          .monospacedDigit()
          .foregroundStyle(Theme.registerAmountColour(row.signedAmount))
        if case .rejected = row.status {
          Button {
            model.retryPending(row.id)
          } label: {
            Image(systemName: "arrow.clockwise")
              .font(.footnote)
              .foregroundStyle(Theme.accent)
              .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Retry \(row.payeeName ?? "transaction")")
        }
        if row.status != .sending {
          Button {
            pendingDiscard = row
          } label: {
            Image(systemName: "trash")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Discard \(row.payeeName ?? "pending transaction")")
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
    }
  }

  private var accountGroups: [AccountListGroup] {
    model.accountListGroups()
  }

  private var collectionGroups: [AccountListGroup] {
    accountGroups.filter { $0.kind == .collection }
  }

  private var indexGroups: [AccountListGroup] {
    accountGroups.filter { $0.kind == .index }
  }

  private func accountListBandLabel(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.tertiary)
      .textCase(.uppercase)
      .tracking(0.8)
      .padding(.horizontal, 4)
      .padding(.top, 8)
      .accessibilityAddTraits(.isHeader)
  }

  private var groupManagementItems: [AccountGroupManagementItem] {
    AccountSystemGroup.allCases.map { AccountGroupManagementItem(id: $0.id, title: $0.title) }
      + model.customAccountGroups.map { AccountGroupManagementItem(id: $0.id, title: $0.name) }
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
  case icon(Account)

  var id: String {
    switch self {
    case .newGroup(let accountID): "new-group-\(accountID ?? "none")"
    case .manageGroups: "manage-groups"
    case .favourites: "favourites"
    case .memberships(let accountID): "memberships-\(accountID)"
    case .editGroup(let group): "edit-\(group.id)"
    case .reorder(let group): "reorder-\(group.id)"
    case .icon(let account): "icon-\(account.id)"
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
            Toggle(isOn: favouriteBinding(account.id)) {
              Label {
                Text(account.name)
              } icon: {
                Text(account.displayIcon)
                  .frame(width: 28, alignment: .center)
              }
            }
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

struct AccountMembershipSheet: View {
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
          Label {
            Text(account.name)
          } icon: {
            Text(account.displayIcon)
              .frame(width: 28, alignment: .center)
          }
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
    model.accounts(inGroupID: group.id)
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
    .binaryConfirm(
      "Delete \(group.name)?",
      isPresented: $isConfirmingDelete,
      confirm: .destructive("Delete Group"),
      message: {
        Text("The accounts and their transactions will not be deleted.")
      }
    ) {
      model.deleteCustomAccountGroup(id: group.id)
      dismiss()
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

struct AccountIdentityEditorSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let account: Account
  @State private var name: String
  @State private var icon: String
  @State private var custom = ""
  @State private var error: String?
  @State private var isSaving = false
  @State private var isIconExpanded = true

  init(account: Account) {
    self.account = account
    _name = State(initialValue: account.name)
    _icon = State(initialValue: account.displayIcon)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          nameCard
          iconCard
          if let error {
            Text(error)
              .font(.footnote)
              .foregroundStyle(Theme.outflow)
          }
        }
        .padding(16)
      }
      .scrollDismissesKeyboard(.immediately)
      .background(Theme.canvas)
      .navigationTitle("Edit name and icon")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.body.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
          }
          .disabled(isSaving)
          .accessibilityLabel("Cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          if isSaving {
            ProgressView()
              .accessibilityLabel("Saving")
          } else {
            Button {
              Task { await save() }
            } label: {
              Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(canSave ? Theme.accent : Color.secondary)
            }
            .disabled(!canSave)
            .accessibilityLabel("Save")
          }
        }
      }
      .interactiveDismissDisabled(isSaving)
    }
  }

  private var nameCard: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          Text("Name")
            .foregroundStyle(Theme.textPrimary)
          nameField
        }
      } else {
        HStack {
          Text("Name")
            .foregroundStyle(Theme.textPrimary)
          nameField
            .multilineTextAlignment(.trailing)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
    .ynabCard()
  }

  private var nameField: some View {
    TextField("Account name", text: $name)
      .textInputAutocapitalization(.words)
      .disabled(isSaving)
  }

  private var iconCard: some View {
    VStack(spacing: 0) {
      Button {
        withAnimation(.snappy) {
          isIconExpanded.toggle()
        }
      } label: {
        HStack {
          Text("Icon")
            .foregroundStyle(Theme.textPrimary)
          Spacer()
          Text(icon)
            .font(.title3)
            .accessibilityHidden(true)
          Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isIconExpanded ? 0 : -90))
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSaving)
      .accessibilityLabel("Icon")
      .accessibilityValue(icon)
      .accessibilityHint(isIconExpanded ? "Collapses the icon picker" : "Expands the icon picker")

      if isIconExpanded {
        Divider().padding(.leading, 16)
        LazyVGrid(columns: paletteColumns, spacing: 8) {
          ForEach(AccountIcon.palette, id: \.self) { candidate in
            Button {
              icon = candidate
              custom = ""
              error = nil
            } label: {
              Text(candidate)
                .font(dynamicTypeSize.isAccessibilitySize ? .title2 : .title3)
                .frame(maxWidth: .infinity, minHeight: paletteCellHeight)
                .background(
                  candidate == icon ? Theme.accent.opacity(0.15) : Color.clear,
                  in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .accessibilityLabel("Use \(candidate)")
            .accessibilityAddTraits(candidate == icon ? .isSelected : [])
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)

        HStack(spacing: 8) {
          TextField("Custom emoji", text: $custom)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit { applyCustom() }
            .disabled(isSaving)
          Button("Use") { applyCustom() }
            .disabled(isSaving || AccountIcon.parse(custom) == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
    }
    .ynabCard()
  }

  private var paletteColumns: [GridItem] {
    let count = dynamicTypeSize.isAccessibilitySize ? 4 : 6
    Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
  }

  private var paletteCellHeight: CGFloat {
    dynamicTypeSize.isAccessibilitySize ? 44 : 36
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSave: Bool {
    AccountIcon.parse(icon) != nil && !trimmedName.isEmpty
  }

  private func applyCustom() {
    guard let parsed = AccountIcon.parse(custom) else {
      error = "Choose a single emoji."
      return
    }
    icon = parsed
    error = nil
  }

  private func save() async {
    guard canSave, let parsed = AccountIcon.parse(icon) else { return }
    isSaving = true
    error = nil
    do {
      try await model.setAccountIdentity(name: trimmedName, icon: parsed, for: account.id)
      dismiss()
    } catch {
      self.error = error.localizedDescription
      isSaving = false
    }
  }
}
