import SwiftUI
import UIKit

// MARK: - Shell: sign-in and the connect requests

/// Signs in to a server without saving anything. Settings and the connect
/// flow both use it; neither changes the app's connection until the user
/// saves or finishes.
enum ServerSignIn {
  enum Outcome {
    /// The server has no account yet: its first owner is set up on the web.
    case setupRequired
    case signedIn(APISettings)
  }

  static func signIn(_ draft: APISettings, password: String) async throws -> Outcome {
    var loginSettings = draft
    loginSettings.sessionToken = ""
    loginSettings.authenticatedUserID = ""
    let client = APIClient(settings: loginSettings)
    let status = try await client.fetchAuthStatus()
    guard !status.setupRequired else {
      return .setupRequired
    }
    let session = try await client.login(username: draft.username, password: password)
    var signedIn = draft
    signedIn.sessionToken = session.token
    signedIn.authenticatedUserID = session.user.id
    signedIn.username = session.user.username ?? draft.username
    return .signedIn(signedIn)
  }
}

/// The requests behind "Connect to a server": a local client for the
/// on-device ledger and a server client for the signed-in plan.
struct ServerConnector {
  let local: APISettings
  let server: APISettings

  enum UploadResult: Equatable {
    case uploaded
    case serverHasData
    case tooLarge
    /// The server refuses this upload for good (not the owner, a YNAB plan).
    case refused(String)
    case failed(String)
  }

  func inspectServerPlan() async throws -> ServerPlanContents {
    let client = APIClient(settings: server)
    let planID = server.planID
    async let accounts = client.fetchAccounts(planID: planID)
    async let groups = client.fetchCategories(planID: planID)
    async let payees = client.fetchPayees(planID: planID)
    async let firstTransaction = client.fetchTransactions(planID: planID, limit: 1)
    async let schedules = client.fetchScheduledTransactions(planID: planID)
    let page = try await firstTransaction
    return try await ServerPlanContents(
      accounts: accounts,
      hasTransactions: !page.transactions.isEmpty || page.hasMore,
      scheduledTransactions: schedules,
      payees: payees,
      categoryGroups: groups
    )
  }

  func exportLocalLedger() async throws -> Data {
    try await APIClient(settings: local).exportSnapshot(planID: local.planID)
  }

  /// Imports the snapshot into the server plan. Nothing on the device
  /// changes, whatever the result.
  func upload(_ snapshot: Data) async -> UploadResult {
    let key = SnapshotImport.idempotencyKey(localPlanID: local.planID, serverPlanID: server.planID)
    do {
      try await APIClient(settings: server).importSnapshot(planID: server.planID, idempotencyKey: key, snapshot: snapshot)
      return .uploaded
    } catch {
      switch SnapshotImport.failure(for: error) {
      case .serverHasData:
        return .serverHasData
      case .tooLarge:
        return .tooLarge
      case .refused(let message):
        return .refused(message)
      case .failed(let message):
        return .failed(message)
      case .recheck(let message):
        guard let contents = try? await inspectServerPlan() else {
          return .failed(message)
        }
        return contents.isEmpty ? .failed(message) : .serverHasData
      }
    }
  }

  /// The archived ledger as snapshot JSON, read through the engine. Only a
  /// request is made: no schedule catch-up runs on the archive.
  static func exportArchive(_ archive: LocalArchive) async throws -> Data {
    let settings = archive.engineSettings
    let segment = archive.planID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
      ?? archive.planID
    let response = try await engine(for: archive).handle(
      config: settings.localEngineConfig,
      method: "GET",
      path: "/v1/plans/\(segment)/export_snapshot",
      query: nil,
      headers: ["Authorization": "Bearer \(settings.sessionToken)", "Accept": "application/json"],
      body: nil
    )
    guard (200 ..< 300).contains(response.status) else {
      throw APIClientError.httpStatus(response.status)
    }
    return try SnapshotImport.snapshot(fromExportResponse: response.body)
  }

  static func engine(for archive: LocalArchive) -> LocalEngine {
    let shared = LocalEngine.shared
    return archive.databaseURL.standardizedFileURL == shared.databaseURL.standardizedFileURL
      ? shared
      : LocalEngine(databaseURL: archive.databaseURL)
  }
}

// MARK: - Flow

