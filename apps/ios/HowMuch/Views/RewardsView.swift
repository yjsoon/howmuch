import SwiftUI

struct RewardsBoardPreferences: Codable, Equatable {
  var hiddenCardIDs: Set<String> = []
  var cardOrder: [String] = []
  var collapsedGroups: Set<String> = []

  func orderedIDs(_ available: [String]) -> [String] {
    var remaining = Set(available)
    return (cardOrder + available).filter { remaining.remove($0) != nil }
  }

  mutating func reorder(_ ids: [String]) {
    let moved = Set(ids)
    cardOrder = ids + cardOrder.filter { !moved.contains($0) }
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

  // An omitted lower bound selects current card periods on the rewards API.
  // All Time must instead send a comparison-only lower bound for aggregation.
  var from: String? { mode == .current ? nil : (range.fromISO ?? "0001-01-01") }
  var to: String? { mode == .current ? (useAsOfDate ? asOfDate.isoDateString : nil) : range.toISO }
  var accountIDs: [String] { scope.accountIDs.sorted() }
  var key: String {
    "\(mode.rawValue)|\(useAsOfDate)|\(asOfDate.isoDateString)|\(range.key)|\(scope.key)"
  }
}

struct RewardsView: View {
  @Environment(AppModel.self) private var model
  @State private var filter: RewardsReportFilter
  @State private var featuredOnly = false
  @State private var group: RewardGroupBy = .flag
  @State private var report: RewardsReport?
  @State private var reportPlanID: String?
  @State private var phase: LoadPhase = .idle
  @State private var showingImport = false
  @State private var editorDestination: RewardCardEditorDestination?
  @State private var showingDisplayPreferences = false
  @State private var preferencesByPlan: [String: RewardsBoardPreferences] = [:]
  @State private var milesValuationText: String?
  @State private var savingValuation = false
  @State private var valuationError: String?

