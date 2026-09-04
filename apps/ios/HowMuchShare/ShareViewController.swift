import UIKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    Task { await ingestAndComplete() }
  }

  private func ingestAndComplete() async {
    if let write = await firstPayload() {
      try? InboxStore.shared.write(write)
    }
    await openHost()
    await MainActor.run {
      extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
  }

  private func openHost() async {
    guard let url = URL(string: "howmuch://inbox") else {
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let finished = { continuation.resume() }
      if let context = extensionContext {
        context.open(url) { _ in
          finished()
        }
      } else {
        finished()
      }
    }
  }

  private func firstPayload() async -> InboxWrite? {
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    for item in items {
      for provider in item.attachments ?? [] {
        if let write = await textWrite(from: provider) {
          return write
        }
        if let write = await imageWrite(from: provider) {
          return write
        }
      }
    }
    return nil
  }

  private func textWrite(from provider: NSItemProvider) async -> InboxWrite? {
    let types = [UTType.plainText, .utf8PlainText, .text]
    for type in types {
      guard provider.hasItemConformingToTypeIdentifier(type.identifier) else {
        continue
      }
      guard let data = await loadData(from: provider, type: type) else {
        continue
      }
      guard !data.isEmpty, data.count <= InboxStore.maxPayloadBytes else {
        continue
      }
      return InboxWrite(
        source: .shareSheet,
        kind: .text,
        filename: "payload.txt",
        data: data
      )
    }
    return nil
  }

  private func imageWrite(from provider: NSItemProvider) async -> InboxWrite? {
    let types: [(UTType, String)] = [
      (.jpeg, "payload.jpg"),
      (.png, "payload.png"),
      (.heic, "payload.heic"),
      (.heif, "payload.heif"),
      (.webP, "payload.webp"),
      (.image, "payload.img"),
    ]
    for (type, filename) in types {
      guard provider.hasItemConformingToTypeIdentifier(type.identifier) else {
        continue
      }
      guard let data = await loadData(from: provider, type: type) else {
        continue
      }
      guard !data.isEmpty, data.count <= InboxStore.maxPayloadBytes else {
        continue
      }
      return InboxWrite(
        source: .shareSheet,
        kind: .image,
        filename: filename,
        data: data
      )
    }
    return nil
  }

  private func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
    if let data = await loadRepresentation(provider, type: type) {
      return data
    }
    return await loadItemData(provider, type: type)
  }

  private func loadRepresentation(_ provider: NSItemProvider, type: UTType) async -> Data? {
    await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
        continuation.resume(returning: data)
      }
    }
  }

  private func loadItemData(_ provider: NSItemProvider, type: UTType) async -> Data? {
    await withCheckedContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
        if let data = item as? Data {
          continuation.resume(returning: data)
          return
        }
        if let image = item as? UIImage {
          continuation.resume(returning: image.jpegData(compressionQuality: 0.92))
          return
        }
        if let url = item as? URL {
          continuation.resume(returning: try? Data(contentsOf: url))
          return
        }
        if let text = item as? String {
          continuation.resume(returning: Data(text.utf8))
          return
        }
        continuation.resume(returning: nil)
      }
    }
  }
}
