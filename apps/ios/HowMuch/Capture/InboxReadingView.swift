import SwiftUI
import UIKit
#if canImport(Vision)
import Vision
#endif

struct InboxReadingView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var store: InboxStore = .shared
  var onResolved: ([TransactionDraft]) -> Void
  var onClaimed: ([UUID]) -> Void = { _ in }

  @State private var thumbnail: UIImage?

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        if let thumbnail {
          Image(uiImage: thumbnail)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
          Image(systemName: "doc.text")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
        }
        Text("Stays on this device")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(Theme.canvas)
      .navigationTitle("Reading…")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .tint(Theme.accent)
        }
      }
      .task {
        await readInbox()
      }
    }
  }

  @MainActor
  private func readInbox() async {
    do {
      try store.claimInbox()
    } catch {
      onResolved([])
      return
    }
    let items = store.loadReading()
    onClaimed(items.map(\.id))
    thumbnail = items.compactMap(Self.thumbnail(for:)).first
    guard !items.isEmpty else {
      onResolved([])
      return
    }
    var mapped: [TransactionDraft] = []
    for item in items {
      mapped.append(contentsOf: await readDrafts(from: item))
    }
    if mapped.count == 1 {
      mapped[0].seedIfNeeded(
        accounts: model.openAccounts,
        preferredAccountID: model.preferredCaptureAccountID
      )
    }
    onResolved(mapped)
  }

  private func readDrafts(from item: InboxItem) async -> [TransactionDraft] {
    let text: String
    switch item.kind {
    case .text:
      text = item.payloadText()
    case .image:
      guard let data = try? item.payloadData() else {
        return []
      }
      text = await SlipImageText.recognize(data)
    }
    return await SlipReader.shared.read(
      text: text,
      accounts: model.openAccounts,
      categoryGroups: model.categoryGroups,
      payees: model.payees
    )
  }

  private static func thumbnail(for item: InboxItem) -> UIImage? {
    guard item.kind == .image, let data = try? item.payloadData() else {
      return nil
    }
    return UIImage(data: data)
  }
}

enum SlipImageText {
  static func recognize(_ data: Data) async -> String {
    #if canImport(Vision)
    await Task.detached(priority: .userInitiated) {
      guard let image = UIImage(data: data), let cgImage = image.cgImage else {
        return ""
      }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
      do {
        try handler.perform([request])
      } catch {
        return ""
      }
      let observations = request.results ?? []
      return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }.value
    #else
    return ""
    #endif
  }
}
