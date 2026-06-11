import SwiftUI

/// Range selection shared by the Reflect detail screens: a single month with
/// stepper arrows, or one of YNAB's presets.
struct ReportRange: Equatable {
  enum Mode: String, CaseIterable, Identifiable {
    case month = "Month"
    case preset = "Preset"

    var id: String { rawValue }
  }

  var mode: Mode = .month
  var monthAnchor = Date().startOfMonth()
  var preset: ReportPreset = .lastThreeMonths

  var fromISO: String {
    switch mode {
    case .month:
      return monthAnchor.startOfMonth().isoDateString
    case .preset:
      return preset.range().from.isoDateString
    }
  }

  var toISO: String {
    switch mode {
    case .month:
      return min(monthAnchor.endOfMonth(), Date()).isoDateString
    case .preset:
      return preset.range().to.isoDateString
    }
  }

  var label: String {
    switch mode {
    case .month:
      return monthAnchor.monthYearLabel
    case .preset:
      return preset.title
    }
  }

  /// Cache key for `.task(id:)` refetching.
  var key: String {
    "\(mode.rawValue)|\(fromISO)|\(toISO)"
  }
}

/// Month/Preset segmented control plus the matching range selector pill.
struct ReportRangePicker: View {
  @Binding var range: ReportRange

  var body: some View {
    VStack(spacing: 12) {
      Picker("Range mode", selection: $range.mode) {
        ForEach(ReportRange.Mode.allCases) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      switch range.mode {
      case .month:
        MonthStepper(monthAnchor: $range.monthAnchor)
      case .preset:
        Menu {
          ForEach(ReportPreset.allCases) { preset in
            Button(preset.title) {
              range.preset = preset
            }
          }
        } label: {
          HStack(spacing: 6) {
            Text(range.preset.title)
              .font(.subheadline.weight(.semibold))
            Image(systemName: "chevron.down")
              .font(.caption.weight(.semibold))
          }
          .foregroundStyle(Theme.accent)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(Theme.surfaceMuted, in: Capsule())
        }
      }
    }
  }

}

// MARK: - Spending Breakdown

struct SpendingBreakdownDetailView: View {
  @Environment(AppModel.self) private var model
  @State private var range = ReportRange()
  @State private var report: SpendingBreakdownReport?
  @State private var phase: LoadPhase = .idle

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ReportRangePicker(range: $range)

