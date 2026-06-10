import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: APISettings
  @State private var isSaving = false

  let onSave: @MainActor (APISettings) async -> Void

  init(settings: APISettings, onSave: @escaping @MainActor (APISettings) async -> Void) {
    _draft = State(initialValue: settings)
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Base URL", text: $draft.baseURLString)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

          TextField("Bearer token", text: $draft.bearerToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

          TextField("Plan ID", text: $draft.planID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("Connection")
        } footer: {
          Text("Use the Bun API host, for example `http://127.0.0.1:8787`. Leave the token blank for local development when the API allows unauthenticated requests.")
        }
      }
      .navigationTitle("API Settings")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close") {
            dismiss()
          }
        }

        ToolbarItem(placement: .topBarTrailing) {
          Button("Save") {
            Task {
              isSaving = true
              await onSave(draft)
              isSaving = false
              dismiss()
            }
          }
          .disabled(isSaving)
        }
      }
    }
  }
}
