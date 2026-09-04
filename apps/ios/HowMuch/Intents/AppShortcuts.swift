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
    AppShortcut(
      intent: AddFromTextIntent(),
      phrases: [
        "Add from text in \(.applicationName)",
      ],
      shortTitle: "Add from Text",
      systemImageName: "text.alignleft"
    )
    AppShortcut(
      intent: AddFromImageIntent(),
      phrases: [
        "Add from an image in \(.applicationName)",
      ],
      shortTitle: "Add from Image",
      systemImageName: "photo"
    )
  }
}
