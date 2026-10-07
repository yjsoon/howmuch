import SwiftUI
import UIKit

enum ShareTheme {
  static let canvas = Color(
    light: Color(red: 0.949, green: 0.937, blue: 0.902),
    dark: Color(red: 0.051, green: 0.063, blue: 0.122)
  )
  static let panel = Color(
    light: .white,
    dark: Color(red: 0.106, green: 0.125, blue: 0.208)
  )
  static let muted = Color(
    light: Color(red: 0.910, green: 0.898, blue: 0.859),
    dark: Color(red: 0.157, green: 0.180, blue: 0.275)
  )
  static let accent = Color(
    light: Color(red: 0.165, green: 0.400, blue: 0.282),
    dark: Color(red: 0.290, green: 0.612, blue: 0.451)
  )
  static let outflow = Color(
    light: Color(red: 0.780, green: 0.196, blue: 0.165),
    dark: Color(red: 0.886, green: 0.447, blue: 0.404)
  )
  static let textPrimary = Color(
    light: Color(red: 0.106, green: 0.125, blue: 0.227),
    dark: Color(red: 0.922, green: 0.933, blue: 0.961)
  )
  static let textSecondary = textPrimary.opacity(0.62)
}

private extension Color {
  init(light: Color, dark: Color) {
    self.init(uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
    })
  }
}

@Observable
@MainActor
final class ShareSheetModel {
  enum Phase: Equatable {
    case loading
    case ready
    case unsupported
  }

  enum SendState: Equatable {
    case idle
    case sending
    case sent
    case failed
  }

  private(set) var phase: Phase = .loading
  private(set) var items: [ShareLoadedItem] = []
  private(set) var context: ShareContext?
  private(set) var skippedCount = 0
  private(set) var sendState: SendState = .idle
  /// An earlier share of the same payload (or of one item in it), if any in the last 30 days.
  private(set) var duplicate: IntakeHashMatch?
  private var hasAcknowledgedDuplicate = false
  /// `nil` means "Let Halation decide".
  var accountSelection: String?
  var hint: IntakeHint = .auto
  var note = ""

  var onFinish: () -> Void = {}
  var onCancel: () -> Void = {}

  private let loader = ShareItemLoader()
  private let store: InboxStore
  private let contextStore: ShareContextStore
  private let hashIndex: IntakeHashIndex

  init(
    store: InboxStore = .shared,
    contextStore: ShareContextStore = .shared,
    hashIndex: IntakeHashIndex = .shared
  ) {
    self.store = store
    self.contextStore = contextStore
    self.hashIndex = hashIndex
  }

  /// The owner has not yet chosen between closing and sharing again.
  var needsDuplicateDecision: Bool {
    duplicate != nil && !hasAcknowledgedDuplicate
  }

  /// "You shared this on 3 Oct", or "You shared one of these on 3 Oct" when only
  /// some of the items were shared before.
  var duplicateMessage: String {
    guard let duplicate else { return "" }
    let date = duplicate.sharedAt.formatted(.dateTime.day().month(.abbreviated))
    if duplicate.isWholeShare || items.count == 1 {
      return "You shared this on \(date)"
    }
    return "You shared one of these on \(date)"
  }

  func shareAnyway() {
    hasAcknowledgedDuplicate = true
  }

  /// A missing context file means "unknown", not signed out: the job is kept
  /// and the app picks the account at review.
  var needsSignIn: Bool {
    context.map { !$0.isSignedIn } ?? false
  }

  var openAccounts: [ShareAccount] {
    context?.openAccounts ?? []
  }

  var selectedAccountName: String? {
    guard let accountSelection else { return nil }
    return openAccounts.first { $0.id == accountSelection }?.name
  }

  var totalBytes: Int {
    items.reduce(0) { $0 + $1.bytes }
  }

  var isTooLarge: Bool {
    items.contains(where: \.exceedsFileLimit) || totalBytes > InboxStore.maxJobBytes
  }

  var tooLargeMessage: String {
    if items.contains(where: \.exceedsFileLimit) {
      return "Too large to send (limit \(Self.megabytes(InboxStore.maxPayloadBytes)))"
    }
    return "Too large to send (limit \(Self.megabytes(InboxStore.maxJobBytes)) in total)"
  }

  var caption: String {
    guard !items.isEmpty else { return "" }
    let base = baseCaption
    switch skippedCount {
    case 0: return base
    case 1: return base + " · 1 item skipped"
    default: return base + " · \(skippedCount) items skipped"
    }
  }

