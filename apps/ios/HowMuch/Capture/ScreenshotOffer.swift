import CryptoKit
import Darwin
import Observation
import SwiftUI
import UIKit
#if canImport(Vision)
import Vision
#endif

struct ScreenshotOffer: Equatable, Identifiable, Sendable {
  var id: String
  var lineCount: Int
  var imageData: Data
  var filename: String

  var caption: String {
    let noun = lineCount == 1 ? "line" : "lines"
    return "Clipboard image · \(lineCount) \(noun)"
  }
}

@MainActor
protocol ClipboardImageSource: AnyObject {
  var changeCount: Int { get }
  var hasImages: Bool { get }
  var notificationObject: AnyObject? { get }
  func imageData() -> Data?
}

@MainActor
final class PasteboardImageSource: ClipboardImageSource {
  private let pasteboard: UIPasteboard

  init(pasteboard: UIPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  var changeCount: Int { pasteboard.changeCount }
  var hasImages: Bool { pasteboard.hasImages }
  var notificationObject: AnyObject? { pasteboard }

  func imageData() -> Data? {
    // .image is the first item's image, unlike .images (which searches all items).
    // This is a programmatic paste and iOS may ask for permission.
    pasteboard.image?.pngData()
  }
}

enum ClipboardOfferEpoch {
  // Cached once per process. A denied probe must not mistake a later process
  // for the same boot: it may offer/prompt again after relaunch instead.
  private static let processFallback = "process:\(UUID().uuidString)"
  static let current = resolve(readBootSessionUUID())

  static func resolve(_ bootSessionUUID: String?) -> String {
    bootSessionUUID.map { "boot:\($0)" } ?? processFallback
  }

  static func readBootSessionUUID() -> String? {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
      size > 0, size <= 128
    else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    let result = buffer.withUnsafeMutableBytes {
      sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &size, nil, 0)
    }
    guard result == 0,
      let value = String(bytes: buffer.prefix(while: { $0 != 0 }), encoding: .utf8),
      let uuid = UUID(uuidString: value)
    else { return nil }
    return uuid.uuidString
  }
}

@MainActor
@Observable
final class ScreenshotOfferController {
  static let shared = ScreenshotOfferController()

  // Photos permission must never migrate into clipboard permission.
  static let enabledKey = "HowMuch.clipboardOffer.enabled"
  static let suppressedRevisionKey = "HowMuch.clipboardOffer.suppressedRevision"
  static let dismissedKey = "HowMuch.clipboardOffer.dismissedID"
  static let epochKey = "HowMuch.clipboardOffer.epoch"

  private(set) var isEnabled: Bool
  private(set) var offer: ScreenshotOffer?

  private let defaults: UserDefaults
  private let clipboard: ClipboardImageSource
  private let lineCounter: @Sendable (Data) -> Int
  private var observers: [NSObjectProtocol] = []
  private var generation = 0
  private var lastCheckedRevision: Int?
  private var offeredRevision: Int?

  init(
    defaults: UserDefaults = .standard,
    clipboard: ClipboardImageSource? = nil,
    epoch: String? = nil,
    lineCounter: @escaping @Sendable (Data) -> Int = { ScreenshotOfferController.countLines(in: $0) }
  ) {
    self.defaults = defaults
    self.clipboard = clipboard ?? PasteboardImageSource()
    self.lineCounter = lineCounter
    isEnabled = defaults.bool(forKey: Self.enabledKey)

    // changeCount restarts after reboot. Keep the epoch only in local defaults,
    // never in offer IDs or Inbox payloads. Missing epochs also invalidate legacy state.
    let epoch = epoch ?? ClipboardOfferEpoch.current
    if defaults.string(forKey: Self.epochKey) != epoch {
      defaults.removeObject(forKey: Self.suppressedRevisionKey)
      defaults.removeObject(forKey: Self.dismissedKey)
      defaults.set(epoch, forKey: Self.epochKey)
    }
  }

  isolated deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  func applyEnabledPreference(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    generation += 1
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
    offer = nil
    offeredRevision = nil
    lastCheckedRevision = nil
    if enabled {
      startObserving()
    } else {
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      observers.removeAll()
    }
  }

  func setEnabled(_ enabled: Bool) async {
    applyEnabledPreference(enabled)
    await refresh()
  }

  func startIfNeeded() {
    guard isEnabled else { return }
    startObserving()
    Task { await refresh() }
  }

