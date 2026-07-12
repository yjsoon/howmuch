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
  static let addExpenseType = "local.howmuch.ios.add-expense"
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
        icon: UIApplicationShortcutIcon(systemImageName: "plus.circle.fill")
      )
    ]
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
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
  case categories
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

      Tab("Categories", systemImage: "square.grid.2x2", value: AppTab.categories) {
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
    .task(id: model.settings.connectionFingerprint) {
      await model.refreshAll()
    }
    .sheet(isPresented: $model.isShowingSettings) {
      SettingsView(settings: model.settings) { nextSettings in
        await model.applySettings(nextSettings)
      }
    }
    .sheet(isPresented: $model.isShowingCapture) {
      AddTransactionSheet()
    }
    .onAppear {
      if QuickAction.pendingCapture {
        QuickAction.pendingCapture = false
        model.isShowingCapture = true
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: QuickAction.notification)) { _ in
      // Warm launch: dismiss whatever sheet is up so capture can present.
      model.isShowingSettings = false
      model.isShowingCapture = true
    }
  }
}
