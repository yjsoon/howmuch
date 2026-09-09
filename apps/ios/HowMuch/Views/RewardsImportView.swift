import SwiftUI
import UniformTypeIdentifiers

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

  var body: some View {
    Form {
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
        Text("Export file")
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
      choose(outcome)
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
        _ = try JSONSerialization.jsonObject(with: data)
        payloadJSON = data
        fileName = url.lastPathComponent
      } catch {
        errorMessage = "That file is not valid JSON. Export settings from Rewards Tracker, then choose the .json file."
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
    defer { busy = false }
    do {
      let imported = try await model.apiClient.importRewardsTracker(
        planID: model.settings.planID,
        payloadJSON: payloadJSON
      )
      result = imported
      phase = .loaded
      await model.noteRewardsImport()
      await refreshSnapshot()
    } catch {
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
