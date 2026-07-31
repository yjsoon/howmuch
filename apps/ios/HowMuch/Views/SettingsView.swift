import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: APISettings
  @State private var password = ""
  @State private var isSaving = false
  @State private var testResult: TestResult?
  @State private var isTesting = false

  let onSave: @MainActor (APISettings) async -> Void

  private enum TestResult: Equatable {
    case success
    case failure(String)
  }

  init(settings: APISettings, onSave: @escaping @MainActor (APISettings) async -> Void) {
    self.onSave = onSave
    self.draft = settings
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
          Text("Use the deployed HowMuch URL, or your computer's LAN address for local development. 127.0.0.1 on a physical device points to the phone itself.")
        }

        Section {
          TextField("Username", text: $draft.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

          SecureField("Password", text: $password)
            .textContentType(.password)

          TextField("Plan ID", text: $draft.planID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("Access")
        } footer: {
          Text(draft.isAuthenticated ? "Signed in as \(draft.username)." : "Sign in stores an opaque session in this device's Keychain. Your password is never saved.")
        }

        Section {
          Button {
            signIn()
          } label: {
            HStack {
              Text(draft.isAuthenticated ? "Sign in again" : "Sign in")
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
          .disabled(isTesting || draft.username.isEmpty || password.isEmpty)

          if draft.isAuthenticated {
            Button("Sign out", role: .destructive) {
              signOut()
            }
          }
        } footer: {
          if case .failure(let message) = testResult {
            Text(message)
              .foregroundStyle(Theme.outflow)
          } else if testResult == .success {
            Text("Signed in successfully.")
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
          .disabled(isSaving || !draft.isConfigured || !draft.isAuthenticated)
        }
      }
    }
  }

  private func signIn() {
    isTesting = true
    testResult = nil
    Task {
      do {
        let session = try await APIClient(settings: draft).login(username: draft.username, password: password)
        draft.sessionToken = session.token
        draft.authenticatedUserID = session.user.id
        draft.username = session.user.username ?? draft.username
        if let plan = try await APIClient(settings: draft).fetchPlans().first {
          draft.planID = plan.id
        }
        password = ""
        testResult = .success
      } catch {
        testResult = .failure(error.localizedDescription)
      }
      isTesting = false
    }
  }

  private func signOut() {
    let current = draft
    draft.sessionToken = ""
    draft.authenticatedUserID = ""
    testResult = nil
    isSaving = true
    Task {
      await onSave(draft)
      try? await APIClient(settings: current).logout()
      isSaving = false
      dismiss()
    }
  }
}