  func refresh() async {
    // Even availability/revision checks stay behind explicit opt-in.
    guard isEnabled else { return }
    let revision = clipboard.changeCount
    guard lastCheckedRevision != revision else { return }
    generation += 1
    let currentGeneration = generation
    lastCheckedRevision = revision
    offeredRevision = nil
    offer = nil

    // Persist non-actionable/denied reads and dismissals so foreground/relaunch
    // never repeatedly asks to paste an unchanged clipboard.
    guard defaults.object(forKey: Self.suppressedRevisionKey) as? Int != revision else { return }
    defaults.set(revision, forKey: Self.suppressedRevisionKey)
    guard clipboard.hasImages, let data = clipboard.imageData(),
      clipboard.changeCount == revision,
      !data.isEmpty, data.count <= InboxStore.maxPayloadBytes
    else { return }

    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let id = "\(revision):\(digest)"
    guard defaults.string(forKey: Self.dismissedKey) != id else { return }
    defaults.removeObject(forKey: Self.suppressedRevisionKey)
    let lines = await Task.detached(priority: .utility) { [lineCounter] in
      max(1, lineCounter(data))
    }.value
    guard isEnabled, generation == currentGeneration, clipboard.changeCount == revision else { return }
    offeredRevision = revision
    offer = ScreenshotOffer(id: id, lineCount: lines, imageData: data, filename: "payload.png")
  }

  func dismiss() {
    guard let offer, let revision = offeredRevision else { return }
    generation += 1
    defaults.set(offer.id, forKey: Self.dismissedKey)
    defaults.set(revision, forKey: Self.suppressedRevisionKey)
    self.offer = nil
    offeredRevision = nil
  }

  func review() throws {
    guard isEnabled, let offer, let revision = offeredRevision else { return }
    // The pasteboard may have changed before its notification was delivered.
    guard clipboard.changeCount == revision else {
      generation += 1
      self.offer = nil
      offeredRevision = nil
      return
    }
    let write = try InboxIntentHandoff.imageWrite(
      offer.imageData,
      filename: offer.filename,
      source: .detectedScreenshot
    )
    try InboxIntentHandoff.enqueue(write)
    dismiss()
  }

  nonisolated static func countLines(in data: Data) -> Int {
    #if canImport(Vision)
    guard let image = UIImage(data: data), let cgImage = image.cgImage else { return 1 }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return 1
    }
    return max(1, request.results?.count ?? 0)
    #else
    return 1
    #endif
  }

  private func startObserving() {
    guard observers.isEmpty, let object = clipboard.notificationObject else { return }
    for name in [UIPasteboard.changedNotification, UIPasteboard.removedNotification] {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: object, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.refresh() }
      })
    }
  }
}

struct ScreenshotOfferToast: View {
  let offer: ScreenshotOffer
  var onAdd: () -> Void
  var onDismiss: () -> Void
  @State private var dragOffset = CGSize.zero

  private let dismissDistance: CGFloat = 72

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Button(action: onAdd) {
        HStack(alignment: .center, spacing: 12) {
          thumbnail
          VStack(alignment: .leading, spacing: 4) {
            Text("Add these transactions?")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
              .multilineTextAlignment(.leading)
            Text(offer.caption)
              .font(.caption)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.leading)
          }
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Add transactions from clipboard image")
      .accessibilityHint(offer.caption)

      Button(action: onDismiss) {
        Image(systemName: "xmark.circle.fill")
          .font(.title)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
          .frame(width: 56, height: 56)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss clipboard image")
    }
    .padding(.leading, 16)
    .padding(.vertical, 10)
    .padding(.trailing, 6)
    .ynabCard()
    // Lifted off the list it floats over, like the save toast.
    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    .offset(x: dragOffset.width, y: max(0, dragOffset.height))
    .opacity(swipeOpacity)
    .simultaneousGesture(swipeToDismiss)
    .accessibilityElement(children: .contain)
  }

  private var swipeOpacity: Double {
    let distance = hypot(dragOffset.width, max(0, dragOffset.height))
    return max(0.35, 1 - Double(distance) / 220)
  }

  private var swipeToDismiss: some Gesture {
    DragGesture(minimumDistance: 16)
      .onChanged { value in
        dragOffset = value.translation
      }
      .onEnded { value in
        let away = abs(value.translation.width) > dismissDistance
          || value.translation.height > dismissDistance
        if away {
          onDismiss()
        } else {
          withAnimation(Theme.Motion.standard) {
            dragOffset = .zero
          }
        }
      }
  }

  @ViewBuilder
  private var thumbnail: some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.inset, style: .continuous)
    Group {
      if let image = UIImage(data: offer.imageData) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "photo")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 56, height: 56)
    .background(Theme.canvas)
    .clipShape(shape)
    .accessibilityHidden(true)
  }
}
