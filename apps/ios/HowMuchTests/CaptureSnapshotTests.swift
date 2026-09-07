import SwiftUI
import UIKit
import XCTest
#if canImport(Vision)
import Vision
#endif
@testable import HowMuch

@MainActor
final class CaptureSnapshotTests: XCTestCase {
  func testDescribeManualAndImageStatesRenderIsolatedContent() async {
    let cases: [(String, [String], (SnapshotHarness) -> AnyView)] = [
      ("empty", ["Add an expense", "Everyday"], { harness in
        AnyView(AddTransactionsView(session: harness.admitEmpty(), workspace: harness.workspace))
      }),
      ("parsed", ["Lunch", "Groceries", "Everyday", "Not saved", "Save transaction"], { harness in
        AnyView(AddTransactionsView(session: harness.admitParsed(), workspace: harness.workspace))
      }),
      ("corrected", ["Lunch", "21.00", "Updated lunch to $21", "Not saved"], { harness in
        AnyView(AddTransactionsView(session: harness.admitCorrected(), workspace: harness.workspace))
      }),
      ("ambiguous", ["Which account?", "Everyday", "Travel"], { harness in
        AnyView(AddTransactionsView(session: harness.admitAmbiguous(), workspace: harness.workspace))
      }),
      ("clarification", ["Which transaction should I change?", "Coffee", "Lunch"], { harness in
        AnyView(AddTransactionsView(session: harness.admitClarification(), workspace: harness.workspace))
      }),
      ("multi", ["Coffee", "Lunch", "Save 2 transactions"], { harness in
        AnyView(AddTransactionsView(session: harness.admitMulti(), workspace: harness.workspace))
      }),
      ("image", ["Lunch", "Not saved"], { harness in
        AnyView(AddTransactionsView(session: harness.admitImage(), workspace: harness.workspace))
      }),
      ("manual", ["Entered manually", "Lunch", "Not saved"], { harness in
        AnyView(AddTransactionsView(session: harness.admitManual(), workspace: harness.workspace))
      }),
      ("sent-photo", ["Lunch with Jo", "Using Everyday"], { harness in
        AnyView(AddTransactionsView(session: harness.admitSentPhoto(), workspace: harness.workspace))
      }),
      ("pending-photo", ["Reading image"], { harness in
        AnyView(AddTransactionsView(session: harness.admitPendingPhoto(), workspace: harness.workspace))
      }),
      ("query", ["Recorded spending", "Inspect"], { harness in
        AnyView(AddTransactionsView(session: harness.admitQuery(), workspace: harness.workspace))
      }),
      ("error", ["Couldn't finish", "Enter manually"], { harness in
        AnyView(AddTransactionsView(session: harness.admitFailedReply(), workspace: harness.workspace))
      }),
      ("generating", ["Let me take a look"], { harness in
        AnyView(AddTransactionsView(session: harness.admitGenerating(), workspace: harness.workspace))
      }),
      ("parsed-dark", ["Lunch", "Groceries", "Everyday", "Not saved", "Save transaction"], { harness in
        AnyView(
          AddTransactionsView(session: harness.admitParsed(), workspace: harness.workspace)
            .environment(\.colorScheme, .dark)
        )
      }),
      ("long-account", ["Everyday Joint Household Spending", "Open in Assistant"], { harness in
        harness.model.accounts[0] = SnapshotHarness.account(
          "acct-everyday",
          "Everyday Joint Household Spending"
        )
        harness.model.rebuildLookups()
        return AnyView(AddTransactionsView(session: harness.admitParsed(), workspace: harness.workspace))
      }),
    ]
    for (name, expected, build) in cases {
      let harness = SnapshotHarness.make()
      XCTAssertFalse(
        ObjectIdentifier(harness.workspace) == ObjectIdentifier(CaptureWorkspace.shared),
        "\(name) must use an isolated workspace"
      )
      await assertRenderedContent(
        build(harness).environment(harness.model),
        expected: expected,
        name: "capture-\(name)",
        scanUntilExpectedTogether: name == "clarification"
      )
    }
  }

  func testAssistantConversationAndHomeRenderIsolatedContent() async {
    let conversation = SnapshotHarness.make()
    let session = conversation.admitConversation()
    conversation.workspace.pendingAssistantSessionID = session.id
    await assertRenderedContent(
      NavigationStack {
        AssistantView(workspace: conversation.workspace)
      }
      .environment(conversation.model),
      expected: ["Conversation", "What did I spend today?", "Lunch"],
      name: "capture-assistant-conversation"
    )
    await assertRenderedContent(
      NavigationStack {
        AddTransactionsView(session: session, embeddedInAssistant: true, workspace: conversation.workspace)
      }
      .environment(conversation.model),
      expected: ["Conversation", "What did I spend today?", "Lunch"],
      name: "capture-assistant-conversation-child",
      forbidden: ["Open in Assistant"]
    )

    SnapshotHomeBriefFailureProtocol.reset()
    XCTAssertTrue(
      URLProtocol.registerClass(SnapshotHomeBriefFailureProtocol.self),
      "home brief stub must register on URLSession.shared"
    )
    defer { URLProtocol.unregisterClass(SnapshotHomeBriefFailureProtocol.self) }
    let home = SnapshotHarness.make(baseURLString: SnapshotHomeBriefFailureProtocol.fixtureBaseURL)
    XCTAssertEqual(home.model.settings.baseURL?.host, SnapshotHomeBriefFailureProtocol.fixtureHost)
    await assertRenderedContent(
      NavigationStack {
        AssistantView(workspace: home.workspace)
      }
      .environment(home.model),
      expected: ["Today", "New conversation", "unavailable"],
      name: "capture-assistant-home",
      required: ["unavailable"],
      forbidden: ["loading recorded spending"],
      timeoutNanoseconds: 5_000_000_000
    )
    let stubbed = SnapshotHomeBriefFailureProtocol.recorded
    XCTAssertFalse(
      stubbed.isEmpty,
      "home brief must hit the fixture URLProtocol stub. If empty, URLSession.shared may have copied its protocol list before registerClass and this test-only stub never ran. recorded \(stubbed)"
    )
    XCTAssertTrue(
      stubbed.contains { $0.path.contains("spending-breakdown") },
      "home brief stub must see the spending-breakdown fixture request; recorded \(stubbed)"
    )
    XCTAssertTrue(
      stubbed.contains { $0.host == SnapshotHomeBriefFailureProtocol.fixtureHost },
      "stub must match only \(SnapshotHomeBriefFailureProtocol.fixtureHost); recorded \(stubbed)"
    )
    XCTAssertFalse(
      stubbed.contains { $0.host == "127.0.0.1" },
      "fixture stub must not intercept 127.0.0.1; recorded \(stubbed)"
    )
  }

