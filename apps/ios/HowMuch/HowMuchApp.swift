import SwiftUI
import UIKit

@main
struct HowMuchApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .tint(Theme.accent)
    }
  }
}

@MainActor
enum QuickAction {
  static let addExpenseType = "sg.soon.howmuch.add-expense"

  static func register() {
    UIApplication.shared.shortcutItems = [
      UIApplicationShortcutItem(
        type: addExpenseType,
        localizedTitle: "Add Expense",
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(type: .add),
        userInfo: nil
      )
    ]
  }

  static func enqueueBlankCapture() {
    CaptureRouter.shared.enqueue(
      CaptureRequest(kind: .blank, connectionFingerprint: nil, origin: .homeScreenShortcut)
    )
  }

  static func enqueueInboxCapture() {
    CaptureRouter.shared.enqueue(
      CaptureRequest(kind: .inbox, connectionFingerprint: nil, origin: .inbox)
    )
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    QuickAction.register()
    return true
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    configuration.delegateClass = QuickActionSceneDelegate.self
    return configuration
  }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    if connectionOptions.shortcutItem?.type == QuickAction.addExpenseType {
      QuickAction.enqueueBlankCapture()
    }
    if connectionOptions.urlContexts.contains(where: { $0.url.scheme == "howmuch" }) {
      QuickAction.enqueueInboxCapture()
    }
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if URLContexts.contains(where: { $0.url.scheme == "howmuch" }) {
      QuickAction.enqueueInboxCapture()
    }
  }

  func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    guard shortcutItem.type == QuickAction.addExpenseType else {
      completionHandler(false)
      return
    }
    QuickAction.enqueueBlankCapture()
    completionHandler(true)
  }
}

enum AppTab: Hashable {
  case accounts
  case rewards
  case assistant
  case add

  var captureSurface: CaptureSurface? {
    switch self {
    case .accounts:
      return .accounts
    case .rewards:
      return .rewards
    case .assistant:
      return .assistant
    case .add:
      return nil
    }
  }
}

