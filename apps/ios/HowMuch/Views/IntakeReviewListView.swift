import SwiftUI

struct IntakeReviewItem: Identifiable, Equatable {
  var id: String
  var draft: TransactionDraft
  var included: Bool

  init(draft: TransactionDraft) {
    let identity = draft.importID ?? UUID().uuidString.lowercased()
    var draft = draft
    draft.importID = identity
    id = identity
    self.draft = draft
    included = true
  }
}

struct IntakeReviewListView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var items: [IntakeReviewItem]
  @State private var repairText = ""
  @State private var addToAccountID: String
  @State private var editingItem: IntakeReviewItem?
  @State private var errorMessage: String?
  @FocusState private var isRepairFocused: Bool

  init(drafts: [TransactionDraft], preferredAccountID: String?) {
    let rows = drafts.map(IntakeReviewItem.init)
    _items = State(initialValue: rows)
    let unique = Set(rows.map(\.draft.accountID).filter { !$0.isEmpty })
    if unique.count == 1, let only = unique.first {
      _addToAccountID = State(initialValue: only)
    } else {
      _addToAccountID = State(
        initialValue: preferredAccountID
          ?? rows.first(where: { !$0.draft.accountID.isEmpty })?.draft.accountID
          ?? ""
      )
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollView {
          VStack(spacing: 14) {
            sourceStrip
            rowsCard
            repairField
            if showsAccountPicker {
              accountPickerCard
            }
            if let errorMessage {
              Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(Theme.outflow)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)
      }
      .background(Theme.canvas)
      .navigationTitle("\(items.count) Transactions")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .tint(Theme.accent)
        }
      }
      .safeAreaInset(edge: .bottom, alignment: .trailing) {
        addButton
          .padding(20)
      }
      .sheet(item: $editingItem) { item in
        TransactionFormView(
          draft: IntakeReviewPreparation.draft(item, addToAccountID: addToAccountID),
          isEditing: false,
          allowsDeletion: false,
          isReviewing: true,
          onPersist: { updated in
            upsert(updated, id: item.id)
          }
        )
      }
    }
  }

  private var includedItems: [IntakeReviewItem] {
    items.filter(\.included)
  }

  private var showsAccountPicker: Bool {
    includedItems.contains { $0.draft.accountID.isEmpty }
  }

  private var addAccountName: String {
    model.account(withID: addToAccountID)?.name
      ?? model.openAccounts.first(where: { $0.id == addToAccountID })?.name
      ?? "Account"
  }

  private var canAdd: Bool {
    !includedItems.isEmpty && includedItems.allSatisfy {
      IntakeReviewPreparation.draft($0, addToAccountID: addToAccountID).canSave
    }
  }

  private var sourceStrip: some View {
    HStack(spacing: 10) {
      Image(systemName: "text.alignleft")
        .foregroundStyle(.secondary)
      Text("Typed · just now")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .ynabCard()
  }

  private var rowsCard: some View {
    LazyVStack(spacing: 0) {
      ForEach(items) { item in
        VStack(spacing: 0) {
          if item.id != items.first?.id {
            CardDivider()
          }
          row(item)
        }
      }
    }
    .ynabCard()
  }

  private func row(_ item: IntakeReviewItem) -> some View {
    HStack(alignment: .center, spacing: 4) {
      Button {
        toggle(item.id)
      } label: {
        Image(systemName: item.included ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(item.included ? Theme.accent : Color.secondary)
          .frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(item.included ? "Include this transaction" : "Excluded transaction")

      Button {
        editingItem = item
      } label: {
        HStack(alignment: .center, spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Text(payeeDisplay(item.draft))
              .font(.body.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
              .lineLimit(1)
            Text(categoryFootnote(item.draft))
              .font(.footnote)
              .foregroundStyle(isUncategorised(item.draft) ? AnyShapeStyle(Theme.uncategorised) : AnyShapeStyle(.secondary))
              .lineLimit(1)
          }
          Spacer()
          Text(MoneyCodec.signedDisplayString(for: item.draft.signedMilliunits, currencyFormat: model.currencyFormat))
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(Theme.registerAmountColour(item.draft.signedMilliunits))
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
    }
    .padding(.leading, 8)
    .padding(.trailing, 16)
    .padding(.vertical, 6)
    .opacity(item.included ? 1 : 0.4)
  }

  private var repairField: some View {
    TextField("everything from Cold Storage is groceries", text: $repairText)
      .textFieldStyle(.plain)
      .font(.footnote)
      .submitLabel(.go)
      .focused($isRepairFocused)
      .onSubmit(applyRepair)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var accountPickerCard: some View {
    NavigationLink {
      AccountPickerView(selectedAccountID: addToAccountID) { account in
        addToAccountID = account.id
      }
    } label: {
      DisclosureValueRow(
        icon: "building.columns",
        caption: "Add to",
        value: model.account(withID: addToAccountID)?.name,
        placeholder: "Choose Account"
      )
    }
    .buttonStyle(.plain)
    .ynabCard()
  }

  private var addButtonTitle: String {
    let count = includedItems.count
    let drafts = includedItems.map {
      IntakeReviewPreparation.draft($0, addToAccountID: addToAccountID)
    }
    if IntakeReviewPreparation.namesSharedAccount(in: drafts) {
      return "Add \(count) to \(addAccountName)"
    }
    return count == 1 ? "Add 1 transaction" : "Add \(count) transactions"
  }

  private var addButton: some View {
    Button(action: addIncluded) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill")
        Text(addButtonTitle)
          .fontWeight(.semibold)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
    .buttonStyle(.glassProminent)
    .tint(Theme.accent)
    .disabled(!canAdd)
    .opacity(canAdd ? 1 : 0.5)
  }

  private func toggle(_ id: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      return
    }
    items[index].included.toggle()
  }

  private func upsert(_ draft: TransactionDraft, id: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      return
    }
    items[index].draft = draft
    editingItem = nil
  }

  private func addIncluded() {
    let drafts = includedItems.map {
      IntakeReviewPreparation.draft($0, addToAccountID: addToAccountID)
    }
    guard drafts.allSatisfy(\.canSave) else {
      return
    }
    do {
      try model.commit(drafts)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func applyRepair() {
    let next = IntakeRepair.apply(
      repairText,
      to: items,
      categoryGroups: model.categoryGroups
    )
    if let next {
      items = next
    }
    isRepairFocused = false
  }

  private func payeeDisplay(_ draft: TransactionDraft) -> String {
    let name = draft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty {
      return name
    }
    return draft.transferAccountID != nil ? "Transfer" : "(No payee)"
  }

  private func isUncategorised(_ draft: TransactionDraft) -> Bool {
    draft.categoryID == nil && draft.transferAccountID == nil && !draft.isSplit
  }

  private func categoryFootnote(_ draft: TransactionDraft) -> String {
    if draft.isSplit {
      return "Split (\(draft.subtransactions.count))"
    }
    if draft.transferAccountID != nil {
      return "Transfer"
    }
    return model.categoryName(forID: draft.categoryID) ?? "Uncategorised"
  }
}

enum IntakeReviewPreparation {
  static func draft(_ item: IntakeReviewItem, addToAccountID: String) -> TransactionDraft {
    var draft = item.draft
    if draft.accountID.isEmpty {
      draft.accountID = addToAccountID
    }
    return draft
  }

  static func namesSharedAccount(in drafts: [TransactionDraft]) -> Bool {
    Set(drafts.map(\.accountID).filter { !$0.isEmpty }).count <= 1
  }
}

enum IntakeRepair {
  static func apply(
    _ text: String,
    to items: [IntakeReviewItem],
    categoryGroups: [CategoryGroup]
  ) -> [IntakeReviewItem]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let pattern = #"^everything from (.+) is (.+)$"#
    guard
      let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
      match.numberOfRanges == 3
    else {
      return nil
    }
    let ns = trimmed as NSString
    let payeeQuery = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    let categoryQuery = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
    let live = categoryGroups.filter { !$0.deleted }.flatMap { group in
      group.categories.filter { !$0.deleted }
    }
    let exact = live.filter { $0.name.caseInsensitiveCompare(categoryQuery) == .orderedSame }
    let matches = exact.isEmpty
      ? live.filter { $0.name.localizedStandardContains(categoryQuery) }
      : exact
    guard matches.count == 1 else {
      return nil
    }
    let categoryID = matches[0].id
    var changed = false
    let next = items.map { item -> IntakeReviewItem in
      var item = item
      if item.draft.payeeName.localizedStandardContains(payeeQuery) {
        item.draft.categoryID = categoryID
        changed = true
      }
      return item
    }
    return changed ? next : nil
  }
}
