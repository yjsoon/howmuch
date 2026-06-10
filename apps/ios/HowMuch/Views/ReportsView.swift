import SwiftUI

struct ReportsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model

    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        controls(model: model)

        if let message = model.reportsPhase.errorMessage {
          failureCard(message: message)
        }

        spendingCard
        incomeCard
        netWorthCard
        ageOfMoneyCard
      }
      .padding(.horizontal)
      .padding(.bottom, 24)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Reports")
    .refreshable {
      await model.refreshReports()
    }
  }

  // MARK: - Controls

  private func controls(model: AppModel) -> some View {
    @Bindable var model = model

    return VStack(spacing: 8) {
      Picker("Window", selection: $model.reportWindow) {
        ForEach(ReportWindow.allCases) { window in
          Text(window.title).tag(window)
        }
      }
      .pickerStyle(.segmented)

      Picker("Interval", selection: $model.reportInterval) {
        ForEach(ReportInterval.allCases) { interval in
          Text("By \(interval.title)").tag(interval)
        }
      }
      .pickerStyle(.segmented)
    }
    .onChange(of: model.reportWindow) {
      Task { await model.refreshReports() }
    }
    .onChange(of: model.reportInterval) {
      Task { await model.refreshReports() }
    }
  }

  private func failureCard(message: String) -> some View {
    ReportCard(title: "Cannot load reports") {
      Text(message)
        .font(.footnote)
        .foregroundStyle(.secondary)
      Button("Try again") {
        Task { await model.refreshReports() }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  // MARK: - Spending

  private var spendingCard: some View {
    ReportCard(title: "Spending") {
      if let report = model.spendingBreakdown {
        if report.groups.isEmpty {
          quietEmpty("No spending in this window.")
        } else {
          AmountHeadline(
            value: MoneyCodec.displayString(for: report.total, currencyFormat: model.currencyFormat),
            caption: "total across \(report.groups.count) categories",
            colour: Theme.outflow
          )

          VStack(spacing: 8) {
            ForEach(report.groups.prefix(6)) { group in
              ShareBarRow(
                label: group.categoryName,
                amount: MoneyCodec.displayString(for: group.amount, currencyFormat: model.currencyFormat),
                share: group.share
              )
            }
          }

          if report.groups.count > 6 {
            Text("and \(report.groups.count - 6) more categories")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
      } else {
        loadingPlaceholder
      }
    }
  }

  // MARK: - Income vs spending

  private var incomeCard: some View {
    ReportCard(title: "Income v Spending") {
      if let report = model.incomeVsSpending {
        if report.periods.isEmpty {
          quietEmpty("No activity in this window.")
        } else {
          PairedColumnsChart(periods: report.periods)
            .frame(height: 72)

          if let latest = report.periods.last {
            VStack(spacing: 6) {
              metricRow("Income", amount: latest.income, colour: Theme.inflow)
              metricRow("Spending", amount: latest.spending, colour: Theme.outflow)
              Divider()
              metricRow("Net", amount: latest.net, colour: Theme.amountColour(latest.net))
            }
            captionRow("Latest: \(LedgerDate.periodLabel(latest.period))")
          }
        }
      } else {
        loadingPlaceholder
      }
    }
  }

  // MARK: - Net worth

  private var netWorthCard: some View {
    ReportCard(title: "Net Worth") {
      if let report = model.netWorth {
        if report.periods.isEmpty {
          quietEmpty("No balances in this window.")
        } else if let latest = report.periods.last {
          AmountHeadline(
            value: MoneyCodec.displayString(for: latest.netWorth, currencyFormat: model.currencyFormat),
            caption: deltaCaption(latest.delta),
            colour: .primary
          )

          Sparkline(values: report.periods.map(\.netWorth))
            .frame(height: 44)

          VStack(spacing: 6) {
            ForEach(latest.accounts.prefix(5)) { account in
              metricRow(account.accountName, amount: account.balance, colour: .secondary)
            }
          }
          if latest.accounts.count > 5 {
            Text("and \(latest.accounts.count - 5) more accounts")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
      } else {
        loadingPlaceholder
      }
    }
  }

  private func deltaCaption(_ delta: Int?) -> String {
    guard let delta, delta != 0 else {
      return "unchanged from previous period"
    }
    let formatted = MoneyCodec.signedDisplayString(for: delta, currencyFormat: model.currencyFormat)
    return "\(formatted) since previous period"
  }

  // MARK: - Age of money

  private var ageOfMoneyCard: some View {
    ReportCard(title: "Age of Money") {
      if let report = model.ageOfMoney {
        let measured = report.periods.compactMap { period in
          period.ageOfMoneyDays.map { (period: period, days: $0) }
        }
        if let latest = measured.last {
          AmountHeadline(
            value: "\(latest.days.formatted(.number.precision(.fractionLength(0)))) days",
            caption: "as of \(LedgerDate.periodLabel(latest.period.period))",
            colour: .primary
          )

          if measured.count > 1 {
            Sparkline(values: measured.map { Int($0.days * 10) })
              .frame(height: 36)
          }

          if latest.period.unmatchedSpending != 0 {
            captionRow("\(MoneyCodec.displayString(for: latest.period.unmatchedSpending, currencyFormat: model.currencyFormat)) of spending predates known income and is excluded.")
          }
        } else if report.periods.isEmpty {
          quietEmpty("No activity in this window.")
        } else {
          quietEmpty("Not enough matched income to measure yet.")
        }
      } else {
        loadingPlaceholder
      }
    }
  }

  // MARK: - Shared bits

  private func metricRow(_ title: String, amount: Int, colour: Color) -> some View {
    HStack {
      Text(title)
        .font(.subheadline)
        .lineLimit(1)
      Spacer(minLength: 12)
      Text(MoneyCodec.displayString(for: amount, currencyFormat: model.currencyFormat))
        .font(.subheadline.weight(.medium).monospacedDigit())
        .foregroundStyle(colour)
    }
  }

  private func captionRow(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.tertiary)
  }

  private func quietEmpty(_ text: String) -> some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 8)
  }

  @ViewBuilder
  private var loadingPlaceholder: some View {
    if model.reportsPhase.isLoading {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(0 ..< 3, id: \.self) { _ in
          RoundedRectangle(cornerRadius: 4)
            .fill(Color(.tertiarySystemFill))
            .frame(height: 14)
        }
      }
      .padding(.vertical, 4)
    } else {
      quietEmpty("Pull to refresh once the API is reachable.")
    }
  }
}

// MARK: - Card container

private struct ReportCard<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title3.weight(.semibold))
        .fontDesign(.serif)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(.secondarySystemGroupedBackground))
    )
  }
}