private struct RootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @State private var tab: AppTab = .accounts

  var body: some View {
    @Bindable var model = model
    @Bindable var capture = CaptureRouter.shared
    @Bindable var workspace = CaptureWorkspace.shared

    let selection = Binding(
      get: { tab },
      set: { (next: AppTab) in
        if next == .add {
          model.presentAddTransactions(origin: model.addTransactionsOrigin())
        } else {
          tab = next
        }
      }
    )

    TabView(selection: selection) {
      Tab("Accounts", systemImage: "building.columns", value: AppTab.accounts) {
        NavigationStack {
          AccountsView()
        }
      }

      Tab("Rewards", systemImage: "creditcard", value: AppTab.rewards) {
        NavigationStack {
          RewardsView()
        }
      }

      Tab("Assistant", systemImage: "bubble.left.and.bubble.right", value: AppTab.assistant) {
        NavigationStack {
          AssistantView(workspace: workspace)
        }
      }

      Tab("Add Transactions", systemImage: "plus", value: AppTab.add, role: .search) {
        Color.clear
      }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
    .onChange(of: tab, initial: true) { _, next in
      if let surface = next.captureSurface {
        model.activeCaptureSurface = surface
      }
    }
    .overlay(alignment: .bottom) {
      Group {
        if let message = model.lastSaveMessage {
          Text(message.text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(message.kind == .failure ? Theme.outflow : Theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 90)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.snappy, value: model.lastSaveMessage?.id)
    }
    .sensoryFeedback(trigger: model.lastSaveMessage) { _, newValue in
      switch newValue?.kind {
      case .failure:
        return .error
      case .success:
        return .success
      case nil:
        return nil
      }
    }
    .task(id: model.settings.connectionFingerprint) {
      await model.refreshAll()
    }
    .sheet(isPresented: $model.isShowingSettings) {
      SettingsView(settings: model.settings) { nextSettings in
        await model.applySettings(nextSettings)
      }
      .environment(model)
      .interactiveDismissDisabled(!model.settings.isAuthenticated)
      .blocksCapturePresentation()
    }
    .sheet(item: $capture.presented) { request in
      CaptureIntakeHost(request: request)
        .id(request.id)
    }
    .onAppear {
      consumePendingCapture()
      enqueueInboxIfNeeded(force: false)
      ScreenshotOfferController.shared.startIfNeeded()
    }
    .onChange(of: capture.pending?.id) { _, _ in
      consumePendingCapture()
    }
    .onChange(of: capture.blockingSheetCount) { _, _ in
      consumePendingCapture()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        enqueueInboxIfNeeded(force: false)
        consumePendingCapture()
        ScreenshotOfferController.shared.startIfNeeded()
      } else if phase == .background {
        CaptureWorkspace.shared.persistCurrentIfNeeded()
      }
    }
    .onChange(of: model.settings.isAuthenticated) { _, isAuthenticated in
      if !isAuthenticated {
        capture.dropForSignOut()
      } else {
        enqueueInboxIfNeeded(force: false)
        consumePendingCapture()
      }
    }
    .onChange(of: workspace.shouldOpenAssistant) { _, shouldOpen in
      if shouldOpen {
        tab = .assistant
        workspace.shouldOpenAssistant = false
      }
    }
    .onOpenURL { url in
      guard url.scheme == "howmuch" else {
        return
      }
      enqueueInboxIfNeeded(force: true)
    }
  }

  private func consumePendingCapture() {
    CaptureRouter.shared.consume(
      isAuthenticated: model.settings.isAuthenticated,
      currentFingerprint: model.settings.connectionFingerprint
    )
  }

  private func enqueueInboxIfNeeded(force: Bool) {
    guard model.settings.isAuthenticated else {
      return
    }
    let store = InboxStore.shared
    if force {
      model.presentCapture(
        CaptureRequest(
          kind: .inbox,
          connectionFingerprint: model.settings.connectionFingerprint,
          origin: .inbox
        )
      )
      return
    }
    if store.hasReadyInboxItems() {
      model.presentCapture(
        CaptureRequest(
          kind: .inbox,
          connectionFingerprint: model.settings.connectionFingerprint,
          origin: .inbox
        )
      )
      return
    }
    if CaptureRouter.shared.presented == nil, store.hasReadingItems() {
      model.presentCapture(
        CaptureRequest(
          kind: .inbox,
          connectionFingerprint: model.settings.connectionFingerprint,
          origin: .inbox
        )
      )
    }
  }
}

private struct CaptureIntakeHost: View {
  @Environment(AppModel.self) private var model
  let request: CaptureRequest
  @State private var session: CaptureSession?
  @State private var claimedInboxIDs: [UUID] = []
  @State private var isReadingInbox = false
  @State private var admissionError: String?
  @State private var didAdmit = false

  var body: some View {
    Group {
      if !didAdmit {
        admissionPlaceholder
      } else if isReadingInbox {
        InboxReadingView(
          preferredAccountID: session?.selectedAccountID,
          onResolved: applyInboxDrafts,
          onAttachments: { attachments in
            for incoming in attachments {
              if session?.attachments.contains(where: { $0.id == incoming.id }) == true {
                session?.updateAttachment(incoming)
              } else {
                session?.addAttachment(incoming)
              }
            }
          },
          onClaimed: { claimedInboxIDs = $0 }
        )
      } else if let session {
        AddTransactionsView(session: session)
          .presentationDetents([.large])
      } else {
        Theme.canvas
      }
    }
    .task(id: request.id) {
      claimedInboxIDs = []
      didAdmit = false
      await admitWhenReady()
    }
    .onDisappear {
      CaptureWorkspace.shared.persistCurrentIfNeeded()
      if CaptureRouter.shared.presented == nil {
        InboxStore.shared.discardReading(ids: claimedInboxIDs)
        claimedInboxIDs = []
      }
    }
  }

  @ViewBuilder
  private var admissionPlaceholder: some View {
    VStack(spacing: 16) {
      if let admissionError {
        Text(admissionError)
          .font(.subheadline)
          .foregroundStyle(Theme.uncategorised)
          .multilineTextAlignment(.center)
        Button("Try again") {
          Task { await admitWhenReady(explicitRetry: true) }
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        Button("Continue without accounts") {
          admitSession()
        }
        .font(.subheadline.weight(.semibold))
      } else {
        ProgressView()
        Text("Loading accounts…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.canvas)
  }

  private func admitWhenReady(explicitRetry: Bool = false) async {
    admissionError = nil
    if CaptureAdmissionGate.shouldRefreshReference(phase: model.referencePhase, explicitRetry: explicitRetry) {
      await model.refreshAll()
    }
    while !CaptureAdmissionGate.canAdmit(referencePhase: model.referencePhase) {
      try? await Task.sleep(for: .milliseconds(50))
      if Task.isCancelled {
        return
      }
    }
    if Task.isCancelled {
      return
    }
    if case .failed(let message) = model.referencePhase {
      admissionError = message
      return
    }
    guard CaptureRouter.shared.presented?.id == request.id else {
      return
    }
    let scopeKey = model.settings.viewPrefsScopeKey
    CaptureWorkspace.shared.activate(scopeKey: scopeKey)
    guard CaptureAdmissionGate.shouldAdmitAfterRefresh(
      request: request,
      presented: CaptureRouter.shared.presented,
      isCancelled: Task.isCancelled,
      settingsScopeKey: scopeKey,
      workspaceScopeKey: CaptureWorkspace.shared.activeScopeKey
    ) else {
      return
    }
    admitSession()
  }

  private func admitSession() {
    let admitted = CaptureWorkspace.shared.admit(
      request: request,
      scopeKey: model.settings.viewPrefsScopeKey,
      openAccounts: model.openAccounts,
      lastUsedAccountID: model.lastUsedOpenAccountID,
      focusedRegisterAccountID: request.origin.ignoresVisibleRegister
        ? nil
        : model.visibleRegisterAccountID
    )
    session = admitted
    didAdmit = true
    admissionError = nil
    isReadingInbox = {
      if case .inbox = request.kind {
        return admitted.drafts.isEmpty && admitted.attachments.isEmpty
      }
      return false
    }()
  }

  private func applyInboxDrafts(_ drafts: [SlipMappedDraft]) {
    guard let session else {
      CaptureRouter.shared.presented = nil
      return
    }
    isReadingInbox = false
    session.claimedInboxIDs = claimedInboxIDs
    if drafts.isEmpty, session.drafts.isEmpty {
      session.recordFailedTurn("I could not read a spend from that share. Nothing was saved.")
      return
    }
    session.replaceDrafts(drafts.map { CaptureDraftItem(mapped: $0) })
    session.ownUnownedDrafts(as: "Added from a share")
    CaptureWorkspace.shared.persistCurrentIfNeeded()
  }
}
