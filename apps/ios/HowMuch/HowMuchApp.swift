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

enum AppTab {
  case accounts
  case reflect
}

private struct RootView: View {
  @Environment(AppModel.self) private var model
  @State private var tab: AppTab = .accounts

  var body: some View {
    @Bindable var model = model

    TabView(selection: $tab) {
      NavigationStack {
        AccountsView()
      }
      .tag(AppTab.accounts)
      .toolbar(.hidden, for: .tabBar)

      NavigationStack {
        ReflectView()
      }
      .tag(AppTab.reflect)
      .toolbar(.hidden, for: .tabBar)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      YnabTabBar(selection: $tab) {
        model.isShowingCapture = true
      }
    }
    .overlay(alignment: .bottom) {
      if let message = model.lastSaveMessage {
        Text(message)
          .font(.footnote.weight(.medium))
          .foregroundStyle(.white)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(Theme.textPrimary.opacity(0.92), in: Capsule())
          .padding(.bottom, 86)
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

/// YNAB-style bottom bar: Accounts | + Transaction | Reflect.
private struct YnabTabBar: View {
  @Binding var selection: AppTab
  let onAddTransaction: () -> Void

  var body: some View {
    HStack(alignment: .bottom) {
      tabButton(.accounts, title: "Accounts", icon: "building.columns")

      Button(action: onAddTransaction) {
        VStack(spacing: 3) {
          ZStack {
            Circle()
              .fill(Theme.accent)
              .frame(width: 44, height: 44)
            Image(systemName: "plus")
              .font(.title3.weight(.semibold))
              .foregroundStyle(.white)
          }
          Text("Transaction")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Add transaction")

      tabButton(.reflect, title: "Reflect", icon: "chart.bar.fill")
    }
    .padding(.top, 8)
    .padding(.bottom, 2)
    .padding(.horizontal, 24)
    .background(
      Theme.card
        .shadow(color: .black.opacity(0.08), radius: 6, y: -2)
        .ignoresSafeArea(edges: .bottom)
    )
  }

  private func tabButton(_ value: AppTab, title: String, icon: String) -> some View {
    let isSelected = selection == value
    return Button {
      selection = value
    } label: {
      VStack(spacing: 4) {
        Image(systemName: icon)
          .font(.title3)
        Text(title)
          .font(.caption2)
      }
      .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
  }
}
