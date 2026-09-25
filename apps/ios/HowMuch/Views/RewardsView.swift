import SwiftUI

struct RewardsBoardPreferences: Codable, Equatable {
  var hiddenCardIDs: Set<String> = []
  var cardOrder: [String] = []
  var collapsedGroups: Set<String> = []
  /// nil until chosen: Featured when any card is featured, otherwise All Cards.
  var featuredOnly: Bool? = nil
  var groupsByType = false

  private enum CodingKeys: String, CodingKey {
    case hiddenCardIDs, cardOrder, collapsedGroups, featuredOnly, groupsByType
  }

  func orderedIDs(_ available: [String]) -> [String] {
    var remaining = Set(available)
    return (cardOrder + available).filter { remaining.remove($0) != nil }
  }

  /// Reorders `ids` among the slots they already occupy, so moving cards in a
  /// filtered or grouped subset keeps every other card where it was.
  mutating func reorder(_ ids: [String], within available: [String]) {
    var seen = Set<String>()
    var sequence = (cardOrder + available).filter { seen.insert($0).inserted }
    let moved = Set(ids)
    let slots = sequence.indices.filter { moved.contains(sequence[$0]) }
    let known = Set(sequence)
    for (slot, id) in zip(slots, ids.filter { known.contains($0) }) {
      sequence[slot] = id
    }
    cardOrder = sequence
  }

  static func storageKey(planID: String) -> String { "howmuch.rewards.board.v1.\(planID)" }

  static func load(planID: String, from defaults: UserDefaults = .standard) -> Self {
    guard let data = defaults.data(forKey: storageKey(planID: planID)),
      let preferences = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
    return preferences
  }

  func save(planID: String, to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: Self.storageKey(planID: planID))
  }
}

extension RewardsBoardPreferences {
  /// Tolerates missing keys, so preferences saved before a field existed keep
  /// their hidden cards and ordering.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hiddenCardIDs = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenCardIDs) ?? []
    cardOrder = try container.decodeIfPresent([String].self, forKey: .cardOrder) ?? []
    collapsedGroups = try container.decodeIfPresent(Set<String>.self, forKey: .collapsedGroups) ?? []
    featuredOnly = try container.decodeIfPresent(Bool.self, forKey: .featuredOnly)
    groupsByType = try container.decodeIfPresent(Bool.self, forKey: .groupsByType) ?? false
  }
}

struct RewardsReportFilter {
  enum Mode: String, CaseIterable, Identifiable {
    case current = "Current card periods"
    case historical = "Historical range"

    var id: String { rawValue }
  }

  var mode: Mode = .current
  var useAsOfDate = false
  var asOfDate = Date()
  var range = ReportRange()
  var scope = ReportScope()

  /// The as-of day in Asia/Singapore, or nil for today (the server decides).
  var asOfISO: String? { useAsOfDate ? RewardsCalendar.isoString(asOfDate) : nil }

  // An omitted lower bound selects current card periods on the rewards API.
  // All Time must instead send a comparison-only lower bound for aggregation.
  var from: String? { mode == .current ? nil : (range.fromISO ?? "0001-01-01") }
  var to: String? { mode == .current ? asOfISO : range.toISO }
  var accountIDs: [String] { scope.accountIDs.sorted() }
  var key: String {
    "\(mode.rawValue)|\(useAsOfDate)|\(RewardsCalendar.isoString(asOfDate))|\(range.key)|\(scope.key)"
  }
}

enum RewardsSheet: Identifiable {
  case detail(String)
  case editor(RewardCardEditorDestination)
  case customise
  case valuation
  case importExport
  case accounts
  case asOfDate

  var id: String {
    switch self {
    case .detail(let cardID): return "detail-\(cardID)"
    case .editor(let destination): return "editor-\(destination.id)"
    case .customise: return "customise"
    case .valuation: return "valuation"
    case .importExport: return "import-export"
    case .accounts: return "accounts"
    case .asOfDate: return "as-of-date"
    }
  }
}

enum RewardsRoute: Hashable {
  case summary
  case rangeReport
}

/// One report's rows, ordered and filtered for the board.
private struct RewardsBoard {
  let ordered: [RewardRowProjection]
  let visible: [RewardRowProjection]
  let featuredIDs: Set<String>
  let featuredOnly: Bool
  let hiddenCount: Int
  let unhiddenCount: Int
  let summary: RewardsBoardSummary

  init(report: RewardsReport, preferences: RewardsBoardPreferences, currencyFormat: CurrencyFormat?) {
    let projections = report.cards.map { RewardRowProjection.make(row: $0, asOf: report.asOf, isRange: false) }
    let byID = Dictionary(projections.map { ($0.cardID, $0) }, uniquingKeysWith: { first, _ in first })
    ordered = preferences.orderedIDs(RewardsBoardOrdering.fallbackOrder(projections)).compactMap { byID[$0] }
    featuredIDs = Set(report.cards.filter(\.card.featured).map(\.id))
    featuredOnly = preferences.featuredOnly ?? !featuredIDs.isEmpty
    let hidden = preferences.hiddenCardIDs
    hiddenCount = ordered.filter { hidden.contains($0.cardID) }.count
    unhiddenCount = ordered.count - hiddenCount
    let featuredSet = self.featuredIDs
    let onlyFeatured = self.featuredOnly
    visible = ordered.filter { (!onlyFeatured || featuredSet.contains($0.cardID)) && !hidden.contains($0.cardID) }
    summary = RewardsBoardSummary(report: report, projections: projections, currencyFormat: currencyFormat)
  }
}

struct RewardsView: View {
  @Environment(AppModel.self) private var model
  @Environment(RootChromeState.self) private var chrome: RootChromeState?
  @State private var filter: RewardsReportFilter
  @State private var report: RewardsReport?
  @State private var reportPlanID: String?
  @State private var phase: LoadPhase = .idle
  @State private var sheet: RewardsSheet?
  @State private var route: RewardsRoute?
  @State private var preferencesByPlan: [String: RewardsBoardPreferences] = [:]
  @State private var rewardAccountIDsByPlan: [String: Set<String>] = [:]

  init(filter: RewardsReportFilter = RewardsReportFilter()) {
    // The board always shows current card periods; ranges live in Range Report.
    var board = filter
    board.mode = .current
    _filter = State(initialValue: board)
  }

