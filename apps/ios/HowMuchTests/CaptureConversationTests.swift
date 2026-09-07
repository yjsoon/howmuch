import XCTest
@testable import HowMuch

@MainActor
final class CaptureConversationTests: XCTestCase {
  func testLegacySnapshotDecodesWithoutOwnershipAndHydratesOnce() throws {
    let session = Self.session()
    let item = CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000))
    session.replaceDrafts([item])
    session.appendUserMessage("Lunch $12")
    session.appendAssistantMessage("Added lunch.")
    var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.snapshot())) as! [String: Any]
    encoded.removeValue(forKey: "pendingAttachmentIDs")
    encoded.removeValue(forKey: "frozenTurn")
    if var messages = encoded["messages"] as? [[String: Any]] {
      messages = messages.map { message in
        var next = message
        for key in ["ownedDraftIDs", "updatedDraftIDs", "queryID", "attachmentIDs", "frozenAccountID", "frozenAccountName", "frozenLocalDate", "replyState", "ownerAnnotation", "frozenTurn"] {
          next.removeValue(forKey: key)
        }
        return next
      }
      encoded["messages"] = messages
    }
    let data = try JSONSerialization.data(withJSONObject: encoded)
    let snapshot = try JSONDecoder().decode(CaptureSessionSnapshot.self, from: data)
    XCTAssertNil(snapshot.pendingAttachmentIDs)
    XCTAssertNil(snapshot.frozenTurn)
    XCTAssertTrue(snapshot.messages[1].ownedDraftIDs.isEmpty)
    let restored = CaptureSession.restore(snapshot, attachments: [])
    XCTAssertEqual(restored.ownedDrafts(for: restored.messages[1]).map(\.id), [item.id])
    let again = restored.messages[1].ownedDraftIDs
    restored.hydrateOwnershipIfNeeded()
    XCTAssertEqual(restored.messages[1].ownedDraftIDs, again)
    XCTAssertEqual(restored.messages.filter { $0.ownedDraftIDs.contains(item.id) }.count, 1)
  }

  func testIndependentAddsOwnSeparateGroupsAndCorrectionKeepsOnePreview() {
    let session = Self.session()
    session.apply(
      turn: Self.addTurn("Added lunch."),
      mapped: [Self.mapped(amount: 12_000, payee: "Lunch")]
    )
    session.apply(
      turn: Self.addTurn("Added taxi."),
      mapped: [Self.mapped(amount: 8_000, payee: "Taxi")]
    )
    let lunch = session.drafts[0]
    let taxi = session.drafts[1]
    let owners = session.messages.filter { $0.kind == .assistant }
    XCTAssertEqual(owners.count, 2)
    XCTAssertEqual(owners[0].ownedDraftIDs, [lunch.id])
    XCTAssertEqual(owners[1].ownedDraftIDs, [taxi.id])
    XCTAssertEqual(session.ownerMessageID(forDraft: lunch.id), owners[0].id)
    XCTAssertEqual(session.ownerMessageID(forDraft: taxi.id), owners[1].id)

    var corrected = lunch.draft
    corrected.amountMagnitudeMilli = 21_000
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Updated lunch to $21.",
        mutations: [CaptureDraftMutation(targetDraftID: lunch.id, extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [Self.mapped(amount: 21_000, payee: "Lunch")]
    )
    XCTAssertEqual(session.drafts.filter { $0.id == lunch.id }.count, 1)
    XCTAssertEqual(session.ownerMessageID(forDraft: lunch.id), owners[0].id)
    XCTAssertEqual(session.messages.last?.updatedDraftIDs, [lunch.id])
    XCTAssertEqual(owners[0].id, session.ownerMessageID(forDraft: lunch.id))
    XCTAssertEqual(session.messages.first { $0.id == owners[0].id }?.ownerAnnotation, "Updated after your correction")

    session.undo()
    XCTAssertEqual(session.drafts.first { $0.id == lunch.id }?.draft.amountMagnitudeMilli, 12_000)
    XCTAssertEqual(session.messages.first { $0.id == owners[0].id }?.ownerAnnotation, "Update undone")
    XCTAssertEqual(session.ownerMessageID(forDraft: lunch.id), owners[0].id)
  }

  func testGroupSaveMarksOnlyOwnedIncludedDraftsAndLeavesOthersEditable() {
    let session = Self.session()
    session.apply(turn: Self.addTurn("Added lunch."), mapped: [Self.mapped(amount: 12_000, payee: "Lunch")])
    session.apply(turn: Self.addTurn("Added two."), mapped: [
      Self.mapped(amount: 5_000, payee: "Coffee"),
      Self.mapped(amount: 8_000, payee: "Taxi"),
    ])
    let first = session.drafts[0]
    let coffee = session.drafts[1]
    let taxi = session.drafts[2]
    session.toggleIncluded(taxi.id)
    XCTAssertTrue(session.canSaveGroup(ids: [coffee.id]))
    XCTAssertFalse(session.canSaveGroup(ids: [first.id, coffee.id]))
    session.markCommitted(ids: [coffee.id])
    XCTAssertTrue(session.drafts[1].committed)
    XCTAssertFalse(session.drafts[1].included)
    XCTAssertFalse(session.drafts[0].committed)
    XCTAssertFalse(session.drafts[2].committed)
    XCTAssertTrue(session.drafts[0].included)
    XCTAssertFalse(session.canSaveGroup(ids: [coffee.id]))
    session.undo()
    XCTAssertTrue(session.drafts[1].committed)
    XCTAssertFalse(session.drafts.contains { $0.id == coffee.id && !$0.committed })
  }

  func testFreezeMovesAttachmentsAndRestoreKeepsBytesWithoutRepeatingPrompt() throws {
    let session = Self.session()
    let bytes = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02, 0x03])
    let attachment = CaptureAttachment(filename: "slip.jpg", data: bytes, recognizedText: "LUNCH 12")
    session.addAttachment(attachment)
    session.composerText = "Lunch with Jo"
    let frozen = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    XCTAssertTrue(session.attachments.isEmpty)
    XCTAssertEqual(session.sentAttachments.map(\.id), [attachment.id])
    XCTAssertEqual(session.sentAttachments[0].data, bytes)
    XCTAssertEqual(session.composerText, "")
    XCTAssertEqual(frozen.attachmentIDs, [attachment.id])
    XCTAssertEqual(session.messages[0].attachmentIDs, [attachment.id])
    XCTAssertEqual(session.messages[1].replyState, .generating)

    session.composerText = "Also coffee"
    let context = CaptureInterpreterPrompt.context(
      text: frozen.text,
      session: session,
      accounts: [Self.account()],
      attachmentIDs: frozen.attachmentIDs
    )
    XCTAssertEqual(context.attachmentTranscripts, ["LUNCH 12"])
    let next = CaptureInterpreterPrompt.context(
      text: session.composerText,
      session: session,
      accounts: [Self.account()]
    )
    XCTAssertTrue(next.attachmentTranscripts.isEmpty)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.chat.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let writer = CaptureWorkspace(store: store)
    writer.activate(scopeKey: "scope-a")
    session.scopeKey = "scope-a"
    writer.current = session
    writer.persistCurrentIfNeeded()
    XCTAssertTrue(writer.current === session)

    let reader = CaptureWorkspace(store: store)
    reader.activate(scopeKey: "scope-a")
    XCTAssertNil(reader.current)
    let restored = reader.resume(session.id)
    XCTAssertEqual(restored?.id, session.id)
    XCTAssertFalse(restored === session)
    XCTAssertEqual(reader.pendingAssistantSessionID, session.id)
    XCTAssertEqual(restored?.sentAttachments.first?.data, bytes)
    XCTAssertTrue(restored?.attachments.isEmpty == true)
    XCTAssertEqual(restored?.messages.first?.attachmentIDs, [attachment.id])
    XCTAssertEqual(restored?.messages.first { $0.id == frozen.replyMessageID }?.replyState, .stopped)
    XCTAssertFalse(restored?.isBusy == true)
  }

  func testStopAndRetryReuseReplySlotAndKeepLaterComposerText() {
    let session = Self.session()
    session.composerText = "Lunch $12"
    let frozen = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    let token = session.beginTurn()
    session.composerText = "Typed for next turn"
    session.stopActiveReply()
    XCTAssertFalse(session.isBusy)
    XCTAssertFalse(session.matchesTurn(generation: token.generation))
    XCTAssertEqual(session.messages.filter { $0.kind == .user }.count, 1)
    XCTAssertEqual(session.messages.filter { $0.kind == .assistant }.count, 1)
    XCTAssertEqual(session.messages.last?.replyState, .stopped)
    XCTAssertEqual(session.messages.last?.text, "Stopped · Nothing saved")
    XCTAssertEqual(session.composerText, "Typed for next turn")

    let retried = session.prepareRetry(replyID: frozen.replyMessageID)
    XCTAssertEqual(retried?.userMessageID, frozen.userMessageID)
    XCTAssertEqual(retried?.replyMessageID, frozen.replyMessageID)
    XCTAssertEqual(session.messages.filter { $0.kind == .assistant }.count, 1)
    XCTAssertEqual(session.messages.last?.replyState, .generating)
    XCTAssertEqual(session.composerText, "Typed for next turn")
    session.recordFailedTurn("Couldn't finish.")
    XCTAssertEqual(session.messages.filter { $0.kind == .assistant }.count, 1)
    XCTAssertEqual(session.messages.last?.replyState, .failed)
    XCTAssertEqual(session.composerText, "Typed for next turn")
  }

  func testNextAccountSelectionDoesNotBulkRetargetExistingDrafts() {
    let session = Self.session()
    session.apply(turn: Self.addTurn("Added lunch."), mapped: [Self.mapped(amount: 12_000, payee: "Lunch")])
    XCTAssertEqual(session.drafts[0].draft.accountID, "acct-everyday")
    let accounts = [
      Self.account(),
      Account(id: "acct-travel", name: "Travel", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false),
    ]
    session.selectAccount("acct-travel", accounts: accounts)
    XCTAssertEqual(session.selectedAccountID, "acct-travel")
    XCTAssertEqual(session.drafts[0].draft.accountID, "acct-everyday")
    let frozen = session.freezeComposerTurn(accountName: "Travel", localDate: "2026-09-06")
    XCTAssertEqual(frozen.accountID, "acct-travel")
    XCTAssertEqual(session.messages.first { $0.id == frozen.userMessageID }?.frozenAccountName, "Travel")
    XCTAssertEqual(session.drafts[0].draft.accountID, "acct-everyday")
  }

  func testTwoManualDonesCreateSeparateDraftsAndRejectSavedUpsert() {
    let session = Self.session()
    XCTAssertTrue(session.drafts.isEmpty)
    var first = Self.draft(payee: "Lunch", amount: 12_000)
    var engine = AmountKeypadEngine()
    engine.setValue(5_000)
    engine.tapOperator(.add)
    engine.tapDigit(2)
    engine.tapDigit(0)
    engine.tapDigit(0)
    first.amountMagnitudeMilli = engine.commitValue()
    let lunch = session.appendManualDraft(first)
    XCTAssertEqual(session.drafts.count, 1)
    XCTAssertEqual(lunch.draft.amountMagnitudeMilli, 7_000)
    XCTAssertEqual(session.messages.filter { $0.text == "Entered manually" }.count, 1)

    let taxi = session.appendManualDraft(Self.draft(payee: "Taxi", amount: 8_000))
    XCTAssertEqual(session.drafts.count, 2)
    XCTAssertNotEqual(lunch.id, taxi.id)
    XCTAssertEqual(session.messages.filter { $0.text == "Entered manually" }.count, 2)
    XCTAssertEqual(session.ownerMessageID(forDraft: lunch.id), session.messages.first { $0.ownedDraftIDs == [lunch.id] }?.id)
    XCTAssertEqual(session.ownerMessageID(forDraft: taxi.id), session.messages.first { $0.ownedDraftIDs == [taxi.id] }?.id)

    var cancelled = lunch.draft
    cancelled.payeeName = "Dinner"
    // Cancel does not call applyManualEdit; original stays.
    XCTAssertEqual(session.drafts.first { $0.id == lunch.id }?.draft.payeeName, "Lunch")
    session.applyManualEdit(cancelled, id: lunch.id)
    XCTAssertEqual(session.drafts.first { $0.id == lunch.id }?.draft.payeeName, "Dinner")
    XCTAssertTrue(session.canUndoDraft(lunch.id))
    session.undo()
    XCTAssertEqual(session.drafts.first { $0.id == lunch.id }?.draft.payeeName, "Lunch")

    session.markCommitted(ids: [taxi.id])
    var overwrite = taxi.draft
    overwrite.payeeName = "Should not apply"
    overwrite.importID = taxi.id
    session.upsertManualDraft(overwrite)
    XCTAssertEqual(session.drafts.first { $0.id == taxi.id }?.draft.payeeName, "Taxi")
    XCTAssertTrue(session.drafts.first { $0.id == taxi.id }?.committed == true)
    XCTAssertEqual(session.drafts.count, 2)
  }

  func testFailedThenSuccessfulReplyRetryTargetsTheFailedTurn() {
    let session = Self.session()
    session.composerText = "First"
    let failed = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    let failToken = session.beginTurn()
    session.recordFailedTurn("Couldn't finish first.")
    _ = session.finishTurn(generation: failToken.generation)
    XCTAssertEqual(session.messages.first { $0.id == failed.replyMessageID }?.replyState, .failed)

    session.composerText = "Second"
    let success = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    _ = session.beginTurn()
    session.apply(
      turn: Self.addTurn("Added lunch."),
      mapped: [Self.mapped(amount: 12_000, payee: "Lunch")],
      expectedGeneration: session.generation
    )
    _ = session.finishTurn(generation: session.generation)
    XCTAssertEqual(session.messages.first { $0.id == success.replyMessageID }?.replyState, .complete)
    XCTAssertNil(session.prepareRetry(replyID: success.replyMessageID))
    XCTAssertEqual(session.messages.filter { $0.kind == .assistant }.count, 2)

    let retried = session.prepareRetry(replyID: failed.replyMessageID)
    XCTAssertEqual(retried?.replyMessageID, failed.replyMessageID)
    XCTAssertEqual(retried?.text, "First")
    XCTAssertEqual(session.messages.filter { $0.kind == .assistant }.count, 2)
    XCTAssertEqual(session.messages.first { $0.id == failed.replyMessageID }?.replyState, .generating)
    XCTAssertEqual(session.messages.first { $0.id == success.replyMessageID }?.replyState, .complete)
    XCTAssertEqual(session.messages.first { $0.id == success.replyMessageID }?.ownedDraftIDs, session.drafts.map(\.id))
  }

  func testOldPendingClarificationDoesNotMutateALaterReply() {
    let session = Self.session()
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    session.ownUnownedDrafts(as: "Entered from a shortcut")
    session.composerText = "Make that 21"
    let first = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    _ = session.beginTurn()
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Which transaction should I change?",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [Self.mapped(amount: 21_000, payee: "Coffee")],
      expectedGeneration: session.generation
    )
    _ = session.finishTurn(generation: session.generation)
    XCTAssertEqual(session.pendingUpdateReplyID, first.replyMessageID)
    XCTAssertFalse(session.pendingTargetDraftIDs.isEmpty)

    session.composerText = "Taxi $8"
    let second = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    XCTAssertNil(session.pendingUpdateReplyID)
    XCTAssertTrue(session.pendingTargetDraftIDs.isEmpty)
    _ = session.beginTurn()
    session.apply(
      turn: Self.addTurn("Added taxi."),
      mapped: [Self.mapped(amount: 8_000, payee: "Taxi")],
      expectedGeneration: session.generation
    )
    _ = session.finishTurn(generation: session.generation)
    XCTAssertEqual(session.messages.first { $0.id == first.replyMessageID }?.text, "Which transaction should I change?")
    XCTAssertEqual(session.messages.first { $0.id == second.replyMessageID }?.ownedDraftIDs.isEmpty, false)
    XCTAssertEqual(session.drafts.filter { $0.draft.payeeName == "Coffee" }.first?.draft.amountMagnitudeMilli, 5_000)
  }

  func testRetryUsesFrozenAccountAndDateNotLiveContext() {
    let session = Self.session()
    session.composerText = "Lunch $12"
    let frozen = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-01")
    let failToken = session.beginTurn()
    session.recordFailedTurn("Couldn't finish.")
    _ = session.finishTurn(generation: failToken.generation)
    let accounts = [
      Self.account(),
      Account(id: "acct-travel", name: "Travel", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false),
    ]
    session.selectAccount("acct-travel", accounts: accounts)
    XCTAssertEqual(session.selectedAccountID, "acct-travel")
    let retried = session.prepareRetry(replyID: frozen.replyMessageID)
    XCTAssertEqual(retried?.accountID, "acct-everyday")
    XCTAssertEqual(retried?.localDate, "2026-09-01")
    let context = CaptureInterpreterPrompt.context(
      text: retried?.text ?? "",
      session: session,
      accounts: accounts,
      frozen: retried
    )
    XCTAssertEqual(context.selectedAccountID, "acct-everyday")
    XCTAssertEqual(context.selectedAccountName, "Everyday")
    XCTAssertEqual(context.today, "2026-09-01")
    XCTAssertEqual(session.selectedAccountID, "acct-travel")

    _ = session.beginTurn()
    session.apply(
      turn: Self.addTurn("Added lunch."),
      mapped: [Self.mapped(amount: 12_000, payee: "Lunch")],
      expectedGeneration: session.generation
    )
    XCTAssertEqual(session.drafts.last?.draft.accountID, "acct-everyday")
    let formatter = DateFormatter()
    formatter.calendar = Calendar.current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = Calendar.current.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    XCTAssertEqual(formatter.string(from: session.drafts.last?.draft.date ?? .distantPast), "2026-09-01")
    XCTAssertEqual(session.selectedAccountID, "acct-travel")
  }

  func testContinueInAssistantKeepsTheSameSessionID() {
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.expand.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      )
    )
    let session = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account()],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    session.composerText = "Keep this"
    let id = session.id
    workspace.continueInAssistant()
    XCTAssertEqual(workspace.pendingAssistantSessionID, id)
    XCTAssertTrue(workspace.shouldOpenAssistant)
    XCTAssertEqual(workspace.current?.id, id)
    XCTAssertEqual(workspace.current?.composerText, "Keep this")
  }

  func testClarificationReplyListsTargetsAndChooseUpdatesOnlyThatDraft() {
    let session = Self.session()
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    session.ownUnownedDrafts(as: "Entered from a shortcut")
    session.composerText = "Make that 21"
    let clarification = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    _ = session.beginTurn()
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Which transaction should I change?",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [Self.mapped(amount: 21_000, payee: "Coffee")],
      expectedGeneration: session.generation
    )
    _ = session.finishTurn(generation: session.generation)
    let reply = session.messages.first { $0.id == clarification.replyMessageID }
    XCTAssertEqual(reply?.ownedDraftIDs, [])
    XCTAssertEqual(session.pendingUpdateReplyID, clarification.replyMessageID)
    let choices = session.pendingTargetDrafts()
    XCTAssertEqual(Set(choices.map(\.draft.payeeName)), ["Coffee", "Lunch"])
    XCTAssertEqual(
      session.groupSaveBlockReason(ids: session.drafts.map(\.id)),
      "Choose which transaction to change before saving."
    )
    let coffee = choices.first { $0.draft.payeeName == "Coffee" }!
    session.chooseTargetDraft(coffee.id)
    XCTAssertEqual(session.drafts.first { $0.id == coffee.id }?.draft.amountMagnitudeMilli, 21_000)
    XCTAssertEqual(session.drafts.first { $0.draft.payeeName == "Lunch" }?.draft.amountMagnitudeMilli, 12_000)
    XCTAssertTrue(session.pendingTargetDraftIDs.isEmpty)
    XCTAssertNotEqual(
      session.groupSaveBlockReason(ids: session.drafts.map(\.id)),
      "Choose which transaction to change before saving."
    )
    XCTAssertEqual(session.messages.first { $0.id == clarification.replyMessageID }?.ownedDraftIDs, [])
  }

  func testUndoIsLocalToChangedOrRemovedOwnedDrafts() {
    let session = Self.session()
    session.apply(turn: Self.addTurn("Added lunch."), mapped: [Self.mapped(amount: 12_000, payee: "Lunch")])
    session.apply(turn: Self.addTurn("Added taxi."), mapped: [Self.mapped(amount: 8_000, payee: "Taxi")])
    let lunch = session.drafts[0]
    let taxi = session.drafts[1]
    let lunchOwner = session.messages.first { $0.ownedDraftIDs.contains(lunch.id) }!
    let taxiOwner = session.messages.first { $0.ownedDraftIDs.contains(taxi.id) }!
    var edited = lunch.draft
    edited.amountMagnitudeMilli = 21_000
    session.applyManualEdit(edited, id: lunch.id)
    XCTAssertTrue(session.canUndo(ownedIDs: lunchOwner.ownedDraftIDs))
    XCTAssertFalse(session.canUndo(ownedIDs: taxiOwner.ownedDraftIDs))

    session.removeDraft(taxi.id)
    XCTAssertTrue(session.drafts.contains { $0.id == lunch.id })
    XCTAssertFalse(session.drafts.contains { $0.id == taxi.id })
    XCTAssertTrue(session.canUndo(ownedIDs: taxiOwner.ownedDraftIDs))
    XCTAssertFalse(session.canUndo(ownedIDs: lunchOwner.ownedDraftIDs))
    session.undo()
    XCTAssertEqual(session.drafts.first { $0.id == taxi.id }?.id, taxi.id)
    XCTAssertEqual(session.ownerMessageID(forDraft: taxi.id), taxiOwner.id)
    XCTAssertEqual(session.drafts.first { $0.id == lunch.id }?.draft.amountMagnitudeMilli, 21_000)
  }

  func testRemovingOnlyOwnedDraftCanUndoOnOwningReply() {
    let session = Self.session()
    session.apply(turn: Self.addTurn("Added lunch."), mapped: [Self.mapped(amount: 12_000, payee: "Lunch")])
    let lunch = session.drafts[0]
    let owner = session.messages.first { $0.ownedDraftIDs.contains(lunch.id) }!
    session.removeDraft(lunch.id)
    XCTAssertTrue(session.drafts.isEmpty)
    XCTAssertTrue(session.canUndo(ownedIDs: owner.ownedDraftIDs))
    session.undo()
    XCTAssertEqual(session.drafts.first?.id, lunch.id)
    XCTAssertEqual(session.ownerMessageID(forDraft: lunch.id), owner.id)
  }

  func testRemovingOnlyManualDraftCanUndoOnSystemOwner() {
    let session = Self.session()
    let lunch = session.appendManualDraft(Self.draft(payee: "Lunch", amount: 12_000))
    let owner = session.messages.first { $0.kind == .system && $0.ownedDraftIDs.contains(lunch.id) }!
    XCTAssertEqual(owner.text, "Entered manually")
    session.removeDraft(lunch.id)
    XCTAssertTrue(session.drafts.isEmpty)
    XCTAssertTrue(session.ownedDrafts(for: owner).isEmpty)
    XCTAssertTrue(session.canUndo(ownedIDs: owner.ownedDraftIDs))
    session.undo()
    XCTAssertEqual(session.drafts.first?.id, lunch.id)
    XCTAssertEqual(session.ownerMessageID(forDraft: lunch.id), owner.id)
  }

  func testUndoAfterLaterManualAddRestoresOnlyTheEditedDraft() {
    let session = Self.session()
    let lunch = session.appendManualDraft(Self.draft(payee: "Lunch", amount: 12_000))
    var edited = lunch.draft
    edited.amountMagnitudeMilli = 21_000
    session.applyManualEdit(edited, id: lunch.id)
    let taxi = session.appendManualDraft(Self.draft(payee: "Taxi", amount: 8_000))
    let lunchOwner = session.messages.first { $0.ownedDraftIDs.contains(lunch.id) }!
    let taxiOwner = session.messages.first { $0.ownedDraftIDs.contains(taxi.id) }!
    XCTAssertTrue(session.canUndo(ownedIDs: lunchOwner.ownedDraftIDs))
    XCTAssertFalse(session.canUndo(ownedIDs: taxiOwner.ownedDraftIDs))
    session.undo()
    XCTAssertEqual(session.drafts.first { $0.id == lunch.id }?.draft.amountMagnitudeMilli, 12_000)
    XCTAssertEqual(session.drafts.first { $0.id == taxi.id }?.id, taxi.id)
    XCTAssertEqual(session.ownerMessageID(forDraft: taxi.id), taxiOwner.id)
    XCTAssertEqual(session.drafts.count, 2)
  }

  func testToggleAndResolveDoNotLetUndoRollBackAnUnrelatedEdit() {
    let session = Self.session()
    session.apply(turn: Self.addTurn("Added lunch."), mapped: [Self.mapped(amount: 12_000, payee: "Lunch")])
    session.apply(turn: Self.addTurn("Added taxi."), mapped: [Self.mapped(amount: 8_000, payee: "Taxi")])
    let lunch = session.drafts[0]
    let taxi = session.drafts[1]
    var edited = lunch.draft
    edited.amountMagnitudeMilli = 21_000
    session.applyManualEdit(edited, id: lunch.id)
    let accounts = [
      Self.account(),
      Account(id: "acct-travel", name: "Travel", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false),
    ]
    session.selectAccount("acct-travel", accounts: accounts)
    session.toggleIncluded(taxi.id)
    session.resolveAccount("acct-travel", forDraft: taxi.id)
    session.resolveCategory("cat-travel", forDraft: taxi.id)
    XCTAssertTrue(session.canUndo(ownedIDs: [lunch.id]))
    XCTAssertFalse(session.canUndo(ownedIDs: [taxi.id]))
    session.undo()
    XCTAssertEqual(session.drafts.first { $0.id == lunch.id }?.draft.amountMagnitudeMilli, 12_000)
    XCTAssertEqual(session.drafts.first { $0.id == taxi.id }?.draft.accountID, "acct-travel")
    XCTAssertEqual(session.drafts.first { $0.id == taxi.id }?.draft.categoryID, "cat-travel")
    XCTAssertFalse(session.drafts.first { $0.id == taxi.id }?.included == true)
    XCTAssertEqual(session.selectedAccountID, "acct-travel")
  }

  func testPrepareRetryRefusesDuringIngestAndSaveThenReusesTheSameFrozenReply() {
    let session = Self.session()
    session.composerText = "Lunch $12"
    let frozen = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    let failToken = session.beginTurn()
    session.recordFailedTurn("Couldn't finish.")
    _ = session.finishTurn(generation: failToken.generation)
    let reply = session.messages.first { $0.id == frozen.replyMessageID }!
    session.composerText = "Typed for next turn"
    let generation = session.generation

    session.isTransferringImages = true
    XCTAssertTrue(session.isIngesting)
    XCTAssertFalse(session.canRetry(reply))
    XCTAssertNil(session.prepareRetry(replyID: frozen.replyMessageID))
    XCTAssertEqual(session.generation, generation)
    XCTAssertEqual(session.composerText, "Typed for next turn")
    XCTAssertTrue(session.isTransferringImages)
    XCTAssertEqual(session.messages.first { $0.id == frozen.replyMessageID }?.replyState, .failed)
    session.isTransferringImages = false

    let reading = CaptureAttachment(filename: "slip.jpg", data: Data([0xFF, 0xD8]), recognizedText: "", isReading: true)
    session.addAttachment(reading)
    XCTAssertTrue(session.isIngesting)
    XCTAssertFalse(session.canRetry(reply))
    XCTAssertNil(session.prepareRetry(replyID: frozen.replyMessageID))
    XCTAssertEqual(session.generation, generation)
    XCTAssertEqual(session.attachments.map(\.id), [reading.id])
    session.removeAttachment(reading.id)

    session.isSaving = true
    XCTAssertFalse(session.canRetry(reply))
    XCTAssertNil(session.prepareRetry(replyID: frozen.replyMessageID))
    XCTAssertEqual(session.generation, generation)
    XCTAssertEqual(session.composerText, "Typed for next turn")
    session.isSaving = false

    XCTAssertTrue(session.canRetry(session.messages.first { $0.id == frozen.replyMessageID }!))
    let retried = session.prepareRetry(replyID: frozen.replyMessageID)
    XCTAssertEqual(retried?.replyMessageID, frozen.replyMessageID)
    XCTAssertEqual(retried?.text, "Lunch $12")
    XCTAssertEqual(session.composerText, "Typed for next turn")
    XCTAssertEqual(session.messages.first { $0.id == frozen.replyMessageID }?.replyState, .generating)
  }

  func testRetryWithNilFrozenAccountDoesNotInheritLaterSelection() {
    let session = CaptureSession(scopeKey: "scope-a", origin: .lastUsedOpen, selectedAccountID: nil)
    session.composerText = "Lunch $12"
    let frozen = session.freezeComposerTurn(accountName: "Choose Account", localDate: "2026-09-01")
    XCTAssertNil(frozen.accountID)
    let failToken = session.beginTurn()
    session.recordFailedTurn("Couldn't finish.")
    _ = session.finishTurn(generation: failToken.generation)
    session.selectAccount("acct-travel", accounts: [
      Self.account(),
      Account(id: "acct-travel", name: "Travel", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false),
    ])
    let retried = session.prepareRetry(replyID: frozen.replyMessageID)
    XCTAssertNil(retried?.accountID)
    XCTAssertEqual(retried?.localDate, "2026-09-01")
    let context = CaptureInterpreterPrompt.context(
      text: retried?.text ?? "",
      session: session,
      accounts: [Self.account()],
      frozen: retried
    )
    XCTAssertEqual(context.selectedAccountID, "")
    XCTAssertEqual(context.selectedAccountName, "Choose Account")
    XCTAssertEqual(context.today, "2026-09-01")
    XCTAssertEqual(session.selectedAccountID, "acct-travel")
    _ = session.beginTurn()
    session.apply(
      turn: Self.addTurn("Added lunch."),
      mapped: [Self.mapped(amount: 12_000, payee: "Lunch")],
      expectedGeneration: session.generation
    )
    XCTAssertTrue(session.drafts.last?.draft.accountID.isEmpty == true)
    let formatter = DateFormatter()
    formatter.calendar = Calendar.current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = Calendar.current.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    XCTAssertEqual(formatter.string(from: session.drafts.last?.draft.date ?? .distantPast), "2026-09-01")
    XCTAssertEqual(session.selectedAccountID, "acct-travel")
  }

  func testClosedAccountBlocksGroupSave() {
    let session = Self.session()
    session.apply(turn: Self.addTurn("Added lunch."), mapped: [Self.mapped(amount: 12_000, payee: "Lunch")])
    let id = session.drafts[0].id
    XCTAssertTrue(session.canSaveGroup(ids: [id]))
    XCTAssertFalse(session.usesClosedOrMissingAccount(ids: [id], openAccounts: [Self.account()]))
    XCTAssertTrue(
      session.usesClosedOrMissingAccount(
        ids: [id],
        openAccounts: [
          Account(id: "acct-everyday", name: "Everyday", icon: nil, type: "checking", onBudget: true, closed: true, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false),
        ]
      )
    )
    XCTAssertTrue(session.usesClosedOrMissingAccount(ids: [id], openAccounts: []))
  }

  func testLegacyQueryCardsHydrateOntoMatchingAssistantOrSystemEvent() throws {
    let session = Self.session()
    let matched = LedgerQueryResult(
      title: "Recorded spending",
      detail: "You recorded $24.00 in dining.",
      totalMilliunits: 24_000,
      from: "2026-09-01",
      to: "2026-09-06",
      accountLabel: "Everyday",
      categoryLabel: "Dining",
      sourceRows: [
        LedgerQuerySourceRow(
          id: "src-1",
          date: "2026-09-06",
          payee: "Lunch",
          amount: -12_000,
          accountName: "Everyday",
          categoryName: "Dining"
        ),
      ],
      sourceCount: 1,
      isRecordedSpending: true,
      isUnavailable: false
    )
    let orphan = LedgerQueryResult(
      title: "Recorded spending",
      detail: "You recorded $8.00 in travel.",
      totalMilliunits: 8_000,
      from: "2026-09-01",
      to: "2026-09-06",
      accountLabel: "Travel",
      categoryLabel: "Travel",
      sourceCount: 1,
      isRecordedSpending: true,
      isUnavailable: false
    )
    session.appendUserMessage("How much did I spend on dining?")
    session.appendAssistantMessage(matched.detail)
    session.appendUserMessage("And travel?")
    session.appendAssistantMessage("I need a recorded-spending answer from the local ledger.")
    session.queryCards = [matched, orphan]
    var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.snapshot())) as! [String: Any]
    if var messages = encoded["messages"] as? [[String: Any]] {
      messages = messages.map { message in
        var next = message
        next.removeValue(forKey: "queryID")
        return next
      }
      encoded["messages"] = messages
    }
    let snapshot = try JSONDecoder().decode(
      CaptureSessionSnapshot.self,
      from: try JSONSerialization.data(withJSONObject: encoded)
    )
    XCTAssertTrue(snapshot.messages.allSatisfy { $0.queryID == nil })
    let restored = CaptureSession.restore(snapshot, attachments: [])
    XCTAssertEqual(restored.messages.first { $0.text == matched.detail }?.queryID, matched.id)
    XCTAssertEqual(restored.messages.first { $0.text == orphan.detail }?.kind, .system)
    XCTAssertEqual(restored.messages.first { $0.text == orphan.detail }?.queryID, orphan.id)
    XCTAssertFalse(restored.messages.contains { $0.queryID == orphan.id && $0.text == "Entered manually" })
    XCTAssertEqual(restored.messages.filter { $0.queryID != nil }.count, 2)
    restored.hydrateOwnershipIfNeeded()
    XCTAssertEqual(restored.messages.filter { $0.queryID == matched.id }.count, 1)
    XCTAssertEqual(restored.messages.filter { $0.queryID == orphan.id }.count, 1)
  }

  func testStopCancelsOwnedConversationTaskAndExpandDoesNot() async {
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.cancel.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      )
    )
    _ = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Self.account()],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    var finishedAfterStop = false
    workspace.runConversationTurn {
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else {
        return
      }
      finishedAfterStop = true
    }
    workspace.cancelOwnedConversationWork()
    try? await Task.sleep(for: .milliseconds(350))
    XCTAssertFalse(finishedAfterStop)

    var finishedAfterExpand = false
    workspace.runConversationTurn {
      try? await Task.sleep(for: .milliseconds(80))
      guard !Task.isCancelled else {
        return
      }
      finishedAfterExpand = true
    }
    workspace.continueInAssistant()
    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(finishedAfterExpand)
  }

  private static func session() -> CaptureSession {
    CaptureSession(scopeKey: "scope-a", origin: .lastUsedOpen, selectedAccountID: "acct-everyday")
  }

  private static func addTurn(_ feedback: String) -> CaptureInterpretedTurn {
    CaptureInterpretedTurn(intent: .add, feedback: feedback, mutations: [], query: nil, applyToAllDrafts: false)
  }

  private static func draft(payee: String, amount: Int) -> TransactionDraft {
    var draft = TransactionDraft()
    draft.payeeName = payee
    draft.amountMagnitudeMilli = amount
    draft.accountID = "acct-everyday"
    return draft
  }

  private static func mapped(amount: Int, payee: String) -> SlipMappedDraft {
    var draft = TransactionDraft()
    draft.payeeName = payee
    draft.amountMagnitudeMilli = amount
    draft.accountID = ""
    return SlipMappedDraft(
      draft: draft,
      parsedAmount: true,
      parsedDate: false,
      parsedAccount: false,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
  }

  private static func account() -> Account {
    Account(id: "acct-everyday", name: "Everyday", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
  }
}
