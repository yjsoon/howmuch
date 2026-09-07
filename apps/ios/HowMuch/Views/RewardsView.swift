import SwiftUI

struct RewardsView: View {
  @Environment(AppModel.self) private var model
  @State private var range = ReportRange(mode: .preset, preset: .allTime)
  @State private var scope = ReportScope()
  @State private var group: RewardGroupBy = .flag
  @State private var report: RewardsReport?
  @State private var phase: LoadPhase = .idle
  @State private var showingImport = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ReportFilterBar(range: $range, group: $group, scope: $scope)

        if let report {
          headlines(report)

          if let message = phase.errorMessage {
            Label(message, systemImage: "wifi.exclamationmark")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }

          if report.cards.isEmpty {
            emptyState
          } else {
            board(report)
          }
          groupsTable(report)
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
    .navigationTitle("Rewards")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        DestinationsMenu()
      }
    }
    .moreDestinations()
    .sheet(isPresented: $showingImport) {
      NavigationStack {
        RewardsImportView()
      }
      .blocksCapturePresentation()
    }
    .task(id: fetchKey) {
      await fetch()
    }
    .refreshable {
      await fetch()
    }
  }

  private var fetchKey: String {
    "\(model.settings.planID)|\(model.rewardsRefreshGeneration)|\(range.key)|\(scope.key)|\(group.rawValue)"
  }

  private var cashback: [RewardsCardRow] {
    (report?.cards ?? []).filter { $0.card.type == .cashback }
  }

  private var miles: [RewardsCardRow] {
    (report?.cards ?? []).filter { $0.card.type == .miles }
  }

  @ViewBuilder
  private func headlines(_ report: RewardsReport) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Qualifying spend")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text(MoneyCodec.displayString(forCurrencyUnits: report.totals.spend, currencyFormat: model.currencyFormat))
        .font(.title.weight(.bold))
        .monospacedDigit()
        .foregroundStyle(Theme.textPrimary)

      HStack {
        Text("Value")
          .foregroundStyle(.secondary)
        Spacer()
        Text(MoneyCodec.displayString(forCurrencyUnits: report.totals.rewardDollars, currencyFormat: model.currencyFormat))
          .monospacedDigit()
          .foregroundStyle(Theme.inflow)
      }
      .font(.subheadline)

      if report.totals.miles > 0 {
        HStack {
          Text("Miles")
            .foregroundStyle(.secondary)
          Spacer()
          Text(Self.milesString(report.totals.miles))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
        }
        .font(.subheadline)
      }

      if report.totals.cashback > 0 {
        HStack {
          Text("Cashback")
            .foregroundStyle(.secondary)
          Spacer()
          Text(MoneyCodec.displayString(forCurrencyUnits: report.totals.cashback, currencyFormat: model.currencyFormat))
            .monospacedDigit()
            .foregroundStyle(Theme.inflow)
        }
        .font(.subheadline)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .ynabCard()
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No reward cards in this range.")
        .font(.headline)
        .foregroundStyle(Theme.textPrimary)
      Text("Import from Connection settings → Rewards import, or choose accounts that have cards.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Button("Rewards import") {
        showingImport = true
      }
      .buttonStyle(.borderedProminent)
      .tint(Theme.accent)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .ynabCard()
  }

  @ViewBuilder
  private func board(_ report: RewardsReport) -> some View {
    if !cashback.isEmpty {
      section(title: "Cashback", rows: cashback)
    }
    if !miles.isEmpty {
      section(title: "Miles", rows: miles)
    }
  }

  private func section(title: String, rows: [RewardsCardRow]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      ForEach(rows) { row in
        RewardTile(row: row, currencyFormat: model.currencyFormat)
      }
    }
  }

  @ViewBuilder
  private func groupsTable(_ report: RewardsReport) -> some View {
    if !report.groups.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("By \(group.title)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer()
          Text("\(report.groups.count) groups")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        VStack(spacing: 0) {
          ForEach(Array(report.groups.enumerated()), id: \.element.id) { index, row in
            HStack(spacing: 8) {
              Circle()
                .fill(Theme.flagColour(named: row.flagColor) ?? Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
              Text(row.label)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
              Spacer()
              Text(MoneyCodec.displayString(forCurrencyUnits: row.spend, currencyFormat: model.currencyFormat))
                .font(.subheadline)
                .monospacedDigit()
              Text(MoneyCodec.displayString(forCurrencyUnits: row.rewardDollars, currencyFormat: model.currencyFormat))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(Theme.inflow)
              Text("\(row.transactionCount)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            if index < report.groups.count - 1 {
              Divider()
            }
          }
        }
        .padding(.horizontal, 16)
        .ynabCard()
      }
    }
  }

  private func fetch() async {
    let planID = model.settings.planID
    let key = fetchKey
    phase = .loading
    do {
      let next = try await model.apiClient.fetchRewards(
        planID: planID,
        from: range.fromISO,
        to: range.toISO,
        accountIDs: Array(scope.accountIDs),
        group: group
      )
      guard key == fetchKey, planID == model.settings.planID else {
        return
      }
      report = next
      phase = .loaded
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

  fileprivate static func milesString(_ value: Double) -> String {
    Int(value.rounded()).formatted(IntegerFormatStyle<Int>(locale: Locale(identifier: "en_GB")))
  }
}

private struct RewardTile: View {
  let row: RewardsCardRow
  let currencyFormat: CurrencyFormat?

  var body: some View {
    let calc = row.calculation
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.card.name)
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(earnedLabel)
          .font(.caption.weight(.semibold))
          .monospacedDigit()
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Theme.surfaceMuted, in: Capsule())
          .foregroundStyle(Theme.inflow)
      }

      HStack {
        labeled("Qualifying spend", MoneyCodec.displayString(forCurrencyUnits: calc.totalSpend, currencyFormat: currencyFormat))
        Spacer()
        labeled("Value", MoneyCodec.displayString(forCurrencyUnits: calc.rewardEarnedDollars, currencyFormat: currencyFormat))
      }

      if let minimum = calc.minimumSpend {
        let progress = min(1, max(0, (calc.minimumSpendProgress ?? 0) / 100))
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(calc.minimumSpendMet ? "Minimum met" : "Minimum spend")
            Spacer()
            Text("\(MoneyCodec.displayString(forCurrencyUnits: calc.totalSpend, currencyFormat: currencyFormat)) / \(MoneyCodec.displayString(forCurrencyUnits: minimum, currencyFormat: currencyFormat))")
              .monospacedDigit()
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          ProgressView(value: progress)
            .tint(Theme.accent)
        }
      }

      ForEach(calc.flags) { flag in
        HStack {
          Circle()
            .fill(Theme.flagColour(named: flag.flagColor) ?? Color.secondary.opacity(0.4))
            .frame(width: 8, height: 8)
          Text(flag.name)
            .font(.subheadline)
          if let rate = flag.rewardRate {
            Text("\(rate.formatted())×")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text(flagEarned(flag, type: calc.rewardType))
            .font(.subheadline)
            .monospacedDigit()
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .ynabCard()
    .opacity(calc.maximumSpendExceeded ? 0.85 : 1)
  }

  private var subtitle: String {
    [row.card.issuer, row.accountName].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private var earnedLabel: String {
    formatReward(row.calculation.rewardEarned, row.calculation.rewardType)
  }

  private func flagEarned(_ flag: RewardsFlagRow, type: RewardKind) -> String {
    formatReward(flag.rewardEarned, type)
  }

  private func formatReward(_ value: Double, _ type: RewardKind) -> String {
    switch type {
    case .cashback:
      return MoneyCodec.displayString(forCurrencyUnits: value, currencyFormat: currencyFormat)
    case .miles:
      return RewardsView.milesString(value)
    }
  }

  private func labeled(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(Theme.textPrimary)
    }
  }
}
