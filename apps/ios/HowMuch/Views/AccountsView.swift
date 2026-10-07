import SwiftUI

enum AccountsPane: Hashable, Identifiable {
  case inbox
  /// The share-intake Inbox list (batches shared to Halation), not the "New" queue.
  case intake
  case intakeBatch(UUID)
  case scheduled
  case all
  case account(String)

  var id: String {
    switch self {
    case .inbox:
      return "inbox"
    case .intake:
      return "intake"
    case .intakeBatch(let id):
      return "intake-\(id.uuidString)"
    case .scheduled:
      return "scheduled"
    case .all:
      return "all"
    case .account(let id):
      return "account-\(id)"
    }
  }

  static func defaultSelection(
    openAccounts: [Account],
    isFavourite: (String) -> Bool
  ) -> AccountsPane {
    if let favourite = openAccounts.first(where: { isFavourite($0.id) }) {
      return .account(favourite.id)
    }
    if let open = openAccounts.first {
      return .account(open.id)
    }
    return .all
  }
}

enum AccountsPaneSelection {
  static func reconciled(
    current: AccountsPane?,
    usesSplit: Bool,
    knownAccountIDs: Set<String>,
    canChooseDefault: Bool,
    defaultPane: AccountsPane
  ) -> AccountsPane? {
    var pane = current
    if case .account(let id) = pane, !knownAccountIDs.contains(id) {
      pane = nil
    }
    guard usesSplit else { return pane }
    if pane == nil, canChooseDefault {
      return defaultPane
    }
    return pane
  }
}

struct AccountsView: View {
  @Environment(AppModel.self) private var model
  @Environment(RootChromeState.self) private var chrome: RootChromeState?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  var usesSplit: Bool
  @State private var collapsedGroups: Set<String> = ["closed"]
  @State private var presentedSheet: AccountsSheet?
  @State private var groupPendingDeletion: CustomAccountGroup?
  @State private var pane: AccountsPane?
  @State private var columnVisibility = NavigationSplitViewVisibility.all

