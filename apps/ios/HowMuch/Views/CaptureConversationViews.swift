import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Downsampled, orientation-correct thumbnails for attachment bubbles, the
/// composer tray and the clipboard toast. Decoding the full photo inside `body`
/// repeated a multi-megapixel decode on every keystroke or drag frame; this
/// decodes each image once per size. Synchronous so the first render already
/// shows the image. `NSCache` is thread-safe, so no actor is needed.
enum CaptureThumbnail {
  private static let cache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 48
    return cache
  }()

  static func image(for attachment: CaptureAttachment, side: CGFloat, displayScale: CGFloat) -> UIImage? {
    image(data: attachment.data, id: attachment.id.uuidString, side: side, displayScale: displayScale)
  }

  static func image(data: Data, id: String, side: CGFloat, displayScale: CGFloat) -> UIImage? {
    guard !data.isEmpty else {
      return nil
    }
    let scale = displayScale.isFinite ? max(1, displayScale) : 1
    // An attachment's bytes only go from empty to filled, but the key still
    // covers length and trailing bytes so replaced bytes never reuse a stale image.
    var tail = Hasher()
    tail.combine(data.suffix(64))
    let key = "\(id)|\(data.count)|\(tail.finalize())|\(side)|\(scale)" as NSString
    if let cached = cache.object(forKey: key) {
      return cached
    }
    guard let image = downsample(data, side: side, scale: scale) ?? UIImage(data: data) else {
      return nil
    }
    cache.setObject(image, forKey: key)
    return image
  }

  /// Sized so the short edge still covers a `side`-point square at `scale`,
  /// since the thumbnails are drawn `scaledToFill`.
  private static func downsample(_ data: Data, side: CGFloat, scale: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          width > 0, height > 0
    else {
      return nil
    }
    let longEdge = max(width, height)
    let needed = ceil(Double(side * scale) * longEdge / min(width, height))
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(needed, longEdge),
      kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary) else {
      return nil
    }
    return UIImage(cgImage: thumbnail, scale: scale, orientation: .up)
  }
}

struct CaptureUserBubble: View {
  let message: CaptureMessage
  let attachments: [CaptureAttachment]
  let inspect: (CaptureAttachment) -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    HStack {
      Spacer(minLength: 24)
      VStack(alignment: .trailing, spacing: 6) {
        if !attachments.isEmpty {
          ForEach(attachments) { attachment in
            Button {
              inspect(attachment)
            } label: {
              sentImage(attachment)
            }
            .buttonStyle(.plain)
            .tint(Theme.accent)
            .accessibilityLabel("Inspect attached image")
          }
        }
        if !message.text.isEmpty {
          Text(message.text)
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10 + CaptureSpeechBubble.tailHeight)
            .background(Theme.accent.opacity(0.16), in: CaptureSpeechBubble(tailEdge: .trailing))
        }
        if let caption = message.frozenAccountName {
          Text("Using \(caption)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .trailing)
      .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 320, alignment: .trailing)
    }
    .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 8 : 48)
  }

  @ViewBuilder
  private func sentImage(_ attachment: CaptureAttachment) -> some View {
    if let image = CaptureThumbnail.image(for: attachment, side: 96, displayScale: displayScale) {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }
}