        if let report {
          let rows = ReflectMaths.demoted(report.groups)

          VStack(spacing: 10) {
            Text("Total Spending")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Text(MoneyCodec.displayString(for: abs(report.total), currencyFormat: model.currencyFormat))
              .font(.system(size: 34, weight: .bold))
              .monospacedDigit()
              .foregroundStyle(Theme.textPrimary)
            StackedShareBar(segments: ReflectMaths.shareSegments(rows, limit: 6))
          }
          .frame(maxWidth: .infinity)
          .padding(16)
          .ynabCard()

          if rows.isEmpty {
            Text("No spending in this range.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 24)
          } else {
            Text("Categories")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
              .padding(.horizontal, 4)

            VStack(spacing: 0) {
              ForEach(Array(rows.enumerated()), id: \.element.id) { index, group in
                NavigationLink {
                  RegisterView(
                    scope: .all,
                    categoryID: group.categoryID,
                    dateRange: range.fromISO ... range.toISO
                  )
                } label: {
                  categoryRow(group, colour: Theme.chartColour(index), total: abs(report.total))
                }
                .buttonStyle(.plain)
                if index < rows.count - 1 {
                  Divider().padding(.leading, 16)
                }
              }
            }
            .ynabCard()
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
    .task(id: range.key) {
      await fetch()
    }
  }

  private func categoryRow(_ group: SpendingBreakdownGroup, colour: Color, total: Int) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text(group.categoryName)
          .font(.subheadline)
          .foregroundStyle(Theme.textPrimary)
        HStack(spacing: 8) {
          GeometryReader { proxy in
            Capsule()
              .fill(Theme.surfaceMuted)
              .overlay(alignment: .leading) {
                Capsule()
                  .fill(colour)
                  .frame(width: max(4, proxy.size.width * min(group.share, 1)))
              }
          }
          .frame(width: 120, height: 6)
          Text(shareLabel(group.share))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Text(MoneyCodec.displayString(for: abs(group.amount), currencyFormat: model.currencyFormat))
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(Theme.textPrimary)
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
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
      report = try await model.apiClient.fetchSpendingBreakdown(
        planID: model.settings.planID, from: range.fromISO, to: range.toISO
      )
      phase = .loaded
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}

// MARK: - Net Worth

struct NetWorthDetailView: View {
  @Environment(AppModel.self) private var model
  @State private var range = ReportRange(mode: .preset, preset: .lastTwelveMonths)
  @State private var report: NetWorthReport?
  @State private var phase: LoadPhase = .idle

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ReportRangePicker(range: $range)

        if let report, let latest = report.periods.last {
          let assets = latest.accounts.map(\.balance).filter { $0 > 0 }.reduce(0, +)
          let debts = latest.accounts.map(\.balance).filter { $0 < 0 }.reduce(0, +)

          VStack(spacing: 10) {
            Text("Net Worth")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Text(MoneyCodec.displayString(for: latest.netWorth, currencyFormat: model.currencyFormat))
              .font(.system(size: 34, weight: .bold))
              .monospacedDigit()
              .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 24) {
              VStack(spacing: 2) {
                Text("Assets")
                  .font(.caption)
                  .foregroundStyle(Theme.accent)
                Text(MoneyCodec.displayString(for: assets, currencyFormat: model.currencyFormat))
                  .font(.subheadline.weight(.semibold))
                  .monospacedDigit()
              }
              VStack(spacing: 2) {
                Text("Debts")
                  .font(.caption)
                  .foregroundStyle(Theme.outflow)
                Text(MoneyCodec.displayString(for: debts, currencyFormat: model.currencyFormat))
                  .font(.subheadline.weight(.semibold))
                  .monospacedDigit()
              }
            }
            ColumnChart(values: report.periods.map { Double($0.netWorth) }, height: 120)
          }
          .frame(maxWidth: .infinity)
          .padding(16)
          .ynabCard()

          Text("Accounts")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 4)

          VStack(spacing: 0) {
            let accounts = latest.accounts.sorted { abs($0.balance) > abs($1.balance) }
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
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
    .task(id: range.key) {
      await fetch()
    }
  }

  private func fetch() async {
    phase = .loading
    do {
      report = try await model.apiClient.fetchNetWorth(
        planID: model.settings.planID, from: range.fromISO, to: range.toISO, interval: .month
      )
      phase = .loaded
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}

// MARK: - Income vs Spending

struct IncomeVsSpendingDetailView: View {
  @Environment(AppModel.self) private var model
  @State private var range = ReportRange(mode: .preset, preset: .lastTwelveMonths)
  @State private var report: IncomeVsSpendingReport?
  @State private var phase: LoadPhase = .idle

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ReportRangePicker(range: $range)

        if let report, !report.periods.isEmpty {
          VStack(spacing: 12) {
            PairedColumnChart(
              pairs: report.periods.map { (Double($0.income), Double(abs($0.spending))) },
              height: 120
            )
            HStack(spacing: 16) {
              legendDot(colour: Theme.inflow, label: "Income")
              legendDot(colour: Theme.outflow, label: "Spending")
            }
          }
          .padding(16)
          .ynabCard()

          VStack(spacing: 0) {
            ForEach(Array(report.periods.reversed().enumerated()), id: \.element.id) { index, period in
              VStack(alignment: .leading, spacing: 6) {
                Text(LedgerDate.periodLabel(period.period))
                  .font(.subheadline.weight(.semibold))
                  .foregroundStyle(Theme.textPrimary)
                HStack {
                  amountColumn("Income", period.income, colour: Theme.inflow)
                  Spacer()
                  amountColumn("Spending", period.spending, colour: Theme.outflow)
                  Spacer()
                  amountColumn("Net", period.net, colour: Theme.amountColour(period.net))
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
    .task(id: range.key) {
      await fetch()
    }
  }

  private func amountColumn(_ label: String, _ amount: Int, colour: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(MoneyCodec.displayString(for: amount, currencyFormat: model.currencyFormat))
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
      report = try await model.apiClient.fetchIncomeVsSpending(
        planID: model.settings.planID, from: range.fromISO, to: range.toISO, interval: .month
      )
      phase = .loaded
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}

// MARK: - Age of Money

struct AgeOfMoneyDetailView: View {
  @Environment(AppModel.self) private var model
  @State private var report: AgeOfMoneyReport?
  @State private var phase: LoadPhase = .idle

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // No range picker: the server replays income lots from the start of
        // the window, so the age is only honest over the full history.
        if let report {
          let ages = report.periods.compactMap(\.ageOfMoneyDays)

          VStack(spacing: 10) {
            Text("Age of Money")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            if let latest = ages.last {
              Text("\(Int(latest.rounded())) Days")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            } else {
              Text("Not enough matched income yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if ages.count > 1 {
              Sparkline(values: ages, colour: Theme.inflow, height: 80)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(16)
          .ynabCard()

          VStack(spacing: 0) {
            ForEach(Array(report.periods.reversed().enumerated()), id: \.element.id) { index, period in
              HStack {
                Text(LedgerDate.periodLabel(period.period))
                  .font(.subheadline)
                  .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let age = period.ageOfMoneyDays {
                  Text("\(Int(age.rounded())) days")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                } else {
                  Text("—")
                    .foregroundStyle(.secondary)
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
    .task {
      await fetch()
    }
  }

  private func fetch() async {
    phase = .loading
    do {
      report = try await model.apiClient.fetchAgeOfMoney(planID: model.settings.planID, interval: .month)
      phase = .loaded
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}