  func testLargeDynamicTypeDescribeStateRendersIsolatedContent() async {
    let harness = SnapshotHarness.make()
    let compact = CGSize(width: 390, height: 844)
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: harness.admitLargeType(), workspace: harness.workspace)
        .environment(harness.model)
        .environment(\.dynamicTypeSize, .accessibility3),
      size: compact
    ) else {
      XCTFail("capture-dynamic-type needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    let card = await scanVisibleFrames(surface) { lines in
      Self.hasCompleteVisibleLine(lines, "Lunch") && Self.hasContiguousAmountLine(lines, "12.00")
    }
    attachImage(card.image, name: "capture-dynamic-type-card")
    let cardDiag = surface.scrollGeometryDiagnostics()
    XCTAssertFalse(
      card.image.cgImage == nil || card.image.size.width < 2 || card.image.size.height < 2,
      "accessibility3 card rendered blank. Vision: \(card.lines.map { Self.normalizedOCR($0) }) \(cardDiag)"
    )
    XCTAssertTrue(
      Self.hasCompleteVisibleLine(card.lines, "Lunch"),
      "accessibility3 card missing complete Lunch line in \(card.lines.map { Self.normalizedOCR($0) }) \(cardDiag)"
    )
    XCTAssertTrue(
      Self.hasContiguousAmountLine(card.lines, "12.00"),
      "accessibility3 card missing contiguous 12.00 in \(card.lines.map { Self.normalizedOCR($0) }) \(cardDiag)"
    )

    let actionNames = ["Save transaction"]
    var seenActions: Set<String> = []
    var actionsImage = card.image
    var actionsLines = card.lines
    await surface.setMainScrollOffsetY(0)
    var actionOffset: CGFloat = 0
    while true {
      await surface.settleVisible()
      actionsImage = surface.captureVisible()
      actionsLines = await Self.visionLines(from: actionsImage)
      let newly = actionNames.filter { name in
        !seenActions.contains(name) && Self.hasVisibleAction(actionsLines, name)
      }
      if !newly.isEmpty {
        seenActions.formUnion(newly)
        attachImage(
          actionsImage,
          name: "capture-dynamic-type-actions-\(Self.actionCaptureSlug(seenActions))"
        )
      }
      if seenActions.count == actionNames.count {
        break
      }
      let maxOffset = surface.mainScrollMaxOffset()
      if actionOffset >= maxOffset {
        break
      }
      actionOffset = min(maxOffset, actionOffset + surface.mainScrollStep())
      guard await surface.setMainScrollOffsetY(actionOffset) else {
        break
      }
    }
    if seenActions.count != actionNames.count {
      attachImage(actionsImage, name: "capture-dynamic-type-footer")
    }
    let actionDiag = surface.scrollGeometryDiagnostics()
    let missingActions = actionNames.filter { !seenActions.contains($0) }
    XCTAssertTrue(
      missingActions.isEmpty,
      "accessibility3 actions missing complete \(missingActions) in \(actionsLines.map { Self.normalizedOCR($0) }) seen \(seenActions) \(actionDiag)"
    )
    for label in ["Save transaction", "Edit", "Send", "Open in Assistant"] {
      guard let control = surface.firstControl(label: label) else {
        XCTFail("accessibility3 \(label) AX missing in \(surface.accessibilityLabels())")
        continue
      }
      surface.assertMinimumHitTarget(control)
    }
  }

  func testPreviewActionsMeetHitTargetsAtDefaultAndAccessibility3() async {
    for size in [DynamicTypeSize.large, .accessibility3] {
      let harness = SnapshotHarness.make()
      guard let surface = SnapshotSurface(
        root: AddTransactionsView(session: harness.admitParsed(), workspace: harness.workspace)
          .environment(harness.model)
          .environment(\.dynamicTypeSize, size),
        size: CGSize(width: 390, height: 844)
      ) else {
        XCTFail("\(size) preview geometry needs a connected UIWindowScene")
        continue
      }
      defer { surface.detach() }
      _ = await surface.captureUntilOCR(contains: ["Lunch", "Save transaction"])
      for label in ["Edit", "Save transaction", "Open in Assistant"] {
        guard let control = surface.firstControl(label: label) else {
          XCTFail("\(size) missing \(label) in \(surface.accessibilityLabels())")
          continue
        }
        surface.assertMinimumHitTarget(control)
      }
    }
  }

  private func scanVisibleFrames(
    _ surface: SnapshotSurface,
    until matches: ([String]) -> Bool
  ) async -> (image: UIImage, lines: [String]) {
    await surface.setMainScrollOffsetY(0)
    await surface.settleVisible()
    var image = surface.captureVisible()
    var lines = await Self.visionLines(from: image)
    if matches(lines) {
      return (image, lines)
    }
    var offset: CGFloat = 0
    while true {
      let maxOffset = surface.mainScrollMaxOffset()
      if offset >= maxOffset {
        break
      }
      offset = min(maxOffset, offset + surface.mainScrollStep())
      guard await surface.setMainScrollOffsetY(offset) else {
        break
      }
      await surface.settleVisible()
      image = surface.captureVisible()
      lines = await Self.visionLines(from: image)
      if matches(lines) {
        break
      }
    }
    return (image, lines)
  }

  func testComposerInsertTextKeepsResponderThenResignsOnManual() async {
    let harness = SnapshotHarness.make()
    let session = harness.admitEmpty()
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace)
        .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("composer typing needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    _ = await surface.captureUntilOCR(contains: ["Add an expense"])
    guard let field = surface.firstDescendant(PasteAwareTextView.self) else {
      XCTFail("production composer UITextView was not hosted")
      return
    }
    XCTAssertTrue(field.becomeFirstResponder(), "composer should accept first responder")
    try? await Task.sleep(nanoseconds: 200_000_000)
    surface.layoutNow()
    let focusedFrame = surface.windowFrame(of: field)
    if let keyboard = surface.keyboardFrameInWindow() {
      XCTAssertLessThanOrEqual(
        focusedFrame.maxY,
        keyboard.minY + 8,
        "composer must sit above the keyboard in window space: field \(focusedFrame) keyboard \(keyboard)"
      )
    } else {
      let limit = surface.windowBounds.maxY - surface.windowSafeAreaInsets.bottom
      XCTAssertLessThanOrEqual(
        focusedFrame.maxY,
        limit + 1,
        "composer must stay in the window dock: field \(focusedFrame) window \(surface.windowBounds)"
      )
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    surface.layoutNow()

    let sentence = "Lunch $12 of Groceries on Everyday Account"
    var typed = ""
    for character in sentence {
      field.insertText(String(character))
      typed.append(character)
      try? await Task.sleep(nanoseconds: 20_000_000)
      surface.layoutNow()
      XCTAssertTrue(
        field.isFirstResponder,
        "lost first responder after \(field.text ?? "")"
      )
      XCTAssertEqual(field.text, typed)
      XCTAssertEqual(session.composerText, typed)
    }
    XCTAssertEqual(field.text, sentence)
    XCTAssertEqual(session.composerText, sentence)
    XCTAssertTrue(field.isFirstResponder)

    session.entryMode = .manual
    await Task.yield()
    try? await Task.sleep(nanoseconds: 20_000_000)
    surface.layoutNow()
    XCTAssertFalse(field.isFirstResponder, "Manual should resign the describe composer")
    XCTAssertNotNil(surface.firstDescendant(PasteAwareTextView.self), "the conversation dock stays mounted")

    XCTAssertTrue(field.becomeFirstResponder())
    field.insertText("!")
    try? await Task.sleep(nanoseconds: 20_000_000)
    surface.layoutNow()
    XCTAssertTrue(field.isFirstResponder)
    XCTAssertTrue((field.text ?? "").contains("!"))
    XCTAssertTrue(session.composerText.contains("!"))
  }

  func testConversationDockStaysPinnedWithIconActionLabels() async {
    let harness = SnapshotHarness.make()
    let session = harness.admitEmpty()
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace)
        .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("dock geometry needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    _ = await surface.captureUntilOCR(contains: ["Add an expense"])
    guard let field = surface.firstDescendant(PasteAwareTextView.self) else {
      XCTFail("conversation dock must host the composer field")
      return
    }
    let send = surface.firstControl(label: "Send")
    let plus = surface.firstControl(label: "Add a photo, paste, or enter manually")
    let account = surface.firstControl(labelContains: "Account for next message")
    let open = surface.firstControl(label: "Open in Assistant")
    XCTAssertNotNil(send, "dock Send AX missing in \(surface.accessibilityLabels())")
    XCTAssertNotNil(plus, "plus AX missing in \(surface.accessibilityLabels())")
    XCTAssertNotNil(account, "account AX missing in \(surface.accessibilityLabels())")
    XCTAssertNotNil(open, "Open in Assistant AX missing in \(surface.accessibilityLabels())")
    for control in [send, plus, account, open].compactMap({ $0 }) {
      XCTAssertGreaterThanOrEqual(control.frame.width, 44, "\(control.label) width \(control.frame)")
      XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(control.label) height \(control.frame)")
    }
    if let account, let open {
      XCTAssertFalse(account.frame.intersects(open.frame), "account and Open in Assistant must not overlap: \(account.frame) \(open.frame)")
      XCTAssertEqual(
        account.frame.midY,
        open.frame.midY,
        accuracy: 12,
        "account and Open in Assistant must share the context row: \(account.frame) \(open.frame)"
      )
    }
    if let send, let open {
      XCTAssertLessThanOrEqual(
        open.frame.maxY,
        send.frame.minY + 1,
        "Open in Assistant must sit above Send: link \(open.frame) send \(send.frame)"
      )
    }
    XCTAssertGreaterThanOrEqual(field.bounds.height, 44, "empty composer field must keep the 44pt row: \(field.bounds)")
    XCTAssertLessThanOrEqual(field.bounds.height, 64, "empty composer field must stay compact: \(field.bounds)")
    let fieldFrame = surface.windowFrame(of: field)
    let dockLimit = surface.windowBounds.maxY - surface.windowSafeAreaInsets.bottom
    XCTAssertGreaterThan(fieldFrame.maxY, surface.windowBounds.midY, "composer left the dock: \(fieldFrame) window \(surface.windowBounds)")
    XCTAssertLessThanOrEqual(fieldFrame.maxY, dockLimit + 1, "composer must stay in the window dock: \(fieldFrame) limit \(dockLimit)")
    field.insertText("one\ntwo\nthree\nfour\nfive\nsix")
    try? await Task.sleep(nanoseconds: 50_000_000)
    surface.layoutNow()
    XCTAssertGreaterThan(field.bounds.height, 44, "multiline composer should grow: \(field.bounds)")
    XCTAssertLessThanOrEqual(field.bounds.height, 120, "composer must cap internally: \(field.bounds)")
    XCTAssertEqual(session.composerText, field.text)
    guard let handoff = surface.firstControl(label: "Open in Assistant") else {
      XCTFail("Open in Assistant missing after multiline input in \(surface.accessibilityLabels())")
      return
    }
    XCTAssertTrue(surface.activate(handoff), "Open in Assistant must hand off via the dock link")
    let opened = await surface.waitUntil {
      harness.workspace.shouldOpenAssistant && harness.workspace.pendingAssistantSessionID == session.id
    }
    XCTAssertTrue(opened, "dock link must set shouldOpenAssistant and pending session without calling workspace directly")
    XCTAssertEqual(session.composerText, field.text, "handoff must keep unsent composer text")
    XCTAssertTrue(harness.model.transactions.isEmpty, "Open in Assistant must not write the ledger")
  }

  func testAssistantNavigationPopRestoresHome() async {
    SnapshotHomeBriefFailureProtocol.reset()
    XCTAssertTrue(URLProtocol.registerClass(SnapshotHomeBriefFailureProtocol.self))
    defer { URLProtocol.unregisterClass(SnapshotHomeBriefFailureProtocol.self) }
    let harness = SnapshotHarness.make(baseURLString: SnapshotHomeBriefFailureProtocol.fixtureBaseURL)
    let session = harness.admitConversation()
    harness.workspace.pendingAssistantSessionID = session.id
    guard let surface = SnapshotSurface(
      root: NavigationStack {
        AssistantView(workspace: harness.workspace)
      }
      .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("assistant navigation needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    _ = await surface.captureUntilOCR(contains: ["Conversation", "What did I spend today?"])
    XCTAssertNil(
      surface.firstControl(label: "Open in Assistant"),
      "pushed Assistant conversation must not show Open in Assistant in \(surface.accessibilityLabels())"
    )
    XCTAssertEqual(harness.workspace.pendingAssistantSessionID, session.id)
    guard let navigation = surface.hostNavigationController() else {
      XCTFail("pushed conversation must sit in a UINavigationController from this host")
      return
    }
    XCTAssertGreaterThan(
      navigation.viewControllers.count,
      1,
      "conversation destination must be pushed before pop"
    )
    let popped = navigation.popViewController(animated: false)
    XCTAssertNotNil(popped, "popViewController must return the conversation view controller")
    surface.layoutNow()
    let clearedPending = await surface.waitUntil { harness.workspace.pendingAssistantSessionID == nil }
    XCTAssertTrue(
      clearedPending,
      "navigationDestination binding must clear pendingAssistantSessionID after popViewController"
    )
    let home = await surface.captureUntilOCR(contains: ["New conversation"])
    XCTAssertTrue(home.text.contains(Self.normalizedOCR("New conversation")))
    XCTAssertNil(harness.workspace.pendingAssistantSessionID)
    XCTAssertTrue(harness.model.transactions.isEmpty, "navigation pop must not write the ledger")
  }

  func testManualEditorDoneAppliesAndCancelLeavesOriginal() async {
    let harness = SnapshotHarness.make()
    let session = harness.admitEmpty()
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace)
        .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("manual editor needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    _ = await surface.captureUntilOCR(contains: ["Add an expense"])
    XCTAssertTrue(session.drafts.isEmpty, "new Manual must not create a draft before Done")
    guard await openManualEditor(on: surface) else {
      return
    }
    _ = await surface.captureUntilOCR(contains: ["New transaction"])
    XCTAssertTrue(session.drafts.isEmpty, "opening Manual must not create a draft")
    guard let cancel = surface.firstControl(label: "Cancel") else {
      XCTFail("manual editor missing Cancel in \(surface.accessibilityLabels())")
      return
    }
    XCTAssertTrue(surface.activate(cancel), "Cancel must dismiss the manual editor")
    let cancelledEditor = await surface.waitUntil {
      session.drafts.isEmpty && surface.firstControl(label: "Cancel") == nil
    }
    XCTAssertTrue(
      cancelledEditor,
      "Cancel must leave no new draft and dismiss the editor"
    )
    XCTAssertTrue(session.drafts.isEmpty, "Cancel must leave no new draft")

    guard await openManualEditor(on: surface) else {
      return
    }
    _ = await surface.captureUntilOCR(contains: ["New transaction"])
    XCTAssertTrue(session.drafts.isEmpty)
    guard let done = surface.firstControl(label: "Done") else {
      XCTFail("manual editor missing Done in \(surface.accessibilityLabels())")
      return
    }
    XCTAssertTrue(surface.activate(done), "Done must apply the manual editor")
    let appliedManual = await surface.waitUntil { session.drafts.count == 1 }
    XCTAssertTrue(
      appliedManual,
      "Done must create the manual draft through the editor"
    )
    XCTAssertEqual(session.drafts.count, 1)
    XCTAssertEqual(session.messages.filter { $0.text == "Entered manually" }.count, 1)
    XCTAssertTrue(harness.model.transactions.isEmpty, "Manual Done must not save to the ledger")
  }

  private func openManualEditor(on surface: SnapshotSurface) async -> Bool {
    guard let plus = surface.firstControl(label: "Add a photo, paste, or enter manually") else {
      XCTFail("plus control missing in \(surface.accessibilityLabels())")
      return false
    }
    XCTAssertTrue(surface.activate(plus), "plus must open the add sheet")
    guard await surface.waitUntil(timeoutNanoseconds: 1_500_000_000, {
      surface.firstControl(label: "Enter manually") != nil
    }) else {
      XCTFail("plus menu missing Enter manually in \(surface.accessibilityLabels())")
      return false
    }
    guard let enter = surface.firstControl(label: "Enter manually") else {
      XCTFail("plus menu missing Enter manually in \(surface.accessibilityLabels())")
      return false
    }
    XCTAssertTrue(surface.activate(enter), "Enter manually must present the editor")
    return await surface.waitUntil(timeoutNanoseconds: 1_500_000_000, {
      surface.firstControl(label: "Cancel") != nil
    })
  }

  func testManualTransitionCancelsInFlightTurnAndIgnoresLateApply() async {
    let harness = SnapshotHarness.make()
    let session = harness.admitParsed()
    session.composerText = "Coffee $5 on Everyday Account"
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace)
        .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("manual cancel needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    _ = await surface.captureUntilOCR(contains: ["Lunch"])
    let composerBefore = session.composerText
    let draftIDsBefore = session.drafts.map(\.id)
    let attachmentCount = session.attachments.count
    XCTAssertFalse(session.isBusy)
    XCTAssertTrue(session.canSaveIncluded)

    let token = session.beginTurn()
    XCTAssertTrue(session.isBusy)
    XCTAssertFalse(session.canSaveIncluded)
    XCTAssertEqual(token.generation, session.generation)

    session.entryMode = .manual
    try? await Task.sleep(nanoseconds: 20_000_000)
    surface.layoutNow()
    try? await Task.sleep(nanoseconds: 20_000_000)
    surface.layoutNow()

    XCTAssertEqual(session.entryMode, .manual)
    XCTAssertNotEqual(session.generation, token.generation)
    XCTAssertFalse(session.isBusy)
    XCTAssertFalse(session.matchesTurn(generation: token.generation))
    XCTAssertEqual(session.composerText, composerBefore)
    XCTAssertEqual(session.drafts.map(\.id), draftIDsBefore)
    XCTAssertEqual(session.attachments.count, attachmentCount)
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 12_000)
    XCTAssertTrue(session.canSaveIncluded)

    var manual = session.drafts[0].draft
    manual.amountMagnitudeMilli = 50
    session.applyManualEdit(manual, id: session.drafts[0].id)
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 50)
    XCTAssertTrue(session.canSaveIncluded)

    var lateDraft = TransactionDraft()
    lateDraft.payeeName = "Coffee"
    lateDraft.amountMagnitudeMilli = 5_000
    lateDraft.accountID = "acct-everyday"
    let lateMapped = SlipMappedDraft(
      draft: lateDraft,
      parsedAmount: true,
      parsedDate: false,
      parsedAccount: true,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .add,
        feedback: "Added coffee.",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "5", payee: "Coffee"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [lateMapped],
      expectedRevision: token.revision,
      expectedGeneration: token.generation
    )
    XCTAssertFalse(session.finishTurn(generation: token.generation))
    XCTAssertFalse(session.isBusy)
    XCTAssertEqual(session.drafts.map(\.id), draftIDsBefore)
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 50)
    XCTAssertEqual(session.drafts[0].draft.payeeName, "Lunch")
    XCTAssertEqual(session.composerText, composerBefore)
    XCTAssertTrue(session.canSaveIncluded)
  }

  func testManualTransitionDuringIngestionPreservesGeneration() async {
    let harness = SnapshotHarness.make()
    let session = harness.admitParsed()
    let pending = CaptureAttachment(
      filename: "slip.jpg",
      data: Data([0xFF, 0xD8]),
      isReading: true
    )
    session.addAttachment(pending)
    session.isTransferringImages = true
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace)
        .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("ingestion preserve needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    _ = await surface.captureUntilOCR(contains: ["Lunch"])
    let generation = session.generation
    XCTAssertFalse(session.isBusy)
    XCTAssertTrue(session.isIngesting)
    XCTAssertTrue(session.isTransferringImages)

    session.entryMode = .manual
    try? await Task.sleep(nanoseconds: 20_000_000)
    surface.layoutNow()
    try? await Task.sleep(nanoseconds: 20_000_000)
    surface.layoutNow()

    XCTAssertEqual(session.entryMode, .manual)
    XCTAssertEqual(session.generation, generation)
    XCTAssertFalse(session.isBusy)
    XCTAssertTrue(session.isTransferringImages)
    XCTAssertTrue(session.isIngesting)
    XCTAssertEqual(session.attachments.map(\.id), [pending.id])
    XCTAssertTrue(session.attachments[0].isReading)
    XCTAssertEqual(session.attachments[0].filename, "slip.jpg")
  }

  func testBusyUndoInMultiGroupFooterDoesNotMutate() async {
    let harness = SnapshotHarness.make()
    let session = harness.admitMulti()
    let coffee = session.currentDrafts[0]
    var edited = coffee.draft
    edited.amountMagnitudeMilli = 8_000
    session.applyManualEdit(edited, id: coffee.id)
    session.composerText = "Add another coffee"
    _ = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    _ = session.beginTurn()
    XCTAssertTrue(session.isBusy)
    XCTAssertTrue(session.canUndo(ownedIDs: [coffee.id]))
    let ids = session.drafts.map(\.id)
    let revision = session.revision
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace)
        .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("busy footer Undo needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }
    _ = await surface.captureUntilOCR(contains: ["Coffee", "Lunch"])
    guard let undo = await revealControl(on: surface, label: "Undo") else {
      XCTFail("multi-group footer Undo missing in \(surface.accessibilityLabels())")
      return
    }
    attachImage(surface.captureVisible(), name: "capture-busy-undo-footer")
    XCTAssertFalse(surface.isControlEnabled(undo), "Undo must be disabled while a turn is in flight")
    XCTAssertFalse(surface.activate(undo), "disabled Undo must not activate")
    XCTAssertEqual(session.drafts.map(\.id), ids)
    XCTAssertEqual(session.revision, revision)
    XCTAssertEqual(session.drafts.first { $0.id == coffee.id }?.draft.amountMagnitudeMilli, 8_000)
    session.cancelTurn()
    surface.layoutNow()
    guard await surface.waitUntil(timeoutNanoseconds: 1_500_000_000, {
      surface.firstControl(label: "Undo").map(surface.isControlEnabled) == true
    }) else {
      XCTFail("Undo must become enabled after the turn ends")
      return
    }
    guard let enabled = surface.firstControl(label: "Undo") else {
      XCTFail("Undo missing after turn ended")
      return
    }
    XCTAssertTrue(surface.activate(enabled), "Undo must act once the turn has ended")
    XCTAssertEqual(session.drafts.first { $0.id == coffee.id }?.draft.amountMagnitudeMilli, 5_000)
  }

  func testBusyUndoOnRemovedGroupRecoveryDoesNotMutate() async {
    let harness = SnapshotHarness.make()
    let session = harness.admitMulti()
    let ids = session.drafts.map(\.id)
    XCTAssertEqual(ids.count, 2)
    var edited = session.drafts[0].draft
    edited.amountMagnitudeMilli = 8_000
    session.applyManualEdit(edited, id: ids[0])
    session.removeDraft(ids[0])
    session.removeDraft(ids[1])
    XCTAssertTrue(session.drafts.isEmpty)
    session.composerText = "Follow up"
    _ = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    _ = session.beginTurn()
    let revision = session.revision
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace)
        .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("recovery Undo needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }
    _ = await surface.captureUntilOCR(contains: ["Undo"])
    guard let undo = await revealControl(on: surface, label: "Undo") else {
      XCTFail("removed-group recovery Undo missing in \(surface.accessibilityLabels())")
      return
    }
    attachImage(surface.captureVisible(), name: "capture-busy-undo-recovery")
    XCTAssertFalse(surface.isControlEnabled(undo), "recovery Undo must be disabled while a turn is in flight")
    XCTAssertFalse(surface.activate(undo), "disabled recovery Undo must not activate")
    XCTAssertTrue(session.drafts.isEmpty)
    XCTAssertEqual(session.revision, revision)
    session.cancelTurn()
    surface.layoutNow()
    guard await surface.waitUntil(timeoutNanoseconds: 1_500_000_000, {
      surface.firstControl(label: "Undo").map(surface.isControlEnabled) == true
    }) else {
      XCTFail("recovery Undo must become enabled after the turn ends")
      return
    }
    guard let enabled = surface.firstControl(label: "Undo") else {
      XCTFail("recovery Undo missing after turn ended")
      return
    }
    XCTAssertTrue(surface.activate(enabled))
    XCTAssertFalse(session.drafts.isEmpty, "Undo should restore the removed drafts after the turn ends")
  }

  func testSamePayeeClarificationChoiceLabelsIncludeAmountAndDate() async {
    let harness = SnapshotHarness.make()
    let session = harness.admitSamePayeeClarification()
    let drafts = session.currentDrafts
    XCTAssertEqual(drafts.map(\.draft.payeeName), ["Coffee", "Coffee"])
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace)
        .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("equal-payee clarification needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }
    _ = await surface.captureUntilOCR(contains: ["Coffee", "Which transaction should I change?"])
    attachImage(surface.captureVisible(), name: "capture-equal-payee-clarification")
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    let expected = drafts.map { item in
      (
        payee: item.draft.payeeName,
        amount: MoneyCodec.signedDisplayString(
          for: item.draft.signedMilliunits,
          currencyFormat: harness.model.currencyFormat
        ),
        date: formatter.string(from: item.draft.date)
      )
    }
    let labels = surface.controls(labelContains: "Coffee").map(\.label)
    XCTAssertEqual(labels.count, 2, "same-payee choices must be two Coffee buttons: \(labels) \(surface.accessibilityLabels())")
    XCTAssertEqual(Set(labels).count, 2, "same-payee choices must have distinct AX labels: \(labels)")
    for parts in expected {
      XCTAssertTrue(
        labels.contains { label in
          label.localizedStandardContains(parts.payee)
            && label.localizedStandardContains(parts.amount)
            && label.localizedStandardContains(parts.date)
        },
        "missing payee/amount/date in \(labels) expected \(parts)"
      )
    }
  }

  func testCandidateRailsMeetHitTargetsAtDefaultAndAccessibility3() async {
    let cases: [(String, (SnapshotHarness) -> CaptureSession, [String])] = [
      ("ambiguity", { $0.admitAmbiguous() }, ["Everyday", "Travel", "Groceries", "Dining Out"]),
      ("query", { $0.admitPendingQueryClarification() }, ["Everyday", "Travel", "Groceries", "Dining Out"]),
    ]
    for size in [DynamicTypeSize.large, .accessibility3] {
      for (name, build, labels) in cases {
        let harness = SnapshotHarness.make()
        guard let surface = SnapshotSurface(
          root: AddTransactionsView(session: build(harness), workspace: harness.workspace)
            .environment(harness.model)
            .environment(\.dynamicTypeSize, size),
          size: CGSize(width: 390, height: 844)
        ) else {
          XCTFail("\(size) \(name) candidates need a connected UIWindowScene")
          continue
        }
        defer { surface.detach() }
        _ = await surface.captureUntilOCR(contains: ["Which"])
        attachImage(surface.captureVisible(), name: "capture-\(name)-candidates-\(size)")
        for label in labels {
          guard let control = await revealControl(on: surface, label: label) else {
            XCTFail("\(size) \(name) missing candidate \(label) in \(surface.accessibilityLabels())")
            continue
          }
          XCTAssertNotEqual(
            control.label,
            "Account for next message, \(label), change account",
            "candidate \(label) must not be the account chooser"
          )
          surface.assertMinimumHitTarget(control)
        }
      }
    }
  }

  func testInterruptedImageOffersRetryReadingAndKeepsRemove() async {
    let harness = SnapshotHarness.make()
    let session = harness.admitInterruptedImage()
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace)
        .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("interrupted image needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }
    _ = await surface.captureUntilOCR(contains: ["Remove attachment"])
    attachImage(surface.captureVisible(), name: "capture-interrupted-image-recovery")
    guard let retry = await revealControl(on: surface, label: "Retry reading image") else {
      XCTFail("Retry reading image missing in \(surface.accessibilityLabels())")
      return
    }
    surface.assertMinimumHitTarget(retry)
    guard let remove = await revealControl(on: surface, label: "Remove attachment") else {
      XCTFail("Remove attachment must stay reachable in \(surface.accessibilityLabels())")
      return
    }
    surface.assertMinimumHitTarget(remove)
    XCTAssertTrue(surface.activate(retry), "Retry reading image must run Vision on the retained bytes")
    let recovered = await surface.waitUntil(timeoutNanoseconds: 5_000_000_000, {
      session.attachments.first?.recognizedText.isEmpty == false
        && session.attachments.first?.isReading == false
        && session.attachments.first?.errorMessage == nil
    })
    XCTAssertTrue(recovered, "retry must recover text from the retained SLIP image")
    XCTAssertTrue(session.canSendComposer)
  }

  func testStopCancelsPendingQueryTransportWithoutLateCard() async {
    SnapshotQueryDelayProtocol.reset()
    XCTAssertTrue(
      URLProtocol.registerClass(SnapshotQueryDelayProtocol.self),
      "query delay stub must register on URLSession.shared"
    )
    defer { URLProtocol.unregisterClass(SnapshotQueryDelayProtocol.self) }
    let harness = SnapshotHarness.make(baseURLString: SnapshotQueryDelayProtocol.fixtureBaseURL)
    let session = harness.admitPendingQueryClarification(includeCategory: false)
    XCTAssertTrue(session.queryCards.isEmpty)
    XCTAssertTrue(session.pendingQuery?.unresolvedCategory.isEmpty == true)
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace)
        .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("pending query cancel needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }
    _ = await surface.captureUntilOCR(contains: ["Which account"])
    attachImage(surface.captureVisible(), name: "capture-pending-query-choices")
    guard let candidate = await revealControl(on: surface, label: "Everyday") else {
      XCTFail("query account candidate missing in \(surface.accessibilityLabels())")
      return
    }
    XCTAssertTrue(surface.activate(candidate), "tapping Everyday must start the pending query")
    let beganTurn = await surface.waitUntil(timeoutNanoseconds: 1_500_000_000, { session.isBusy })
    XCTAssertTrue(beganTurn, "pending query pick must begin a turn")
    let startedReport = await surface.waitUntil(timeoutNanoseconds: 1_500_000_000, {
      SnapshotQueryDelayProtocol.started.contains { $0.path.contains("spending-breakdown") }
    })
    XCTAssertTrue(
      startedReport,
      "delayed query stub must see the spending-breakdown request; started \(SnapshotQueryDelayProtocol.started)"
    )
    guard startedReport else {
      return
    }
    guard let stop = await revealControl(on: surface, label: "Stop response") else {
      XCTFail("Stop response missing after query start in \(surface.accessibilityLabels())")
      return
    }
    XCTAssertTrue(surface.activate(stop), "Stop response must be the production control")
    let stoppedTransport = await surface.waitUntil(timeoutNanoseconds: 1_000_000_000, {
      SnapshotQueryDelayProtocol.stopped > 0
    })
    XCTAssertTrue(
      stoppedTransport,
      "URLProtocol.stopLoading must run promptly after Stop; stopped \(SnapshotQueryDelayProtocol.stopped) started \(SnapshotQueryDelayProtocol.started)"
    )
    try? await Task.sleep(nanoseconds: 2_200_000_000)
    surface.layoutNow()
    XCTAssertTrue(session.queryCards.isEmpty, "cancelled query must not apply a late card")
  }

  private func revealControl(on surface: SnapshotSurface, label: String) async -> SnapshotAXNode? {
    func usable(_ node: SnapshotAXNode) -> Bool {
      guard node.frame.width > 0, node.frame.height > 0 else {
        return false
      }
      let visible = node.frame.intersection(surface.windowBounds)
      return visible.width >= min(44, node.frame.width)
        && visible.height >= min(44, node.frame.height)
    }
    if let node = surface.firstControl(label: label), usable(node) {
      return node
    }
    await surface.setMainScrollOffsetY(0)
    if let node = surface.firstControl(label: label), usable(node) {
      return node
    }
    var offset: CGFloat = 0
    let maxOffset = surface.mainScrollMaxOffset()
    while offset < maxOffset {
      offset = min(maxOffset, offset + surface.mainScrollStep())
      guard await surface.setMainScrollOffsetY(offset) else {
        break
      }
      if let node = surface.firstControl(label: label), usable(node) {
        return node
      }
    }
    return nil
  }

  private static func actionCaptureSlug(_ names: Set<String>) -> String {
    names.sorted().map {
      $0.replacingOccurrences(of: " ", with: "-")
    }.joined(separator: "_")
  }

  private func attachImage(_ image: UIImage, name: String) {
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func assertRenderedContent<V: View>(
    _ root: V,
    expected: [String],
    name: String,
    size: CGSize = CGSize(width: 390, height: 844),
    required: [String] = [],
    forbidden: [String] = [],
    timeoutNanoseconds: UInt64 = 800_000_000,
    requireUnbrokenLines: [String] = [],
    scanUntilExpectedTogether: Bool = false
  ) async {
    guard let surface = SnapshotSurface(root: root, size: size) else {
      XCTFail("\(name) needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    let capturedImage: UIImage
    let ocrText: String
    let isBlank: Bool
    if scanUntilExpectedTogether {
      let choiceLabels = [
        "Use Coffee for the last instruction",
        "Use Lunch for the last instruction",
      ]
      func frameShowsClarification(_ lines: [String]) -> Bool {
        let blob = lines.map { Self.normalizedOCR($0) }.joined(separator: " ")
        guard expected.allSatisfy({ blob.contains(Self.normalizedOCR($0)) }) else {
          return false
        }
        return choiceLabels.allSatisfy { surface.hasVisibleTimelineControl(label: $0) }
      }
      await surface.setMainScrollOffsetY(surface.mainScrollMaxOffset())
      await surface.settleVisible()
      let endImage = surface.captureVisible()
      var scanned = (image: endImage, lines: await Self.visionLines(from: endImage))
      if !frameShowsClarification(scanned.lines) {
        scanned = await scanVisibleFrames(surface, until: frameShowsClarification)
      }
      capturedImage = scanned.image
      ocrText = scanned.lines.map { Self.normalizedOCR($0) }.joined(separator: " ")
      isBlank = scanned.image.cgImage == nil || scanned.image.size.width < 2 || scanned.image.size.height < 2 || scanned.lines.isEmpty
      let missingChoices = choiceLabels.filter { !surface.hasVisibleTimelineControl(label: $0) }
      XCTAssertTrue(
        missingChoices.isEmpty,
        "\(name) missing visible clarification choices \(missingChoices) in timeline \(surface.timelineVisibleFrame()) AX \(surface.accessibilityLabels())"
      )
    } else {
      let waitFor = required.isEmpty ? expected : required
      let captured = await surface.captureUntilOCR(contains: waitFor, timeoutNanoseconds: timeoutNanoseconds)
      capturedImage = captured.image
      ocrText = captured.text
      isBlank = captured.isBlank
    }
    let attachment = XCTAttachment(image: capturedImage)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)

    if isBlank {
      XCTFail("\(name) rendered a blank surface. OCR: [\(ocrText)]")
      return
    }
    let missing = expected.filter { !ocrText.contains(Self.normalizedOCR($0)) }
    XCTAssertTrue(missing.isEmpty, "\(name) missing \(missing) in OCR [\(ocrText)]")
    let forbiddenHits = forbidden.filter { ocrText.contains(Self.normalizedOCR($0)) }
    XCTAssertTrue(forbiddenHits.isEmpty, "\(name) still showing \(forbiddenHits) in OCR [\(ocrText)]")
    if !requireUnbrokenLines.isEmpty {
      let lines = await Self.visionLines(from: capturedImage)
      let failed = requireUnbrokenLines.filter { needle in
        needle.contains(".") ? !Self.hasContiguousAmountLine(lines, needle) : !Self.hasCompleteVisibleLine(lines, needle)
      }
      XCTAssertTrue(
        failed.isEmpty,
        "\(name) missing unbroken lines \(failed) in Vision lines \(lines.map { Self.normalizedOCR($0) })"
      )
    }
  }

  fileprivate static func normalizedOCR(_ text: String) -> String {
    text
      .lowercased()
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  fileprivate static func stripLeadingIconPunctuation(_ line: String) -> String {
    var scalars = Array(line.trimmingCharacters(in: .whitespacesAndNewlines))
    while let first = scalars.first {
      if first.isLetter || first.isNumber || first == "$" {
        break
      }
      let isHarmless = first.unicodeScalars.allSatisfy { scalar in
        CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
      }
      guard isHarmless else {
        break
      }
      scalars.removeFirst()
      while scalars.first?.isWhitespace == true {
        scalars.removeFirst()
      }
    }
    return String(scalars)
  }

  fileprivate static func hasCompleteVisibleLine(_ lines: [String], _ needle: String) -> Bool {
    let target = normalizedOCR(needle)
    return lines.contains { normalizedOCR(stripLeadingIconPunctuation($0)) == target }
  }

  fileprivate static func hasVisibleAction(_ lines: [String], _ name: String) -> Bool {
    if name == "Open in Assistant" || name == "Save transaction" {
      return hasCompleteVisibleLine(lines, name) || hasAdjacentPhrase(lines, name)
    }
    return hasCompleteVisibleLine(lines, name)
  }

  fileprivate static func hasAdjacentPhrase(_ lines: [String], _ phrase: String) -> Bool {
    let wanted = normalizedOCR(phrase).split(separator: " ").map(String.init)
    guard !wanted.isEmpty else {
      return false
    }
    let tokens = lines.flatMap {
      normalizedOCR(stripLeadingIconPunctuation($0)).split(separator: " ").map(String.init)
    }
    guard tokens.count >= wanted.count else {
      return false
    }
    return (0 ... (tokens.count - wanted.count)).contains { start in
      Array(tokens[start ..< (start + wanted.count)]) == wanted
    }
  }

  fileprivate static func hasContiguousAmountLine(_ lines: [String], _ amount: String) -> Bool {
    let target = normalizedOCR(amount)
    return lines.contains { normalizedOCR($0).contains(target) }
  }

  fileprivate static func visionLines(from image: UIImage) async -> [String] {
    guard let data = image.jpegData(compressionQuality: 0.85) else {
      return []
    }
#if canImport(Vision)
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(data: data, options: [:])
        _ = try? handler.perform([request])
        continuation.resume(returning: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
      }
    }
#else
    return []
#endif
  }
}

@MainActor
private final class SnapshotHarness {
  let model: AppModel
  let workspace: CaptureWorkspace

  static func make(baseURLString: String = "http://127.0.0.1:1") -> SnapshotHarness {
    var settings = APISettings()
    settings.baseURLString = baseURLString
    settings.username = "fixture-owner"
    settings.sessionToken = "fixture-session-token"
    settings.authenticatedUserID = "fixture-user"
    settings.planID = "fixture-plan"

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs())
    model.accounts = [
      account("acct-everyday", "Everyday"),
      account("acct-travel", "Travel"),
    ]
    model.categoryGroups = [
      CategoryGroup(
        id: "grp-spend",
        name: "Everyday",
        hidden: false,
        deleted: false,
        categories: [
          Category(id: "cat-groceries", categoryGroupID: "grp-spend", name: "Groceries", deleted: false),
          Category(id: "cat-dining", categoryGroupID: "grp-spend", name: "Dining Out", deleted: false),
        ]
      ),
    ]
    model.payees = [
      Payee(id: "payee-lunch", name: "Lunch Shop", transferAccountId: nil, deleted: false),
    ]
    model.planSettings = PlanSettings(
      dateFormat: DateFormat(format: "yyyy-MM-dd"),
      currencyFormat: CurrencyFormat(
        isoCode: "USD",
        exampleFormat: "$1,234.56",
        decimalDigits: 2,
        decimalSeparator: ".",
        groupSeparator: ",",
        symbolFirst: true,
        currencySymbol: "$"
      ),
      display: DisplaySettings()
    )
    model.referencePhase = .loaded
    model.rebuildLookups()

    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.snap.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("howmuch-snap-\(UUID().uuidString)")
      )
    )
    workspace.activate(scopeKey: model.settings.viewPrefsScopeKey)
    return SnapshotHarness(model: model, workspace: workspace)
  }

  private init(model: AppModel, workspace: CaptureWorkspace) {
    self.model = model
    self.workspace = workspace
  }

  func admitEmpty() -> CaptureSession {
    admit()
  }

  func admitParsed() -> CaptureSession {
    let session = admit()
    session.replaceDrafts([
      item(payee: "Lunch", amount: 12_000, account: "acct-everyday", category: "cat-groceries"),
    ])
    session.appendUserMessage("Lunch $12 of Groceries on Everyday")
    session.appendAssistantMessage("I've got lunch ready for you. It isn't saved yet.")
    session.hydrateOwnershipIfNeeded()
    return session
  }

  func admitCorrected() -> CaptureSession {
    let session = admitParsed()
    var draft = session.currentDrafts[0].draft
    draft.amountMagnitudeMilli = 21_000
    session.applyManualEdit(draft, id: session.currentDrafts[0].id)
    session.appendUserMessage("Actually, $21")
    session.appendAssistantMessage("I've updated lunch to $21. It isn't saved yet.")
    return session
  }

  func admitAmbiguous() -> CaptureSession {
    let session = admit()
    var draft = item(payee: "Lunch", amount: 12_000, account: "")
    draft.accountWasExplicit = true
    draft.categoryWasExplicit = true
    draft.accountCandidates = [
      SlipCandidate(id: "acct-everyday", name: "Everyday"),
      SlipCandidate(id: "acct-travel", name: "Travel"),
    ]
    draft.categoryCandidates = [
      SlipCandidate(id: "cat-groceries", name: "Groceries"),
      SlipCandidate(id: "cat-dining", name: "Dining Out"),
    ]
    session.replaceDrafts([draft])
    session.appendUserMessage("Lunch $12 on the card")
    session.appendAssistantMessage("Which account would you like to use for lunch?")
    session.hydrateOwnershipIfNeeded()
    return session
  }

  func admitClarification() -> CaptureSession {
    let session = admit()
    session.replaceDrafts([
      item(payee: "Coffee", amount: 5_000, account: "acct-everyday"),
      item(payee: "Lunch", amount: 12_000, account: "acct-everyday"),
    ])
    session.ownUnownedDrafts(as: "Entered from a shortcut")
    session.composerText = "Make that 21"
    _ = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    _ = session.beginTurn()
    var mapped = TransactionDraft()
    mapped.payeeName = "Coffee"
    mapped.amountMagnitudeMilli = 21_000
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Which transaction should I change?",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [
        SlipMappedDraft(
          draft: mapped,
          parsedAmount: true,
          parsedDate: false,
          parsedAccount: false,
          parsedCategory: false,
          parsedDirection: false,
          accountCandidates: [],
          categoryCandidates: []
        ),
      ],
      expectedGeneration: session.generation
    )
    _ = session.finishTurn(generation: session.generation)
    return session
  }

  func admitMulti() -> CaptureSession {
    let session = admit()
    session.replaceDrafts([
      item(payee: "Coffee", amount: 5_000, account: "acct-everyday", category: "cat-groceries"),
      item(payee: "Lunch", amount: 12_000, account: "acct-travel", category: "cat-groceries", explicit: true),
    ])
    session.appendUserMessage("Coffee $5 and lunch $12 on Travel")
    session.appendAssistantMessage("I've got coffee and lunch ready for you. They aren't saved yet.")
    session.hydrateOwnershipIfNeeded()
    return session
  }

  func admitImage() -> CaptureSession {
    let session = admitParsed()
    session.addAttachment(
      CaptureAttachment(
        filename: "slip.jpg",
        data: Self.validThumbnailJPEG(),
        recognizedText: "SLIP"
      )
    )
    return session
  }

  func admitManual() -> CaptureSession {
    let session = admit()
    session.replaceDrafts([
      item(payee: "Lunch", amount: 12_000, account: "acct-everyday", category: "cat-groceries"),
    ])
    session.ownUnownedDrafts(as: "Entered manually")
    return session
  }

  func admitLargeType() -> CaptureSession {
    let session = admit()
    session.replaceDrafts([
      item(payee: "Lunch", amount: 12_000, account: "acct-everyday", category: "cat-groceries"),
    ])
    session.appendUserMessage("Added from a typed sentence.")
    session.appendAssistantMessage("I've got this draft ready for you. It isn't saved yet.")
    session.hydrateOwnershipIfNeeded()
    return session
  }

  func admitConversation() -> CaptureSession {
    let session = admitParsed()
    session.appendUserMessage("What did I spend today?")
    session.appendAssistantMessage("I need a recorded-spending answer from the local ledger.")
    return session
  }

  func admitSentPhoto() -> CaptureSession {
    let session = admit()
    session.addAttachment(
      CaptureAttachment(
        filename: "slip.jpg",
        data: Self.validThumbnailJPEG(),
        recognizedText: "SLIP"
      )
    )
    session.composerText = "Lunch with Jo"
    _ = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    session.interruptGeneratingReplies()
    return session
  }

  func admitPendingPhoto() -> CaptureSession {
    let session = admit()
    session.addAttachment(
      CaptureAttachment(
        filename: "slip.jpg",
        data: Self.validThumbnailJPEG(),
        recognizedText: "",
        isReading: true
      )
    )
    session.isTransferringImages = true
    return session
  }

  func admitQuery() -> CaptureSession {
    let session = admit()
    session.appendUserMessage("How much did I spend on dining?")
    let card = LedgerQueryResult(
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
          categoryName: "Dining",
          isSplitPortion: false
        ),
      ],
      sourceCount: 1,
      isPreview: false,
      isRecordedSpending: true,
      isUnavailable: false
    )
    session.queryCards = [card]
    session.appendAssistantMessage("You recorded $24.00 in dining.", ownedDraftIDs: [], queryID: card.id)
    return session
  }

  func admitGenerating() -> CaptureSession {
    let session = admit()
    session.composerText = "Lunch $12"
    _ = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    return session
  }

  func admitFailedReply() -> CaptureSession {
    let session = admit()
    session.composerText = "Lunch $12"
    let frozen = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    if let index = session.messages.firstIndex(where: { $0.id == frozen.replyMessageID }) {
      session.messages[index].replyState = .failed
      session.messages[index].text = "Couldn't finish. Nothing was saved; existing drafts are unchanged."
    }
    return session
  }

  func admitSamePayeeClarification() -> CaptureSession {
    let session = admit()
    var morning = item(payee: "Coffee", amount: 5_000, account: "acct-everyday")
    morning.draft.date = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 1)) ?? morning.draft.date
    var afternoon = item(payee: "Coffee", amount: 12_000, account: "acct-everyday")
    afternoon.draft.date = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 15)) ?? afternoon.draft.date
    session.replaceDrafts([morning, afternoon])
    session.ownUnownedDrafts(as: "Entered from a shortcut")
    session.composerText = "Make that 21"
    _ = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-08-20")
    _ = session.beginTurn()
    var mapped = TransactionDraft()
    mapped.payeeName = "Coffee"
    mapped.amountMagnitudeMilli = 21_000
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Which transaction should I change?",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [
        SlipMappedDraft(
          draft: mapped,
          parsedAmount: true,
          parsedDate: false,
          parsedAccount: false,
          parsedCategory: false,
          parsedDirection: false,
          accountCandidates: [],
          categoryCandidates: []
        ),
      ],
      expectedGeneration: session.generation
    )
    _ = session.finishTurn(generation: session.generation)
    return session
  }

  func admitPendingQueryClarification(includeCategory: Bool = true) -> CaptureSession {
    let session = admit()
    session.composerText = "What did I spend on the card?"
    let frozen = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    session.pendingQuery = LedgerQueryResolution(
      spec: LedgerQuerySpec(kind: .spending, category: "", account: "Account", merchant: "", from: "2026-09-01", to: "2026-09-06"),
      from: "2026-09-01",
      to: "2026-09-06",
      priorFrom: nil,
      priorTo: nil,
      accountIDs: [],
      categoryIDs: [],
      accountLabel: "All accounts",
      categoryLabel: "Recorded spending",
      unresolvedAccount: [
        SlipCandidate(id: "acct-everyday", name: "Everyday"),
        SlipCandidate(id: "acct-travel", name: "Travel"),
      ],
      unresolvedCategory: includeCategory
        ? [
          SlipCandidate(id: "cat-groceries", name: "Groceries"),
          SlipCandidate(id: "cat-dining", name: "Dining Out"),
        ]
        : [],
      categoryWasExplicit: false
    )
    session.pendingQueryReplyID = frozen.replyMessageID
    session.recordFailedTurn("Which account or category did you mean? I will not guess.")
    return session
  }

  func admitInterruptedImage() -> CaptureSession {
    let session = admit()
    session.addAttachment(
      CaptureAttachment(
        filename: "slip.jpg",
        data: Self.validThumbnailJPEG(),
        recognizedText: "",
        errorMessage: "I could not read text from that image. It is still attached."
      )
    )
    return session
  }

  @discardableResult
  private func admit() -> CaptureSession {
    workspace.admit(
      request: CaptureRequest(
        kind: .blank,
        connectionFingerprint: model.settings.connectionFingerprint,
        origin: .lastUsedOpen
      ),
      scopeKey: model.settings.viewPrefsScopeKey,
      openAccounts: model.openAccounts,
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
  }

  private func item(
    payee: String,
    amount: Int,
    account: String,
    category: String? = nil,
    explicit: Bool = false
  ) -> CaptureDraftItem {
    var draft = TransactionDraft()
    draft.payeeName = payee
    draft.amountMagnitudeMilli = amount
    draft.accountID = account
    draft.categoryID = category
    var item = CaptureDraftItem(draft: draft)
    item.accountWasExplicit = explicit || !account.isEmpty
    item.categoryWasExplicit = category != nil
    return item
  }

  fileprivate static func account(_ id: String, _ name: String) -> Account {
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

  private static func validThumbnailJPEG() -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160))
    let image = renderer.image { context in
      UIColor.systemOrange.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
      let text = "SLIP" as NSString
      let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 36),
        .foregroundColor: UIColor.white,
      ]
      let size = text.size(withAttributes: attrs)
      text.draw(
        at: CGPoint(x: (160 - size.width) / 2, y: (160 - size.height) / 2),
        withAttributes: attrs
      )
    }
    return image.jpegData(compressionQuality: 0.9) ?? Data()
  }
}