  private var baseCaption: String {
    if items.count == 1, let item = items.first {
      switch item.kind {
      case .pdf:
        var parts = ["PDF"]
        if let pages = item.pageCount, pages > 0 {
          parts.append(pages == 1 ? "1 page" : "\(pages) pages")
        }
        parts.append(Self.size(item.bytes))
        return parts.joined(separator: " · ")
      case .image:
        return "1 screenshot"
      case .text:
        return "Text"
      }
    }
    if items.allSatisfy({ $0.kind == .image }) {
      return "\(items.count) screenshots"
    }
    return "\(items.count) items"
  }

  var itemCountLabel: String {
    items.count == 1 ? "1 item" : "\(items.count) items"
  }

  var sendAccessibilityLabel: String {
    if let name = selectedAccountName {
      return "Send \(itemCountLabel) to \(name)"
    }
    return "Send \(itemCountLabel) to Halation, which picks the account"
  }

  var canSend: Bool {
    phase == .ready && !needsSignIn && !items.isEmpty && !isTooLarge && !needsDuplicateDecision
      && (sendState == .idle || sendState == .failed)
  }

  var canSaveForLater: Bool {
    phase == .ready && needsSignIn && !items.isEmpty && !isTooLarge && !needsDuplicateDecision
      && (sendState == .idle || sendState == .failed)
  }

  var hintLine: String {
    switch hint {
    case .auto: return "Halation works out whether each item is new or a correction."
    case .new: return "Add as new transactions."
    case .fix: return "Match to transactions already in the register."
    case .statement: return "Reconcile against the register for the statement period."
    }
  }

  func load(from inputItems: [NSExtensionItem], displayScale: CGFloat) async {
    let context = contextStore.read()
    self.context = context
    accountSelection = context?.defaultAccountID
    let result = await loader.load(from: inputItems, displayScale: displayScale)
    items = result.items
    skippedCount = result.unsupportedCount
    duplicate = result.items.isEmpty ? nil : hashIndex.lookup(
      contentHash: ShareItemLoader.contentHash(of: result.items),
      sourceHashes: result.items.map(\.sha256)
    )
    phase = result.items.isEmpty ? .unsupported : .ready
  }

  func send() async {
    guard canSend else { return }
    await write(decide: accountSelection == nil, accountID: accountSelection, hint: hint, note: note)
  }

  func saveForLater() async {
    guard canSaveForLater else { return }
    await write(decide: true, accountID: nil, hint: .auto, note: note)
  }

  func cancel() {
    loader.cleanUp()
    onCancel()
  }

  private func write(decide: Bool, accountID: String?, hint: IntakeHint, note: String) async {
    sendState = .sending
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    var counts: [InboxPayloadKind: Int] = [:]
    let sources = items.map { item -> InboxFileSource in
      let index = (counts[item.kind] ?? 0) + 1
      counts[item.kind] = index
      let base: String
      switch item.kind {
      case .image: base = "image"
      case .pdf: base = "document"
      case .text: base = "text"
      }
      return InboxFileSource(
        filename: "\(base)-\(index).\(item.fileURL.pathExtension)",
        kind: item.kind,
        fileURL: item.fileURL,
        sha256: item.sha256
      )
    }
    let job = InboxFileWrite(
      source: .shareSheet,
      sources: sources,
      accountID: accountID,
      decideAccount: decide,
      hint: hint,
      note: trimmed.isEmpty ? nil : trimmed,
      contentHash: ShareItemLoader.contentHash(of: items)
    )
    let store = store
    do {
      try await Task.detached { try store.write(job) }.value
    } catch {
      sendState = .failed
      return
    }
    sendState = .sent
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    try? await Task.sleep(for: .milliseconds(1200))
    loader.cleanUp()
    onFinish()
  }

  private static func size(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private static func megabytes(_ bytes: Int) -> String {
    "\(bytes / (1024 * 1024)) MB"
  }
}

struct ShareSheetView: View {
  @Bindable var model: ShareSheetModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let tile: CGFloat = 72

  var body: some View {
    ZStack {
      ShareTheme.canvas.ignoresSafeArea()
      VStack(spacing: 0) {
        header
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            content
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
      }
      if model.sendState == .sent {
        sentPill
      }
    }
    .animation(.default, value: model.sendState)
    .animation(.default, value: model.phase)
  }