  init(filter: RewardsReportFilter = RewardsReportFilter()) {
    _filter = State(initialValue: filter)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading) {
          Picker("Period", selection: $filter.mode) {
            ForEach(RewardsReportFilter.Mode.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          if filter.mode == .current {
            Toggle("Choose as-of date", isOn: $filter.useAsOfDate)
            if filter.useAsOfDate {
              DatePicker("As of", selection: $filter.asOfDate, displayedComponents: .date)
            }
          }
          ReportFilterBar(
            range: filter.mode == .historical ? $filter.range : nil,
            group: $group,
            scope: $filter.scope
          )
          Picker("Cards", selection: $featuredOnly) {
            Text("All cards").tag(false)
            Text("Featured").tag(true)
          }
          .pickerStyle(.segmented)
          Button("Display preferences · \(orderedCards.filter { preferences.hiddenCardIDs.contains($0.id) }.count) hidden") {
            showingDisplayPreferences = true
          }
          Text("Display preferences are device-local for this plan. Hidden cards still count in totals; configuration import/export is separate.")
            .font(.caption).foregroundStyle(.secondary)
        }

        if let report, reportPlanID == model.settings.planID {
          headlines(report)

          if let message = phase.errorMessage {
            Label(message, systemImage: "wifi.exclamationmark")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }

          if report.cards.isEmpty {
            emptyState
          } else {
            Button("Add card") {
              editorDestination = .create
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .accessibilityLabel("Add card")
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
      ToolbarItem(placement: .topBarTrailing) {
        Button("Import / export") { showingImport = true }
      }
    }
    .sheet(isPresented: $showingImport) {
      NavigationStack {
        RewardsImportView()
      }
      .blocksCapturePresentation()
    }
    .sheet(item: $editorDestination) { destination in
      RewardCardEditorView(cardID: destination.cardID)
        .blocksCapturePresentation()
    }
    .sheet(isPresented: $showingDisplayPreferences) {
      displayPreferences
        .blocksCapturePresentation()
    }
    .task(id: fetchKey) {
      await fetch()
    }
    .onChange(of: model.settings.planID) {
      milesValuationText = nil
      valuationError = nil
    }
    .refreshable {
      await fetch()
    }
  }

  private var fetchKey: String {
    "\(model.settings.planID)|\(model.rewardsRefreshGeneration)|\(filter.key)|\(group.rawValue)"
  }

  private var visibleCards: [RewardsCardRow] {
    orderedCards.filter { (!featuredOnly || $0.card.featured) && !preferences.hiddenCardIDs.contains($0.id) }
  }

  private var preferences: RewardsBoardPreferences {
    preferencesByPlan[model.settings.planID] ?? .load(planID: model.settings.planID)
  }

  private func updatePreferences(_ change: (inout RewardsBoardPreferences) -> Void) {
    let planID = model.settings.planID
    var next = preferences
    change(&next)
    preferencesByPlan[planID] = next
    next.save(planID: planID)
  }

  private var orderedCards: [RewardsCardRow] {
    let cards = reportPlanID == model.settings.planID ? (report?.cards ?? []) : []
    let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return preferences.orderedIDs(cards.map(\.id)).compactMap { byID[$0] }
  }

  private func expanded(_ key: String) -> Binding<Bool> {
    Binding(
      get: { !preferences.collapsedGroups.contains(key) },
      set: { value in
        updatePreferences {
          if value { $0.collapsedGroups.remove(key) } else { $0.collapsedGroups.insert(key) }
        }
      }
    )
  }

  private var displayPreferences: some View {
    NavigationStack {
      List {
        Section {
          Text("Device-local for this plan. Drag to reorder within each reward type. Show or hide cards here, including cards excluded by Featured. These choices do not change rewards or configuration exports.")
            .font(.footnote).foregroundStyle(.secondary)
          Button("Show all cards") { updatePreferences { $0.hiddenCardIDs = [] } }
          Button("Reset display preferences") { updatePreferences { $0 = RewardsBoardPreferences() } }
        }
        displaySection("Cashback", kind: .cashback)
        displaySection("Miles", kind: .miles)
      }
      .environment(\.editMode, .constant(.active))
      .navigationTitle("Display preferences")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { showingDisplayPreferences = false }
        }
      }
    }
  }

  private func displaySection(_ title: String, kind: RewardKind) -> some View {
    let cards = orderedCards.filter { $0.card.type == kind }
    return Section(title) {
      Toggle("Expand \(title)", isOn: expanded(kind.rawValue))
      ForEach(cards) { row in
        Toggle(row.card.name, isOn: Binding(
          get: { !preferences.hiddenCardIDs.contains(row.id) },
          set: { visible in
            updatePreferences {
              if visible { $0.hiddenCardIDs.remove(row.id) } else { $0.hiddenCardIDs.insert(row.id) }
            }
          }
        ))
        .accessibilityLabel("Show \(row.card.name)")
      }
      .onMove { offsets, destination in
        var ids = cards.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        updatePreferences { $0.reorder(ids) }
      }
    }
  }

  private var cashback: [RewardsCardRow] {
    visibleCards.filter { $0.card.type == .cashback }
  }

  private var miles: [RewardsCardRow] {
    visibleCards.filter { $0.card.type == .miles }
  }

  @ViewBuilder
  private func headlines(_ report: RewardsReport) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let asOf = report.asOf {
        Text("As of \(asOf)").font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        TextField("Miles valuation", text: Binding(
          get: { milesValuationText ?? String(report.milesValuation) },
          set: { milesValuationText = $0 }
        ))
        .keyboardType(.decimalPad)
        .accessibilityLabel("Miles valuation")
        Button(savingValuation ? "Saving…" : "Save valuation") {
          Task { await saveValuation() }
        }
        .disabled(savingValuation || milesValuationText == nil)
      }
      Text("Currency units per mile. Zero keeps miles but assigns no cash value.")
        .font(.caption).foregroundStyle(.secondary)
      if let valuationError {
        Text(valuationError).font(.caption).foregroundStyle(Theme.outflow)
      }
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
      Text("Import from Connection settings → Rewards import, or choose Add card to score one of your HowMuch cards.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Button("Add card") {
        editorDestination = .create
      }
      .buttonStyle(.borderedProminent)
      .tint(Theme.accent)
      .accessibilityLabel("Add card")
      Button("Rewards import") {
        showingImport = true
      }
      .buttonStyle(.bordered)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .ynabCard()
  }

  @ViewBuilder
  private func board(_ report: RewardsReport) -> some View {
    if visibleCards.isEmpty {
      Text("No cards match these display choices. Choose All cards or show hidden cards in Display preferences.")
        .foregroundStyle(.secondary)
    }
    if !cashback.isEmpty {
      section(title: "Cashback", key: "cashback", rows: cashback)
    }
    if !miles.isEmpty {
      section(title: "Miles", key: "miles", rows: miles)
    }
  }