@MainActor
private struct SnapshotAXNode {
  let object: NSObject
  let label: String
  let traits: UIAccessibilityTraits
  let frame: CGRect
}

@MainActor
private final class SnapshotSurface {
  private let window: UIWindow
  private let host: UIHostingController<AnyView>
  private let previousKeyWindow: UIWindow?

  init?<V: View>(root: V, size: CGSize) {
    guard let scene = Self.connectedScene() else {
      return nil
    }
    let host = UIHostingController(rootView: AnyView(root))
    host.view.frame = CGRect(origin: .zero, size: size)
    host.view.bounds = CGRect(origin: .zero, size: size)
    host.view.backgroundColor = .systemBackground
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    window.backgroundColor = .systemBackground
    window.rootViewController = host
    previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    window.makeKeyAndVisible()
    self.window = window
    self.host = host
  }

  func captureUntilOCR(
    contains needles: [String],
    timeoutNanoseconds: UInt64 = 800_000_000
  ) async -> (image: UIImage, text: String, isBlank: Bool) {
    let deadline = DispatchTime.now() + .nanoseconds(Int(timeoutNanoseconds))
    var image = captureImage()
    var text = ""
    while true {
      layout()
      image = captureImage()
      if let data = image.jpegData(compressionQuality: 0.85) {
        text = CaptureSnapshotTests.normalizedOCR(await SlipImageText.recognize(data))
      } else {
        text = ""
      }
      let isBlank = image.cgImage == nil || image.size.width < 2 || image.size.height < 2 || text.isEmpty
      let matched = needles.allSatisfy { text.contains(CaptureSnapshotTests.normalizedOCR($0)) }
      if matched || DispatchTime.now() >= deadline {
        return (image, text, isBlank && !matched)
      }
      await Task.yield()
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  func detach() {
    window.resignKey()
    window.isHidden = true
    window.rootViewController = nil
    window.windowScene = nil
    if let previousKeyWindow, previousKeyWindow !== window {
      previousKeyWindow.makeKeyAndVisible()
    }
  }

  func layoutNow() {
    layout()
  }

  func captureVisible() -> UIImage {
    layout()
    return captureImage()
  }

  func firstDescendant<T: UIView>(_ type: T.Type) -> T? {
    Self.search(host.view, type)
  }

  var windowBounds: CGRect { window.bounds }

  var windowSafeAreaInsets: UIEdgeInsets { window.safeAreaInsets }

  func windowFrame(of view: UIView) -> CGRect {
    windowFrame(of: view as NSObject)
  }

  func windowFrame(of object: NSObject) -> CGRect {
    if let view = object as? UIView, view.bounds.width > 0 || view.bounds.height > 0 {
      return view.convert(view.bounds, to: window)
    }
    let screen = object.accessibilityFrame
    if screen.width > 0 || screen.height > 0 {
      return window.convert(screen, from: nil)
    }
    return .zero
  }

  func firstControl(label: String) -> SnapshotAXNode? {
    let nodes = accessibilityNodes()
    return nodes.first {
      $0.label == label && $0.traits.contains(.button)
    } ?? nodes.first { $0.label == label }
  }

  func firstControl(labelContains needle: String) -> SnapshotAXNode? {
    controls(labelContains: needle).first
  }

  func controls(labelContains needle: String) -> [SnapshotAXNode] {
    let nodes = accessibilityNodes()
    let buttons = nodes.filter {
      $0.label.localizedStandardContains(needle) && $0.traits.contains(.button)
    }
    if !buttons.isEmpty {
      return buttons
    }
    return nodes.filter { $0.label.localizedStandardContains(needle) }
  }

  func assertMinimumHitTarget(_ node: SnapshotAXNode, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThanOrEqual(node.frame.width, 44, "\(node.label) width \(node.frame)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(node.frame.height, 44, "\(node.label) height \(node.frame)", file: file, line: line)
  }

  func isControlEnabled(_ node: SnapshotAXNode) -> Bool {
    if node.traits.contains(.notEnabled) {
      return false
    }
    if let control = Self.nearestControl(from: node.object) {
      return control.isEnabled
    }
    return true
  }

  func timelineVisibleFrame() -> CGRect {
    guard let scroll = mainContentScrollView() else {
      return window.bounds
    }
    let insetBounds = scroll.bounds.inset(by: scroll.adjustedContentInset)
    let converted = scroll.convert(insetBounds, to: window)
    return converted.intersection(window.bounds)
  }

  func hasVisibleTimelineControl(label: String) -> Bool {
    guard let node = firstControl(label: label) else {
      return false
    }
    let frame = node.frame
    guard frame.width > 0, frame.height > 0 else {
      return false
    }
    return timelineVisibleFrame().contains(frame)
  }

  func hostNavigationController() -> UINavigationController? {
    func walk(_ controller: UIViewController, seen: inout Set<ObjectIdentifier>) -> UINavigationController? {
      let identity = ObjectIdentifier(controller)
      guard !seen.contains(identity) else {
        return nil
      }
      seen.insert(identity)
      if let navigation = controller as? UINavigationController {
        return navigation
      }
      if let navigation = controller.navigationController {
        return navigation
      }
      for child in controller.children {
        if let found = walk(child, seen: &seen) {
          return found
        }
      }
      if let presented = controller.presentedViewController {
        return walk(presented, seen: &seen)
      }
      return nil
    }
    var seen = Set<ObjectIdentifier>()
    return walk(host, seen: &seen)
  }

  @discardableResult
  func activate(_ node: SnapshotAXNode) -> Bool {
    Self.activate(node.object)
  }

  @discardableResult
  static func activate(_ object: NSObject) -> Bool {
    if object.accessibilityActivate() {
      return true
    }
    guard let control = nearestControl(from: object), control.isEnabled else {
      return false
    }
    let events = control.allControlEvents
    if events.contains(.primaryActionTriggered) {
      control.sendActions(for: .primaryActionTriggered)
      return true
    }
    if events.contains(.touchUpInside) {
      control.sendActions(for: .touchUpInside)
      return true
    }
    return false
  }

  func waitUntil(
    timeoutNanoseconds: UInt64 = 1_500_000_000,
    _ predicate: () -> Bool
  ) async -> Bool {
    let deadline = DispatchTime.now() + .nanoseconds(Int(timeoutNanoseconds))
    layoutNow()
    if predicate() {
      return true
    }
    while DispatchTime.now() < deadline {
      try? await Task.sleep(nanoseconds: 50_000_000)
      layoutNow()
      if predicate() {
        return true
      }
    }
    return predicate()
  }

  func keyboardFrameInWindow() -> CGRect? {
    guard let scene = window.windowScene else {
      return nil
    }
    for candidate in scene.windows {
      let name = String(describing: type(of: candidate))
      guard name.contains("Keyboard") else {
        continue
      }
      let frame = candidate.convert(candidate.bounds, to: window)
      if frame.height > 1 {
        return frame
      }
    }
    return nil
  }

  func accessibilityLabels() -> [String] {
    accessibilityNodes().map(\.label).filter { !$0.isEmpty }
  }

  private func accessibilityNodes() -> [SnapshotAXNode] {
    var nodes: [SnapshotAXNode] = []
    var seen = Set<ObjectIdentifier>()
    collectAX(from: window, into: &nodes, seen: &seen)
    var presenter: UIViewController? = host
    while let current = presenter {
      guard let presented = current.presentedViewController else {
        break
      }
      collectAX(from: presented.view, into: &nodes, seen: &seen)
      presenter = presented
    }
    return nodes.filter { !$0.label.isEmpty }
  }

  private func collectAX(
    from object: NSObject,
    into nodes: inout [SnapshotAXNode],
    seen: inout Set<ObjectIdentifier>
  ) {
    let identity = ObjectIdentifier(object)
    guard !seen.contains(identity) else {
      return
    }
    seen.insert(identity)

    let label = object.accessibilityLabel ?? ""
    if !label.isEmpty {
      nodes.append(
        SnapshotAXNode(
          object: object,
          label: label,
          traits: object.accessibilityTraits,
          frame: windowFrame(of: object)
        )
      )
    }

    let count = object.accessibilityElementCount()
    if count != NSNotFound, count > 0 {
      for index in 0..<count {
        guard let element = object.accessibilityElement(at: index) as? NSObject else {
          continue
        }
        collectAX(from: element, into: &nodes, seen: &seen)
      }
    } else if let elements = object.accessibilityElements {
      for element in elements {
        guard let child = element as? NSObject else {
          continue
        }
        collectAX(from: child, into: &nodes, seen: &seen)
      }
    }

    if let view = object as? UIView {
      for subview in view.subviews {
        collectAX(from: subview, into: &nodes, seen: &seen)
      }
    }
  }

  private static func nearestControl(from object: NSObject, seen: Set<ObjectIdentifier> = []) -> UIControl? {
    let identity = ObjectIdentifier(object)
    guard !seen.contains(identity) else {
      return nil
    }
    var nextSeen = seen
    nextSeen.insert(identity)
    if let control = object as? UIControl {
      return control
    }
    if let view = object as? UIView {
      var current: UIView? = view.superview
      var walk = nextSeen
      while let candidate = current {
        let step = ObjectIdentifier(candidate)
        if walk.contains(step) {
          break
        }
        walk.insert(step)
        if let control = candidate as? UIControl {
          return control
        }
        current = candidate.superview
      }
    }
    if let container = (object as? UIAccessibilityElement)?.accessibilityContainer as? NSObject {
      return nearestControl(from: container, seen: nextSeen)
    }
    return nil
  }

  func mainContentScrollView() -> UIScrollView? {
    var scrolls: [UIScrollView] = []
    Self.collect(host.view, UIScrollView.self, into: &scrolls)
    return scrolls
      .filter { !($0 is UITextView) }
      .max { lhs, rhs in
        if lhs.contentSize.height != rhs.contentSize.height {
          return lhs.contentSize.height < rhs.contentSize.height
        }
        return lhs.bounds.height < rhs.bounds.height
      }
  }

  func mainScrollVisibleHeight() -> CGFloat {
    guard let scroll = mainContentScrollView() else {
      return 1
    }
    return max(1, scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom)
  }

  func mainScrollStep() -> CGFloat {
    let visible = mainScrollVisibleHeight()
    return min(100, max(44, visible * 0.5))
  }

  func mainScrollMaxOffset() -> CGFloat {
    guard let scroll = mainContentScrollView() else {
      return 0
    }
    return max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
  }

  func scrollGeometryDiagnostics() -> String {
    guard let scroll = mainContentScrollView() else {
      return "no content UIScrollView"
    }
    return "offset=\(scroll.contentOffset.y) max=\(mainScrollMaxOffset()) visible=\(mainScrollVisibleHeight()) bounds=\(scroll.bounds.height) content=\(scroll.contentSize.height) inset=\(scroll.adjustedContentInset)"
  }

  func settleVisible() async {
    layoutNow()
    try? await Task.sleep(nanoseconds: 20_000_000)
    layoutNow()
  }

  @discardableResult
  func setMainScrollOffsetY(_ y: CGFloat) async -> Bool {
    guard let scroll = mainContentScrollView() else {
      return false
    }
    let minY = -scroll.adjustedContentInset.top
    let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    scroll.setContentOffset(CGPoint(x: 0, y: min(maxY, max(minY, y))), animated: false)
    await settleVisible()
    return true
  }

  private func layout() {
    window.layoutIfNeeded()
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
  }

  private static func search<T: UIView>(_ view: UIView, _ type: T.Type) -> T? {
    if let match = view as? T {
      return match
    }
    for subview in view.subviews {
      if let found = search(subview, type) {
        return found
      }
    }
    return nil
  }

  private static func collect<T: UIView>(_ view: UIView, _ type: T.Type, into matches: inout [T]) {
    if let match = view as? T {
      matches.append(match)
    }
    for subview in view.subviews {
      collect(subview, type, into: &matches)
    }
  }

  private func captureImage() -> UIImage {
    let bounds = window.bounds
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    format.opaque = true
    return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
      window.drawHierarchy(in: bounds, afterScreenUpdates: true)
    }
  }

  private static func connectedScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
  }
}

private final class SnapshotHomeBriefRequestLog: @unchecked Sendable {
  static let shared = SnapshotHomeBriefRequestLog()
  private let lock = NSLock()
  private var urls: [URL] = []