  private var header: some View {
    HStack(spacing: 8) {
      cancelButton
      Spacer(minLength: 0)
      Text("Add to Halation")
        .font(.headline)
        .foregroundStyle(ShareTheme.textPrimary)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
      cancelButton
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 52)
  }

  private var cancelButton: some View {
    Button("Cancel") { model.cancel() }
      .foregroundStyle(ShareTheme.accent)
      .fixedSize(horizontal: true, vertical: false)
      .frame(minWidth: 44, minHeight: 44)
      .disabled(model.sendState == .sending || model.sendState == .sent)
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .loading:
      placeholderStrip
      Text("Loading what you shared…")
        .font(.footnote)
        .foregroundStyle(ShareTheme.textSecondary)
      sendButton(title: "Send", enabled: false, action: {})
    case .unsupported:
      panel {
        Text("Halation can read screenshots, photos and PDFs.")
          .font(.body)
          .foregroundStyle(ShareTheme.textPrimary)
      }
    case .ready:
      readyContent
    }
  }

  @ViewBuilder
  private var readyContent: some View {
    itemsStrip
    caption
    if model.needsDuplicateDecision {
      duplicatePrompt
    } else if !model.needsSignIn {
      accountRow
      kindPicker
      noteField
      if model.sendState == .failed { failureLine }
      sendButton(
        title: "Send",
        enabled: model.canSend,
        action: { Task { await model.send() } }
      )
      .accessibilityLabel(model.sendAccessibilityLabel)
      footnote("Reads on this phone", "Nothing is saved without your review")
    } else {
      panel {
        VStack(alignment: .leading, spacing: 6) {
          Text("Open Halation to finish setting up")
            .font(.headline)
            .foregroundStyle(ShareTheme.textPrimary)
          Text("Kept on this device until you sign in")
            .font(.subheadline)
            .foregroundStyle(ShareTheme.textSecondary)
        }
      }
      noteField
      if model.sendState == .failed { failureLine }
      sendButton(
        title: "Save for later",
        enabled: model.canSaveForLater,
        action: { Task { await model.saveForLater() } }
      )
      footnote("Reads on this phone", "Nothing is saved without your review")
    }
  }

  /// A share extension cannot open the app, so there is no Open button: the
  /// owner closes this and opens Halation themselves.
  private var duplicatePrompt: some View {
    VStack(alignment: .leading, spacing: 12) {
      panel {
        VStack(alignment: .leading, spacing: 6) {
          Text(model.duplicateMessage)
            .font(.headline)
            .foregroundStyle(ShareTheme.textPrimary)
          Text("It's in your Halation Inbox. Open Halation to see it.")
            .font(.subheadline)
            .foregroundStyle(ShareTheme.textSecondary)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
      }
      sendButton(title: "Share anyway", enabled: true, action: { model.shareAnyway() })
      Button(action: { model.cancel() }) {
        Text("Close")
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 44)
          .foregroundStyle(ShareTheme.accent)
          .background(ShareTheme.muted, in: Capsule())
      }
    }
  }

