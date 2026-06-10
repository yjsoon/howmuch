import SwiftUI

@main
struct HowMuchApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
    }
  }
}

private struct RootView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model

    TabView {
      NavigationStack {
        QuickEntryView()
          .toolbar { settingsToolbar }
      }
      .tabItem {
        Label("Capture", systemImage: "plus.circle.fill")
      }

      NavigationStack {
        RecentTransactionsView()
          .toolbar { settingsToolbar }
      }
      .tabItem {
        Label("Recents", systemImage: "list.bullet.rectangle.portrait")
      }

      NavigationStack {
        ReportsView()
          .toolbar { settingsToolbar }
      }
      .tabItem {
        Label("Reports", systemImage: "chart.bar.xaxis")
      }
    }
    .tint(Theme.inflow)
    .task(id: model.settings.connectionFingerprint) {
      await model.refreshAll()
    }
    .sheet(isPresented: $model.isShowingSettings) {
      SettingsView(settings: model.settings) { nextSettings in
        await model.applySettings(nextSettings)
      }
    }
  }

  @ToolbarContentBuilder
  private var settingsToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Button {
        model.isShowingSettings = true
      } label: {
        Label("Connection settings", systemImage: "gearshape")
      }
    }
  }
}
