import Foundation
import Observation

struct CaptureDraftItem: Identifiable, Equatable, Codable, Sendable {
  var id: String
  var draft: TransactionDraft
  var included: Bool
  var accountWasExplicit: Bool
  var categoryWasExplicit: Bool
  var accountCandidates: [SlipCandidate]
  var categoryCandidates: [SlipCandidate]
  var hasManualEdits: Bool
  var committed: Bool
  var unrecognizedAccount: String?
  var unrecognizedCategory: String?

  init(draft: TransactionDraft, included: Bool = true) {
    var draft = draft
    let identity = draft.importID ?? UUID().uuidString.lowercased()
    draft.importID = identity
    id = identity
    self.draft = draft
    self.included = included
    accountWasExplicit = !draft.accountID.isEmpty
    categoryWasExplicit = draft.categoryID != nil
    accountCandidates = []
    categoryCandidates = []
    hasManualEdits = false
    committed = false
    unrecognizedAccount = nil
    unrecognizedCategory = nil
  }

  init(mapped row: SlipMappedDraft, included: Bool = true) {
    self.init(draft: row.draft, included: included)
    accountWasExplicit = row.parsedAccount
    categoryWasExplicit = row.parsedCategory
    accountCandidates = row.accountCandidates
    categoryCandidates = row.categoryCandidates
    unrecognizedAccount = row.unrecognizedAccount
    unrecognizedCategory = row.unrecognizedCategory
  }
}

enum CaptureMessageKind: String, Codable, Sendable {
  case user
  case assistant
  case system
}

enum CaptureReplyState: String, Codable, Sendable {
  case generating
  case stopped
  case failed
  case complete
}

struct CaptureFrozenTurn: Equatable, Codable, Sendable {
  var text: String
  var accountID: String?
  var accountName: String
  var localDate: String
  var attachmentIDs: [UUID]
  var userMessageID: UUID
  var replyMessageID: UUID
}

struct CaptureMessage: Identifiable, Equatable, Codable, Sendable {
  var id: UUID
  var kind: CaptureMessageKind
  var text: String
  var createdAt: Date
  var ownedDraftIDs: [String]
  var updatedDraftIDs: [String]
  var queryID: UUID?
  var attachmentIDs: [UUID]
  var frozenAccountID: String?
  var frozenAccountName: String?
  var frozenLocalDate: String?
  var replyState: CaptureReplyState?
  var ownerAnnotation: String?
  var frozenTurn: CaptureFrozenTurn?

  init(
    id: UUID = UUID(),
    kind: CaptureMessageKind,
    text: String,
    createdAt: Date = .now,
    ownedDraftIDs: [String] = [],
    updatedDraftIDs: [String] = [],
    queryID: UUID? = nil,
    attachmentIDs: [UUID] = [],
    frozenAccountID: String? = nil,
    frozenAccountName: String? = nil,
    frozenLocalDate: String? = nil,
    replyState: CaptureReplyState? = nil,
    ownerAnnotation: String? = nil,
    frozenTurn: CaptureFrozenTurn? = nil
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.createdAt = createdAt
    self.ownedDraftIDs = ownedDraftIDs
    self.updatedDraftIDs = updatedDraftIDs
    self.queryID = queryID
    self.attachmentIDs = attachmentIDs
    self.frozenAccountID = frozenAccountID
    self.frozenAccountName = frozenAccountName
    self.frozenLocalDate = frozenLocalDate
    self.replyState = replyState
    self.ownerAnnotation = ownerAnnotation
    self.frozenTurn = frozenTurn
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    kind = try container.decode(CaptureMessageKind.self, forKey: .kind)
    text = try container.decode(String.self, forKey: .text)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    ownedDraftIDs = try container.decodeIfPresent([String].self, forKey: .ownedDraftIDs) ?? []
    updatedDraftIDs = try container.decodeIfPresent([String].self, forKey: .updatedDraftIDs) ?? []
    queryID = try container.decodeIfPresent(UUID.self, forKey: .queryID)
    attachmentIDs = try container.decodeIfPresent([UUID].self, forKey: .attachmentIDs) ?? []
    frozenAccountID = try container.decodeIfPresent(String.self, forKey: .frozenAccountID)
    frozenAccountName = try container.decodeIfPresent(String.self, forKey: .frozenAccountName)
    frozenLocalDate = try container.decodeIfPresent(String.self, forKey: .frozenLocalDate)
    replyState = try container.decodeIfPresent(CaptureReplyState.self, forKey: .replyState)
    ownerAnnotation = try container.decodeIfPresent(String.self, forKey: .ownerAnnotation)
    frozenTurn = try container.decodeIfPresent(CaptureFrozenTurn.self, forKey: .frozenTurn)
  }
}

struct CaptureAttachment: Identifiable, Equatable, Sendable {
  var id: UUID
  var filename: String
  var data: Data
  var recognizedText: String
  var isReading: Bool
  var errorMessage: String?

  init(
    id: UUID = UUID(),
    filename: String,
    data: Data,
    recognizedText: String = "",
    isReading: Bool = false,
    errorMessage: String? = nil
  ) {
    self.id = id
    self.filename = filename
    self.data = data
    self.recognizedText = recognizedText
    self.isReading = isReading
    self.errorMessage = errorMessage
  }
}

enum CaptureTurnIntent: String, Codable, Sendable {
  case add
  case update
  case query
  case unsupported
}

struct CaptureDraftMutation: Equatable, Codable, Sendable {
  var targetDraftID: String?
  var extraction: SlipReaderMapping.Extraction
}

struct CaptureMappedChange: Equatable, Codable, Sendable {
  var targetDraftID: String?
  var mapped: SlipMappedDraft
}

struct CaptureInterpretedTurn: Equatable, Codable, Sendable {
  var intent: CaptureTurnIntent
  var feedback: String
  var mutations: [CaptureDraftMutation]
  var query: LedgerQuerySpec?
  var applyToAllDrafts: Bool
}