  private var placeholderStrip: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(ShareTheme.muted)
      .frame(width: tile, height: tile)
      .accessibilityHidden(true)
  }

  private var itemsStrip: some View {
    let items = model.items
    let overflow = items.count > 4
    let visible = overflow ? Array(items.prefix(3)) : items
    return HStack(spacing: 8) {
      ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
        thumbnail(item, index: index, total: items.count)
      }
      if overflow {
        Text("+\(items.count - 3)")
          .font(.title3.weight(.semibold))
          .foregroundStyle(ShareTheme.textSecondary)
          .frame(width: tile, height: tile)
          .background(ShareTheme.muted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .accessibilityLabel("\(items.count - 3) more items")
      }
      Spacer(minLength: 0)
    }
  }

  private func thumbnail(_ item: ShareLoadedItem, index: Int, total: Int) -> some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    return ZStack(alignment: .bottom) {
      if let cgImage = item.thumbnail {
        Image(decorative: cgImage, scale: 1, orientation: .up)
          .resizable()
          .scaledToFill()
          .frame(width: tile, height: tile)
          .clipShape(shape)
      } else {
        shape.fill(ShareTheme.muted)
          .frame(width: tile, height: tile)
          .overlay {
            Image(systemName: item.kind == .text ? "text.alignleft" : "doc")
              .font(.title2)
              .foregroundStyle(ShareTheme.textSecondary)
          }
      }
      if item.kind == .pdf {
        Text(pdfBadge(item))
          .font(.system(size: 10, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .foregroundStyle(.white)
          .padding(.horizontal, 4)
          .padding(.vertical, 2)
          .frame(maxWidth: .infinity)
          .background(.black.opacity(0.6))
          .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
      }
    }
    .frame(width: tile, height: tile)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(thumbnailLabel(item, index: index, total: total))
  }

  private func pdfBadge(_ item: ShareLoadedItem) -> String {
    guard let pages = item.pageCount, pages > 0 else { return "PDF" }
    return "PDF · \(pages) \(pages == 1 ? "page" : "pages")"
  }

  private func thumbnailLabel(_ item: ShareLoadedItem, index: Int, total: Int) -> String {
    switch item.kind {
    case .pdf:
      guard let pages = item.pageCount, pages > 0 else { return "PDF" }
      return "PDF, \(pages) \(pages == 1 ? "page" : "pages")"
    case .image:
      return "Screenshot \(index + 1) of \(total)"
    case .text:
      return "Text \(index + 1) of \(total)"
    }
  }

  @ViewBuilder
  private var caption: some View {
    if model.isTooLarge {
      Text(model.tooLargeMessage)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(ShareTheme.outflow)
    } else {
      Text(model.caption)
        .font(.subheadline)
        .foregroundStyle(ShareTheme.textSecondary)
    }
  }

  private var accountRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      panel {
        Menu {
          Picker("Account", selection: $model.accountSelection) {
            ForEach(model.openAccounts) { account in
              Text(account.name).tag(Optional(account.id))
            }
            Text("Let Halation decide").tag(String?.none)
          }
        } label: {
          HStack {
            Text("Account")
              .foregroundStyle(ShareTheme.textPrimary)
            Spacer()
            Text(model.selectedAccountName ?? "Let Halation decide")
              .foregroundStyle(ShareTheme.textSecondary)
            Image(systemName: "chevron.up.chevron.down")
              .font(.footnote)
              .foregroundStyle(ShareTheme.textSecondary)
          }
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .accessibilityLabel("Account")
        .accessibilityValue(model.selectedAccountName ?? "Let Halation decide")
      }
      if model.accountSelection == nil {
        Text("Picks from the document. You confirm at review.")
          .font(.footnote)
          .foregroundStyle(ShareTheme.textSecondary)
          .padding(.horizontal, 4)
      }
    }
  }

  private var kindPicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("What is this?")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(ShareTheme.textPrimary)
      Picker("What is this?", selection: $model.hint) {
        Text("Auto").tag(IntakeHint.auto)
        Text("New").tag(IntakeHint.new)
        Text("Fix").tag(IntakeHint.fix)
      }
      .pickerStyle(.segmented)
      .frame(minHeight: 44)
      Text(model.hintLine)
        .font(.footnote)
        .foregroundStyle(ShareTheme.textSecondary)
        .padding(.horizontal, 4)
    }
  }

  private var noteField: some View {
    panel {
      TextField("Add a note (optional)", text: $model.note, axis: .vertical)
        .lineLimit(1...3)
        .frame(minHeight: 44, alignment: .leading)
        .foregroundStyle(ShareTheme.textPrimary)
    }
  }

  private var failureLine: some View {
    Text("Couldn't hand this to Halation. Try again.")
      .font(.subheadline.weight(.medium))
      .foregroundStyle(ShareTheme.outflow)
  }

  private func sendButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Group {
        if model.sendState == .sending {
          ProgressView().tint(.white)
        } else {
          Text(title).font(.headline)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 44)
      .foregroundStyle(.white)
      .background(
        ShareTheme.accent.opacity(enabled ? 1 : 0.4),
        in: Capsule()
      )
    }
    .disabled(!enabled)
  }

  private func footnote(_ first: String, _ second: String) -> some View {
    VStack(spacing: 2) {
      Text(first)
      Text(second)
    }
    .font(.footnote)
    .foregroundStyle(ShareTheme.textSecondary)
    .frame(maxWidth: .infinity)
  }

  private var sentPill: some View {
    Label("Sent to Halation", systemImage: "checkmark.circle.fill")
      .font(.headline)
      .foregroundStyle(.white)
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      .background(ShareTheme.accent, in: Capsule())
      .shadow(radius: 8, y: 2)
      .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
      .onAppear {
        AccessibilityNotification.Announcement("Sent to Halation").post()
      }
  }

  private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .padding(.horizontal, 14)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ShareTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}
