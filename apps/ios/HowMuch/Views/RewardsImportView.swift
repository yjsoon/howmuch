import SwiftUI
import UniformTypeIdentifiers

enum RewardsImportFile {
  static func accountConfig(_ data: Data) throws -> String {
    let object = try object(data)
    guard object["format"] as? String == "rewards-account-config",
      let version = object["version"] as? NSNumber,
      CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
      let card = object["card"] as? [String: Any],
      let name = card["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      card["issuer"] is String, ["cashback", "miles"].contains(card["type"] as? String ?? "") else {
      throw APIClientError.validation("Choose a rewards-account-config version 1 file, not a whole-app settings export.")
    }
    return name
  }

  static func wholeSettings(_ data: Data) throws -> [String: Any] {
    let object = try object(data)
    guard object["format"] == nil, object["card"] == nil else {
      throw APIClientError.validation("Use Import into one account for an account configuration file.")
    }
    return object
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
  var sourceName: String?
  var confirmation: Confirmation?
  var success: String?
  var error: String?

  struct Confirmation {
    let planID: String
    let accountID: String
    let accountName: String
    let sourceName: String
    let data: Data
  }

  func choose(data: Data, fileName: String) throws {
    clearFile()
    let name = try RewardsImportFile.accountConfig(data)
    self.data = data
    self.fileName = fileName
    sourceName = name
  }

  func clearFile() {
    data = nil
    fileName = nil
    sourceName = nil
    confirmation = nil
    success = nil
    error = nil
  }

  func reset() {
    clearFile()
    accountID = ""
  }
}

struct RewardsImportView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var snapshot: RewardsTrackerSnapshot?
  @State private var phase: LoadPhase = .idle
  @State private var isPicking = false
  @State private var fileName: String?
  @State private var payloadJSON: Data?
  @State private var busy = false
  @State private var errorMessage: String?
  @State private var result: RewardsTrackerImportResult?
  @State private var editorDestination: RewardCardEditorDestination?
  @State private var exportDocument: RewardsConfigurationDocument?
  @State private var isExporting = false
  @State private var accountImport: RewardsAccountImportSelection
  @State private var pickingAccountConfig = false
  @State private var pickerPlanID: String?

  init(accountImport: RewardsAccountImportSelection = RewardsAccountImportSelection()) {
    _accountImport = State(initialValue: accountImport)
  }

  private var destinationAccounts: [Account] {
    RewardCardAccounts.choices(accounts: model.accounts, takenIDs: [], keepingID: nil)
  }