struct CaptureAssistantReply: View {
  let message: CaptureMessage
  let drafts: [CaptureDraftItem]
  let query: LedgerQueryResult?
  let highlightID: String?
  var showsProse = true
  let accountName: (TransactionDraft) -> String
  let categoryName: (TransactionDraft) -> String
  let amountText: (TransactionDraft) -> String
  let dateText: (TransactionDraft) -> String
  let money: (Int) -> String
  let saveGroup: ([String]) -> Void
  let toggleIncluded: (String) -> Void
  let edit: (CaptureDraftItem) -> Void
  let remove: (String) -> Void
  let resolveAccount: (String, String) -> Void
  let resolveCategory: (String, String) -> Void
  let chooseUnresolvedAccount: (String) -> Void
  let chooseUnresolvedCategory: (String) -> Void
  let chooseTarget: (String) -> Void
  let inspectQuery: (LedgerQueryResult) -> Void
  let jumpToDraft: (String) -> Void
  let retry: () -> Void
  let enterManually: () -> Void
  let undo: (() -> Void)?
  let pendingQuery: LedgerQueryResolution?
  let pendingTargetDrafts: [CaptureDraftItem]
  let accountIsOpen: (TransactionDraft) -> Bool
  let resolveQueryAccount: (SlipCandidate) -> Void
  let resolveQueryCategory: (SlipCandidate) -> Void
  let saveError: String?
  let canSave: Bool
  let saveBlockedReason: String?
  let isMutatingLocked: Bool
  let isSyncPending: (CaptureDraftItem) -> Bool
  let canRetry: Bool
  let intelligence: CaptureIntelligenceStatus
  var activity: CaptureAIActivity? = nil
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var animateCompletion = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsProse {
        assistantProse
      }
      if message.replyState == .stopped || message.replyState == .failed {
        replyRecovery
      }
      if let pendingQuery {
        pendingQueryChoices(pendingQuery)
      }
      if !pendingTargetDrafts.isEmpty {
        targetChoices(pendingTargetDrafts)
      }
      if let query {
        queryCard(query)
      }
      if !drafts.isEmpty {
        previewGroup
      } else if let undo {
        Button(action: undo) {
          Text("Undo")
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.semibold))
        .tint(Theme.accent)
        .disabled(isMutatingLocked)
      }
      if !message.updatedDraftIDs.isEmpty {
        ForEach(message.updatedDraftIDs, id: \.self) { id in
          Button("View updated draft") {
            jumpToDraft(id)
          }
          .font(.footnote.weight(.semibold))
          .tint(Theme.accent)
        }
      }
    }
    .onAppear {
      animateCompletion = message.replyState == .generating
    }
    .onChange(of: message.id) { _, _ in
      animateCompletion = message.replyState == .generating
    }
    .onChange(of: message.replyState) { _, new in
      if new == .generating {
        animateCompletion = true
      }
    }
  }

  @ViewBuilder
  private var assistantProse: some View {
    if message.replyState == .generating || !message.text.isEmpty {
      HStack(alignment: .bottom, spacing: 0) {
        Group {
          if message.replyState == .generating {
            waitingProse
          } else {
            CaptureTypedProse(
              fullText: message.text,
              animate: animateCompletion && message.replyState == .complete,
              charactersPerSecond: CaptureAssistantPresence.replyCharactersPerSecond,
              accessibilityLabel: message.text
            )
          }
        }
        .font(.body)
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10 + CaptureSpeechBubble.tailHeight)
        .background(Theme.surfaceMuted, in: CaptureSpeechBubble(tailEdge: .leading))
        .frame(
          maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 320,
          alignment: .leading
        )
        if !dynamicTypeSize.isAccessibilitySize {
          Spacer(minLength: 24)
        }
      }
    }
  }

  @ViewBuilder
  private var waitingProse: some View {
    let clock = activity?.startedAt ?? message.createdAt
    let hasAttachments = !(message.frozenTurn?.attachmentIDs.isEmpty ?? true)
    VStack(alignment: .leading, spacing: 8) {
      TimelineView(.periodic(from: clock, by: 1.0 / 30.0)) { context in
        CaptureWaitingLine(
          messageID: message.id,
          hasAttachments: hasAttachments,
          phase: activity?.phase,
          elapsed: max(0, context.date.timeIntervalSince(clock)),
          now: context.date
        )
      }
      if let activity {
        TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
          let seconds = max(0, Int(context.date.timeIntervalSince(activity.startedAt)))
          VStack(alignment: .leading, spacing: 4) {
            Text(activity.phase == .fetching ? "HowMuch server" : activity.provider).font(.caption)
            Text("\(activity.phase.rawValue) · \(seconds)s")
              .monospacedDigit()
            if seconds >= 20 {
              Text("Taking longer than usual — you can stop and retry, or add it manually.")
            }
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private var replyRecovery: some View {
    adaptiveFooter {
      if canRetry, intelligence == .available {
        Button(action: retry) {
          Text("Retry")
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
      }
      Button(action: enterManually) {
        Text("Add manually")
          .frame(minWidth: 44, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
      }
    }
    .buttonStyle(.plain)
    .font(.subheadline.weight(.semibold))
    .foregroundStyle(Theme.accent)
    .tint(Theme.accent)
  }

  private var previewGroup: some View {
    let unsaved = drafts.filter { !$0.committed }
    let saved = drafts.filter(\.committed)
    return VStack(alignment: .leading, spacing: 10) {
      if let annotation = message.ownerAnnotation {
        Text(annotation)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      ForEach(saved) { item in
        previewRow(item, saved: true)
      }
      ForEach(unsaved) { item in
        previewRow(item, saved: false)
      }
      if unsaved.count > 1 {
        groupFooter(unsaved)
      } else if let only = unsaved.first {
        singleFooter(only)
      }
    }
    .padding(14)
    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  @ViewBuilder
  private func previewRow(_ item: CaptureDraftItem, saved: Bool) -> some View {
    let stacked = dynamicTypeSize.isAccessibilitySize
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if !saved, drafts.filter({ !$0.committed }).count > 1 {
          Button {
            toggleIncluded(item.id)
          } label: {
            Image(systemName: item.included ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(Theme.accent)
              .frame(width: 44, height: 44)
          }
          .tint(Theme.accent)
          .disabled(isMutatingLocked)
          .accessibilityLabel(item.included ? "Include this transaction" : "Excluded transaction")
        }
        Text(item.draft.payeeName.isEmpty ? "(No payee)" : item.draft.payeeName)
          .font(.body.weight(.semibold))
          .foregroundStyle(Theme.textPrimary)
        if !stacked {
          Spacer()
          Text(amountText(item.draft))
            .font(.body.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.registerAmountColour(item.draft.signedMilliunits))
        }
      }
      if stacked {
        Text(amountText(item.draft))
          .font(.body.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(Theme.registerAmountColour(item.draft.signedMilliunits))
      }
      Text(statusText(item, saved: saved))
        .font(.footnote)
        .foregroundStyle(saved ? .secondary : Theme.uncategorised)
      Text("\(categoryName(item.draft)) · \(accountName(item.draft)) · \(dateText(item.draft))")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if !saved {
        if item.accountWasExplicit, item.draft.accountID.isEmpty {
          if !item.accountCandidates.isEmpty {
            candidateRail(prompt: "Which account?", candidates: item.accountCandidates) { candidate in
              resolveAccount(candidate.id, item.id)
            }
          } else {
            Button(item.unrecognizedAccount.map { "I do not recognise “\($0)”. Choose an account." } ?? "Choose an account") {
              chooseUnresolvedAccount(item.id)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.uncategorised)
            .frame(minHeight: 44, alignment: .leading)
            .disabled(isMutatingLocked)
          }
        }
        if item.categoryWasExplicit, item.draft.categoryID == nil {
          if !item.categoryCandidates.isEmpty {
            candidateRail(prompt: "Which category?", candidates: item.categoryCandidates) { candidate in
              resolveCategory(candidate.id, item.id)
            }
          } else {
            Button(item.unrecognizedCategory.map { "I do not recognise “\($0)”. Choose a category." } ?? "Choose a category") {
              chooseUnresolvedCategory(item.id)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.uncategorised)
            .frame(minHeight: 44, alignment: .leading)
            .disabled(isMutatingLocked)
          }
        }
        if !item.draft.accountID.isEmpty, !accountIsOpen(item.draft) {
          Button("Choose an open account") {
            chooseUnresolvedAccount(item.id)
          }
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Theme.uncategorised)
          .frame(minHeight: 44, alignment: .leading)
          .disabled(isMutatingLocked)
        }
        if drafts.filter({ !$0.committed }).count > 1 {
          Button {
            edit(item)
          } label: {
            Text("Edit")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Theme.accent)
              .frame(minWidth: 44, minHeight: 44, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(isMutatingLocked || item.committed)
        }
      }
    }
    .overlay {
      if highlightID == item.id {
        RoundedRectangle(cornerRadius: 12).stroke(Theme.accent, lineWidth: 2)
      }
    }
  }

  private func statusText(_ item: CaptureDraftItem, saved: Bool) -> String {
    if saved {
      return isSyncPending(item) ? "Saved on device · Sync pending" : "Saved on device"
    }
    if !item.included {
      return "Excluded"
    }
    return "Not saved"
  }

  private func singleFooter(_ item: CaptureDraftItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let saveError {
        Text(saveError)
          .font(.footnote)
          .foregroundStyle(Theme.outflow)
      } else if !canSave, let saveBlockedReason, item.included {
        Text(saveBlockedReason)
          .font(.footnote)
          .foregroundStyle(Theme.uncategorised)
      }
      adaptiveFooter {
        Button {
          edit(item)
        } label: {
          Text("Edit")
            .foregroundStyle(Theme.accent)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isMutatingLocked)
        Button {
          saveGroup([item.id])
        } label: {
          Text(item.included ? "Save transaction" : "Select a transaction to save")
        }
        .buttonStyle(CaptureQuietSaveStyle())
        .disabled(!item.included || !canSave || isMutatingLocked)
        Menu {
          Button(item.included ? "Exclude" : "Include") { toggleIncluded(item.id) }
          Button("Remove draft", role: .destructive) { remove(item.id) }
          if let undo {
            Button("Undo") { undo() }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .foregroundStyle(Theme.accent)
            .frame(width: 44, height: 44)
        }
        .tint(Theme.accent)
        .disabled(isMutatingLocked)
        .accessibilityLabel("Draft actions")
      }
    }
    .font(.subheadline.weight(.semibold))
    .tint(Theme.accent)
  }

  private func groupFooter(_ items: [CaptureDraftItem]) -> some View {
    let selected = items.filter(\.included)
    return VStack(alignment: .leading, spacing: 8) {
      if let saveError {
        Text(saveError)
          .font(.footnote)
          .foregroundStyle(Theme.outflow)
      } else if !canSave, let saveBlockedReason, !selected.isEmpty {
        Text(saveBlockedReason)
          .font(.footnote)
          .foregroundStyle(Theme.uncategorised)
      }
      Text(groupSummary(selected))
        .font(.footnote)
        .foregroundStyle(.secondary)
      adaptiveFooter {
        if let undo {
          Button(action: undo) {
            Text("Undo")
              .frame(minWidth: 44, minHeight: 44, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(isMutatingLocked)
        }
        Button {
          saveGroup(selected.map(\.id))
        } label: {
          Text(selected.count <= 1 ? "Save transaction" : "Save \(selected.count) transactions")
        }
        .buttonStyle(CaptureQuietSaveStyle())
        .disabled(selected.isEmpty || !canSave || isMutatingLocked)
      }
    }
    .font(.subheadline.weight(.semibold))
    .tint(Theme.accent)
  }

  private func groupSummary(_ selected: [CaptureDraftItem]) -> String {
    let inflow = selected.filter { $0.draft.signedMilliunits > 0 }.reduce(0) { $0 + $1.draft.signedMilliunits }
    let outflow = selected.filter { $0.draft.signedMilliunits < 0 }.reduce(0) { $0 + abs($1.draft.signedMilliunits) }
    var parts = ["\(selected.count) selected"]
    if outflow > 0 {
      parts.append("\(money(-outflow)) outflow")
    }
    if inflow > 0 {
      parts.append("\(money(inflow)) inflow")
    }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private func adaptiveFooter<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 8) {
        content()
      }
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 12) {
          content()
        }
        VStack(alignment: .leading, spacing: 8) {
          content()
        }
      }
    }
  }

  private func candidateRail(
    prompt: String,
    candidates: [SlipCandidate],
    onPick: @escaping (SlipCandidate) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(prompt)
        .font(.footnote)
        .foregroundStyle(Theme.uncategorised)
      WrappingHStack(spacing: 8) {
        ForEach(candidates) { candidate in
          Button {
            onPick(candidate)
          } label: {
            FilterChip(label: candidate.name, showsChevron: false)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(isMutatingLocked)
        }
      }
    }
  }

  private func targetChoices(_ items: [CaptureDraftItem]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(items) { item in
        Button {
          chooseTarget(item.id)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(item.draft.payeeName.isEmpty ? "(No payee)" : item.draft.payeeName)
              .font(.body.weight(.semibold))
              .foregroundStyle(Theme.textPrimary)
            Text("\(amountText(item.draft)) · \(dateText(item.draft))")
              .font(.subheadline)
              .foregroundStyle(Theme.textPrimary)
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
        .disabled(isMutatingLocked)
        .accessibilityLabel(
          "\(item.draft.payeeName.isEmpty ? "(No payee)" : item.draft.payeeName) \(amountText(item.draft)) \(dateText(item.draft))"
        )
        .accessibilityHint("Use this draft for the last instruction")
      }
    }
  }

  private func pendingQueryChoices(_ pending: LedgerQueryResolution) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if !pending.unresolvedAccount.isEmpty {
        candidateRail(prompt: "Which account?", candidates: pending.unresolvedAccount, onPick: resolveQueryAccount)
      }
      if !pending.unresolvedCategory.isEmpty {
        candidateRail(prompt: "Which category?", candidates: pending.unresolvedCategory, onPick: resolveQueryCategory)
      }
    }
  }

  private func queryCard(_ card: LedgerQueryResult) -> some View {
    let range = card.from == card.to ? card.from : "\(card.from) – \(card.to)"
    return VStack(alignment: .leading, spacing: 8) {
      Text("Recorded spending")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Theme.uncategorised)
      Text("\(range) · \(card.accountLabel) · \(card.categoryLabel)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if !card.sourceRows.isEmpty {
        Button {
          inspectQuery(card)
        } label: {
          Text(card.sourceCount == 1
            ? "Inspect 1 matching payment"
            : "Inspect \(card.sourceCount) matching payments")
        }
        .font(.footnote.weight(.semibold))
        .tint(Theme.accent)
        .frame(minHeight: 44, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

struct CaptureComposerDock: View {
  @Binding var text: String
  @Binding var isFocused: Bool
  var claimFocus: Bool
  var accountLabel: String
  var isBusy: Bool
  var isIngesting: Bool
  var canSend: Bool
  var canChangeAccount: Bool
  var canOpenPlus: Bool
  var pending: [CaptureAttachment]
  var ingestError: String?
  var onAccount: () -> Void
  var onPlus: () -> Void
  var onSend: () -> Void
  var onStop: () -> Void
  var onImages: ([UIImage]) -> Void
  var onRemove: (UUID) -> Void
  var onRetry: (UUID) -> Void
  var onAddManually: () -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Button(action: onAccount) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Account: \(accountLabel)")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.down")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canChangeAccount)
        .accessibilityLabel("Account for next message, \(accountLabel), change account")
        Button(action: onAddManually) {
          Text("Add manually")
            .font(.footnote)
            .foregroundStyle(Theme.accent)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpenPlus)
        .accessibilityLabel("Add manually")
      }
      VStack(alignment: .leading, spacing: 8) {
        let recovery = pending.filter { $0.errorMessage != nil }
        let ready = pending.filter { $0.errorMessage == nil }
        if !recovery.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
              ForEach(recovery) { attachment in
                pendingRecovery(attachment)
                  .containerRelativeFrame(.horizontal)
              }
            }
          }
        }
        if !ready.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(ready) { attachment in
                pendingThumb(attachment)
              }
            }
          }
        }
        if isIngesting {
          Text("Reading the photo…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let ingestError {
          Text(ingestError)
            .font(.caption)
            .foregroundStyle(Theme.outflow)
        }
        HStack(alignment: .bottom, spacing: 8) {
          Button(action: onPlus) {
            Image(systemName: "plus")
              .font(.body.weight(.semibold))
              .foregroundStyle(Theme.accent)
              .frame(width: 44, height: 44)
          }
          .tint(Theme.accent)
          .disabled(!canOpenPlus)
          .accessibilityLabel("Add a photo or paste")
          CaptureComposerField(text: $text, isComposerFocused: $isFocused, claimFocus: claimFocus, onImages: onImages)
            .accessibilityLabel("Transaction description")
            .accessibilityHint("Describe a spend or ask a recorded-spending question. System dictation works here.")
          if isBusy {
            Button(action: onStop) {
              Image(systemName: "stop.fill")
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
            }
            .tint(Theme.accent)
            .accessibilityLabel("Stop response")
          } else {
            Button(action: onSend) {
              Image(systemName: canSend ? "arrow.up.circle.fill" : "arrow.up.circle")
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
          }
        }
      }
      .padding(10)
      .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Theme.canvas)
  }

  @ViewBuilder
  private func pendingRecovery(_ attachment: CaptureAttachment) -> some View {
    let details = VStack(alignment: .leading, spacing: 4) {
      if let error = attachment.errorMessage {
        Text(error)
          .font(.caption2)
          .foregroundStyle(Theme.outflow)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if !attachment.isReading {
        Button {
          onRetry(attachment.id)
        } label: {
          Text("Retry")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canChangeAccount || isIngesting)
        .accessibilityLabel("Retry reading image")
      }
    }
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          pendingThumb(attachment)
          details
        }
      } else {
        HStack(alignment: .top, spacing: 8) {
          pendingThumb(attachment)
          details
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func pendingThumb(_ attachment: CaptureAttachment) -> some View {
    ZStack(alignment: .topTrailing) {
      if let image = CaptureThumbnail.image(for: attachment, side: 64, displayScale: displayScale) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 64, height: 64)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      } else {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Theme.surfaceMuted)
          .frame(width: 64, height: 64)
      }
      Button {
        onRemove(attachment.id)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.white, .black.opacity(0.6))
          .frame(width: 44, height: 44)
      }
      .offset(x: 8, y: -8)
      .accessibilityLabel("Remove attachment")
    }
    .frame(width: 64, height: 64)
  }
}

