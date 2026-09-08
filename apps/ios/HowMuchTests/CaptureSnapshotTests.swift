import SwiftUI
import UIKit
import XCTest
#if canImport(Vision)
import Vision
#endif
@testable import HowMuch

@MainActor
final class CaptureSnapshotTests: XCTestCase {
  func testAddManuallySavesOnceAndCancelPreservesConversation() async {
    // Reuse the immediate offline transport so Save exercises the real outbox
    // without an unpredictable socket timeout or any real ledger request.
    XCTAssertTrue(URLProtocol.registerClass(SnapshotHomeBriefFailureProtocol.self))
    defer { URLProtocol.unregisterClass(SnapshotHomeBriefFailureProtocol.self) }
    for size in [DynamicTypeSize.large, .accessibility3] {
      SnapshotHomeBriefFailureProtocol.reset()
      let harness = SnapshotHarness.make(baseURLString: SnapshotHomeBriefFailureProtocol.fixtureBaseURL)
      harness.model.settings.authenticatedUserID = "manual-fixture-\(UUID().uuidString)"
      let session = harness.admitParsed()
      session.selectedAccountID = "acct-travel"
      session.composerText = "Keep this unsent message"
      let attachment = CaptureAttachment(filename: "pending.jpg", data: Data([1, 2, 3]), isReading: true)
      session.addAttachment(attachment)
      let draftIDs = session.drafts.map(\.id)
      let messageIDs = session.messages.map(\.id)
      guard let surface = SnapshotSurface(
        root: AddTransactionsView(session: session, workspace: harness.workspace)
          .environment(harness.model)
          .environment(\.dynamicTypeSize, size),
        size: CGSize(width: 390, height: 844)
      ) else {
        XCTFail("manual entry requires a connected UIWindowScene")
        continue
      }
      defer {
        surface.detach()
        for row in harness.model.pendingRows { harness.model.discardPending(row.id) }
      }
      _ = await surface.captureUntilOCR(contains: ["Lunch"])
      attachImage(surface.captureVisible(), name: "manual-entry-conversation-\(size)")
      guard let manual = surface.firstControl(label: "Add manually") else {
        XCTFail("Quick Add must expose Add manually in its dock: \(surface.accessibilityLabels())")
        continue
      }
      surface.assertMinimumHitTarget(manual)
      XCTAssertTrue(surface.windowBounds.contains(manual.frame))
      XCTAssertNil(surface.firstControl(label: "Open in Assistant"))
      XCTAssertTrue(surface.activate(manual))
      let opened = await surface.waitUntil { surface.firstControl(label: "Cancel") != nil }
      XCTAssertTrue(opened)
      _ = await surface.captureUntilOCR(contains: ["Add Transaction", "Travel"])
      attachImage(surface.captureVisible(), name: "manual-entry-form-\(size)")
      guard let cancel = surface.firstControl(label: "Cancel"),
            let digit = surface.firstControl(label: "1") else {
        XCTFail("normal manual form must expose Cancel and its calculator")
        continue
      }
      XCTAssertTrue(surface.activate(digit))
      XCTAssertTrue(surface.activate(cancel))
      let closed = await surface.waitUntil { surface.firstControl(label: "Cancel") == nil }
      XCTAssertTrue(closed)
      await surface.settleNavigation()
      XCTAssertTrue(harness.model.pendingRows.isEmpty, "Cancel must not enqueue a transaction")
      XCTAssertEqual(harness.workspace.current?.id, session.id)
      XCTAssertEqual(session.composerText, "Keep this unsent message")
      XCTAssertEqual(session.drafts.map(\.id), draftIDs)
      XCTAssertEqual(session.messages.map(\.id), messageIDs)
      XCTAssertEqual(session.attachments.map(\.id), [attachment.id])
      XCTAssertTrue(session.attachments[0].isReading)

      guard let reopen = surface.firstControl(label: "Add manually") else {
        XCTFail("manual action must remain available after Cancel")
        continue
      }
      XCTAssertTrue(surface.activate(reopen))
      let reopened = await surface.waitUntil { surface.firstControl(label: "1") != nil }
      XCTAssertTrue(reopened)
      await surface.settleNavigation()
      for label in ["1", "2", "0", "0", "next"] {
        guard let control = surface.firstControl(label: label) else {
          XCTFail("manual calculator missing \(label): \(surface.accessibilityLabels())")
          break
        }
        XCTAssertTrue(surface.activate(control))
        await surface.settleVisible()
      }
      let choosingPayee = await surface.waitUntil { surface.firstControl(label: "Lunch Shop") != nil }
      XCTAssertTrue(choosingPayee)
      await surface.settleNavigation()
      guard let payee = surface.firstControl(label: "Lunch Shop") else { continue }
      XCTAssertTrue(surface.activate(payee))
      let ready = await surface.waitUntil { surface.firstControl(label: "Save") != nil }
      XCTAssertTrue(ready, "\(size) Save missing after payee selection: \(surface.accessibilityLabels())")
      await surface.settleNavigation()
      let rendered = await surface.captureUntilOCR(contains: ["Add Transaction", "Lunch Shop", "Save"])
      XCTAssertTrue(rendered.text.contains(Self.normalizedOCR("Add Transaction")), "manual form title missing in OCR [\(rendered.text)]")
      XCTAssertTrue(rendered.text.contains(Self.normalizedOCR("Save")), "manual Save missing in OCR [\(rendered.text)]")
      attachImage(rendered.image, name: "manual-entry-ready-\(size)")
      guard let save = surface.firstControl(label: "Save") else { continue }
      XCTAssertTrue(surface.isControlEnabled(save))
      XCTAssertTrue(surface.activate(save))
      _ = surface.activate(save) // A rapid second activation must not enqueue twice.
      let saved = await surface.waitUntil {
        harness.model.pendingRows.count == 1 && surface.firstControl(label: "Cancel") == nil
      }
      XCTAssertTrue(saved, "Save must enqueue directly and dismiss the manual sheet")
      XCTAssertEqual(harness.model.pendingRows.count, 1)
      XCTAssertEqual(harness.model.pendingRows.first?.signedAmount, -12_000)
      XCTAssertEqual(harness.model.pendingRows.first?.accountID, "acct-travel")
      XCTAssertEqual(harness.model.pendingRows.first?.payeeName, "Lunch Shop")
      XCTAssertTrue(harness.model.transactions.isEmpty, "local Save does not claim server success")
      XCTAssertEqual(harness.workspace.current?.id, session.id)
      XCTAssertEqual(session.composerText, "Keep this unsent message")
      XCTAssertEqual(session.drafts.map(\.id), draftIDs, "manual Save must not create a second saveable chat card")
      XCTAssertEqual(session.messages.map(\.id), messageIDs)
      XCTAssertEqual(session.attachments.map(\.id), [attachment.id])
      let drained = await surface.waitUntil {
        !SnapshotHomeBriefFailureProtocol.recorded.isEmpty && !harness.model.isSyncingOutbox
      }
      XCTAssertTrue(drained, "the fixture's offline request must finish before outbox cleanup")
      for row in harness.model.pendingRows { harness.model.discardPending(row.id) }
      XCTAssertTrue(harness.model.pendingRows.isEmpty)
      XCTAssertFalse(
        OutboxStore.load().contains { $0.connectionFingerprint == harness.model.settings.connectionFingerprint },
        "manual Save fixture must leave no persisted outbox residue"
      )
    }
  }

