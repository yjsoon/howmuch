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
  static let notification = Notification.Name("HowMuch.QuickAction.addExpense")
  static var pendingCapture = false

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
    // Cold launch from the shortcut: RootView does not exist yet, so leave a
    // flag for it rather than posting into the void.
    if connectionOptions.shortcutItem?.type == QuickAction.addExpenseType {
      QuickAction.pendingCapture = true
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
    NotificationCenter.default.post(name: QuickAction.notification, object: nil)
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
  @State private var tab: AppTab = .accounts
  @State private var appliedReportsGeneration = 0

  var body: some View {
    @Bindable var model = model

    let selection = Binding(
      get: { tab },
      set: { (next: AppTab) in
        if next == .transaction {
          model.isShowingCapture = true
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
      if let message = model.lastSaveMessage {
        Text(message)
          .font(.footnote.weight(.medium))
          .foregroundStyle(Theme.textPrimary)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .glassEffect(.regular, in: .capsule)
          .padding(.bottom, 90)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: model.lastSaveMessage)
    .sensoryFeedback(trigger: model.lastSaveMessage) { _, newValue in
      newValue != nil ? .success : nil
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
      .onDisappear {
        consumePendingCapture()
      }
    }
    .sheet(isPresented: $model.isShowingCapture) {
      AddTransactionSheet()
    }
    .onAppear {
      consumePendingCapture()
    }
    .onReceive(NotificationCenter.default.publisher(for: QuickAction.notification)) { _ in
      guard !model.isShowingCapture else {
        return
      }
      if model.isShowingSettings {
        QuickAction.pendingCapture = true
        model.isShowingSettings = false
      } else {
        model.isShowingCapture = true
      }
    }
  }

  private func consumePendingCapture() {
    if QuickAction.pendingCapture {
      QuickAction.pendingCapture = false
      model.isShowingCapture = true
    }
  }
}

private struct ReflectVisitKey: Hashable {
  let tab: AppTab
  let generation: Int
}
