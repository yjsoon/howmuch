import SwiftUI

@main
struct HowMuchApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .tint(Theme.accent)
    }
  }
}

enum AppTab: Hashable {
  case accounts
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
  }
}