private struct CaptureWaitingLine: View {
  let messageID: UUID
  let hasAttachments: Bool
  let phase: CaptureAIPhase?
  let elapsed: TimeInterval
  let now: Date
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let frame = CaptureAssistantPresence.waitingFrame(
      messageID: messageID,
      hasAttachments: hasAttachments,
      phase: phase,
      elapsed: elapsed,
      reduceMotion: reduceMotion
    )
    let blinkOn = Int(now.timeIntervalSinceReferenceDate * 2) % 2 == 0
    let cursor = !reduceMotion && frame.showsCursor && blinkOn ? "▍" : ""
    Text(frame.visibleText + cursor)
      .accessibilityLabel(CaptureAssistantPresence.workingAccessibilityLabel)
  }
}

private struct CaptureTypedProse: View {
  let fullText: String
  var animate = false
  var charactersPerSecond = CaptureAssistantPresence.replyCharactersPerSecond
  let accessibilityLabel: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var startedAt: Date?

  var body: some View {
    let shouldType = animate && !reduceMotion
    TimelineView(.periodic(from: startedAt ?? .now, by: shouldType ? 1.0 / 30.0 : 3_600)) { context in
      let visible = revealed(shouldType: shouldType, now: context.date)
      let cursor = shouldType && visible != fullText
        && Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? "▍" : ""
      Text(visible + cursor)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .onAppear {
      if shouldType, startedAt == nil {
        startedAt = Date()
      }
    }
  }

  private func revealed(shouldType: Bool, now: Date) -> String {
    if !shouldType {
      return fullText
    }
    guard let startedAt else {
      return ""
    }
    return CaptureAssistantPresence.revealedText(
      fullText,
      elapsed: max(0, now.timeIntervalSince(startedAt)),
      reduceMotion: false,
      charactersPerSecond: charactersPerSecond
    )
  }
}

private struct CaptureQuietSaveStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isEnabled ? Theme.accent : Theme.textPrimary.opacity(0.45))
      .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Theme.accent.opacity(fillOpacity(pressed: configuration.isPressed)))
          .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(Theme.accent.opacity(isEnabled ? 0.45 : 0.22), lineWidth: 1)
          }
      }
      .frame(minWidth: 44, minHeight: 44, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
      .contentShape(Rectangle())
  }

  private func fillOpacity(pressed: Bool) -> Double {
    if !isEnabled {
      return 0.05
    }
    return pressed ? 0.16 : 0.10
  }
}