  func testBlankConversationIgnoresRememberedManualEntry() async {
    let suite = "howmuch.tests.manual-preference.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let harness = SnapshotHarness.make(store: CaptureWorkspaceStore(defaults: defaults, rootURL: directory))
    let scope = harness.model.settings.viewPrefsScopeKey!
    defaults.set("manual", forKey: "HowMuch.CaptureEntryMode.\(scope)")
    harness.workspace.dropForScopeChange()
    let session = harness.admitEmpty()
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace).environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("conversation entry requires a connected UIWindowScene")
      return
    }
    defer { surface.detach() }
    let rendered = await surface.captureUntilOCR(contains: ["Add an expense"])
    XCTAssertTrue(rendered.text.contains(Self.normalizedOCR("Add an expense")))
    XCTAssertNil(surface.firstControl(label: "Cancel"), "a remembered mode must not route a conversation request to the form")
    XCTAssertEqual(session.entryMode, .describe)
    XCTAssertNotNil(surface.firstControl(label: "Send"))
  }

  func testFloatingAddTapAndAccessibilityActionUseDistinctRoutes() async {
    let router = CaptureRouter.shared
    let previous = router.pending
    defer { router.pending = previous }
    for size in [DynamicTypeSize.large, .accessibility3] {
      let harness = SnapshotHarness.make()
      let origin = CaptureOrigin.visibleRegister(accountID: "acct-travel")
      let chrome = RootChromeState()
      guard let surface = SnapshotSurface(
        root: ZStack {
          TabView(selection: Binding(
            get: { chrome.tab },
            set: { chrome.tab = $0 }
          )) {
            Tab("Accounts", systemImage: "building.columns", value: AppTab.accounts) {
              Text("Entry fixture")
            }
            Tab("Rewards", systemImage: "creditcard", value: AppTab.rewards) {
              Text("Rewards fixture")
            }
            Tab("Reflect", systemImage: "chart.bar.fill", value: AppTab.reflect) {
              Text("Reflect fixture")
            }
          }
          RootAddControl(presenting: {
            harness.model.presentAddTransactions(origin: origin)
          }, presentingManually: {
            harness.model.presentManualTransaction(origin: origin)
          })
          .padding(RootChrome.addControlInsets(idiom: .phone, horizontalSizeClass: .compact))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .environment(chrome)
        .environment(harness.model)
        .environment(\.dynamicTypeSize, size),
        size: CGSize(width: 390, height: 844)
      ) else {
        XCTFail("root Add control needs a connected UIWindowScene")
        continue
      }
      defer { surface.detach() }
      let appeared = await surface.waitUntil { surface.firstControl(label: "Add Transactions") != nil }
      XCTAssertTrue(appeared)
      guard let button = surface.firstControl(label: "Add Transactions") else { continue }
      surface.assertMinimumHitTarget(button)
      XCTAssertTrue(surface.windowBounds.contains(button.frame))
      for label in ["Accounts", "Rewards", "Reflect"] {
        guard let destination = surface.firstControl(label: label) else {
          XCTFail("root tab missing \(label)")
          continue
        }
        XCTAssertGreaterThan(
          abs(button.frame.midY - destination.frame.midY),
          12,
          "Add is a floating plus, not a tab-row item"
        )
        XCTAssertFalse(destination.object.accessibilityCustomActions?.contains { $0.name == "Add manually" } == true)
      }
      attachImage(surface.captureVisible(), name: "manual-entry-fab-\(size)")
      XCTAssertTrue(surface.activate(button))
      XCTAssertEqual(router.pending?.kind, .blank, "ordinary tap must remain conversational")
      XCTAssertEqual(router.pending?.origin, origin)
      XCTAssertEqual(chrome.tab, .accounts, "Add must not replace the selected destination")
      _ = await surface.waitUntil {
        surface.firstControl(label: "Add Transactions")?.object.accessibilityCustomActions?.contains { $0.name == "Add manually" } == true
      }
      guard let manual = surface.firstControl(label: "Add Transactions")?.object.accessibilityCustomActions?.first(where: { $0.name == "Add manually" }),
            let handler = manual.actionHandler else {
        XCTFail("the floating plus must expose an actionable Add manually VoiceOver action")
        continue
      }
      XCTAssertTrue(handler(manual))
      guard let request = router.pending, case .manual(let draft) = request.kind else {
        XCTFail("manual accessibility action must enqueue the form, not conversation")
        continue
      }
      XCTAssertTrue(draft.accountID.isEmpty, "resolve the frozen origin only after references load")
      XCTAssertEqual(router.pending?.origin, origin)
      XCTAssertTrue(harness.model.pendingRows.isEmpty)
    }
  }

  func testManualIntakeHostPreservesConversationAndAccountIntent() async {
    let router = CaptureRouter.shared
    let previous = router.presented
    defer { router.presented = previous }
    var preset = TransactionDraft()
    preset.accountID = "acct-everyday"
    preset.amountMagnitudeMilli = 5_700
    preset.payeeName = "Shortcut coffee"
    preset.memo = "Shortcut fixture"
    var stale = preset
    stale.accountID = "missing-account"
    let cases: [(String, TransactionDraft, CaptureOrigin, String)] = [
      ("blank", TransactionDraft(), .visibleRegister(accountID: "acct-travel"), "Travel"),
      ("prefilled", preset, .presetDraft, "Everyday"),
      ("stale-account", stale, .presetDraft, "Choose Account"),
    ]
    for (name, draft, origin, account) in cases {
      let harness = SnapshotHarness.make()
      let session = harness.admitParsed()
      session.composerText = "Keep the conversation"
      let generation = session.generation
      let request = CaptureRequest(kind: .manual(draft), connectionFingerprint: harness.model.settings.connectionFingerprint, origin: origin)
      router.presented = request
      guard let surface = SnapshotSurface(
        root: Text("Entry fixture")
          .sheet(item: Binding(get: { router.presented }, set: { router.presented = $0 })) { request in
            CaptureIntakeHost(request: request, workspace: harness.workspace)
              .environment(harness.model)
          },
        size: CGSize(width: 390, height: 844)
      ) else {
        XCTFail("manual intake needs a connected UIWindowScene")
        continue
      }
      defer { surface.detach() }
      let admitted = await surface.waitUntil {
        surface.firstControl(label: "Cancel") != nil
          && surface.firstControl(labelContains: account) != nil
      }
      XCTAssertTrue(admitted, "\(name) manual intake must finish admission: \(surface.accessibilityLabels())")
      let rendered = await surface.captureUntilOCR(
        contains: ["Add Transaction", account],
        timeoutNanoseconds: 2_000_000_000
      )
      XCTAssertTrue(rendered.text.contains(Self.normalizedOCR("Add Transaction")), "\(name) title missing in OCR [\(rendered.text)]")
      XCTAssertTrue(rendered.text.contains(Self.normalizedOCR(account)), "\(name) account missing in OCR [\(rendered.text)]")
      attachImage(rendered.image, name: "manual-entry-intake-\(name)")
      XCTAssertEqual(harness.workspace.current?.id, session.id)
      XCTAssertEqual(session.composerText, "Keep the conversation")
      XCTAssertEqual(session.generation, generation, "manual intake must not cancel or replace a separate conversation")
      XCTAssertEqual(session.drafts.count, 1)
      XCTAssertFalse(session.drafts[0].committed)
      XCTAssertNil(surface.firstControl(label: "Send"))
      if name != "blank" {
        guard let save = surface.firstControl(label: "Save") else {
          XCTFail("prefilled normal form must expose Save")
          continue
        }
        XCTAssertEqual(surface.isControlEnabled(save), name == "prefilled", "unresolved explicit account must block Save")
        XCTAssertNotNil(surface.firstControl(labelContains: "Shortcut coffee"))
      }
      guard let cancel = surface.firstControl(label: "Cancel") else { continue }
      XCTAssertTrue(surface.activate(cancel))
      let closed = await surface.waitUntil { router.presented == nil }
      XCTAssertTrue(closed)
      XCTAssertTrue(harness.model.pendingRows.isEmpty)
      XCTAssertEqual(harness.workspace.current?.id, session.id)
    }
  }

  func testManualShortcutTransferRequiresDistinctInheritedSource() async throws {
    let router = CaptureRouter.shared
    let previous = router.presented
    let preferencesKey = ScopedViewPrefsStore.userDefaultsKey
    let previousPreferences = UserDefaults.standard.object(forKey: preferencesKey)
    defer {
      router.presented = previous
      UserDefaults.standard.set(previousPreferences, forKey: preferencesKey)
    }
    let cases: [(String, String?)] = [("last-used", "acct-travel"), ("fallback", nil)]
    for (name, lastUsedAccountID) in cases {
      let harness = SnapshotHarness.make(
        baseURLString: "https://manual-transfer-\(UUID().uuidString.lowercased()).invalid",
        lastUsedAccountID: lastUsedAccountID
      )
      if lastUsedAccountID == nil { harness.model.accounts.reverse() }
      harness.model.payees.append(
        Payee(id: "payee-transfer", name: "Transfer to Travel", transferAccountId: "acct-travel", deleted: false)
      )
      harness.model.rebuildLookups()
      XCTAssertEqual(harness.model.lastUsedOpenAccountID, lastUsedAccountID)
      if lastUsedAccountID == nil { XCTAssertEqual(harness.model.openAccounts.first?.id, "acct-travel") }
      let request = try AddTransactionIntentBuilder.request(
        amount: Decimal(12), direction: .outflow, accountID: nil,
        payee: .init(id: "payee-transfer", name: "Transfer to Travel", transferAccountId: "acct-travel", isNew: false),
        categoryID: nil, date: nil, flag: nil, memo: nil, cleared: nil,
        catalog: IntentCatalogSnapshot.project(
          fingerprint: harness.model.settings.connectionFingerprint,
          accounts: harness.model.accounts, categoryGroups: harness.model.categoryGroups, payees: harness.model.payees
        )
      )
      guard case .manual(let draft) = request.kind else {
        return XCTFail("structured transfer shortcut must open the manual form")
      }
      XCTAssertEqual(request.origin, .lastUsedOpen)
      XCTAssertTrue(draft.accountID.isEmpty)
      XCTAssertEqual(draft.transferAccountID, "acct-travel")
      router.presented = request
      guard let surface = SnapshotSurface(
        root: Text("Entry fixture")
          .sheet(item: Binding(get: { router.presented }, set: { router.presented = $0 })) { request in
            CaptureIntakeHost(request: request, workspace: harness.workspace).environment(harness.model)
          },
        size: CGSize(width: 390, height: 844)
      ) else {
        return XCTFail("manual transfer intake needs a connected UIWindowScene")
      }
      defer { surface.detach() }
      let admitted = await surface.waitUntil { surface.firstControl(label: "Save") != nil }
      XCTAssertTrue(admitted)
      await surface.settleNavigation()
      let save = try XCTUnwrap(surface.firstControl(label: "Save"))
      XCTAssertFalse(surface.isControlEnabled(save), "\(name) must not make an inherited self-transfer saveable")
      XCTAssertNotNil(surface.firstControl(labelContains: "Transfer to Travel"), "keep the explicit transfer destination")
      attachImage(surface.captureVisible(), name: "manual-transfer-blocked-\(name)")
      guard let account = surface.firstControl(labelContains: "Choose Account") else {
        XCTFail("\(name) must require a source distinct from the transfer destination: \(surface.accessibilityLabels())")
        continue
      }
      XCTAssertTrue(surface.activate(account))
      let choosing = await surface.waitUntil { surface.firstControl(label: "Everyday") != nil }
      XCTAssertTrue(choosing)
      await surface.settleNavigation()
      let everyday = try XCTUnwrap(surface.firstControl(label: "Everyday"))
      XCTAssertTrue(surface.activate(everyday))
      await surface.settleNavigation()
      let rendered = await surface.captureUntilOCR(contains: ["Add Transaction", "Transfer to Travel", "Everyday", "Save"])
      XCTAssertTrue(rendered.text.contains(Self.normalizedOCR("Transfer to Travel")))
      XCTAssertTrue(rendered.text.contains(Self.normalizedOCR("Everyday")))
      attachImage(rendered.image, name: "manual-transfer-ready-\(name)")
      let readySave = try XCTUnwrap(surface.firstControl(label: "Save"))
      XCTAssertTrue(surface.isControlEnabled(readySave), "a distinct source must allow the preserved transfer")
      let cancel = try XCTUnwrap(surface.firstControl(label: "Cancel"))
      XCTAssertTrue(surface.activate(cancel))
      let closed = await surface.waitUntil { router.presented == nil }
      XCTAssertTrue(closed)
      XCTAssertTrue(harness.model.pendingRows.isEmpty, "checking transfer readiness must not save anything")
    }
  }

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
      ("error", ["Couldn't finish", "Add manually"], { harness in
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
      ("long-account", ["Everyday Joint Household Spending", "Add manually"], { harness in
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
      .environment(conversation.model)
      .environment(RootChromeState()),
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
      .environment(home.model)
      .environment(RootChromeState()),
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
    for label in ["Save transaction", "Edit", "Send", "Add manually"] {
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
      for label in ["Edit", "Save transaction", "Add manually"] {
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

    guard await openManualForm(on: surface) else { return }
    XCTAssertFalse(field.isFirstResponder, "Manual should resign the describe composer")
    XCTAssertNotNil(surface.firstDescendant(PasteAwareTextView.self), "the conversation dock stays mounted")

    guard let cancel = surface.firstControl(label: "Cancel") else {
      return XCTFail("manual form must expose Cancel")
    }
    XCTAssertTrue(surface.activate(cancel))
    let closed = await surface.waitUntil { surface.firstControl(label: "Cancel") == nil }
    XCTAssertTrue(closed)
    XCTAssertTrue(field.becomeFirstResponder())
    field.insertText("!")
    try? await Task.sleep(nanoseconds: 20_000_000)
    surface.layoutNow()
    XCTAssertTrue(field.isFirstResponder)
    XCTAssertTrue((field.text ?? "").contains("!"))
    XCTAssertTrue(session.composerText.contains("!"))
  }

  func testComposerInsetsCenterBodyLineInMinRow() {
    let font = CaptureComposerMetrics.bodyFont()
    let inset = CaptureComposerMetrics.textContainerInset(for: font)
    XCTAssertEqual(inset.top, inset.bottom)
    XCTAssertEqual(inset.left, CaptureComposerMetrics.horizontalInset)
    XCTAssertEqual(inset.right, CaptureComposerMetrics.horizontalInset)
    let stacked = inset.top + font.lineHeight + inset.bottom
    if font.lineHeight + 16 <= CaptureComposerMetrics.minHeight {
      XCTAssertEqual(
        stacked,
        CaptureComposerMetrics.minHeight,
        accuracy: 1,
        "single-line composer insets must fill the 44pt row: font \(font.lineHeight) inset \(inset.top)"
      )
    } else {
      XCTAssertEqual(inset.top, 8, "large type keeps an 8pt floor rather than a negative inset")
      XCTAssertGreaterThan(stacked, CaptureComposerMetrics.minHeight)
    }
  }

  func testComposerFittedHeightDoesNotClipWrappedUsedRect() {
    let font = CaptureComposerMetrics.bodyFont()
    let inset = CaptureComposerMetrics.textContainerInset(for: font)
    let wrappedUsed = font.lineHeight * 1.2
    let needed = wrappedUsed + inset.top + inset.bottom
    let height = CaptureComposerMetrics.fittedHeight(usedRectHeight: wrappedUsed, font: font, inset: inset)
    XCTAssertGreaterThanOrEqual(height, needed - 0.5, "wrapped usedRect must fit: used \(wrappedUsed) height \(height)")
    XCTAssertGreaterThan(height, CaptureComposerMetrics.minHeight)
    XCTAssertLessThanOrEqual(height, CaptureComposerMetrics.maxHeight)
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
    let plus = surface.firstControl(label: "Add a photo or paste")
    let account = surface.firstControl(labelContains: "Account for next message")
    let manual = surface.firstControl(label: "Add manually")
    XCTAssertNotNil(send, "dock Send AX missing in \(surface.accessibilityLabels())")
    XCTAssertNotNil(plus, "plus AX missing in \(surface.accessibilityLabels())")
    XCTAssertNotNil(account, "account AX missing in \(surface.accessibilityLabels())")
    XCTAssertNotNil(manual, "Add manually AX missing in \(surface.accessibilityLabels())")
    for control in [send, plus, account, manual].compactMap({ $0 }) {
      XCTAssertGreaterThanOrEqual(control.frame.width, 44, "\(control.label) width \(control.frame)")
      XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(control.label) height \(control.frame)")
    }
    if let account, let manual {
      XCTAssertFalse(account.frame.intersects(manual.frame), "account and Add manually must not overlap: \(account.frame) \(manual.frame)")
      XCTAssertEqual(
        account.frame.midY,
        manual.frame.midY,
        accuracy: 12,
        "account and Add manually must share the context row: \(account.frame) \(manual.frame)"
      )
    }
    if let send, let manual {
      XCTAssertLessThanOrEqual(
        manual.frame.maxY,
        send.frame.minY + 1,
        "Add manually must sit above Send: link \(manual.frame) send \(send.frame)"
      )
    }
    XCTAssertGreaterThanOrEqual(field.bounds.height, 44, "empty composer field must keep the 44pt row: \(field.bounds)")
    XCTAssertLessThanOrEqual(field.bounds.height, 64, "empty composer field must stay compact: \(field.bounds)")
    field.insertText("Lunch $12")
    try? await Task.sleep(nanoseconds: 50_000_000)
    surface.layoutNow()
    let plusAfter = surface.firstControl(label: "Add a photo or paste") ?? plus
    let sendAfter = surface.firstControl(label: "Send") ?? send
    let typedFieldFrame = surface.windowFrame(of: field)
    let caret = field.caretRect(for: field.endOfDocument)
    let caretMidY = typedFieldFrame.minY + caret.midY
    if let plusAfter {
      XCTAssertEqual(
        caretMidY,
        plusAfter.frame.midY,
        accuracy: 4,
        "typed composer text must sit on the plus midline: caret \(caretMidY) plus \(plusAfter.frame)"
      )
    }
    if let sendAfter {
      XCTAssertEqual(
        caretMidY,
        sendAfter.frame.midY,
        accuracy: 4,
        "typed composer text must sit on the send midline: caret \(caretMidY) send \(sendAfter.frame)"
      )
    }
    field.text = ""
    session.composerText = ""
    try? await Task.sleep(nanoseconds: 20_000_000)
    surface.layoutNow()
    let fieldFrame = surface.windowFrame(of: field)
    let dockLimit = surface.windowBounds.maxY - surface.windowSafeAreaInsets.bottom
    XCTAssertGreaterThan(fieldFrame.maxY, surface.windowBounds.midY, "composer left the dock: \(fieldFrame) window \(surface.windowBounds)")
    XCTAssertLessThanOrEqual(fieldFrame.maxY, dockLimit + 1, "composer must stay in the window dock: \(fieldFrame) limit \(dockLimit)")
    field.insertText("one\ntwo\nthree\nfour\nfive\nsix")
    try? await Task.sleep(nanoseconds: 50_000_000)
    surface.layoutNow()
    XCTAssertGreaterThan(field.bounds.height, 44, "multiline composer should grow: \(field.bounds)")
    XCTAssertLessThanOrEqual(field.bounds.height, 120, "composer must cap internally: \(field.bounds)")
    XCTAssertGreaterThanOrEqual(
      field.contentOffset.y,
      -0.5,
      "multiline must drop the single-line centering offset: \(field.contentOffset)"
    )
    XCTAssertEqual(field.contentInset.top, 0, accuracy: 0.5, "multiline must drop centering contentInset: \(field.contentInset)")
    XCTAssertEqual(session.composerText, field.text)
    guard await openManualForm(on: surface) else { return }
    XCTAssertEqual(harness.workspace.current?.id, session.id)
    XCTAssertNil(harness.workspace.pendingAssistantSessionID, "manual entry must not navigate to Assistant")
    XCTAssertEqual(session.composerText, field.text, "manual entry must keep unsent composer text")
    XCTAssertTrue(harness.model.transactions.isEmpty, "opening the form must not write the ledger")
    XCTAssertTrue(harness.model.pendingRows.isEmpty, "opening the form must not enqueue a save")
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
      .environment(harness.model)
      .environment(RootChromeState()),
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

  func testConversationDraftEditorDoneAndCancelRemainDraftOnly() async {
    let harness = SnapshotHarness.make()
    let session = harness.admitParsed()
    let id = session.drafts[0].id
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: session, workspace: harness.workspace)
        .environment(harness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("draft editor needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    for finish in ["Cancel", "Done"] {
      _ = await surface.captureUntilOCR(contains: ["Lunch"])
      guard let edit = await revealControl(on: surface, label: "Edit") else {
        return XCTFail("conversation must retain its draft Edit action")
      }
      XCTAssertTrue(surface.activate(edit))
      _ = await surface.captureUntilOCR(contains: ["Edit draft"])
      guard let amount = surface.firstControl(labelContains: "12.00") else {
        return XCTFail("draft editor must expose its amount")
      }
      XCTAssertTrue(surface.activate(amount))
      let keypad = await surface.waitUntil { surface.firstControl(label: "1") != nil }
      XCTAssertTrue(keypad)
      guard let digit = surface.firstControl(label: "1") else { return }
      XCTAssertTrue(surface.activate(digit))
      await surface.settleVisible()
      XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 12_000, "editing must stay local until Done")
      guard let action = surface.controls(labelContains: finish)
        .filter({ $0.label == finish }).min(by: { $0.frame.minY < $1.frame.minY }) else {
        return XCTFail("draft editor must retain toolbar \(finish)")
      }
      XCTAssertTrue(surface.activate(action))
      let closed = await surface.waitUntil { surface.firstControl(label: "Cancel") == nil }
      XCTAssertTrue(closed)
      XCTAssertEqual(session.drafts.map(\.id), [id])
      XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, finish == "Cancel" ? 12_000 : 120_010)
      XCTAssertFalse(session.drafts[0].committed)
      XCTAssertTrue(harness.model.pendingRows.isEmpty, "draft Done must not save to the ledger")
      XCTAssertTrue(harness.model.transactions.isEmpty)
    }
  }

  private func openManualForm(on surface: SnapshotSurface) async -> Bool {
    guard let enter = surface.firstControl(label: "Add manually") else {
      XCTFail("dock missing Add manually in \(surface.accessibilityLabels())")
      return false
    }
    XCTAssertTrue(surface.activate(enter), "Add manually must present the form")
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

    guard await openManualForm(on: surface) else { return }
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

    guard await openManualForm(on: surface) else { return }
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
        for label in labels {
          guard let control = await revealControl(on: surface, label: label, requireTimelineVisible: true) else {
            XCTFail("\(size) \(name) could not scroll candidate \(label) fully into the timeline \(surface.timelineVisibleFrame()) AX \(surface.accessibilityLabels())")
            continue
          }
          XCTAssertNotEqual(
            control.label,
            "Account for next message, \(label), change account",
            "candidate \(label) must not be the account chooser"
          )
          XCTAssertTrue(
            surface.timelineVisibleFrame().contains(control.frame),
            "\(size) \(name) \(label) must sit in the timeline, not under the navbar or composer \(control.frame) timeline \(surface.timelineVisibleFrame())"
          )
          surface.assertMinimumHitTarget(control)
          let slug = label.replacingOccurrences(of: " ", with: "-")
          attachImage(surface.captureVisible(), name: "capture-\(name)-candidates-\(size)-\(slug)")
        }
      }
    }
  }

  func testInterruptedImageOffersRetryReadingAndKeepsRemove() async {
    let cases: [(suffix: String, size: DynamicTypeSize?)] = [
      ("", nil),
      ("-accessibility3", .accessibility3),
    ]
    for item in cases {
      let harness = SnapshotHarness.make()
      let session = harness.admitInterruptedImage()
      XCTAssertEqual(session.attachments.count, 1)
      let attachmentID = session.attachments[0].id
      let bytes = session.attachments[0].data
      XCTAssertFalse(bytes.isEmpty)
      let messageIDs = session.messages.map(\.id)
      let draftIDs = session.drafts.map(\.id)
      let ledgerIDs = harness.model.transactions.map(\.id)
      let root: AnyView
      if let size = item.size {
        root = AnyView(
          AddTransactionsView(session: session, workspace: harness.workspace)
            .environment(harness.model)
            .environment(\.dynamicTypeSize, size)
        )
      } else {
        root = AnyView(
          AddTransactionsView(session: session, workspace: harness.workspace)
            .environment(harness.model)
        )
      }
      guard let surface = SnapshotSurface(root: root, size: CGSize(width: 390, height: 844)) else {
        XCTFail("interrupted image\(item.suffix) needs a connected UIWindowScene")
        continue
      }
      defer { surface.detach() }
      _ = await surface.captureUntilOCR(contains: ["Remove attachment"])
      attachImage(surface.captureVisible(), name: "capture-interrupted-image-recovery\(item.suffix)")
      guard let retry = await revealControl(on: surface, label: "Retry reading image") else {
        XCTFail("Retry reading image missing\(item.suffix) in \(surface.accessibilityLabels())")
        continue
      }
      surface.assertMinimumHitTarget(retry)
      guard let remove = await revealControl(on: surface, label: "Remove attachment") else {
        XCTFail("Remove attachment must stay reachable\(item.suffix) in \(surface.accessibilityLabels())")
        continue
      }
      surface.assertMinimumHitTarget(remove)
      XCTAssertTrue(surface.activate(retry), "Retry reading image must run Vision on the retained bytes\(item.suffix)")
      let recovered = await surface.waitUntil(timeoutNanoseconds: 5_000_000_000, {
        session.attachments.first?.recognizedText.isEmpty == false
          && session.attachments.first?.isReading == false
          && session.attachments.first?.errorMessage == nil
      })
      XCTAssertTrue(recovered, "retry must recover text from the retained SLIP image\(item.suffix)")
      XCTAssertTrue(session.canSendComposer)
      XCTAssertEqual(session.attachments.map(\.id), [attachmentID])
      XCTAssertEqual(session.attachments.first?.data, bytes)
      XCTAssertEqual(session.attachments.count, 1)
      XCTAssertTrue(session.sentAttachments.isEmpty, "retry must not create a sent image\(item.suffix)")
      XCTAssertEqual(session.messages.map(\.id), messageIDs, "retry must not append conversation messages\(item.suffix)")
      XCTAssertTrue(session.queryCards.isEmpty, "retry must not write a query card\(item.suffix)")
      XCTAssertEqual(session.drafts.map(\.id), draftIDs, "retry must not create drafts\(item.suffix)")
      XCTAssertEqual(
        harness.model.transactions.map(\.id),
        ledgerIDs,
        "retry must not write the ledger\(item.suffix)"
      )
      surface.layoutNow()
      attachImage(surface.captureVisible(), name: "capture-interrupted-image-recovered\(item.suffix)")
    }

    let many = SnapshotHarness.make()
    let crowded = many.admitInterruptedImages(3)
    XCTAssertEqual(crowded.attachments.count, 3)
    guard let crowdedSurface = SnapshotSurface(
      root: AddTransactionsView(session: crowded, workspace: many.workspace)
        .environment(many.model)
        .environment(\.dynamicTypeSize, .accessibility3),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("three-error AX3 recovery needs a connected UIWindowScene")
      return
    }
    defer { crowdedSurface.detach() }
    _ = await crowdedSurface.captureUntilOCR(contains: ["Add an expense", "Remove attachment"])
    attachImage(crowdedSurface.captureVisible(), name: "capture-interrupted-image-recovery-three-accessibility3")
    guard let firstRetry = await revealControl(on: crowdedSurface, label: "Retry reading image") else {
      XCTFail("first Retry missing in three-error AX3 \(crowdedSurface.accessibilityLabels())")
      return
    }
    crowdedSurface.assertMinimumHitTarget(firstRetry)
    guard let firstRemove = await revealControl(on: crowdedSurface, label: "Remove attachment") else {
      XCTFail("first Remove missing in three-error AX3 \(crowdedSurface.accessibilityLabels())")
      return
    }
    crowdedSurface.assertMinimumHitTarget(firstRemove)
    XCTAssertNotNil(
      crowdedSurface.firstControl(labelContains: "Account for next message"),
      "three-error AX3 must keep the account context visible \(crowdedSurface.accessibilityLabels())"
    )
    XCTAssertNotNil(
      crowdedSurface.firstControl(label: "Send"),
      "three-error AX3 must keep composer Send visible \(crowdedSurface.accessibilityLabels())"
    )
    XCTAssertNotNil(
      crowdedSurface.firstControl(label: "Add a photo or paste"),
      "three-error AX3 must keep composer plus visible \(crowdedSurface.accessibilityLabels())"
    )
  }

  func testStopCancelsPendingQueryTransportWithoutLateCard() async {
    XCTAssertTrue(
      URLProtocol.registerClass(SnapshotQueryDelayProtocol.self),
      "query delay stub must register on URLSession.shared"
    )
    defer { URLProtocol.unregisterClass(SnapshotQueryDelayProtocol.self) }
    for size in [DynamicTypeSize.large, .accessibility3] {
      SnapshotQueryDelayProtocol.reset()
      let harness = SnapshotHarness.make(baseURLString: SnapshotQueryDelayProtocol.fixtureBaseURL)
      let session = harness.admitPendingQueryClarification(includeCategory: false)
      XCTAssertTrue(session.queryCards.isEmpty)
      XCTAssertTrue(session.pendingQuery?.unresolvedCategory.isEmpty == true)
      let owner = session.pendingQueryReplyID
      let messageCount = session.messages.count
      guard let surface = SnapshotSurface(
        root: AddTransactionsView(session: session, workspace: harness.workspace)
          .environment(harness.model)
          .environment(\.dynamicTypeSize, size),
        size: CGSize(width: 390, height: 844)
      ) else {
        XCTFail("pending query cancel needs a connected UIWindowScene")
        return
      }
      defer { surface.detach() }
      _ = await surface.captureUntilOCR(contains: ["Which account"])
      attachImage(surface.captureVisible(), name: "capture-pending-query-choices-\(size)")
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
      XCTAssertEqual(session.messages.first { $0.id == owner }?.replyState, .generating)
      XCTAssertEqual(session.messages.count, messageCount, "clarification resumes the existing reply")
      XCTAssertEqual(session.aiActivity?.phase, .fetching)
      surface.layoutNow()
      let labels = surface.accessibilityLabels().joined(separator: " | ")
      XCTAssertTrue(labels.contains("HowMuch server"), labels)
      XCTAssertNotNil(labels.range(of: #"Fetching recorded transactions · [0-9]+s"#, options: .regularExpression), labels)
      attachImage(surface.captureVisible(), name: "capture-pending-query-fetching-\(size)")
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
  }

  func testManualAndScopeChangeCancelPendingQueryTransportWithoutLateCard() async {
    SnapshotQueryDelayProtocol.reset()
    XCTAssertTrue(
      URLProtocol.registerClass(SnapshotQueryDelayProtocol.self),
      "query delay stub must register on URLSession.shared"
    )
    defer { URLProtocol.unregisterClass(SnapshotQueryDelayProtocol.self) }
    let cancels: [(String, (SnapshotHarness, SnapshotSurface, CaptureSession) async -> Void)] = [
      ("manual", { _, surface, _ in
        guard let enter = await self.revealControl(on: surface, label: "Add manually") else {
          XCTFail("Add manually missing after query start in \(surface.accessibilityLabels())")
          return
        }
        XCTAssertTrue(surface.activate(enter), "Add manually must be the production control")
      }),
      ("scope", { harness, _, _ in
        harness.workspace.dropForScopeChange()
      }),
    ]
    for (name, cancel) in cancels {
      SnapshotQueryDelayProtocol.reset()
      let harness = SnapshotHarness.make(baseURLString: SnapshotQueryDelayProtocol.fixtureBaseURL)
      let session = harness.admitPendingQueryClarification(includeCategory: false)
      XCTAssertTrue(session.queryCards.isEmpty)
      guard let surface = SnapshotSurface(
        root: AddTransactionsView(session: session, workspace: harness.workspace)
          .environment(harness.model),
        size: CGSize(width: 390, height: 844)
      ) else {
        XCTFail("\(name) pending query cancel needs a connected UIWindowScene")
        continue
      }
      defer { surface.detach() }
      _ = await surface.captureUntilOCR(contains: ["Which account"])
      guard let candidate = await revealControl(on: surface, label: "Everyday") else {
        XCTFail("\(name) query account candidate missing in \(surface.accessibilityLabels())")
        continue
      }
      XCTAssertTrue(surface.activate(candidate), "\(name) tapping Everyday must start the pending query")
      let beganTurn = await surface.waitUntil(timeoutNanoseconds: 1_500_000_000, { session.isBusy })
      XCTAssertTrue(beganTurn, "\(name) pending query pick must begin a turn")
      let startedReport = await surface.waitUntil(timeoutNanoseconds: 1_500_000_000, {
        SnapshotQueryDelayProtocol.started.contains { $0.path.contains("spending-breakdown") }
      })
      XCTAssertTrue(
        startedReport,
        "\(name) delayed query stub must see the spending-breakdown request; started \(SnapshotQueryDelayProtocol.started)"
      )
      guard startedReport else {
        continue
      }
      await cancel(harness, surface, session)
      let stoppedTransport = await surface.waitUntil(timeoutNanoseconds: 1_000_000_000, {
        SnapshotQueryDelayProtocol.stopped > 0
      })
      XCTAssertTrue(
        stoppedTransport,
        "\(name) must cancel URLProtocol promptly; stopped \(SnapshotQueryDelayProtocol.stopped) started \(SnapshotQueryDelayProtocol.started)"
      )
      try? await Task.sleep(nanoseconds: 2_200_000_000)
      surface.layoutNow()
      XCTAssertTrue(session.queryCards.isEmpty, "\(name) cancelled query must not apply a late card")
    }
  }

  func testRestoredPendingMerchantReportClarificationDoesNotFetchAfterAccountChoice() async {
    SnapshotQueryDelayProtocol.reset()
    XCTAssertTrue(
      URLProtocol.registerClass(SnapshotQueryDelayProtocol.self),
      "query delay stub must register on URLSession.shared"
    )
    defer { URLProtocol.unregisterClass(SnapshotQueryDelayProtocol.self) }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CaptureWorkspaceStore(
      defaults: UserDefaults(suiteName: "howmuch.tests.capture.\(UUID().uuidString)")!,
      rootURL: directory
    )
    let original = SnapshotHarness.make(
      baseURLString: SnapshotQueryDelayProtocol.fixtureBaseURL,
      store: store
    )
    let scope = original.model.settings.viewPrefsScopeKey
    XCTAssertEqual(original.model.settings.baseURL?.host, SnapshotQueryDelayProtocol.fixtureHost)
    let session = original.admitPendingQueryClarification(
      includeCategory: false,
      account: "Card",
      merchant: "Starbucks"
    )
    XCTAssertEqual(session.pendingQuery?.spec.kind, .spending)
    XCTAssertEqual(session.pendingQuery?.spec.merchant, "Starbucks")
    XCTAssertEqual(session.pendingQuery?.spec.account, "Card")
    XCTAssertEqual(session.pendingQuery?.from, "2026-09-01")
    XCTAssertEqual(session.pendingQuery?.to, "2026-09-06")
    XCTAssertTrue(session.pendingQuery?.accountIDs.isEmpty == true)
    XCTAssertTrue(session.pendingQuery?.unresolvedCategory.isEmpty == true)
    original.workspace.persistCurrentIfNeeded()
    let persisted = store.load(scope: scope)
    XCTAssertEqual(persisted.count, 1, "legacy-valid pending query must persist through CaptureWorkspaceStore")
    XCTAssertEqual(persisted.first?.id, session.id)
    XCTAssertEqual(persisted.first?.pendingQuery?.spec.merchant, "Starbucks")
    XCTAssertEqual(persisted.first?.pendingQuery?.spec.kind, .spending)
    XCTAssertEqual(persisted.first?.pendingQuery?.from, "2026-09-01")
    XCTAssertEqual(persisted.first?.pendingQuery?.to, "2026-09-06")
    XCTAssertEqual(persisted.first?.pendingQuery?.unresolvedAccount.map(\.id), ["acct-everyday", "acct-travel"])

    let restoredHarness = SnapshotHarness.make(
      baseURLString: SnapshotQueryDelayProtocol.fixtureBaseURL,
      store: store
    )
    XCTAssertEqual(restoredHarness.model.settings.viewPrefsScopeKey, scope)
    XCTAssertEqual(restoredHarness.workspace.recents.map(\.id), [session.id])
    guard let restored = restoredHarness.workspace.resume(session.id) else {
      XCTFail("fresh workspace must resume the persisted pending query")
      return
    }
    XCTAssertEqual(restored.pendingQuery?.spec.merchant, "Starbucks")
    XCTAssertEqual(restored.pendingQuery?.from, "2026-09-01")
    XCTAssertEqual(restored.pendingQuery?.to, "2026-09-06")
    XCTAssertTrue(restored.queryCards.isEmpty)
    guard let surface = SnapshotSurface(
      root: AddTransactionsView(session: restored, workspace: restoredHarness.workspace)
        .environment(restoredHarness.model),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("restored merchant pending query needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }
    _ = await surface.captureUntilOCR(contains: ["Which account"])
    attachImage(surface.captureVisible(), name: "capture-restored-merchant-pending-query")
    guard let candidate = await revealControl(on: surface, label: "Everyday") else {
      XCTFail("stored account candidate missing after resume in \(surface.accessibilityLabels())")
      return
    }
    SnapshotQueryDelayProtocol.reset()
    XCTAssertTrue(surface.activate(candidate), "tapping Everyday must continue the restored pending query")
    let honest = await surface.waitUntil(timeoutNanoseconds: 1_500_000_000, {
      restored.lastFeedback?.localizedCaseInsensitiveContains("merchant") == true
    })
    XCTAssertTrue(
      honest,
      "restored spending+merchant clarification must be rejected honestly without a report; feedback \(restored.lastFeedback ?? "") cards \(restored.queryCards.count) started \(SnapshotQueryDelayProtocol.started)"
    )
    XCTAssertTrue(
      SnapshotQueryDelayProtocol.started.isEmpty,
      "restored merchant-qualified spending must not fetch report or sources; started \(SnapshotQueryDelayProtocol.started)"
    )
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    XCTAssertTrue(
      SnapshotQueryDelayProtocol.started.isEmpty,
      "late restored merchant-qualified spending must still not fetch; started \(SnapshotQueryDelayProtocol.started)"
    )
    XCTAssertTrue(restored.queryCards.isEmpty)
  }

  func testConversationOffersAIProviderSettingsAtDefaultAndAccessibility3() async {
    for (size, name, embedded) in [
      (DynamicTypeSize.large, "large", false), (.accessibility3, "accessibility3", false),
      (.large, "assistant-large", true), (.accessibility3, "assistant-accessibility3", true),
    ] {
      let harness = SnapshotHarness.make()
      let session = harness.admitEmpty()
      let view = AddTransactionsView(session: session, embeddedInAssistant: embedded, workspace: harness.workspace)
        .environment(harness.model)
        .environment(\.dynamicTypeSize, size)
      guard let surface = SnapshotSurface(
        root: embedded ? AnyView(NavigationStack { view }) : AnyView(view),
        size: CGSize(width: 390, height: 844)
      ) else {
        XCTFail("AI settings needs a connected UIWindowScene")
        continue
      }
      _ = await surface.captureUntilOCR(contains: [embedded ? "Conversation" : "Add Transactions"])
      let entry = surface.firstControl(label: "AI provider")
      XCTAssertNotNil(entry, "Conversation must offer AI provider settings at \(name)")
      if let entry {
        XCTAssertTrue(surface.activate(entry))
        let presented = await surface.waitUntil {
          surface.accessibilityLabels().contains("On device")
        }
        XCTAssertTrue(presented, "AI provider settings must be available without changing ledger connection")
        attachImage(surface.captureVisible(), name: "byok-settings-on-device-\(name)")
        if let cancel = surface.firstControl(label: "Cancel") {
          XCTAssertTrue(surface.activate(cancel))
          let closed = await surface.waitUntil { surface.firstControl(label: "Cancel") == nil }
          XCTAssertTrue(closed)
          await surface.settleNavigation()
        } else {
          XCTFail("AI settings must offer Cancel")
        }
      }
      XCTAssertTrue(session.drafts.isEmpty)
      XCTAssertTrue(harness.model.pendingRows.isEmpty)
      surface.detach()
    }
  }

  func testAIProviderSettingsAndModelsRenderAtDefaultAndAccessibility3() async throws {
    for (size, name) in [(DynamicTypeSize.large, "large"), (.accessibility3, "accessibility3")] {
      for provider in CaptureAICatalog.bundled.providers {
        let suite = "howmuch.byok.snapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CaptureAISettings(defaults: defaults, keys: CaptureAIMemoryKeys())
        try settings.save(CaptureAISelection(providerID: provider.id, modelID: provider.models[0].id))
        await assertRenderedContent(
          NavigationStack { CaptureAISettingsView(settings: settings) }.environment(\.dynamicTypeSize, size),
          expected: [provider.name, provider.models[0].name],
          name: "byok-settings-\(provider.id)-\(name)",
          forbidden: ["fixture-api-key"]
        )
      }
      let suite = "howmuch.byok.custom.\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      let settings = CaptureAISettings(defaults: defaults, keys: CaptureAIMemoryKeys())
      try settings.save(CaptureAISelection(providerID: "custom", modelID: "fixture-model",
        customBaseURL: "https://byok.invalid/v1"))
      await assertRenderedContent(
        NavigationStack { CaptureAISettingsView(settings: settings) }.environment(\.dynamicTypeSize, size),
        expected: ["Custom endpoint", "fixture-model"], name: "byok-settings-custom-\(name)"
      )
    }
  }

  func testAIModelSelectionSavesPreferencesWithoutExposingOrReplacingKey() async throws {
    let suite = "howmuch.byok.selection.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = CaptureAISettings(defaults: defaults, keys: CaptureAIMemoryKeys())
    let initial = CaptureAISelection(providerID: "opencode-go", modelID: "gpt-5.6-luna", allowsRemote: true)
    try settings.save(initial, keyChange: "private-fixture-value")
    guard let surface = SnapshotSurface(
      root: NavigationStack { CaptureAISettingsView(settings: settings) }, size: CGSize(width: 390, height: 844)
    ) else { XCTFail("AI model selection needs a window"); return }
    defer { surface.detach() }
    _ = await surface.captureUntilOCR(contains: ["GPT 5.6 Luna"])
    XCTAssertFalse(surface.accessibilityLabels().joined().contains("private-fixture-value"))
    guard let picker = surface.firstControl(labelContains: "Model") else {
      XCTFail("Model picker missing: \(surface.accessibilityLabels())"); return
    }
    XCTAssertTrue(surface.activate(picker))
    let choicesVisible = await surface.waitUntil {
      surface.firstControl(labelContains: "DeepSeek V4 Flash Vision Exp") != nil
    }
    XCTAssertTrue(choicesVisible)
    guard let choice = surface.firstControl(labelContains: "DeepSeek V4 Flash Vision Exp") else { return }
    XCTAssertTrue(surface.activate(choice))
    let returned = await surface.waitUntil {
      surface.firstControl(label: "Save AI settings") != nil
        && surface.accessibilityLabels().contains("deepseek-v4-flash-vision-exp")
    }
    XCTAssertTrue(returned, "Selected model must return to settings: \(surface.accessibilityLabels())")
    XCTAssertEqual(settings.selection, initial, "Picker edits remain staged until Save")
    guard let save = surface.firstControl(label: "Save AI settings") else { return }
    XCTAssertTrue(surface.activate(save))
    XCTAssertEqual(settings.selection.modelID, "deepseek-v4-flash-vision-exp")
    XCTAssertFalse(settings.selection.allowsRemote, "Changing models requires acknowledging its data policy")
    XCTAssertTrue(settings.hasKey(for: settings.selection), "Switching models must not overwrite the provider key")
  }

  func testAISlowAndTimeoutRecoveryRenderAtDefaultAndAccessibility3() async {
    for (size, name) in [(DynamicTypeSize.large, "large"), (.accessibility3, "accessibility3")] {
      let harness = SnapshotHarness.make()
      let session = harness.admitEmpty()
      session.composerText = "Lunch $12"
      _ = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-08")
      let token = session.beginTurn(provider: "OpenAI · GPT 5.6 Luna")
      session.aiActivity?.startedAt = Date().addingTimeInterval(-25)
      let view = AddTransactionsView(session: session, interpreter: CaptureInterpreter(backend: .fixed { _ in
        CaptureInterpretedTurn(intent: .unsupported, feedback: "Fixture", mutations: [], query: nil, applyToAllDrafts: false)
      }), workspace: harness.workspace).environment(harness.model).environment(\.dynamicTypeSize, size)
      await assertRenderedContent(view, expected: ["Waiting for response", "Taking longer"],
        name: "byok-slow-\(name)", required: ["Stop"])
      session.updateAIPhase(.fetching, generation: token.generation)
      await assertRenderedContent(view, expected: ["HowMuch server", "Fetching recorded transactions"],
        name: "byok-fetching-\(name)")
      session.timeOutTurn(generation: token.generation)
      guard let surface = SnapshotSurface(root: view, size: CGSize(width: 390, height: 844)) else {
        XCTFail("AI recovery needs a window"); continue
      }
      defer { surface.detach() }
      let failed = await surface.captureUntilOCR(contains: ["reply took too long", "Nothing was saved"])
      XCTAssertFalse(failed.isBlank)
      await surface.setMainScrollOffsetY(surface.mainScrollMaxOffset())
      await surface.settleVisible()
      for label in ["Retry", "Add manually"] {
        guard let control = surface.controls(labelContains: label).first(where: {
          $0.label == label && surface.timelineVisibleFrame().contains($0.frame)
        }) else {
          XCTFail("\(label) must be fully reachable above the composer at \(name)"); continue
        }
        surface.assertMinimumHitTarget(control)
        XCTAssertTrue(surface.isControlEnabled(control))
      }
      attachImage(surface.captureVisible(), name: "byok-timeout-\(name)")
      guard let manual = surface.controls(labelContains: "Add manually").first(where: {
        $0.label == "Add manually" && surface.timelineVisibleFrame().contains($0.frame)
      }) else { XCTFail("Recovery manual action missing"); continue }
      XCTAssertTrue(surface.activate(manual))
      let opened = await surface.waitUntil { surface.firstControl(label: "Cancel") != nil }
      XCTAssertTrue(opened, "Timeout recovery must open the real manual form")
      _ = await surface.captureUntilOCR(contains: ["Add Transaction"])
      attachImage(surface.captureVisible(), name: "byok-recovery-manual-\(name)")
      guard let cancel = surface.firstControl(label: "Cancel") else { XCTFail("Manual Cancel missing"); continue }
      XCTAssertTrue(surface.activate(cancel))
      let closed = await surface.waitUntil { surface.firstControl(label: "Cancel") == nil }
      XCTAssertTrue(closed)
      await surface.settleNavigation()
      XCTAssertEqual(session.messages.first(where: { $0.kind == .user })?.text, "Lunch $12")
      XCTAssertTrue(session.drafts.isEmpty)
      XCTAssertTrue(harness.model.pendingRows.isEmpty)
    }
  }

  private func revealControl(
    on surface: SnapshotSurface,
    label: String,
    requireTimelineVisible: Bool = false
  ) async -> SnapshotAXNode? {
    func usable(_ node: SnapshotAXNode) -> Bool {
      guard node.frame.width > 0, node.frame.height > 0 else {
        return false
      }
      if requireTimelineVisible {
        return surface.timelineVisibleFrame().contains(node.frame)
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
      let choicePayees = ["Coffee", "Lunch"]
      func frameShowsClarification(_ lines: [String]) -> Bool {
        let blob = lines.map { Self.normalizedOCR($0) }.joined(separator: " ")
        guard expected.allSatisfy({ blob.contains(Self.normalizedOCR($0)) }) else {
          return false
        }
        return choicePayees.allSatisfy { surface.hasVisibleMeaningfulChoice(payee: $0) }
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
      let missingChoices = choicePayees.filter { !surface.hasVisibleMeaningfulChoice(payee: $0) }
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
    if name == "Add manually" || name == "Save transaction" {
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
final class SnapshotHarness {
  let model: AppModel
  let workspace: CaptureWorkspace

  static func make(
    baseURLString: String = "http://127.0.0.1:1",
    store: CaptureWorkspaceStore? = nil,
    lastUsedAccountID: String? = nil
  ) -> SnapshotHarness {
    var settings = APISettings()
    settings.baseURLString = baseURLString
    settings.username = "fixture-owner"
    settings.sessionToken = "fixture-session-token"
    settings.authenticatedUserID = "fixture-user"
    settings.planID = "fixture-plan"

    if let lastUsedAccountID, let scope = settings.viewPrefsScopeKey {
      var preferences = ScopedViewPrefsStore.load()
      preferences.set(ViewPrefs(lastUsedAccountID: lastUsedAccountID), for: scope)
    }
    let model = AppModel(settings: settings, viewPrefs: ViewPrefs(), captureAI: CaptureAISettings(
      defaults: UserDefaults(suiteName: "howmuch.tests.ai.\(UUID().uuidString)")!, keys: CaptureAIMemoryKeys()
    ))
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
      store: store ?? CaptureWorkspaceStore(
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

  func admitPendingQueryClarification(
    includeCategory: Bool = true,
    account: String = "Account",
    merchant: String = ""
  ) -> CaptureSession {
    let session = admit()
    session.composerText = "What did I spend on the card?"
    let frozen = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-06")
    session.pendingQuery = LedgerQueryResolution(
      spec: LedgerQuerySpec(kind: .spending, category: "", account: account, merchant: merchant, from: "2026-09-01", to: "2026-09-06"),
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
    admitInterruptedImages(1)
  }

  func admitInterruptedImages(_ count: Int) -> CaptureSession {
    let session = admit()
    for index in 1...count {
      session.addAttachment(
        CaptureAttachment(
          filename: count == 1 ? "slip.jpg" : "slip-\(index).jpg",
          data: Self.validThumbnailJPEG(),
          recognizedText: "",
          errorMessage: "I could not read text from that image. It is still attached."
        )
      )
    }
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
struct SnapshotAXNode {
  let object: NSObject
  let label: String
  let traits: UIAccessibilityTraits
  let frame: CGRect
}

@MainActor
final class SnapshotSurface {
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

  func hasVisibleMeaningfulChoice(payee: String) -> Bool {
    controls(labelContains: payee).contains { node in
      let frame = node.frame
      guard frame.width > 0, frame.height > 0 else {
        return false
      }
      guard timelineVisibleFrame().contains(frame) else {
        return false
      }
      let label = node.label
      return label.localizedStandardContains(payee)
        && !label.localizedStandardContains("last instruction")
        && (label.contains("$") || label.rangeOfCharacter(from: .decimalDigits) != nil)
    }
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

  func settleNavigation(file: StaticString = #filePath, line: UInt = #line) async {
    // AX nodes can exist while UIKit is still presenting/pushing their screen.
    // Synthetic activation must wait until a real user could interact with it.
    func isTransitioning(_ controller: UIViewController) -> Bool {
      controller.transitionCoordinator != nil
        || controller.isBeingPresented
        || controller.isBeingDismissed
        || controller.children.contains(where: isTransitioning)
        || controller.presentedViewController.map(isTransitioning) == true
    }
    let settled = await waitUntil { !isTransitioning(host) }
    XCTAssertTrue(settled, "UIKit navigation must settle before activation", file: file, line: line)
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
