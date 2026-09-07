import CryptoKit
import Foundation
import Observation

/// Scoped owner of the current capture / Assistant session and recent history.
/// Capture origin is frozen on the session; this workspace is not rebound when
/// the user merely browses another register.
@MainActor
@Observable
final class CaptureWorkspace {
  static let shared = CaptureWorkspace()

  var current: CaptureSession?
  var recents: [CaptureSessionSnapshot] = []
  private(set) var activeScopeKey: String?
  var pendingAssistantSessionID: UUID?
  var shouldOpenAssistant = false

  private let store: CaptureWorkspaceStore
  private let persistDelay: Duration
  private var persistTask: Task<Void, Never>?
  private var conversationTask: Task<Void, Never>?
  private var lastUsedEntryMode: CaptureEntryMode = .describe

  init(store: CaptureWorkspaceStore = .shared, persistDelay: Duration = .milliseconds(250)) {
    self.store = store
    self.persistDelay = persistDelay
  }

  func cancelOwnedConversationWork() {
    conversationTask?.cancel()
    conversationTask = nil
  }

  func activate(scopeKey: String?) {
    guard scopeKey != activeScopeKey else {
      return
    }
    cancelOwnedConversationWork()
    current?.cancelTurn()
    persistCurrentIfNeeded()
    current = nil
    pendingAssistantSessionID = nil
    shouldOpenAssistant = false
    activeScopeKey = scopeKey
    recents = store.load(scope: scopeKey)
    lastUsedEntryMode = store.lastEntryMode(scope: scopeKey)
  }

  func dropForScopeChange() {
    cancelOwnedConversationWork()
    current?.cancelTurn()
    persistCurrentIfNeeded()
    cancelDeferredPersist()
    current = nil
    recents = []
    pendingAssistantSessionID = nil
    shouldOpenAssistant = false
    activeScopeKey = nil
  }

  func rememberedEntryMode() -> CaptureEntryMode {
    lastUsedEntryMode
  }

  func runConversationTurn(_ work: @escaping @MainActor () async -> Void) {
    conversationTask?.cancel()
    conversationTask = Task { @MainActor in
      guard !Task.isCancelled else {
        return
      }
      await work()
    }
  }

  func rememberEntryMode(_ mode: CaptureEntryMode) {
    lastUsedEntryMode = mode
    if let current {
      current.entryMode = mode
    }
    store.saveLastEntryMode(mode, scope: activeScopeKey)
  }

  @discardableResult
  func admit(
    request: CaptureRequest,
    scopeKey: String?,
    openAccounts: [Account],
    lastUsedAccountID: String?,
    focusedRegisterAccountID: String?
  ) -> CaptureSession {
    activate(scopeKey: scopeKey)
    if let current, current.id == request.id, current.scopeKey == (scopeKey ?? "") {
      return current
    }
    cancelOwnedConversationWork()
    current?.cancelTurn()
    persistCurrentIfNeeded()
    let presetAccountID: String?
    if case .draft(let draft) = request.kind {
      presetAccountID = draft.accountID.isEmpty ? nil : draft.accountID
    } else {
      presetAccountID = nil
    }
    let context = CaptureAccountContext.resolve(
      origin: request.origin,
      openAccounts: openAccounts,
      lastUsedAccountID: lastUsedAccountID,
      focusedRegisterAccountID: focusedRegisterAccountID,
      presetAccountID: presetAccountID
    )
    let session = CaptureSession(
      id: request.id,
      scopeKey: scopeKey ?? "",
      origin: request.origin,
      selectedAccountID: context.selectedAccountID,
      entryMode: lastUsedEntryMode
    )
    if case .draft(let draft) = request.kind {
      session.replaceDrafts([CaptureDraftItem(draft: draft)])
      session.ownUnownedDrafts(as: "Entered from a shortcut")
    }
    current = session
    persistCurrentIfNeeded()
    return session
  }

  func resume(_ id: UUID) -> CaptureSession? {
    if let current, current.id == id {
      pendingAssistantSessionID = current.id
      return current
    }
    guard let snapshot = recents.first(where: { $0.id == id }) else {
      return nil
    }
    cancelOwnedConversationWork()
    current?.cancelTurn()
    persistCurrentIfNeeded()
    let attachments = store.loadAttachments(snapshot: snapshot, scope: activeScopeKey)
    let session = CaptureSession.restore(snapshot, attachments: attachments)
    current = session
    pendingAssistantSessionID = session.id
    return session
  }

