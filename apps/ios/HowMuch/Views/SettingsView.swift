import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The on-device ledger archive (JSON), saved with the file exporter.
private struct LocalArchiveDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

/// The on-device ledger an install used before it connected to a server.
/// It can be saved as a file or used again.
private struct LocalArchiveSection: View {
  let archive: LocalArchive
  @Environment(AppModel.self) private var model
  @State private var exportDocument: LocalArchiveDocument?
  @State private var isExporting = false
  @State private var isWorking = false
  @State private var isConfirmingSwitch = false
  @State private var errorMessage: String?
  private let device = UIDevice.current.model

  var body: some View {
    Section {
      Button("Export as file") {
        export()
      }
      Button("Switch back to this \(device)’s data") {
        isConfirmingSwitch = true
      }
      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(Theme.outflow)
      }
    } header: {
      Text("Data from before you connected")
    } footer: {
      Text("Kept on this \(device) since \(archive.archivedAt.formatted(date: .abbreviated, time: .omitted)). Switching back signs you out of the server.")
    }
    .disabled(isWorking)
    .fileExporter(
      isPresented: $isExporting,
      document: exportDocument,
      contentType: .json,
      defaultFilename: "halation-\(device.lowercased())-\(archive.archivedAt.isoDateString).json"
    ) { outcome in
      if case .failure(let error) = outcome {
        errorMessage = error.localizedDescription
      }
      exportDocument = nil
    }
    .confirmationDialog(
      "Use the records on this \(device) instead of the server?",
      isPresented: $isConfirmingSwitch,
      titleVisibility: .visible
    ) {
      Button("Switch back") {
        switchBack()
      }
    }
  }

  private func export() {
    isWorking = true
    errorMessage = nil
    Task {
      do {
        exportDocument = LocalArchiveDocument(data: try await model.exportLocalArchive())
        isExporting = true
      } catch {
        errorMessage = error.localizedDescription
      }
      isWorking = false
    }
  }

  private func switchBack() {
    isWorking = true
    errorMessage = nil
    Task {
      do {
        try await model.switchToLocalArchive()
      } catch {
        errorMessage = error.localizedDescription
      }
      isWorking = false
    }
  }
}

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var draft: APISettings
  @State private var password = ""
  @State private var authenticatedBaseURL: String
  @State private var authenticatedUsername: String
  @State private var isSaving = false
  @State private var testResult: TestResult?
  @State private var isTesting = false
  @State private var setupState: SetupState = .idle
  @State private var planState: PlanState = .idle
  @State private var planRequestID = UUID()
  private let wasInitiallyAuthenticated: Bool
  /// Read once: an archive appears only when an install connects, which
  /// happens outside this sheet.
  @State private var localArchive: LocalArchive?

  let onSave: @MainActor (APISettings) async -> Void
  private let screenshots: ScreenshotOfferController

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

  private enum PlanState: Equatable {
    case idle
    case loading
    case loaded([PlanSummary])
    case failure(String)
  }

  init(
    settings: APISettings,
    screenshots: ScreenshotOfferController? = nil,
    onSave: @escaping @MainActor (APISettings) async -> Void
  ) {
    self.onSave = onSave
    self.screenshots = screenshots ?? .shared
    self.draft = settings
    self.authenticatedBaseURL = settings.trimmedBaseURL
    self.authenticatedUsername = settings.username
    self.wasInitiallyAuthenticated = settings.isAuthenticated
    self._localArchive = State(initialValue: settings.isLocal ? nil : LocalArchive.existing())
  }

  private var sessionMatchesDraft: Bool {
    draft.isAuthenticated
      && draft.trimmedBaseURL == authenticatedBaseURL
      && draft.username == authenticatedUsername
  }

  private var hasValidPlanSelection: Bool {
    guard case .loaded(let plans) = planState else {
      return false
    }
    return plans.contains { $0.id == draft.planID }
  }

  var body: some View {
    if draft.isLocal {
      localBody
    } else {
      serverBody
    }
  }

  private static let clipboardImagesFooter = "Offers only the image currently on your clipboard. iOS may ask for paste permission. Images are checked on this device; your Photos library is never read. Off by default."

  private var clipboardImagesButton: some View {
    Button {
      let next = !screenshots.isEnabled
      screenshots.applyEnabledPreference(next)
      Task { await screenshots.refresh() }
    } label: {
      HStack {
        Text("Offer clipboard images")
          .foregroundStyle(Theme.textPrimary)
        Spacer()
        Text(screenshots.isEnabled ? "On" : "Off")
          .foregroundStyle(screenshots.isEnabled ? Theme.accent : .secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .accessibilityIdentifier("offer-clipboard-images")
    .accessibilityLabel("Offer clipboard images")
    .accessibilityValue(screenshots.isEnabled ? "On" : "Off")
  }

  /// Local mode has no server session to manage: no sign-in, plan choice or
  /// sign-out. "Connect to a server" signs in and moves the ledger there.
  private var localBody: some View {
    NavigationStack {
      Form {
        Section {
          Label("Records are kept on this \(UIDevice.current.model)", systemImage: "iphone")
            .foregroundStyle(Theme.textPrimary)
          NavigationLink("Connect to a server") {
            ServerConnectView(local: draft)
          }
        } header: {
          Text("Storage")
        }
        Section("Intelligence") {
          NavigationLink("AI provider") {
            CaptureAISettingsView(settings: model.captureAI)
          }
        }
        Section {
          NavigationLink {
            RewardsImportView()
          } label: {
            Text("Rewards Import & Export")
          }
        } header: {
          Text("Tools")
        } footer: {
          Text("Import or export Rewards Tracker settings. Does not connect to live YNAB.")
        }
        Section {
          clipboardImagesButton
        } footer: {
          Text(Self.clipboardImagesFooter)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }

  private var serverBody: some View {
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
            Text(draft.refusesPublicHTTP
              ? "HTTP is only for this device or this LAN."
              : "Enter a complete HTTP or HTTPS URL with a host.")
              .foregroundStyle(Theme.outflow)
          } else {
            Text("New installs connect to Halation. HTTP is allowed only for this device or this network. First-time setup must be opened from the website.")
          }
        }
        .disabled(isTesting)

        if setupState == .required {
          SetupRequiredSection(setupURL: draft.browserSetupURL) {
            checkSetupStatus()
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
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

          SecureField("Password", text: $password)
            .textContentType(.password)
        } header: {
          Text("Access")
        } footer: {
          Text(sessionMatchesDraft ? "Signed in as \(draft.username)." : "Sign in stores an opaque session in this device's Keychain. Your password is never saved.")
        }
        .disabled(isTesting)

        if sessionMatchesDraft {
          planSection
          Section("Intelligence") {
            NavigationLink("AI provider") {
              CaptureAISettingsView(settings: model.captureAI)
            }
          }
          Section {
            NavigationLink {
              RewardsImportView()
            } label: {
              Text("Rewards Import & Export")
            }
          } header: {
            Text("Tools")
          } footer: {
            Text("Import or export Rewards Tracker settings. Does not connect to live YNAB.")
          }
        }

        if let localArchive {
          LocalArchiveSection(archive: localArchive)
        }

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
            Button("Sign out / Use another account", role: .destructive) {
              signOut()
            }
            .disabled(isSaving || isTesting)
          }

          clipboardImagesButton
        } footer: {
          VStack(alignment: .leading, spacing: 8) {
            if case .failure(let message) = testResult {
              Text(message)
                .foregroundStyle(Theme.outflow)
            } else if testResult == .success {
              Text("Signed in successfully.")
            }
            Text(Self.clipboardImagesFooter)
          }
        }
      }
      .navigationTitle("Connection")
      .navigationBarTitleDisplayMode(.inline)
      .task {
        checkSetupStatus()
        if sessionMatchesDraft {
          loadPlans()
        }
      }
      .onChange(of: draft.baseURLString) {
        setupState = .idle
        testResult = nil
        planState = .idle
        planRequestID = UUID()
      }
      .onChange(of: draft.username) {
        testResult = nil
        planState = .idle
        planRequestID = UUID()
        if !isTesting && sessionMatchesDraft {
          loadPlans()
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if !wasInitiallyAuthenticated && model.canReturnToWelcome {
            Button("Back") {
              model.returnToWelcome()
            }
          } else {
            Button("Cancel") {
              dismiss()
            }
            .disabled(!wasInitiallyAuthenticated || !draft.isAuthenticated)
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
          .disabled(isSaving || isTesting || !draft.isConfigured || !sessionMatchesDraft || !hasValidPlanSelection)
        }
      }
    }
  }

  @ViewBuilder
  private var planSection: some View {
    switch planState {
    case .idle, .loading:
      Section("Plan") {
        HStack {
          Text("Finding your plans…")
          Spacer()
          ProgressView()
        }
      }
    case .loaded(let plans) where plans.isEmpty:
      Section("Plan") {
        Text("No plans available")
          .font(.headline)
        Text("This account doesn’t have access to a plan yet. Ask for access, then try again.")
          .foregroundStyle(.secondary)
        Button("Try Again") {
          loadPlans()
        }
      }
    case .loaded(let plans) where plans.count == 1:
      Section {
        Text(plans[0].name)
      } header: {
        Text("Plan")
      } footer: {
        Text("Selected automatically.")
      }
    case .loaded(let plans):
      Section {
        PlanChoiceRows(plans: plans, selection: $draft.planID)
      } header: {
        Text("Choose a plan")
      } footer: {
        if draft.planID.isEmpty {
          Text("Choose a plan to continue.")
            .foregroundStyle(Theme.outflow)
        } else {
          Text("You have access to more than one plan. Choose which plan to use on this device.")
        }
      }
    case .failure(let message):
      Section("Couldn’t load plans") {
        Text("You’re signed in, but Halation couldn’t load your plans. Check the connection and try again.")
          .foregroundStyle(.secondary)
        Text(message)
          .font(.caption)
          .foregroundStyle(Theme.outflow)
        Button("Try Again") {
          loadPlans()
        }
      }
    }
  }

  private func signIn() {
    isTesting = true
    testResult = nil
    planState = .idle
    planRequestID = UUID()
    Task {
      do {
        guard case .signedIn(let signedIn) = try await ServerSignIn.signIn(draft, password: password) else {
          setupState = .required
          testResult = .failure("Finish setup in the website before signing in.")
          isTesting = false
          return
        }
        setupState = .ready
        draft.sessionToken = signedIn.sessionToken
        draft.authenticatedUserID = signedIn.authenticatedUserID
        draft.username = signedIn.username
        authenticatedBaseURL = draft.trimmedBaseURL
        authenticatedUsername = draft.username
        password = ""
        testResult = .success
        let requestID = UUID()
        planRequestID = requestID
        planState = .loading
        do {
          let plans = try await APIClient(settings: draft).fetchPlans()
          guard planRequestID == requestID, sessionMatchesDraft else {
            isTesting = false
            return
          }
          applyDiscoveredPlans(plans)
        } catch {
          guard planRequestID == requestID, sessionMatchesDraft else {
            isTesting = false
            return
          }
          planState = .failure(error.localizedDescription)
        }
      } catch {
        testResult = .failure(error.localizedDescription)
      }
      isTesting = false
    }
  }

  private func loadPlans() {
    guard sessionMatchesDraft else {
      planState = .idle
      return
    }
    let requestID = UUID()
    planRequestID = requestID
    planState = .loading
    let expectedBaseURL = draft.trimmedBaseURL
    let expectedUsername = draft.username
    let settings = draft
    Task {
      do {
        let plans = try await APIClient(settings: settings).fetchPlans()
        guard planRequestID == requestID, draft.trimmedBaseURL == expectedBaseURL, draft.username == expectedUsername, sessionMatchesDraft else {
          return
        }
        applyDiscoveredPlans(plans)
      } catch {
        guard planRequestID == requestID, draft.trimmedBaseURL == expectedBaseURL, draft.username == expectedUsername, sessionMatchesDraft else {
          return
        }
        planState = .failure(error.localizedDescription)
      }
    }
  }

  private func applyDiscoveredPlans(_ plans: [PlanSummary]) {
    draft.planID = draft.resolvedPlanID(from: plans) ?? ""
    planState = .loaded(plans)
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
    draft.planID = ""
    password = ""
    testResult = nil
    planState = .idle
    planRequestID = UUID()
    isSaving = true
    Task {
      await onSave(draft)
      try? await APIClient(settings: current).logout()
      isSaving = false
    }
  }
}