@MainActor
@Observable
final class ServerConnectFlow {
  enum Step: Equatable {
    case signIn
    case choosePlan([PlanSummary])
    case checking
    case checkFailed(String)
    case confirmUpload(SnapshotImport.Summary)
    case uploading
    case uploadFailed(String)
    case serverHasData
    case tooLarge
    /// The server will never take this upload; no retry is offered.
    case refused(String)
  }

  let local: APISettings
  var draft = APISettings(baseURLString: "")
  var password = ""
  var selectedPlanID = ""
  private(set) var step: Step = .signIn
  private(set) var isSigningIn = false
  private(set) var signInError: String?
  private(set) var setupRequired = false
  /// The signed-in server connection. Held only in memory until the user
  /// finishes, so leaving the flow saves nothing.
  private(set) var server: APISettings?
  private var snapshot: Data?
  /// The user left the flow. Nothing that finishes afterwards may switch the
  /// app to the server: its session has been, or is being, signed out.
  private(set) var isAbandoned = false
  /// The user chose to switch to the server.
  private(set) var isFinished = false

  /// `signedIn` starts the flow after sign-in, with its plan chosen.
  init(local: APISettings, signedIn server: APISettings? = nil) {
    self.local = local
    self.server = server
    if let server {
      draft = server
    }
  }

  var host: String {
    draft.baseURL?.host() ?? draft.trimmedBaseURL
  }

  var canSignIn: Bool {
    !isSigningIn && draft.isConfigured && !draft.username.isEmpty && !password.isEmpty
  }

  /// A request is in flight. Leaving is disabled until it answers.
  var isBusy: Bool {
    isSigningIn || step == .checking || step == .uploading
  }

  /// Leaves the flow. Returns the session to sign out, unless the user
  /// already chose the server.
  func abandon() -> APISettings? {
    guard !isFinished, !isAbandoned else {
      return nil
    }
    isAbandoned = true
    return server
  }

  /// Claims a result for switching to the server. Nil once the flow has been
  /// left, so a late upload can never adopt a signed-out session.
  func adopt(_ candidate: APISettings?) -> APISettings? {
    guard !isAbandoned, !isFinished, let candidate else {
      return nil
    }
    isFinished = true
    return candidate
  }

  func signIn() async {
    isSigningIn = true
    signInError = nil
    setupRequired = false
    defer { isSigningIn = false }
    var opened: APISettings?
    do {
      switch try await ServerSignIn.signIn(draft, password: password) {
      case .setupRequired:
        setupRequired = true
        signInError = "Finish setup in the website before signing in."
      case .signedIn(var signedIn):
        opened = signedIn
        password = ""
        let plans = try await APIClient(settings: signedIn).fetchPlans()
        guard !isAbandoned else {
          try? await APIClient(settings: signedIn).logout()
          return
        }
        if plans.isEmpty {
          signInError = "This account doesn’t have access to a plan yet. Ask for access, then try again."
          try? await APIClient(settings: signedIn).logout()
          return
        }
        if let planID = signedIn.resolvedPlanID(from: plans) {
          signedIn.planID = planID
          server = signedIn
          await check()
        } else {
          server = signedIn
          step = .choosePlan(plans)
        }
      }
    } catch {
      signInError = error.localizedDescription
      // Signed in, then a later step failed: the session is not kept.
      if let opened, server == nil {
        try? await APIClient(settings: opened).logout()
      }
    }
  }

  func continueWithSelectedPlan() async {
    guard !selectedPlanID.isEmpty else {
      return
    }
    server?.planID = selectedPlanID
    await check()
  }

  /// Decides between uploading and the choice: an empty server plan gets the
  /// on-device ledger; one with records is never touched.
  func check() async {
    guard let server else {
      return
    }
    step = .checking
    let connector = ServerConnector(local: local, server: server)
    do {
      let contents = try await connector.inspectServerPlan()
      guard !isAbandoned else {
        return
      }
      guard contents.isEmpty else {
        step = .serverHasData
        return
      }
      let snapshot = try await connector.exportLocalLedger()
      let summary = try SnapshotImport.summary(of: snapshot)
      guard !isAbandoned else {
        return
      }
      guard summary.fitsOneRequest else {
        step = .tooLarge
        return
      }
      self.snapshot = snapshot
      step = .confirmUpload(summary)
    } catch {
      guard !isAbandoned else {
        return
      }
      step = .checkFailed(error.localizedDescription)
    }
  }

