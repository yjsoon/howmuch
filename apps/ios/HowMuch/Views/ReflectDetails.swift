import SwiftUI

/// Range selection shared by the Reflect detail screens: a single month with
/// stepper arrows, one of YNAB's presets, or a custom from/to pair — the same
/// choices as the web filter rail.
struct ReportRange: Equatable {
  enum Mode: String, CaseIterable, Identifiable {
    case month = "Month"
    case preset = "Preset"
    case custom = "Custom"

    var id: String { rawValue }
  }

  var mode: Mode = .month
  var monthAnchor = Date.now.startOfMonth()
  var preset: ReportPreset = .lastThreeMonths
  var customFrom = Date.now.startOfMonth()
  var customTo = Date.now

  /// `nil` means unbounded, e.g. the All Time preset.
  var fromISO: String? {
    switch mode {
    case .month:
      return monthAnchor.startOfMonth().isoDateString
    case .preset:
      return preset.range().from?.isoDateString
    case .custom:
      return min(customFrom, customTo).isoDateString
    }
  }

  var toISO: String? {
    switch mode {
    case .month:
      return min(monthAnchor.endOfMonth(), Date.now).isoDateString
    case .preset:
      return preset.range().to?.isoDateString
    case .custom:
      return max(customFrom, customTo).isoDateString
    }
  }

  var label: String {
    switch mode {
    case .month:
      return monthAnchor.monthYearLabel
    case .preset:
      return preset.title
    case .custom:
      let from = min(customFrom, customTo).compactDateLabel
      let to = max(customFrom, customTo).compactDateLabel
      return from == to ? from : "\(from) – \(to)"
    }
  }

  /// The drill-down window for register links; nil when unbounded.
  var dateRange: ClosedRange<String>? {
    guard let from = fromISO, let to = toISO, from <= to else {
      return nil
    }
    return from ... to
  }

  /// Cache key for `.task(id:)` refetching.
  var key: String {
    "\(mode.rawValue)|\(fromISO ?? "open")|\(toISO ?? "open")"
  }
}

/// Account/category scoping shared by the Reflect detail screens, mirroring
/// the web filter rail's multi-selects. Empty means "all".
struct ReportScope: Equatable {
  var accountIDs: Set<String> = []
  var categoryIDs: Set<String> = []

  var isActive: Bool {
    !accountIDs.isEmpty || !categoryIDs.isEmpty
  }

  var key: String {
    accountIDs.sorted().joined(separator: ",") + "|" + categoryIDs.sorted().joined(separator: ",")
  }
}

/// Range, grouping, and scope as one chip row — no stacked segmented controls.
struct ReportFilterBar: View {
  var range: Binding<ReportRange>?
  var interval: Binding<ReportInterval>?
  var intervalChoices: [ReportInterval] = []
  var group: Binding<RewardGroupBy>?
  @Binding var scope: ReportScope
  var showsCategories = false

  @State private var isPickingAccounts = false
  @State private var isPickingCategories = false

