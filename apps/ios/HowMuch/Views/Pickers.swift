import SwiftUI

struct PayeePickerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: TransactionDraft
  @State private var searchText = ""
  /// Arriving with search already presented focuses the field declaratively —
  /// typing is the primary gesture here, and an imperative focus request
  /// would race the navigation push.
  @State private var isSearchPresented = true

  var body: some View {
    let recents = recentPayees
    List {
      if !trimmedSearch.isEmpty, !hasExactMatch {
        Button {
          draft.payeeID = nil
          draft.payeeName = trimmedSearch
          draft.transferAccountID = nil
          dismiss()
        } label: {
          Label("Create payee “\(trimmedSearch)”", systemImage: "plus.circle.fill")
            .foregroundStyle(Theme.accent)
        }
      }

      if !recents.isEmpty {
        Section("Recent") {
          ForEach(recents) { payee in
            payeeRow(payee)
          }
        }
      }

      if !filteredPayees.isEmpty {
        Section("Payees") {
          ForEach(filteredPayees) { payee in
            payeeRow(payee)
          }
        }
      }

      if !filteredTransferPayees.isEmpty {
        Section("Transfers") {
          ForEach(filteredTransferPayees) { payee in
            payeeRow(payee)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .searchable(
      text: $searchText,
      isPresented: $isSearchPresented,
      placement: .navigationBarDrawer(displayMode: .always),
      prompt: "Search or add a payee"
    )
    .navigationTitle("Payee")
    .navigationBarTitleDisplayMode(.inline)
  }

  /// The payees most recently used in the ledger — most expenses repeat, so
  /// the last few merchants outrank the alphabet. Hidden while searching.
  private var recentPayees: [Payee] {
    guard trimmedSearch.isEmpty else {
      return []
    }
    let payeesByID = Dictionary(model.payees.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<String>()
    var recents: [Payee] = []
    for transaction in model.transactions {
      guard
        let payeeID = transaction.payeeID,
        seen.insert(payeeID).inserted,
        let payee = payeesByID[payeeID],
        !payee.isTransferPayee
      else {
        continue
      }
      recents.append(payee)
      if recents.count == 6 {
        break
      }
    }
    return recents
  }

  private func payeeRow(_ payee: Payee) -> some View {
    Button {
      select(payee)
    } label: {
      HStack {
        Text(payee.name)
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        if payee.id == draft.payeeID {
          Image(systemName: "checkmark")
            .foregroundStyle(Theme.accent)
        }
      }
    }
  }

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filteredPayees: [Payee] {
    model.payees
      .filter { !$0.isTransferPayee }
      .filter { trimmedSearch.isEmpty || $0.name.localizedStandardContains(trimmedSearch) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Other accounts' transfer payees; picking one records a transfer and the
  /// API creates the mirrored side (YNAB behaviour). A split parent cannot
  /// itself be a transfer, so splits get no Transfers section.
  private var filteredTransferPayees: [Payee] {
    guard !draft.isSplit else {
      return []
    }
    return model.payees
      .filter { payee in
        guard let targetAccountID = payee.transferAccountId, targetAccountID != draft.accountID else {
          return false
        }
        guard let account = model.account(withID: targetAccountID) else {
          return false
        }
        return !account.closed
      }
      .filter { trimmedSearch.isEmpty || $0.name.localizedStandardContains(trimmedSearch) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private var hasExactMatch: Bool {
    model.payees.contains { $0.name.localizedCaseInsensitiveCompare(trimmedSearch) == .orderedSame }
  }

  private func select(_ payee: Payee) {
    draft.payeeID = payee.id
    draft.payeeName = payee.name
    draft.transferAccountID = payee.transferAccountId
    if payee.isTransferPayee {
      // Transfers between two budget accounts carry no category.
      if model.accountsBothOnBudget(draft.accountID, payee.transferAccountId) {
        draft.categoryID = nil
      }
    } else if draft.categoryID == nil, let suggestion = model.suggestedCategoryID(forPayeeID: payee.id) {
      draft.categoryID = suggestion
    }
    dismiss()
  }
}

struct CategoryPickerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: TransactionDraft
  @State private var searchText = ""

  var body: some View {
    CategorisedPickerList(
      groups: visibleGroups,
      groupTitle: { $0.name },
      items: { $0.categories.filter(categoryMatches) },
      itemTitle: { $0.name },
      isSelected: { $0.id == draft.categoryID },
      searchText: $searchText,
      searchPrompt: "Search categories",
      title: "Category"
    ) { category in
      draft.categoryID = category.id
      dismiss()
    } header: {
      if trimmedSearch.isEmpty {
        Button {
          draft.categoryID = nil
          dismiss()
        } label: {
          PickerCheckRow(title: "No Category", isSelected: draft.categoryID == nil, isSecondary: true)
        }
      }
    }
  }

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func categoryMatches(_ category: Category) -> Bool {
    !category.deleted && (trimmedSearch.isEmpty || category.name.localizedStandardContains(trimmedSearch))
  }

  /// Everyday groups first, bookkeeping groups demoted to the bottom.
  private var visibleGroups: [CategoryGroup] {
    let live = model.categoryGroups.filter { group in
      !group.deleted && group.categories.contains(where: categoryMatches)
    }
    return live.filter { !$0.isQuiet } + live.filter(\.isQuiet)
  }
}

struct AccountPickerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let selectedAccountID: String
  var disabledAccountIDs: Set<String> = []
  let onSelect: (Account) -> Void
  @State private var searchText = ""

  var body: some View {
    CategorisedPickerList(
      groups: visibleGroups,
      groupTitle: { $0.title },
      items: { $0.accounts },
      itemTitle: { $0.name },
      isSelected: { $0.id == selectedAccountID },
      isEnabled: { !disabledAccountIDs.contains($0.id) },
      searchText: $searchText,
      searchPrompt: "Search accounts",
      title: "Account",
      onSelect: { account in
        onSelect(account)
        dismiss()
      }
    )
    .task(id: accountUsageTaskID) {
      guard usesMostUsedSort, model.accountUsagePhase != .loaded else {
        return
      }
      await model.refreshAccountUsageLast30Days()
    }
  }

  private var pickerGroups: [AccountListGroup] {
    model.accountListGroups(includeClosed: false, includeEmptyCustomGroups: false)
  }

  private var visibleGroups: [AccountListGroup] {
    pickerGroups.compactMap { $0.matching(searchText) }
  }

  private var usesMostUsedSort: Bool {
    pickerGroups.contains { model.sortForAccountGroup($0.id) == .mostUsedLast30Days }
  }

  private var accountUsageTaskID: String {
    "\(usesMostUsedSort)-\(model.accountUsageGeneration)"
  }
}

/// Checkmark row shared by the searchable grouped pickers.
struct PickerCheckRow: View {
  let title: String
  var isSelected: Bool
  var isSecondary: Bool = false

  var body: some View {
    HStack {
      Text(title)
        .foregroundStyle(isSecondary ? Color.secondary : Theme.textPrimary)
      Spacer()
      if isSelected {
        Image(systemName: "checkmark")
          .foregroundStyle(Theme.accent)
      }
    }
  }
}

/// Sectioned searchable list used by category and account pickers.
struct CategorisedPickerList<Group: Identifiable, Item: Identifiable, Header: View>: View {
  let groups: [Group]
  let groupTitle: (Group) -> String
  let items: (Group) -> [Item]
  let itemTitle: (Item) -> String
  let isSelected: (Item) -> Bool
  var isEnabled: (Item) -> Bool = { _ in true }
  @Binding var searchText: String
  var searchPrompt: String
  var title: String
  let onSelect: (Item) -> Void
  let header: () -> Header

  init(
    groups: [Group],
    groupTitle: @escaping (Group) -> String,
    items: @escaping (Group) -> [Item],
    itemTitle: @escaping (Item) -> String,
    isSelected: @escaping (Item) -> Bool,
    isEnabled: @escaping (Item) -> Bool = { _ in true },
    searchText: Binding<String>,
    searchPrompt: String,
    title: String,
    onSelect: @escaping (Item) -> Void,
    @ViewBuilder header: @escaping () -> Header
  ) {
    self.groups = groups
    self.groupTitle = groupTitle
    self.items = items
    self.itemTitle = itemTitle
    self.isSelected = isSelected
    self.isEnabled = isEnabled
    self._searchText = searchText
    self.searchPrompt = searchPrompt
    self.title = title
    self.onSelect = onSelect
    self.header = header
  }

  var body: some View {
    List {
      header()
      ForEach(groups) { group in
        Section(groupTitle(group)) {
          ForEach(items(group)) { item in
            let enabled = isEnabled(item)
            Button {
              onSelect(item)
            } label: {
              PickerCheckRow(title: itemTitle(item), isSelected: isSelected(item), isSecondary: !enabled)
            }
            .disabled(!enabled)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

extension CategorisedPickerList where Header == EmptyView {
  init(
    groups: [Group],
    groupTitle: @escaping (Group) -> String,
    items: @escaping (Group) -> [Item],
    itemTitle: @escaping (Item) -> String,
    isSelected: @escaping (Item) -> Bool,
    isEnabled: @escaping (Item) -> Bool = { _ in true },
    searchText: Binding<String>,
    searchPrompt: String,
    title: String,
    onSelect: @escaping (Item) -> Void
  ) {
    self.init(
      groups: groups,
      groupTitle: groupTitle,
      items: items,
      itemTitle: itemTitle,
      isSelected: isSelected,
      isEnabled: isEnabled,
      searchText: searchText,
      searchPrompt: searchPrompt,
      title: title,
      onSelect: onSelect,
      header: { EmptyView() }
    )
  }
}