  func continueInAssistant() {
    persistCurrentIfNeeded()
    pendingAssistantSessionID = current?.id
    shouldOpenAssistant = true
  }

  func discardCurrent() {
    cancelDeferredPersist()
    cancelOwnedConversationWork()
    current?.cancelTurn()
    if let current {
      store.remove(id: current.id, scope: activeScopeKey)
      recents.removeAll { $0.id == current.id }
    }
    current = nil
    pendingAssistantSessionID = nil
    shouldOpenAssistant = false
  }

  func discard(id: UUID) {
    if current?.id == id {
      cancelDeferredPersist()
      cancelOwnedConversationWork()
      current?.cancelTurn()
    }
    store.remove(id: id, scope: activeScopeKey)
    recents.removeAll { $0.id == id }
    if current?.id == id {
      current = nil
    }
    if pendingAssistantSessionID == id {
      pendingAssistantSessionID = nil
    }
  }

  func discardAll() {
    cancelDeferredPersist()
    cancelOwnedConversationWork()
    current?.cancelTurn()
    store.removeAll(scope: activeScopeKey)
    recents = []
    current = nil
    pendingAssistantSessionID = nil
    shouldOpenAssistant = false
  }

  @discardableResult
  func requestPersistCurrent() -> Task<Void, Never> {
    persistTask?.cancel()
    let task = Task { @MainActor [persistDelay] in
      do {
        try await Task.sleep(for: persistDelay)
      } catch {
        return
      }
      guard !Task.isCancelled else {
        return
      }
      self.persistCurrentIfNeeded()
    }
    persistTask = task
    return task
  }

  func persistCurrentIfNeeded() {
    cancelDeferredPersist()
    guard let scope = activeScopeKey, CaptureWorkspaceStore.isPersistableScope(scope) else {
      return
    }
    guard let current, current.scopeKey == scope, current.isUnfinished else {
      return
    }
    let snapshot = current.snapshot()
    store.save(snapshot: snapshot, attachments: current.persistableAttachments, scope: scope)
    recents.removeAll { $0.id == snapshot.id }
    recents.insert(snapshot, at: 0)
    if recents.count > 20 {
      recents = Array(recents.prefix(20))
    }
  }

  private func cancelDeferredPersist() {
    persistTask?.cancel()
    persistTask = nil
  }

  func markSaved(_ session: CaptureSession, ids: [String]? = nil) {
    if let ids {
      session.markCommitted(ids: ids)
    } else {
      session.markCommittedIncluded()
    }
    persistCurrentIfNeeded()
  }
}

struct CaptureWorkspaceStore {
  static let shared = CaptureWorkspaceStore()

  private let defaults: UserDefaults
  private let fileManager: FileManager
  private let rootURL: URL

  init(defaults: UserDefaults = .standard, fileManager: FileManager = .default, rootURL: URL? = nil) {
    self.defaults = defaults
    self.fileManager = fileManager
    if let rootURL {
      self.rootURL = rootURL
    } else {
      let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
      self.rootURL = base.appendingPathComponent("HowMuchCapture", isDirectory: true)
    }
  }

  func load(scope: String?) -> [CaptureSessionSnapshot] {
    guard let scope, Self.isPersistableScope(scope) else {
      return []
    }
    let url = indexURL(scope: scope)
    guard let data = try? Data(contentsOf: url) else {
      return []
    }
    let decoded = (try? JSONDecoder().decode([CaptureSessionSnapshot].self, from: data)) ?? []
    return decoded.filter { $0.scopeKey == scope }
  }

  func save(snapshot: CaptureSessionSnapshot, attachments: [CaptureAttachment], scope: String?) {
    guard let scope, Self.isPersistableScope(scope), snapshot.scopeKey == scope else {
      return
    }
    var items = load(scope: scope).filter { $0.id != snapshot.id }
    var stored = snapshot
    stored.scopeKey = scope
    items.insert(stored, at: 0)
    let evicted = items.dropFirst(20)
    for old in evicted {
      try? fileManager.removeItem(at: sessionDirectory(sessionID: old.id, scope: scope))
    }
    if items.count > 20 {
      items = Array(items.prefix(20))
    }
    write(items, scope: scope)
    writeAttachments(attachments, sessionID: snapshot.id, scope: scope)
  }