struct CaptureTurnScope: Equatable, Sendable {
  var sessionID: UUID
  var generation: Int
  var sessionScopeKey: String
  var settingsScopeKey: String?
  var workspaceScopeKey: String?
  var workspaceCurrentID: UUID?
  var planID: String

  @MainActor
  static func capture(
    session: CaptureSession,
    settingsScopeKey: String?,
    workspace: CaptureWorkspace,
    planID: String
  ) -> CaptureTurnScope {
    CaptureTurnScope(
      sessionID: session.id,
      generation: session.generation,
      sessionScopeKey: session.scopeKey,
      settingsScopeKey: settingsScopeKey,
      workspaceScopeKey: workspace.activeScopeKey,
      workspaceCurrentID: workspace.current?.id,
      planID: planID
    )
  }

  @MainActor
  func isCurrent(
    session: CaptureSession,
    settingsScopeKey: String?,
    workspace: CaptureWorkspace,
    planID: String
  ) -> Bool {
    guard
      let settingsScopeKey,
      let workspaceScopeKey = workspace.activeScopeKey,
      let currentID = workspace.current?.id,
      CaptureWorkspaceStore.isPersistableScope(session.scopeKey),
      CaptureWorkspaceStore.isPersistableScope(settingsScopeKey),
      CaptureWorkspaceStore.isPersistableScope(workspaceScopeKey),
      session.scopeKey == settingsScopeKey,
      settingsScopeKey == workspaceScopeKey,
      currentID == session.id
    else {
      return false
    }
    return session.id == sessionID
      && session.generation == generation
      && session.scopeKey == sessionScopeKey
      && settingsScopeKey == self.settingsScopeKey
      && workspaceScopeKey == self.workspaceScopeKey
      && currentID == workspaceCurrentID
      && planID == self.planID
  }
}

struct CaptureUndoSnapshot: Equatable, Sendable {
  var drafts: [CaptureDraftItem]
  var affectedDraftIDs: [String]
  var feedback: String
}

/// One capture / Assistant conversation. Sending, attachments, mode changes,
/// and questions never commit. Only an explicit Save does.
@MainActor
@Observable
final class CaptureSession: Identifiable {
  let id: UUID
  let createdAt: Date
  var updatedAt: Date
  var scopeKey: String
  var origin: CaptureOrigin
  var selectedAccountID: String?
  var entryMode: CaptureEntryMode
  var drafts: [CaptureDraftItem]
  var messages: [CaptureMessage]
  var attachments: [CaptureAttachment]
  var sentAttachments: [CaptureAttachment]
  var composerText: String
  var frozenTurn: CaptureFrozenTurn?
  var lastFeedback: String?
  var canUndo: Bool { undoStack.isEmpty == false }
  var isBusy: Bool
  var aiActivity: CaptureAIActivity?
  var isSaving: Bool
  var claimedInboxIDs: [UUID]
  var generation: Int
  var revision: Int
  var queryCards: [LedgerQueryResult]
  var pendingQuery: LedgerQueryResolution?
  var pendingQueryReplyID: UUID?
  var selectedManualDraftID: String?
  var pendingTargetDraftIDs: [String]
  var pendingUpdateTurn: CaptureInterpretedTurn?
  var pendingUpdateReplyID: UUID?
  var pendingUpdateChanges: [CaptureMappedChange]
  var isTransferringImages: Bool
  private var undoStack: [CaptureUndoSnapshot]
  private var admitted: Bool

  init(
    id: UUID = UUID(),
    scopeKey: String,
    origin: CaptureOrigin,
    selectedAccountID: String?,
    entryMode: CaptureEntryMode = .describe,
    drafts: [CaptureDraftItem] = [],
    createdAt: Date = .now
  ) {
    self.id = id
    self.createdAt = createdAt
    updatedAt = createdAt
    self.scopeKey = scopeKey
    self.origin = origin
    self.selectedAccountID = selectedAccountID
    self.entryMode = entryMode
    self.drafts = drafts
    messages = []
    attachments = []
    sentAttachments = []
    composerText = ""
    frozenTurn = nil
    lastFeedback = nil
    isBusy = false
    isSaving = false
    claimedInboxIDs = []
    generation = 0
    revision = 0
    queryCards = []
    pendingQuery = nil
    pendingQueryReplyID = nil
    selectedManualDraftID = drafts.first?.id
    pendingTargetDraftIDs = []
    pendingUpdateTurn = nil
    pendingUpdateReplyID = nil
    pendingUpdateChanges = []
    isTransferringImages = false
    undoStack = []
    admitted = true
  }

  var saveableDrafts: [TransactionDraft] {
    includedDrafts.map(\.draft)
  }

  var currentDrafts: [CaptureDraftItem] {
    drafts.filter { !$0.committed }
  }

  var committedDrafts: [CaptureDraftItem] {
    drafts.filter(\.committed)
  }

  var includedDrafts: [CaptureDraftItem] {
    currentDrafts.filter(\.included)
  }

  var hasUnresolvedAmbiguity: Bool {
    includedDrafts.contains { item in
      (item.accountWasExplicit && item.draft.accountID.isEmpty)
        || (item.categoryWasExplicit && item.draft.categoryID == nil)
    }
  }

  var isIngesting: Bool {
    isTransferringImages || attachments.contains { $0.isReading }
  }

  var canSendComposer: Bool {
    let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasSendableAttachment = attachments.contains { !$0.data.isEmpty }
    return (hasText || hasSendableAttachment) && !isBusy && !isSaving
  }

  var canSaveIncluded: Bool {
    !includedDrafts.isEmpty
      && !hasUnresolvedAmbiguity
      && !isBusy
      && !isIngesting
      && !isSaving
      && pendingTargetDraftIDs.isEmpty
      && pendingQuery == nil
      && pendingUpdateTurn == nil
      && includedDrafts.allSatisfy { $0.draft.canSave }
  }