private struct CaptureSpeechBubble: Shape {
  enum TailEdge {
    case trailing
    case leading
  }

  static let tailHeight: CGFloat = 10
  static let tailBase: CGFloat = 17

  var tailEdge: TailEdge = .trailing

  func path(in rect: CGRect) -> Path {
    let trailing = trailingPath(in: rect)
    guard tailEdge == .leading else {
      return trailing
    }
    return trailing.applying(
      CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0)
    )
  }

  private func trailingPath(in rect: CGRect) -> Path {
    let body = CGRect(
      x: rect.minX,
      y: rect.minY,
      width: rect.width,
      height: max(0, rect.height - Self.tailHeight)
    )
    let radius = min(16, body.width / 3, body.height / 2)
    let tailLeft = max(body.minX + radius, body.maxX - radius - Self.tailBase)
    var path = Path()
    path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
    path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
    path.addQuadCurve(
      to: CGPoint(x: body.maxX, y: body.minY + radius),
      control: CGPoint(x: body.maxX, y: body.minY)
    )
    path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
    path.addQuadCurve(
      to: CGPoint(x: body.maxX - max(5, radius - 6), y: body.maxY),
      control: CGPoint(x: body.maxX, y: body.maxY)
    )
    path.addLine(to: CGPoint(x: body.maxX - 5, y: rect.maxY))
    path.addLine(to: CGPoint(x: tailLeft, y: body.maxY))
    path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
    path.addQuadCurve(
      to: CGPoint(x: body.minX, y: body.maxY - radius),
      control: CGPoint(x: body.minX, y: body.maxY)
    )
    path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
    path.addQuadCurve(
      to: CGPoint(x: body.minX + radius, y: body.minY),
      control: CGPoint(x: body.minX, y: body.minY)
    )
    path.closeSubpath()
    return path
  }
}
