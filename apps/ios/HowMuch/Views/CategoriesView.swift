import SwiftUI

/// YNAB-style monthly envelope view. HowMuch-owned assignments and targets
/// are editable while selecting a category still opens its register.
struct CategoriesView: View {
  @Environment(AppModel.self) private var model
  @State private var monthAnchor = Date.now.startOfMonth()
  @State private var planMonth: PlanMonth?
  @State private var phase: LoadPhase = .idle
  @State private var collapsedGroups: Set<String> = []
  @State private var showsQuietGroups = false
  @State private var editingCategory: PlanMonthCategory?
  @State private var editingTarget: PlanMonthCategory?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        MonthStepper(monthAnchor: $monthAnchor)

        if let planMonth {
          summary(for: planMonth)

          if let message = phase.errorMessage {
            Label(message, systemImage: "wifi.exclamationmark")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }

          ForEach(primaryGroups) { group in
            groupSection(group)
          }

          if !quietGroups.isEmpty {
            quietGroupsToggle
            if showsQuietGroups {
              ForEach(quietGroups) { group in
                groupSection(group)
              }
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
    .navigationTitle("Plan")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        DestinationsMenu(omitting: .plan)
      }
    }
    .task(id: PlanRefreshKey(month: monthAnchor, generation: model.planRefreshGeneration)) {
      await fetch()
    }
    .refreshable {
      await model.refreshReferenceData()
      await fetch()
    }
    .sheet(item: $editingCategory) { category in
      PlanAssignmentSheet(category: category, currencyFormat: model.currencyFormat) { budgeted in
        planMonth = try await model.apiClient.setPlanMonthCategoryAssignment(
          planID: model.settings.planID,
          month: monthKey,
          categoryID: category.id,
          budgeted: budgeted
        )
      }
      .blocksCapturePresentation()
    }
    .sheet(item: $editingTarget) { category in
      PlanTargetSheet(category: category, currencyFormat: model.currencyFormat) { target in
        planMonth = try await model.apiClient.setPlanMonthCategoryTarget(
          planID: model.settings.planID,
          month: monthKey,
          categoryID: category.id,
          target: target
        )
      } restore: {
        planMonth = try await model.apiClient.restorePlanMonthCategoryTarget(
          planID: model.settings.planID,
          month: monthKey,
          categoryID: category.id
        )
      }
      .blocksCapturePresentation()
    }
  }

  private struct PlanRefreshKey: Hashable {
    let month: Date
    let generation: Int
  }