  init(
    range: Binding<ReportRange>? = nil,
    interval: Binding<ReportInterval>? = nil,
    intervalChoices: [ReportInterval] = [],
    group: Binding<RewardGroupBy>? = nil,
    scope: Binding<ReportScope>,
    showsCategories: Bool = false
  ) {
    self.range = range
    self.interval = interval
    self.intervalChoices = intervalChoices
    self.group = group
    _scope = scope
    self.showsCategories = showsCategories
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      WrappingHStack(spacing: 8) {
        if let range {
          ReportRangeMenu(range: range)
        }
        if let interval {
          ReportIntervalMenu(interval: interval, choices: intervalChoices)
        }
        if let group {
          RewardGroupMenu(group: group)
        }
        chip(label: accountsLabel, isActive: !scope.accountIDs.isEmpty) {
          isPickingAccounts = true
        }
        if showsCategories {
          chip(label: categoriesLabel, isActive: !scope.categoryIDs.isEmpty) {
            isPickingCategories = true
          }
        }
        if scope.isActive {
          Button {
            scope = ReportScope()
          } label: {
            Label("Clear", systemImage: "xmark.circle.fill")
              .font(.footnote.weight(.medium))
              .foregroundStyle(Theme.accent)
              .padding(.horizontal, 6)
              .padding(.vertical, 7)
              .contentShape(Capsule())
          }
          .buttonStyle(.pressable)
          .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
      }

      if let range, range.wrappedValue.mode != .preset {
        ReportRangeAccessory(range: range)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(Theme.Motion.standard, value: range?.wrappedValue.mode)
    .animation(Theme.Motion.standard, value: scope.isActive)
    .sheet(isPresented: $isPickingAccounts) {
      AccountScopePicker(selection: $scope.accountIDs)
        .blocksCapturePresentation()
    }
    .sheet(isPresented: $isPickingCategories) {
      CategoryScopePicker(selection: $scope.categoryIDs)
        .blocksCapturePresentation()
    }
  }

  private var accountsLabel: String {
    scope.accountIDs.isEmpty
      ? "All Accounts"
      : "\(scope.accountIDs.count) Account\(scope.accountIDs.count == 1 ? "" : "s")"
  }

  private var categoriesLabel: String {
    scope.categoryIDs.isEmpty
      ? "All Categories"
      : "\(scope.categoryIDs.count) Categor\(scope.categoryIDs.count == 1 ? "y" : "ies")"
  }

  private func chip(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      FilterChip(label: label, isActive: isActive)
    }
    .buttonStyle(.pressable)
    .accessibilityLabel(label)
  }
}

/// One menu for window length: a calendar month, a named preset, or custom dates.
struct ReportRangeMenu: View {
  @Binding var range: ReportRange

  var body: some View {
    Menu {
      Button {
        range.mode = .month
      } label: {
        menuRow("Choose a month", selected: range.mode == .month)
      }
      Section {
        ForEach(ReportPreset.allCases) { preset in
          Button {
            range.mode = .preset
            range.preset = preset
          } label: {
            menuRow(preset.title, selected: range.mode == .preset && range.preset == preset)
          }
        }
      }
      Button {
        range.mode = .custom
      } label: {
        menuRow("Custom dates", selected: range.mode == .custom)
      }
    } label: {
      FilterChip(label: range.label)
    }
    .accessibilityLabel("Date range, \(range.label)")
  }
}

/// Stepper or from/to dates; hidden while a named preset is selected.
struct ReportRangeAccessory: View {
  @Binding var range: ReportRange

  var body: some View {
    switch range.mode {
    case .month:
      MonthStepper(monthAnchor: $range.monthAnchor)
    case .preset:
      EmptyView()
    case .custom:
      HStack(spacing: 12) {
        DatePicker("From", selection: $range.customFrom, in: ...Date.now, displayedComponents: .date)
          .labelsHidden()
        Text("–")
          .foregroundStyle(.secondary)
        DatePicker("To", selection: $range.customTo, in: ...Date.now, displayedComponents: .date)
          .labelsHidden()
      }
      .frame(maxWidth: .infinity)
    }
  }
}

/// Grouping menu (week / month / year). A chip, not a second segmented control.
struct ReportIntervalMenu: View {
  @Binding var interval: ReportInterval
  let choices: [ReportInterval]

  var body: some View {
    Menu {
      Picker("Group by", selection: $interval) {
        ForEach(choices) { choice in
          Text(choice.title).tag(choice)
        }
      }
    } label: {
      FilterChip(label: interval.title)
    }
    .accessibilityLabel("Group by, \(interval.title)")
  }
}

struct RewardGroupMenu: View {
  @Binding var group: RewardGroupBy

  var body: some View {
    Menu {
      Picker("Group", selection: $group) {
        ForEach(RewardGroupBy.allCases) { choice in
          Text(choice.title).tag(choice)
        }
      }
    } label: {
      FilterChip(label: group.title)
    }
    .accessibilityLabel("Group, \(group.title)")
  }
}

private func menuRow(_ title: String, selected: Bool) -> some View {
  Label {
    Text(title)
  } icon: {
    if selected {
      Image(systemName: "checkmark")
    }
  }
}


/// Multi-select over open accounts; empty selection means "all accounts".
/// `candidateIDs` narrows the list (closed accounts included), e.g. to the
/// accounts that have reward cards.
struct AccountScopePicker: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var selection: Set<String>
  var candidateIDs: Set<String>? = nil