private struct AmountHeadline: View {
  let value: String
  let caption: String
  let colour: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.system(.title, design: .rounded).weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(colour)
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}

private struct ShareBarRow: View {
  let label: String
  let amount: String
  let share: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(label)
          .font(.subheadline)
          .lineLimit(1)
        Spacer(minLength: 12)
        Text(amount)
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color(.tertiarySystemFill))
          Capsule()
            .fill(Theme.outflow.opacity(0.85))
            .frame(width: max(3, proxy.size.width * share))
        }
      }
      .frame(height: 5)
    }
  }
}

// MARK: - Mini charts

private struct PairedColumnsChart: View {
  let periods: [IncomeVsSpendingPeriod]

  var body: some View {
    let peak = max(periods.map(\.income).max() ?? 0, periods.map(\.spending).max() ?? 0)

    HStack(alignment: .bottom, spacing: 6) {
      ForEach(periods) { period in
        HStack(alignment: .bottom, spacing: 2) {
          column(value: period.income, peak: peak, colour: Theme.inflow)
          column(value: period.spending, peak: peak, colour: Theme.outflow)
        }
        .frame(maxWidth: .infinity)
      }
    }
  }

  private func column(value: Int, peak: Int, colour: Color) -> some View {
    GeometryReader { proxy in
      let fraction = peak > 0 ? Double(value) / Double(peak) : 0
      VStack {
        Spacer(minLength: 0)
        RoundedRectangle(cornerRadius: 2)
          .fill(colour.opacity(0.85))
          .frame(height: max(2, proxy.size.height * fraction))
      }
    }
  }
}

private struct Sparkline: View {
  let values: [Int]

  var body: some View {
    GeometryReader { proxy in
      if values.count > 1, let minValue = values.min(), let maxValue = values.max() {
        let range = max(1, maxValue - minValue)
        let points = values.enumerated().map { index, value in
          CGPoint(
            x: proxy.size.width * CGFloat(index) / CGFloat(values.count - 1),
            y: proxy.size.height * (1 - CGFloat(value - minValue) / CGFloat(range))
          )
        }

        ZStack {
          Path { path in
            path.move(to: CGPoint(x: points[0].x, y: proxy.size.height))
            for point in points {
              path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: proxy.size.height))
            path.closeSubpath()
          }
          .fill(Color.secondary.opacity(0.12))

          Path { path in
            path.move(to: points[0])
            for point in points.dropFirst() {
              path.addLine(to: point)
            }
          }
          .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
      }
    }
  }
}
