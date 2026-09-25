import SwiftUI
import UniformTypeIdentifiers

enum RewardsImportFile {
  /// Enough of a `rewards-account-config` card to preview before import.
  struct AccountConfigSummary: Equatable {
    let name: String
    let issuer: String
    let type: String
  }

  static func accountConfig(_ data: Data) throws -> AccountConfigSummary {
    let object = try object(data)
    guard object["format"] as? String == "rewards-account-config",
      let version = object["version"] as? NSNumber,
      CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
      let card = object["card"] as? [String: Any],
      let name = card["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let issuer = card["issuer"] as? String,
      let type = card["type"] as? String, ["cashback", "miles"].contains(type) else {
      throw APIClientError.validation("Choose a rewards-account-config version 1 file, not a whole-app settings export.")
    }
    return AccountConfigSummary(name: name, issuer: issuer, type: type)
  }

  static func wholeSettings(_ data: Data) throws -> [String: Any] {
    let object = try object(data)
    guard object["format"] == nil, object["card"] == nil else {
      throw APIClientError.validation("Use Import into one account for an account configuration file.")
    }
    return object
  }

  /// iOS smart punctuation turns JSON's straight double quotes into curly ones; undo that before decoding.
  /// Single curly quotes are left alone: they are valid apostrophes inside names, never JSON delimiters.
  static func pastedData(_ text: String) -> Data {
    let normalised = text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\u{201C}", with: "\"")
      .replacingOccurrences(of: "\u{201D}", with: "\"")
    return Data(normalised.utf8)
  }

  private static func object(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw APIClientError.validation("Choose a JSON object, not an array or a scalar.")
    }
    return object
  }
}

@Observable
final class RewardsAccountImportSelection {
  var accountID = ""
  var fileName: String?
  var data: Data?
  var summary: RewardsImportFile.AccountConfigSummary?
  var confirmation: Confirmation?
  var success: String?
  var error: String?
  var isImporting = false

  var sourceName: String? { summary?.name }

  struct Confirmation {
    let planID: String
    let accountID: String
    let accountName: String
    let sourceName: String
    let data: Data
  }

  func choose(data: Data, fileName: String) throws {
    clearFile()
    let summary = try RewardsImportFile.accountConfig(data)
    self.data = data
    self.fileName = fileName
    self.summary = summary
  }

  func choose(text: String) throws {
    try choose(data: RewardsImportFile.pastedData(text), fileName: "Pasted JSON")
  }

  func clearFile() {
    data = nil
    fileName = nil
    summary = nil
    confirmation = nil
    success = nil
    error = nil
  }

  func reset() {
    clearFile()
    accountID = ""
  }

  @MainActor
  func importAccount(_ confirmation: Confirmation, model: AppModel) async {
    guard !isImporting, confirmation.planID == model.settings.planID else { return }
    isImporting = true
    error = nil
    defer { isImporting = false }
    do {
      _ = try await model.apiClient.importRewardsAccountConfig(planID: confirmation.planID,
        accountID: confirmation.accountID, payloadJSON: confirmation.data)
      guard confirmation.planID == model.settings.planID else { return }
      clearFile()
      success = "Imported \(confirmation.sourceName) into \(confirmation.accountName)."
      await model.noteRewardsImport()
    } catch {
      guard confirmation.planID == model.settings.planID else { return }
      self.confirmation = nil
      self.error = error.localizedDescription
    }
  }
}

