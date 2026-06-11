import SwiftUI

/// YNAB's category list without the budget columns: per-month spending for
/// every category, grouped and collapsible, with drill-down to transactions.
struct CategoriesView: View {
  @Environment(AppModel.self) private var model
  @State private var monthAnchor = Date().startOfMonth()
  @State private var report: SpendingBreakdownReport?
  @State private var phase: LoadPhase = .idle
  @State private var collapsedGroups: Set<String> = []
  @State private var showsQuietGroups = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ScreenTitle("Categories")
        MonthStepper(monthAnchor: $monthAnchor)

        if model.categoryGroups.isEmpty, model.referencePhase != .loaded {
          PhasePlaceholder(phase: model.referencePhase) {
            await model.refreshReferenceData()
          }
        } else {
          HStack {
            Text("Total Spending")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
            Spacer()
            if phase.isLoading, report == nil {
              ProgressView()
            } else {
              Text(MoneyCodec.displayString(for: abs(report?.total ?? 0), currencyFormat: model.currencyFormat))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            }
          }
          .padding(16)
          .ynabCard()

          if let message = phase.errorMessage {
            Label(message, systemImage: "wifi.exclamationmark")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }

          ForEach(primaryGroups) { group in
            groupSection(group)
          }

          if !quietGroups.isEmpty {
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

            if showsQuietGroups {
              ForEach(quietGroups) { group in
                groupSection(group)
              }
            }
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
    .task(id: monthAnchor) {
      await fetch()
    }
    .refreshable {
      await model.refreshAll()
      await fetch()
    }
  }

  // MARK: Data

  private var monthRangeISO: (from: String, to: String) {
    (monthAnchor.startOfMonth().isoDateString, monthAnchor.endOfMonth().isoDateString)
  }

  private var spentByCategory: [String: Int] {
    guard let report else {
      return [:]
    }
    return Dictionary(report.groups.map { ($0.categoryID, abs($0.amount)) }, uniquingKeysWith: +)
  }

  private var liveGroups: [CategoryGroup] {
    model.categoryGroups.filter { group in
      !group.deleted && group.categories.contains { !$0.deleted }
    }
  }

  private var primaryGroups: [CategoryGroup] {
    liveGroups.filter { !$0.isQuiet }
  }

  private var quietGroups: [CategoryGroup] {
    liveGroups.filter(\.isQuiet)
  }

  private func fetch() async {
    phase = .loading
    do {
      let range = monthRangeISO
      report = try await model.apiClient.fetchSpendingBreakdown(
        planID: model.settings.planID, from: range.from, to: range.to
      )
      phase = .loaded
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  // MARK: Sections

  private func groupSection(_ group: CategoryGroup) -> some View {
    let spent = spentByCategory
    let categories = group.categories.filter { !$0.deleted }
    let groupTotal = categories.reduce(0) { $0 + (spent[$1.id] ?? 0) }
    let isCollapsed = collapsedGroups.contains(group.id)

    return VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(.snappy) {
          if isCollapsed {
            collapsedGroups.remove(group.id)
          } else {
            collapsedGroups.insert(group.id)
          }
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
          Text(MoneyCodec.displayString(for: groupTotal, currencyFormat: model.currencyFormat))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(groupTotal == 0 ? .secondary : Theme.textPrimary)
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if !isCollapsed {
        VStack(spacing: 0) {
          ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
            categoryRow(category, spent: spent[category.id] ?? 0)
            if index < categories.count - 1 {
              Divider().padding(.leading, 16)
            }
          }
        }
        .ynabCard()
      }
    }
  }

  private func categoryRow(_ category: Category, spent: Int) -> some View {
    NavigationLink {
      RegisterView(
        scope: .all,
        categoryID: category.id,
        dateRange: monthRangeISO.from ... monthRangeISO.to
      )
    } label: {
      HStack {
        Text(category.name)
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        Text(MoneyCodec.displayString(for: spent, currencyFormat: model.currencyFormat))
          .monospacedDigit()
          .foregroundStyle(spent == 0 ? .secondary : Theme.textPrimary)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
