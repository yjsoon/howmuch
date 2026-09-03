import SwiftUI

struct NewAccountSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var name = ""
  @State private var kind = AccountKind.checking
  @State private var balanceText = ""
  @State private var icon = AccountIcon.default(for: AccountKind.checking.rawValue)
  @State private var iconIsCustom = false
  @State private var isPickingIcon = false
  @State private var error: String?
  @State private var isSaving = false
  @FocusState private var isNameFocused: Bool

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          nameCard
          typeCard
          balanceCard
          iconCard
          if let error {
            Text(error)
              .font(.footnote)
              .foregroundStyle(Theme.outflow)
          }
        }
        .padding(16)
      }
      .background(Theme.canvas)
      .navigationTitle("New Account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.body.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
          }
          .disabled(isSaving)
          .accessibilityLabel("Cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          if isSaving {
            ProgressView()
              .accessibilityLabel("Saving")
          } else {
            Button {
              Task { await save() }
            } label: {
              Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(canSave ? Theme.accent : Color.secondary)
            }
            .disabled(!canSave)
            .accessibilityLabel("Save")
          }
        }
      }
      .interactiveDismissDisabled(isSaving)
      .task {
        await Task.yield()
        isNameFocused = true
      }
    }
  }

  private var nameCard: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 6) {
          Text("Name")
            .foregroundStyle(Theme.textPrimary)
          nameField
        }
      } else {
        HStack {
          Text("Name")
            .foregroundStyle(Theme.textPrimary)
          nameField
            .multilineTextAlignment(.trailing)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
    .ynabCard()
  }

  private var nameField: some View {
    TextField("Everyday Account", text: $name)
      .textInputAutocapitalization(.words)
      .focused($isNameFocused)
      .disabled(isSaving)
  }

  private var typeCard: some View {
    NavigationLink {
      AccountKindPicker(selection: $kind)
    } label: {
      HStack {
        Text("Type")
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        Text(kind.title)
          .foregroundStyle(.secondary)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isSaving)
    .ynabCard()
    .accessibilityLabel("Type")
    .accessibilityValue(kind.title)
    .onChange(of: kind) { _, next in
      if !iconIsCustom {
        icon = AccountIcon.default(for: next.rawValue)
      }
    }
  }

  private var balanceCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 6) {
            Text(balanceLabel)
              .foregroundStyle(Theme.textPrimary)
            balanceField
          }
        } else {
          HStack {
            Text(balanceLabel)
              .foregroundStyle(Theme.textPrimary)
            balanceField
              .multilineTextAlignment(.trailing)
          }
        }
      }
      Text(balanceHint)
        .font(.footnote)
        .foregroundStyle(enteredBalance == nil ? Theme.outflow : Color.secondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
    .ynabCard()
  }

  private var balanceField: some View {
    TextField("0.00", text: $balanceText)
      .keyboardType(kind.storesLiability ? .decimalPad : .numbersAndPunctuation)
      .disabled(isSaving)
      .accessibilityLabel(balanceLabel)
  }

  private var iconCard: some View {
    Button {
      isPickingIcon = true
    } label: {
      HStack {
        Text("Icon")
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        Text(icon.rawValue)
          .font(.title3)
          .accessibilityHidden(true)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isSaving)
    .ynabCard()
    .accessibilityLabel("Icon")
    .accessibilityValue(icon.rawValue)
    .accessibilityHint("Opens the icon picker")
    .sheet(isPresented: $isPickingIcon) {
      AccountIconPicker(selected: icon) { picked in
        icon = picked
        iconIsCustom = true
        isPickingIcon = false
      }
    }
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var enteredBalance: Int? {
    let trimmed = balanceText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return 0
    }
    return MoneyCodec.milliunits(from: trimmed)
  }

  private var canSave: Bool {
    !trimmedName.isEmpty && enteredBalance != nil && !isSaving
  }

  private var balanceLabel: String {
    kind.storesLiability ? "Amount owed" : "Current balance"
  }

  private var balanceHint: String {
    if enteredBalance == nil {
      return "Enter an amount with no more than three decimal places."
    }
    if kind.storesLiability {
      return "Stored as a negative balance, like a credit card statement."
    }
    return "Use a minus sign if this account is already overdrawn."
  }

  private func save() async {
    guard let enteredBalance, canSave else { return }
    isSaving = true
    error = nil
    do {
      _ = try await model.createAccount(
        name: trimmedName,
        kind: kind,
        enteredBalance: enteredBalance,
        icon: icon
      )
      dismiss()
    } catch {
      self.error = error.localizedDescription
      isSaving = false
    }
  }
}

private struct AccountKindPicker: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var selection: AccountKind

  var body: some View {
    List {
      ForEach(AccountKind.Group.allCases, id: \.self) { group in
        Section(group.title) {
          ForEach(AccountKind.kinds(in: group)) { kind in
            Button {
              selection = kind
              dismiss()
            } label: {
              HStack {
                Text(kind.title)
                  .foregroundStyle(Theme.textPrimary)
                Spacer()
                if selection == kind {
                  Image(systemName: "checkmark")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                }
              }
            }
            .accessibilityAddTraits(selection == kind ? [.isSelected] : [])
          }
        }
      }
    }
    .navigationTitle("Account Type")
    .navigationBarTitleDisplayMode(.inline)
  }
}
