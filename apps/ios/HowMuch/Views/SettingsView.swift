import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: APISettings
  @State private var isSaving = false
  @State private var testResult: TestResult?
  @State private var isTesting = false

  let onSave: @MainActor (APISettings) async -> Void

  private enum TestResult: Equatable {
    case success
    case failure(String)
  }

  init(settings: APISettings, onSave: @escaping @MainActor (APISettings) async -> Void) {
    _draft = State(initialValue: settings)
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("http://192.168.1.10:8787", text: $draft.baseURLString)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("Server")
        } footer: {
          Text("The Bun API host, reachable from this device. Use your machine's LAN address rather than 127.0.0.1 when running on hardware.")
        }

        Section {
          TextField("Bearer token", text: $draft.bearerToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .privacySensitive()

          TextField("Plan ID", text: $draft.planID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("Access")
        } footer: {
          Text("Leave the token blank when the API runs without one. The default plan ID is `local-plan`.")
        }

        Section {
          Button {
            testConnection()
          } label: {
            HStack {
              Text("Test connection")
              Spacer()
              if isTesting {
                ProgressView()
              } else if let testResult {
                switch testResult {
                case .success:
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.inflow)
                case .failure:
                  Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.outflow)
                }
              }
            }
          }
          .disabled(isTesting)
        } footer: {
          if case .failure(let message) = testResult {
            Text(message)
              .foregroundStyle(Theme.outflow)
          } else if testResult == .success {
            Text("Connected. The server answered as expected.")
          }
        }
      }
      .navigationTitle("Connection")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") {
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
          .disabled(isSaving || !draft.isConfigured)
        }
      }
    }
  }

  private func testConnection() {
    isTesting = true
    testResult = nil
    Task {
      do {
        _ = try await APIClient(settings: draft).fetchUser()
        testResult = .success
      } catch {
        testResult = .failure(error.localizedDescription)
      }
      isTesting = false
    }
  }
}