  var body: some View {
    Form {
      accountImportSection
      Section {
        Button("Export configuration JSON") {
          Task { await prepareExport() }
        }
        .disabled(busy)
      } footer: {
        Text("Exports current cards, rules, tag mappings and settings without connection credentials or cached transactions.")
      }
      Section {
        Button("Choose export") {
          pickerPlanID = model.settings.planID
          pickingAccountConfig = false
          isPicking = true
        }
        if let fileName {
          Text("Selected \(fileName)")
            .foregroundStyle(.secondary)
        }
        Button(busy ? "Importing…" : "Import export") {
          Task { await importChosen() }
        }
        .disabled(busy || payloadJSON == nil)
      } header: {
        Text("Whole-app settings import")
      } footer: {
        Text("Import a Rewards Tracker for YNAB settings export. Cards, rules, and tag mappings are stored on this plan. Cached YNAB-shaped accounts and transactions in older dumps are upserted by their original IDs, so running the import twice updates the same rows instead of duplicating them. This does not connect to live YNAB.")
      }

      Section {
        Text("Import replaces the stored card set.")
          .font(.headline)
        Text("Cards omitted from the export are soft-deleted. An empty cards array removes every HowMuch card. Miles valuation in the export replaces a native value when the export sets a finite number.")
          .foregroundStyle(.secondary)
      }

      if let errorMessage {
        Section {
          Text("Could not complete rewards import / export.")
            .font(.headline)
          Text(errorMessage)
            .foregroundStyle(Theme.outflow)
        }
      }

      if let result {
        Section("Imported this session") {
          count("Cards", result.cards)
          count("Rules", result.rules)
          count("Tag mappings", result.tagMappings)
          count("Accounts upserted", result.accountsUpserted)
          count("Transactions imported", result.transactionsImported)
          count("Transactions updated", result.transactionsUpdated)
          count("Flag names", result.flagNames)
        }
      }

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
      } header: {
        Text("Stored cards")
      } footer: {
        if let count = snapshot?.cards.count {
          Text("\(count) stored")
        }
      }
    }
    .disabled(busy || isExporting)
    .navigationTitle("Rewards import / export")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") {
          dismiss()
        }
      }
    }
    .fileImporter(isPresented: $isPicking, allowedContentTypes: [.json], allowsMultipleSelection: false) { outcome in
      guard pickerPlanID == model.settings.planID, !busy else { return }
      if pickingAccountConfig { chooseAccount(outcome) } else { choose(outcome) }
    }
    .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json,
      defaultFilename: "howmuch-rewards-\(Date.now.isoDateString).json") { outcome in
      if case .failure(let error) = outcome { errorMessage = error.localizedDescription }
      exportDocument = nil
    }
    .sheet(item: $editorDestination, onDismiss: {
      Task { await refreshSnapshot() }
    }) { destination in
      RewardCardEditorView(cardID: destination.cardID)
        .blocksCapturePresentation()
    }
    .task(id: model.settings.planID) {
      await refreshSnapshot()
    }
    .onChange(of: model.settings.planID) {
      accountImport.reset()
      payloadJSON = nil
      fileName = nil
      result = nil
      errorMessage = nil
      snapshot = nil
      editorDestination = nil
      exportDocument = nil
      isExporting = false
      isPicking = false
      pickerPlanID = nil
    }
  }

  private var accountImportSection: some View {
    @Bindable var selection = accountImport
    return Section {
      Picker("Destination account", selection: $selection.accountID) {
        Text("Choose an account").tag("")
        ForEach(destinationAccounts) { account in
          Text(account.name).tag(account.id)
        }
      }
      .disabled(accountImport.confirmation != nil)
      Button("Choose account JSON") {
        pickerPlanID = model.settings.planID
        pickingAccountConfig = true
        isPicking = true
      }
      if let fileName = accountImport.fileName {
        Text("Selected \(fileName)").foregroundStyle(.secondary)
      }
      if let confirmation = accountImport.confirmation {
        Text("Replace rewards configuration?").font(.headline)
        Text("Import \(confirmation.sourceName) into \(confirmation.accountName). Existing limits, categories and tiers will be replaced, including clearing omitted fields. The destination name and featured preference stay unchanged.")
        Button(busy ? "Importing…" : "Replace account configuration", role: .destructive) {
          Task { await importAccount(confirmation) }
        }
        Button("Cancel", role: .cancel) { accountImport.confirmation = nil }
      } else {
        Button(busy ? "Working…" : "Review account import") {
          guard let account = destinationAccounts.first(where: { $0.id == accountImport.accountID }),
            let data = accountImport.data, let name = accountImport.sourceName else { return }
          accountImport.success = nil
          accountImport.error = nil
          accountImport.confirmation = .init(planID: model.settings.planID, accountID: account.id,
            accountName: account.name, sourceName: name, data: data)
        }
        .disabled(accountImport.data == nil || !destinationAccounts.contains { $0.id == accountImport.accountID })
      }
      if let success = accountImport.success { Text(success).foregroundStyle(.secondary) }
      if let error = accountImport.error { Text(error).foregroundStyle(Theme.outflow) }
      if destinationAccounts.isEmpty { Text("Add an open on-budget account first.").foregroundStyle(.secondary) }
    } header: {
      Text("Import into one account")
    } footer: {
      Text("Only this account’s rewards configuration changes. Other cards, settings and transactions stay unchanged. Use the same currency as the source; amounts are not converted.")
    }
  }

  private func chooseAccount(_ outcome: Result<[URL], Error>) {
    do {
      guard let url = try outcome.get().first else { return }
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      accountImport.clearFile()
      try accountImport.choose(data: Data(contentsOf: url), fileName: url.lastPathComponent)
    } catch {
      let nsError = error as NSError
      if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError { return }
      accountImport.clearFile()
      accountImport.error = error.localizedDescription
    }
  }

  private func importAccount(_ confirmation: RewardsAccountImportSelection.Confirmation) async {
    guard !busy, confirmation.planID == model.settings.planID else { return }
    busy = true
    accountImport.error = nil
    defer { busy = false }
    do {
      _ = try await model.apiClient.importRewardsAccountConfig(planID: confirmation.planID,
        accountID: confirmation.accountID, payloadJSON: confirmation.data)
      guard confirmation.planID == model.settings.planID else { return }
      accountImport.clearFile()
      accountImport.success = "Imported \(confirmation.sourceName) into \(confirmation.accountName)."
      await model.noteRewardsImport()
      await refreshSnapshot()
    } catch {
      guard confirmation.planID == model.settings.planID else { return }
      accountImport.confirmation = nil
      accountImport.error = error.localizedDescription
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
      phase = .loaded
      await model.noteRewardsImport()
      await refreshSnapshot()
    } catch {
      guard planID == model.settings.planID else { return }
      let message = error.localizedDescription
      errorMessage = message
      phase = .failed(message)
    }
  }

  private func refreshSnapshot() async {
    let planID = model.settings.planID
    phase = .loading
    do {
      let next = try await model.apiClient.fetchRewardsTrackerSnapshot(planID: planID)
      guard planID == model.settings.planID else {
        return
      }
      snapshot = next
      phase = .loaded
    } catch {
      guard planID == model.settings.planID else {
        return
      }
      phase = .failed(error.localizedDescription)
    }
  }

  private func prepareExport() async {
    guard !busy else { return }
    busy = true
    errorMessage = nil
    defer { busy = false }
    let planID = model.settings.planID
    do {
      let current = try await model.apiClient.fetchRewardsTrackerSnapshot(planID: planID)
      guard planID == model.settings.planID else { return }
      exportDocument = RewardsConfigurationDocument(data: try current.configurationData())
      snapshot = current
      isExporting = true
    } catch {
      guard planID == model.settings.planID else { return }
      errorMessage = error.localizedDescription
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
