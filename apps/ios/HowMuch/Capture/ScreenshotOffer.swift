import CryptoKit
import Observation
import Photos
import SwiftUI
import UIKit
#if canImport(Vision)
import Vision
#endif

struct ScreenshotCandidate: Equatable, Sendable {
  var id: String
  var data: Data
  var filename: String
  var createdAt: Date
}

struct ScreenshotOffer: Equatable, Identifiable, Sendable {
  var id: String
  var fingerprint: String
  var lineCount: Int
  var imageData: Data
  var filename: String

  var caption: String {
    let noun = lineCount == 1 ? "line" : "lines"
    return "Looks like a screenshot · \(lineCount) \(noun)"
  }
}

protocol ScreenshotLibrary: AnyObject {
  var authorizationStatus: PHAuthorizationStatus { get }
  var observesPhotoLibrary: Bool { get }
  func requestAccess() async -> PHAuthorizationStatus
  func latestScreenshot(createdAfter: Date, excluding: Set<String>) async -> ScreenshotCandidate?
}

@MainActor
@Observable
final class ScreenshotOfferController {
  static let shared = ScreenshotOfferController()

  static let enabledKey = "HowMuch.screenshotOffer.enabled"
  static let enabledAtKey = "HowMuch.screenshotOffer.enabledAt"
  static let dismissedKey = "HowMuch.screenshotOffer.dismissedIDs"
  static let dismissedFingerprintsKey = "HowMuch.screenshotOffer.dismissedFingerprints"
  static let dismissedLimit = 64

  private(set) var isEnabled: Bool
  private(set) var offer: ScreenshotOffer?

  private var enabledAt: Date?
  private var dismissedIDs: [String]
  private var dismissedFingerprints: [String]
  private let defaults: UserDefaults
  private let library: ScreenshotLibrary
  private let lineCounter: @Sendable (Data) -> Int
  private var photoProbe: PhotoLibraryChangeProbe?
  private var screenshotObserver: NSObjectProtocol?
  private var considerGeneration = 0

  init(
    defaults: UserDefaults = .standard,
    library: ScreenshotLibrary = PhotosScreenshotLibrary(),
    lineCounter: @escaping @Sendable (Data) -> Int = ScreenshotOfferController.countLines
  ) {
    self.defaults = defaults
    self.library = library
    self.lineCounter = lineCounter
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    if defaults.object(forKey: Self.enabledAtKey) != nil {
      enabledAt = Date(timeIntervalSince1970: defaults.double(forKey: Self.enabledAtKey))
    }
    dismissedIDs = defaults.stringArray(forKey: Self.dismissedKey) ?? []
    dismissedFingerprints = defaults.stringArray(forKey: Self.dismissedFingerprintsKey) ?? []
  }

  func applyEnabledPreference(_ enabled: Bool) {
    considerGeneration += 1
    if !enabled {
      persistEnabled(false, at: nil)
      offer = nil
      stopObserving()
      return
    }
    persistEnabled(true, at: Date())
    startObserving()
  }

  func setEnabled(_ enabled: Bool) async {
    applyEnabledPreference(enabled)
    guard enabled else {
      return
    }
    await authorizeAndRefresh()
  }

  func startIfNeeded() {
    guard isEnabled else {
      return
    }
    startObserving()
    Task { await authorizeAndRefresh() }
  }

  private func authorizeAndRefresh() async {
    let status = await library.requestAccess()
    guard isEnabled else {
      return
    }
    guard status.isScreenshotReadable else {
      offer = nil
      return
    }
    await refresh()
  }

  func refresh() async {
    guard isEnabled, let enabledAt else {
      offer = nil
      return
    }
    guard library.authorizationStatus.isScreenshotReadable else {
      offer = nil
      return
    }
    guard let candidate = await library.latestScreenshot(
      createdAfter: enabledAt,
      excluding: Set(dismissedIDs)
    ) else {
      offer = nil
      return
    }
    guard shouldOffer(candidate) else {
      rememberAliasIfDismissed(candidate)
      offer = nil
      return
    }
    await consider(candidate)
  }

