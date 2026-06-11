import SwiftUI

struct ReflectView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ScreenTitle("Reflect")

        if model.spendingBreakdown == nil, model.reportsPhase != .loaded {
          PhasePlaceholder(phase: model.reportsPhase) {
            await model.refreshReflectOverview()
          }
        } else {
          ReflectCard(icon: "chart.pie.fill", title: "Spending Breakdown") {
            SpendingBreakdownDetailView()
          } content: {
            spendingContent
          }

          ReflectCard(icon: "building.columns.fill", title: "Net Worth") {
            NetWorthDetailView()
          } content: {
            netWorthContent
          }

          ReflectCard(icon: "arrow.left.arrow.right", title: "Income vs Spending") {
            IncomeVsSpendingDetailView()
          } content: {
            incomeContent
          }

          ReflectCard(icon: "clock.fill", title: "Age of Money") {
            AgeOfMoneyDetailView()
          } content: {
            ageContent
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

  // MARK: Spending Breakdown

  @ViewBuilder
  private var spendingContent: some View {
    if let report = model.spendingBreakdown {
      let rows = ReflectMaths.demoted(report.groups)
      VStack(alignment: .leading, spacing: 12) {
        Text(Date().monthYearLabel)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text(MoneyCodec.displayString(for: abs(report.total), currencyFormat: model.currencyFormat))
          .font(.title.weight(.bold))
          .monospacedDigit()
          .foregroundStyle(Theme.textPrimary)

        if !rows.isEmpty {
          StackedShareBar(segments: ReflectMaths.shareSegments(rows, limit: 6))

          HStack {
            Text("Top Categories")
            Spacer()
            Text("Spent")
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

          VStack(spacing: 8) {
            ForEach(Array(rows.prefix(5).enumerated()), id: \.element.id) { index, group in
              HStack(spacing: 8) {
                Circle()
                  .fill(Theme.chartColour(index))
                  .frame(width: 8, height: 8)
                Text(group.categoryName)
                  .font(.subheadline)
                  .foregroundStyle(Theme.textPrimary)
                  .lineLimit(1)
                Spacer()
                Text(MoneyCodec.displayString(for: abs(group.amount), currencyFormat: model.currencyFormat))
                  .font(.subheadline)
                  .monospacedDigit()
                  .foregroundStyle(Theme.textPrimary)
              }
            }
            if rows.count > 5 {
              let remainder = rows.dropFirst(5).reduce(0) { $0 + abs($1.amount) }
              HStack(spacing: 8) {
                Circle()
                  .fill(Color.secondary.opacity(0.4))
                  .frame(width: 8, height: 8)
                Text("All Others")
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
                Spacer()
                Text(MoneyCodec.displayString(for: remainder, currencyFormat: model.currencyFormat))
                  .font(.subheadline)
                  .monospacedDigit()
                  .foregroundStyle(.secondary)
              }
            }
          }
        } else {
          Text("No spending recorded this month.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: Net Worth

  @ViewBuilder
  private var netWorthContent: some View {
    if let report = model.netWorth, let latest = report.periods.last {
      let assets = latest.accounts.map(\.balance).filter { $0 > 0 }.reduce(0, +)
      let debts = latest.accounts.map(\.balance).filter { $0 < 0 }.reduce(0, +)
      VStack(alignment: .leading, spacing: 10) {
        Text(MoneyCodec.displayString(for: latest.netWorth, currencyFormat: model.currencyFormat))
          .font(.title.weight(.bold))
          .monospacedDigit()
          .foregroundStyle(Theme.textPrimary)

        HStack {
          Text("Assets")
            .foregroundStyle(Theme.accent)
          Spacer()
          Text(MoneyCodec.displayString(for: assets, currencyFormat: model.currencyFormat))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
        }
        .font(.subheadline)
        HStack {
          Text("Debts")
            .foregroundStyle(Theme.outflow)
          Spacer()
          Text(MoneyCodec.displayString(for: debts, currencyFormat: model.currencyFormat))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
        }
        .font(.subheadline)

        ColumnChart(values: report.periods.map { Double($0.netWorth) })
      }
    }
  }

  // MARK: Income vs Spending

  @ViewBuilder
  private var incomeContent: some View {
    if let report = model.incomeVsSpending, let latest = report.periods.last {
      VStack(alignment: .leading, spacing: 10) {
        Text(LedgerDate.periodLabel(latest.period))
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text(MoneyCodec.signedDisplayString(for: latest.net, currencyFormat: model.currencyFormat))
          .font(.title.weight(.bold))
          .monospacedDigit()
          .foregroundStyle(Theme.amountColour(latest.net))

        PairedColumnChart(
          pairs: report.periods.map { (Double($0.income), Double(abs($0.spending))) }
        )

        HStack(spacing: 16) {
          legendDot(colour: Theme.inflow, label: "Income")
          legendDot(colour: Theme.outflow, label: "Spending")
        }
      }
    }
  }

  // MARK: Age of Money

  @ViewBuilder
  private var ageContent: some View {
    if let report = model.ageOfMoney {
      let ages = report.periods.compactMap(\.ageOfMoneyDays)
      VStack(alignment: .leading, spacing: 10) {
        if let latest = ages.last {
          Text("\(Int(latest.rounded())) Days")
            .font(.title.weight(.bold))
            .foregroundStyle(Theme.textPrimary)
        } else {
          Text("Not enough data yet")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        if ages.count > 1 {
          Sparkline(values: ages, colour: Theme.inflow)
        }
      }
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
}

/// Card wrapper: blurple header with chevron, tappable into a detail screen.
struct ReflectCard<Destination: View, Content: View>: View {
  let icon: String
  let title: String
  @ViewBuilder let destination: () -> Destination
  @ViewBuilder let content: () -> Content

  var body: some View {
    NavigationLink {
      destination()
    } label: {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Image(systemName: icon)
            .font(.subheadline)
          Text(title)
            .font(.subheadline.weight(.semibold))
          Spacer()
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .foregroundStyle(Theme.accent)

        content()
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .ynabCard()
    }
    .buttonStyle(.plain)
  }
}

enum ReflectMaths {
  /// Spending rows with bookkeeping ("quiet") category groups pushed to the end.
  static func demoted(_ groups: [SpendingBreakdownGroup]) -> [SpendingBreakdownGroup] {
    let primary = groups.filter { !CategoryGroup.isQuietName($0.categoryGroupName) }
    let quiet = groups.filter { CategoryGroup.isQuietName($0.categoryGroupName) }
    return primary + quiet
  }

  /// Top-N share segments plus a grey remainder, for stacked bars.
  static func shareSegments(_ groups: [SpendingBreakdownGroup], limit: Int) -> [(colour: Color, fraction: Double)] {
    let total = groups.reduce(0.0) { $0 + abs(Double($1.amount)) }
    guard total > 0 else {
      return []
    }
    var segments: [(colour: Color, fraction: Double)] = groups.prefix(limit).enumerated().map { index, group in
      (colour: Theme.chartColour(index), fraction: abs(Double(group.amount)) / total)
    }
    let remainder = groups.dropFirst(limit).reduce(0.0) { $0 + abs(Double($1.amount)) }
    if remainder > 0 {
      segments.append((colour: Color.secondary.opacity(0.4), fraction: remainder / total))
    }
    return segments
  }
}
