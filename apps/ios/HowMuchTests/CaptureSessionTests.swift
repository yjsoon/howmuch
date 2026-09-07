import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import HowMuch

@MainActor
final class CaptureSessionTests: XCTestCase {
  func testAddKeepsStableIdentityAndFillsSelectedAccount() {
    let session = Self.session(accountID: "acct-everyday")
    let coffee = Self.mapped(amount: 5_000, payee: "Coffee", accountID: "")
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .add,
        feedback: "Added coffee.",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "5", payee: "Coffee"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [coffee]
    )
    XCTAssertEqual(session.drafts.count, 1)
    XCTAssertEqual(session.drafts[0].draft.payeeName, "Coffee")
    XCTAssertEqual(session.drafts[0].draft.accountID, "acct-everyday")
    XCTAssertFalse(session.drafts[0].accountWasExplicit)
    let firstID = session.drafts[0].id

    let second = Self.mapped(amount: 8_000, payee: "Lunch", accountID: "")
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .add,
        feedback: "Added lunch.",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "8", payee: "Lunch"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [second]
    )
    XCTAssertEqual(session.drafts.count, 2)
    XCTAssertEqual(session.drafts[0].id, firstID)
    XCTAssertEqual(session.drafts[1].draft.payeeName, "Lunch")
  }

  func testExplicitAccountIsNotOverwrittenBySelectedAccount() {
    let session = Self.session(accountID: "acct-everyday")
    let travel = Self.mapped(amount: 12_000, payee: "Lunch", accountID: "acct-travel", parsedAccount: true)
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .add,
        feedback: "Added lunch on Travel.",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "12", payee: "Lunch", account: "Travel Card"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [travel]
    )
    XCTAssertEqual(session.drafts[0].draft.accountID, "acct-travel")
    XCTAssertTrue(session.drafts[0].accountWasExplicit)
  }

  func testUpdatePreservesUnrelatedFieldsAndManualEdits() {
    let session = Self.session(accountID: "acct-everyday")
    var draft = TransactionDraft()
    draft.payeeName = "Coffee"
    draft.amountMagnitudeMilli = 5_000
    draft.accountID = "acct-everyday"
    draft.categoryID = "cat-dining"
    draft.memo = "Keep me"
    session.replaceDrafts([CaptureDraftItem(draft: draft)])
    session.applyManualEdit({
      var edited = session.drafts[0].draft
      edited.memo = "Manual memo"
      return edited
    }(), id: session.drafts[0].id)

    var updated = session.drafts[0].draft
    updated.amountMagnitudeMilli = 21_000
    let mapped = SlipMappedDraft(
      draft: updated,
      parsedAmount: true,
      parsedDate: false,
      parsedAccount: false,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Updated the amount to $21.",
        mutations: [CaptureDraftMutation(targetDraftID: session.drafts[0].id, extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [mapped]
    )
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 21_000)
    XCTAssertEqual(session.drafts[0].draft.payeeName, "Coffee")
    XCTAssertEqual(session.drafts[0].draft.categoryID, "cat-dining")
    XCTAssertEqual(session.drafts[0].draft.memo, "Manual memo")
    XCTAssertTrue(session.drafts[0].hasManualEdits)
  }

  func testAmbiguousUpdateDoesNotGuessAmongSeveralDrafts() {
    let session = Self.session(accountID: "acct-everyday")
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    var changed = session.drafts[0].draft
    changed.amountMagnitudeMilli = 21_000
    let mapped = SlipMappedDraft(
      draft: changed,
      parsedAmount: true,
      parsedDate: false,
      parsedAccount: false,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Which transaction?",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [mapped]
    )
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 5_000)
    XCTAssertEqual(session.drafts[1].draft.amountMagnitudeMilli, 12_000)
    XCTAssertEqual(session.lastFeedback, "Which transaction should I change?")
  }

  func testApplyToAllUpdatesAccountsWithoutTouchingPayees() {
    let session = Self.session(accountID: "acct-everyday")
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    var visa = TransactionDraft()
    visa.accountID = "acct-travel"
    let mapped = SlipMappedDraft(
      draft: visa,
      parsedAmount: false,
      parsedDate: false,
      parsedAccount: true,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Using Travel Card for both.",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(account: "Travel Card"))],
        query: nil,
        applyToAllDrafts: true
      ),
      mapped: [mapped]
    )
    XCTAssertEqual(session.drafts.map(\.draft.accountID), ["acct-travel", "acct-travel"])
    XCTAssertEqual(session.drafts.map(\.draft.payeeName), ["Coffee", "Lunch"])
  }

  func testAmbiguousAccountBlocksSave() {
    let session = Self.session(accountID: "acct-everyday")
    var draft = Self.draft(payee: "Lunch", amount: 12_000)
    draft.accountID = ""
    var item = CaptureDraftItem(draft: draft)
    item.accountCandidates = [
      SlipCandidate(id: "acct-everyday", name: "Everyday"),
      SlipCandidate(id: "acct-travel", name: "Travel Card"),
    ]
    item.accountWasExplicit = true
    session.replaceDrafts([item])
    XCTAssertTrue(session.hasUnresolvedAmbiguity)
    XCTAssertFalse(session.canSaveIncluded)
  }

  func testUndoRestoresPreviousDraftsAndDoesNotSave() {
    let session = Self.session(accountID: "acct-everyday")
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .add,
        feedback: "Added coffee.",
        mutations: [],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [Self.mapped(amount: 5_000, payee: "Coffee", accountID: "")]
    )
    XCTAssertEqual(session.drafts.count, 1)
    session.undo()
    XCTAssertTrue(session.drafts.isEmpty)
    XCTAssertEqual(session.lastFeedback, "Undid last change.")
  }

  func testSendingAndQuestionsDoNotMarkSaveableUntilDraftsExist() {
    let session = Self.session(accountID: "acct-everyday")
    session.appendUserMessage("How much did I spend this month?")
    XCTAssertFalse(session.canSaveIncluded)
    XCTAssertTrue(session.saveableDrafts.isEmpty)
  }

  func testLateGenerationIsRejected() {
    let session = Self.session(accountID: "acct-everyday")
    let first = session.beginTurn()
    let second = session.beginTurn()
    XCTAssertFalse(session.finishTurn(generation: first.generation))
    XCTAssertTrue(session.finishTurn(generation: second.generation))
    session.cancelTurn()
    XCTAssertFalse(session.isBusy)
  }

  func testFailedTurnKeepsDraftsAndInput() {
    let session = Self.session(accountID: "acct-everyday")
    session.composerText = "Lunch $12"
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .add,
        feedback: "Added lunch.",
        mutations: [],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [Self.mapped(amount: 12_000, payee: "Lunch", accountID: "")]
    )
    session.recordFailedTurn("Apple Intelligence is not available. Your drafts are still here.")
    XCTAssertEqual(session.drafts.count, 1)
    XCTAssertEqual(session.composerText, "Lunch $12")
  }

  func testManualModeSwitchDoesNotDropDrafts() {
    let session = Self.session(accountID: "acct-everyday")
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .add,
        feedback: "Added coffee.",
        mutations: [],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [Self.mapped(amount: 5_000, payee: "Coffee", accountID: "")]
    )
    session.entryMode = .manual
    XCTAssertEqual(session.drafts.count, 1)
    XCTAssertEqual(session.drafts[0].draft.payeeName, "Coffee")
  }

  func testAmbiguousParsedAccountDoesNotInheritSelectedAccount() {
    let session = Self.session(accountID: "acct-everyday")
    var draft = TransactionDraft()
    draft.payeeName = "Lunch"
    draft.amountMagnitudeMilli = 12_000
    let mapped = SlipMappedDraft(
      draft: draft,
      parsedAmount: true,
      parsedDate: false,
      parsedAccount: true,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [
        SlipCandidate(id: "acct-everyday", name: "Everyday"),
        SlipCandidate(id: "acct-travel", name: "Travel"),
      ],
      categoryCandidates: []
    )
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .add,
        feedback: "Added lunch.",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "12", payee: "Lunch", account: "Account"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [mapped]
    )
    XCTAssertTrue(session.drafts[0].accountWasExplicit)
    XCTAssertTrue(session.drafts[0].draft.accountID.isEmpty)
    XCTAssertTrue(session.hasUnresolvedAmbiguity)
    XCTAssertFalse(session.canSaveIncluded)
  }

  func testUnknownCategoryClearsPreviousCategory() {
    let session = Self.session(accountID: "acct-everyday")
    var draft = Self.draft(payee: "Coffee", amount: 5_000)
    draft.categoryID = "cat-dining"
    session.replaceDrafts([CaptureDraftItem(draft: draft)])
    var mappedDraft = session.drafts[0].draft
    mappedDraft.categoryID = nil
    let mapped = SlipMappedDraft(
      draft: mappedDraft,
      parsedAmount: false,
      parsedDate: false,
      parsedAccount: false,
      parsedCategory: true,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: [],
      unrecognizedCategory: "Spaceship Fuel"
    )
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Updated category.",
        mutations: [CaptureDraftMutation(targetDraftID: session.drafts[0].id, extraction: .init(category: "Spaceship Fuel"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [mapped]
    )
    XCTAssertNil(session.drafts[0].draft.categoryID)
    XCTAssertTrue(session.drafts[0].categoryWasExplicit)
    XCTAssertFalse(session.canSaveIncluded)
  }

  func testSelectorUpdatesContextOnlyAndNotExistingDrafts() {
    let session = Self.session(accountID: "acct-everyday")
    session.apply(
      turn: CaptureInterpretedTurn(intent: .add, feedback: "Added lunch.", mutations: [], query: nil, applyToAllDrafts: false),
      mapped: [Self.mapped(amount: 12_000, payee: "Lunch", accountID: "")]
    )
    session.apply(
      turn: CaptureInterpretedTurn(intent: .add, feedback: "Added travel lunch.", mutations: [], query: nil, applyToAllDrafts: false),
      mapped: [Self.mapped(amount: 9_000, payee: "Airport", accountID: "acct-travel", parsedAccount: true)]
    )
    let accounts = [
      Account(id: "acct-everyday", name: "Everyday", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false),
      Account(id: "acct-travel", name: "Travel", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false),
    ]
    session.selectAccount("acct-travel", accounts: accounts)
    XCTAssertEqual(session.drafts[0].draft.accountID, "acct-everyday")
    XCTAssertEqual(session.drafts[1].draft.accountID, "acct-travel")
    XCTAssertEqual(session.selectedAccountID, "acct-travel")
    let context = CaptureInterpreterPrompt.context(
      text: "Add coffee $4",
      session: session,
      accounts: accounts
    )
    XCTAssertEqual(context.selectedAccountID, "acct-travel")
    XCTAssertEqual(context.selectedAccountName, "Travel")
  }

  func testApplyToAllAccountUpdatesSelectedContext() {
    let session = Self.session(accountID: "acct-everyday")
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    var visa = TransactionDraft()
    visa.accountID = "acct-travel"
    let mapped = SlipMappedDraft(
      draft: visa,
      parsedAmount: false,
      parsedDate: false,
      parsedAccount: true,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Using Travel for both.",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(account: "Travel"))],
        query: nil,
        applyToAllDrafts: true
      ),
      mapped: [mapped]
    )
    XCTAssertEqual(session.selectedAccountID, "acct-travel")
    let context = CaptureInterpreterPrompt.context(
      text: "Add tea $3",
      session: session,
      accounts: [
        Account(id: "acct-everyday", name: "Everyday", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false),
        Account(id: "acct-travel", name: "Travel", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false),
      ]
    )
    XCTAssertEqual(context.selectedAccountID, "acct-travel")
  }

  func testStaleRevisionDoesNotOverwriteNewerEdits() {
    let session = Self.session(accountID: "acct-everyday")
    session.apply(
      turn: CaptureInterpretedTurn(intent: .add, feedback: "Added coffee.", mutations: [], query: nil, applyToAllDrafts: false),
      mapped: [Self.mapped(amount: 5_000, payee: "Coffee", accountID: "")]
    )
    let stale = session.revision
    session.applyManualEdit({
      var edited = session.drafts[0].draft
      edited.memo = "Manual now"
      return edited
    }(), id: session.drafts[0].id)
    var changed = session.drafts[0].draft
    changed.amountMagnitudeMilli = 21_000
    let mapped = SlipMappedDraft(
      draft: changed,
      parsedAmount: true,
      parsedDate: false,
      parsedAccount: false,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Updated amount.",
        mutations: [CaptureDraftMutation(targetDraftID: session.drafts[0].id, extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [mapped],
      expectedRevision: stale
    )
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 5_000)
    XCTAssertEqual(session.drafts[0].draft.memo, "Manual now")
  }

  func testInvalidTargetIDsDoNotPositionalMatch() {
    let session = Self.session(accountID: "acct-everyday")
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    var changed = session.drafts[0].draft
    changed.amountMagnitudeMilli = 21_000
    let mapped = SlipMappedDraft(
      draft: changed,
      parsedAmount: true,
      parsedDate: false,
      parsedAccount: false,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Updated the first one.",
        mutations: [CaptureDraftMutation(targetDraftID: "missing-id", extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      changes: [CaptureMappedChange(targetDraftID: "missing-id", mapped: mapped)]
    )
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 5_000)
    XCTAssertEqual(session.drafts[1].draft.amountMagnitudeMilli, 12_000)
    XCTAssertEqual(session.lastFeedback, "Which transaction should I change?")
  }

  func testChoosingDraftAppliesPendingUpdate() {
    let session = Self.session(accountID: "acct-everyday")
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    var changed = session.drafts[1].draft
    changed.amountMagnitudeMilli = 21_000
    let mapped = SlipMappedDraft(
      draft: changed,
      parsedAmount: true,
      parsedDate: false,
      parsedAccount: false,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Which transaction?",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [mapped]
    )
    session.chooseTargetDraft(session.drafts[1].id)
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 5_000)
    XCTAssertEqual(session.drafts[1].draft.amountMagnitudeMilli, 21_000)
    XCTAssertTrue(session.pendingTargetDraftIDs.isEmpty)
  }

  func testExplicitOutflowCorrectionDoesNotStayInflow() {
    let session = Self.session(accountID: "acct-everyday")
    var draft = Self.draft(payee: "Refund", amount: 12_000)
    draft.direction = .inflow
    session.replaceDrafts([CaptureDraftItem(draft: draft)])
    var mappedDraft = session.drafts[0].draft
    mappedDraft.direction = .outflow
    let mapped = SlipMappedDraft(
      draft: mappedDraft,
      parsedAmount: false,
      parsedDate: false,
      parsedAccount: false,
      parsedCategory: false,
      parsedDirection: true,
      accountCandidates: [],
      categoryCandidates: []
    )
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Marked as outflow.",
        mutations: [CaptureDraftMutation(targetDraftID: session.drafts[0].id, extraction: .init(direction: "outflow"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [mapped]
    )
    XCTAssertEqual(session.drafts[0].draft.direction, .outflow)
  }

  func testSplitAmountChangeIsRejectedAndDraftKept() {
    let session = Self.session(accountID: "acct-everyday")
    var draft = Self.draft(payee: "Market", amount: 15_000)
    draft.subtransactions = [
      TransactionSubtransactionDraft(amountText: "5.00", categoryID: "cat-dining"),
      TransactionSubtransactionDraft(amountText: "10.00", categoryID: "cat-grocery"),
    ]
    session.replaceDrafts([CaptureDraftItem(draft: draft)])
    var mappedDraft = session.drafts[0].draft
    mappedDraft.amountMagnitudeMilli = 21_000
    let mapped = SlipMappedDraft(
      draft: mappedDraft,
      parsedAmount: true,
      parsedDate: false,
      parsedAccount: false,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
    let message = session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Updated the amount.",
        mutations: [CaptureDraftMutation(targetDraftID: session.drafts[0].id, extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [mapped]
    )
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 15_000)
    XCTAssertTrue(session.drafts[0].draft.isSplit)
    XCTAssertTrue(message.contains("split"))
  }

  func testMarkSavedKeepsHistoryAndBlocksResave() {
    let session = Self.session(accountID: "acct-everyday")
    session.apply(
      turn: CaptureInterpretedTurn(intent: .add, feedback: "Added coffee.", mutations: [], query: nil, applyToAllDrafts: false),
      mapped: [Self.mapped(amount: 5_000, payee: "Coffee", accountID: "")]
    )
    XCTAssertFalse(session.saveableDrafts.isEmpty)
    session.markCommittedIncluded()
    XCTAssertTrue(session.saveableDrafts.isEmpty)
    XCTAssertFalse(session.canSaveIncluded)
    XCTAssertEqual(session.messages.last?.text, "Added coffee.")
    XCTAssertTrue(session.drafts[0].committed)
  }

  func testUnknownAndFourPlusAccountMatchesStayUnresolved() {
    let accounts = (1...4).map {
      Account(id: "acct-\($0)", name: "Card \($0)", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)
    }
    let none = SlipReaderMapping.map(
      [.init(amount: "12", payee: "Lunch", account: "Spaceship")],
      accounts: accounts,
      categoryGroups: [],
      payees: [],
      calendar: .current,
      now: .now
    )
    XCTAssertTrue(none[0].parsedAccount)
    XCTAssertTrue(none[0].draft.accountID.isEmpty)
    XCTAssertEqual(none[0].unrecognizedAccount, "Spaceship")

    let many = SlipReaderMapping.map(
      [.init(amount: "12", payee: "Lunch", account: "Card")],
      accounts: accounts,
      categoryGroups: [],
      payees: [],
      calendar: .current,
      now: .now
    )
    XCTAssertTrue(many[0].parsedAccount)
    XCTAssertTrue(many[0].draft.accountID.isEmpty)
    XCTAssertEqual(many[0].accountCandidates.count, 4)
  }

  func testStaleGenerationDoesNotApplyAfterCancel() {
    let session = Self.session(accountID: "acct-everyday")
    let token = session.beginTurn()
    session.cancelTurn()
    session.apply(
      turn: CaptureInterpretedTurn(intent: .add, feedback: "Added coffee.", mutations: [], query: nil, applyToAllDrafts: false),
      mapped: [Self.mapped(amount: 5_000, payee: "Coffee", accountID: "")],
      expectedGeneration: token.generation
    )
    XCTAssertTrue(session.drafts.isEmpty)
  }

  func testResolvePendingQueryIsBlockedWhileBusy() {
    let session = Self.session(accountID: "acct-everyday")
    session.pendingQuery = LedgerQueryResolution(
      spec: LedgerQuerySpec(kind: .spending, category: "", account: "Account", merchant: "", from: "2025-05-01", to: "2025-05-04"),
      from: "2025-05-01",
      to: "2025-05-04",
      priorFrom: nil,
      priorTo: nil,
      accountIDs: [],
      categoryIDs: [],
      accountLabel: "All accounts",
      categoryLabel: "Recorded spending",
      unresolvedAccount: [SlipCandidate(id: "acct-everyday", name: "Everyday")],
      unresolvedCategory: [],
      categoryWasExplicit: false
    )
    _ = session.beginTurn()
    XCTAssertFalse(session.canSendComposer)
    XCTAssertFalse(session.canSaveIncluded)
  }

  func testMultiMutationDoesNotPartiallyApplyWhenALaterTargetIsMissing() {
    let session = Self.session(accountID: "acct-everyday")
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    var first = session.drafts[0].draft
    first.amountMagnitudeMilli = 21_000
    var second = session.drafts[1].draft
    second.amountMagnitudeMilli = 30_000
    session.apply(
      turn: CaptureInterpretedTurn(intent: .update, feedback: "Updated both.", mutations: [], query: nil, applyToAllDrafts: false),
      changes: [
        CaptureMappedChange(
          targetDraftID: session.drafts[0].id,
          mapped: SlipMappedDraft(draft: first, parsedAmount: true, parsedDate: false, parsedAccount: false, parsedCategory: false, parsedDirection: false, accountCandidates: [], categoryCandidates: [])
        ),
        CaptureMappedChange(
          targetDraftID: "missing-later",
          mapped: SlipMappedDraft(draft: second, parsedAmount: true, parsedDate: false, parsedAccount: false, parsedCategory: false, parsedDirection: false, accountCandidates: [], categoryCandidates: [])
        ),
      ]
    )
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 5_000)
    XCTAssertEqual(session.drafts[1].draft.amountMagnitudeMilli, 12_000)
    XCTAssertEqual(session.lastFeedback, "Which transaction should I change?")
    XCTAssertEqual(Set(session.pendingTargetDraftIDs), Set(session.drafts.map(\.id)))
  }

  func testSplitDirectionAndCategoryAreRejected() {
    let session = Self.session(accountID: "acct-everyday")
    var draft = Self.draft(payee: "Market", amount: 15_000)
    draft.categoryID = "cat-grocery"
    draft.subtransactions = [
      TransactionSubtransactionDraft(amountText: "5.00", categoryID: "cat-dining"),
      TransactionSubtransactionDraft(amountText: "10.00", categoryID: "cat-grocery"),
    ]
    session.replaceDrafts([CaptureDraftItem(draft: draft)])
    var mappedDraft = session.drafts[0].draft
    mappedDraft.direction = .inflow
    mappedDraft.categoryID = "cat-dining"
    let mapped = SlipMappedDraft(
      draft: mappedDraft,
      parsedAmount: false,
      parsedDate: false,
      parsedAccount: false,
      parsedCategory: true,
      parsedDirection: true,
      accountCandidates: [],
      categoryCandidates: []
    )
    let message = session.apply(
      turn: CaptureInterpretedTurn(intent: .update, feedback: "Updated.", mutations: [CaptureDraftMutation(targetDraftID: session.drafts[0].id, extraction: .init(category: "Dining Out", direction: "inflow"))], query: nil, applyToAllDrafts: false),
      mapped: [mapped]
    )
    XCTAssertEqual(session.drafts[0].draft.direction, .outflow)
    XCTAssertEqual(session.drafts[0].draft.categoryID, "cat-grocery")
    XCTAssertTrue(message.contains("split"))
  }

  func testRemovingLastAmbiguousTargetClearsPendingUpdateAndDoesNotApplyToFreshDraft() {
    let session = Self.session(accountID: "acct-everyday")
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    var changed = session.drafts[0].draft
    changed.amountMagnitudeMilli = 21_000
    session.apply(
      turn: CaptureInterpretedTurn(
        intent: .update,
        feedback: "Which transaction should I change?",
        mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "21"))],
        query: nil,
        applyToAllDrafts: false
      ),
      mapped: [SlipMappedDraft(
        draft: changed,
        parsedAmount: true,
        parsedDate: false,
        parsedAccount: false,
        parsedCategory: false,
        parsedDirection: false,
        accountCandidates: [],
        categoryCandidates: []
      )]
    )
    XCTAssertFalse(session.canSaveIncluded)
    XCTAssertNotNil(session.pendingUpdateTurn)
    XCTAssertEqual(session.pendingTargetDraftIDs.count, 2)

    let firstID = session.drafts[0].id
    let secondID = session.drafts[1].id
    session.removeDraft(firstID)
    XCTAssertEqual(session.pendingTargetDraftIDs, [secondID])
    XCTAssertNotNil(session.pendingUpdateTurn)
    XCTAssertFalse(session.canSaveIncluded)

    session.removeDraft(secondID)
    XCTAssertNil(session.pendingUpdateTurn)
    XCTAssertTrue(session.pendingUpdateChanges.isEmpty)
    XCTAssertTrue(session.pendingTargetDraftIDs.isEmpty)
    XCTAssertEqual(session.lastFeedback, "That change was cancelled because those drafts were removed.")

    session.upsertManualDraft(Self.draft(payee: "Tea", amount: 3_000))
    XCTAssertEqual(session.drafts.count, 1)
    XCTAssertEqual(session.drafts[0].draft.payeeName, "Tea")
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 3_000)
    XCTAssertTrue(session.canSaveIncluded)
    XCTAssertNil(session.pendingUpdateTurn)
  }

  func testPendingAmbiguitySurvivesSnapshotAndBlocksSave() {
    let session = Self.session(accountID: "acct-everyday")
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    var changed = session.drafts[0].draft
    changed.amountMagnitudeMilli = 21_000
    session.apply(
      turn: CaptureInterpretedTurn(intent: .update, feedback: "Which?", mutations: [CaptureDraftMutation(targetDraftID: nil, extraction: .init(amount: "21"))], query: nil, applyToAllDrafts: false),
      mapped: [SlipMappedDraft(draft: changed, parsedAmount: true, parsedDate: false, parsedAccount: false, parsedCategory: false, parsedDirection: false, accountCandidates: [], categoryCandidates: [])]
    )
    XCTAssertFalse(session.canSaveIncluded)
    let restored = CaptureSession.restore(session.snapshot(), attachments: [])
    XCTAssertEqual(restored.pendingTargetDraftIDs.count, 2)
    XCTAssertNotNil(restored.pendingUpdateTurn)
    XCTAssertFalse(restored.canSaveIncluded)
    restored.chooseTargetDraft(restored.drafts[1].id)
    XCTAssertEqual(restored.drafts[0].draft.amountMagnitudeMilli, 5_000)
    XCTAssertEqual(restored.drafts[1].draft.amountMagnitudeMilli, 21_000)
  }

  func testSaveUndoSaveDoesNotReactivateCommittedDrafts() {
    let session = Self.session(accountID: "acct-everyday")
    session.apply(
      turn: CaptureInterpretedTurn(intent: .add, feedback: "Added coffee.", mutations: [], query: nil, applyToAllDrafts: false),
      mapped: [Self.mapped(amount: 5_000, payee: "Coffee", accountID: "")]
    )
    session.markCommittedIncluded()
    XCTAssertTrue(session.drafts[0].committed)
    session.undo()
    XCTAssertTrue(session.drafts[0].committed)
    XCTAssertTrue(session.saveableDrafts.isEmpty)
    XCTAssertFalse(session.canSaveIncluded)
    session.markCommittedIncluded()
    XCTAssertTrue(session.drafts[0].committed)
    XCTAssertTrue(session.currentDrafts.isEmpty)
  }

  func testCommittedDraftsAreOutOfManualEditorAndInterpreter() {
    let session = Self.session(accountID: "acct-everyday")
    session.apply(
      turn: CaptureInterpretedTurn(intent: .add, feedback: "Added coffee.", mutations: [], query: nil, applyToAllDrafts: false),
      mapped: [Self.mapped(amount: 5_000, payee: "Coffee", accountID: "")]
    )
    session.markCommittedIncluded()
    var lunch = Self.draft(payee: "Lunch", amount: 12_000)
    lunch.amountMagnitudeMilli = 12_000
    session.applyManualEdit(lunch, id: session.drafts[0].id)
    XCTAssertEqual(session.drafts[0].draft.payeeName, "Coffee")
    let context = CaptureInterpreterPrompt.context(
      text: "Add tea $3",
      session: session,
      accounts: [Account(id: "acct-everyday", name: "Everyday", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)]
    )
    XCTAssertTrue(context.drafts.isEmpty)
  }

  func testDelayedManualCallbackUsesDraftImportIDNotNewlySelectedID() {
    let session = Self.session(accountID: "acct-everyday")
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    let coffeeID = session.drafts[0].id
    session.selectedManualDraftID = session.drafts[1].id
    var delayed = session.drafts[0].draft
    XCTAssertEqual(delayed.importID, coffeeID)
    delayed.amountMagnitudeMilli = 7_000
    session.applyManualEdit(delayed, id: delayed.importID ?? coffeeID)
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 7_000)
    XCTAssertEqual(session.drafts[0].draft.payeeName, "Coffee")
    XCTAssertEqual(session.drafts[1].draft.amountMagnitudeMilli, 12_000)
    XCTAssertEqual(session.drafts[1].draft.payeeName, "Lunch")
  }

  func testSelectingSecondDraftEditsOnlyThatDraft() {
    let session = Self.session(accountID: "acct-everyday")
    session.replaceDrafts([
      CaptureDraftItem(draft: Self.draft(payee: "Coffee", amount: 5_000)),
      CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000)),
    ])
    session.selectedManualDraftID = session.drafts[1].id
    var edited = session.drafts[1].draft
    edited.payeeName = "Dinner"
    edited.amountMagnitudeMilli = 18_000
    session.applyManualEdit(edited, id: session.drafts[1].id)
    XCTAssertEqual(session.drafts[0].draft.payeeName, "Coffee")
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 5_000)
    XCTAssertEqual(session.drafts[1].draft.payeeName, "Dinner")
    XCTAssertEqual(session.drafts[1].draft.amountMagnitudeMilli, 18_000)
  }

  func testManualSaveAndModeSwitchUseCommittedArithmetic() {
    var engine = AmountKeypadEngine()
    engine.setValue(5_000)
    engine.tapOperator(.add)
    engine.tapDigit(2)
    engine.tapDigit(0)
    engine.tapDigit(0)
    XCTAssertEqual(engine.display, 2_000)
    XCTAssertEqual(engine.committedValue, 7_000)
    let hook = CaptureFormCommitHook()
    hook.keypad = engine
    let session = Self.session(accountID: "acct-everyday")
    var draft = Self.draft(payee: "Coffee", amount: engine.display)
    session.replaceDrafts([CaptureDraftItem(draft: draft)])
    session.selectedManualDraftID = session.drafts[0].id
    XCTAssertTrue(hook.hasPendingArithmetic)
    draft.amountMagnitudeMilli = hook.commit()
    session.applyManualEdit(draft, id: session.drafts[0].id)
    session.entryMode = .describe
    XCTAssertEqual(session.drafts[0].draft.amountMagnitudeMilli, 7_000)
    XCTAssertFalse(hook.hasPendingArithmetic)
  }

  func testDiscardedAndResumedAwaySessionsRejectLateApply() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("howmuch-capture-\(UUID().uuidString)", isDirectory: true)
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.discard.\(UUID().uuidString)")!,
        rootURL: directory
      )
    )
    let discarded = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Account(id: "acct-everyday", name: "Everyday", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    discarded.appendUserMessage("Keep me")
    workspace.persistCurrentIfNeeded()
    let discardToken = discarded.beginTurn()
    workspace.discardCurrent()
    discarded.apply(
      turn: CaptureInterpretedTurn(intent: .add, feedback: "Added coffee.", mutations: [], query: nil, applyToAllDrafts: false),
      mapped: [Self.mapped(amount: 5_000, payee: "Coffee", accountID: "")],
      expectedGeneration: discardToken.generation
    )
    XCTAssertTrue(discarded.drafts.isEmpty)

    let first = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Account(id: "acct-everyday", name: "Everyday", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    first.appendUserMessage("First")
    workspace.persistCurrentIfNeeded()
    let second = workspace.admit(
      request: CaptureRequest(kind: .blank, connectionFingerprint: "a", origin: .lastUsedOpen),
      scopeKey: "scope-a",
      openAccounts: [Account(id: "acct-everyday", name: "Everyday", icon: nil, type: "checking", onBudget: true, closed: false, balance: 0, clearedBalance: 0, unclearedBalance: 0, lastReconciledDate: nil, deleted: false)],
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: nil
    )
    second.appendUserMessage("Second")
    workspace.persistCurrentIfNeeded()
    let resumeToken = second.beginTurn()
    _ = workspace.resume(first.id)
    second.apply(
      turn: CaptureInterpretedTurn(intent: .add, feedback: "Added lunch.", mutations: [], query: nil, applyToAllDrafts: false),
      mapped: [Self.mapped(amount: 12_000, payee: "Lunch", accountID: "")],
      expectedGeneration: resumeToken.generation
    )
    XCTAssertTrue(second.drafts.isEmpty)
    XCTAssertEqual(workspace.current?.id, first.id)
  }

  func testScopeChangeDuringImageLoadBlocksSendAndRejectsTurn() {
    let session = CaptureSession(scopeKey: "https://a|user-a|plan-x", origin: .lastUsedOpen, selectedAccountID: "acct-everyday")
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.midload.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      )
    )
    workspace.activate(scopeKey: "https://a|user-a|plan-x")
    workspace.current = session
    session.composerText = "Lunch $12"
    session.isTransferringImages = true
    XCTAssertFalse(session.canSendComposer)
    XCTAssertTrue(session.isIngesting)
    let token = session.beginTurn()
    let captured = CaptureTurnScope.capture(
      session: session,
      settingsScopeKey: "https://a|user-a|plan-x",
      workspace: workspace,
      planID: "plan-x"
    )
    workspace.activate(scopeKey: "https://b|user-b|plan-x")
    XCTAssertFalse(
      captured.isCurrent(
        session: session,
        settingsScopeKey: "https://b|user-b|plan-x",
        workspace: workspace,
        planID: "plan-x"
      )
    )
    XCTAssertFalse(session.canSendComposer)
    session.apply(
      turn: CaptureInterpretedTurn(intent: .add, feedback: "Added lunch.", mutations: [], query: nil, applyToAllDrafts: false),
      mapped: [Self.mapped(amount: 12_000, payee: "Lunch", accountID: "")],
      expectedGeneration: token.generation
    )
    XCTAssertTrue(session.drafts.isEmpty)
  }

  func testSendIsBlockedDuringPhotoLoadAndOCR() {
    let session = Self.session(accountID: "acct-everyday")
    session.composerText = "Lunch $12"
    XCTAssertTrue(session.canSendComposer)
    session.isTransferringImages = true
    XCTAssertFalse(session.canSendComposer)
    XCTAssertFalse(session.canSaveIncluded)
    session.isTransferringImages = false
    session.addAttachment(CaptureAttachment(filename: "slip.jpg", data: Data(), isReading: true))
    XCTAssertFalse(session.canSendComposer)
    XCTAssertTrue(session.isIngesting)
  }

  func testTurnScopeRejectsInitiallyMismatchedScopeAndCurrentIdentity() {
    let session = CaptureSession(
      scopeKey: "https://a|user-a|plan-x",
      origin: .lastUsedOpen,
      selectedAccountID: "acct-everyday"
    )
    let other = CaptureSession(
      scopeKey: "https://a|user-a|plan-x",
      origin: .lastUsedOpen,
      selectedAccountID: "acct-everyday"
    )
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.scope.mismatch.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      )
    )
    workspace.activate(scopeKey: "https://b|user-b|plan-x")
    workspace.current = other
    let capturedAfterMismatch = CaptureTurnScope.capture(
      session: session,
      settingsScopeKey: "https://b|user-b|plan-x",
      workspace: workspace,
      planID: "plan-x"
    )
    XCTAssertFalse(
      capturedAfterMismatch.isCurrent(
        session: session,
        settingsScopeKey: "https://b|user-b|plan-x",
        workspace: workspace,
        planID: "plan-x"
      )
    )

    workspace.activate(scopeKey: "https://a|user-a|plan-x")
    workspace.current = other
    let capturedWrongCurrent = CaptureTurnScope.capture(
      session: session,
      settingsScopeKey: "https://a|user-a|plan-x",
      workspace: workspace,
      planID: "plan-x"
    )
    XCTAssertFalse(
      capturedWrongCurrent.isCurrent(
        session: session,
        settingsScopeKey: "https://a|user-a|plan-x",
        workspace: workspace,
        planID: "plan-x"
      )
    )

    let empty = CaptureSession(scopeKey: "", origin: .lastUsedOpen, selectedAccountID: "acct-everyday")
    workspace.activate(scopeKey: "")
    workspace.current = empty
    let capturedEmpty = CaptureTurnScope.capture(
      session: empty,
      settingsScopeKey: "",
      workspace: workspace,
      planID: "plan-x"
    )
    XCTAssertFalse(
      capturedEmpty.isCurrent(
        session: empty,
        settingsScopeKey: "",
        workspace: workspace,
        planID: "plan-x"
      )
    )
    XCTAssertFalse(
      capturedEmpty.isCurrent(
        session: empty,
        settingsScopeKey: nil,
        workspace: workspace,
        planID: "plan-x"
      )
    )
  }

  func testTurnScopeAcceptsAlignedScopeAndCurrentIdentity() {
    let session = CaptureSession(
      scopeKey: "https://a|user-a|plan-x",
      origin: .lastUsedOpen,
      selectedAccountID: "acct-everyday"
    )
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.scope.valid.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      )
    )
    workspace.activate(scopeKey: "https://a|user-a|plan-x")
    workspace.current = session
    let captured = CaptureTurnScope.capture(
      session: session,
      settingsScopeKey: "https://a|user-a|plan-x",
      workspace: workspace,
      planID: "plan-x"
    )
    XCTAssertTrue(
      captured.isCurrent(
        session: session,
        settingsScopeKey: "https://a|user-a|plan-x",
        workspace: workspace,
        planID: "plan-x"
      )
    )
  }

  func testTurnScopeRejectsSamePlanEndpointOrUserSwitch() {
    let session = CaptureSession(scopeKey: "https://a|user-a|plan-x", origin: .lastUsedOpen, selectedAccountID: "acct-everyday")
    let token = session.beginTurn()
    let workspace = CaptureWorkspace(
      store: CaptureWorkspaceStore(
        defaults: UserDefaults(suiteName: "howmuch.tests.scope.\(UUID().uuidString)")!,
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      )
    )
    workspace.activate(scopeKey: "https://a|user-a|plan-x")
    workspace.current = session
    let captured = CaptureTurnScope.capture(
      session: session,
      settingsScopeKey: "https://a|user-a|plan-x",
      workspace: workspace,
      planID: "plan-x"
    )
    workspace.activate(scopeKey: "https://b|user-b|plan-x")
    XCTAssertFalse(
      captured.isCurrent(
        session: session,
        settingsScopeKey: "https://b|user-b|plan-x",
        workspace: workspace,
        planID: "plan-x"
      )
    )
    XCTAssertNotEqual(session.generation, token.generation)
  }

  func testPasteAdmissionKeepsTextOfferedWithAnImageAndRejectsOverlappingAttachments() {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
      completion(Data([0xFF, 0xD8, 0xFF, 0xD9]), nil)
      return nil
    }
    provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
      completion(Data("Lunch $12 of Groceries".utf8), nil)
      return nil
    }
    XCTAssertTrue(CapturePasteAdmission.offersImage(provider))
    XCTAssertTrue(CapturePasteAdmission.offersText(provider))

    let session = Self.session(accountID: "acct-everyday")
    session.replaceDrafts([CaptureDraftItem(draft: Self.draft(payee: "Lunch", amount: 12_000))])
    session.composerText = "Lunch $12"
    XCTAssertTrue(session.canSaveIncluded)
    XCTAssertTrue(session.canSendComposer)
    XCTAssertFalse(CapturePasteAdmission.shouldRejectNewAttachments(session))
    session.isTransferringImages = true
    XCTAssertTrue(CapturePasteAdmission.shouldRejectNewAttachments(session))
    XCTAssertFalse(session.canSaveIncluded)
    XCTAssertFalse(session.canSendComposer)
    session.isTransferringImages = false
    session.isSaving = true
    XCTAssertTrue(CapturePasteAdmission.shouldRejectNewAttachments(session))
    session.isSaving = false
    _ = session.beginTurn()
    XCTAssertTrue(CapturePasteAdmission.shouldRejectNewAttachments(session))
  }

  func testComposerTextMakesSessionUnfinished() {
    let session = Self.session(accountID: "acct-everyday")
    XCTAssertFalse(session.isUnfinished)
    session.composerText = "Lunch $12"
    XCTAssertTrue(session.isUnfinished)
    XCTAssertEqual(session.snapshot().composerText, "Lunch $12")
  }

  private static func session(accountID: String) -> CaptureSession {
    CaptureSession(scopeKey: "scope-a", origin: .lastUsedOpen, selectedAccountID: accountID)
  }

  private static func draft(payee: String, amount: Int) -> TransactionDraft {
    var draft = TransactionDraft()
    draft.payeeName = payee
    draft.amountMagnitudeMilli = amount
    draft.accountID = "acct-everyday"
    return draft
  }

  private static func mapped(
    amount: Int,
    payee: String,
    accountID: String,
    parsedAccount: Bool = false
  ) -> SlipMappedDraft {
    var draft = TransactionDraft()
    draft.payeeName = payee
    draft.amountMagnitudeMilli = amount
    draft.accountID = accountID
    return SlipMappedDraft(
      draft: draft,
      parsedAmount: true,
      parsedDate: false,
      parsedAccount: parsedAccount,
      parsedCategory: false,
      parsedDirection: false,
      accountCandidates: [],
      categoryCandidates: []
    )
  }
}