  func consider(_ candidate: ScreenshotCandidate) async {
    guard shouldOffer(candidate) else {
      rememberAliasIfDismissed(candidate)
      return
    }
    considerGeneration += 1
    let generation = considerGeneration
    let lines = await Task.detached(priority: .utility) { [lineCounter] in
      max(1, lineCounter(candidate.data))
    }.value
    guard generation == considerGeneration, shouldOffer(candidate) else {
      return
    }
    offer = ScreenshotOffer(
      id: candidate.id,
      fingerprint: Self.fingerprint(of: candidate.data, createdAt: candidate.createdAt),
      lineCount: lines,
      imageData: candidate.data,
      filename: candidate.filename
    )
  }

  private func shouldOffer(_ candidate: ScreenshotCandidate) -> Bool {
    guard isEnabled else {
      return false
    }
    if dismissedIDs.contains(candidate.id)
      || dismissedFingerprints.contains(Self.fingerprint(of: candidate.data, createdAt: candidate.createdAt))
    {
      return false
    }
    if let enabledAt, candidate.createdAt < enabledAt {
      return false
    }
    return !candidate.data.isEmpty && candidate.data.count <= InboxStore.maxPayloadBytes
  }

  func dismiss() {
    guard let offer else {
      return
    }
    rememberDismissed(offer)
  }

  func review() throws {
    guard isEnabled, let offer else {
      return
    }
    let write = try InboxIntentHandoff.imageWrite(
      offer.imageData,
      filename: offer.filename,
      source: .detectedScreenshot
    )
    try InboxIntentHandoff.enqueue(write)
    rememberDismissed(offer)
  }

  static func countLines(in data: Data) -> Int {
    #if canImport(Vision)
    guard let image = UIImage(data: data), let cgImage = image.cgImage else {
      return 1
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return 1
    }
    let count = request.results?.count ?? 0
    return max(1, count)
    #else
    return 1
    #endif
  }

  private func rememberDismissed(_ offer: ScreenshotOffer) {
    considerGeneration += 1
    dismissedIDs = Self.inserting(offer.id, into: dismissedIDs)
    dismissedFingerprints = Self.inserting(offer.fingerprint, into: dismissedFingerprints)
    defaults.set(dismissedIDs, forKey: Self.dismissedKey)
    defaults.set(dismissedFingerprints, forKey: Self.dismissedFingerprintsKey)
    if self.offer?.id == offer.id {
      self.offer = nil
    }
  }

  private func rememberAliasIfDismissed(_ candidate: ScreenshotCandidate) {
    let fingerprint = Self.fingerprint(of: candidate.data, createdAt: candidate.createdAt)
    guard dismissedFingerprints.contains(fingerprint) else {
      return
    }
    dismissedIDs = Self.inserting(candidate.id, into: dismissedIDs)
    defaults.set(dismissedIDs, forKey: Self.dismissedKey)
  }

  static func fingerprint(of data: Data, createdAt: Date) -> String {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let millis = Int64((createdAt.timeIntervalSince1970 * 1000).rounded(.towardZero))
    return "\(digest).\(millis)"
  }

  private static func inserting(_ value: String, into values: [String]) -> [String] {
    var next = values.filter { $0 != value }
    next.append(value)
    if next.count > dismissedLimit {
      next.removeFirst(next.count - dismissedLimit)
    }
    return next
  }

  private func persistEnabled(_ enabled: Bool, at date: Date?) {
    isEnabled = enabled
    enabledAt = date
    defaults.set(enabled, forKey: Self.enabledKey)
    if let date {
      defaults.set(date.timeIntervalSince1970, forKey: Self.enabledAtKey)
    } else {
      defaults.removeObject(forKey: Self.enabledAtKey)
    }
  }