  var body: some View {
    let board = currentReport.map {
      RewardsBoard(report: $0, preferences: preferences, currencyFormat: model.currencyFormat)
    }
    List {
      controlBar(board)
      if let report = currentReport, let board {
        if !report.cards.isEmpty {
          summaryRow(board)
        }
        if let asOf = filter.asOfISO {
          pastDateBanner(asOf)
        }
        if let message = phase.errorMessage {
          errorRow(message)
        }
        boardRows(report, board: board)
      } else {
        PhasePlaceholder(phase: phase) {
          await fetch()
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle("Rewards")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        DestinationsMenu {
          rewardsMenuItems
        }
      }
    }
    .navigationDestination(item: $route) { route in
      switch route {
      case .summary:
        RewardsReportScreen(filter: filter, allowsRange: false)
      case .rangeReport:
        RewardsReportScreen(filter: rangeFilter, allowsRange: true)
      }
    }
    .sheet(item: $sheet) { sheet in
      sheetContent(sheet)
        .blocksCapturePresentation()
    }
    .task(id: fetchKey) {
      await fetch()
    }
    .refreshable {
      await fetch()
    }
    .onChange(of: chrome?.pendingRewardsCardID, initial: true) { _, _ in
      consumeCardRequest()
    }
  }

  // MARK: Board

  private var currentReport: RewardsReport? {
    reportPlanID == model.settings.planID ? report : nil
  }

  @ViewBuilder
  private func boardRows(_ report: RewardsReport, board: RewardsBoard) -> some View {
    if report.cards.isEmpty {
      if filter.scope.accountIDs.isEmpty {
        emptyState(
          "No Reward Cards",
          systemImage: "creditcard",
          description: "Add a card to track minimums and caps, or import your Rewards Tracker configuration."
        ) {
          Button("Add Card") { sheet = .editor(.create) }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
          Button("Import Rewards") { sheet = .importExport }
        }
      } else {
        emptyState(
          "No Cards in These Accounts",
          systemImage: "building.columns",
          description: "None of the selected accounts has a reward card."
        ) {
          Button("Show All Accounts") { filter.scope.accountIDs = [] }
        }
      }
    } else if board.visible.isEmpty {
      if board.unhiddenCount == 0 {
        emptyState(
          "All Cards Hidden",
          systemImage: "eye.slash",
          description: "Hidden cards still count in the totals above."
        ) {
          Button("Show Hidden Cards") { updatePreferences { $0.hiddenCardIDs = [] } }
        }
      } else {
        emptyState(
          "No Featured Cards",
          systemImage: "star",
          description: "None of the visible cards is featured."
        ) {
          Button("Show All Cards") { updatePreferences { $0.featuredOnly = false } }
        }
      }
    } else if preferences.groupsByType {
      typeSection("Cashback", kind: .cashback, rows: board.visible)
      typeSection("Miles", kind: .miles, rows: board.visible)
    } else {
      ForEach(board.visible, id: \.cardID) { projection in
        boardRow(projection)
      }
    }
    if board.hiddenCount > 0, !board.visible.isEmpty {
      Button {
        sheet = .customise
      } label: {
        Text("\(board.hiddenCount) hidden · Show")
          .font(.footnote.weight(.medium))
          .foregroundStyle(Theme.accent)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(.plain)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .accessibilityHint("Opens Customise Board to show hidden cards.")
    }
  }

  @ViewBuilder
  private func typeSection(_ title: String, kind: RewardKind, rows: [RewardRowProjection]) -> some View {
    let matching = rows.filter { $0.rewardType == kind }
    if !matching.isEmpty {
      let isExpanded = !preferences.collapsedGroups.contains(kind.rawValue)
      Button {
        updatePreferences {
          if isExpanded {
            _ = $0.collapsedGroups.insert(kind.rawValue)
          } else {
            _ = $0.collapsedGroups.remove(kind.rawValue)
          }
        }
      } label: {
        HStack {
          Text("\(title) · \(matching.count)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.rowSecondary)
          Spacer()
          Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.rowSecondary)
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 0, trailing: 20))
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .accessibilityLabel("\(title), \(matching.count) cards")
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      if isExpanded {
        ForEach(matching, id: \.cardID) { projection in
          boardRow(projection)
        }
      }
    }
  }

  private func boardRow(_ projection: RewardRowProjection) -> some View {
    let text = RewardRowText(projection, currencyFormat: model.currencyFormat)
    return Button {
      sheet = .detail(projection.cardID)
    } label: {
      RewardFilledRow(projection: projection, icon: icon(for: projection.accountID), currencyFormat: model.currencyFormat)
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button {
        hide(projection.cardID)
      } label: {
        Label("Hide", systemImage: "eye.slash")
      }
      .tint(.gray)
    }
    .contextMenu {
      Button {
        sheet = .detail(projection.cardID)
      } label: {
        Label("Show Details", systemImage: "info.circle")
      }
      Button {
        sheet = .editor(.edit(projection.cardID))
      } label: {
        Label("Edit Card", systemImage: "pencil")
      }
      if let chrome {
        Button {
          chrome.showAccount(projection.accountID)
        } label: {
          Label("View Transactions", systemImage: "list.bullet.rectangle")
        }
      }
      Button {
        hide(projection.cardID)
      } label: {
        Label("Hide on This Device", systemImage: "eye.slash")
      }
    }
    .accessibilityLabel(projection.title)
    .accessibilityValue(text.accessibilityValue)
    .accessibilityHint("Shows details.")
    .accessibilityAction(named: "Edit Card") {
      sheet = .editor(.edit(projection.cardID))
    }
    .accessibilityAction(named: "Hide") {
      hide(projection.cardID)
    }
  }

  private func summaryRow(_ board: RewardsBoard) -> some View {
    var line = board.summary.line
    if board.visible.count < board.ordered.count {
      line += " · showing \(board.visible.count) of \(board.ordered.count)"
    }
    return Button {
      route = .summary
    } label: {
      Text("\(line)\u{00A0}\(Image(systemName: "chevron.forward"))")
        .font(.footnote)
        .foregroundStyle(Theme.rowSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.plain)
    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .accessibilityLabel("Summary for current periods, \(line)")
    .accessibilityHint("Opens totals and the breakdown.")
  }

  private func pastDateBanner(_ asOf: String) -> some View {
    HStack(spacing: 8) {
      Label(
        "Showing \(RewardsCalendar.shortLabel(asOf, referenceISO: RewardsCalendar.today()))",
        systemImage: "clock.arrow.circlepath"
      )
      .font(.subheadline)
      .foregroundStyle(Theme.textPrimary)
      Spacer(minLength: 8)
      Button("Back to Today") {
        backToToday()
      }
      .buttonStyle(.borderless)
      .font(.subheadline.weight(.semibold))
      .tint(Theme.accent)
      .frame(minHeight: 44)
    }
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }

  private func errorRow(_ message: String) -> some View {
    Label(message, systemImage: "wifi.exclamationmark")
      .font(.footnote)
      .foregroundStyle(Theme.rowSecondary)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
  }

  private func emptyState<Actions: View>(
    _ title: String,
    systemImage: String,
    description: String,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(description)
    } actions: {
      actions()
    }
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }

  // MARK: Controls

  private func controlBar(_ board: RewardsBoard?) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 4) {
        featuredMenu(board)
        Spacer(minLength: 8)
        accountsButton
        dateMenu
      }
      VStack(alignment: .leading, spacing: 0) {
        featuredMenu(board)
        Divider()
        accountsButton
        dateMenu
      }
    }
    .padding(.horizontal, 6)
    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }

  private func menuLabel(_ title: String, systemImage: String? = nil) -> some View {
    HStack(spacing: 6) {
      if let systemImage {
        Image(systemName: systemImage)
          .foregroundStyle(Theme.rowSecondary)
      }
      Text(title)
        .foregroundStyle(Theme.textPrimary)
      Image(systemName: "chevron.down")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Theme.rowSecondary)
    }
    .padding(.horizontal, 10)
    .frame(minHeight: 44)
    .contentShape(.rect)
  }

  private func featuredMenu(_ board: RewardsBoard?) -> some View {
    let featuredOnly = board?.featuredOnly ?? (preferences.featuredOnly ?? true)
    let title = featuredOnly ? "Featured" : "All Cards"
    return Menu {
      Picker("Cards", selection: Binding(
        get: { featuredOnly },
        set: { value in updatePreferences { $0.featuredOnly = value } }
      )) {
        Text("Featured (\(board?.featuredIDs.count ?? 0))").tag(true)
        Text("All Cards (\(board?.ordered.count ?? 0))").tag(false)
      }
      .pickerStyle(.inline)
      Toggle("Group by Reward Type", isOn: Binding(
        get: { preferences.groupsByType },
        set: { value in updatePreferences { $0.groupsByType = value } }
      ))
    } label: {
      menuLabel(title)
    }
    .accessibilityLabel("Cards, \(title)")
  }

  @ViewBuilder
  private var accountsButton: some View {
    if !filter.scope.accountIDs.isEmpty {
      let count = filter.scope.accountIDs.count
      HStack(spacing: 0) {
        Button {
          sheet = .accounts
        } label: {
          Label("\(count) Account\(count == 1 ? "" : "s")", systemImage: "building.columns")
            .padding(.leading, 10)
            .frame(minHeight: 44)
        }
        .accessibilityHint("Choose which accounts the report covers.")
        Button {
          filter.scope.accountIDs = []
        } label: {
          Image(systemName: "xmark.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .frame(minWidth: 36, minHeight: 44)
        }
        .accessibilityLabel("Show all accounts")
      }
      .buttonStyle(.borderless)
      .tint(Theme.accent)
    }
  }

  private var dateMenu: some View {
    let title = filter.asOfISO.map { RewardsCalendar.shortLabel($0, referenceISO: RewardsCalendar.today()) } ?? "Today"
    return Menu {
      if filter.useAsOfDate {
        Button {
          backToToday()
        } label: {
          Label("Back to Today", systemImage: "arrow.uturn.backward")
        }
      } else {
        Button {} label: {
          Label("Today", systemImage: "checkmark")
        }
      }
      Button {
        sheet = .asOfDate
      } label: {
        Label("Choose Date…", systemImage: "calendar")
      }
      Section {
        Button {
          route = .rangeReport
        } label: {
          Label("Range Report…", systemImage: "calendar.badge.clock")
        }
      }
    } label: {
      menuLabel(title, systemImage: "calendar")
    }
    .accessibilityLabel("As of, \(title)")
  }

  @ViewBuilder
  private var rewardsMenuItems: some View {
    Button {
      sheet = .editor(.create)
    } label: {
      Label("Add Card", systemImage: "plus.rectangle.on.rectangle")
    }
    Button {
      sheet = .customise
    } label: {
      Label("Customise Board…", systemImage: "slider.horizontal.3")
    }
    Button {
      sheet = .accounts
    } label: {
      Text("Accounts…")
      Text(filter.scope.accountIDs.isEmpty ? "All accounts" : "\(filter.scope.accountIDs.count) selected")
      Image(systemName: "building.columns")
    }
    Button {
      sheet = .valuation
    } label: {
      Text("Miles Valuation…")
      if let valuation = currentReport?.milesValuation {
        Text("\(valuation.formatted()) per mile")
      }
      Image(systemName: "airplane")
    }
    Button {
      sheet = .importExport
    } label: {
      Label("Import & Export…", systemImage: "square.and.arrow.up.on.square")
    }
  }

  // MARK: Sheets

  @ViewBuilder
  private func sheetContent(_ sheet: RewardsSheet) -> some View {
    switch sheet {
    case .detail(let cardID):
      detailSheet(cardID)
    case .editor(let destination):
      RewardCardEditorView(cardID: destination.cardID)
    case .customise:
      customiseSheet
    case .valuation:
      RewardsValuationSheet(current: currentReport?.milesValuation)
    case .importExport:
      NavigationStack {
        RewardsImportView()
      }
    case .accounts:
      AccountScopePicker(
        selection: $filter.scope.accountIDs,
        candidateIDs: rewardAccountIDsByPlan[model.settings.planID]
      )
    case .asOfDate:
      RewardsAsOfDateSheet(filter: $filter)
    }
  }

  @ViewBuilder
  private func detailSheet(_ cardID: String) -> some View {
    // Looked up live, so edits and refreshes update the open sheet.
    if let report = currentReport, let row = report.cards.first(where: { $0.id == cardID }) {
      RewardCardDetailSheet(
        row: row,
        asOf: report.asOf,
        icon: icon(for: row.accountId),
        currencyFormat: model.currencyFormat,
        canOpenAccount: chrome != nil,
        onEdit: { sheet = .editor(.edit(cardID)) },
        onOpenAccount: {
          sheet = nil
          chrome?.showAccount(row.accountId)
        }
      )
    } else {
      ContentUnavailableView(
        "Card Unavailable",
        systemImage: "creditcard",
        description: Text("This card is no longer in the report.")
      )
      .presentationDetents([.medium])
    }
  }

  private var customiseSheet: some View {
    let ordered = currentReport.map {
      RewardsBoard(report: $0, preferences: preferences, currencyFormat: model.currencyFormat).ordered
    } ?? []
    let available = ordered.map(\.cardID)
    return NavigationStack {
      List {
        Section {
          Text("Device-local for this plan. Drag to reorder, and show or hide cards, including cards excluded by Featured. These choices do not change rewards, totals or configuration exports.")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Button("Show All Cards") { updatePreferences { $0.hiddenCardIDs = [] } }
          Button("Reset Display Preferences") { updatePreferences { $0 = RewardsBoardPreferences() } }
        }
        if preferences.groupsByType {
          customiseSection("Cashback", rows: ordered.filter { $0.rewardType == .cashback }, available: available)
          customiseSection("Miles", rows: ordered.filter { $0.rewardType == .miles }, available: available)
        } else {
          customiseSection("Cards", rows: ordered, available: available)
        }
      }
      .environment(\.editMode, .constant(.active))
      .navigationTitle("Customise Board")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { sheet = nil }
        }
      }
    }
  }

  @ViewBuilder
  private func customiseSection(_ title: String, rows: [RewardRowProjection], available: [String]) -> some View {
    if !rows.isEmpty {
      Section(title) {
        ForEach(rows, id: \.cardID) { row in
          Toggle(isOn: Binding(
            get: { !preferences.hiddenCardIDs.contains(row.cardID) },
            set: { visible in
              updatePreferences {
                if visible {
                  _ = $0.hiddenCardIDs.remove(row.cardID)
                } else {
                  _ = $0.hiddenCardIDs.insert(row.cardID)
                }
              }
            }
          )) {
            HStack(spacing: 6) {
              if let icon = icon(for: row.accountID) {
                Text(icon).accessibilityHidden(true)
              }
              Text(row.title)
            }
          }
          .accessibilityLabel("Show \(row.title)")
        }
        .onMove { offsets, destination in
          var ids = rows.map(\.cardID)
          ids.move(fromOffsets: offsets, toOffset: destination)
          updatePreferences { $0.reorder(ids, within: available) }
        }
      }
    }
  }

  // MARK: State

  private var fetchKey: String {
    "\(model.settings.planID)|\(model.rewardsRefreshGeneration)|\(filter.key)"
  }

  private var rangeFilter: RewardsReportFilter {
    var range = RewardsReportFilter(mode: .historical)
    range.scope = filter.scope
    return range
  }

  private var preferences: RewardsBoardPreferences {
    preferencesByPlan[model.settings.planID] ?? .load(planID: model.settings.planID)
  }

  private func updatePreferences(_ change: (inout RewardsBoardPreferences) -> Void) {
    let planID = model.settings.planID
    var next = preferences
    change(&next)
    // Hiding, collapsing and filtering move rows rather than redrawing the board.
    withAnimation(Theme.Motion.standard) {
      preferencesByPlan[planID] = next
    }
    next.save(planID: planID)
  }

  private func hide(_ cardID: String) {
    updatePreferences { $0.hiddenCardIDs.insert(cardID) }
  }

  private func icon(for accountID: String) -> String? {
    model.accounts.first { $0.id == accountID }?.displayIcon
  }

  private func backToToday() {
    filter.useAsOfDate = false
    filter.asOfDate = Date()
  }

  /// Opens the card a register link asked for, widening the account scope or
  /// date first if they exclude it.
  private func consumeCardRequest() {
    guard let chrome, let cardID = chrome.pendingRewardsCardID, let report = currentReport else { return }
    route = nil
    if report.cards.contains(where: { $0.id == cardID }) {
      chrome.pendingRewardsCardID = nil
      sheet = .detail(cardID)
    } else if !filter.scope.accountIDs.isEmpty || filter.useAsOfDate {
      filter.scope.accountIDs = []
      backToToday()
    } else {
      chrome.pendingRewardsCardID = nil
    }
  }

  private func fetch() async {
    let planID = model.settings.planID
    let key = fetchKey
    phase = .loading
    do {
      let next = try await model.apiClient.fetchRewards(
        planID: planID,
        from: filter.from,
        to: filter.to,
        accountIDs: filter.accountIDs,
        group: .flag
      )
      guard key == fetchKey, planID == model.settings.planID else {
        return
      }
      withAnimation(Theme.Motion.arrive) {
        report = next
        reportPlanID = planID
        phase = .loaded
      }
      if filter.accountIDs.isEmpty {
        rewardAccountIDsByPlan[planID] = Set(next.cards.map(\.accountId))
      }
      consumeCardRequest()
    } catch {
      guard key == fetchKey, planID == model.settings.planID else {
        return
      }
      if error is CancellationError || (error as? URLError)?.code == .cancelled {
        return
      }
      phase = .failed(error.localizedDescription)
    }
  }
}

