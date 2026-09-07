import XCTest
@testable import HowMuch

@MainActor
final class CaptureWorkspaceTests: XCTestCase {
  func testScopeIsolationDoesNotLeakSessions() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    let defaults = UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!
    let store = CaptureWorkspaceStore(defaults: defaults, rootURL: directory)
    let workspace = CaptureWorkspace(store: store)

    workspace.activate(scopeKey: "https://a|user-a|plan-a")
    _ = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "https://a|user-a|plan-a",
      openAccounts: [Self.account("acct-a", "Everyday")],
      lastUsedAccountID: "acct-a",
      focusedRegisterAccountID: nil
    )
    workspace.current?.appendUserMessage("Lunch $12")
    workspace.persistCurrentIfNeeded()
    XCTAssertEqual(workspace.recents.count, 1)

    workspace.activate(scopeKey: "https://b|user-b|plan-b")
    XCTAssertNil(workspace.current)
    XCTAssertTrue(workspace.recents.isEmpty)

    workspace.activate(scopeKey: "https://a|user-a|plan-a")
    XCTAssertEqual(workspace.recents.count, 1)
    XCTAssertEqual(workspace.recents.first?.messages.first?.text, "Lunch $12")
  }

  func testSignOutDropsInMemorySession() {
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      )
    )
    workspace.activate(scopeKey: "scope-a")
    _ = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .homeScreenShortcut),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-a", "Everyday")],
      lastUsedAccountID: "acct-a",
      focusedRegisterAccountID: "acct-travel"
    )
    XCTAssertEqual(workspace.current?.selectedAccountID, "acct-a")
    workspace.dropForScopeChange()
    XCTAssertNil(workspace.current)
    XCTAssertTrue(workspace.recents.isEmpty)
  }

  func testAdmissionFreezesOriginAwayFromFocusedRegisterForHomeScreen() {
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      )
    )
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .homeScreenShortcut),
      scopeKey: "scope-a",
      openAccounts: [
        Self.account("acct-everyday", "Everyday"),
        Self.account("acct-travel", "Travel"),
      ],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: "acct-travel"
    )
    XCTAssertEqual(session.origin, .homeScreenShortcut)
    XCTAssertEqual(session.selectedAccountID, "acct-everyday")
  }

  func testResumeOfCurrentSessionSetsPendingAssistant() {
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      )
    )
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    session.appendUserMessage("Keep me")
    workspace.pendingAssistantSessionID = nil
    let resumed = workspace.resume(session.id)
    XCTAssertEqual(resumed?.id, session.id)
    XCTAssertEqual(workspace.pendingAssistantSessionID, session.id)
  }

  func testEmptyScopeNeverPersistsFinancialData() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    let defaults = UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!
    let store = CaptureWorkspaceStore(defaults: defaults, rootURL: directory)
    let workspace = CaptureWorkspace(store: store)
    workspace.activate(scopeKey: "")
    _ = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    workspace.current?.composerText = "Lunch $12"
    workspace.persistCurrentIfNeeded()
    XCTAssertTrue(workspace.recents.isEmpty)
    XCTAssertTrue((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.isEmpty != false)
  }

  func testDistinctSlashScopesDoNotSharePersistedSessions() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let first = CaptureSessionSnapshot(
      id: UUID(),
      createdAt: .now,
      updatedAt: .now,
      scopeKey: "https://a/b",
      origin: .lastUsedOpen,
      selectedAccountID: "acct-a",
      entryMode: .describe,
      drafts: [],
      messages: [CaptureMessage(kind: .user, text: "scope slash")],
      attachmentRecords: [],
      lastFeedback: nil,
      claimedInboxIDs: [],
      queryCards: [],
      composerText: "slash",
      selectedManualDraftID: nil
    )
    let second = CaptureSessionSnapshot(
      id: UUID(),
      createdAt: .now,
      updatedAt: .now,
      scopeKey: "https://a_b",
      origin: .lastUsedOpen,
      selectedAccountID: "acct-b",
      entryMode: .describe,
      drafts: [],
      messages: [CaptureMessage(kind: .user, text: "scope underscore")],
      attachmentRecords: [],
      lastFeedback: nil,
      claimedInboxIDs: [],
      queryCards: [],
      composerText: "underscore",
      selectedManualDraftID: nil
    )
    store.save(snapshot: first, attachments: [], scope: "https://a/b")
    store.save(snapshot: second, attachments: [], scope: "https://a_b")
    XCTAssertEqual(store.load(scope: "https://a/b").first?.composerText, "slash")
    XCTAssertEqual(store.load(scope: "https://a_b").first?.composerText, "underscore")
    XCTAssertEqual(store.load(scope: "https://a/b").count, 1)
  }

  func testComposerTextSurvivesPersistAndRestore() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
        rootURL: directory
      )
    )
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    session.composerText = "Lunch $12 still typing"
    workspace.persistCurrentIfNeeded()
    workspace.activate(scopeKey: "scope-other")
    workspace.activate(scopeKey: "scope-a")
    let restored = workspace.resume(workspace.recents[0].id)
    XCTAssertEqual(restored?.composerText, "Lunch $12 still typing")
  }

  func testAdmitAndResumeCancelOutgoingTurns() {
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      )
    )
    let first = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    first.appendUserMessage("Keep me")
    let token = first.beginTurn()
    let second = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertFalse(first.matchesTurn(generation: token.generation))
    XCTAssertFalse(first.isBusy)
    second.appendUserMessage("Second")
    workspace.persistCurrentIfNeeded()
    let thirdToken = second.beginTurn()
    let resumed = workspace.resume(workspace.recents.first(where: { $0.id == first.id })!.id)
    XCTAssertEqual(resumed?.id, first.id)
    XCTAssertFalse(second.matchesTurn(generation: thirdToken.generation))
  }

  func testSamePlanScopeSwitchDropsCurrentSession() {
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      )
    )
    let first = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "https://a|user-a|plan-x",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    let token = first.beginTurn()
    workspace.activate(scopeKey: "https://b|user-b|plan-x")
    XCTAssertNil(workspace.current)
    XCTAssertFalse(first.matchesTurn(generation: token.generation))
    let second = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "b", origin: .lastUsedOpen),
      scopeKey: "https://b|user-b|plan-x",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    XCTAssertEqual(second.scopeKey, "https://b|user-b|plan-x")
    XCTAssertNotEqual(second.id, first.id)
  }

  func testAdmissionGateWaitsWhileReferenceIsLoading() {
    XCTAssertFalse(CaptureAdmissionGate.canAdmit(referencePhase: .idle))
    XCTAssertFalse(CaptureAdmissionGate.canAdmit(referencePhase: .loading))
    XCTAssertTrue(CaptureAdmissionGate.canAdmit(referencePhase: .loaded))
    XCTAssertTrue(CaptureAdmissionGate.canAdmit(referencePhase: .failed("offline")))
  }

  func testAdmitDoesNotWriteLastUsedAndPersistsQueryCards() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    let defaults = UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!
    let store = CaptureWorkspaceStore(defaults: defaults, rootURL: directory)
    let workspace = CaptureWorkspace(store: store)
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    session.queryCards = [
      LedgerQueryResult(
        title: "This month",
        detail: "$12 recorded spending",
        totalMilliunits: 12_000,
        from: "2025-05-01",
        to: "2025-05-04",
        accountLabel: "All accounts",
        categoryLabel: "Recorded spending",
        sourceRows: [
          LedgerQuerySourceRow(
            id: "t1",
            date: "2025-05-03",
            payee: "Coffee",
            amount: -5_000,
            accountName: "Everyday"
          ),
        ],
        sourceCount: 1,
        isRecordedSpending: true,
        isUnavailable: false
      ),
    ]
    session.appendUserMessage("How much this month?")
    workspace.persistCurrentIfNeeded()
    workspace.activate(scopeKey: "scope-other")
    workspace.activate(scopeKey: "scope-a")
    XCTAssertEqual(workspace.recents.first?.queryCards.first?.sourceRows.first?.payee, "Coffee")
    XCTAssertEqual(defaults.string(forKey: "HowMuch.CaptureEntryMode.scope-a"), nil)
  }

  func testTypingBurstDeferredTaskPersistsLatest() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let workspace = CaptureWorkspace(store: store, persistDelay: .zero)
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    session.composerText = "L"
    let first = workspace.requestPersistCurrent()
    session.composerText = "Lu"
    let second = workspace.requestPersistCurrent()
    session.composerText = "Lunch $12"
    let final = workspace.requestPersistCurrent()
    XCTAssertTrue(store.load(scope: "scope-a").isEmpty)
    await final.value
    XCTAssertEqual(store.load(scope: "scope-a").first?.composerText, "Lunch $12")
    await first.value
    await second.value
    XCTAssertEqual(store.load(scope: "scope-a").first?.composerText, "Lunch $12")
  }

  func testCloseEquivalentFlushPersistsImmediately() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let workspace = CaptureWorkspace(store: store, persistDelay: .seconds(30))
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    session.composerText = "Close me"
    workspace.requestPersistCurrent()
    XCTAssertTrue(store.load(scope: "scope-a").isEmpty)
    workspace.persistCurrentIfNeeded()
    XCTAssertEqual(store.load(scope: "scope-a").first?.composerText, "Close me")
    XCTAssertEqual(workspace.recents.first?.composerText, "Close me")
  }

  func testDeferredPersistDoesNotResurrectDiscardedOrCrossScope() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let workspace = CaptureWorkspace(store: store, persistDelay: .zero)
    let discarded = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    discarded.composerText = "keep-then-discard"
    workspace.persistCurrentIfNeeded()
    XCTAssertEqual(store.load(scope: "scope-a").count, 1)
    discarded.composerText = "stale-resurrect"
    let discardedJob = workspace.requestPersistCurrent()
    workspace.discardCurrent()
    await discardedJob.value
    XCTAssertTrue(store.load(scope: "scope-a").isEmpty)

    let dropped = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    dropped.composerText = "from-a-unsent"
    let droppedJob = workspace.requestPersistCurrent()
    workspace.dropForScopeChange()
    await droppedJob.value
    XCTAssertEqual(store.load(scope: "scope-a").first?.composerText, "from-a-unsent")
    XCTAssertTrue(store.load(scope: "scope-b").isEmpty)

    let other = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "b", origin: .lastUsedOpen),
      scopeKey: "scope-b",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    other.composerText = "from-b"
    workspace.persistCurrentIfNeeded()
    XCTAssertEqual(store.load(scope: "scope-a").map(\.composerText), ["from-a-unsent"])
    XCTAssertEqual(store.load(scope: "scope-b").map(\.composerText), ["from-b"])
  }

  func testUnchangedAttachmentFileSurvivesMetadataPersist() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let workspace = CaptureWorkspace(store: store)
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    let bytes = Data([0xFF, 0xD8, 0x01, 0x02, 0x03, 0x04])
    session.addAttachment(CaptureAttachment(filename: "slip.jpg", data: bytes, recognizedText: "was"))
    workspace.persistCurrentIfNeeded()
    let file = Self.firstAttachmentFile(in: directory)
    XCTAssertNotNil(file)
    let identityBefore = file.flatMap(Self.fileNumber)
    XCTAssertNotNil(identityBefore)
    session.composerText = "metadata only"
    session.updateAttachment(
      CaptureAttachment(
        id: session.attachments[0].id,
        filename: "slip.jpg",
        data: bytes,
        recognizedText: "now"
      )
    )
    workspace.persistCurrentIfNeeded()
    XCTAssertEqual(file.flatMap(Self.fileNumber), identityBefore)
    XCTAssertEqual(try file.map { try Data(contentsOf: $0) }, bytes)
    workspace.activate(scopeKey: "scope-other")
    workspace.activate(scopeKey: "scope-a")
    let restored = workspace.resume(workspace.recents[0].id)
    XCTAssertEqual(restored?.composerText, "metadata only")
    XCTAssertEqual(restored?.attachments.first?.data, bytes)
    XCTAssertEqual(restored?.attachments.first?.recognizedText, "now")
  }

  func testReplacedAndNewAttachmentBytesArePersisted() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let workspace = CaptureWorkspace(store: store)
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    let originalID = UUID()
    session.addAttachment(
      CaptureAttachment(id: originalID, filename: "slip.jpg", data: Data([0x01, 0x02, 0x03]))
    )
    workspace.persistCurrentIfNeeded()
    session.updateAttachment(
      CaptureAttachment(id: originalID, filename: "slip.jpg", data: Data([0x0A, 0x0B, 0x0C]))
    )
    workspace.persistCurrentIfNeeded()
    let replacement = store.loadAttachments(snapshot: workspace.recents[0], scope: "scope-a")
    XCTAssertEqual(replacement.map(\.data), [Data([0x0A, 0x0B, 0x0C])])

    session.addAttachment(CaptureAttachment(filename: "other.jpg", data: Data([0x11, 0x22, 0x33])))
    workspace.persistCurrentIfNeeded()
    let both = store.loadAttachments(snapshot: workspace.recents[0], scope: "scope-a")
    XCTAssertEqual(both.count, 2)
    XCTAssertEqual(both.first(where: { $0.id == originalID })?.data, Data([0x0A, 0x0B, 0x0C]))
    XCTAssertEqual(Set(both.map(\.data)), Set([Data([0x0A, 0x0B, 0x0C]), Data([0x11, 0x22, 0x33])]))
  }

  func testFreshWorkspaceRoundtripRestoresPendingOCRAsRecoverableError() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let workspace = CaptureWorkspace(store: store)
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    let attachmentID = UUID()
    let bytes = Data([0xFF, 0xD8, 0xAA, 0xBB, 0xCC, 0xDD])
    session.addAttachment(
      CaptureAttachment(
        id: attachmentID,
        filename: "slip.jpg",
        data: bytes,
        recognizedText: "",
        isReading: true
      )
    )
    XCTAssertTrue(session.attachments[0].isReading)
    XCTAssertFalse(session.canSendComposer)
    workspace.persistCurrentIfNeeded()

    let fresh = CaptureWorkspace(store: store)
    fresh.activate(scopeKey: "scope-a")
    let restored = fresh.resume(session.id)
    XCTAssertEqual(restored?.attachments.first?.id, attachmentID)
    XCTAssertEqual(restored?.attachments.first?.data, bytes)
    XCTAssertEqual(restored?.attachments.first?.filename, "slip.jpg")
    XCTAssertEqual(restored?.attachments.first?.recognizedText, "")
    XCTAssertEqual(restored?.attachments.count, 1)
    XCTAssertNotNil(restored)
    XCTAssertEqual(restored?.attachments.first?.isReading, false)
    XCTAssertFalse(restored?.attachments.first?.errorMessage?.isEmpty ?? true, "pending empty transcript needs an explicit recoverable error")
    restored?.composerText = "Lunch $12"
    XCTAssertEqual(restored?.canSendComposer, false, "Send must stay blocked for pending recovery, including typed text")
  }

  func testFreshWorkspaceRoundtripKeepsRecognizedImageReadyToSend() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let workspace = CaptureWorkspace(store: store)
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    let attachmentID = UUID()
    let bytes = Data([0xFF, 0xD8, 0x11, 0x22])
    session.addAttachment(
      CaptureAttachment(
        id: attachmentID,
        filename: "slip.jpg",
        data: bytes,
        recognizedText: "SLIP"
      )
    )
    workspace.persistCurrentIfNeeded()
    let fresh = CaptureWorkspace(store: store)
    fresh.activate(scopeKey: "scope-a")
    let restored = fresh.resume(session.id)
    XCTAssertEqual(restored?.attachments.first?.id, attachmentID)
    XCTAssertEqual(restored?.attachments.first?.recognizedText, "SLIP")
    XCTAssertEqual(restored?.attachments.first?.isReading, false)
    XCTAssertNil(restored?.attachments.first?.errorMessage)
    XCTAssertEqual(restored?.canSendComposer, true)
  }

  func testPersistedAttachmentErrorSurvivesFreshWorkspaceLoad() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let workspace = CaptureWorkspace(store: store)
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    session.addAttachment(
      CaptureAttachment(
        filename: "slip.jpg",
        data: Data([0xFF, 0xD8, 0x33]),
        recognizedText: "",
        errorMessage: "I could not read text from that image. It is still attached."
      )
    )
    workspace.persistCurrentIfNeeded()
    let fresh = CaptureWorkspace(store: store)
    fresh.activate(scopeKey: "scope-a")
    let restored = fresh.resume(session.id)
    XCTAssertEqual(
      restored?.attachments.first?.errorMessage,
      "I could not read text from that image. It is still attached."
    )
    XCTAssertEqual(restored?.attachments.first?.isReading, false)
    XCTAssertEqual(restored?.canSendComposer, false)
  }

  func testLegacyAttachmentJSONWithoutReadingOrErrorFieldsStaysCompatible() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let workspace = CaptureWorkspace(store: store)
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account("acct-everyday", "Everyday")],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    let pendingID = UUID()
    let readyID = UUID()
    session.addAttachment(
      CaptureAttachment(id: pendingID, filename: "pending.jpg", data: Data([0x01, 0x02]), recognizedText: "")
    )
    session.addAttachment(
      CaptureAttachment(id: readyID, filename: "ready.jpg", data: Data([0x03, 0x04]), recognizedText: "SLIP")
    )
    workspace.persistCurrentIfNeeded()
    let original = store.load(scope: "scope-a")
    XCTAssertEqual(original.count, 1)
    let encodedRecords = try JSONEncoder().encode(original[0].attachmentRecords)
    let stripped = try Self.removingAttachmentStatusKeys(encodedRecords)
    let records = try JSONDecoder().decode([CaptureAttachmentRecord].self, from: stripped)
    XCTAssertEqual(records.count, 2)
    var decoded = original[0]
    decoded.attachmentRecords = records
    let bytes = store.loadAttachments(snapshot: original[0], scope: "scope-a")
    store.save(snapshot: decoded, attachments: bytes, scope: "scope-a")

    let fresh = CaptureWorkspace(store: store)
    fresh.activate(scopeKey: "scope-a")
    let restored = fresh.resume(decoded.id)
    let pending = restored?.attachments.first { $0.id == pendingID }
    let ready = restored?.attachments.first { $0.id == readyID }
    XCTAssertEqual(pending?.data, Data([0x01, 0x02]))
    XCTAssertEqual(ready?.data, Data([0x03, 0x04]))
    XCTAssertEqual(ready?.recognizedText, "SLIP")
    XCTAssertEqual(ready?.isReading, false)
    XCTAssertNil(ready?.errorMessage)
    XCTAssertEqual(pending?.isReading, false)
    XCTAssertFalse(pending?.errorMessage?.isEmpty ?? true, "legacy empty transcript must restore as explicit recovery")
  }

  private static func removingAttachmentStatusKeys(_ data: Data) throws -> Data {
    guard var records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return data
    }
    records = records.map { record in
      var next = record
      next.removeValue(forKey: "isReading")
      next.removeValue(forKey: "error")
      next.removeValue(forKey: "errorMessage")
      return next
    }
    return try JSONSerialization.data(withJSONObject: records)
  }

  private static func firstAttachmentFile(in directory: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
      return nil
    }
    return enumerator.compactMap { item in
      guard let url = item as? URL, url.pathExtension == "bin" else {
        return nil
      }
      return url
    }.first
  }

  private static func fileNumber(_ url: URL) -> NSNumber? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber
  }

  private static func account(_ id: String, _ name: String) -> Account {
    Account(
      id: id,
      name: name,
      icon: nil,
      type: "checking",
      onBudget: true,
      closed: false,
      balance: 0,
      clearedBalance: 0,
      unclearedBalance: 0,
      lastReconciledDate: nil,
      deleted: false
    )
  }
}
