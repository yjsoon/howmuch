import XCTest
@testable import HowMuch

@MainActor
final class CaptureInterpreterTests: XCTestCase {
  func testPromptIncludesSelectedAccountDraftsAndDate() {
    let session = CaptureSession(
      scopeKey: "scope-a",
      origin: .lastUsedOpen,
      selectedAccountID: "acct-everyday"
    )
    var draft = TransactionDraft()
    draft.importID = "draft-coffee"
    draft.payeeName = "Coffee"
    draft.amountMagnitudeMilli = 5_000
    draft.accountID = "acct-everyday"
    draft.categoryID = "cat-dining"
    session.replaceDrafts([CaptureDraftItem(draft: draft)])
    session.appendUserMessage("Coffee $5")

    let context = CaptureInterpreterPrompt.context(
      text: "Actually, $21, and yesterday",
      session: session,
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    let prefix = CaptureInterpreterPrompt.prefix(
      context: context,
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-closed", "Closed Card", closed: true),
      ],
      categoryGroups: [Self.everydayGroup]
    )

    XCTAssertTrue(prefix.contains("Today: 2025-05-04"))
    XCTAssertTrue(prefix.contains("Selected account: Everyday Account"))
    XCTAssertTrue(prefix.contains("id=draft-coffee"))
    XCTAssertTrue(prefix.contains("payee=Coffee"))
    XCTAssertTrue(prefix.contains("category=Dining Out"))
    XCTAssertFalse(prefix.contains("category=cat-dining"))
    XCTAssertTrue(prefix.contains("Prior instructions:\nCoffee $5"))
    XCTAssertTrue(prefix.contains("Prior answers:"))
    session.appendAssistantMessage("$5 recorded spending today")
    let withAnswer = CaptureInterpreterPrompt.context(
      text: "What about yesterday?",
      session: session,
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    XCTAssertTrue(withAnswer.priorAnswers.contains("$5 recorded spending today"))
    XCTAssertTrue(
      CaptureInterpreterPrompt.prefix(
        context: withAnswer,
        accounts: [Self.account("acct-everyday", "Everyday Account")],
        categoryGroups: [Self.everydayGroup]
      ).contains("Selected account and current drafts apply only to add and update")
    )
    XCTAssertTrue(CaptureInterpreterPrompt.instructions.contains("capture-only"))
    XCTAssertTrue(CaptureInterpreterPrompt.instructions.contains("not spending-query scope"))
    XCTAssertTrue(CaptureInterpreterPrompt.instructions.contains("leave spends empty"))
    XCTAssertTrue(CaptureInterpreterPrompt.instructions.contains("conversational British English"))
    XCTAssertTrue(CaptureInterpreterPrompt.instructions.contains("not saved yet"))
    XCTAssertTrue(CaptureInterpreterPrompt.instructions.contains("Never claim that anything was saved"))
    XCTAssertTrue(prefix.contains("Accounts: Everyday Account"))
    XCTAssertFalse(prefix.contains("Closed Card"))
    XCTAssertTrue(prefix.hasSuffix("Instruction:\n"))
  }

  func testFixedBackendDoesNotCommit() async {
    let before = OutboxStore.load()
    let session = CaptureSession(
      scopeKey: "scope-a",
      origin: .lastUsedOpen,
      selectedAccountID: "acct-everyday"
    )
    let interpreter = CaptureInterpreter(backend: .fixed { context in
      XCTAssertTrue(context.text.contains("Lunch"))
      return CaptureInterpretedTurn(
        intent: .add,
        feedback: "Added lunch.",
        mutations: [
          CaptureDraftMutation(
            targetDraftID: nil,
            extraction: .init(amount: "12", payee: "Lunch", account: "")
          ),
        ],
        query: nil,
        applyToAllDrafts: false
      )
    })
    let context = CaptureInterpreterPrompt.context(
      text: "Lunch $12",
      session: session,
      accounts: [Self.account("acct-everyday", "Everyday Account")]
    )
    let result = await interpreter.interpret(
      context: context,
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup],
      payees: []
    )
    guard case .success(let value) = result else {
      return XCTFail("expected success")
    }
    XCTAssertEqual(value.0.intent, .add)
    XCTAssertEqual(value.1.count, 1)
    XCTAssertEqual(value.1.first?.mapped.draft.payeeName, "Lunch")
    XCTAssertEqual(OutboxStore.load().map(\.id), before.map(\.id))
  }