  private var accounts: [Account] {
    guard let candidateIDs, !candidateIDs.isEmpty else { return model.openAccounts }
    return model.accounts.filter { candidateIDs.contains($0.id) && !$0.deleted }
  }

  var body: some View {
    NavigationStack {
      List {
        Button {
          selection = []
        } label: {
          HStack {
            Text("All Accounts")
              .foregroundStyle(Theme.textPrimary)
            Spacer()
            if selection.isEmpty {
              Image(systemName: "checkmark")
                .foregroundStyle(Theme.accent)
            }
          }
        }

        Section {
          ForEach(accounts) { account in
            Button {
              toggle(account.id)
            } label: {
              HStack {
                Text(account.name)
                  .foregroundStyle(Theme.textPrimary)
                Spacer()
                if selection.contains(account.id) {
                  Image(systemName: "checkmark")
                    .foregroundStyle(Theme.accent)
                }
              }
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(Theme.canvas)
      .navigationTitle("Accounts")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func toggle(_ id: String) {
    if selection.contains(id) {
      selection.remove(id)
    } else {
      selection.insert(id)
    }
  }
}

/// Multi-select over categories (plus the Uncategorised pseudo-category);
/// empty selection means "all categories". Bookkeeping groups sit at the end,
/// as in the web filter rail.
struct CategoryScopePicker: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var selection: Set<String>
  @State private var searchText = ""

  var body: some View {
    NavigationStack {
      List {
        if trimmedSearch.isEmpty {
          Button {
            selection = []
          } label: {
            HStack {
              Text("All Categories")
                .foregroundStyle(Theme.textPrimary)
              Spacer()
              if selection.isEmpty {
                Image(systemName: "checkmark")
                  .foregroundStyle(Theme.accent)
              }
            }
          }
        }

        ForEach(visibleGroups) { group in
          Section(group.name) {
            ForEach(group.categories.filter(matches)) { category in
              row(id: category.id, name: category.name)
            }
          }
        }

        if matchesUncategorised {
          Section("Needs a Category") {
            row(id: CategoryGroup.uncategorisedCategoryID, name: "Uncategorised")
          }
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(Theme.canvas)
      .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search categories")
      .navigationTitle("Categories")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func matches(_ category: Category) -> Bool {
    trimmedSearch.isEmpty || category.name.localizedStandardContains(trimmedSearch)
  }

  private var matchesUncategorised: Bool {
    trimmedSearch.isEmpty || "Uncategorised".localizedStandardContains(trimmedSearch)
  }

  private var visibleGroups: [CategoryGroup] {
    let live = model.categoryGroups.filter { group in
      !group.deleted && group.categories.contains { !$0.deleted && matches($0) }
    }
    let primary = live.filter { !$0.isQuiet }
    let quiet = live.filter(\.isQuiet)
    return primary + quiet
  }

  private func row(id: String, name: String) -> some View {
    Button {
      if selection.contains(id) {
        selection.remove(id)
      } else {
        selection.insert(id)
      }
    } label: {
      HStack {
        Text(name)
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        if selection.contains(id) {
          Image(systemName: "checkmark")
            .foregroundStyle(Theme.accent)
        }
      }
    }
  }
}

// MARK: - Spending Breakdown

struct SpendingBreakdownDetailView: View {
  @Environment(AppModel.self) private var model
  @State private var range = ReportRange()
  @State private var scope = ReportScope()
  @State private var report: SpendingBreakdownReport?
  @State private var phase: LoadPhase = .idle

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ReportFilterBar(range: $range, scope: $scope, showsCategories: true)

        if let report {
          // Web parity: bookkeeping groups are excluded until asked, unless
          // an explicit category filter made the choice deliberate.
          let hideQuiet = !model.includeQuietSpending && scope.categoryIDs.isEmpty
          let split = ReflectMaths.split(report.groups)
          let rows = hideQuiet ? split.primary : split.primary + split.quiet
          let total = rows.reduce(0) { $0 + abs($1.amount) }
          let excluded = abs(report.total) - total
          let transactionCount = rows.reduce(0) { $0 + $1.transactionCount }

          headlineCard(rows: rows, total: total, transactionCount: transactionCount)

          if scope.categoryIDs.isEmpty, excluded > 0 || model.includeQuietSpending {
            quietToggleNote(excluded: excluded)
          }

          if rows.isEmpty {
            ReflectMaths.emptyRange(title: "No Spending", systemImage: "chart.pie")
          } else {
            ForEach(ReflectMaths.groupSections(rows)) { section in
              groupSection(section, total: total, maxAmount: rows.map { abs($0.amount) }.max() ?? 1)
            }
          }
        } else {
          PhasePlaceholder(phase: phase) {
            await fetch()
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .background(Theme.canvas)
    .navigationTitle("Spending Breakdown")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: range.key + "|" + scope.key) {
      await fetch()
    }
  }

  private func headlineCard(rows: [SpendingBreakdownGroup], total: Int, transactionCount: Int) -> some View {
    VStack(spacing: 10) {
      Text("Total Spending")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text(MoneyCodec.displayString(for: total, currencyFormat: model.currencyFormat))
        .font(.largeTitle.weight(.bold))
        .monospacedDigit()
        .foregroundStyle(Theme.textPrimary)
        .rollingNumber(total)
      StackedShareBar(segments: ReflectMaths.shareSegments(rows, limit: 6))

      HStack {
        statColumn("Largest Line", rows.max { abs($0.amount) < abs($1.amount) }?.categoryName ?? "—")
        Spacer()
        statColumn(
          "Avg Transaction",
          transactionCount > 0
            ? MoneyCodec.displayString(for: total / transactionCount, currencyFormat: model.currencyFormat)
            : "—"
        )
        Spacer()
        statColumn("Transactions", "\(transactionCount)")
      }
      .padding(.top, 2)
    }
    .frame(maxWidth: .infinity)
    .padding(16)
    .ynabCard()
  }

  private func statColumn(_ label: String, _ value: String) -> some View {
    VStack(spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.footnote.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(Theme.textPrimary)
        .lineLimit(1)
    }
  }

  private func quietToggleNote(excluded: Int) -> some View {
    HStack(spacing: 6) {
      Text(
        model.includeQuietSpending
          ? "Including hidden & non-personal categories."
          : "\(MoneyCodec.displayString(for: max(excluded, 0), currencyFormat: model.currencyFormat)) in hidden & non-personal categories excluded."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      Button(model.includeQuietSpending ? "Exclude" : "Include") {
        withAnimation(Theme.Motion.standard) {
          model.setIncludeQuietSpending(!model.includeQuietSpending)
        }
      }
      .font(.footnote.weight(.semibold))
      .foregroundStyle(Theme.accent)
    }
    .padding(.horizontal, 4)
  }

  private func groupSection(_ section: SpendingGroupSection, total: Int, maxAmount: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(section.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        Text(MoneyCodec.displayString(for: section.amount, currencyFormat: model.currencyFormat))
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(Theme.textPrimary)
          .rollingNumber(section.amount)
        Text(total > 0 ? shareLabel(Double(section.amount) / Double(total)) : "—")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(width: 44, alignment: .trailing)
      }
      .padding(.horizontal, 4)

      VStack(spacing: 0) {
        ForEach(section.rows.enumerated(), id: \.element.id) { index, group in
          NavigationLink {
            RegisterView(
              scope: .all,
              categoryID: group.categoryID,
              dateRange: range.dateRange,
              accountIDs: scope.accountIDs.isEmpty ? nil : scope.accountIDs
            )
          } label: {
            categoryRow(group, total: total, maxAmount: maxAmount)
          }
          .buttonStyle(.cardRow)
          if index < section.rows.count - 1 {
            Divider().padding(.leading, 16)
          }
        }
      }
      .ynabCard()
    }
  }

  private func categoryRow(_ group: SpendingBreakdownGroup, total: Int, maxAmount: Int) -> some View {
    let amount = abs(group.amount)
    let share = total > 0 ? Double(amount) / Double(total) : 0
    return HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text(group.categoryName)
          .font(.subheadline)
          .foregroundStyle(Theme.textPrimary)
        HStack(spacing: 8) {
          ShareMeter(fraction: Double(amount) / Double(max(maxAmount, 1)))
            .frame(width: 120, height: 6)
          Text(shareLabel(share))
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("· \(group.transactionCount) txn\(group.transactionCount == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      Spacer()
      Text(MoneyCodec.displayString(for: amount, currencyFormat: model.currencyFormat))
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(Theme.textPrimary)
        .rollingNumber(amount)
      Image(systemName: "chevron.forward")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .contentShape(Rectangle())
  }

  private func shareLabel(_ share: Double) -> String {
    let percent = share * 100
    return percent < 1 ? "< 1%" : "\(Int(percent.rounded()))%"
  }

  private func fetch() async {
    phase = .loading
    do {
      let next = try await model.apiClient.fetchSpendingBreakdown(
        planID: model.settings.planID,
        from: range.fromISO,
        to: range.toISO,
        accountIDs: Array(scope.accountIDs),
        categoryIDs: Array(scope.categoryIDs)
      )
      // A superseded request must not overwrite the current filter's data.
      guard !Task.isCancelled else { return }
      withAnimation(Theme.Motion.arrive) {
        report = next
        phase = .loaded
      }
    } catch {
      // A filter change restarts `.task(id:)`; the cancelled request must
      // not flash an error over the new one.
      guard !Task.isCancelled else { return }
      // Drop the previous window's figures so they never sit under the new
      // filter chips; the placeholder offers Retry instead.
      withAnimation(Theme.Motion.arrive) {
        report = nil
        phase = .failed(error.localizedDescription)
      }
    }
  }
}

// MARK: - Net Worth

struct NetWorthDetailView: View {
  @Environment(AppModel.self) private var model
  @State private var range = ReportRange(mode: .preset, preset: .lastTwelveMonths)
  @State private var scope = ReportScope()
  @State private var interval: ReportInterval = .month
  @State private var report: NetWorthReport?
  @State private var phase: LoadPhase = .idle

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ReportFilterBar(range: $range, interval: $interval, intervalChoices: [.week, .month], scope: $scope)

        if let report, let latest = report.periods.last {
          headlineCard(report: report, latest: latest)

          Text("Accounts")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 4)
          accountsCard(latest: latest)

          Text("History")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 4)
          historyCard(report: report)
        } else if report != nil, phase != .loading {
          ReflectMaths.emptyRange(title: "No Net Worth History", systemImage: "chart.bar")
        } else {
          PhasePlaceholder(phase: phase) {
            await fetch()
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .background(Theme.canvas)
    .navigationTitle("Net Worth")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: range.key + "|" + scope.key + "|" + interval.rawValue) {
      await fetch()
    }
  }

  private func headlineCard(report: NetWorthReport, latest: NetWorthPeriod) -> some View {
    let assets = latest.accounts.map(\.balance).filter { $0 > 0 }.reduce(0, +)
    let debts = latest.accounts.map(\.balance).filter { $0 < 0 }.reduce(0, +)
    let change = report.periods.dropLast().last.map { latest.netWorth - $0.netWorth }

    return VStack(spacing: 10) {
      Text("Net Worth · as at \(LedgerDate.friendlyString(fromISO: latest.endDate))")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text(MoneyCodec.displayString(for: latest.netWorth, currencyFormat: model.currencyFormat))
        .font(.largeTitle.weight(.bold))
        .monospacedDigit()
        .foregroundStyle(Theme.textPrimary)
        .rollingNumber(latest.netWorth)
      if let change {
        Text("\(MoneyCodec.signedDisplayString(for: change, currencyFormat: model.currencyFormat)) on previous period")
          .font(.footnote.weight(.medium))
          .monospacedDigit()
          .foregroundStyle(Theme.amountColour(change))
          .rollingNumber(change)
      }
      HStack(spacing: 24) {
        VStack(spacing: 2) {
          Text("Assets")
            .font(.caption)
            .foregroundStyle(Theme.accent)
          Text(MoneyCodec.displayString(for: assets, currencyFormat: model.currencyFormat))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
            .rollingNumber(assets)
        }
        VStack(spacing: 2) {
          Text("Debts")
            .font(.caption)
            .foregroundStyle(Theme.outflow)
          Text(MoneyCodec.displayString(for: debts, currencyFormat: model.currencyFormat))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
            .rollingNumber(debts)
        }
      }
      ColumnChart(
        values: report.periods.map { Double($0.netWorth) },
        labels: LedgerDate.periodAxisLabels(report.periods.map(\.period)),
        height: 120
      )
    }
    .frame(maxWidth: .infinity)
    .padding(16)
    .ynabCard()
  }

  private func accountsCard(latest: NetWorthPeriod) -> some View {
    let accounts = latest.accounts.sorted { abs($0.balance) > abs($1.balance) }
    return VStack(spacing: 0) {
      ForEach(accounts.enumerated(), id: \.element.id) { index, account in
        HStack {
          Text(account.accountName)
            .font(.subheadline)
            .foregroundStyle(Theme.textPrimary)
          Spacer()
          Text(MoneyCodec.displayString(for: account.balance, currencyFormat: model.currencyFormat))
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(account.balance == 0 ? .secondary : Theme.amountColour(account.balance))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        if index < accounts.count - 1 {
          Divider().padding(.leading, 16)
        }
      }
    }
    .ynabCard()
  }

  private func historyCard(report: NetWorthReport) -> some View {
    let periods = Array(report.periods.reversed())
    return VStack(spacing: 0) {
      ForEach(periods.enumerated(), id: \.element.id) { index, period in
        let prior = index + 1 < periods.count ? periods[index + 1] : nil
        let delta = prior.map { period.netWorth - $0.netWorth }
        HStack {
          Text(LedgerDate.periodLabel(period.period))
            .font(.subheadline)
            .foregroundStyle(Theme.textPrimary)
          Spacer()
          VStack(alignment: .trailing, spacing: 2) {
            Text(MoneyCodec.displayString(for: period.netWorth, currencyFormat: model.currencyFormat))
              .font(.subheadline.weight(.medium))
              .monospacedDigit()
              .foregroundStyle(Theme.textPrimary)
            if let delta {
              Text(MoneyCodec.signedDisplayString(for: delta, currencyFormat: model.currencyFormat))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.amountColour(delta))
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        if index < periods.count - 1 {
          Divider().padding(.leading, 16)
        }
      }
    }
    .ynabCard()
  }

  private func fetch() async {
    phase = .loading
    do {
      let next = try await model.apiClient.fetchNetWorth(
        planID: model.settings.planID,
        from: range.fromISO,
        to: range.toISO,
        interval: interval,
        accountIDs: Array(scope.accountIDs)
      )
      // A superseded request must not overwrite the current filter's data.
      guard !Task.isCancelled else { return }
      withAnimation(Theme.Motion.arrive) {
        report = next
        phase = .loaded
      }
    } catch {
      // A filter change restarts `.task(id:)`; the cancelled request must
      // not flash an error over the new one.
      guard !Task.isCancelled else { return }
      // Drop the previous window's figures so they never sit under the new
      // filter chips; the placeholder offers Retry instead.
      withAnimation(Theme.Motion.arrive) {
        report = nil
        phase = .failed(error.localizedDescription)
      }
    }
  }
}

// MARK: - Income vs Spending

struct IncomeVsSpendingDetailView: View {
  @Environment(AppModel.self) private var model
  @State private var range = ReportRange(mode: .preset, preset: .yearToDate)
  @State private var scope = ReportScope()
  @State private var interval: ReportInterval = .month
  @State private var report: IncomeVsSpendingReport?
  @State private var phase: LoadPhase = .idle

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ReportFilterBar(
          range: $range,
          interval: $interval,
          intervalChoices: [.week, .month, .year],
          scope: $scope,
          showsCategories: true
        )

        if let report, !report.periods.isEmpty {
          totalsCard(report: report)
          periodsCard(report: report)
        } else if report != nil, phase != .loading {
          ReflectMaths.emptyRange(title: "No Income or Spending", systemImage: "chart.bar")
        } else {
          PhasePlaceholder(phase: phase) {
            await fetch()
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .background(Theme.canvas)
    .navigationTitle("Income vs Spending")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: range.key + "|" + scope.key + "|" + interval.rawValue) {
      await fetch()
    }
  }

  private func totalsCard(report: IncomeVsSpendingReport) -> some View {
    let income = report.periods.reduce(0) { $0 + $1.income }
    let spending = report.periods.reduce(0) { $0 + abs($1.spending) }
    let net = income - spending

    return VStack(spacing: 12) {
      HStack {
        statColumn("Income", MoneyCodec.displayString(for: income, currencyFormat: model.currencyFormat), colour: Theme.inflow)
        Spacer()
        statColumn("Spending", MoneyCodec.displayString(for: spending, currencyFormat: model.currencyFormat), colour: Theme.outflow)
        Spacer()
        statColumn("Net", MoneyCodec.signedDisplayString(for: net, currencyFormat: model.currencyFormat), colour: Theme.amountColour(net))
        Spacer()
        statColumn("Savings Rate", savingsRate(net: net, income: income), colour: Theme.amountColour(net))
      }

      PairedColumnChart(
        pairs: report.periods.map { (Double($0.income), Double(abs($0.spending))) },
        labels: LedgerDate.periodAxisLabels(report.periods.map(\.period)),
        height: 120
      )
      HStack(spacing: 16) {
        legendDot(colour: Theme.inflow, label: "Income")
        legendDot(colour: Theme.outflow, label: "Spending")
      }
    }
    .padding(16)
    .ynabCard()
  }

  private func periodsCard(report: IncomeVsSpendingReport) -> some View {
    VStack(spacing: 0) {
      ForEach(report.periods.reversed().enumerated(), id: \.element.id) { index, period in
        VStack(alignment: .leading, spacing: 6) {
          Text(LedgerDate.periodLabel(period.period))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
          HStack {
            amountColumn("Income", MoneyCodec.displayString(for: period.income, currencyFormat: model.currencyFormat), colour: Theme.inflow)
            Spacer()
            amountColumn("Spending", MoneyCodec.displayString(for: abs(period.spending), currencyFormat: model.currencyFormat), colour: Theme.outflow)
            Spacer()
            amountColumn("Net", MoneyCodec.signedDisplayString(for: period.net, currencyFormat: model.currencyFormat), colour: Theme.amountColour(period.net))
            Spacer()
            amountColumn("Cumulative", MoneyCodec.signedDisplayString(for: period.cumulativeNet, currencyFormat: model.currencyFormat), colour: .secondary)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        if index < report.periods.count - 1 {
          Divider().padding(.leading, 16)
        }
      }
    }
    .ynabCard()
  }

  /// Net over income for the range, as on the web ("−12.3%" when overspent).
  private func savingsRate(net: Int, income: Int) -> String {
    guard income > 0 else {
      return "—"
    }
    return (Double(net) / Double(income)).formatted(.percent.precision(.fractionLength(1)))
  }

  private func statColumn(_ label: String, _ value: String, colour: Color) -> some View {
    VStack(spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.footnote.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(colour)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
  }

  private func amountColumn(_ label: String, _ value: String, colour: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.footnote.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(colour)
    }
  }

  private func legendDot(colour: Color, label: String) -> some View {
    HStack(spacing: 5) {
      Circle()
        .fill(colour)
        .frame(width: 8, height: 8)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func fetch() async {
    phase = .loading
    do {
      let next = try await model.apiClient.fetchIncomeVsSpending(
        planID: model.settings.planID,
        from: range.fromISO,
        to: range.toISO,
        interval: interval,
        accountIDs: Array(scope.accountIDs),
        categoryIDs: Array(scope.categoryIDs)
      )
      // A superseded request must not overwrite the current filter's data.
      guard !Task.isCancelled else { return }
      withAnimation(Theme.Motion.arrive) {
        report = next
        phase = .loaded
      }
    } catch {
      // A filter change restarts `.task(id:)`; the cancelled request must
      // not flash an error over the new one.
      guard !Task.isCancelled else { return }
      // Drop the previous window's figures so they never sit under the new
      // filter chips; the placeholder offers Retry instead.
      withAnimation(Theme.Motion.arrive) {
        report = nil
        phase = .failed(error.localizedDescription)
      }
    }
  }
}

// MARK: - Age of Money

struct AgeOfMoneyDetailView: View {
  @Environment(AppModel.self) private var model
  @State private var scope = ReportScope()
  @State private var interval: ReportInterval = .month
  @State private var report: AgeOfMoneyReport?
  @State private var phase: LoadPhase = .idle

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // No range picker: the server replays income lots from the start of
        // the window, so the age is only honest over the full history.
        ReportFilterBar(interval: $interval, intervalChoices: [.week, .month], scope: $scope)

        if let report {
          let measured = report.periods.filter { $0.ageOfMoneyDays != nil }
          let latest = measured.last?.ageOfMoneyDays
          let previous = measured.dropLast().last?.ageOfMoneyDays
          let matchedTotal = report.periods.reduce(0) { $0 + $1.spent }
          let unmatchedTotal = report.periods.reduce(0) { $0 + $1.unmatchedSpending }

          VStack(spacing: 10) {
            Text("Age of Money")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            if let latest {
              let days = Int(latest.rounded())
              Text(ReflectMaths.daysLabel(days, capitalised: true))
                .font(.largeTitle.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .rollingNumber(days)
              if let previous {
                let delta = days - Int(previous.rounded())
                Text("\(delta > 0 ? "+" : "")\(ReflectMaths.daysLabel(delta)) on previous period")
                  .font(.footnote.weight(.medium))
                  .monospacedDigit()
                  .foregroundStyle(delta == 0 ? Color.secondary : Theme.amountColour(delta))
                  .rollingNumber(delta)
              }
            } else {
              Text("Not enough matched income yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if measured.count > 1 {
              Sparkline(values: measured.compactMap(\.ageOfMoneyDays), colour: Theme.inflow, height: 80)
            }
            if matchedTotal > 0 {
              Text("\(MoneyCodec.displayString(for: matchedTotal, currencyFormat: model.currencyFormat)) of spending matched to income")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(16)
          .ynabCard()

          if unmatchedTotal > 0 {
            Text("\(MoneyCodec.displayString(for: unmatchedTotal, currencyFormat: model.currencyFormat)) of spending predates the earliest recorded income and is excluded from the weighted age.")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 4)
          }

          VStack(spacing: 0) {
            ForEach(report.periods.reversed().enumerated(), id: \.element.id) { index, period in
              periodRow(period)
              if index < report.periods.count - 1 {
                Divider().padding(.leading, 16)
              }
            }
          }
          .ynabCard()
        } else {
          PhasePlaceholder(phase: phase) {
            await fetch()
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .background(Theme.canvas)
    .navigationTitle("Age of Money")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: scope.key + "|" + interval.rawValue) {
      await fetch()
    }
  }

  private func periodRow(_ period: AgeOfMoneyPeriod) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(LedgerDate.periodLabel(period.period))
          .font(.subheadline)
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        if let age = period.ageOfMoneyDays {
          Text(ReflectMaths.daysLabel(Int(age.rounded())))
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
        } else {
          Text("—")
            .foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 12) {
        Text("Matched \(MoneyCodec.displayString(for: period.spent, currencyFormat: model.currencyFormat))")
        if period.unmatchedSpending > 0 {
          Text("Unmatched \(MoneyCodec.displayString(for: period.unmatchedSpending, currencyFormat: model.currencyFormat))")
        }
      }
      .font(.caption)
      .monospacedDigit()
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
  }

  private func fetch() async {
    phase = .loading
    do {
      let next = try await model.apiClient.fetchAgeOfMoney(
        planID: model.settings.planID,
        interval: interval,
        accountIDs: Array(scope.accountIDs)
      )
      // A superseded request must not overwrite the current filter's data.
      guard !Task.isCancelled else { return }
      withAnimation(Theme.Motion.arrive) {
        report = next
        phase = .loaded
      }
    } catch {
      // A filter change restarts `.task(id:)`; the cancelled request must
      // not flash an error over the new one.
      guard !Task.isCancelled else { return }
      // Drop the previous window's figures so they never sit under the new
      // filter chips; the placeholder offers Retry instead.
      withAnimation(Theme.Motion.arrive) {
        report = nil
        phase = .failed(error.localizedDescription)
      }
    }
  }
}
