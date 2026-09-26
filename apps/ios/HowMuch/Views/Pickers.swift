import SwiftUI

struct PayeePickerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: TransactionDraft
  @State private var searchText = ""
  /// Typing is the primary gesture here, so the field takes focus on arrival.
  /// It is an ordinary inline field, not system search: `.searchable` with
  /// `isPresented` presents a UISearchController as the picker arrives, and a
  /// payee tapped while that presentation is in flight either did nothing or
  /// popped the picker and left its search stranded over the form.
  @FocusState private var isSearchFocused: Bool

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
    .safeAreaInset(edge: .top, spacing: 0) {
      PickerSearchField(prompt: "Search or add a payee", text: $searchText, isFocused: $isSearchFocused)
    }
    .navigationTitle("Payee")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      isSearchFocused = true
    }
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
      title: "Category",
      presentsSearchOnAppear: true
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

/// Inline search field pinned above a picker list: magnifying glass, rounded
/// field and a clear button, as the HIG describes for a search field. Unlike
/// `.searchable`, focusing it presents nothing, so a row tapped while the
/// picker is still arriving cannot race a search presentation.
struct PickerSearchField: View {
  let prompt: String
  @Binding var text: String
  var isFocused: FocusState<Bool>.Binding

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(prompt, text: $text)
        .focused(isFocused)
        .submitLabel(.search)
        .foregroundStyle(Theme.textPrimary)
        .accessibilityAddTraits(.isSearchField)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear text")
      }
    }
    .padding(.leading, 14)
    .padding(.trailing, text.isEmpty ? 14 : 0)
    .frame(minHeight: 44)
    .background(Theme.surfaceMuted, in: Capsule())
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(Theme.canvas)
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
  let presentsSearchOnAppear: Bool
  @FocusState private var isSearchFocused: Bool

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
    presentsSearchOnAppear: Bool = false,
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
    self.presentsSearchOnAppear = presentsSearchOnAppear
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
    .safeAreaInset(edge: .top, spacing: 0) {
      PickerSearchField(prompt: searchPrompt, text: $searchText, isFocused: $isSearchFocused)
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      // Inline focus, not a presented search controller; see PayeePickerView.
      if presentsSearchOnAppear {
        isSearchFocused = true
      }
    }
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
    presentsSearchOnAppear: Bool = false,
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
      presentsSearchOnAppear: presentsSearchOnAppear,
      onSelect: onSelect,
      header: { EmptyView() }
    )
  }
}
