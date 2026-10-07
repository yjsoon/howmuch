import UIKit
import UniformTypeIdentifiers
import ImageIO
import PDFKit
import CryptoKit

struct ShareLoadedItem: Identifiable, @unchecked Sendable {
  let id = UUID()
  var kind: InboxPayloadKind
  var filename: String
  var fileURL: URL
  var bytes: Int
  var sha256: String
  var pageCount: Int?
  var thumbnail: CGImage?

  var exceedsFileLimit: Bool {
    bytes > InboxStore.maxPayloadBytes
  }
}

struct ShareLoadResult: @unchecked Sendable {
  var items: [ShareLoadedItem]
  var unsupportedCount: Int
}

/// Copies shared items to temp files and derives thumbnails and hashes from the
/// files. Full images are never decoded: the extension has roughly 120 MB.
@MainActor
final class ShareItemLoader {
  let directory: URL
  private let thumbnailPoints: CGFloat = 72

  init(directory: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ShareIntake-\(UUID().uuidString)", isDirectory: true)) {
    self.directory = directory
  }

  func load(from inputItems: [NSExtensionItem], displayScale: CGFloat) async -> ShareLoadResult {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let scale = displayScale.isFinite ? max(1, displayScale) : 2
    var items: [ShareLoadedItem] = []
    var unsupported = 0
    for input in inputItems {
      for provider in input.attachments ?? [] {
        if let item = await loadItem(from: provider, scale: scale) {
          items.append(item)
        } else {
          unsupported += 1
        }
      }
    }
    return ShareLoadResult(items: items, unsupportedCount: unsupported)
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
  }

  private enum Acquired: Sendable {
    case file(URL)
    case oversize(Int)
    case failed
  }

  private func loadItem(from provider: NSItemProvider, scale: CGFloat) async -> ShareLoadedItem? {
    let pixels = ceil(thumbnailPoints * scale)
    let candidates: [(UTType, InboxPayloadKind, String)] = [
      (.pdf, .pdf, "pdf"),
      (.image, .image, "img"),
    ]
    for (type, kind, fallbackExtension) in candidates
    where provider.hasItemConformingToTypeIdentifier(type.identifier) {
      switch await acquire(from: provider, type: type, fallbackExtension: fallbackExtension) {
      case .file(let url):
        return await Task.detached {
          Self.describe(url: url, kind: kind, pixels: pixels)
        }.value
      case .oversize(let bytes):
        return ShareLoadedItem(
          kind: kind,
          filename: "oversize",
          fileURL: directory.appendingPathComponent("oversize"),
          bytes: bytes,
          sha256: ""
        )
      case .failed:
        return nil
      }
    }
    for type in [UTType.plainText, .utf8PlainText, .text] {
      guard provider.hasItemConformingToTypeIdentifier(type.identifier) else {
        continue
      }
      guard let url = await writeText(from: provider, type: type) else {
        continue
      }
      return await Task.detached {
        Self.describe(url: url, kind: .text, pixels: pixels)
      }.value
    }
    return nil
  }

  private func acquire(
    from provider: NSItemProvider, type: UTType, fallbackExtension: String
  ) async -> Acquired {
    let direct = await copyFile(from: provider, type: type, fallbackExtension: fallbackExtension)
    if case .failed = direct {
      return await copyViaLoadItem(from: provider, type: type, fallbackExtension: fallbackExtension)
    }
    return direct
  }

  private func copyFile(
    from provider: NSItemProvider, type: UTType, fallbackExtension: String
  ) async -> Acquired {
    let directory = directory
    return await withCheckedContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        guard let url else {
          continuation.resume(returning: .failed)
          return
        }
        continuation.resume(returning: Self.place(
          fileAt: url, in: directory, fallbackExtension: fallbackExtension
        ))
      }
    }
  }

  private func copyViaLoadItem(
    from provider: NSItemProvider, type: UTType, fallbackExtension: String
  ) async -> Acquired {
    let directory = directory
    return await withCheckedContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
        if let url = item as? URL, url.isFileURL {
          continuation.resume(returning: Self.place(
            fileAt: url, in: directory, fallbackExtension: fallbackExtension
          ))
        } else if let data = item as? Data {
          continuation.resume(returning: Self.place(
            data: data, in: directory, fileExtension: fallbackExtension
          ))
        } else if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
          continuation.resume(returning: Self.place(data: data, in: directory, fileExtension: "jpg"))
        } else {
          continuation.resume(returning: .failed)
        }
      }
    }
  }

  nonisolated private static func place(
    fileAt url: URL, in directory: URL, fallbackExtension: String
  ) -> Acquired {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    if size > InboxStore.maxPayloadBytes {
      return .oversize(size)
    }
    let ext = url.pathExtension.isEmpty ? fallbackExtension : url.pathExtension
    let destination = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    do {
      try FileManager.default.copyItem(at: url, to: destination)
      return .file(destination)
    } catch {
      return .failed
    }
  }

  nonisolated private static func place(
    data: Data, in directory: URL, fileExtension: String
  ) -> Acquired {
    guard !data.isEmpty else {
      return .failed
    }
    if data.count > InboxStore.maxPayloadBytes {
      return .oversize(data.count)
    }
    let destination = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
    do {
      try data.write(to: destination, options: .atomic)
      return .file(destination)
    } catch {
      return .failed
    }
  }

  private func writeText(from provider: NSItemProvider, type: UTType) async -> URL? {
    let directory = directory
    return await withCheckedContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
        var data: Data?
        if let text = item as? String {
          data = Data(text.utf8)
        } else if let raw = item as? Data {
          data = raw
        } else if let url = item as? URL, url.isFileURL {
          data = try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard let data, !data.isEmpty else {
          continuation.resume(returning: nil)
          return
        }
        let destination = directory.appendingPathComponent("\(UUID().uuidString).txt")
        do {
          try data.write(to: destination, options: .atomic)
          continuation.resume(returning: destination)
        } catch {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  nonisolated private static func describe(
    url: URL, kind: InboxPayloadKind, pixels: CGFloat
  ) -> ShareLoadedItem? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0, let hash = sha256Hex(of: url) else {
      return nil
    }
    var thumbnail: CGImage?
    var pages: Int?
    switch kind {
    case .image:
      thumbnail = imageThumbnail(url: url, pixels: pixels)
    case .pdf:
      if let document = PDFDocument(url: url) {
        pages = document.pageCount
        if let page = document.page(at: 0) {
          thumbnail = page.thumbnail(of: CGSize(width: pixels, height: pixels), for: .cropBox).cgImage
        }
      }
    case .text:
      break
    }
    return ShareLoadedItem(
      kind: kind,
      filename: url.lastPathComponent,
      fileURL: url,
      bytes: size,
      sha256: hash,
      pageCount: pages,
      thumbnail: thumbnail
    )
  }

  nonisolated private static func imageThumbnail(url: URL, pixels: CGFloat) -> CGImage? {
    autoreleasepool { () -> CGImage? in
      guard let source = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
      ) else {
        return nil
      }
      return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: pixels,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary)
    }
  }

  nonisolated static func sha256Hex(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      return nil
    }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk: Data? = autoreleasepool { () -> Data? in
        try? handle.read(upToCount: 1_048_576)
      }
      guard let chunk, !chunk.isEmpty else {
        break
      }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// SHA-256 over the sorted per-source hashes, so source order does not matter.
  nonisolated static func contentHash(of items: [ShareLoadedItem]) -> String {
    let joined = items.map(\.sha256).sorted().joined(separator: "\n")
    return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