  /// Returns the server connection to switch to once the upload is in, or
  /// nil if it is not, or if the user left meanwhile.
  func upload() async -> APISettings? {
    guard let server, let snapshot, !isAbandoned else {
      return nil
    }
    step = .uploading
    let result = await ServerConnector(local: local, server: server).upload(snapshot)
    guard !isAbandoned else {
      return nil
    }
    switch result {
    case .uploaded:
      return adopt(server)
    case .serverHasData:
      step = .serverHasData
    case .tooLarge:
      step = .tooLarge
    case .refused(let message):
      step = .refused(message)
    case .failed(let message):
      step = .uploadFailed(message)
    }
    return nil
  }
}

// MARK: - Views shared with Settings

/// Shown when a server has no account yet. The first owner is set up on the
/// website, never from the app.
struct SetupRequiredSection: View {
  let setupURL: URL?
  let onRetry: () -> Void
  @Environment(\.openURL) private var openURL

  var body: some View {
    Section {
      Text("This HowMuch site does not have an account yet. Finish setup in the website, then return here and sign in.")

      if let setupURL {
        Button {
          openURL(setupURL)
        } label: {
          Label("Open HowMuch Setup in Browser", systemImage: "safari")
        }
      } else {
        Text("Enter the HTTPS address above to open setup in your browser.")
          .foregroundStyle(.secondary)
      }

      Button("Retry Setup Check", action: onRetry)
    } header: {
      Text("Setup required")
    }
  }
}

/// One row per plan, for a sign-in that can reach more than one.
struct PlanChoiceRows: View {
  let plans: [PlanSummary]
  @Binding var selection: String

