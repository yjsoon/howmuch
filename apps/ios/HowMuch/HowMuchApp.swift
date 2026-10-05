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

  static func handleOpenURL(_ url: URL) {
    if HowMuchDeepLink.parse(url) == .inbox {
      enqueueInboxCapture()
    }
  }
}

enum HowMuchDeepLink: Equatable {
  case launch
  case inbox

  static func parse(_ url: URL) -> HowMuchDeepLink? {
    guard url.scheme?.lowercased() == "howmuch" else {
      return nil
    }
    let host = (url.host ?? "").lowercased()
    if host == "inbox" {
      return .inbox
    }
    let path = url.path.lowercased().split(separator: "/").map(String.init)
    if path.first == "inbox" {
      return .inbox
    }
    return .launch
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
    for context in connectionOptions.urlContexts {
      QuickAction.handleOpenURL(context.url)
    }
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      QuickAction.handleOpenURL(context.url)
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

private struct RootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var chrome = RootChromeState()

  var body: some View {
    @Bindable var model = model
    @Bindable var capture = CaptureRouter.shared
    @Bindable var chrome = chrome
    @Bindable var workspace = CaptureWorkspace.shared

    RootTabView(chrome: chrome, usesSidebar: usesSidebar, workspace: workspace)
      .onChange(of: usesSidebar, initial: true) { _, sidebar in
      if sidebar {
        chrome.adoptSidebarLayout()
      } else {
        chrome.adoptCompactLayout()
      }
    }
    .onChange(of: chrome.captureSurface, initial: true) { _, surface in
      model.activeCaptureSurface = surface
    }
    .overlay(alignment: .bottomTrailing) {
      if usesSidebar {
        RootAddControl()
          .environment(chrome)
          .padding(RootChrome.addControlInsets(
            idiom: UIDevice.current.userInterfaceIdiom,
            horizontalSizeClass: horizontalSizeClass
          ))
      }
    }
    .overlay(alignment: .bottom) {
      if usesSidebar {
        RootSaveToastOverlay(
          bottomPadding: RootChrome.toastBottomPadding(
            idiom: UIDevice.current.userInterfaceIdiom,
            horizontalSizeClass: horizontalSizeClass
          )
        )
      }
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
    .task(id: model.launchRefreshTaskID) {
      // Local mode: finish any starter categories and enter due schedules
      // first, so the launch refresh shows them.
      await model.completeStarterCategories()
      await model.runLocalScheduledTransactions(refreshAfter: false)
      await model.refreshAll()
    }
    .overlay {
      if model.isShowingWelcome {
        WelcomeView()
          .accessibilityAddTraits(.isModal)
          .transition(.opacity)
      }
    }
    .animation(.default, value: model.isShowingWelcome)
    .sheet(isPresented: $model.isShowingSettings) {
      SettingsView(settings: model.settings) { nextSettings in
        await model.applySettings(nextSettings)
      }
      .environment(model)
      .interactiveDismissDisabled(!model.settings.isAuthenticated || model.isConnectingToServer)
      .blocksCapturePresentation()
      .howmuchFormSheet()
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
        Task { await model.runLocalScheduledTransactions() }
        model.sceneDidBecomeActive()
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
    .onOpenURL { url in
      guard HowMuchDeepLink.parse(url) == .inbox else {
        return
      }
      enqueueInboxIfNeeded(force: true)
    }
    .environment(chrome)
  }

  private var usesSidebar: Bool {
    RootChrome.usesSidebar(
      idiom: UIDevice.current.userInterfaceIdiom,
      horizontalSizeClass: horizontalSizeClass
    )
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

struct CaptureIntakeHost: View {
  @Environment(AppModel.self) private var model
  let request: CaptureRequest
  private let workspace: CaptureWorkspace
  @State private var session: CaptureSession?
  @State private var manualDraft: TransactionDraft?
  @State private var claimedInboxIDs: [UUID] = []
  @State private var isReadingInbox = false
  @State private var admissionError: String?
  @State private var didAdmit = false

  init(request: CaptureRequest, workspace: CaptureWorkspace = .shared) {
    self.request = request
    self.workspace = workspace
  }

  var body: some View {
    Group {
      if !didAdmit {
        admissionPlaceholder
      } else if let manualDraft {
        TransactionFormView(draft: manualDraft, isEditing: false, allowsDeletion: false)
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
        AddTransactionsView(session: session, workspace: workspace)
      } else {
        Theme.canvas
      }
    }
    .presentationDetents([.large])
    .howmuchFormSheet()
    .task(id: request.id) {
      claimedInboxIDs = []
      didAdmit = false
      await admitWhenReady()
    }
    .onDisappear {
      workspace.persistCurrentIfNeeded()
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
      // Only this path joins a run already in flight: it is a read of state
      // another path is already loading. A caller that just changed server
      // state (an import, a settings save) starts a fresh run instead.
      await model.refreshAll(joinInFlight: true)
    }
    // `refreshAll(joinInFlight: true)` joins the launch refresh when one is in
    // flight, so this wait only covers reference loads another path owns.
    waiting: while true {
      switch CaptureAdmissionGate.referenceWait(
        referencePhase: model.referencePhase,
        isRefreshingAll: model.isRefreshingAll
      ) {
      case .admit:
        break waiting
      case .stalled:
        guard !Task.isCancelled else {
          return
        }
        admissionError = CaptureAdmissionGate.stalledMessage
        return
      case .wait:
        try? await Task.sleep(for: .milliseconds(50))
        if Task.isCancelled {
          return
        }
      }
    }
    if Task.isCancelled {
      return
    }
    if let message = CaptureAdmissionGate.blockingError(
      referencePhase: model.referencePhase,
      hasAccounts: !model.accounts.isEmpty
    ) {
      admissionError = message
      return
    }
    guard CaptureRouter.shared.presented?.id == request.id else {
      return
    }
    let scopeKey = model.settings.viewPrefsScopeKey
    workspace.activate(scopeKey: scopeKey)
    guard CaptureAdmissionGate.shouldAdmitAfterRefresh(
      request: request,
      presented: CaptureRouter.shared.presented,
      isCancelled: Task.isCancelled,
      settingsScopeKey: scopeKey,
      workspaceScopeKey: workspace.activeScopeKey
    ) else {
      return
    }
    admitSession()
  }

  private func admitSession() {
    if case .manual(var draft) = request.kind {
      // A manual form never admits/replaces a conversation session. Preserve
      // explicit shortcut accounts; unresolved or closed picks need a choice.
      if !draft.accountID.isEmpty || request.origin == .presetDraft {
        if !model.openAccounts.contains(where: { $0.id == draft.accountID }) {
          draft.accountID = ""
        }
      } else {
        draft.accountID = CaptureAccountContext.resolve(
          origin: request.origin,
          openAccounts: model.openAccounts,
          lastUsedAccountID: model.lastUsedOpenAccountID
        ).selectedAccountID ?? ""
      }
      // Preserve an explicit transfer destination instead of inheriting it as the source.
      if draft.accountID == draft.transferAccountID {
        draft.accountID = ""
      }
      manualDraft = draft
      didAdmit = true
      admissionError = nil
      return
    }
    let admitted = workspace.admit(
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
    workspace.persistCurrentIfNeeded()
  }
}