  func testInterpretMapsRelativeDatesFromFrozenContext() async {
    let session = CaptureSession(
      scopeKey: "scope-a",
      origin: .lastUsedOpen,
      selectedAccountID: "acct-everyday"
    )
    let frozen = CaptureFrozenTurn(
      text: "Lunch $12",
      accountID: "acct-everyday",
      accountName: "Everyday",
      localDate: "2026-09-01",
      attachmentIDs: [],
      userMessageID: UUID(),
      replyMessageID: UUID()
    )
    let interpreter = CaptureInterpreter(backend: .fixed { _ in
      CaptureInterpretedTurn(
        intent: .add,
        feedback: "Added lunch.",
        mutations: [
          CaptureDraftMutation(
            targetDraftID: nil,
            extraction: .init(amount: "12", payee: "Lunch", date: "today")
          ),
        ],
        query: nil,
        applyToAllDrafts: false
      )
    })
    let context = CaptureInterpreterPrompt.context(
      text: "Lunch $12",
      session: session,
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      calendar: Self.calendar,
      now: Self.now,
      frozen: frozen
    )
    XCTAssertEqual(context.today, "2026-09-01")
    let later = Self.calendar.date(from: DateComponents(year: 2026, month: 9, day: 6))!
    let result = await interpreter.interpret(
      context: context,
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup],
      payees: [],
      calendar: Self.calendar,
      now: later
    )
    guard case .success(let value) = result else {
      return XCTFail("expected frozen-date mapping")
    }
    XCTAssertEqual(value.1.first?.mapped.parsedDate, true)
    XCTAssertEqual(
      Self.calendar.startOfDay(for: value.1.first?.mapped.draft.date ?? .distantPast),
      SlipReaderMapping.date(from: "2026-09-01", calendar: Self.calendar, now: later)
    )
  }

  func testBlankMutationKeepsLaterTargetIdentity() async {
    let interpreter = CaptureInterpreter(backend: .fixed { _ in
      CaptureInterpretedTurn(
        intent: .update,
        feedback: "Updated lunch.",
        mutations: [
          CaptureDraftMutation(targetDraftID: "draft-a", extraction: .init()),
          CaptureDraftMutation(targetDraftID: "draft-b", extraction: .init(amount: "21")),
        ],
        query: nil,
        applyToAllDrafts: false
      )
    })
    let result = await interpreter.interpret(
      context: CaptureTurnContext(
        text: "Make lunch $21",
        selectedAccountName: "Everyday",
        selectedAccountID: "acct-everyday",
        today: "2025-05-04",
        drafts: [],
        priorInstructions: [],
        priorAnswers: [],
        attachmentTranscripts: []
      ),
      accounts: [Self.account("acct-everyday", "Everyday Account")],
      categoryGroups: [Self.everydayGroup],
      payees: []
    )
    guard case .success(let value) = result else {
      return XCTFail("expected mapped change")
    }
    XCTAssertEqual(value.1.count, 1)
    XCTAssertEqual(value.1.first?.targetDraftID, "draft-b")
  }

  func testCommittedDraftsAreOmittedFromInterpreterContext() {
    let session = CaptureSession(
      scopeKey: "scope-a",
      origin: .lastUsedOpen,
      selectedAccountID: "acct-everyday"
    )
    var draft = TransactionDraft()
    draft.importID = "draft-coffee"
    draft.payeeName = "Coffee"
    draft.amountMagnitudeMilli = 5_000
    draft.accountID = "acct-everyday"
    session.replaceDrafts([CaptureDraftItem(draft: draft)])
    session.markCommittedIncluded()
    let context = CaptureInterpreterPrompt.context(
      text: "Add tea $3",
      session: session,
      accounts: [Self.account("acct-everyday", "Everyday Account")]
    )
    XCTAssertTrue(context.drafts.isEmpty)
  }

  func testPayeeOnlyRenameMapsWithoutInventingAmount() async {
    let interpreter = CaptureInterpreter(backend: .fixed { context in
      XCTAssertEqual(context.text, "Name POSB rebate")
      return CaptureInterpretedTurn(
        intent: .update,
        feedback: "Renamed the draft.",
        mutations: [
          CaptureDraftMutation(
            targetDraftID: "draft-posb",
            extraction: .init(payee: "POSB rebate")
          ),
        ],
        query: nil,
        applyToAllDrafts: false
      )
    })
    let result = await interpreter.interpret(
      context: CaptureTurnContext(
        text: "Name POSB rebate",
        selectedAccountName: "POSB Savings",
        selectedAccountID: "acct-posb",
        today: "2026-09-07",
        drafts: [
          CaptureDraftPromptRow(
            id: "draft-posb",
            payee: "POSB",
            amount: "+54.53",
            account: "POSB Savings",
            category: "Savings",
            date: "2026-09-07"
          ),
        ],
        priorInstructions: [],
        priorAnswers: [],
        attachmentTranscripts: []
      ),
      accounts: [Self.account("acct-posb", "POSB Savings")],
      categoryGroups: [Self.everydayGroup],
      payees: []
    )
    guard case .success(let value) = result else {
      return XCTFail("expected mapped payee-only update")
    }
    XCTAssertEqual(value.0.intent, .update)
    XCTAssertEqual(value.1.count, 1)
    XCTAssertEqual(value.1.first?.targetDraftID, "draft-posb")
    XCTAssertEqual(value.1.first?.mapped.draft.payeeName, "POSB rebate")
    XCTAssertFalse(value.1.first?.mapped.parsedAmount ?? true)
    XCTAssertEqual(value.1.first?.mapped.draft.amountMagnitudeMilli, 0)
  }

  func testSavedConversationCardStaysVisibleForRename() {
    let session = CaptureSession(
      scopeKey: "scope-a",
      origin: .lastUsedOpen,
      selectedAccountID: "acct-posb"
    )
    var draft = TransactionDraft()
    draft.importID = "draft-posb"
    draft.payeeName = "POSB"
    draft.amountMagnitudeMilli = 54_530
    draft.direction = .inflow
    draft.accountID = "acct-posb"
    session.replaceDrafts([CaptureDraftItem(draft: draft)])
    session.markCommittedIncluded()
    let context = CaptureInterpreterPrompt.context(
      text: "Name POSB rebate",
      session: session,
      accounts: [Self.account("acct-posb", "POSB Savings")]
    )
    XCTAssertEqual(context.drafts.count, 1)
    XCTAssertEqual(context.drafts.first?.id, "draft-posb")
    XCTAssertEqual(context.drafts.first?.payee, "POSB")
    let prefix = CaptureInterpreterPrompt.prefix(
      context: context,
      accounts: [Self.account("acct-posb", "POSB Savings")],
      categoryGroups: []
    )
    XCTAssertTrue(prefix.contains("id=draft-posb"))
    XCTAssertTrue(prefix.contains("payee=POSB"))
  }

  func testMapPayloadUnqualifiedTodayQueryStaysUnfilteredAndSpendless() {
    let turn = CaptureInterpreter.mapPayload(
      CaptureTurnPayload(
        kind: "query",
        feedback: "Today’s recorded spending.",
        applyToAllDrafts: false,
        spends: [],
        queryKind: "today",
        queryCategory: "",
        queryAccount: "",
        queryMerchant: "",
        queryFrom: "",
        queryTo: ""
      )
    )
    XCTAssertEqual(turn.intent, .query)
    XCTAssertEqual(turn.query?.kind, .today)
    XCTAssertEqual(turn.query?.account, "")
    XCTAssertEqual(turn.query?.category, "")
    XCTAssertEqual(turn.query?.merchant, "")
    XCTAssertTrue(turn.mutations.isEmpty)
    let resolved = LedgerQueryPlanner.resolve(
      spec: turn.query!,
      accounts: [
        Self.account("acct-everyday", "Everyday Account"),
        Self.account("acct-travel", "Travel Card"),
      ],
      categoryGroups: [Self.everydayGroup],
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let value) = resolved else {
      return XCTFail("expected unfiltered today")
    }
    XCTAssertEqual(value.from, "2025-05-04")
    XCTAssertEqual(value.to, "2025-05-04")
    XCTAssertTrue(value.accountIDs.isEmpty)
    XCTAssertTrue(value.categoryIDs.isEmpty)
    XCTAssertEqual(value.accountLabel, "All accounts")
  }

  func testMapPayloadSpendingQueryKeepsExplicitAccountFromQuestion() {
    let turn = CaptureInterpreter.mapPayload(
      CaptureTurnPayload(
        kind: "query",
        feedback: "Travel Card recorded spending today.",
        applyToAllDrafts: false,
        spends: [],
        queryKind: "spending",
        queryCategory: "",
        queryAccount: "Travel Card",
        queryMerchant: "",
        queryFrom: "2025-05-04",
        queryTo: "2025-05-04"
      )
    )
    XCTAssertEqual(turn.query?.kind, .spending)
    XCTAssertEqual(turn.query?.account, "Travel Card")
    XCTAssertEqual(turn.query?.from, "2025-05-04")
    XCTAssertEqual(turn.query?.to, "2025-05-04")
    XCTAssertTrue(turn.mutations.isEmpty)
  }

  func testQueryOtherKindBecomesSpending() {
    let turn = CaptureInterpreter.mapPayload(
      CaptureTurnPayload(
        kind: "query",
        feedback: "Yesterday’s recorded spending.",
        applyToAllDrafts: false,
        spends: [],
        queryKind: "other",
        queryCategory: "",
        queryAccount: "",
        queryMerchant: "",
        queryFrom: "2025-05-03",
        queryTo: "2025-05-03"
      )
    )
    XCTAssertEqual(turn.query?.kind, .spending)
    XCTAssertEqual(turn.query?.from, "2025-05-03")
  }

  func testUnsupportedPayloadRefusesDeletingSavedTransactions() {
    let turn = CaptureInterpreter.mapPayload(
      CaptureTurnPayload(
        kind: "unsupported",
        feedback: "I cannot delete saved transactions.",
        applyToAllDrafts: false,
        spends: [],
        queryKind: "",
        queryCategory: "",
        queryAccount: "",
        queryMerchant: "",
        queryFrom: "",
        queryTo: ""
      )
    )
    XCTAssertEqual(turn.intent, .unsupported)
    XCTAssertTrue(turn.mutations.isEmpty)
    XCTAssertTrue(turn.feedback.localizedCaseInsensitiveContains("cannot delete saved transactions"))
  }

  func testLiveFoundationModelsCoffeeAddUpdateAndTodayQuery() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["HOWMUCH_LIVE_MODEL_VERIFY"] == "1",
      "Set HOWMUCH_LIVE_MODEL_VERIFY=1 to run the on-device Foundation Models regression."
    )
    try skipUnlessLiveModelAvailable()
    continueAfterFailure = false
    executionTimeAllowance = 240

    let outboxBefore = OutboxStore.load()
    let accounts = Self.liveAccounts
    let categoryGroups = Self.liveCategoryGroups
    let payees = Self.livePayees
    let session = CaptureSession(
      scopeKey: "fixture-live-model",
      origin: .lastUsedOpen,
      selectedAccountID: "acct-everyday"
    )
    let interpreter = CaptureInterpreter(backend: .foundationModels)

    let addInput = "Coffee $5 on Everyday Account"
    let added = try await interpretLiveTurn(
      step: "add-coffee-5",
      text: addInput,
      session: session,
      interpreter: interpreter,
      accounts: accounts,
      categoryGroups: categoryGroups,
      payees: payees
    )
    XCTAssertEqual(added.turn.intent, .add, "raw intent for \(addInput)")
    XCTAssertEqual(
      MoneyCodec.milliunits(from: added.turn.mutations.first?.extraction.amount ?? "").map(abs),
      5_000,
      "raw extraction amount \(added.turn.mutations.first?.extraction.amount ?? "")"
    )
    XCTAssertEqual(added.changes.first?.mapped.draft.amountMagnitudeMilli, 5_000)
    XCTAssertTrue(added.changes.first?.mapped.parsedAmount ?? false)
    XCTAssertTrue(
      added.changes.first?.mapped.draft.accountID == "acct-everyday"
        || added.changes.first?.mapped.draft.accountID.isEmpty == true
    )

    session.apply(turn: added.turn, changes: added.changes)
    attachAppliedDrafts(step: "add-coffee-5-applied", session: session)
    XCTAssertEqual(session.drafts.count, 1)
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 5_000)
    XCTAssertEqual(session.drafts[0].draft.signedMilliunits, -5_000)
    XCTAssertEqual(session.drafts[0].draft.accountID, "acct-everyday")
    XCTAssertTrue(session.canSaveIncluded)
    XCTAssertFalse(session.drafts[0].committed)
    let draftID = session.drafts[0].id

    let updateInput = "Change the coffee amount to 7.00"
    let updated = try await interpretLiveTurn(
      step: "update-coffee-7",
      text: updateInput,
      session: session,
      interpreter: interpreter,
      accounts: accounts,
      categoryGroups: categoryGroups,
      payees: payees
    )
    XCTAssertEqual(updated.turn.intent, .update, "raw intent for \(updateInput)")
    XCTAssertEqual(
      MoneyCodec.milliunits(from: updated.turn.mutations.first?.extraction.amount ?? "").map(abs),
      7_000,
      "raw extraction amount \(updated.turn.mutations.first?.extraction.amount ?? "")"
    )
    XCTAssertEqual(updated.changes.first?.mapped.draft.amountMagnitudeMilli, 7_000)
    XCTAssertTrue(updated.changes.first?.mapped.parsedAmount ?? false)
    if let target = updated.changes.first?.targetDraftID ?? updated.turn.mutations.first?.targetDraftID {
      XCTAssertEqual(target, draftID)
    }

    session.apply(turn: updated.turn, changes: updated.changes)
    attachAppliedDrafts(step: "update-coffee-7-applied", session: session)
    XCTAssertEqual(session.drafts.count, 1)
    XCTAssertEqual(session.drafts[0].id, draftID)
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 7_000)
    XCTAssertEqual(session.drafts[0].draft.signedMilliunits, -7_000)
    XCTAssertEqual(session.drafts[0].draft.accountID, "acct-everyday")
    XCTAssertTrue(session.canSaveIncluded)
    XCTAssertFalse(session.drafts[0].committed)

    let renameInput = "Name it Starbucks"
    let renamed = try await interpretLiveTurn(
      step: "rename-starbucks",
      text: renameInput,
      session: session,
      interpreter: interpreter,
      accounts: accounts,
      categoryGroups: categoryGroups,
      payees: payees
    )
    XCTAssertEqual(renamed.turn.intent, .update, "raw intent for \(renameInput)")
    XCTAssertEqual(
      renamed.changes.first?.mapped.draft.payeeName,
      "Starbucks",
      "raw payee \(renamed.turn.mutations.first?.extraction.payee ?? "")"
    )
    XCTAssertFalse(renamed.changes.first?.mapped.parsedAmount ?? true)
    session.apply(turn: renamed.turn, changes: renamed.changes)
    attachAppliedDrafts(step: "rename-starbucks-applied", session: session)
    XCTAssertEqual(session.drafts[0].id, draftID)
    XCTAssertEqual(session.drafts[0].draft.payeeName, "Starbucks")
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 7_000)

    session.markCommittedIncluded()
    let savedRenameInput = "Name it Coffee rebate"
    let savedRename = try await interpretLiveTurn(
      step: "rename-saved-coffee-rebate",
      text: savedRenameInput,
      session: session,
      interpreter: interpreter,
      accounts: accounts,
      categoryGroups: categoryGroups,
      payees: payees
    )
    XCTAssertEqual(savedRename.turn.intent, .update, "raw intent for \(savedRenameInput)")
    XCTAssertEqual(
      savedRename.changes.first?.mapped.draft.payeeName,
      "Coffee rebate",
      "raw payee \(savedRename.turn.mutations.first?.extraction.payee ?? "")"
    )
    session.apply(turn: savedRename.turn, changes: savedRename.changes)
    attachAppliedDrafts(step: "rename-saved-coffee-rebate-applied", session: session)
    XCTAssertEqual(session.drafts[0].id, draftID)
    XCTAssertEqual(session.drafts[0].draft.payeeName, "Coffee rebate")
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 7_000)
    XCTAssertTrue(session.drafts[0].committed)

    let queryInput = "How much did I spend today?"
    let queried = try await interpretLiveTurn(
      step: "today-spending-query",
      text: queryInput,
      session: session,
      interpreter: interpreter,
      accounts: accounts,
      categoryGroups: categoryGroups,
      payees: payees
    )
    XCTAssertEqual(queried.turn.intent, .query, "raw intent for \(queryInput)")
    XCTAssertNotNil(queried.turn.query)
    let spec = try XCTUnwrap(queried.turn.query)
    XCTAssertTrue(
      spec.kind == .today || spec.kind == .spending,
      "today question must be .today or same-day .spending, got \(spec.kind.rawValue)"
    )
    XCTAssertEqual(spec.account.trimmingCharacters(in: .whitespacesAndNewlines), "")
    XCTAssertEqual(spec.category.trimmingCharacters(in: .whitespacesAndNewlines), "")
    XCTAssertEqual(spec.merchant.trimmingCharacters(in: .whitespacesAndNewlines), "")
    XCTAssertTrue(queried.turn.mutations.isEmpty, "query must not emit spends; raw \(queried.turn.mutations)")
    XCTAssertTrue(queried.changes.isEmpty, "query must not map draft mutations")
    if spec.kind == .spending {
      XCTAssertEqual(spec.from, "2025-05-04")
      XCTAssertEqual(spec.to, "2025-05-04")
    }
    let planned = LedgerQueryPlanner.resolve(
      spec: spec,
      accounts: accounts,
      categoryGroups: categoryGroups,
      calendar: Self.calendar,
      now: Self.now
    )
    guard case .success(let resolution) = planned else {
      return XCTFail("planner must resolve live today query: \(planned)")
    }
    attachJSON(
      LiveModelQueryPlanEvidence(
        kind: spec.kind.rawValue,
        queryAccount: spec.account,
        queryCategory: spec.category,
        queryMerchant: spec.merchant,
        queryFrom: spec.from,
        queryTo: spec.to,
        resolvedFrom: resolution.from,
        resolvedTo: resolution.to,
        resolvedAccountIDs: resolution.accountIDs,
        resolvedCategoryIDs: resolution.categoryIDs,
        resolvedAccountLabel: resolution.accountLabel,
        unresolvedAccount: resolution.unresolvedAccount.map(\.name)
      ),
      name: "live-model-today-spending-query-plan"
    )
    XCTAssertEqual(resolution.from, "2025-05-04")
    XCTAssertEqual(resolution.to, "2025-05-04")
    XCTAssertTrue(resolution.accountIDs.isEmpty, "unqualified today must not narrow to \(resolution.accountIDs)")
    XCTAssertTrue(resolution.categoryIDs.isEmpty)
    XCTAssertTrue(resolution.unresolvedAccount.isEmpty)
    XCTAssertEqual(resolution.accountLabel, "All accounts")

    let draftsBeforeQuery = session.drafts
    session.apply(turn: queried.turn, changes: queried.changes)
    attachAppliedDrafts(step: "today-spending-query-applied", session: session)
    XCTAssertEqual(session.drafts.map(\.id), draftsBeforeQuery.map(\.id))
    XCTAssertEqual(
      session.drafts.map(\.draft.amountMagnitudeMilli),
      draftsBeforeQuery.map(\.draft.amountMagnitudeMilli)
    )
    XCTAssertEqual(session.drafts.map(\.draft.accountID), draftsBeforeQuery.map(\.draft.accountID))
    XCTAssertEqual(session.drafts[0].id, draftID)
    XCTAssertEqual(session.drafts[0].draft.signedMilliunits, -7_000)
    XCTAssertEqual(OutboxStore.load().map(\.id), outboxBefore.map(\.id))
  }

  private func skipUnlessLiveModelAvailable() throws {
    #if canImport(FoundationModels)
    switch CaptureIntelligenceStatus.current {
    case .available:
      return
    case .downloading:
      throw XCTSkip("SystemLanguageModel is still downloading.")
    case .unavailable:
      throw XCTSkip("SystemLanguageModel is not available.")
    case .error(let message):
      throw XCTSkip("SystemLanguageModel is not available: \(message)")
    }
    #else
    throw XCTSkip("Foundation Models are not compiled in this target.")
    #endif
  }

  private func interpretLiveTurn(
    step: String,
    text: String,
    session: CaptureSession,
    interpreter: CaptureInterpreter,
    accounts: [Account],
    categoryGroups: [CategoryGroup],
    payees: [Payee]
  ) async throws -> (turn: CaptureInterpretedTurn, changes: [CaptureMappedChange]) {
    session.appendUserMessage(text)
    let context = CaptureInterpreterPrompt.context(
      text: text,
      session: session,
      accounts: accounts,
      categoryGroups: categoryGroups,
      calendar: Self.calendar,
      now: Self.now
    )
    let started = Date()
    let result = await interpreter.interpret(
      context: context,
      accounts: accounts,
      categoryGroups: categoryGroups,
      payees: payees,
      calendar: Self.calendar,
      now: Self.now
    )
    let duration = Date().timeIntervalSince(started)
    switch result {
    case .success(let value):
      attachLiveEvidence(
        step: step,
        input: text,
        duration: duration,
        turn: value.0,
        changes: value.1
      )
      return (value.0, value.1)
    case .failure(.unavailable):
      attachLiveEvidence(step: step, input: text, duration: duration, error: "unavailable")
      throw XCTSkip("SystemLanguageModel is not available.")
    case .failure(let error):
      attachLiveEvidence(step: step, input: text, duration: duration, error: error.localizedDescription)
      XCTFail("Foundation Models was available but \(step) failed: \(error.localizedDescription)")
      throw error
    }
  }

  private func attachLiveEvidence(
    step: String,
    input: String,
    duration: TimeInterval,
    error: String? = nil,
    turn: CaptureInterpretedTurn? = nil,
    changes: [CaptureMappedChange] = []
  ) {
    let evidence = LiveModelTurnEvidence(
      step: step,
      input: input,
      durationMS: Int((duration * 1000).rounded()),
      error: error,
      intent: turn?.intent.rawValue,
      feedback: turn?.feedback,
      applyToAllDrafts: turn?.applyToAllDrafts,
      queryKind: turn?.query?.kind.rawValue,
      queryAccount: turn?.query?.account,
      queryCategory: turn?.query?.category,
      queryMerchant: turn?.query?.merchant,
      queryFrom: turn?.query?.from,
      queryTo: turn?.query?.to,
      mutations: (turn?.mutations ?? []).map { mutation in
        LiveModelMutationEvidence(
          targetDraftID: mutation.targetDraftID,
          amount: mutation.extraction.amount,
          payee: mutation.extraction.payee,
          category: mutation.extraction.category,
          account: mutation.extraction.account,
          date: mutation.extraction.date,
          isInflow: mutation.extraction.isInflow,
          direction: mutation.extraction.direction
        )
      },
      mapped: changes.map { change in
        LiveModelMappedEvidence(
          targetDraftID: change.targetDraftID,
          parsedAmount: change.mapped.parsedAmount,
          amountMilliunits: change.mapped.draft.amountMagnitudeMilli,
          signedMilliunits: change.mapped.draft.signedMilliunits,
          payee: change.mapped.draft.payeeName,
          accountID: change.mapped.draft.accountID,
          categoryID: change.mapped.draft.categoryID
        )
      },
      catalog: LiveModelCatalogEvidence(
        accounts: Self.liveAccounts.map(\.name),
        categories: Self.liveCategoryGroups.flatMap { $0.categories.map(\.name) },
        payees: Self.livePayees.map(\.name)
      )
    )
    attachJSON(evidence, name: "live-model-\(step)")
  }

  private func attachAppliedDrafts(step: String, session: CaptureSession) {
    let evidence = session.drafts.map { item in
      LiveModelAppliedDraftEvidence(
        id: item.id,
        payee: item.draft.payeeName,
        amountMilliunits: item.draft.amountMagnitudeMilli,
        signedMilliunits: item.draft.signedMilliunits,
        accountID: item.draft.accountID,
        categoryID: item.draft.categoryID,
        committed: item.committed,
        canSave: item.draft.canSave
      )
    }
    attachJSON(evidence, name: "live-model-\(step)")
  }

  private func attachJSON<T: Encodable>(_ value: T, name: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = (try? encoder.encode(value)) ?? Data()
    let json = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    json.name = "\(name).json"
    json.lifetime = .keepAlways
    add(json)
    let text = XCTAttachment(string: String(data: data, encoding: .utf8) ?? "")
    text.name = "\(name).txt"
    text.lifetime = .keepAlways
    add(text)
  }

  private struct LiveModelTurnEvidence: Encodable {
    var step: String
    var input: String
    var durationMS: Int
    var error: String?
    var intent: String?
    var feedback: String?
    var applyToAllDrafts: Bool?
    var queryKind: String?
    var queryAccount: String?
    var queryCategory: String?
    var queryMerchant: String?
    var queryFrom: String?
    var queryTo: String?
    var mutations: [LiveModelMutationEvidence]
    var mapped: [LiveModelMappedEvidence]
    var catalog: LiveModelCatalogEvidence
  }

  private struct LiveModelMutationEvidence: Encodable {
    var targetDraftID: String?
    var amount: String
    var payee: String
    var category: String
    var account: String
    var date: String
    var isInflow: Bool
    var direction: String
  }

  private struct LiveModelMappedEvidence: Encodable {
    var targetDraftID: String?
    var parsedAmount: Bool
    var amountMilliunits: Int
    var signedMilliunits: Int
    var payee: String
    var accountID: String
    var categoryID: String?
  }

  private struct LiveModelAppliedDraftEvidence: Encodable {
    var id: String
    var payee: String
    var amountMilliunits: Int
    var signedMilliunits: Int
    var accountID: String
    var categoryID: String?
    var committed: Bool
    var canSave: Bool
  }

  private struct LiveModelCatalogEvidence: Encodable {
    var accounts: [String]
    var categories: [String]
    var payees: [String]
  }

  private struct LiveModelQueryPlanEvidence: Encodable {
    var kind: String
    var queryAccount: String
    var queryCategory: String
    var queryMerchant: String
    var queryFrom: String
    var queryTo: String
    var resolvedFrom: String
    var resolvedTo: String
    var resolvedAccountIDs: [String]
    var resolvedCategoryIDs: [String]
    var resolvedAccountLabel: String
    var unresolvedAccount: [String]
  }

  private static let now = Date(timeIntervalSince1970: 1_746_316_800)
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  private static let everydayGroup = CategoryGroup(
    id: "grp-spend",
    name: "Everyday",
    hidden: false,
    deleted: false,
    categories: [
      Category(id: "cat-groceries", categoryGroupID: "grp-spend", name: "Groceries", deleted: false),
      Category(id: "cat-dining", categoryGroupID: "grp-spend", name: "Dining Out", deleted: false),
    ]
  )

  private static let liveAccounts = [
    account("acct-everyday", "Everyday Account"),
    account("acct-travel", "Travel Card"),
    account("acct-savings", "Savings"),
  ]

  private static let liveCategoryGroups: [CategoryGroup] = [
    everydayGroup,
    CategoryGroup(
      id: "grp-more",
      name: "More",
      hidden: false,
      deleted: false,
      categories: [
        Category(id: "cat-transport", categoryGroupID: "grp-more", name: "Transportation", deleted: false),
        Category(id: "cat-entertainment", categoryGroupID: "grp-more", name: "Entertainment", deleted: false),
        Category(id: "cat-shopping", categoryGroupID: "grp-more", name: "Shopping", deleted: false),
        Category(id: "cat-healthcare", categoryGroupID: "grp-more", name: "Healthcare", deleted: false),
        Category(id: "cat-utilities", categoryGroupID: "grp-more", name: "Utilities", deleted: false),
        Category(id: "cat-rent", categoryGroupID: "grp-more", name: "Rent", deleted: false),
        Category(id: "cat-personal", categoryGroupID: "grp-more", name: "Personal Care", deleted: false),
        Category(id: "cat-other", categoryGroupID: "grp-more", name: "Other", deleted: false),
      ]
    ),
  ]

  private static let livePayees: [Payee] = [
    "Coffee Shop", "Lunch Shop", "FairPrice", "Grab", "Starbucks",
    "NTUC", "Cold Storage", "McDonald's", "Hawker", "Bus",
    "MRT", "Singtel", "SP Services", "Guardian", "Watsons",
    "Uniqlo", "Cinema", "Pharmacy",
  ].enumerated().map { index, name in
    Payee(id: "payee-\(index)", name: name, transferAccountId: nil, deleted: false)
  }

  private static func account(_ id: String, _ name: String, closed: Bool = false) -> Account {
    Account(
      id: id,
      name: name,
      icon: nil,
      type: "checking",
      onBudget: true,
      closed: closed,
      balance: 0,
      clearedBalance: 0,
      unclearedBalance: 0,
      lastReconciledDate: nil,
      deleted: false
    )
  }
}