  func reset() {
    lock.lock()
    urls = []
    lock.unlock()
  }

  func append(_ url: URL) {
    lock.lock()
    urls.append(url)
    lock.unlock()
  }

  func snapshot() -> [URL] {
    lock.lock()
    defer { lock.unlock() }
    return urls
  }
}

private final class SnapshotHomeBriefFailureProtocol: URLProtocol {
  static let fixtureHost = "howmuch-snapshot-home.test"
  static let fixtureBaseURL = "https://howmuch-snapshot-home.test"

  static var recorded: [URL] {
    SnapshotHomeBriefRequestLog.shared.snapshot()
  }

  static func reset() {
    SnapshotHomeBriefRequestLog.shared.reset()
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.lowercased() == fixtureHost
  }

  override class func canInit(with task: URLSessionTask) -> Bool {
    guard let request = task.currentRequest ?? task.originalRequest else {
      return false
    }
    return canInit(with: request)
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    if let url = request.url {
      SnapshotHomeBriefRequestLog.shared.append(url)
    }
    client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
  }

  override func stopLoading() {}
}

private final class SnapshotQueryDelayLog: @unchecked Sendable {
  static let shared = SnapshotQueryDelayLog()
  private let lock = NSLock()
  private var startedURLs: [URL] = []
  private var stopCount = 0