enum RewardCardEditorDestination: Identifiable {
  case create
  case edit(String)

  var id: String {
    switch self {
    case .create:
      return "new"
    case .edit(let cardID):
      return cardID
    }
  }

  var cardID: String? {
    switch self {
    case .create:
      return nil
    case .edit(let cardID):
      return cardID
    }
  }
}

// MARK: - Filled row

/// A rounded row whose whole background is the progress track. Text colours
/// never change across the fill edge.
struct RewardFilledRow: View {
  let projection: RewardRowProjection
  var icon: String?
  let currencyFormat: CurrencyFormat?
  var showsChevron = true
  /// Off in the detail sheet, whose navigation title already names the card.
  var showsTitle = true

  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.layoutDirection) private var layoutDirection
  @ScaledMetric(relativeTo: .body) private var verticalPadding = 14.0
  @ScaledMetric(relativeTo: .body) private var horizontalPadding = 16.0

  private static let cornerRadius: CGFloat = 18

  var body: some View {
    let text = RewardRowText(projection, currencyFormat: currencyFormat)
    let palette = RewardTonePalette.palette(for: projection.tone)
    let increased = contrast == .increased
    VStack(alignment: .leading, spacing: 3) {
      if showsTitle {
        titleLine
      }
      actionLine(text, palette: palette)
      if let basis = text.basisLine {
        Text(basis)
          .font(.subheadline)
          .monospacedDigit()
          .foregroundStyle(Theme.rowSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(text.exceptionLines, id: \.self) { line in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(palette.ink)
            .accessibilityHidden(true)
          Text(line)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote.weight(.medium))
        .padding(.top, 2)
      }
    }
    .padding(.vertical, verticalPadding)
    .padding(.horizontal, horizontalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      ZStack(alignment: .leading) {
        palette.track
        if let fill = projection.fill {
          LeadingFill(fraction: fill, rightToLeft: layoutDirection == .rightToLeft)
            .fill(palette.fill)
        }
      }
      .animation(reduceMotion ? nil : .smooth, value: projection.fill)
    }
    .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
    .overlay {
      if increased {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
      }
    }
    .contentShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(projection.title)
    .accessibilityValue(text.accessibilityValue)
  }

  private var titleLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if let icon {
        Text(icon)
          .font(.headline)
          .accessibilityHidden(true)
      }
      Text(projection.title)
        .font(.headline)
        .foregroundStyle(Theme.textPrimary)
        .lineLimit(2)
      Spacer(minLength: 8)
      if showsChevron {
        Image(systemName: "chevron.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Theme.rowSecondary)
          .accessibilityHidden(true)
      }
    }
  }

  @ViewBuilder
  private func actionLine(_ text: RewardRowText, palette: RewardTonePalette) -> some View {
    let headline = headlineText(text)
    let deadline = text.deadline.map { value in
      Text(value)
        .font(.subheadline.weight(text.isUrgent ? .semibold : .regular))
        .foregroundStyle(text.isUrgent ? palette.ink : Theme.rowSecondary)
    }
    let stacked = VStack(alignment: .leading, spacing: 2) {
      headline
        .fixedSize(horizontal: false, vertical: true)
      deadline
    }
    if dynamicTypeSize.isAccessibilitySize {
      stacked
    } else {
      // The deadline drops below rather than breaking the action mid-phrase.
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          headline
            .lineLimit(1)
          Spacer(minLength: 8)
          deadline
        }
        stacked
      }
    }
  }

  private func headlineText(_ text: RewardRowText) -> Text {
    if let amount = text.amount {
      return Text("\(Text(amount).font(.title2.bold()).monospacedDigit()) \(text.actionLabel)")
        .font(.body)
        .foregroundStyle(Theme.textPrimary)
    }
    return Text(text.actionLabel)
      .font(.title3.weight(.semibold))
      .foregroundStyle(projection.tone == .failed ? Theme.outflow : Theme.textPrimary)
  }
}