  private func startObserving() {
    guard library.observesPhotoLibrary else {
      return
    }
    if photoProbe == nil {
      let probe = PhotoLibraryChangeProbe { [weak self] in
        Task { @MainActor in
          await self?.refresh()
        }
      }
      photoProbe = probe
      PHPhotoLibrary.shared().register(probe)
    }
    if screenshotObserver == nil {
      screenshotObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.userDidTakeScreenshotNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(800))
          await self?.refresh()
        }
      }
    }
  }

  private func stopObserving() {
    if let photoProbe {
      PHPhotoLibrary.shared().unregisterChangeObserver(photoProbe)
    }
    photoProbe = nil
    if let screenshotObserver {
      NotificationCenter.default.removeObserver(screenshotObserver)
      self.screenshotObserver = nil
    }
  }
}

extension PHAuthorizationStatus {
  var isScreenshotReadable: Bool {
    self == .authorized || self == .limited
  }
}

final class PhotosScreenshotLibrary: ScreenshotLibrary {
  var authorizationStatus: PHAuthorizationStatus {
    PHPhotoLibrary.authorizationStatus(for: .readWrite)
  }

  var observesPhotoLibrary: Bool { true }

  func requestAccess() async -> PHAuthorizationStatus {
    let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if current != .notDetermined {
      return current
    }
    return await withTaskGroup(of: PHAuthorizationStatus.self) { group in
      group.addTask {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return PHPhotoLibrary.authorizationStatus(for: .readWrite)
      }
      let first = await group.next() ?? .notDetermined
      group.cancelAll()
      return first
    }
  }

  func latestScreenshot(createdAfter: Date, excluding: Set<String>) async -> ScreenshotCandidate? {
    let albums = PHAssetCollection.fetchAssetCollections(
      with: .smartAlbum,
      subtype: .smartAlbumScreenshots,
      options: nil
    )
    guard let album = albums.firstObject else {
      return nil
    }
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    options.fetchLimit = 12
    let assets = PHAsset.fetchAssets(in: album, options: options)
    var match: PHAsset?
    assets.enumerateObjects { asset, _, stop in
      guard let created = asset.creationDate, created >= createdAfter else {
        return
      }
      guard !excluding.contains(asset.localIdentifier) else {
        return
      }
      match = asset
      stop.pointee = true
    }
    guard let asset = match else {
      return nil
    }
    return await load(asset)
  }

  private func load(_ asset: PHAsset) async -> ScreenshotCandidate? {
    await withCheckedContinuation { continuation in
      let options = PHImageRequestOptions()
      options.version = .current
      options.isNetworkAccessAllowed = false
      options.isSynchronous = false
      options.deliveryMode = .highQualityFormat
      PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
        guard let data, !data.isEmpty, data.count <= InboxStore.maxPayloadBytes else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(
          returning: ScreenshotCandidate(
            id: asset.localIdentifier,
            data: data,
            filename: Self.filename(forUTI: uti),
            createdAt: asset.creationDate ?? Date()
          )
        )
      }
    }
  }

  static func filename(forUTI uti: String?) -> String {
    switch uti {
    case "public.jpeg", "public.jpg":
      return "payload.jpg"
    case "public.png":
      return "payload.png"
    case "public.heic", "public.heif":
      return "payload.heic"
    default:
      return "payload.img"
    }
  }
}

private final class PhotoLibraryChangeProbe: NSObject, PHPhotoLibraryChangeObserver {
  private let onChange: () -> Void

  init(onChange: @escaping () -> Void) {
    self.onChange = onChange
  }

  func photoLibraryDidChange(_ changeInstance: PHChange) {
    onChange()
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
      .accessibilityLabel("Add these transactions?")
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
      .accessibilityLabel("Dismiss")
    }
    .padding(.leading, 16)
    .padding(.vertical, 10)
    .padding(.trailing, 6)
    .ynabCard()
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
          dragOffset = .zero
        }
      }
  }

  @ViewBuilder
  private var thumbnail: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
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