  func loadAttachments(snapshot: CaptureSessionSnapshot, scope: String?) -> [CaptureAttachment] {
    guard let scope else {
      return []
    }
    let pendingIDs: Set<UUID>
    if snapshot.pendingAttachmentIDs == nil, snapshot.messages.allSatisfy(\.attachmentIDs.isEmpty) {
      pendingIDs = Set(snapshot.attachmentRecords.map(\.id))
    } else {
      pendingIDs = Set(snapshot.pendingAttachmentIDs ?? [])
    }
    return snapshot.attachmentRecords.compactMap { record in
      let url = attachmentURL(sessionID: snapshot.id, attachmentID: record.id, scope: scope)
      if let data = try? Data(contentsOf: url) {
        return CaptureAttachment(
          id: record.id,
          filename: record.filename,
          data: data,
          recognizedText: record.recognizedText,
          isReading: record.isReading ?? false,
          errorMessage: record.errorMessage
        )
      }
      guard pendingIDs.contains(record.id) else {
        return nil
      }
      return CaptureAttachment(
        id: record.id,
        filename: record.filename,
        data: Data(),
        recognizedText: record.recognizedText,
        isReading: false,
        errorMessage: "That image is no longer on this device. Remove it and attach it again."
      )
    }
  }

  func remove(id: UUID, scope: String?) {
    guard let scope else {
      return
    }
    write(load(scope: scope).filter { $0.id != id }, scope: scope)
    try? fileManager.removeItem(at: sessionDirectory(sessionID: id, scope: scope))
  }

  func removeAll(scope: String?) {
    guard let scope else {
      return
    }
    try? fileManager.removeItem(at: scopeDirectory(scope: scope))
    defaults.removeObject(forKey: entryModeKey(scope: scope))
  }

  func lastEntryMode(scope: String?) -> CaptureEntryMode {
    guard let scope, Self.isPersistableScope(scope),
          let raw = defaults.string(forKey: entryModeKey(scope: scope)),
          let mode = CaptureEntryMode(rawValue: raw)
    else {
      return .describe
    }
    return mode
  }

  func saveLastEntryMode(_ mode: CaptureEntryMode, scope: String?) {
    guard let scope, Self.isPersistableScope(scope) else {
      return
    }
    defaults.set(mode.rawValue, forKey: entryModeKey(scope: scope))
  }

  private func write(_ items: [CaptureSessionSnapshot], scope: String) {
    let directory = scopeDirectory(scope: scope)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(items) {
      try? data.write(to: indexURL(scope: scope), options: .atomic)
    }
  }

  private func writeAttachments(_ attachments: [CaptureAttachment], sessionID: UUID, scope: String) {
    let directory = sessionDirectory(sessionID: sessionID, scope: scope)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let keep = Set(attachments.map(\.id))
    if let existing = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      for url in existing where url.pathExtension == "bin" {
        let name = url.deletingPathExtension().lastPathComponent
        if UUID(uuidString: name).map({ !keep.contains($0) }) == true {
          try? fileManager.removeItem(at: url)
        }
      }
    }
    for attachment in attachments {
      let url = attachmentURL(sessionID: sessionID, attachmentID: attachment.id, scope: scope)
      if let existing = try? Data(contentsOf: url), existing == attachment.data {
        continue
      }
      try? attachment.data.write(to: url, options: .atomic)
    }
  }

  private func scopeDirectory(scope: String) -> URL {
    let digest = SHA256.hash(data: Data(scope.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return rootURL.appendingPathComponent(hex, isDirectory: true)
  }

  private func sessionDirectory(sessionID: UUID, scope: String) -> URL {
    scopeDirectory(scope: scope).appendingPathComponent(sessionID.uuidString, isDirectory: true)
  }

  private func indexURL(scope: String) -> URL {
    scopeDirectory(scope: scope).appendingPathComponent("sessions.json")
  }

  private func attachmentURL(sessionID: UUID, attachmentID: UUID, scope: String) -> URL {
    sessionDirectory(sessionID: sessionID, scope: scope)
      .appendingPathComponent("\(attachmentID.uuidString).bin")
  }

  private func entryModeKey(scope: String) -> String {
    "HowMuch.CaptureEntryMode.\(scope)"
  }

  static func isPersistableScope(_ scope: String) -> Bool {
    let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed != "*"
  }
}