  var body: some View {
    @Bindable var screenshots = ScreenshotOfferController.shared
    Group {
      if usesSplit {
        NavigationSplitView(columnVisibility: $columnVisibility) {
          overview()
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        } detail: {
          NavigationStack {
            if let pane {
              detail(pane)
                .id(pane)
            } else {
              PhasePlaceholder(phase: model.referencePhase) {
                await model.refreshReferenceData()
              }
            }
          }
        }
        .navigationSplitViewStyle(.balanced)
      } else {
        NavigationStack {
          overview()
            .navigationDestination(item: $pane) { selected in
              detail(selected)
                .id(selected)
            }
        }
      }
    }
    .overlay(alignment: .bottom) {
      if let offer = screenshots.offer, screenshots.isEnabled {
        ScreenshotOfferToast(
          offer: offer,
          onAdd: {
            try? screenshots.review()
          },
          onDismiss: {
            screenshots.dismiss()
          }
        )
        .padding(.horizontal, 16)
        .padding(
          .bottom,
          RootChrome.usesSidebar(
            idiom: UIDevice.current.userInterfaceIdiom,
            horizontalSizeClass: horizontalSizeClass
          )
            ? RootChrome.toastBottomPadding(
              idiom: UIDevice.current.userInterfaceIdiom,
              horizontalSizeClass: horizontalSizeClass
            )
            : RootChrome.compactToastGap
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(Theme.Motion.arrive, value: screenshots.offer?.id)
    .onAppear {
      reconcilePane()
    }
    .onChange(of: model.accounts.map(\.id)) { _, _ in
      reconcilePane()
    }
    .onChange(of: model.referencePhase) { _, _ in
      reconcilePane()
    }
    .onChange(of: chrome?.pendingAccountID, initial: true) { _, accountID in
      // Opened from a Rewards card: show that account's register.
      guard let accountID else { return }
      chrome?.pendingAccountID = nil
      pane = .account(accountID)
    }
    .sheet(item: $presentedSheet) { sheet in
      Group {
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
        case .edit(let account):
          EditAccountSheet(account: account)
        case .newAccount:
          NewAccountSheet()
        }
      }
      .blocksCapturePresentation()
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

  private var defaultPane: AccountsPane {
    .defaultSelection(
      openAccounts: model.openAccounts,
      isFavourite: model.isAccountFavourite
    )
  }

  private var knownAccountIDs: Set<String> {
    Set(model.accounts.map(\.id))
  }

  private var canChooseDefaultPane: Bool {
    !model.accounts.isEmpty || model.referencePhase == .loaded
  }

  private func reconcilePane() {
    pane = AccountsPaneSelection.reconciled(
      current: pane,
      usesSplit: usesSplit,
      knownAccountIDs: knownAccountIDs,
      canChooseDefault: canChooseDefaultPane,
      defaultPane: defaultPane
    )
  }

  private func isShowing(_ candidate: AccountsPane) -> Bool {
    pane == candidate
  }

  @ViewBuilder
  private func detail(_ pane: AccountsPane) -> some View {
    switch pane {
    case .inbox:
      RegisterView(scope: .unapproved)
    case .intake:
      InboxListView()
    case .intakeBatch(let id):
      // Close pops the push on a phone and returns to the Inbox list in the split layout.
      IntakeReviewView(jobID: id, onClose: { self.pane = usesSplit ? .intake : nil })
    case .scheduled:
      ScheduledTransactionsView()
    case .all:
      RegisterView(scope: .all)
    case .account(let id):
      RegisterView(scope: .account(id))
    }
  }

  private func overview() -> some View {
    // Group construction includes each group's selected sort. Share one
    // snapshot between the emptiness checks and both bands for this render.
    let groups = model.accountListGroups()
    let collectionGroups = groups.filter { $0.kind == .collection }
    let indexGroups = groups.filter { $0.kind == .index }
    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if model.unsentChangeCount > 0 || model.outboxNotice != nil {
          OutboxCard()
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        IntakeInboxBand(
          onSeeAll: { pane = .intake },
          onOpen: { job in pane = .intakeBatch(job.id) }
        )

        if model.accounts.isEmpty, model.referencePhase != .loaded {
          PhasePlaceholder(phase: model.referencePhase) {
            await model.refreshReferenceData()
          }
        } else if model.accounts.isEmpty {
          ContentUnavailableView {
            Label("No Accounts", systemImage: "building.columns")
          } description: {
            Text("Add a bank account or card to start recording transactions.")
          } actions: {
            Button("New Account") {
              presentedSheet = .newAccount
            }
            .buttonStyle(.borderedProminent)
          }
          .frame(maxWidth: .infinity)
          .padding(.top, 48)
        } else {
          ledgerShortcuts
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
      .animation(Theme.Motion.standard, value: model.pendingRows.isEmpty)
    }
    .background(Theme.canvas)
    .navigationTitle("Accounts")
    .navigationBarTitleDisplayMode(.large)
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
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          presentedSheet = .newAccount
        } label: {
          Label("New Account", systemImage: "plus")
        }
        .tint(Theme.accent)
        DestinationsMenu()
      }
    }
    .refreshable {
      await model.refresh(
        slices: TabRefresh.accounts(
          referencePhase: model.referencePhase,
          isReferenceProvisional: model.referenceIsProvisional
        ),
        quiet: false
      )
    }
    .task(id: accountUsageTaskID) {
      guard usesMostUsedSort, model.accountUsagePhase != .loaded else {
        return
      }
      await model.refreshAccountUsageLast30Days()
    }
  }

  private var ledgerShortcuts: some View {
    let newTransactions = LedgerShortcutTile(
      icon: "tray",
      title: "New",
      status: LedgerShortcutStatus.newQueue(count: model.unapprovedBadgeCount),
      isSelected: isShowing(.inbox)
    ) {
      pane = .inbox
    }

    let scheduled = LedgerShortcutTile(
      icon: "calendar.badge.clock",
      title: "Scheduled",
      status: LedgerShortcutStatus.scheduled(
        phase: model.scheduledTransactionsPhase,
        count: model.scheduledTransactions.count
      ),
      isSelected: isShowing(.scheduled)
    ) {
      pane = .scheduled
    }

    let allTransactions = LedgerShortcutTile(
      icon: "list.bullet.rectangle",
      title: "All",
      status: .quiet,
      isSelected: isShowing(.all)
    ) {
      pane = .all
    }

    return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
      if usesColumnShortcuts {
        GridRow {
          newTransactions
          scheduled
          allTransactions
        }
      } else {
        GridRow {
          newTransactions
        }
        GridRow {
          scheduled
        }
        GridRow {
          allTransactions
        }
      }
    }
  }

  private var usesColumnShortcuts: Bool {
    dynamicTypeSize < .xxLarge
  }

  private func accountGroupSection(_ group: AccountListGroup) -> some View {
    let isCollapsed = collapsedGroups.contains(group.id)
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button {
          withAnimation(Theme.Motion.standard) {
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
              .rollingNumber(group.total)
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
          .transition(Self.groupCardTransition)
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
          .transition(Self.groupCardTransition)
        }
      }
    }
  }