/// The leading part of a rect, square-edged so small values read as a quantity.
struct LeadingFill: Shape {
  var fraction: Double
  var rightToLeft = false

  var animatableData: Double {
    get { fraction }
    set { fraction = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let width = rect.width * min(1, max(0, fraction))
    let x = rightToLeft ? rect.maxX - width : rect.minX
    return Path(CGRect(x: x, y: rect.minY, width: width, height: rect.height))
  }
}

// MARK: - Detail sheet

struct RewardCardDetailSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var contentHeight: CGFloat = 0
  let row: RewardsCardRow
  let asOf: String?
  let icon: String?
  let currencyFormat: CurrencyFormat?
  let canOpenAccount: Bool
  let onEdit: () -> Void
  let onOpenAccount: () -> Void

  var body: some View {
    let projection = RewardRowProjection.make(row: row, asOf: asOf, isRange: false)
    NavigationStack {
      List {
        Section {
          RewardFilledRow(
            projection: projection, icon: icon, currencyFormat: currencyFormat, showsChevron: false, showsTitle: false
          )
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
        }
        .listSectionSpacing(12)
        Section {
          if let period = currentPeriod {
            LabeledContent("Period", value: "\(short(period.start)) – \(short(period.end))")
          }
          if let asOf, asOf < RewardsCalendar.today() {
            Label("Showing \(short(asOf))", systemImage: "clock.arrow.circlepath")
              .foregroundStyle(.secondary)
          }
          if canOpenAccount {
            Button {
              onOpenAccount()
            } label: {
              Label("View Transactions", systemImage: "list.bullet.rectangle")
            }
          }
        }
        targetsSection
        tiersSection
        monthsSection
        categoriesSection
        periodsSection
      }
      .listStyle(.insetGrouped)
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        // Measure every visible section at the current width and text size.
        // The detent adds the bottom safe area; the top inset includes navigation.
        ceil(geometry.contentSize.height + geometry.contentInsets.top)
      } action: { _, height in
        if height > 0 { contentHeight = height }
      }
      .navigationTitle(row.card.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Edit") { onEdit() }
        }
      }
    }
    .presentationDetents([contentHeight > 0 ? .height(contentHeight) : .large])
    .presentationDragIndicator(.visible)
    // Financial figures stay on an opaque surface, not the glass sheet.
    .presentationBackground(Color(.systemGroupedBackground))
  }

  private var calc: RewardsCalculation { row.calculation }

  private var currentPeriod: RewardsCalculationPeriod? {
    guard let asOf else { return calc.periods?.last }
    return calc.periods?.last(where: { $0.start <= asOf && asOf <= $0.end })
  }

  private var activeMonth: RewardsMonthlyQualification? {
    guard let asOf else { return nil }
    return calc.monthlyQualifications?.first(where: { $0.start <= asOf && asOf <= $0.end })
  }

  @ViewBuilder
  private var targetsSection: some View {
    let minimum = calc.minimumSpend ?? 0
    let maximum = calc.maximumSpend ?? 0
    if minimum > 0 || maximum > 0 || activeMonth != nil || calc.nextSpendingTierThreshold != nil {
      Section("Targets") {
        if minimum > 0 {
          progressRow(
            calc.minimumSpendMet ? "Minimum met" : "Minimum",
            spend: calc.totalSpend,
            target: minimum,
            caption: "Qualifying spend before rounding.",
            tone: calc.minimumSpendMet ? .earning : .needsMinimum
          )
        }
        if let month = activeMonth {
          progressRow(
            "This month's minimum",
            spend: month.spend,
            target: month.minimumSpend,
            caption: "\(short(month.start)) – \(short(month.end)), net of refunds.",
            tone: month.spend >= month.minimumSpend ? .earning : .needsMinimum
          )
        }
        if calc.hasNextSpendingTier == true, let threshold = calc.nextSpendingTierThreshold {
          progressRow("Next tier", spend: calc.totalSpend, target: threshold, caption: nil, tone: .earning)
        }
        if maximum > 0 {
          progressRow(
            calc.maximumSpendExceeded ? "Cap reached" : "Cap",
            spend: calc.countedSpend,
            target: maximum,
            caption: (row.card.earningBlockSize ?? 0) > 0
              ? "Counts spend in whole earning blocks, so the room left can differ by up to one block."
              : nil,
            tone: calc.maximumSpendExceeded ? .complete : .earning
          )
        }
      }
    }
  }

  @ViewBuilder
  private var tiersSection: some View {
    let tiers = (row.card.spendingTiers ?? []).sorted { $0.spendThreshold < $1.spendThreshold }
    if !tiers.isEmpty {
      Section("Tiers") {
        ForEach(tiers) { tier in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text("From \(money(tier.spendThreshold))")
                .monospacedDigit()
              Text(tierDetail(tier))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if tier.id == calc.activeSpendingTierId {
              Label("Active", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.inflow)
            } else if tier.id == calc.nextSpendingTierId {
              Text("Next")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  @ViewBuilder
  private var monthsSection: some View {
    let months = calc.monthlyQualifications ?? []
    if !months.isEmpty {
      Section("Qualification") {
        ForEach(Array(months.enumerated()), id: \.offset) { _, month in
          HStack {
            Label {
              Text("\(short(month.start)) – \(short(month.end))")
            } icon: {
              Image(systemName: statusSymbol(month.status))
                .foregroundStyle(month.status == "failed" ? Theme.outflow : month.status == "met" ? Theme.inflow : Color.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
              Text("\(money(month.spend)) / \(money(month.minimumSpend))")
                .monospacedDigit()
              Text(month.status.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  @ViewBuilder
  private var categoriesSection: some View {
    if !calc.flags.isEmpty {
      Section("Categories") {
        RewardCategoryBreakdown(row: row, currencyFormat: currencyFormat)
          .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
          .listRowBackground(Color.clear)
      }
    }
  }

  @ViewBuilder
  private var periodsSection: some View {
    let periods = calc.periods ?? []
    if periods.count > 1 {
      Section("Periods") {
        ForEach(Array(periods.enumerated()), id: \.offset) { _, period in
          LabeledContent("\(short(period.start)) – \(short(period.end))") {
            Text(money(period.calculation.totalSpend))
              .monospacedDigit()
          }
        }
      }
    }
  }

  private func progressRow(
    _ title: String, spend: Double, target: Double, caption: String?, tone: RewardRowProjection.Tone
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
        Spacer()
        Text("\(money(spend)) / \(money(target))")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      ProgressView(value: target > 0 ? min(1, max(0, spend / target)) : 0)
        .tint(RewardTonePalette.palette(for: tone).ink)
      if let caption {
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func tierDetail(_ tier: CardSpendingTier) -> String {
    var parts: [String] = []
    if let rate = tier.earningRate {
      parts.append(rateText(rate))
    }
    if let maximum = tier.maximumSpend {
      parts.append("cap \(money(maximum))")
    }
    return parts.isEmpty ? "Base rate" : parts.joined(separator: " · ")
  }

  private func rateText(_ rate: Double) -> String {
    calc.rewardType == .cashback ? "\(rate.formatted())%" : "\(rate.formatted()) miles/$"
  }

  private func statusSymbol(_ status: String) -> String {
    switch status {
    case "met": return "checkmark.circle.fill"
    case "failed": return "xmark.octagon.fill"
    default: return "clock"
    }
  }

  private func money(_ value: Double) -> String {
    MoneyCodec.displayString(forCurrencyUnits: value, currencyFormat: currencyFormat)
  }

  private func short(_ iso: String) -> String {
    RewardsCalendar.shortLabel(iso, referenceISO: RewardsCalendar.today())
  }
}

// MARK: - Category spending

/// Actual spend is distinct from the rounded/capped amount eligible for rewards.
struct RewardCategoryUsage: Identifiable {
  let flag: RewardsFlagRow
  let excluded: Bool
  var id: String { flag.id }
  var spend: Double { flag.totalSpend ?? flag.eligibleSpend }
  var cap: Double? { excluded ? nil : flag.maximumSpend.flatMap { $0 > 0 ? $0 : nil } }
  var ratio: Double? { cap.map { max(0, spend / $0) } }
  var fill: Double { ratio.map { min(1, $0) } ?? (spend > 0 ? 1 : 0) }
  var warning: Bool { (ratio ?? 0) >= 0.9 }

  static func make(row: RewardsCardRow) -> [Self] {
    let excludedIDs = Set((row.card.subcategories ?? []).filter { $0.excludeFromRewards == true }.map(\.id))
    return row.calculation.flags.map { Self(flag: $0, excluded: excludedIDs.contains($0.id)) }
      .sorted { lhs, rhs in
        if lhs.excluded != rhs.excluded { return !lhs.excluded }
        if lhs.spend != rhs.spend { return lhs.spend > rhs.spend }
        return lhs.id < rhs.id
      }
  }
}

struct RewardCategoryBreakdown: View {
  @Environment(\.layoutDirection) private var layoutDirection
  let row: RewardsCardRow
  let currencyFormat: CurrencyFormat?

  var body: some View {
    let categories = RewardCategoryUsage.make(row: row)
    let total = categories.reduce(0) { $0 + max(0, $1.spend) }
    VStack(spacing: 6) {
      if total > 0 {
        GeometryReader { geometry in
          HStack(spacing: 0) {
            ForEach(categories) { category in
              colour(category)
                .frame(width: geometry.size.width * max(0, category.spend) / total)
            }
          }
        }
        .frame(height: 16)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset / 2, style: .continuous))
        .accessibilityHidden(true)
        .padding(.bottom, 4)
      }
      ForEach(categories) { category in
        categoryRow(category)
      }
    }
  }

  private func categoryRow(_ category: RewardCategoryUsage) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          categoryName(category)
            .fixedSize(horizontal: true, vertical: true)
          Spacer(minLength: 0)
          amounts(category)
            .fixedSize(horizontal: true, vertical: true)
        }
        VStack(alignment: .leading, spacing: 4) {
          categoryName(category)
          amounts(category)
        }
      }
      if !category.excluded, let minimum = category.flag.minimumSpend, minimum > 0 {
        Text("\(category.flag.minimumSpendMet == true ? "Minimum met" : "Minimum"): \(money(minimum))")
          .font(.caption)
          .foregroundStyle(Theme.rowSecondary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      LeadingFill(fraction: category.fill, rightToLeft: layoutDirection == .rightToLeft)
        .fill(colour(category).opacity(0.19))
    }
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.inset, style: .continuous)
        .strokeBorder(colour(category).opacity(0.45), lineWidth: 1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(category.flag.name), \(money(category.spend)) spent")
    .accessibilityValue(accessibilityDetail(category))
  }

  private func categoryName(_ category: RewardCategoryUsage) -> some View {
    HStack(spacing: 6) {
      Circle().fill(colour(category)).frame(width: 8, height: 8)
      Text(category.flag.name).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func amounts(_ category: RewardCategoryUsage) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 5) {
        amountParts(category)
      }
      .fixedSize(horizontal: true, vertical: true)
      VStack(alignment: .leading, spacing: 4) {
        amountParts(category)
      }
    }
    .font(.subheadline)
    .monospacedDigit()
  }

  @ViewBuilder
  private func amountParts(_ category: RewardCategoryUsage) -> some View {
    Text(money(category.spend)).fontWeight(.semibold)
    if let cap = category.cap, let ratio = category.ratio {
      Text("/\(money(cap))").foregroundStyle(Theme.rowSecondary)
      Text("\(Int((ratio * 100).rounded()))%")
        // Darker than system red on the light tinted fills (normal-text contrast).
        .foregroundStyle(category.warning ? Color(light: 0xA82B24, dark: 0xFF6961) : Theme.rowSecondary)
    } else if !category.excluded {
      Text("No cap").foregroundStyle(Theme.rowSecondary)
    }
  }

  private func colour(_ category: RewardCategoryUsage) -> Color {
    Theme.flagColour(named: category.flag.flagColor) ?? .secondary
  }

  private func money(_ value: Double) -> String {
    MoneyCodec.displayString(forCurrencyUnits: value, currencyFormat: currencyFormat)
  }

  private func accessibilityDetail(_ category: RewardCategoryUsage) -> String {
    if category.excluded { return "Excluded from rewards" }
    var parts: [String] = []
    if let cap = category.cap, let ratio = category.ratio {
      parts.append("Cap \(money(cap)), \(Int((ratio * 100).rounded())) percent used")
    } else {
      parts.append("No cap")
    }
    if let minimum = category.flag.minimumSpend, minimum > 0 {
      parts.append("\(category.flag.minimumSpendMet == true ? "Minimum met" : "Minimum not met"), \(money(minimum))")
    }
    return parts.joined(separator: ". ")
  }
}

// MARK: - Summary and range report

/// Totals and the breakdown table for the board's scope, or for a historical
/// range. A range never appears as progress rows.
struct RewardsReportScreen: View {
  @Environment(AppModel.self) private var model
  @State private var filter: RewardsReportFilter
  @State private var group: RewardGroupBy = .flag
  @State private var report: RewardsReport?
  @State private var reportPlanID: String?
  @State private var phase: LoadPhase = .idle
  let allowsRange: Bool

  init(filter: RewardsReportFilter, allowsRange: Bool) {
    _filter = State(initialValue: filter)
    self.allowsRange = allowsRange
  }

  var body: some View {
    List {
      Section {
        if allowsRange {
          ReportFilterBar(range: $filter.range, group: $group, scope: $filter.scope)
        } else {
          Text(scopeDescription)
            .font(.footnote)
            .foregroundStyle(.secondary)
          RewardGroupMenu(group: $group)
        }
      }
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)

      if let report = reportPlanID == model.settings.planID ? report : nil {
        if let message = phase.errorMessage {
          Label(message, systemImage: "wifi.exclamationmark")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        totalsSection(report)
        if allowsRange, !report.cards.isEmpty {
          Section("Cards") {
            ForEach(report.cards) { row in
              RewardFilledRow(
                projection: .make(row: row, asOf: report.asOf, isRange: true),
                icon: model.accounts.first { $0.id == row.accountId }?.displayIcon,
                currencyFormat: model.currencyFormat,
                showsChevron: false
              )
              .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
              .listRowBackground(Color.clear)
            }
          }
        }
        groupsSection(report)
      } else {
        PhasePlaceholder(phase: phase) {
          await fetch()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .listRowBackground(Color.clear)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle(allowsRange ? "Range Report" : "Summary")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: fetchKey) {
      await fetch()
    }
    .refreshable {
      await fetch()
    }
  }

  private var scopeDescription: String {
    let date = filter.asOfISO.map { "as of \(RewardsCalendar.shortLabel($0, referenceISO: RewardsCalendar.today()))" } ?? "as of today"
    let accounts = filter.scope.accountIDs.isEmpty
      ? "all accounts"
      : "\(filter.scope.accountIDs.count) account\(filter.scope.accountIDs.count == 1 ? "" : "s")"
    return "Current card periods, \(date), \(accounts). Includes hidden and non-featured cards."
  }

  private func totalsSection(_ report: RewardsReport) -> some View {
    Section("Totals") {
      if let asOf = report.asOf {
        LabeledContent("As of", value: RewardsCalendar.shortLabel(asOf, referenceISO: RewardsCalendar.today()))
      }
      LabeledContent("Qualifying spend") {
        Text(money(report.totals.spend)).monospacedDigit()
      }
      LabeledContent("Value") {
        Text(money(report.totals.rewardDollars))
          .monospacedDigit()
          .foregroundStyle(Theme.inflow)
      }
      if report.totals.cashback > 0 {
        LabeledContent("Cashback") {
          Text(money(report.totals.cashback)).monospacedDigit()
        }
      }
      if report.totals.miles > 0 {
        LabeledContent("Miles") {
          Text(RewardRowText.milesString(report.totals.miles)).monospacedDigit()
        }
      }
    }
  }

  @ViewBuilder
  private func groupsSection(_ report: RewardsReport) -> some View {
    if !report.groups.isEmpty {
      Section("By \(group.title) · \(report.groups.count)") {
        ForEach(report.groups) { row in
          HStack(spacing: 8) {
            Circle()
              .fill(Theme.flagColour(named: row.flagColor) ?? Color.secondary.opacity(0.4))
              .frame(width: 8, height: 8)
              .accessibilityHidden(true)
            Text(row.label)
              .lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
              Text(money(row.spend))
                .monospacedDigit()
              Text("\(money(row.rewardDollars)) · \(row.transactionCount) txn")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.inflow)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private var fetchKey: String {
    "\(model.settings.planID)|\(model.rewardsRefreshGeneration)|\(filter.key)|\(group.rawValue)"
  }

  private func money(_ value: Double) -> String {
    MoneyCodec.displayString(forCurrencyUnits: value, currencyFormat: model.currencyFormat)
  }

  private func fetch() async {
    let planID = model.settings.planID
    let key = fetchKey
    phase = .loading
    do {
      let next = try await model.apiClient.fetchRewards(
        planID: planID,
        from: filter.from,
        to: filter.to,
        accountIDs: filter.accountIDs,
        group: group
      )
      guard key == fetchKey, planID == model.settings.planID else { return }
      withAnimation(Theme.Motion.arrive) {
        report = next
        reportPlanID = planID
        phase = .loaded
      }
    } catch {
      guard key == fetchKey, planID == model.settings.planID else { return }
      if error is CancellationError || (error as? URLError)?.code == .cancelled {
        return
      }
      phase = .failed(error.localizedDescription)
    }
  }
}

// MARK: - Small sheets

struct RewardsAsOfDateSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var filter: RewardsReportFilter
  @State private var draft: Date

  init(filter: Binding<RewardsReportFilter>) {
    _filter = filter
    _draft = State(initialValue: filter.wrappedValue.useAsOfDate ? filter.wrappedValue.asOfDate : Date())
  }

  var body: some View {
    NavigationStack {
      // Pinned to Singapore so the chosen day is the day sent to the server,
      // whatever zone the device is in.
      DatePicker("As of", selection: $draft, in: ...Date(), displayedComponents: .date)
        .datePickerStyle(.graphical)
        .environment(\.timeZone, RewardsCalendar.timeZone)
        .environment(\.calendar, RewardsCalendar.calendar)
        .padding(.horizontal)
        .navigationTitle("Show Rewards As Of")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Today") {
              filter.useAsOfDate = false
              filter.asOfDate = Date()
              dismiss()
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              apply()
              dismiss()
            }
          }
        }
    }
    .presentationDetents([.medium, .large])
  }

  private func apply() {
    if RewardsCalendar.isoString(draft) >= RewardsCalendar.today() {
      filter.useAsOfDate = false
      filter.asOfDate = Date()
    } else {
      filter.asOfDate = draft
      filter.useAsOfDate = true
    }
  }
}

struct RewardsValuationSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var text: String
  @State private var saving = false
  @State private var error: String?

  init(current: Double?) {
    _text = State(initialValue: current.map { String($0) } ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Miles valuation", text: $text)
            .keyboardType(.decimalPad)
            .accessibilityLabel("Miles valuation")
        } footer: {
          Text("Currency units per mile. Zero keeps miles but assigns no cash value.")
        }
        if let error {
          Section {
            Text(error)
              .foregroundStyle(Theme.outflow)
          }
        }
      }
      .navigationTitle("Miles Valuation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(saving ? "Saving…" : "Save") {
            Task { await save() }
          }
          .disabled(saving)
        }
      }
    }
    .presentationDetents([.medium])
  }

  private func save() async {
    guard !saving else { return }
    guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
      value.isFinite, value >= 0 else {
      error = "Miles valuation must be a nonnegative number."
      return
    }
    let planID = model.settings.planID
    saving = true
    error = nil
    defer { saving = false }
    do {
      _ = try await model.apiClient.updateRewardSettings(planID: planID, milesValuation: value)
      guard planID == model.settings.planID else { return }
      model.noteRewardsBoardChanged()
      dismiss()
    } catch {
      guard planID == model.settings.planID else { return }
      self.error = error.localizedDescription
    }
  }
}

// MARK: - Register strip

/// The reward rows for one account, shown in its register so the limit is in
/// view while adding transactions. Tapping opens the card in Rewards.
struct RegisterRewardsStrip: View {
  @Environment(AppModel.self) private var model
  @Environment(RootChromeState.self) private var chrome: RootChromeState?
  let accountID: String
  @State private var rows: [RewardsCardRow] = []
  @State private var asOf: String?
  @State private var loadedPlanID: String?

  var body: some View {
    VStack(spacing: 8) {
      if loadedPlanID == model.settings.planID {
        ForEach(rows) { row in
          let projection = RewardRowProjection.make(row: row, asOf: asOf, isRange: false)
          Button {
            chrome?.showRewardsCard(row.id)
          } label: {
            RewardFilledRow(projection: projection, currencyFormat: model.currencyFormat, showsChevron: chrome != nil)
          }
          .buttonStyle(.plain)
          .disabled(chrome == nil)
          .accessibilityLabel("Rewards, \(projection.title)")
          .accessibilityValue(RewardRowText(projection, currencyFormat: model.currencyFormat).accessibilityValue)
          .accessibilityHint("Opens this card in Rewards.")
        }
      }
    }
    .padding(.top, rows.isEmpty ? 0 : 6)
    .task(id: fetchKey) {
      await load()
    }
  }

  /// Refetches when this account's transactions change, so a new transaction
  /// moves the limit without leaving the register.
  private var fetchKey: String {
    var hasher = Hasher()
    for transaction in model.transactions where transaction.accountID == accountID {
      hasher.combine(transaction)
    }
    return "\(model.settings.planID)|\(accountID)|\(model.rewardsRefreshGeneration)|\(hasher.finalize())"
  }

  private func load() async {
    let planID = model.settings.planID
    do {
      let report = try await model.apiClient.fetchRewards(
        planID: planID,
        from: nil,
        to: nil,
        accountIDs: [accountID],
        group: .flag
      )
      guard planID == model.settings.planID else { return }
      rows = report.cards.filter { $0.accountId == accountID }
      asOf = report.asOf
      loadedPlanID = planID
    } catch {
      // The register stands on its own; keep the last rows on failure.
    }
  }
}