  private func summary(for month: PlanMonth) -> some View {
    HStack(alignment: .top, spacing: 12) {
      summaryValue("Ready to assign", amount: month.toBeBudgeted ?? 0, colour: Theme.amountColour(month.toBeBudgeted ?? 0))
      Divider().frame(height: 42)
      summaryValue("Assigned", amount: month.budgeted ?? 0, colour: Theme.textPrimary)
      Divider().frame(height: 42)
      summaryValue("Activity", amount: month.activity ?? 0, colour: Theme.amountColour(month.activity ?? 0))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .ynabCard()
    .accessibilityElement(children: .combine)
  }

  private func summaryValue(_ title: String, amount: Int, colour: Color) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
      Text(MoneyCodec.displayString(for: amount, currencyFormat: model.currencyFormat))
        .font(.footnote.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(colour)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var quietGroupsToggle: some View {
    Button {
      withAnimation(.snappy) {
        showsQuietGroups.toggle()
      }
    } label: {
      HStack {
        Text(showsQuietGroups ? "Hide bookkeeping categories" : "Show bookkeeping categories")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
        Image(systemName: "chevron.down")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(showsQuietGroups ? 180 : 0))
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .ynabCard()
    }
    .buttonStyle(.plain)
  }

  // MARK: Data

  private var monthKey: String {
    let components = Calendar.current.dateComponents([.year, .month], from: monthAnchor)
    return String(format: "%04d-%02d", components.year ?? 1970, components.month ?? 1)
  }

  private var monthRangeISO: (from: String, to: String) {
    (monthAnchor.startOfMonth().isoDateString, monthAnchor.endOfMonth().isoDateString)
  }

  private var groups: [PlanCategoryGroup] {
    guard let planMonth else { return [] }
    let grouped = Dictionary(grouping: planMonth.categories.filter { $0.deleted != true }, by: \.categoryGroupID)
    let references = Dictionary(uniqueKeysWithValues: model.categoryGroups.map { ($0.id, $0) })
    var remaining = grouped
    var result: [PlanCategoryGroup] = []

    for reference in model.categoryGroups where !reference.deleted {
      guard let categories = remaining.removeValue(forKey: reference.id), !categories.isEmpty else { continue }
      result.append(PlanCategoryGroup(
        id: reference.id,
        name: reference.name,
        isQuiet: reference.isQuiet,
        categories: categories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      ))
    }

    for (id, categories) in remaining.sorted(by: { $0.key < $1.key }) {
      let name = references[id]?.name ?? "Uncategorised group"
      result.append(PlanCategoryGroup(
        id: id,
        name: name,
        isQuiet: references[id]?.isQuiet ?? CategoryGroup.isQuietName(name),
        categories: categories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      ))
    }
    return result
  }

  private var primaryGroups: [PlanCategoryGroup] { groups.filter { !$0.isQuiet } }
  private var quietGroups: [PlanCategoryGroup] { groups.filter(\.isQuiet) }

  private func fetch() async {
    let month = monthKey
    let generation = model.planRefreshGeneration
    phase = .loading
    do {
      let snapshot = try await model.apiClient.fetchPlanMonth(planID: model.settings.planID, month: month)
      guard month == monthKey, generation == model.planRefreshGeneration else {
        return
      }
      planMonth = snapshot
      phase = .loaded
    } catch {
      if error is CancellationError || (error as? URLError)?.code == .cancelled {
        return
      }
      guard month == monthKey, generation == model.planRefreshGeneration else {
        return
      }
      phase = .failed(error.localizedDescription)
    }
  }

  // MARK: Sections

  private func groupSection(_ group: PlanCategoryGroup) -> some View {
    let isCollapsed = collapsedGroups.contains(group.id)
    let available = group.categories.reduce(0) { $0 + ($1.balance ?? 0) }

    return VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(.snappy) {
          if isCollapsed { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
        }
      } label: {
        HStack {
          Image(systemName: "chevron.down")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
          Text(group.name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
          Spacer()
          Text(MoneyCodec.displayString(for: available, currencyFormat: model.currencyFormat))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.amountColour(available))
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if !isCollapsed {
        VStack(spacing: 0) {
          ForEach(group.categories) { category in
            categoryRow(category)
            if category.id != group.categories.last?.id {
              Divider().padding(.leading, 16)
            }
          }
        }
        .ynabCard()
      }
    }
  }

  private func categoryRow(_ category: PlanMonthCategory) -> some View {
    HStack(alignment: .top, spacing: 8) {
      NavigationLink {
        RegisterView(scope: .all, categoryID: category.id, dateRange: monthRangeISO.from ... monthRangeISO.to)
      } label: {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 8) {
          Text(category.name)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
          Spacer()
          if let target = targetLabel(for: category) {
            Text(target)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        HStack(spacing: 8) {
          amountColumn("Assigned", category.budgeted ?? 0, colour: Theme.textPrimary)
          amountColumn("Activity", category.activity ?? 0, colour: Theme.amountColour(category.activity ?? 0))
          amountColumn("Available", category.balance ?? 0, colour: Theme.amountColour(category.balance ?? 0))
        }

        if let progress = category.targetProgress {
          ProgressView(value: progress)
            .tint(progress >= 1 ? Theme.inflow : Theme.accent)
            .accessibilityLabel("Target progress")
            .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        }
      }
      .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button {
        editingCategory = category
      } label: {
        Label("Edit assigned amount", systemImage: "pencil")
          .labelStyle(.iconOnly)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Theme.accent)
          .padding(7)
          .background(Theme.surfaceMuted, in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Edit assigned amount for \(category.name)")

      Button {
        editingTarget = category
      } label: {
        Label("Edit target", systemImage: "target")
          .labelStyle(.iconOnly)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Theme.accent)
          .padding(7)
          .background(Theme.surfaceMuted, in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Edit target for \(category.name)")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
  }

  private func amountColumn(_ label: String, _ amount: Int, colour: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(MoneyCodec.displayString(for: amount, currencyFormat: model.currencyFormat))
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(colour)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func targetLabel(for category: PlanMonthCategory) -> String? {
    guard category.hasTarget else { return nil }
    if let progress = category.targetProgress {
      return progress >= 1 ? "Target met" : "Target \(Int((progress * 100).rounded()))%"
    }
    return "Target set"
  }
}

private struct PlanTargetSheet: View {
  @Environment(\.dismiss) private var dismiss
  let category: PlanMonthCategory
  let currencyFormat: CurrencyFormat?
  let save: (PlanTargetPayload?) async throws -> Void
  let restore: () async throws -> Void
  @State private var type: String
  @State private var amountText: String
  @State private var monthText: String
  @State private var isSaving = false
  @State private var errorMessage: String?

  init(
    category: PlanMonthCategory,
    currencyFormat: CurrencyFormat?,
    save: @escaping (PlanTargetPayload?) async throws -> Void,
    restore: @escaping () async throws -> Void
  ) {
    self.category = category
    self.currencyFormat = currencyFormat
    self.save = save
    self.restore = restore
    _type = State(initialValue: category.goalType ?? "TB")
    _amountText = State(initialValue: Self.editableAmount(category.goalTarget ?? 0))
    _monthText = State(initialValue: category.goalTargetMonth?.prefix(7).description ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section(category.name) {
          Picker("Target type", selection: $type) {
            Text("Savings balance").tag("TB")
            Text("By date").tag("TBD")
            Text("Monthly spending").tag("MF")
            Text("Needed for spending").tag("NEED")
            Text("Debt payoff").tag("DEBT")
          }
          TextField("Target amount", text: $amountText)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
          TextField("Target month (optional)", text: $monthText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        Section {
          Button("Clear target", role: .destructive) { Task { await clear() } }
            .disabled(isSaving)
          if category.targetSource != nil {
            Button("Restore original target") { Task { await restoreSource() } }
              .disabled(isSaving)
          }
        }
        if let errorMessage {
          Section { Text(errorMessage).font(.footnote).foregroundStyle(Theme.outflow) }
        }
      }
      .navigationTitle("Edit target")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(isSaving ? "Saving" : "Save") { Task { await submit() } }.disabled(isSaving)
        }
      }
    }
  }

  private func submit() async {
    guard let amount = Self.milliunits(from: amountText), amount > 0 else {
      errorMessage = "Enter a target amount greater than zero with no more than three decimal places."
      return
    }
    let trimmedMonth = monthText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedMonth.isEmpty || trimmedMonth.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil else {
      errorMessage = "Use a month like 2026-08."
      return
    }
    isSaving = true; errorMessage = nil
    do {
      try await save(PlanTargetPayload(goalType: type, goalTarget: amount, goalTargetMonth: trimmedMonth.isEmpty ? nil : trimmedMonth))
      dismiss()
    } catch { errorMessage = error.localizedDescription }
    isSaving = false
  }

  private func clear() async {
    isSaving = true; errorMessage = nil
    do { try await save(nil); dismiss() } catch { errorMessage = error.localizedDescription }
    isSaving = false
  }

  private func restoreSource() async {
    isSaving = true; errorMessage = nil
    do { try await restore(); dismiss() } catch { errorMessage = error.localizedDescription }
    isSaving = false
  }

  private static func editableAmount(_ milliunits: Int) -> String {
    let absolute = milliunits.magnitude
    let whole = absolute / 1_000
    var fraction = String(absolute % 1_000 + 1_000).dropFirst()
    while fraction.last == "0" { fraction.removeLast() }
    return fraction.isEmpty ? "\(whole)" : "\(whole).\(fraction)"
  }

  private static func milliunits(from text: String) -> Int? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count <= 2, let whole = Int(parts[0]), whole >= 0 else { return nil }
    let fractional = parts.count == 2 ? String(parts[1]) : ""
    guard fractional.count <= 3, fractional.allSatisfy(\.isNumber), let fraction = Int(fractional.padding(toLength: 3, withPad: "0", startingAt: 0)) else { return nil }
    let result = whole.multipliedReportingOverflow(by: 1_000)
    guard !result.overflow else { return nil }
    let total = result.partialValue.addingReportingOverflow(fraction)
    return total.overflow ? nil : total.partialValue
  }
}

private struct PlanCategoryGroup: Identifiable {
  let id: String
  let name: String
  let isQuiet: Bool
  let categories: [PlanMonthCategory]
}

private struct PlanAssignmentSheet: View {
  @Environment(\.dismiss) private var dismiss
  let category: PlanMonthCategory
  let currencyFormat: CurrencyFormat?
  let save: (Int) async throws -> Void
  @State private var amountText: String
  @State private var isSaving = false
  @State private var errorMessage: String?

  init(category: PlanMonthCategory, currencyFormat: CurrencyFormat?, save: @escaping (Int) async throws -> Void) {
    self.category = category
    self.currencyFormat = currencyFormat
    self.save = save
    _amountText = State(initialValue: Self.editableAmount(category.budgeted ?? 0))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section(category.name) {
          TextField("Assigned", text: $amountText)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
          Text("Enter the amount to assign for this month.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if let errorMessage {
          Section {
            Text(errorMessage)
              .font(.footnote)
              .foregroundStyle(Theme.outflow)
          }
        }
      }
      .navigationTitle("Assign money")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isSaving ? "Saving" : "Save") {
            Task { await submit() }
          }
          .disabled(isSaving)
        }
      }
    }
  }

  private func submit() async {
    guard let amount = Self.milliunits(from: amountText) else {
      errorMessage = "Use a whole number or up to three decimal places."
      return
    }
    isSaving = true
    errorMessage = nil
    do {
      try await save(amount)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
    isSaving = false
  }

  private static func editableAmount(_ milliunits: Int) -> String {
    let absolute = milliunits.magnitude
    let whole = absolute / 1_000
    var fraction = String(absolute % 1_000 + 1_000).dropFirst()
    while fraction.last == "0" {
      fraction.removeLast()
    }
    let sign = milliunits < 0 ? "-" : ""
    return fraction.isEmpty ? "\(sign)\(whole)" : "\(sign)\(whole).\(fraction)"
  }

  private static func milliunits(from text: String) -> Int? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = "^(-?)([0-9]+)(?:\\.([0-9]{1,3}))?$"
    guard let match = value.range(of: pattern, options: .regularExpression) else { return nil }
    let parts = String(value[match]).split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let wholeText = String(parts[0])
    let negative = wholeText.hasPrefix("-")
    guard let whole = Int(negative ? String(wholeText.dropFirst()) : wholeText) else { return nil }
    let fractionText = parts.count == 2 ? String(parts[1]) : ""
    guard let fraction = Int(fractionText.padding(toLength: 3, withPad: "0", startingAt: 0)) else { return nil }
    let amount = whole.multipliedReportingOverflow(by: 1_000)
    guard !amount.overflow else { return nil }
    let total = amount.partialValue.addingReportingOverflow(fraction)
    guard !total.overflow else { return nil }
    return negative ? -total.partialValue : total.partialValue
  }
}