  var title: String {
    if drafts.isEmpty {
      return "Add Transactions"
    }
    if drafts.count == 1 {
      return "Add Transaction"
    }
    return "\(drafts.count) Transactions"
  }

  var saveTitle: String {
    let count = includedDrafts.count
    if count <= 1 {
      return "Save"
    }
    return "Save \(count) transactions"
  }

  var persistableAttachments: [CaptureAttachment] {
    attachments + sentAttachments
  }

  var isUnfinished: Bool {
    !drafts.isEmpty
      || !messages.isEmpty
      || !attachments.isEmpty
      || !sentAttachments.isEmpty
      || !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func ownerMessageID(forDraft id: String) -> UUID? {
    messages.first { $0.ownedDraftIDs.contains(id) }?.id
  }

  func ownedDrafts(for message: CaptureMessage) -> [CaptureDraftItem] {
    message.ownedDraftIDs.compactMap { draftID in
      drafts.first { $0.id == draftID }
    }
  }

  func hydrateOwnershipIfNeeded() {
    var changed = false
    var claimed = Set<String>()
    for index in messages.indices {
      let unique = messages[index].ownedDraftIDs.filter { claimed.insert($0).inserted }
      if unique != messages[index].ownedDraftIDs {
        messages[index].ownedDraftIDs = unique
        changed = true
      }
    }
    let unowned = drafts.filter { item in
      !messages.contains { $0.ownedDraftIDs.contains(item.id) }
    }
    if !unowned.isEmpty {
      if let index = messages.lastIndex(where: { $0.kind == .assistant }) {
        messages[index].ownedDraftIDs.append(contentsOf: unowned.map(\.id))
      } else {
        messages.append(
          CaptureMessage(
            kind: .system,
            text: "Entered manually",
            ownedDraftIDs: unowned.map(\.id)
          )
        )
      }
      changed = true
    }
    if hydrateUnownedQueryCards() {
      changed = true
    }
    if changed {
      touch()
    }
  }

  private func hydrateUnownedQueryCards() -> Bool {
    var claimed = Set(messages.compactMap(\.queryID))
    var changed = false
    for card in queryCards where !claimed.contains(card.id) {
      if let index = messages.lastIndex(where: { message in
        message.queryID == nil && message.kind != .user && message.text == card.detail
      }) {
        messages[index].queryID = card.id
      } else {
        messages.append(
          CaptureMessage(
            kind: .system,
            text: card.detail,
            queryID: card.id
          )
        )
      }
      claimed.insert(card.id)
      changed = true
    }
    return changed
  }

  func applyFrozenAccountToMissingDrafts(
    accountID: String? = nil,
    draftIDs: [String]? = nil,
    inheritSelected: Bool = true
  ) {
    let account = accountID ?? (inheritSelected ? selectedAccountID : nil)
    guard let account else {
      return
    }
    for index in drafts.indices
    where drafts[index].draft.accountID.isEmpty
      && !drafts[index].accountWasExplicit
      && drafts[index].accountCandidates.isEmpty
      && (draftIDs == nil || draftIDs?.contains(drafts[index].id) == true)
    {
      SlipAccountPick.apply(account, to: &drafts[index].draft)
    }
    touch()
  }

  func selectAccount(_ accountID: String, accounts: [Account]) {
    guard accounts.contains(where: { $0.id == accountID && !$0.closed && !$0.deleted }) else {
      return
    }
    selectedAccountID = accountID
    touch()
  }

  func replaceDrafts(_ items: [CaptureDraftItem], recordUndo: Bool = false) {
    if recordUndo {
      let affected = Array(Set(drafts.map(\.id) + items.map(\.id)))
      pushUndo(feedback: lastFeedback ?? "", affectedDraftIDs: affected, priorDrafts: drafts)
    }
    drafts = items
    if selectedManualDraftID == nil {
      selectedManualDraftID = items.first?.id
    }
    applyFrozenAccountToMissingDrafts()
    touch()
  }

  @discardableResult
  func appendManualDraft(_ draft: TransactionDraft) -> CaptureDraftItem {
    var fresh = draft
    fresh.importID = UUID().uuidString.lowercased()
    var item = CaptureDraftItem(draft: fresh)
    item.hasManualEdits = true
    item.accountWasExplicit = !fresh.accountID.isEmpty
    item.categoryWasExplicit = fresh.categoryID != nil
    drafts.append(item)
    selectedManualDraftID = item.id
    if !item.draft.accountID.isEmpty {
      selectedAccountID = item.draft.accountID
    }
    messages.append(CaptureMessage(kind: .system, text: "Entered manually", ownedDraftIDs: [item.id]))
    touch()
    return item
  }

  func upsertManualDraft(_ draft: TransactionDraft) {
    if let identity = draft.importID, let index = drafts.firstIndex(where: { $0.id == identity }) {
      guard !drafts[index].committed else {
        return
      }
      applyManualEdit(draft, id: identity)
      return
    }
    _ = appendManualDraft(draft)
  }

  func ownUnownedDrafts(as text: String) {
    let unowned = drafts.filter { ownerMessageID(forDraft: $0.id) == nil }
    guard !unowned.isEmpty else {
      return
    }
    messages.append(CaptureMessage(kind: .system, text: text, ownedDraftIDs: unowned.map(\.id)))
    touch()
  }

  func canUndo(ownedIDs: [String]) -> Bool {
    guard let last = undoStack.last else {
      return false
    }
    return !Set(last.affectedDraftIDs).isDisjoint(with: ownedIDs)
  }

  func canUndoDraft(_ id: String) -> Bool {
    canUndo(ownedIDs: [id])
  }

  func applyManualEdit(_ draft: TransactionDraft, id: String) {
    guard let index = drafts.firstIndex(where: { $0.id == id && !$0.committed }) else {
      return
    }
    pushUndo(feedback: lastFeedback ?? "", affectedDraftIDs: [id])
    drafts[index].draft = draft
    drafts[index].hasManualEdits = true
    drafts[index].accountWasExplicit = !draft.accountID.isEmpty
    drafts[index].categoryWasExplicit = draft.categoryID != nil
    drafts[index].accountCandidates = []
    drafts[index].categoryCandidates = []
    drafts[index].unrecognizedAccount = nil
    drafts[index].unrecognizedCategory = nil
    if !draft.accountID.isEmpty {
      selectedAccountID = draft.accountID
    }
    annotateOwners([id], "Edited manually")
    touch()
  }

  func toggleIncluded(_ id: String) {
    guard let index = drafts.firstIndex(where: { $0.id == id }), !drafts[index].committed else {
      return
    }
    drafts[index].included.toggle()
    touch()
  }

  func removeDraft(_ id: String) {
    guard drafts.contains(where: { $0.id == id && !$0.committed }) else {
      return
    }
    pushUndo(feedback: lastFeedback ?? "", affectedDraftIDs: [id])
    drafts.removeAll { $0.id == id }
    if selectedManualDraftID == id {
      selectedManualDraftID = currentDrafts.first?.id
    }
    pendingTargetDraftIDs.removeAll { $0 == id }
    if pendingUpdateTurn != nil, pendingTargetDraftIDs.isEmpty {
      pendingUpdateTurn = nil
      pendingUpdateChanges = []
      appendAssistantMessage("That change was cancelled because those drafts were removed.")
      return
    }
    touch()
  }

  func resolveAccount(_ accountID: String, forDraft id: String) {
    guard let index = drafts.firstIndex(where: { $0.id == id && !$0.committed }) else {
      return
    }
    SlipAccountPick.apply(accountID, to: &drafts[index].draft)
    drafts[index].accountWasExplicit = true
    drafts[index].accountCandidates = []
    drafts[index].unrecognizedAccount = nil
    selectedAccountID = accountID
    touch()
  }

  func resolveCategory(_ categoryID: String, forDraft id: String) {
    guard let index = drafts.firstIndex(where: { $0.id == id && !$0.committed }) else {
      return
    }
    drafts[index].draft.categoryID = categoryID
    drafts[index].categoryWasExplicit = true
    drafts[index].categoryCandidates = []
    drafts[index].unrecognizedCategory = nil
    touch()
  }

  func addAttachment(_ attachment: CaptureAttachment) {
    attachments.append(attachment)
    touch()
  }

  func updateAttachment(_ attachment: CaptureAttachment) {
    guard let index = attachments.firstIndex(where: { $0.id == attachment.id }) else {
      return
    }
    attachments[index] = attachment
    touch()
  }

  func removeAttachment(_ id: UUID) {
    attachments.removeAll { $0.id == id }
    touch()
  }

  func appendUserMessage(_ text: String) {
    messages.append(CaptureMessage(kind: .user, text: text))
    touch()
  }

  func appendAssistantMessage(_ text: String) {
    appendAssistantMessage(text, ownedDraftIDs: [], updatedDraftIDs: [], queryID: nil)
  }

  func appendAssistantMessage(
    _ text: String,
    ownedDraftIDs: [String],
    updatedDraftIDs: [String] = [],
    queryID: UUID? = nil,
    replyState: CaptureReplyState = .complete
  ) {
    messages.append(
      CaptureMessage(
        kind: .assistant,
        text: text,
        ownedDraftIDs: ownedDraftIDs,
        updatedDraftIDs: updatedDraftIDs,
        queryID: queryID,
        replyState: replyState
      )
    )
    lastFeedback = text
    touch()
  }

  @discardableResult
  func freezeComposerTurn(accountName: String, localDate: String) -> CaptureFrozenTurn {
    let attachmentIDs = attachments.map(\.id)
    sentAttachments.append(contentsOf: attachments)
    attachments.removeAll()
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    let display = text.isEmpty ? "Read the attached slips." : text
    let user = CaptureMessage(
      kind: .user,
      text: display,
      attachmentIDs: attachmentIDs,
      frozenAccountID: selectedAccountID,
      frozenAccountName: accountName,
      frozenLocalDate: localDate
    )
    let replyID = UUID()
    let frozen = CaptureFrozenTurn(
      text: display,
      accountID: selectedAccountID,
      accountName: accountName,
      localDate: localDate,
      attachmentIDs: attachmentIDs,
      userMessageID: user.id,
      replyMessageID: replyID
    )
    let reply = CaptureMessage(
      id: replyID,
      kind: .assistant,
      text: "",
      replyState: .generating,
      frozenTurn: frozen
    )
    supersedeOpenClarifications()
    messages.append(user)
    messages.append(reply)
    composerText = ""
    frozenTurn = frozen
    touch()
    return frozen
  }

  func stopActiveReply() {
    guard isBusy else {
      return
    }
    let replyID = frozenTurn?.replyMessageID
    cancelTurn()
    if let replyID, let index = messages.firstIndex(where: { $0.id == replyID }) {
      messages[index].replyState = .stopped
      messages[index].text = CaptureAssistantPresence.stoppedCopy
    }
    lastFeedback = CaptureAssistantPresence.stoppedCopy
    touch()
  }

  func canRetry(_ message: CaptureMessage) -> Bool {
    guard !isBusy, !isIngesting, !isSaving, message.kind == .assistant else {
      return false
    }
    guard message.replyState == .failed || message.replyState == .stopped else {
      return false
    }
    return message.frozenTurn != nil
  }

  func prepareRetry(replyID: UUID) -> CaptureFrozenTurn? {
    guard !isBusy,
          !isIngesting,
          !isSaving,
          let index = messages.firstIndex(where: { $0.id == replyID && $0.kind == .assistant }),
          canRetry(messages[index]),
          let frozen = messages[index].frozenTurn
    else {
      return nil
    }
    messages[index].replyState = .generating
    messages[index].text = ""
    frozenTurn = frozen
    touch()
    return frozen
  }

  func finishReply(
    text: String,
    ownedDraftIDs: [String] = [],
    updatedDraftIDs: [String] = [],
    queryID: UUID? = nil,
    state: CaptureReplyState = .complete,
    replyID: UUID? = nil
  ) {
    let target = replyID ?? frozenTurn?.replyMessageID
    if let target, let index = messages.firstIndex(where: { $0.id == target && $0.kind == .assistant }) {
      messages[index].text = text
      messages[index].ownedDraftIDs = ownedDraftIDs
      messages[index].updatedDraftIDs = updatedDraftIDs
      messages[index].queryID = queryID
      messages[index].replyState = state
    } else {
      appendAssistantMessage(text, ownedDraftIDs: ownedDraftIDs, updatedDraftIDs: updatedDraftIDs, queryID: queryID, replyState: state)
    }
    lastFeedback = text
    if state != .generating, let target, frozenTurn?.replyMessageID == target {
      frozenTurn = nil
    }
    touch()
  }

  func beginTurn(provider: String = "On-device model") -> (generation: Int, revision: Int) {
    isBusy = true
    aiActivity = CaptureAIActivity(provider: provider, startedAt: .now)
    generation += 1
    return (generation, revision)
  }

  func updateAIPhase(_ phase: CaptureAIPhase, generation expected: Int) {
    guard matchesTurn(generation: expected) else { return }
    aiActivity?.phase = phase
  }

  func timeOutTurn(generation expected: Int) {
    guard matchesTurn(generation: expected) else { return }
    recordFailedTurn(CaptureAIError.timedOut.localizedDescription)
    cancelTurn()
  }

  func finishTurn(generation expected: Int) -> Bool {
    guard generation == expected else {
      return false
    }
    isBusy = false
    aiActivity = nil
    return true
  }

  func matchesTurn(generation expected: Int) -> Bool {
    generation == expected && isBusy
  }

  func cancelTurn() {
    generation += 1
    isBusy = false
    aiActivity = nil
    interruptGeneratingReplies()
  }

  func interruptGeneratingReplies() {
    aiActivity = nil
    var changed = false
    for index in messages.indices where messages[index].replyState == .generating {
      messages[index].replyState = .stopped
      if messages[index].text.isEmpty {
        messages[index].text = CaptureAssistantPresence.stoppedCopy
      }
      changed = true
    }
    if isBusy {
      isBusy = false
      changed = true
    }
    if changed {
      lastFeedback = CaptureAssistantPresence.stoppedCopy
      touch()
    }
  }

  func supersedeOpenClarifications() {
    pendingQuery = nil
    pendingQueryReplyID = nil
    pendingUpdateTurn = nil
    pendingUpdateChanges = []
    pendingTargetDraftIDs = []
    pendingUpdateReplyID = nil
  }

  @discardableResult
  func apply(
    turn: CaptureInterpretedTurn,
    mapped: [SlipMappedDraft],
    expectedRevision: Int? = nil,
    expectedGeneration: Int? = nil
  ) -> String {
    let changes = zip(turn.mutations, mapped).map {
      CaptureMappedChange(targetDraftID: $0.0.targetDraftID, mapped: $0.1)
    } + mapped.dropFirst(turn.mutations.count).map {
      CaptureMappedChange(targetDraftID: nil, mapped: $0)
    }
    return apply(
      turn: turn,
      changes: changes,
      expectedRevision: expectedRevision,
      expectedGeneration: expectedGeneration
    )
  }

  @discardableResult
  func apply(
    turn: CaptureInterpretedTurn,
    changes: [CaptureMappedChange],
    expectedRevision: Int? = nil,
    expectedGeneration: Int? = nil
  ) -> String {
    if let expectedGeneration, generation != expectedGeneration {
      return lastFeedback ?? turn.feedback
    }
    if let expectedRevision, expectedRevision != revision {
      let message = "That change was skipped because the drafts changed. Your latest edits are still here."
      appendAssistantMessage(message)
      return message
    }
    let replyID = frozenTurn?.replyMessageID
    let existingIDs = Set(drafts.map(\.id))
    var changes = changes
    var turn = coercePayeeOnlyAddToUpdate(turn, changes: changes)
    if let synthesized = synthesizedPayeeUpdate(turn: turn, changes: changes) {
      turn = synthesized.turn
      changes = synthesized.changes
    }
    switch turn.intent {
    case .query:
      return turn.feedback
    case .unsupported:
      finishReply(text: turn.feedback, state: .complete, replyID: replyID)
      return turn.feedback
    case .add, .update:
      break
    }

    if turn.intent == .update, let prepared = prepareUpdates(turn: turn, changes: changes) {
      switch prepared {
      case .clarification(let message, let shouldHold):
        if shouldHold {
          pendingUpdateTurn = turn
          pendingUpdateChanges = changes
          pendingTargetDraftIDs = drafts.map(\.id)
          pendingUpdateReplyID = replyID ?? messages.last(where: { $0.kind == .assistant })?.id
        } else {
          pendingUpdateTurn = nil
          pendingUpdateChanges = []
          pendingTargetDraftIDs = []
          pendingUpdateReplyID = nil
        }
        lastFeedback = message
        finishReply(text: message, state: .complete, replyID: replyID)
        return message
      case .assignments(let assignments, let splitWarning):
        let updated = assignments.map { drafts[$0.index].id }
        pushUndo(feedback: lastFeedback ?? "", affectedDraftIDs: updated)
        pendingTargetDraftIDs = []
        pendingUpdateTurn = nil
        pendingUpdateChanges = []
        pendingUpdateReplyID = nil
        applyPreparedUpdates(assignments)
        applyFrozenAccountToMissingDrafts(
          accountID: frozenTurn?.accountID,
          draftIDs: updated,
          inheritSelected: frozenTurn == nil
        )
        annotateOwners(updated, "Updated after your correction")
        let message = splitWarning ?? turn.feedback
        lastFeedback = message
        finishReply(text: message, updatedDraftIDs: updated, replyID: replyID)
        return message
      }
    }

    pendingTargetDraftIDs = []
    pendingUpdateTurn = nil
    pendingUpdateChanges = []
    pendingUpdateReplyID = nil
    if turn.intent == .add {
      applyAdditions(
        changes.map(\.mapped),
        accountID: frozenTurn?.accountID,
        inheritSelected: frozenTurn == nil
      )
      let created = drafts.map(\.id).filter { !existingIDs.contains($0) }
      if !created.isEmpty {
        pushUndo(feedback: lastFeedback ?? "", affectedDraftIDs: created, priorDrafts: [])
      }
      finishReply(text: turn.feedback, ownedDraftIDs: created, replyID: replyID)
      return turn.feedback
    }
    applyFrozenAccountToMissingDrafts(
      accountID: frozenTurn?.accountID,
      draftIDs: [],
      inheritSelected: frozenTurn == nil
    )
    finishReply(text: turn.feedback, replyID: replyID)
    return turn.feedback
  }

  private func annotateOwners(_ draftIDs: [String], _ annotation: String) {
    for index in messages.indices where !Set(messages[index].ownedDraftIDs).isDisjoint(with: draftIDs) {
      messages[index].ownerAnnotation = annotation
    }
  }

  @discardableResult
  func undo() -> [String] {
    guard let snapshot = undoStack.popLast() else {
      return []
    }
    let prior = Dictionary(uniqueKeysWithValues: snapshot.drafts.map { ($0.id, $0) })
    var next = drafts
    for id in snapshot.affectedDraftIDs {
      if let saved = prior[id] {
        if let index = next.firstIndex(where: { $0.id == id }) {
          if next[index].committed {
            var restored = saved
            restored.committed = true
            restored.included = false
            next[index] = restored
            continue
          }
          next[index] = saved
        } else {
          next.append(saved)
        }
      } else {
        next.removeAll { $0.id == id && !$0.committed }
      }
    }
    drafts = next
    lastFeedback = "Undid last change."
    pendingTargetDraftIDs.removeAll { snapshot.affectedDraftIDs.contains($0) }
    if pendingUpdateTurn != nil, pendingTargetDraftIDs.isEmpty {
      pendingUpdateTurn = nil
      pendingUpdateChanges = []
      pendingUpdateReplyID = nil
    }
    messages.append(CaptureMessage(kind: .system, text: "Update undone"))
    annotateOwners(snapshot.affectedDraftIDs, "Update undone")
    touch()
    return snapshot.affectedDraftIDs
  }

  func recordFailedTurn(_ message: String) {
    finishReply(text: message, state: .failed, replyID: frozenTurn?.replyMessageID)
  }

  func markCommittedIncluded() {
    markCommitted(ids: includedDrafts.map(\.id))
  }

  func markCommitted(ids: [String]) {
    let accepted = Set(ids)
    for index in drafts.indices where accepted.contains(drafts[index].id) {
      drafts[index].committed = true
      drafts[index].included = false
    }
    undoStack.removeAll()
    pendingTargetDraftIDs.removeAll { accepted.contains($0) }
    if pendingUpdateTurn != nil, pendingTargetDraftIDs.isEmpty {
      pendingUpdateTurn = nil
      pendingUpdateChanges = []
      pendingUpdateReplyID = nil
    }
    if let selected = selectedManualDraftID, accepted.contains(selected) {
      selectedManualDraftID = currentDrafts.first?.id
    }
    touch()
  }

  func groupSaveCandidates(ids: [String]) -> [CaptureDraftItem] {
    ids.compactMap { id in
      drafts.first { $0.id == id && $0.included && !$0.committed }
    }
  }

  func groupSaveBlockReason(ids: [String]) -> String? {
    if isBusy || isIngesting || isSaving {
      return "Wait until this reply finishes."
    }
    if canSaveGroup(ids: ids) {
      return nil
    }
    if groupSaveCandidates(ids: ids).isEmpty {
      return "Select a transaction to save"
    }
    if !pendingTargetDraftIDs.isEmpty {
      return "Choose which transaction to change before saving."
    }
    if hasUnresolvedAmbiguity || pendingQuery != nil {
      return "Choose an account or category before saving."
    }
    return "Enter an amount and pick an account."
  }

  func pendingTargetDrafts() -> [CaptureDraftItem] {
    pendingTargetDraftIDs.compactMap { id in
      drafts.first { $0.id == id }
    }
  }

  func usesClosedOrMissingAccount(ids: [String], openAccounts: [Account]) -> Bool {
    let open = Set(openAccounts.filter { !$0.closed && !$0.deleted }.map(\.id))
    return groupSaveCandidates(ids: ids).contains { !open.contains($0.draft.accountID) }
  }

  func canSaveGroup(ids: [String]) -> Bool {
    let items = groupSaveCandidates(ids: ids)
    guard !items.isEmpty, items.count == ids.count, !isBusy, !isIngesting, !isSaving else {
      return false
    }
    let owners = Set(ids.compactMap { ownerMessageID(forDraft: $0) })
    guard owners.count == 1 else {
      return false
    }
    if !pendingTargetDraftIDs.isEmpty, pendingTargetDraftIDs.contains(where: { ids.contains($0) }) {
      return false
    }
    return items.allSatisfy { item in
      item.draft.canSave
        && !(item.accountWasExplicit && item.draft.accountID.isEmpty)
        && !(item.categoryWasExplicit && item.draft.categoryID == nil)
    }
  }

  func chooseTargetDraft(_ id: String) {
    guard drafts.contains(where: { $0.id == id }) else {
      return
    }
    if let owner = pendingUpdateReplyID, owner != frozenTurn?.replyMessageID {
      frozenTurn = messages.first { $0.id == owner }?.frozenTurn
    }
    pendingTargetDraftIDs = []
    guard let turn = pendingUpdateTurn else {
      touch()
      return
    }
    let changes = pendingUpdateChanges.map { change -> CaptureMappedChange in
      var next = change
      if next.targetDraftID == nil || drafts.contains(where: { $0.id == next.targetDraftID }) == false {
        next.targetDraftID = id
      }
      return next
    }
    pendingUpdateTurn = nil
    pendingUpdateChanges = []
    pendingUpdateReplyID = nil
    _ = apply(turn: turn, changes: changes)
  }

  func snapshot() -> CaptureSessionSnapshot {
    CaptureSessionSnapshot(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt,
      scopeKey: scopeKey,
      origin: origin,
      selectedAccountID: selectedAccountID,
      entryMode: entryMode,
      drafts: drafts,
      messages: messages,
      attachmentRecords: persistableAttachments.map {
        CaptureAttachmentRecord(
          id: $0.id,
          filename: $0.filename,
          recognizedText: $0.recognizedText,
          isReading: $0.isReading,
          errorMessage: $0.errorMessage
        )
      },
      pendingAttachmentIDs: attachments.map(\.id) as [UUID]?,
      lastFeedback: lastFeedback,
      claimedInboxIDs: claimedInboxIDs,
      queryCards: queryCards,
      composerText: composerText,
      selectedManualDraftID: selectedManualDraftID,
      pendingTargetDraftIDs: pendingTargetDraftIDs,
      pendingUpdateTurn: pendingUpdateTurn,
      pendingUpdateChanges: pendingUpdateChanges,
      pendingQuery: pendingQuery,
      pendingQueryReplyID: pendingQueryReplyID,
      pendingUpdateReplyID: pendingUpdateReplyID,
      frozenTurn: frozenTurn
    )
  }

  static func restore(
    _ snapshot: CaptureSessionSnapshot,
    attachments: [CaptureAttachment]
  ) -> CaptureSession {
    let session = CaptureSession(
      id: snapshot.id,
      scopeKey: snapshot.scopeKey,
      origin: snapshot.origin,
      selectedAccountID: snapshot.selectedAccountID,
      entryMode: snapshot.entryMode,
      drafts: snapshot.drafts,
      createdAt: snapshot.createdAt
    )
    session.updatedAt = snapshot.updatedAt
    session.messages = snapshot.messages
    let pendingIDs = Set(snapshot.pendingAttachmentIDs ?? [])
    if snapshot.pendingAttachmentIDs == nil, snapshot.messages.allSatisfy(\.attachmentIDs.isEmpty) {
      session.attachments = attachments.map { normalizedRestoredAttachment($0, isPending: true) }
      session.sentAttachments = []
    } else {
      session.attachments = attachments
        .filter { pendingIDs.contains($0.id) }
        .map { normalizedRestoredAttachment($0, isPending: true) }
      session.sentAttachments = attachments
        .filter { !pendingIDs.contains($0.id) }
        .map { normalizedRestoredAttachment($0, isPending: false) }
    }
    session.lastFeedback = snapshot.lastFeedback
    session.claimedInboxIDs = snapshot.claimedInboxIDs
    session.queryCards = snapshot.queryCards
    session.composerText = snapshot.composerText
    session.selectedManualDraftID = snapshot.selectedManualDraftID ?? snapshot.drafts.first(where: { !$0.committed })?.id
    session.pendingTargetDraftIDs = snapshot.pendingTargetDraftIDs
    session.pendingUpdateTurn = snapshot.pendingUpdateTurn
    session.pendingUpdateChanges = snapshot.pendingUpdateChanges
    session.pendingQuery = snapshot.pendingQuery
    session.pendingQueryReplyID = snapshot.pendingQueryReplyID
    session.pendingUpdateReplyID = snapshot.pendingUpdateReplyID
    session.frozenTurn = snapshot.frozenTurn
    session.hydrateOwnershipIfNeeded()
    session.interruptGeneratingReplies()
    return session
  }

  private static func normalizedRestoredAttachment(
    _ attachment: CaptureAttachment,
    isPending: Bool
  ) -> CaptureAttachment {
    var next = attachment
    let wasReading = next.isReading
    next.isReading = false
    guard isPending else {
      return next
    }
    if let error = next.errorMessage, !error.isEmpty {
      return next
    }
    if wasReading || next.recognizedText.isEmpty {
      next.errorMessage = "I could not read text from that image. It is still attached."
    }
    return next
  }

  private func applyAdditions(
    _ mapped: [SlipMappedDraft],
    accountID: String? = nil,
    inheritSelected: Bool = true
  ) {
    let inherit = accountID ?? (inheritSelected ? selectedAccountID : nil)
    let inheritDate = frozenTurn.flatMap {
      SlipReaderMapping.date(from: $0.localDate, calendar: .current, now: .now)
    }
    for row in mapped {
      var item = CaptureDraftItem(mapped: row)
      if item.draft.accountID.isEmpty, let inherit, !row.parsedAccount {
        SlipAccountPick.apply(inherit, to: &item.draft)
        item.accountWasExplicit = false
      }
      if !row.parsedDate, let inheritDate {
        item.draft.date = inheritDate
      }
      drafts.append(item)
    }
    touch()
  }

  private func coercePayeeOnlyAddToUpdate(
    _ turn: CaptureInterpretedTurn,
    changes: [CaptureMappedChange]
  ) -> CaptureInterpretedTurn {
    guard turn.intent == .add, !drafts.isEmpty, !changes.isEmpty else {
      return turn
    }
    let payeeOnly = changes.allSatisfy { change in
      let payee = change.mapped.draft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
      return !change.mapped.parsedAmount
        && change.mapped.draft.amountMagnitudeMilli == 0
        && !payee.isEmpty
        && !change.mapped.parsedDate
        && !change.mapped.parsedAccount
        && !change.mapped.parsedCategory
    }
    guard payeeOnly else {
      return turn
    }
    var next = turn
    next.intent = .update
    return next
  }

  private func synthesizedPayeeUpdate(
    turn: CaptureInterpretedTurn,
    changes: [CaptureMappedChange]
  ) -> (turn: CaptureInterpretedTurn, changes: [CaptureMappedChange])? {
    guard changes.isEmpty, !drafts.isEmpty else {
      return nil
    }
    switch turn.intent {
    case .query:
      return nil
    case .add, .update, .unsupported:
      break
    }
    let text = frozenTurn?.text ?? messages.last(where: { $0.kind == .user })?.text ?? ""
    guard let payee = CapturePayeeRename.payee(from: text) else {
      return nil
    }
    var draft = TransactionDraft()
    draft.payeeName = payee
    let mapped = SlipMappedDraft(
      draft: draft,
      parsedAmount: false,
      parsedDate: false,
      parsedAccount: false,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
    var next = turn
    next.intent = .update
    return (next, [CaptureMappedChange(targetDraftID: nil, mapped: mapped)])
  }

  private enum PreparedUpdates {
    case clarification(String, shouldHold: Bool)
    case assignments([(index: Int, change: CaptureMappedChange)], String?)
  }

  /// Prevalidates every target, then applies atomically. Never mutates
  /// drafts when any target is missing or a split cannot accept the field.
  private func prepareUpdates(
    turn: CaptureInterpretedTurn,
    changes: [CaptureMappedChange]
  ) -> PreparedUpdates? {
    if turn.applyToAllDrafts {
      var assignments: [(index: Int, change: CaptureMappedChange)] = []
      var splitWarning: String?
      for change in changes {
        for index in drafts.indices {
          if let warning = unsupportedSplitChange(change.mapped, item: drafts[index]) {
            splitWarning = warning
            continue
          }
          assignments.append((index, change))
        }
      }
      return .assignments(assignments, splitWarning)
    }

    if changes.isEmpty {
      return nil
    }

    let live = drafts
    var resolved: [(index: Int, change: CaptureMappedChange)] = []
    for change in changes {
      let targetID = change.targetDraftID
      if let targetID {
        guard let index = drafts.firstIndex(where: { $0.id == targetID }) else {
          return .clarification("Which transaction should I change?", shouldHold: true)
        }
        if let warning = unsupportedSplitChange(change.mapped, item: drafts[index]) {
          return .clarification(warning, shouldHold: false)
        }
        resolved.append((index, change))
      } else if live.count == 1, let index = drafts.indices.first {
        if let warning = unsupportedSplitChange(change.mapped, item: drafts[index]) {
          return .clarification(warning, shouldHold: false)
        }
        resolved.append((index, change))
      } else {
        return .clarification("Which transaction should I change?", shouldHold: true)
      }
    }
    return .assignments(resolved, nil)
  }

  private func applyPreparedUpdates(_ assignments: [(index: Int, change: CaptureMappedChange)]) {
    var next = drafts
    for (index, change) in assignments {
      applyMapped(change.mapped, to: &next[index])
      if change.mapped.parsedAccount, !change.mapped.draft.accountID.isEmpty {
        selectedAccountID = change.mapped.draft.accountID
      }
    }
    drafts = next
    touch()
  }

  private func unsupportedSplitChange(_ row: SlipMappedDraft, item: CaptureDraftItem) -> String? {
    guard item.draft.isSplit else {
      return nil
    }
    if row.parsedAmount || row.parsedDirection || row.parsedCategory {
      return "That draft is a split. Open the editor to change its allocations. Nothing was guessed."
    }
    return nil
  }

  @discardableResult
  private func applyMapped(_ row: SlipMappedDraft, to item: inout CaptureDraftItem) -> String? {
    if let warning = unsupportedSplitChange(row, item: item) {
      return warning
    }
    let applied = ComposeParseApply.applying(row, to: item.draft)
    item.draft = applied.draft
    if row.parsedAccount {
      item.accountWasExplicit = true
      item.accountCandidates = applied.accountCandidates
      item.unrecognizedAccount = row.unrecognizedAccount
    }
    if row.parsedCategory {
      item.categoryWasExplicit = true
      item.categoryCandidates = applied.categoryCandidates
      item.unrecognizedCategory = row.unrecognizedCategory
    }
    return nil
  }

  private func pushUndo(
    feedback: String,
    affectedDraftIDs: [String],
    priorDrafts: [CaptureDraftItem]? = nil
  ) {
    let captured = priorDrafts ?? drafts.filter { affectedDraftIDs.contains($0.id) }
    undoStack.append(
      CaptureUndoSnapshot(drafts: captured, affectedDraftIDs: affectedDraftIDs, feedback: feedback)
    )
    if undoStack.count > 20 {
      undoStack.removeFirst()
    }
  }

  private func touch() {
    revision += 1
    updatedAt = .now
  }
}

struct CaptureAttachmentRecord: Equatable, Codable, Sendable {
  var id: UUID
  var filename: String
  var recognizedText: String
  var isReading: Bool? = nil
  var errorMessage: String? = nil
}

struct CaptureSessionSnapshot: Equatable, Codable, Sendable {
  var id: UUID
  var createdAt: Date
  var updatedAt: Date
  var scopeKey: String
  var origin: CaptureOrigin
  var selectedAccountID: String?
  var entryMode: CaptureEntryMode
  var drafts: [CaptureDraftItem]
  var messages: [CaptureMessage]
  var attachmentRecords: [CaptureAttachmentRecord]
  var pendingAttachmentIDs: [UUID]? = nil
  var lastFeedback: String?
  var claimedInboxIDs: [UUID]
  var queryCards: [LedgerQueryResult]
  var composerText: String
  var selectedManualDraftID: String?
  var pendingTargetDraftIDs: [String] = []
  var pendingUpdateTurn: CaptureInterpretedTurn?
  var pendingUpdateChanges: [CaptureMappedChange] = []
  var pendingQuery: LedgerQueryResolution?
  var pendingQueryReplyID: UUID? = nil
  var pendingUpdateReplyID: UUID? = nil
  var frozenTurn: CaptureFrozenTurn? = nil
}
