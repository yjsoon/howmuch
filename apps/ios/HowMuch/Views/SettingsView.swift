import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var draft: APISettings
  @State private var password = ""
  @State private var authenticatedBaseURL: String
  @State private var authenticatedUsername: String
  @State private var isSaving = false
  @State private var testResult: TestResult?
  @State private var isTesting = false
  @State private var setupState: SetupState = .idle

  let onSave: @MainActor (APISettings) async -> Void

  private enum TestResult: Equatable {
    case success
    case failure(String)
  }

  private enum SetupState: Equatable {
    case idle
    case checking
    case ready
    case required
    case failure(String)
  }

  init(settings: APISettings, onSave: @escaping @MainActor (APISettings) async -> Void) {
    self.onSave = onSave
    self.draft = settings
    self.authenticatedBaseURL = settings.trimmedBaseURL
    self.authenticatedUsername = settings.username
  }

  private var sessionMatchesDraft: Bool {
    draft.isAuthenticated
      && draft.trimmedBaseURL == authenticatedBaseURL
      && draft.username == authenticatedUsername
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
          if !draft.trimmedBaseURL.isEmpty && !draft.isConfigured {
            Text("Enter a complete HTTP or HTTPS URL with a host.")
              .foregroundStyle(Theme.outflow)
          } else {
            Text("New installs use the production service. You can enter an HTTP LAN address for local development, but first-owner setup can only be opened from an HTTPS site.")
          }
        }
        .disabled(isTesting)

        if setupState == .required {
          Section {
            Text("This HowMuch server does not have an owner yet. Finish first-owner setup securely in the HowMuch website, then return here and retry before signing in.")

            if let setupURL = draft.browserSetupURL {
              Button {
                openURL(setupURL)
              } label: {
                Label("Open HowMuch Setup in Browser", systemImage: "safari")
              }
            } else {
              Text("Enter the server's HTTPS URL above to open setup in your browser.")
                .foregroundStyle(.secondary)
            }

            Button("Retry Setup Check") {
              checkSetupStatus()
            }
          } header: {
            Text("First-owner setup required")
          }
        } else if case .failure(let message) = setupState {
          Section {
            Text(message)
              .foregroundStyle(Theme.outflow)
            Button("Retry Server Check") {
              checkSetupStatus()
            }
          } header: {
            Text("Server check")
          }
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
          Text(sessionMatchesDraft ? "Signed in as \(draft.username)." : "Sign in stores an opaque session in this device's Keychain. Your password is never saved.")
        }
        .disabled(isTesting)

        Section {
          Button {
            signIn()
          } label: {
            HStack {
              Text(sessionMatchesDraft ? "Sign in again" : "Sign in")
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
          .disabled(isTesting || setupState == .checking || setupState == .required || !draft.isConfigured || draft.username.isEmpty || password.isEmpty)

          if sessionMatchesDraft {
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
      .task {
        checkSetupStatus()
      }
      .onChange(of: draft.baseURLString) {
        setupState = .idle
        testResult = nil
      }
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
          .disabled(isSaving || isTesting || !draft.isConfigured || !sessionMatchesDraft)
        }
      }
    }
  }

  private func signIn() {
    isTesting = true
    testResult = nil
    Task {
      do {
        var loginSettings = draft
        loginSettings.sessionToken = ""
        loginSettings.authenticatedUserID = ""
        let client = APIClient(settings: loginSettings)
        let status = try await client.fetchAuthStatus()
        guard !status.setupRequired else {
          setupState = .required
          testResult = .failure("Complete first-owner setup in the website before signing in.")
          isTesting = false
          return
        }
        setupState = .ready
        let session = try await client.login(username: draft.username, password: password)
        draft.sessionToken = session.token
        draft.authenticatedUserID = session.user.id
        draft.username = session.user.username ?? draft.username
        authenticatedBaseURL = draft.trimmedBaseURL
        authenticatedUsername = draft.username
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

  private func checkSetupStatus() {
    guard draft.isConfigured else {
      setupState = .idle
      return
    }
    setupState = .checking
    let checkedBaseURL = draft.trimmedBaseURL
    var statusSettings = draft
    statusSettings.sessionToken = ""
    statusSettings.authenticatedUserID = ""
    Task {
      do {
        let status = try await APIClient(settings: statusSettings).fetchAuthStatus()
        guard draft.trimmedBaseURL == checkedBaseURL else {
          return
        }
        setupState = status.setupRequired ? .required : .ready
      } catch {
        guard draft.trimmedBaseURL == checkedBaseURL else {
          return
        }
        setupState = .failure(error.localizedDescription)
      }
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
