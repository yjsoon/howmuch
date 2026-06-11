import SwiftUI

struct PayeePickerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: TransactionDraft
  @State private var searchText = ""

  var body: some View {
    List {
      if !trimmedSearch.isEmpty, !hasExactMatch {
        Button {
          draft.payeeID = nil
          draft.payeeName = trimmedSearch
          dismiss()
        } label: {
          Label("Create payee “\(trimmedSearch)”", systemImage: "plus.circle.fill")
            .foregroundStyle(Theme.accent)
        }
      }

      ForEach(filteredPayees) { payee in
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
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or add a payee")
    .navigationTitle("Payee")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filteredPayees: [Payee] {
    let query = trimmedSearch.lowercased()
    return model.payees
      .filter { !$0.isTransferPayee }
      .filter { query.isEmpty || $0.name.lowercased().contains(query) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private var hasExactMatch: Bool {
    model.payees.contains { $0.name.localizedCaseInsensitiveCompare(trimmedSearch) == .orderedSame }
  }

  private func select(_ payee: Payee) {
    draft.payeeID = payee.id
    draft.payeeName = payee.name
    if draft.categoryID == nil, let suggestion = model.suggestedCategoryID(forPayeeID: payee.id) {
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
    List {
      if trimmedSearch.isEmpty {
        Button {
          draft.categoryID = nil
          dismiss()
        } label: {
          HStack {
            Text("No Category")
              .foregroundStyle(.secondary)
            Spacer()
            if draft.categoryID == nil {
              Image(systemName: "checkmark")
                .foregroundStyle(Theme.accent)
            }
          }
        }
      }

      ForEach(visibleGroups) { group in
        Section(group.name) {
          ForEach(group.categories.filter(categoryMatches)) { category in
            Button {
              draft.categoryID = category.id
              dismiss()
            } label: {
              HStack {
                Text(category.name)
                  .foregroundStyle(Theme.textPrimary)
                Spacer()
                if category.id == draft.categoryID {
                  Image(systemName: "checkmark")
                    .foregroundStyle(Theme.accent)
                }
              }
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search categories")
    .navigationTitle("Category")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func categoryMatches(_ category: Category) -> Bool {
    let query = trimmedSearch.lowercased()
    return query.isEmpty || category.name.lowercased().contains(query)
  }

  /// Everyday groups first, bookkeeping groups demoted to the bottom.
  private var visibleGroups: [CategoryGroup] {
    let live = model.categoryGroups.filter { group in
      !group.deleted && group.categories.contains { !$0.deleted && categoryMatches($0) }
    }
    let primary = live.filter { !$0.isQuiet }
    let quiet = live.filter(\.isQuiet)
    return primary + quiet
  }
}

struct AccountPickerView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: TransactionDraft

  var body: some View {
    List {
      accountSection("Budget", accounts: model.openAccounts.filter(\.onBudget))
      accountSection("Tracking", accounts: model.openAccounts.filter { !$0.onBudget })
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Theme.canvas)
    .navigationTitle("Account")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder
  private func accountSection(_ title: String, accounts: [Account]) -> some View {
    if !accounts.isEmpty {
      Section(title) {
        ForEach(accounts) { account in
          Button {
            draft.accountID = account.id
            dismiss()
          } label: {
            HStack {
              Text(account.name)
                .foregroundStyle(Theme.textPrimary)
              Spacer()
              if account.id == draft.accountID {
                Image(systemName: "checkmark")
                  .foregroundStyle(Theme.accent)
              }
            }
          }
        }
      }
    }
  }
}