  func reset() {
    lock.lock()
    startedURLs = []
    stopCount = 0
    lock.unlock()
  }

  func appendStarted(_ url: URL) {
    lock.lock()
    startedURLs.append(url)
    lock.unlock()
  }

  func markStopped() {
    lock.lock()
    stopCount += 1
    lock.unlock()
  }

  func started() -> [URL] {
    lock.lock()
    defer { lock.unlock() }
    return startedURLs
  }

  func stopped() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return stopCount
  }
}

private final class SnapshotQueryDelayProtocol: URLProtocol {
  static let fixtureHost = "howmuch-snapshot-query.test"
  static let fixtureBaseURL = "https://howmuch-snapshot-query.test"

  static var started: [URL] {
    SnapshotQueryDelayLog.shared.started()
  }

  static var stopped: Int {
    SnapshotQueryDelayLog.shared.stopped()
  }

  static func reset() {
    SnapshotQueryDelayLog.shared.reset()
  }

  private let stateLock = NSLock()
  private var cancelled = false
  private var workItem: DispatchWorkItem?

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.lowercased() == fixtureHost
  }

  override class func canInit(with task: URLSessionTask) -> Bool {
    guard let request = task.currentRequest ?? task.originalRequest else {
      return false
    }
    return canInit(with: request)
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    if let url = request.url {
      SnapshotQueryDelayLog.shared.appendStarted(url)
    }
    let item = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }
      self.stateLock.lock()
      let cancelled = self.cancelled
      self.stateLock.unlock()
      guard !cancelled else {
        return
      }
      self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    stateLock.lock()
    workItem = item
    stateLock.unlock()
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2, execute: item)
  }

  override func stopLoading() {
    stateLock.lock()
    cancelled = true
    workItem?.cancel()
    stateLock.unlock()
    SnapshotQueryDelayLog.shared.markStopped()
  }
}
