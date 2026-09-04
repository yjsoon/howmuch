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
      ZStack {
        Theme.canvas
        IntelligenceAura()
        VStack(spacing: 18) {
          Spacer()
          sourcePreview
          Text("Stays on this device")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.textPrimary.opacity(0.72))
          Spacer()
        }
        .padding(28)
      }
      .ignoresSafeArea()
      .navigationTitle("Reading…")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
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

  @ViewBuilder
  private var sourcePreview: some View {
    let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
    ZStack {
      IntelligenceHalo()
        .blur(radius: 18)
        .frame(width: 240, height: 240)
        .scaleEffect(1.15)
      if let thumbnail {
        Image(uiImage: thumbnail)
          .resizable()
          .scaledToFill()
          .frame(width: 168, height: 168)
          .clipShape(shape)
          .overlay {
            IntelligenceHalo()
              .mask(shape.stroke(lineWidth: 3))
          }
          .shadow(color: Color(red: 0.45, green: 0.38, blue: 0.95).opacity(0.35), radius: 24)
      } else {
        Circle()
          .fill(.ultraThinMaterial)
          .frame(width: 148, height: 148)
          .overlay {
            IntelligenceHalo()
              .mask(Circle().stroke(lineWidth: 4))
          }
          .overlay {
            Image(systemName: "doc.text")
              .font(.system(size: 36, weight: .medium))
              .foregroundStyle(Theme.textPrimary.opacity(0.78))
          }
          .shadow(color: Color(red: 0.45, green: 0.38, blue: 0.95).opacity(0.4), radius: 28)
      }
    }
    .accessibilityHidden(true)
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
