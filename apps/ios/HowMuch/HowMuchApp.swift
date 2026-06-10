import SwiftUI

@main
struct HowMuchApp: App {
  @State private var model = AppModel()
  @State private var showingSettings = false

  var body: some Scene {
    WindowGroup {
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
      .environment(model)
      .task(id: model.settings.connectionFingerprint) {
        await model.refreshAll()
      }
      .sheet(isPresented: $showingSettings) {
        SettingsView(settings: model.settings) { nextSettings in
          await model.applySettings(nextSettings)
        }
      }
    }
  }

  @ToolbarContentBuilder
  private var settingsToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Button {
        showingSettings = true
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
    }
  }
}
