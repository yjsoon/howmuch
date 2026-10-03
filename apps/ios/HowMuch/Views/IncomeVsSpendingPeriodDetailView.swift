import SwiftUI

enum IncomeSpendingTab: String, CaseIterable, Identifiable {
  case spending = "Spending"
  case income = "Income"

  var id: String { rawValue }
}

struct IncomeVsSpendingPeriodRow: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let row: IncomeVsSpendingMaths.PeriodRow
  let interval: ReportInterval
  let allRows: [IncomeVsSpendingMaths.PeriodRow]
  let scope: ReportScope
  let currencyFormat: CurrencyFormat?
  @State private var haptic = 0

  var body: some View {
    let today = Date.now.isoDateString
    let current = IncomeVsSpendingMaths.isCurrentPeriod(row.period, interval: interval, today: today)
    let title = LedgerDate.periodLabel(row.period)
    let spokenTitle = current ? "\(title) · so far" : title
    let incomeText = MoneyCodec.displayString(for: row.income, currencyFormat: currencyFormat)
    let spendingText = MoneyCodec.displayString(for: abs(row.spending), currencyFormat: currencyFormat)
    let netText = MoneyCodec.signedDisplayString(for: row.net, currencyFormat: currencyFormat)
    let saved = IncomeVsSpendingMaths.savingsRateLabel(net: row.net, income: row.income)
    VStack(alignment: .leading, spacing: 8) {
      destinationLink(tab: .spending) {
        HStack {
          (Text(title).foregroundStyle(Theme.textPrimary)
            + (current ? Text(" · so far").foregroundStyle(.secondary) : Text("")))
            .font(.subheadline.weight(.semibold))
          Spacer()
          Image(systemName: "chevron.forward")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          IncomeVsSpendingMaths.voiceOverRowLabel(
            period: spokenTitle,
            income: incomeText,
            spending: spendingText,
            net: netText
          )
        )
      }

      if dynamicTypeSize.isAccessibilitySize {
        VStack(spacing: 8) {
          amountZone(caption: "Income", value: incomeText, amount: row.income, colour: Theme.inflow, tab: .income)
          amountZone(caption: "Spending", value: spendingText, amount: row.spending, colour: Theme.outflow, tab: .spending)
        }
      } else {
        HStack(spacing: 0) {
          amountZone(caption: "Income", value: incomeText, amount: row.income, colour: Theme.inflow, tab: .income)
          amountZone(caption: "Spending", value: spendingText, amount: row.spending, colour: Theme.outflow, tab: .spending)
        }
      }

      destinationLink(tab: .spending) {
        (Text("Net ")
          + Text(netText).foregroundStyle(Theme.signedReportColour(row.net))
          + Text(" · Saved \(saved)"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .accessibilityHidden(true)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .sensoryFeedback(.selection, trigger: haptic)
  }

  @ViewBuilder
  private func amountZone(caption: String, value: String, amount: Int, colour: Color, tab: IncomeSpendingTab) -> some View {
    destinationLink(tab: tab) {
      VStack(alignment: .leading, spacing: 2) {
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.title3.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(amount == 0 ? Color.secondary : colour)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(minHeight: 56)
      .padding(16)
      .contentShape(Rectangle())
    }
    .buttonStyle(.cardRow)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func destinationLink<Label: View>(tab: IncomeSpendingTab, @ViewBuilder label: () -> Label) -> some View {
    let dateRange = row.from ... min(row.to, Date.now.isoDateString)
    NavigationLink {
      Group {
        if interval == .day {
          RegisterView(
            scope: .all,
            dateRange: dateRange,
            accountIDs: scope.accountIDs.isEmpty ? nil : scope.accountIDs,
            amountFilter: tab == .income ? .income : .spending,
            excludePlainTransfers: true
          )
        } else {
          IncomeVsSpendingPeriodDetailView(
            rows: allRows,
            selectedPeriod: row.period,
            initialTab: tab,
            interval: interval,
            scope: scope
          )
        }
      }
      .onAppear { haptic += 1 }
    } label: {
      label()
    }
    .buttonStyle(.plain)
  }
}

struct IncomeVsSpendingPeriodDetailView: View {
  @Environment(AppModel.self) private var model
  let rows: [IncomeVsSpendingMaths.PeriodRow]
  @State private var selectedPeriod: String
  @State private var tab: IncomeSpendingTab
  let interval: ReportInterval
  let scope: ReportScope
  @State private var groups: IncomeVsSpendingGroupsReport?
  @State private var phase: LoadPhase = .idle
  @State private var fetchGate = ReportFetchGate()

  init(
    rows: [IncomeVsSpendingMaths.PeriodRow],
    selectedPeriod: String,
    initialTab: IncomeSpendingTab,
    interval: ReportInterval,
    scope: ReportScope
  ) {
    self.rows = rows
    _selectedPeriod = State(initialValue: selectedPeriod)
    _tab = State(initialValue: initialTab)
    self.interval = interval
    self.scope = scope
  }

  var body: some View {
    let chronological = Array(rows.reversed())
    let selected = chronological.first { $0.period == selectedPeriod } ?? rows.first
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let selected {
          headerCard(selected, chronological: chronological)
          PeriodStepper(
            label: LedgerDate.periodLabel(selected.period),
            canGoBack: canStep(from: selected, delta: -1),
            canGoForward: canStep(from: selected, delta: 1),
            onBack: { step(from: selected, delta: -1) },
            onForward: { step(from: selected, delta: 1) }
          )
        }

        Picker("Breakdown", selection: $tab) {
          ForEach(IncomeSpendingTab.allCases) { item in
            Text(item.rawValue).tag(item)
          }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)

        tabBody
          .gesture(
            DragGesture(minimumDistance: 24).onEnded { value in
              if value.translation.width < -40, tab == .spending {
                tab = .income
              } else if value.translation.width > 40, tab == .income {
                tab = .spending
              }
            }
          )
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .background(Theme.canvas)
    .navigationTitle(selected.map { LedgerDate.periodLabel($0.period) } ?? "Income vs Spending")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: selectedPeriod + "|" + scope.key) {
      await fetch()
    }
  }

  @ViewBuilder
  private var tabBody: some View {
    if let groups {
      switch tab {
      case .spending:
        spendingTab(groups)
      case .income:
        incomeTab(groups)
      }
    } else {
      PhasePlaceholder(phase: phase) {
        await fetch()
      }
    }
  }

  private func headerCard(_ selected: IncomeVsSpendingMaths.PeriodRow, chronological: [IncomeVsSpendingMaths.PeriodRow]) -> some View {
    let today = Date.now.isoDateString
    let current = IncomeVsSpendingMaths.isCurrentPeriod(selected.period, interval: interval, today: today)
    let saved = IncomeVsSpendingMaths.savingsRateLabel(net: selected.net, income: selected.income)
    let filter = IncomeVsSpendingMaths.filterLine(
      accountCount: scope.accountIDs.count,
      categoryCount: scope.categoryIDs.count
    )
    let running = chronological.count > 1
      ? IncomeVsSpendingMaths.runningNet(rows: chronological, through: selected.period)
      : nil
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        headerStat("Income", MoneyCodec.displayString(for: selected.income, currencyFormat: model.currencyFormat), colour: selected.income == 0 ? .secondary : Theme.inflow)
        Spacer()
        headerStat("Spending", MoneyCodec.displayString(for: abs(selected.spending), currencyFormat: model.currencyFormat), colour: selected.spending == 0 ? .secondary : Theme.outflow)
        Spacer()
        headerStat("Net", MoneyCodec.signedDisplayString(for: selected.net, currencyFormat: model.currencyFormat), colour: Theme.signedReportColour(selected.net))
        Spacer()
        headerStat("Saved", saved, colour: selected.income == 0 ? .secondary : Theme.signedReportColour(selected.net))
      }
      if current {
        Text(IncomeVsSpendingMaths.inProgressCaption(from: selected.from, to: min(selected.to, today)))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if let running, let first = chronological.first {
        Text("Running net since \(IncomeVsSpendingMaths.runningSinceLabel(first.period, interval: interval)): \(MoneyCodec.signedDisplayString(for: running, currencyFormat: model.currencyFormat))")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if let filter {
        Text(filter)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .ynabCard()
  }

  private func headerStat(_ label: String, _ value: String, colour: Color) -> some View {
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

  @ViewBuilder
  private func spendingTab(_ groups: IncomeVsSpendingGroupsReport) -> some View {
    if groups.spendingByCategory.isEmpty {
      emptyTab(kind: .spending)
    } else {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Spending")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Text(MoneyCodec.displayString(for: groups.spending, currencyFormat: model.currencyFormat))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
        }
        StackedShareBar(segments: spendingSegments(groups.spendingByCategory))
        VStack(spacing: 0) {
          ForEach(Array(groups.spendingByCategory.enumerated()), id: \.element.id) { index, group in
            NavigationLink {
              registerLink(categoryID: group.categoryID, amountFilter: .spending)
            } label: {
              spendingRow(group, index: index)
            }
            .buttonStyle(.cardRow)
            if index < groups.spendingByCategory.count - 1 {
              Divider().padding(.leading, 16)
            }
          }
        }
        .ynabCard()
        Text("Totals match the Income vs Spending report. Transfers between your own accounts are left out.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(16)
      }
    }
  }

  @ViewBuilder
  private func incomeTab(_ groups: IncomeVsSpendingGroupsReport) -> some View {
    if groups.incomeByPayee.isEmpty {
      emptyTab(kind: .income)
    } else {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Income")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Text(MoneyCodec.displayString(for: groups.income, currencyFormat: model.currencyFormat))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
        }
        StackedShareBar(segments: incomeSegments(groups.incomeByPayee))
        VStack(spacing: 0) {
          ForEach(Array(groups.incomeByPayee.enumerated()), id: \.element.id) { index, group in
            NavigationLink {
              registerLink(payee: group, amountFilter: .income)
            } label: {
              incomeRow(group)
            }
            .buttonStyle(.cardRow)
            if index < groups.incomeByPayee.count - 1 {
              Divider().padding(.leading, 16)
            }
          }
        }
        .ynabCard()
        Text("Anything that adds money to an account counts as income, including refunds and reimbursements.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(16)
      }
    }
  }

  private func spendingRow(_ group: IncomeVsSpendingSpendingGroup, index: Int) -> some View {
    HStack(spacing: 12) {
      Circle()
        .fill(group.categoryID == CategoryGroup.uncategorisedCategoryID ? Theme.uncategorised : Theme.chartColour(index))
        .frame(width: 8, height: 8)
      Text(group.categoryName)
        .font(.subheadline)
        .foregroundStyle(Theme.textPrimary)
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text(MoneyCodec.displayString(for: group.amount, currencyFormat: model.currencyFormat))
          .font(.subheadline)
          .monospacedDigit()
        Text(IncomeVsSpendingMaths.txnShareLabel(count: group.transactionCount, share: group.share))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .contentShape(Rectangle())
  }

  private func incomeRow(_ group: IncomeVsSpendingPayeeGroup) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(group.payeeName)
          .font(.subheadline)
          .foregroundStyle(Theme.textPrimary)
        Text(group.categoryName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text(MoneyCodec.displayString(for: group.amount, currencyFormat: model.currencyFormat))
          .font(.subheadline)
          .monospacedDigit()
        Text(IncomeVsSpendingMaths.txnShareLabel(count: group.transactionCount, share: group.share))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private func emptyTab(kind: IncomeSpendingTab) -> some View {
    let name = IncomeVsSpendingMaths.emptyPeriodName(selectedPeriod, interval: interval)
    let noun = IncomeVsSpendingMaths.emptyWindowNoun(interval)
    switch kind {
    case .income:
      ContentUnavailableView(
        "No income in \(name)",
        systemImage: "arrow.down.circle",
        description: Text("Nothing was added to your accounts \(noun).")
      )
    case .spending:
      ContentUnavailableView(
        "No spending in \(name)",
        systemImage: "arrow.up.circle",
        description: Text("Nothing was spent \(noun).")
      )
    }
  }

  private func spendingSegments(_ groups: [IncomeVsSpendingSpendingGroup]) -> [(colour: Color, fraction: Double)] {
    var segments: [(colour: Color, fraction: Double)] = groups.prefix(6).enumerated().map { index, group in
      let colour = group.categoryID == CategoryGroup.uncategorisedCategoryID
        ? Theme.uncategorised
        : Theme.chartColour(index)
      return (colour, group.share)
    }
    let remainder = groups.dropFirst(6).reduce(0.0) { $0 + $1.share }
    if remainder > 0 {
      segments.append((Color.secondary.opacity(0.4), remainder))
    }
    return segments
  }

  private func incomeSegments(_ groups: [IncomeVsSpendingPayeeGroup]) -> [(colour: Color, fraction: Double)] {
    var segments: [(colour: Color, fraction: Double)] = groups.prefix(6).enumerated().map { index, group in
      (Theme.inflowChartColour(index), group.share)
    }
    let remainder = groups.dropFirst(6).reduce(0.0) { $0 + $1.share }
    if remainder > 0 {
      segments.append((Color.secondary.opacity(0.4), remainder))
    }
    return segments
  }

  @ViewBuilder
  private func registerLink(categoryID: String? = nil, payee: IncomeVsSpendingPayeeGroup? = nil, amountFilter: RegisterAmountFilter) -> some View {
    if let selected = rows.first(where: { $0.period == selectedPeriod }) ?? rows.first {
      let dateRange = selected.from ... min(selected.to, Date.now.isoDateString)
      RegisterView(
        scope: .all,
        categoryID: categoryID,
        payeeID: payee?.payeeID,
        payeeName: payee?.payeeName,
        missingPayee: payee.map { $0.payeeID == nil && $0.payeeName == "No payee" } ?? false,
        dateRange: dateRange,
        accountIDs: scope.accountIDs.isEmpty ? nil : scope.accountIDs,
        amountFilter: amountFilter,
        excludePlainTransfers: true
      )
    }
  }

  private func canStep(from selected: IncomeVsSpendingMaths.PeriodRow, delta: Int) -> Bool {
    guard let index = rows.firstIndex(where: { $0.period == selected.period }) else {
      return false
    }
    // rows are newest-first, so +1 is older.
    let next = index + (delta < 0 ? 1 : -1)
    return rows.indices.contains(next)
  }

  private func step(from selected: IncomeVsSpendingMaths.PeriodRow, delta: Int) {
    guard let index = rows.firstIndex(where: { $0.period == selected.period }) else {
      return
    }
    let next = index + (delta < 0 ? 1 : -1)
    guard rows.indices.contains(next) else {
      return
    }
    selectedPeriod = rows[next].period
  }

  private func fetch() async {
    let token = fetchGate.begin()
    phase = .loading
    guard let selected = rows.first(where: { $0.period == selectedPeriod }) ?? rows.first else {
      phase = .loaded
      return
    }
    do {
      let next = try await model.apiClient.fetchIncomeVsSpendingGroups(
        planID: model.settings.planID,
        from: selected.from,
        to: min(selected.to, Date.now.isoDateString),
        accountIDs: Array(scope.accountIDs),
        categoryIDs: Array(scope.categoryIDs)
      )
      guard fetchGate.isCurrent(token), !Task.isCancelled else { return }
      withAnimation(Theme.Motion.arrive) {
        groups = next
        phase = .loaded
      }
    } catch {
      guard fetchGate.isCurrent(token), !Task.isCancelled else { return }
      withAnimation(Theme.Motion.arrive) {
        if groups == nil {
          phase = .failed(error.localizedDescription)
        }
      }
    }
  }
}

