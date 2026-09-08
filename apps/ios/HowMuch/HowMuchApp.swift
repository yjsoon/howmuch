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
  case plan
  case reflect
  case add

  var captureSurface: CaptureSurface? {
    switch self {
    case .accounts:
      return .accounts
    case .rewards:
      return .rewards
    case .assistant:
      return .assistant
    case .plan:
      return .plan
    case .reflect:
      return .reflect
    case .add:
      return nil
    }
  }
}

private struct RootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
        AccountsView()
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

      Tab("Plan", systemImage: "square.grid.2x2", value: AppTab.plan) {
        NavigationStack {
          CategoriesView()
            .moreDestinations()
        }
      }
      .defaultVisibility(.hidden, for: .tabBar)

      Tab("Reflect", systemImage: "chart.bar.fill", value: AppTab.reflect) {
        NavigationStack {
          ReflectView()
            .moreDestinations()
        }
      }
      .defaultVisibility(.hidden, for: .tabBar)

      RootCaptureTab(addManually: { model.presentManualTransaction(origin: model.addTransactionsOrigin()) })
    }
    .tabViewStyle(.sidebarAdaptable)
    .defaultAdaptableTabBarPlacement(.sidebar)
    .tabBarMinimizeBehavior(.onScrollDown)
    .background {
      RootCaptureTabActions(addManually: { model.presentManualTransaction(origin: model.addTransactionsOrigin()) })
        .frame(width: 0, height: 0)
    }
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
            .padding(.bottom, horizontalSizeClass == .regular ? 28 : 90)
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
          .presentationDetents([.large])
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

struct RootCaptureTab: TabContent {
  let addManually: () -> Void

  var body: some TabContent<AppTab> {
    Tab("Add Transactions", systemImage: "plus.bubble", value: AppTab.add, role: .search) {
      Color.clear
    }
    .contextMenu {
      Button(action: addManually) {
        Label("Add manually", systemImage: "square.and.pencil")
      }
    }
  }
}

/// SwiftUI's TabContent menu serves the sidebar, not the iPhone tab bar.
/// Attach standard UIKit interactions to the semantically identified Add control.
struct RootCaptureTabActions: UIViewControllerRepresentable {
  let addManually: () -> Void

  func makeUIViewController(context: Context) -> Controller {
    let controller = Controller()
    controller.addManually = addManually
    return controller
  }

  func updateUIViewController(_ controller: Controller, context: Context) {
    controller.addManually = addManually
    controller.install()
  }

  static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
    controller.uninstall()
  }

  final class Controller: UIViewController, UIContextMenuInteractionDelegate {
    var addManually: () -> Void = {}
    private weak var target: UIControl?
    private var menuInteraction: UIContextMenuInteraction?
    private var manualAction: UIAccessibilityCustomAction?

    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      install()
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      install()
    }

    func install() {
      func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tab = controller as? UITabBarController { return tab }
        return controller.children.lazy.compactMap { tabController(in: $0) }.first
      }
      func addControl(in view: UIView) -> UIControl? {
        if let control = view as? UIControl, control.accessibilityLabel == "Add Transactions" {
          return control
        }
        return view.subviews.lazy.compactMap { addControl(in: $0) }.first
      }
      guard let root = view.window?.rootViewController,
            let tab = tabController(in: root),
            let control = addControl(in: tab.tabBar),
            control !== target else { return }
      uninstall()
      target = control
      let interaction = UIContextMenuInteraction(delegate: self)
      menuInteraction = interaction
      control.addInteraction(interaction)
      let action = UIAccessibilityCustomAction(name: "Add manually") { [weak self] _ in
        guard let self else { return false }
        self.addManually()
        return true
      }
      manualAction = action
      control.accessibilityCustomActions = (control.accessibilityCustomActions ?? []) + [action]
    }

    func uninstall() {
      if let menuInteraction { target?.removeInteraction(menuInteraction) }
      if let manualAction {
        target?.accessibilityCustomActions = target?.accessibilityCustomActions?.filter { $0 !== manualAction }
      }
      target = nil
      menuInteraction = nil
      manualAction = nil
    }

    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
        UIMenu(children: [
          UIAction(title: "Add manually", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
            self?.addManually()
          },
        ])
      }
    }
  }
}