  /// Collapsing a group folds its card up under the header.
  private static let groupCardTransition = AnyTransition.opacity
    .combined(with: .scale(scale: 0.96, anchor: .top))

  private func accountRow(_ account: Account) -> some View {
    let selected = isShowing(.account(account.id))
    return Button {
      pane = .account(account.id)
    } label: {
      HStack(alignment: .center, spacing: 8) {
        Text(account.displayIcon)
          .font(.title3)
          .frame(width: 32)
          .accessibilityHidden(true)

        Group {
          if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
              Text(account.name)
                .font(selected ? .body.weight(.semibold) : .body)
                .foregroundStyle(Theme.textPrimary)
              accountBalance(account)
            }
          } else {
            HStack {
              Text(account.name)
                .font(selected ? .body.weight(.semibold) : .body)
                .foregroundStyle(Theme.textPrimary)
              Spacer()
              accountBalance(account)
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
      .contentShape(Rectangle())
      .background(selected ? Theme.accent.opacity(0.12) : Color.clear)
      .animation(Theme.Motion.standard, value: selected)
    }
    .buttonStyle(.cardRow)
    .accessibilityLabel("\(account.displayIcon) \(account.name)")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityValue(MoneyCodec.displayString(for: account.balance, currencyFormat: model.currencyFormat))
    .accessibilityActions {
      if !account.closed {
        Button(model.isAccountFavourite(account.id) ? "Remove from Favourites" : "Add to Favourites") {
          withAnimation(Theme.Motion.standard) {
            model.toggleAccountFavourite(account.id)
          }
        }
      }
      Button("Groups") {
        presentedSheet = .memberships(account.id)
      }
      Button("Edit Account") {
        presentedSheet = .edit(account)
      }
    }
    .contextMenu {
      if !account.closed {
        Button(model.isAccountFavourite(account.id) ? "Remove from Favourites" : "Add to Favourites") {
          withAnimation(Theme.Motion.standard) {
            model.toggleAccountFavourite(account.id)
          }
        }
      }
      Button("Groups") {
        presentedSheet = .memberships(account.id)
      }
      Button("Edit Account") {
        presentedSheet = .edit(account)
      }
    }
  }

  private func accountBalance(_ account: Account) -> some View {
    Text(MoneyCodec.displayString(for: account.balance, currencyFormat: model.currencyFormat))
      .monospacedDigit()
      .foregroundStyle(account.balance == 0 ? .secondary : Theme.amountColour(account.balance))
      .rollingNumber(account.balance)
      .fixedSize(horizontal: true, vertical: false)
  }

  private func groupSortBinding(_ groupID: String) -> Binding<AccountGroupSort> {
    Binding(
      get: { model.sortForAccountGroup(groupID) },
      set: { model.setSort($0, forAccountGroup: groupID) }
    )
  }

  private enum LedgerShortcutStatus {
    case quiet
    case detail(String)
    case busy(String)

    static func scheduled(phase: LoadPhase, count: Int) -> LedgerShortcutStatus {
      switch phase {
      case .loaded:
        .detail(count == 1 ? "1 upcoming transaction" : "\(count) upcoming transactions")
      case .loading:
        .busy("Loading upcoming transactions")
      case .idle, .failed:
        .quiet
      }
    }

    static func newQueue(count: Int) -> LedgerShortcutStatus {
      switch count {
      case 0:
        .quiet
      case 1:
        .detail("1 new transaction")
      default:
        .detail("\(count) new transactions")
      }
    }

    var detail: String? {
      switch self {
      case .quiet: nil
      case .detail(let text), .busy(let text): text
      }
    }

    var isBusy: Bool {
      if case .busy = self { true } else { false }
    }
  }

  private struct LedgerShortcutTile: View {
    let icon: String
    let title: String
    let status: LedgerShortcutStatus
    var isSelected = false
    let action: () -> Void
    @ScaledMetric(relativeTo: .title2) private var iconSlot = 32.0

    var body: some View {
      Button(action: action) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
              .font(.title2)
              .foregroundStyle(Theme.accent)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
              .accessibilityHidden(true)
            if status.isBusy {
              ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            }
          }
          .frame(height: iconSlot)

          Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .ynabCard()
        .overlay {
          RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
        }
        .animation(Theme.Motion.standard, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(status.detail ?? "")
      }
      .buttonStyle(.pressable)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private struct OutboxCard: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDiscard: OutboxItem?

    var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: "arrow.triangle.2.circlepath")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text(title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            Task {
              // A successful drain schedules its own narrow refresh.
              await model.drainOutbox(trigger: .manual)
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

        if let notice = model.outboxNotice {
          Divider().padding(.leading, 16)
          Label(notice, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(Theme.outflow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }

        ForEach(listedItems) { item in
          Divider().padding(.leading, 16)
          itemRow(item)
        }
      }
      .ynabCard()
      .binaryConfirm(
        "Discard this change? It hasn’t reached the server.",
        presenting: $pendingDiscard,
        confirm: .destructive("Discard Change")
      ) { item in
        model.discardPending(item.id)
      }
    }

    private var title: String {
      let count = model.unsentChangeCount
      return count == 1 ? "1 change not sent yet" : "\(count) changes not sent yet"
    }

    private var subtitle: String {
      let rejected = rejectedItems.count
      if rejected > 0 {
        return rejected == 1
          ? "The server refused 1. Retry or discard it."
          : "The server refused \(rejected). Retry or discard them."
      }
      return "Shown here until they reach the server"
    }

    private var rejectedItems: [OutboxItem] {
      model.outboxItems.filter { item in
        if case .rejected = item.status {
          return true
        }
        return false
      }
    }

    /// Every change, refused ones first, so any of them can be discarded.
    private var listedItems: [OutboxItem] {
      model.outboxItems
    }

    private func itemRow(_ item: OutboxItem) -> some View {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(item.action) · \(item.payeeName ?? "Transaction")")
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
          if let isoDate = item.isoDate {
            Text(LedgerDate.friendlyString(fromISO: isoDate))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          if case .rejected(let error) = item.status {
            Text(error)
              .font(.footnote)
              .foregroundStyle(Theme.outflow)
              .lineLimit(2)
          } else if item.status == .sending {
            Text("Sending…")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if let amount = item.signedAmount {
          Text(MoneyCodec.signedDisplayString(for: amount, currencyFormat: model.currencyFormat))
            .monospacedDigit()
            .foregroundStyle(Theme.registerAmountColour(amount))
        }
        if case .rejected = item.status {
          Button {
            model.retryPending(item.id)
          } label: {
            Image(systemName: "arrow.clockwise")
              .font(.footnote)
              .foregroundStyle(Theme.accent)
              .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Retry \(item.payeeName ?? "change")")
        }
        if item.status != .sending {
          Button {
            pendingDiscard = item
          } label: {
            Image(systemName: "trash")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Discard \(item.payeeName ?? "change")")
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
    }
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
  case edit(Account)
  case newAccount

  var id: String {
    switch self {
    case .newGroup(let accountID): "new-group-\(accountID ?? "none")"
    case .manageGroups: "manage-groups"
    case .favourites: "favourites"
    case .memberships(let accountID): "memberships-\(accountID)"
    case .editGroup(let group): "edit-\(group.id)"
    case .reorder(let group): "reorder-\(group.id)"
    case .edit(let account): "edit-account-\(account.id)"
    case .newAccount: "new-account"
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