struct RewardsImportView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var accountImport: RewardsAccountImportSelection
  @State private var snapshot: RewardsTrackerSnapshot?
  @State private var phase: LoadPhase = .idle
  @State private var exportDocument: RewardsConfigurationDocument?
  @State private var isExporting = false
  @State private var exportBusy = false
  @State private var exportError: String?

  init(accountImport: RewardsAccountImportSelection = RewardsAccountImportSelection()) {
    _accountImport = State(initialValue: accountImport)
  }

  var body: some View {
    Form {
      Section("Import") {
        NavigationLink {
          RewardsAccountImportView(selection: accountImport)
        } label: {
          hubRow(icon: "creditcard", title: "Import into One Account",
            subtitle: "Replace one card's rewards set-up from JSON")
        }
        NavigationLink {
          RewardsBackupImportView()
        } label: {
          hubRow(icon: "arrow.counterclockwise.circle", title: "Restore Rewards Tracker Backup",
            subtitle: "Replaces all cards, rules and tag mappings")
        }
      }
      Section {
        Button {
          Task { await prepareExport() }
        } label: {
          Label("Export All Settings…", systemImage: "square.and.arrow.up")
        }
        .disabled(exportBusy)
      } header: {
        Text("Export")
      } footer: {
        Text("Excludes connection credentials and cached transactions.")
      }
      Section {
        NavigationLink {
          RewardsStoredCardsView(snapshot: snapshot, phase: phase, refresh: refreshSnapshot)
        } label: {
          HStack {
            Text("Stored Cards")
            Spacer()
            if let count = snapshot?.cards.count {
              Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .disabled(exportBusy)
    .navigationTitle("Import & Export")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") {
          dismiss()
        }
      }
    }
    .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json,
      defaultFilename: "howmuch-rewards-\(Date.now.isoDateString).json") { outcome in
      if case .failure(let error) = outcome { exportError = error.localizedDescription }
      exportDocument = nil
    }
    .alert("Could Not Export Settings", isPresented: Binding(
      get: { exportError != nil },
      set: { newValue in if !newValue { exportError = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(exportError ?? "")
    }
    .task(id: model.settings.planID) {
      await refreshSnapshot()
    }
    .onChange(of: model.rewardsRefreshGeneration) {
      Task { await refreshSnapshot() }
    }
    .onChange(of: model.settings.planID) {
      accountImport.reset()
      snapshot = nil
      phase = .idle
      exportDocument = nil
      isExporting = false
      exportError = nil
    }
  }

  private func hubRow(icon: String, title: String, subtitle: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(Theme.accent)
        .frame(width: 22)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func refreshSnapshot() async {
    let planID = model.settings.planID
    phase = .loading
    do {
      let next = try await model.apiClient.fetchRewardsTrackerSnapshot(planID: planID)
      guard planID == model.settings.planID else { return }
      snapshot = next
      phase = .loaded
    } catch {
      guard planID == model.settings.planID else { return }
      phase = .failed(error.localizedDescription)
    }
  }

  private func prepareExport() async {
    guard !exportBusy else { return }
    exportBusy = true
    exportError = nil
    defer { exportBusy = false }
    let planID = model.settings.planID
    do {
      let current = try await model.apiClient.fetchRewardsTrackerSnapshot(planID: planID)
      guard planID == model.settings.planID else { return }
      exportDocument = RewardsConfigurationDocument(data: try current.configurationData())
      snapshot = current
      isExporting = true
    } catch {
      guard planID == model.settings.planID else { return }
      exportError = error.localizedDescription
    }
  }
}

struct RewardsAccountImportView: View {
  @Environment(AppModel.self) private var model
  @Bindable var selection: RewardsAccountImportSelection
  @State private var isPicking = false
  @State private var pickerPlanID: String?

  private var destinationAccounts: [Account] {
    RewardCardAccounts.choices(accounts: model.accounts, takenIDs: [], keepingID: nil)
  }

  var body: some View {
    Form {
      Section {
        if destinationAccounts.isEmpty {
          Text("Add an open on-budget account first.").foregroundStyle(.secondary)
        } else {
          Picker("Account", selection: $selection.accountID) {
            Text("Choose an account").tag("")
            ForEach(destinationAccounts) { account in
              Text(account.name).tag(account.id)
            }
          }
          .pickerStyle(.menu)
          .disabled(selection.isImporting)
        }
      } header: {
        Text("Destination")
      }
      Section {
        Button("Choose File…") {
          pickerPlanID = model.settings.planID
          isPicking = true
        }
        LabeledContent("Paste JSON") {
          PasteButton(payloadType: String.self) { strings in
            guard let text = strings.first else { return }
            do {
              try selection.choose(text: text)
            } catch {
              selection.clearFile()
              selection.error = error.localizedDescription
            }
          }
        }
        if let summary = selection.summary {
          previewRow(summary)
        }
        if let error = selection.error {
          Text(error).foregroundStyle(Theme.outflow)
        }
      } header: {
        Text("Configuration")
      } footer: {
        Text("In Rewards Tracker, open Settings → Account Rewards Configuration, then View JSON and Copy. Use the same currency as the source; amounts are not converted.")
      }
      if let success = selection.success {
        Section {
          Text(success).foregroundStyle(.secondary)
        }
      }
    }
    .disabled(selection.isImporting)
    .navigationTitle("Import into One Account")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(selection.isImporting ? "Importing…" : "Import") {
          guard let account = destinationAccounts.first(where: { $0.id == selection.accountID }),
            let data = selection.data, let name = selection.sourceName else { return }
          selection.success = nil
          selection.error = nil
          selection.confirmation = .init(planID: model.settings.planID, accountID: account.id,
            accountName: account.name, sourceName: name, data: data)
        }
        .disabled(selection.isImporting || selection.data == nil
          || !destinationAccounts.contains { $0.id == selection.accountID })
      }
    }
    .fileImporter(isPresented: $isPicking, allowedContentTypes: [.json], allowsMultipleSelection: false) { outcome in
      guard pickerPlanID == model.settings.planID, !selection.isImporting else { return }
      choose(outcome)
    }
    .confirmationDialog(
      "Replace Rewards Configuration?",
      isPresented: Binding(
        get: { selection.confirmation != nil },
        set: { newValue in if !newValue { selection.confirmation = nil } }
      ),
      titleVisibility: .visible,
      presenting: selection.confirmation
    ) { confirmation in
      Button("Replace Configuration", role: .destructive) {
        Task { await selection.importAccount(confirmation, model: model) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { confirmation in
      Text("Import \(confirmation.sourceName) into \(confirmation.accountName). Existing limits, categories and tiers will be replaced, including clearing omitted fields. The account's name and featured setting stay unchanged.")
    }
    .onChange(of: model.settings.planID) {
      selection.reset()
      isPicking = false
      pickerPlanID = nil
    }
  }

  private func previewRow(_ summary: RewardsImportFile.AccountConfigSummary) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(summary.name).font(.headline)
      Text([summary.issuer, summary.type == "miles" ? "Miles" : "Cashback"].filter { !$0.isEmpty }.joined(separator: " · "))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .swipeActions {
      Button("Clear", role: .destructive) { selection.clearFile() }
    }
  }

  private func choose(_ outcome: Result<[URL], Error>) {
    do {
      guard let url = try outcome.get().first else { return }
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      try selection.choose(data: Data(contentsOf: url), fileName: url.lastPathComponent)
    } catch {
      let nsError = error as NSError
      if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError { return }
      selection.clearFile()
      selection.error = error.localizedDescription
    }
  }
}

struct RewardsBackupImportView: View {
  @Environment(AppModel.self) private var model
  @State private var isPicking = false
  @State private var pickerPlanID: String?
  @State private var fileName: String?
  @State private var payloadJSON: Data?
  @State private var busy = false
  @State private var confirming = false
  @State private var errorMessage: String?
  @State private var result: RewardsTrackerImportResult?

  var body: some View {
    Form {
      Section {
        Button("Choose Backup File…") {
          pickerPlanID = model.settings.planID
          isPicking = true
        }
        if let fileName {
          Text("Selected \(fileName)").foregroundStyle(.secondary)
        }
      } footer: {
        Text("Import a Rewards Tracker for YNAB settings export. Cards, rules and tag mappings are stored on this plan. Cached YNAB-shaped accounts and transactions in older dumps are upserted by their original IDs, so re-importing updates rather than duplicates them. This does not connect to live YNAB.")
      }

      if let errorMessage {
        Section {
          Text(errorMessage).foregroundStyle(Theme.outflow)
        }
      }

      if let result {
        Section("Imported") {
          count("Cards", result.cards)
          count("Rules", result.rules)
          count("Tag mappings", result.tagMappings)
          count("Accounts upserted", result.accountsUpserted)
          count("Transactions imported", result.transactionsImported)
          count("Transactions updated", result.transactionsUpdated)
          count("Flag names", result.flagNames)
        }
      }
    }
    .disabled(busy)
    .navigationTitle("Restore Backup")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(busy ? "Importing…" : "Import") {
          confirming = true
        }
        .disabled(busy || payloadJSON == nil)
      }
    }
    .confirmationDialog("Replace All Rewards Cards?", isPresented: $confirming, titleVisibility: .visible) {
      Button("Replace All Cards", role: .destructive) {
        Task { await importChosen() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Cards missing from the backup are removed. Miles valuation is replaced when the backup sets one.")
    }
    .fileImporter(isPresented: $isPicking, allowedContentTypes: [.json], allowsMultipleSelection: false) { outcome in
      guard pickerPlanID == model.settings.planID, !busy else { return }
      choose(outcome)
    }
    .onChange(of: model.settings.planID) {
      payloadJSON = nil
      fileName = nil
      result = nil
      errorMessage = nil
      isPicking = false
      pickerPlanID = nil
      confirming = false
    }
  }

  private func count(_ label: String, _ value: Int) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text("\(value)")
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
  }

  private func choose(_ outcome: Result<[URL], Error>) {
    switch outcome {
    case .failure(let error):
      let nsError = error as NSError
      if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
        return
      }
      errorMessage = error.localizedDescription
      result = nil
      payloadJSON = nil
      fileName = nil
    case .success(let urls):
      errorMessage = nil
      result = nil
      payloadJSON = nil
      fileName = nil
      guard let url = urls.first else {
        return
      }
      let accessed = url.startAccessingSecurityScopedResource()
      defer {
        if accessed {
          url.stopAccessingSecurityScopedResource()
        }
      }
      do {
        let data = try Data(contentsOf: url)
        _ = try RewardsImportFile.wholeSettings(data)
        payloadJSON = data
        fileName = url.lastPathComponent
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func importChosen() async {
    guard let payloadJSON, !busy else {
      return
    }
    busy = true
    errorMessage = nil
    result = nil
    let planID = model.settings.planID
    defer { busy = false }
    do {
      let imported = try await model.apiClient.importRewardsTracker(
        planID: planID,
        payloadJSON: payloadJSON
      )
      guard planID == model.settings.planID else { return }
      result = imported
      await model.noteRewardsImport()
    } catch {
      guard planID == model.settings.planID else { return }
      errorMessage = error.localizedDescription
    }
  }
}

struct RewardsStoredCardsView: View {
  let snapshot: RewardsTrackerSnapshot?
  let phase: LoadPhase
  let refresh: () async -> Void
  @State private var editorDestination: RewardCardEditorDestination?

  var body: some View {
    Form {
      Section {
        if phase == .loading && snapshot == nil {
          HStack {
            Text("Loading stored cards…")
            Spacer()
            ProgressView()
          }
        } else if let message = phase.errorMessage, snapshot == nil {
          Text(message)
            .foregroundStyle(Theme.outflow)
        } else if (snapshot?.cards ?? []).isEmpty {
          Text("No Rewards Tracker cards stored yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(snapshot?.cards ?? []) { card in
            Button {
              editorDestination = .edit(card.id)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                  .foregroundStyle(Theme.textPrimary)
                Text([card.issuer, card.type.rawValue].filter { !$0.isEmpty }.joined(separator: " · "))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(card.name)
          }
        }
      } footer: {
        if let count = snapshot?.cards.count {
          Text("\(count) stored")
        }
      }
    }
    .navigationTitle("Stored Cards")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $editorDestination, onDismiss: {
      Task { await refresh() }
    }) { destination in
      RewardCardEditorView(cardID: destination.cardID)
        .blocksCapturePresentation()
    }
  }
}

struct RewardsConfigurationDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
