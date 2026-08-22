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

/// Home-screen quick action ("Add Expense") plumbing. The shortcut is
/// registered dynamically — no Info.plist entry, which this project generates
/// from build settings — and the scene delegate relays taps into SwiftUI.
@MainActor
enum QuickAction {
  static let addExpenseType = "sg.soon.howmuch.add-expense"
  static let notification = Notification.Name("HowMuch.QuickAction.addExpense")

  /// Set when the app is cold-launched from the shortcut, before any SwiftUI
  /// view is subscribed to the notification; RootView consumes it on appear.
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

  var body: some View {
    @Bindable var model = model

    // The Transaction tab takes the search role, so Liquid Glass floats it
    // separately at the trailing edge. Selecting it opens the capture sheet
    // rather than switching tabs.
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
          ReflectView(isSelected: tab == .reflect)
        }
      }

      Tab("Transaction", systemImage: "plus", value: AppTab.transaction, role: .search) {
        // Never shown: selecting this tab presents the capture sheet instead.
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
    // A save (or delete) confirmation deserves a physical acknowledgement;
    // the toast clearing itself three seconds later does not.
    .sensoryFeedback(trigger: model.lastSaveMessage) { _, newValue in
      newValue != nil ? .success : nil
    }
    .task(id: model.settings.connectionFingerprint) {
      await model.refreshAll()
    }
    .sheet(isPresented: $model.isShowingSettings) {
      SettingsView(settings: model.settings) { nextSettings in
        await model.applySettings(nextSettings)
      }
      .interactiveDismissDisabled(!model.settings.isAuthenticated)
      // Runs once the dismissal has completed, so swapping to the capture
      // sheet cannot race the settings sheet's teardown.
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
        // Dismiss settings first; its onDisappear picks the capture back up.
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