  private func section(title: String, key: String, rows: [RewardsCardRow]) -> some View {
    DisclosureGroup("\(title) · \(rows.count)", isExpanded: expanded(key)) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
        ForEach(rows) { row in
          Button {
            editorDestination = .edit(row.card.id)
          } label: {
            RewardTile(row: row, asOf: report?.asOf, currencyFormat: model.currencyFormat)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(row.card.name)
          .contextMenu {
            Button("Hide card on this device", systemImage: "eye.slash") {
              updatePreferences { $0.hiddenCardIDs.insert(row.id) }
            }
          }
        }
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

  private func saveValuation() async {
    guard !savingValuation else { return }
    guard let text = milesValuationText,
      let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
      value.isFinite, value >= 0 else {
      valuationError = "Miles valuation must be a nonnegative number."
      return
    }
    let planID = model.settings.planID
    savingValuation = true
    valuationError = nil
    defer { savingValuation = false }
    do {
      _ = try await model.apiClient.updateRewardSettings(planID: planID, milesValuation: value)
      guard planID == model.settings.planID else { return }
      milesValuationText = nil
      model.noteRewardsBoardChanged()
    } catch {
      guard planID == model.settings.planID else { return }
      valuationError = error.localizedDescription
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
        group: group
      )
      guard key == fetchKey, planID == model.settings.planID else {
        return
      }
      report = next
      reportPlanID = planID
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

private struct RewardTile: View {
  let row: RewardsCardRow
  let asOf: String?
  let currencyFormat: CurrencyFormat?

  var body: some View {
    let calc = row.calculation
    let fullPeriod = calc.periods?.last(where: { period in
      guard let asOf else { return false }
      return period.start <= asOf && period.end >= asOf
    })?.calculation
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

      if let periods = calc.periods, !periods.isEmpty {
        ForEach(Array(periods.enumerated()), id: \.offset) { _, period in
          Text("\(period.start) – \(period.end)").font(.caption).foregroundStyle(.secondary)
        }
      } else {
        Text(calc.period).font(.caption).foregroundStyle(.secondary)
      }
      if calc.maximumSpendExceeded || calc.shouldStopUsing == true {
        Label(calc.hasNextSpendingTier == true ? "Current cap reached · a higher tier is available" : "Cap reached · consider another card", systemImage: "exclamationmark.circle")
          .font(.caption).foregroundStyle(Theme.outflow)
      }
      if let status = calc.qualificationStatus {
        Text("Qualification: \(status.replacingOccurrences(of: "_", with: " "))")
          .font(.caption)
      }
      if let minimum = calc.monthlyMinimumSpend {
        labeled("Monthly minimum", MoneyCodec.displayString(forCurrencyUnits: minimum, currencyFormat: currencyFormat))
      }
      ForEach(Array((calc.monthlyQualifications ?? []).enumerated()), id: \.offset) { _, month in
        VStack(alignment: .leading, spacing: 2) {
          Text("\(month.start) – \(month.end) · \(month.status)")
          Text("\(MoneyCodec.displayString(forCurrencyUnits: month.spend, currencyFormat: currencyFormat)) / \(MoneyCodec.displayString(forCurrencyUnits: month.minimumSpend, currencyFormat: currencyFormat))")
            .monospacedDigit()
        }
        .font(.caption)
      }
      if let tierID = calc.activeSpendingTierId {
        if let tier = row.card.spendingTiers?.first(where: { $0.id == tierID }) {
          labeled("Active tier threshold", MoneyCodec.displayString(forCurrencyUnits: tier.spendThreshold, currencyFormat: currencyFormat))
          if let rate = tier.earningRate { Text("Tier rate: \(rate.formatted())").font(.caption) }
          if let maximum = tier.maximumSpend {
            labeled("Tier cap", MoneyCodec.displayString(forCurrencyUnits: maximum, currencyFormat: currencyFormat))
          }
        } else {
          Text("Active tier: \(tierID)").font(.caption)
        }
      }
      if calc.hasNextSpendingTier == true, let threshold = calc.nextSpendingTierThreshold {
        labeled("Next tier at", MoneyCodec.displayString(forCurrencyUnits: threshold, currencyFormat: currencyFormat))
      }

      if let minimum = calc.minimumSpend {
        let progress = min(1, max(0, (calc.minimumSpendProgress ?? 0) / 100))
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(fullPeriod != nil
              ? (calc.minimumSpendMet ? "Full-period minimum met" : "Full-period minimum")
              : (calc.minimumSpendMet ? "Minimum met" : "Minimum spend"))
            Spacer()
            Text("\(MoneyCodec.displayString(forCurrencyUnits: fullPeriod?.totalSpend ?? calc.totalSpend, currencyFormat: currencyFormat)) / \(MoneyCodec.displayString(forCurrencyUnits: minimum, currencyFormat: currencyFormat))")
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
            Text("\(rate.formatted())\(calc.rewardType == .cashback ? "%" : " miles/$")")
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
