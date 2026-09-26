import SwiftUI
import UIKit
import ImageIO
#if canImport(Vision)
import Vision
#endif

struct InboxReadingView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Environment(\.displayScale) private var displayScale

  var store: InboxStore = .shared
  var preferredAccountID: String?
  var onResolved: ([SlipMappedDraft]) -> Void
  var onAttachments: ([CaptureAttachment]) -> Void = { _ in }
  var onClaimed: ([UUID]) -> Void = { _ in }

  @State private var thumbnail: UIImage?
  @State private var readingTask: Task<Void, Never>?

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
            readingTask?.cancel()
            dismiss()
          }
          .tint(Theme.accent)
        }
      }
      .task {
        let task = Task { await readInbox() }
        readingTask = task
        await withTaskCancellationHandler {
          await task.value
        } onCancel: {
          task.cancel()
        }
      }
      .onDisappear {
        readingTask?.cancel()
      }
    }
  }

  @ViewBuilder
  private var sourcePreview: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
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
          .transition(.scale(scale: 0.9).combined(with: .opacity))
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
          .transition(.scale(scale: 0.9).combined(with: .opacity))
      }
    }
    .animation(Theme.Motion.arrive, value: thumbnail != nil)
    .accessibilityHidden(true)
  }

  @MainActor
  private func readInbox() async {
    do {
      let store = store
      let items = try await inboxBackgroundWork {
        try store.claimInbox()
        try Task.checkCancellation()
        return store.loadReading()
      }
      try Task.checkCancellation()
      onClaimed(items.map(\.id))
      thumbnail = try await InboxPreview.firstThumbnail(in: items, displayScale: displayScale)
      try Task.checkCancellation()
      var mapped: [SlipMappedDraft] = []
      for item in items {
        try Task.checkCancellation()
        switch item.kind {
        case .image:
          guard let data = try await inboxBackgroundWork({ try? item.payloadData() }) else {
            continue
          }
          let attachmentID = UUID()
          onAttachments([
            CaptureAttachment(id: attachmentID, filename: item.filename, data: data, isReading: true)
          ])
          let text = await SlipImageText.recognize(data)
          onAttachments([
            CaptureAttachment(
              id: attachmentID,
              filename: item.filename,
              data: data,
              recognizedText: text,
              isReading: false,
              errorMessage: text.isEmpty ? "I could not read text from that image. It is still attached." : nil
            )
          ])
          mapped.append(contentsOf: await interpretDrafts(from: text))
        case .text:
          mapped.append(contentsOf: await interpretDrafts(from: item.payloadText()))
        }
      }
      try Task.checkCancellation()
      if mapped.count == 1, !mapped[0].parsedAccount {
        mapped[0].draft.seedIfNeeded(
          accounts: model.openAccounts,
          preferredAccountID: preferredAccountID
        )
      }
      onResolved(mapped)
    } catch is CancellationError {
      // The capture host owns item cleanup. Never deliver a result after dismissal.
    } catch {
      guard !Task.isCancelled else { return }
      onResolved([])
    }
  }

  @MainActor
  private func interpretDrafts(from text: String) async -> [SlipMappedDraft] {
    await SlipReader.shared.interpret(
      text: text,
      accounts: model.openAccounts,
      categoryGroups: model.categoryGroups,
      payees: model.payees
    )
  }
}

/// File-backed, orientation-correct previews; OCR continues to use the original payload.
enum InboxPreview {
  static func firstThumbnail(in items: [InboxItem], displayScale: CGFloat) async throws -> UIImage? {
    try await inboxBackgroundWork {
      let scale = displayScale.isFinite ? max(1, displayScale) : 1
      let maximumPixelSize = ceil(168 * scale)
      for item in items {
        try Task.checkCancellation()
        guard item.kind == .image else { continue }
        let image: UIImage? = autoreleasepool {
          guard let source = CGImageSourceCreateWithURL(
            item.payloadURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
          ), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
          ] as CFDictionary) else { return nil }
          return UIImage(cgImage: thumbnail, scale: scale, orientation: .up)
        }
        try Task.checkCancellation()
        if let image { return image }
      }
      return nil
    }
  }
}

/// Detached synchronous work must inherit cancellation explicitly, including cancellation
/// while an uninterruptible file read/decoder is running. Never deliver that stale result.
private func inboxBackgroundWork<Value: Sendable>(
  _ operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
  try Task.checkCancellation()
  let task = Task.detached(priority: .userInitiated) {
    try Task.checkCancellation()
    let value = try operation()
    try Task.checkCancellation()
    return value
  }
  return try await withTaskCancellationHandler {
    let value = try await task.value
    try Task.checkCancellation()
    return value
  } onCancel: {
    task.cancel()
  }
}

enum SlipImageText {
  static func recognize(_ data: Data) async -> String {
    #if canImport(Vision)
    return (try? await inboxBackgroundWork {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      let handler = VNImageRequestHandler(data: data, options: [:])
      try Task.checkCancellation()
      try handler.perform([request])
      try Task.checkCancellation()
      let observations = request.results ?? []
      return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }) ?? ""
    #else
    return ""
    #endif
  }
}
