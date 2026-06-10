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
        RecentTransactionsView()
          .toolbar { appToolbar }
      }
      .tabItem {
        Label("Recents", systemImage: "list.bullet.rectangle.portrait")
      }

      NavigationStack {
        ReportsView()
          .toolbar { appToolbar }
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
    .sheet(isPresented: $model.isShowingCapture, onDismiss: model.captureDidDismiss) {
      NavigationStack {
        QuickEntryView()
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Done") {
                model.isShowingCapture = false
              }
            }
          }
      }
    }
  }

  @ToolbarContentBuilder
  private var appToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Button {
        model.isShowingCapture = true
      } label: {
        Label("Capture transaction", systemImage: "plus.circle.fill")
      }
      .tint(Theme.inflow)
    }

    ToolbarItem(placement: .topBarLeading) {
      Button {
        model.isShowingSettings = true
      } label: {
        Label("Connection settings", systemImage: "gearshape")
      }
    }
  }
}
