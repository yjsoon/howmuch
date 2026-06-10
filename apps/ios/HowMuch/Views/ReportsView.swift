import SwiftUI

struct ReportsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        controls

        if let error = model.lastErrorMessage {
          Label(error, systemImage: "wifi.exclamationmark")
            .foregroundStyle(.red)
        }

        spendingSection
        incomeSection
        netWorthSection
        ageOfMoneySection
      }
      .padding()
    }
    .navigationTitle("Reports")
    .refreshable {
      await model.refreshReports()
    }
  }

  private var controls: some View {
    let windowBinding = Binding(
      get: { model.reportWindow },
      set: { model.reportWindow = $0 }
    )
    let intervalBinding = Binding(
      get: { model.reportInterval },
      set: { model.reportInterval = $0 }
    )

    return VStack(alignment: .leading, spacing: 12) {
      Text("Summary Window")
        .font(.headline)

      Picker("Window", selection: windowBinding) {
        ForEach(ReportWindow.allCases) { window in
          Text(window.title).tag(window)
        }
      }
      .pickerStyle(.segmented)

      Picker("Interval", selection: intervalBinding) {
        ForEach(ReportInterval.allCases) { interval in
          Text(interval.title).tag(interval)
        }
      }
      .pickerStyle(.segmented)
      .onChange(of: model.reportWindow) { _, _ in
        Task { await model.refreshReports() }
      }
      .onChange(of: model.reportInterval) { _, _ in
        Task { await model.refreshReports() }
      }
    }
  }

  private var spendingSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Spending Breakdown")
        .font(.title3.bold())

      if let report = model.spendingBreakdown {
        Text(MoneyCodec.displayString(for: report.total, currencyFormat: model.planSettings?.currencyFormat))
          .font(.title2.monospacedDigit())

        ForEach(report.groups.prefix(5)) { group in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(group.categoryName)
              Spacer()
              Text(MoneyCodec.displayString(for: group.amount, currencyFormat: model.planSettings?.currencyFormat))
                .monospacedDigit()
            }
            ProgressView(value: group.share)
          }
        }
      } else {
        placeholderCard
      }
    }
  }

  private var incomeSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Income vs Spending")
        .font(.title3.bold())

      if let period = model.incomeVsSpending?.periods.last {
        reportMetricRow(title: "Income", value: period.income, colour: .green)
        reportMetricRow(title: "Spending", value: period.spending, colour: .red)
        reportMetricRow(title: "Net", value: period.net, colour: period.net >= 0 ? .green : .red)
        Text("Latest period: \(period.period)")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        placeholderCard
      }
    }
  }

  private var netWorthSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Net Worth")
        .font(.title3.bold())

      if let latest = model.netWorth?.periods.last {
        Text(MoneyCodec.displayString(for: latest.netWorth, currencyFormat: model.planSettings?.currencyFormat))
          .font(.title2.monospacedDigit())
        ForEach(latest.accounts.prefix(5)) { account in
          HStack {
            Text(account.accountName)
            Spacer()
            Text(MoneyCodec.displayString(for: account.balance, currencyFormat: model.planSettings?.currencyFormat))
              .monospacedDigit()
          }
          .font(.subheadline)
        }
      } else {
        placeholderCard
      }
    }
  }

  private var ageOfMoneySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Age of Money")
        .font(.title3.bold())

      if let latest = model.ageOfMoney?.periods.last {
        Text(latest.ageOfMoneyDays.map { "\($0.formatted(.number.precision(.fractionLength(1)))) days" } ?? "No data yet")
          .font(.title2.monospacedDigit())
        reportMetricRow(title: "Spent", value: latest.spent, colour: .primary)
        reportMetricRow(title: "Unmatched", value: latest.unmatchedSpending, colour: .secondary)
      } else {
        placeholderCard
      }
    }
  }

  private func reportMetricRow(title: String, value: Int, colour: Color) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(MoneyCodec.displayString(for: value, currencyFormat: model.planSettings?.currencyFormat))
        .monospacedDigit()
        .foregroundStyle(colour)
    }
  }

  private var placeholderCard: some View {
    Text("Refresh after connecting to the API.")
      .font(.subheadline)
      .foregroundStyle(.secondary)
  }
}
