import AppIntents

struct HowMuchShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AddTransactionIntent(),
      phrases: [
        "Add a transaction in \(.applicationName)",
      ],
      shortTitle: "Add Transaction",
      systemImageName: "plus"
    )
  }
}