  var body: some View {
    ForEach(plans) { plan in
      let duplicate = plans.contains { $0.id != plan.id && $0.name == plan.name }
      Button {
        selection = plan.id
      } label: {
        HStack {
          VStack(alignment: .leading) {
            Text(plan.name)
              .foregroundStyle(Theme.textPrimary)
            if duplicate {
              Text(plan.id)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          if selection == plan.id {
            Image(systemName: "checkmark")
          }
        }
      }
      .accessibilityLabel(duplicate ? "\(plan.name), plan ID \(plan.id)" : plan.name)
      .accessibilityAddTraits(selection == plan.id ? [.isSelected] : [])
    }
  }
}

// MARK: - Connect to a server

/// Moves the on-device ledger to a server, or leaves it where it is. The app
/// stays in local mode until the user finishes.
struct ServerConnectView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var flow: ServerConnectFlow
  @State private var isFinishing = false
  private let device = UIDevice.current.model

  init(local: APISettings) {
    _flow = State(initialValue: ServerConnectFlow(local: local))
  }

  var body: some View {
    Form {
      switch flow.step {
      case .signIn:
        signInSections
      case .choosePlan(let plans):
        Section {
          PlanChoiceRows(plans: plans, selection: $flow.selectedPlanID)
        } header: {
          Text("Choose a plan")
        } footer: {
          Text("This account can use more than one plan. Choose the one to connect.")
        }
        Section {
          Button("Continue") {
            Task { await flow.continueWithSelectedPlan() }
          }
          .disabled(flow.selectedPlanID.isEmpty)
        }
      case .checking:
        progress("Checking \(flow.host)…")
      case .uploading:
        progress("Uploading to \(flow.host)…")
      case .checkFailed(let message):
        failure(
          "HowMuch couldn’t check \(flow.host). Nothing has changed on this \(device).",
          message: message
        ) {
          Task { await flow.check() }
        }
      case .uploadFailed(let message):
        failure(
          "The upload didn’t finish. Nothing has changed on this \(device).",
          message: message
        ) {
          Task { await finish(with: flow.upload()) }
        }
      case .confirmUpload(let summary):
        Section {
          Text("Upload \(Self.count(summary.accounts, "account")) and \(Self.count(summary.transactions, "transaction")) from this \(device) to \(flow.host)?")
            .foregroundStyle(Theme.textPrimary)
        } footer: {
          Text("The records also stay on this \(device). After the upload, HowMuch uses the server.")
        }
        Section {
          Button("Upload") {
            Task { await finish(with: flow.upload()) }
          }
          Button("Cancel", role: .cancel) {
            Task { await keepThisDevice() }
          }
        }
      case .serverHasData:
        Section {
          Text("\(flow.host) already has records. They may include an earlier upload from this \(device). HowMuch doesn’t combine two sets of records.")
            .foregroundStyle(Theme.textPrimary)
        }
        Section {
          Button("Use the data on the server") {
            Task { await finish(with: flow.adopt(flow.server)) }
          }
        } footer: {
          Text("The records on this \(device) stay on it. You can export them from Settings.")
        }
        Section {
          Button("Keep using this \(device) only") {
            Task { await keepThisDevice() }
          }
        } footer: {
          Text("Signs out of \(flow.host).")
        }
      case .tooLarge:
        Section {
          Text("These records are too large to upload in one go. Nothing has changed on this \(device).")
            .foregroundStyle(Theme.textPrimary)
        }
        Section {
          Button("Keep using this \(device) only") {
            Task { await keepThisDevice() }
          }
        }
      case .refused(let message):
        Section {
          Text(message)
            .foregroundStyle(Theme.textPrimary)
        } footer: {
          Text("Nothing has changed on this \(device).")
        }
        Section {
          Button("Keep using this \(device) only") {
            Task { await keepThisDevice() }
          }
        }
      }
    }
    .disabled(isFinishing)
    .navigationTitle("Connect to a server")
    .navigationBarTitleDisplayMode(.inline)
    // While a request is in flight the user cannot go back or swipe the
    // sheet away; `abandon()` covers anything that still gets through.
    .navigationBarBackButtonHidden(flow.isBusy || isFinishing)
    .onChange(of: flow.isBusy || isFinishing, initial: true) { _, busy in
      model.isConnectingToServer = busy
    }
    .onDisappear {
      model.isConnectingToServer = false
      // Leaving without finishing ends the session the flow opened.
      if let server = flow.abandon() {
        Task { await model.discardServerSession(server) }
      }
    }
  }

  @ViewBuilder
  private var signInSections: some View {
    Section {
      TextField("https://howmuch.example.com", text: $flow.draft.baseURLString)
        .keyboardType(.URL)
        .textContentType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    } header: {
      Text("Server")
    } footer: {
      if !flow.draft.trimmedBaseURL.isEmpty && !flow.draft.isConfigured {
        Text(flow.draft.refusesPublicHTTP
          ? "HTTP is only for this device or this LAN."
          : "Enter a complete HTTP or HTTPS URL with a host.")
          .foregroundStyle(Theme.outflow)
      } else {
        Text("A HowMuch server that you or your organisation runs.")
      }
    }

    if flow.setupRequired {
      SetupRequiredSection(setupURL: flow.draft.browserSetupURL) {
        Task { await flow.signIn() }
      }
    }

    Section {
      TextField("Username", text: $flow.draft.username)
        .textContentType(.username)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      SecureField("Password", text: $flow.password)
        .textContentType(.password)
    } header: {
      Text("Account")
    } footer: {
      Text("Use an account that already exists on the server. There is no public sign-up.")
    }

    Section {
      Button {
        Task { await flow.signIn() }
      } label: {
        HStack {
          Text("Sign in")
          Spacer()
          if flow.isSigningIn {
            ProgressView()
          }
        }
      }
      .disabled(!flow.canSignIn)
    } footer: {
      if let error = flow.signInError {
        Text(error)
          .foregroundStyle(Theme.outflow)
      }
    }
  }

  private func progress(_ title: String) -> some View {
    Section {
      HStack {
        Text(title)
        Spacer()
        ProgressView()
      }
    }
  }

  private func failure(_ text: String, message: String, retry: @escaping () -> Void) -> some View {
    Section {
      Text(text)
        .foregroundStyle(Theme.textPrimary)
      Text(message)
        .font(.caption)
        .foregroundStyle(Theme.outflow)
      Button("Try Again", action: retry)
      Button("Keep using this \(device) only") {
        Task { await keepThisDevice() }
      }
    }
  }

  /// `server` comes from `flow.upload()` or `flow.adopt(_:)`, which return
  /// nil once the flow has been left.
  private func finish(with server: APISettings?) async {
    guard let server else {
      return
    }
    isFinishing = true
    await model.adoptServerConnection(server)
    isFinishing = false
  }

  private func keepThisDevice() async {
    if let server = flow.abandon() {
      isFinishing = true
      await model.discardServerSession(server)
      isFinishing = false
    }
    dismiss()
  }

  private static func count(_ value: Int, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
  }
}
