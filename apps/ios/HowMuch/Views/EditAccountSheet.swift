import SwiftUI

struct EditAccountSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let account: Account
  @State private var name: String
  @State private var classification: AccountClassification
  @State private var icon: AccountIconChoice
  @State private var error: String?
  @State private var isSaving = false
  @FocusState private var nameFocused: Bool

  init(account: Account) {
    self.account = account
    _name = State(initialValue: account.name)
    _classification = State(initialValue: AccountClassification(type: account.type))
    _icon = State(initialValue: AccountIconChoice(stored: account.icon, type: account.type))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          AccountIdentityFields(
            name: $name,
            classification: $classification,
            icon: $icon,
            nameFocus: $nameFocused
          )
          .disabled(isSaving)
          ForEach(typeNotes, id: \.self) { note in
            Text(note)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          if let error {
            Text(error)
              .font(.footnote)
              .foregroundStyle(Theme.outflow)
          }
        }
        .padding(16)
      }
      .background(Theme.canvas)
      .navigationTitle("Edit Account")
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
    }
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSave: Bool {
    !trimmedName.isEmpty
  }

  private var identity: AccountIdentity {
    AccountIdentity(
      name: trimmedName,
      classification: classification,
      icon: icon.resolved(default: classification.defaultIcon)
    )
  }

  private var typeNotes: [String] {
    switch classification {
    case .imported:
      return [
        "Imported as \(classification.title). Choose a type to classify it. Balances do not change.",
      ]
    case .kind(let kind):
      var notes: [String] = []
      if AccountKind(rawValue: account.type) == nil {
        notes.append("Replaces the imported type “\(account.type)”. Balances do not change.")
      }
      if kind.onBudget != account.onBudget {
        let origin = account.onBudget ? "Budget" : "Tracking"
        let destination = kind.onBudget ? "Budget" : "Tracking"
        notes.append("Moves the account from \(origin) to \(destination). Balances do not change.")
      }
      return notes
    }
  }

  private func save() async {
    guard canSave else { return }
    isSaving = true
    error = nil
    do {
      try await model.updateAccount(identity, for: account.id)
      dismiss()
    } catch {
      self.error = error.localizedDescription
      isSaving = false
    }
  }
}
