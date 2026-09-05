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
      CaptureRequest(kind: .blank, connectionFingerprint: nil)
    )
  }

  static func enqueueInboxCapture() {
    CaptureRouter.shared.enqueue(
      CaptureRequest(kind: .inbox, connectionFingerprint: nil)
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
  case plan
  case reflect
  case transaction
}

private struct RootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @State private var tab: AppTab = .accounts
  @State private var appliedReportsGeneration = 0

  var body: some View {
    @Bindable var model = model
    @Bindable var capture = CaptureRouter.shared

    let selection = Binding(
      get: { tab },
      set: { (next: AppTab) in
        if next == .transaction {
          model.presentCapture(
            CaptureRequest(
              kind: .blank,
              connectionFingerprint: model.settings.connectionFingerprint
            )
          )
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

      Tab("Plan", systemImage: "square.grid.2x2", value: AppTab.plan) {
        NavigationStack {
          CategoriesView()
        }
      }

      Tab("Reflect", systemImage: "chart.bar.fill", value: AppTab.reflect) {
        NavigationStack {
          ReflectView()
        }
      }

      Tab("Transaction", systemImage: "plus", value: AppTab.transaction, role: .search) {
        Color.clear
      }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
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
    .task(id: ReflectVisitKey(tab: tab, generation: model.reportsRefreshGeneration)) {
      guard tab == .reflect else {
        return
      }
      let generation = model.reportsRefreshGeneration
      guard generation > appliedReportsGeneration else {
        return
      }
      if await model.refreshReflectOverview(quiet: true) {
        appliedReportsGeneration = generation
      }
    }
    .sheet(isPresented: $model.isShowingSettings) {
      SettingsView(settings: model.settings) { nextSettings in
        await model.applySettings(nextSettings)
      }
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
          connectionFingerprint: model.settings.connectionFingerprint
        )
      )
      return
    }
    if store.hasReadyInboxItems() {
      model.presentCapture(
        CaptureRequest(
          kind: .inbox,
          connectionFingerprint: model.settings.connectionFingerprint
        )
      )
      return
    }
    if CaptureRouter.shared.presented == nil, store.hasReadingItems() {
      model.presentCapture(
        CaptureRequest(
          kind: .inbox,
          connectionFingerprint: model.settings.connectionFingerprint
        )
      )
    }
  }
}

private struct CaptureIntakeHost: View {
  @Environment(AppModel.self) private var model
  let request: CaptureRequest
  @State private var reviewDrafts: [TransactionDraft]?
  @State private var inboxDraft: TransactionDraft?
  @State private var claimedInboxIDs: [UUID] = []

  var body: some View {
    Group {
      if let reviewDrafts {
        IntakeReviewListView(
          drafts: reviewDrafts,
          preferredAccountID: model.preferredCaptureAccountID
        )
      } else if case .inbox = request.kind, inboxDraft == nil {
        InboxReadingView(
          onResolved: applyInboxDrafts,
          onClaimed: { claimedInboxIDs = $0 }
        )
      } else {
        AddTransactionSheet(request: formRequest) { drafts in
          reviewDrafts = drafts
        }
      }
    }
    .onChange(of: request.id) { _, _ in
      reviewDrafts = nil
      inboxDraft = nil
      claimedInboxIDs = []
    }
    .onDisappear {
      if CaptureRouter.shared.presented == nil {
        InboxStore.shared.discardReading(ids: claimedInboxIDs)
        claimedInboxIDs = []
      }
    }
  }

  private var formRequest: CaptureRequest {
    if let inboxDraft {
      return CaptureRequest(
        id: request.id,
        kind: .draft(inboxDraft),
        connectionFingerprint: request.connectionFingerprint
      )
    }
    return request
  }

  private func applyInboxDrafts(_ drafts: [TransactionDraft]) {
    if drafts.count > 1 {
      reviewDrafts = drafts
    } else if let only = drafts.first {
      inboxDraft = only
    } else {
      CaptureRouter.shared.presented = nil
    }
  }
}

private struct ReflectVisitKey: Hashable {
  let tab: AppTab
  let generation: Int
}
