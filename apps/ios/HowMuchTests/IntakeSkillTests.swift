import XCTest
@testable import HowMuch

/// Expectations come from docs/plans/share-intake.md sections 4, 7.6, 8 and 9,
/// not from the rule engine's code. Failure modes these tests exist for (the
/// Share-to-Halation E2E flows cannot reach them cheaply):
/// - a less specific rule silently recategorising a row a more specific one owns;
/// - a disabled rule still applying, or shadowing the next enabled one;
/// - a payee token matching too broadly ("GRAB" hitting "GrabFood") or too
///   narrowly ("KOPITIAM" missing "KOPITIAM AMK SINGAPORE SG");
/// - a rule whose token cleans to nothing, or that names a deleted category or
///   a closed account, applying to every row or writing a dead ID;
/// - the owner's own edit not counting as an override, or an unrelated edit
///   counting as one, so a rule is never flagged (or flagged wrongly);
/// - a skill.json written by a newer build losing the rest of the file;
/// - Remember this? offering more than one rule, a rule the owner dismissed, or
///   one that already exists for the account in question;
/// - a rule turning a row that is already in the register into a Fix of a saved
///   transaction, or a flag rule being shadowed by a category rule;
/// - a skill file's unreadable rules being erased on the next save, or a file
///   that could not be read being overwritten.
@MainActor
final class IntakeSkillTests: XCTestCase {
  private let everyday = "acct-everyday"
  private let altitude = "acct-altitude"
  private let uob = "acct-uob"
  private let closedAccount = "acct-closed"
  private let eatingOut = "cat-eating-out"
  private let groceries = "cat-groceries"
  private let household = "cat-household"
  private let transport = "cat-transport"
  private let deletedCategory = "cat-deleted"

  private lazy var context = IntakeRuleContext(
    openAccountIDs: [everyday, altitude, uob],
    categoryIDs: [eatingOut, groceries, household, transport],
    accountNames: [everyday: "Everyday", altitude: "DBS Altitude", uob: "UOB One"],
    categoryNames: [eatingOut: "Eating Out", groceries: "Groceries", household: "Household", transport: "Transport"],
    transferPayees: [everyday: IntakeTransferPayee(id: "payee-to-everyday", name: "Transfer : Everyday")],
    onBudgetAccountIDs: [everyday, altitude]
  )

  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  // MARK: Precedence

  func testMoreSpecificRuleWinsAndLessSpecificOnesNeverFireUnderIt() {
    // Specificity: payee + account, then payee, then account (with a direction), then global (with a direction).
    let global = rule(scope: .global, when: .init(amountSign: .outflow), then: .setCategory(groceries))
    let accountOnly = rule(scope: .account(altitude), when: .init(amountSign: .outflow), then: .setCategory(household))
    let payeeOnly = rule(scope: .payee("kopitiam"), when: .init(payeeToken: "KOPITIAM"), then: .setCategory(eatingOut))
    let payeeAndAccount = rule(
      scope: .account(altitude),
      when: .init(payeeToken: "KOPITIAM", accountID: altitude),
      then: .setCategory(transport)
    )

    let all = [global, accountOnly, payeeOnly, payeeAndAccount]
    XCTAssertEqual(category(after: all, payee: "KOPITIAM AMK", account: altitude), transport)
    XCTAssertEqual(category(after: [global, accountOnly, payeeOnly], payee: "KOPITIAM AMK", account: altitude), eatingOut)
    XCTAssertEqual(category(after: [global, accountOnly], payee: "KOPITIAM AMK", account: altitude), household)
    XCTAssertEqual(category(after: [global], payee: "KOPITIAM AMK", account: altitude), groceries)
    // Listing order must not matter.
    XCTAssertEqual(category(after: all.reversed(), payee: "KOPITIAM AMK", account: altitude), transport)
    // The payee + account rule is for DBS Altitude only; the same payee elsewhere gets the payee rule.
    XCTAssertEqual(category(after: all, payee: "KOPITIAM AMK", account: everyday), eatingOut)
  }

  func testRenameAndCategoryRulesBothFireButEachFamilyTakesItsBestRule() {
    var read = line(payee: "KOPITIAM AMK", account: altitude)
    let rename = rule(scope: .payee("kopitiam"), when: .init(payeeToken: "kopitiam"), then: .renamePayee("Kopitiam"))
    let broaderCategory = rule(when: .init(payeeToken: "kopitiam"), then: .setCategory(groceries))
    let bestCategory = rule(
      scope: .account(altitude), when: .init(payeeToken: "kopitiam", accountID: altitude), then: .setCategory(eatingOut)
    )
    let outcomes = IntakeRuleEngine.apply([rename, broaderCategory, bestCategory], to: &read, context: context)
    XCTAssertEqual(Set(outcomes.map(\.application.ruleID)), [rename.id, bestCategory.id])
    XCTAssertEqual(read.draft.categoryID, eatingOut, "the more specific category rule wins within its family")
    XCTAssertEqual(read.draft.payeeName, "Kopitiam", "the rename is a different family, so it fires too")
  }

  func testFlagRuleFiresAlongsideACategoryRule() {
    var read = line(payee: "PAYNOW TAN AH KOW", account: altitude)
    let flag = rule(when: .init(payeeToken: "tan ah kow"), then: .flag)
    let categorise = rule(
      scope: .account(altitude), when: .init(payeeToken: "tan ah kow", accountID: altitude), then: .setCategory(household)
    )
    let outcomes = IntakeRuleEngine.apply([categorise, flag], to: &read, context: context)
    XCTAssertEqual(read.draft.categoryID, household)
    XCTAssertEqual(outcomes.filter(\.needsReview).count, 1, "a matching flag rule is always honoured")
    XCTAssertEqual(outcomes.count, 2)
  }

  func testTransferRuleSuppressesCategoryAndRenameRules() {
    var read = line(payee: "GRABPAY TOP-UP", account: altitude)
    let transfer = rule(when: .init(payeeToken: "grabpay"), then: .treatAsTransfer(everyday))
    let categorise = rule(
      scope: .account(altitude), when: .init(payeeToken: "grabpay", accountID: altitude), then: .setCategory(transport)
    )
    let rename = rule(when: .init(payeeToken: "grabpay"), then: .renamePayee("GrabPay"))
    let outcomes = IntakeRuleEngine.apply([categorise, rename, transfer], to: &read, context: context)
    XCTAssertEqual(outcomes.map(\.application.ruleID), [transfer.id])
    XCTAssertEqual(read.draft.transferAccountID, everyday)
    XCTAssertNil(read.draft.categoryID)
    XCTAssertEqual(read.draft.payeeName, "Transfer : Everyday")
  }

  func testAnUnperformableTransferDoesNotSuppressTheOthers() {
    var read = line(payee: "GRABPAY TOP-UP", account: everyday)
    let selfTransfer = rule(when: .init(payeeToken: "grabpay"), then: .treatAsTransfer(everyday))
    let categorise = rule(when: .init(payeeToken: "grabpay"), then: .setCategory(transport))
    let outcomes = IntakeRuleEngine.apply([selfTransfer, categorise], to: &read, context: context)
    XCTAssertEqual(outcomes.map(\.application.ruleID), [categorise.id])
  }

  func testCategoryRuleLeavesACategoryTheReaderSetAlone() {
    var read = line(payee: "KOPITIAM AMK", account: altitude)
    read.draft.categoryID = groceries
    read.parsedCategory = true
    let categorise = rule(when: .init(payeeToken: "kopitiam"), then: .setCategory(eatingOut))
    XCTAssertTrue(IntakeRuleEngine.apply([categorise], to: &read, context: context).isEmpty)
    XCTAssertEqual(read.draft.categoryID, groceries)
  }

  func testSkippingAFamilyLeavesThatFieldToTheOwner() {
    var read = line(payee: "KOPITIAM AMK", account: altitude)
    let rename = rule(when: .init(payeeToken: "kopitiam"), then: .renamePayee("Kopitiam"))
    let categorise = rule(when: .init(payeeToken: "kopitiam"), then: .setCategory(eatingOut))
    let outcomes = IntakeRuleEngine.apply([rename, categorise], to: &read, context: context, skipping: [.category])
    XCTAssertEqual(outcomes.map(\.application.ruleID), [rename.id])
    XCTAssertNil(read.draft.categoryID)
  }

  // MARK: Saved transactions

  func testCategoryRuleNeverTurnsAnAlreadyInRowIntoAFix() {
    // The row is already in the register under another category. The line as
    // read matches it exactly, so it is Already in; a rule must not make it a Fix.
    let read = line(payee: "Kopitiam", account: altitude, date: "2026-06-30")
    let existing = IntakeCandidateRow(
      id: "row-1", accountID: altitude, date: "2026-06-30", amountMilli: -8_900, payeeName: "Kopitiam",
      categoryID: groceries, approved: true
    )
    var proposals = IntakeMatcher().match([read], openAccountIDs: [everyday, altitude], candidates: [existing])
    XCTAssertEqual(proposals.first?.kind, .alreadyIn, "setup: the line as read is already in")
    let categorise = rule(when: .init(payeeToken: "kopitiam"), then: .setCategory(eatingOut))
    IntakeRuleEngine.applyLearned([categorise], to: &proposals, reads: [read], context: context)
    XCTAssertEqual(proposals[0].kind, .alreadyIn)
    XCTAssertEqual(proposals[0].changedFields, [])
    XCTAssertNil(proposals[0].draft.categoryID)
    XCTAssertEqual(proposals[0].draft, proposals[0].proposedDraft)
    XCTAssertTrue(proposals[0].ruleApplications.isEmpty)
    XCTAssertTrue(proposals[0].reasons.contains(IntakeRuleEngine.notAppliedReason))
  }

  func testRenameRuleDoesNotTurnAnAlreadyInRowIntoAFixOrAPossibleDuplicate() {
    let read = line(payee: "KOPITIAM AMK", account: altitude, date: "2026-06-30")
    let existing = IntakeCandidateRow(
      id: "row-1", accountID: altitude, date: "2026-06-30", amountMilli: -8_900, payeeName: "Kopitiam",
      categoryID: nil, approved: true
    )
    var proposals = IntakeMatcher().match([read], openAccountIDs: [everyday, altitude], candidates: [existing])
    XCTAssertEqual(proposals.first?.kind, .alreadyIn, "setup")
    let rename = rule(when: .init(payeeToken: "kopitiam"), then: .renamePayee("Kopitiam Eating House"))
    IntakeRuleEngine.applyLearned([rename], to: &proposals, reads: [read], context: context)
    XCTAssertEqual(proposals[0].kind, .alreadyIn)
    XCTAssertEqual(proposals[0].draft.payeeName, "KOPITIAM AMK")
    XCTAssertTrue(proposals[0].ruleApplications.isEmpty)
  }

  func testRulesApplyToNewRowsAndFlagsCapTheirConfidence() {
    let read = line(payee: "KOPITIAM AMK", account: altitude)
    var proposals = IntakeMatcher().match([read], openAccountIDs: [everyday, altitude], candidates: [])
    XCTAssertEqual(proposals.first?.kind, .add)
    let rename = rule(when: .init(payeeToken: "kopitiam"), then: .renamePayee("Kopitiam"))
    let flag = rule(when: .init(payeeToken: "kopitiam"), then: .flag)
    IntakeRuleEngine.applyLearned([rename, flag], to: &proposals, reads: [read], context: context)
    XCTAssertEqual(proposals[0].draft.payeeName, "Kopitiam")
    XCTAssertEqual(proposals[0].proposedDraft, proposals[0].draft)
    XCTAssertEqual(proposals[0].readPayee, "KOPITIAM AMK", "the reader's own payee is kept for learning")
    XCTAssertEqual(proposals[0].ruleApplications.count, 2)
    XCTAssertLessThanOrEqual(proposals[0].confidence, IntakeRuleEngine.flaggedConfidenceCap)
    XCTAssertFalse(proposals[0].appliesOnApproval, "a flagged row is not ticked")
    XCTAssertTrue(proposals[0].reasons.first?.hasPrefix(IntakeRuleEngine.reasonPrefix) == true)
  }

  func testEqualSpecificityGoesToTheNewestRule() {
    let older = rule(
      when: .init(payeeToken: "daiso"), then: .setCategory(groceries), createdAt: now.addingTimeInterval(-86_400)
    )
    let newer = rule(when: .init(payeeToken: "daiso"), then: .setCategory(household), createdAt: now)
    XCTAssertEqual(category(after: [older, newer], payee: "DAISO"), household)
    XCTAssertEqual(category(after: [newer, older], payee: "DAISO"), household)
  }

  // MARK: Enabled and valid

  func testDisabledRuleNeverAppliesAndTheNextEnabledRuleDoes() {
    let specificButOff = rule(
      when: .init(payeeToken: "kopitiam", accountID: altitude), then: .setCategory(transport), enabled: false
    )
    let broader = rule(when: .init(payeeToken: "kopitiam"), then: .setCategory(eatingOut))
    XCTAssertEqual(category(after: [specificButOff, broader], payee: "KOPITIAM", account: altitude), eatingOut)
    XCTAssertNil(category(after: [specificButOff], payee: "KOPITIAM", account: altitude))
  }

  func testRuleNamingADeletedCategoryIsSkippedAndTheNextOneApplies() {
    let stale = rule(when: .init(payeeToken: "kopitiam", accountID: altitude), then: .setCategory(deletedCategory))
    let good = rule(when: .init(payeeToken: "kopitiam"), then: .setCategory(eatingOut))
    XCTAssertEqual(category(after: [stale, good], payee: "KOPITIAM", account: altitude), eatingOut)
    XCTAssertNil(category(after: [stale], payee: "KOPITIAM", account: altitude))
  }

  func testRuleWithNoConditionsNeverMatches() {
    let everything = rule(scope: .global, when: .init(), then: .setCategory(groceries))
    XCTAssertNil(category(after: [everything], payee: "ANYTHING AT ALL"))
  }

  func testPayeeTokenThatCleansToNothingNeverMatches() {
    // "123" has no merchant word. It must not become "match every payee".
    let broken = rule(when: .init(payeeToken: "123"), then: .setCategory(groceries))
    XCTAssertNil(category(after: [broken], payee: "KOPITIAM"))
    XCTAssertNil(category(after: [broken], payee: "123"))
  }

  // MARK: Payee token matching

  func testGrabRuleDoesNotHitGrabFoodAndGrabFoodRuleDoesNotHitGrab() {
    let grab = rule(when: .init(payeeToken: "GRAB"), then: .setCategory(transport))
    let grabFood = rule(when: .init(payeeToken: "GRABFOOD"), then: .setCategory(eatingOut))
    XCTAssertEqual(category(after: [grab], payee: "Grab"), transport)
    XCTAssertEqual(category(after: [grab], payee: "GRAB*A-5X7K9 SINGAPORE SG"), transport)
    XCTAssertNil(category(after: [grab], payee: "GrabFood"))
    XCTAssertNil(category(after: [grab], payee: "GRABFOOD SINGAPORE"))
    XCTAssertEqual(category(after: [grabFood], payee: "GrabFood"), eatingOut)
    XCTAssertNil(category(after: [grabFood], payee: "Grab"))
    // Both present: each line gets its own.
    XCTAssertEqual(category(after: [grab, grabFood], payee: "GrabFood"), eatingOut)
    XCTAssertEqual(category(after: [grab, grabFood], payee: "Grab"), transport)
  }

  func testTokenMatchesWholeWordsOfNoisyBankDescriptors() {
    let kopitiam = rule(when: .init(payeeToken: "kopitiam"), then: .setCategory(eatingOut))
    for payee in ["Kopitiam", "KOPITIAM AMK SINGAPORE SG", "NETS KOPITIAM 1234", "kopitiam"] {
      XCTAssertEqual(category(after: [kopitiam], payee: payee), eatingOut, payee)
    }
    // A longer word that merely starts with the token is another merchant.
    XCTAssertNil(category(after: [kopitiam], payee: "KOPITIAMS GALORE"))
  }

  func testMultiWordTokenNeedsTheWordsTogetherAndInOrder() {
    let fingers = rule(when: .init(payeeToken: "Four Fingers"), then: .setCategory(eatingOut))
    XCTAssertEqual(category(after: [fingers], payee: "4FINGERS CRISPY CHICKEN"), eatingOut)
    XCTAssertEqual(category(after: [fingers], payee: "Four Fingers"), eatingOut)
    XCTAssertNil(category(after: [fingers], payee: "Four Seasons"))
    XCTAssertNil(category(after: [fingers], payee: "Fingers Four"))
  }

  func testSuggestedTokenIsTheMerchantWordNotTheBranch() {
    XCTAssertEqual(IntakeRuleCondition.suggestedToken(from: "KOPITIAM AMK"), "kopitiam")
    XCTAssertEqual(IntakeRuleCondition.suggestedToken(from: "GRAB*A-5X7K9 SINGAPORE SG"), "grab")
    XCTAssertEqual(IntakeRuleCondition.suggestedToken(from: "Four Fingers"), "four fingers")
    XCTAssertNil(IntakeRuleCondition.suggestedToken(from: "12345"))
    XCTAssertNil(IntakeRuleCondition.suggestedToken(from: ""))
  }

  // MARK: Scope and direction

  func testAccountScopeAndDirectionAreEnforced() {
    let altitudeOnly = rule(
      scope: .account(altitude), when: .init(payeeToken: "shopee"), then: .setCategory(household)
    )
    XCTAssertEqual(category(after: [altitudeOnly], payee: "SHOPEE", account: altitude), household)
    XCTAssertNil(category(after: [altitudeOnly], payee: "SHOPEE", account: uob))

    let refunds = rule(when: .init(payeeToken: "shopee", amountSign: .inflow), then: .setCategory(groceries))
    XCTAssertEqual(category(after: [refunds], payee: "SHOPEE", direction: .inflow), groceries)
    XCTAssertNil(category(after: [refunds], payee: "SHOPEE", direction: .outflow))
  }

  // MARK: Actions

  func testRenameChangesThePayeeAndDropsTheStalePayeeID() {
    var read = line(payee: "KOPITIAM AMK SINGAPORE SG", account: altitude)
    read.draft.payeeID = "payee-stale"
    let rename = rule(when: .init(payeeToken: "kopitiam"), then: .renamePayee("Kopitiam"))
    let outcomes = IntakeRuleEngine.apply([rename], to: &read, context: context)
    XCTAssertEqual(read.draft.payeeName, "Kopitiam")
    XCTAssertNil(read.draft.payeeID)
    XCTAssertEqual(outcomes.first?.application.effects, [.payee])
  }

  func testTransferRuleSetsTheTransferAndClearsTheCategoryBetweenOnBudgetAccounts() {
    var read = line(payee: "GRABPAY TOP-UP", account: altitude)
    read.draft.categoryID = groceries
    let transfer = rule(when: .init(payeeToken: "grabpay"), then: .treatAsTransfer(everyday))
    let outcomes = IntakeRuleEngine.apply([transfer], to: &read, context: context)
    XCTAssertEqual(read.draft.transferAccountID, everyday)
    XCTAssertEqual(read.draft.payeeID, "payee-to-everyday")
    XCTAssertEqual(read.draft.payeeName, "Transfer : Everyday")
    XCTAssertNil(read.draft.categoryID)
    XCTAssertEqual(outcomes.first?.application.effects, [.transfer])
  }

  func testTransferRuleKeepsTheCategoryWhenTheOtherAccountIsOffBudget() {
    var read = line(payee: "GRABPAY TOP-UP", account: altitude)
    read.draft.categoryID = groceries
    var offBudget = context
    offBudget.onBudgetAccountIDs = [altitude]
    let transfer = rule(when: .init(payeeToken: "grabpay"), then: .treatAsTransfer(everyday))
    _ = IntakeRuleEngine.apply([transfer], to: &read, context: offBudget)
    XCTAssertEqual(read.draft.transferAccountID, everyday)
    XCTAssertEqual(read.draft.categoryID, groceries)
  }

  func testTransferRuleNeverTargetsTheLinesOwnAccountAClosedAccountOrAMissingTransferPayee() {
    let toSelf = rule(when: .init(payeeToken: "grabpay"), then: .treatAsTransfer(everyday))
    var read = line(payee: "GRABPAY TOP-UP", account: everyday)
    XCTAssertTrue(IntakeRuleEngine.apply([toSelf], to: &read, context: context).isEmpty)
    XCTAssertNil(read.draft.transferAccountID)

    let toClosed = rule(when: .init(payeeToken: "grabpay"), then: .treatAsTransfer(closedAccount))
    read = line(payee: "GRABPAY TOP-UP", account: altitude)
    XCTAssertTrue(IntakeRuleEngine.apply([toClosed], to: &read, context: context).isEmpty)

    // Open, but no transfer payee exists for it (the register has not loaded it).
    let toUOB = rule(when: .init(payeeToken: "grabpay"), then: .treatAsTransfer(uob))
    XCTAssertTrue(IntakeRuleEngine.apply([toUOB], to: &read, context: context).isEmpty)
    XCTAssertNil(read.draft.transferAccountID)
  }

  func testFlagRuleChangesNothingButAsksForReview() {
    var read = line(payee: "PAYNOW TAN AH KOW", account: altitude)
    let before = read.draft
    let flag = rule(when: .init(payeeToken: "tan ah kow"), then: .flag)
    let outcomes = IntakeRuleEngine.apply([flag], to: &read, context: context)
    XCTAssertEqual(read.draft, before)
    XCTAssertEqual(outcomes.first?.needsReview, true)
    XCTAssertEqual(outcomes.first?.application.effects, [.review])
  }

  func testReasonNamesTheRuleAndHowManyCorrectionsItCameFrom() {
    var read = line(payee: "KOPITIAM AMK", account: altitude)
    var learned = rule(when: .init(payeeToken: "kopitiam"), then: .setCategory(eatingOut))
    learned.origin.corrections = 4
    var outcomes = IntakeRuleEngine.apply([learned], to: &read, context: context)
    XCTAssertEqual(outcomes.first?.reason, "Learned rule: KOPITIAM → Eating Out (from 4 corrections)")

    read = line(payee: "KOPITIAM AMK", account: altitude)
    learned.origin.corrections = 1
    outcomes = IntakeRuleEngine.apply([learned], to: &read, context: context)
    XCTAssertEqual(outcomes.first?.reason, "Learned rule: KOPITIAM → Eating Out (from 1 correction)")
  }

  // MARK: Overrides

  func testChangingAFieldARuleSetCountsAsAnOverrideAndOtherEditsDoNot() {
    var proposed = TransactionDraft()
    proposed.payeeName = "Kopitiam"
    proposed.categoryID = eatingOut
    let categoryRule = IntakeRuleApplication(ruleID: UUID(), effects: [.category])
    let renameRule = IntakeRuleApplication(ruleID: UUID(), effects: [.payee])

    XCTAssertFalse(IntakeRuleEngine.wasOverridden(categoryRule, proposed: proposed, final: proposed))

    var changedCategory = proposed
    changedCategory.categoryID = groceries
    XCTAssertTrue(IntakeRuleEngine.wasOverridden(categoryRule, proposed: proposed, final: changedCategory))
    XCTAssertFalse(IntakeRuleEngine.wasOverridden(renameRule, proposed: proposed, final: changedCategory))

    var clearedCategory = proposed
    clearedCategory.categoryID = nil
    XCTAssertTrue(IntakeRuleEngine.wasOverridden(categoryRule, proposed: proposed, final: clearedCategory))

    var changedPayee = proposed
    changedPayee.payeeName = "Kopi Tiam"
    XCTAssertTrue(IntakeRuleEngine.wasOverridden(renameRule, proposed: proposed, final: changedPayee))
    XCTAssertFalse(IntakeRuleEngine.wasOverridden(categoryRule, proposed: proposed, final: changedPayee))

    var changedAmount = proposed
    changedAmount.amountMagnitudeMilli = 9_990
    XCTAssertFalse(IntakeRuleEngine.wasOverridden(categoryRule, proposed: proposed, final: changedAmount))
    XCTAssertFalse(IntakeRuleEngine.wasOverridden(renameRule, proposed: proposed, final: changedAmount))
  }

  func testTransferOverrideIsTheOwnerUndoingTheTransfer() {
    var proposed = TransactionDraft()
    proposed.transferAccountID = everyday
    let application = IntakeRuleApplication(ruleID: UUID(), effects: [.transfer])
    XCTAssertFalse(IntakeRuleEngine.wasOverridden(application, proposed: proposed, final: proposed))
    var final = proposed
    final.transferAccountID = nil
    XCTAssertTrue(IntakeRuleEngine.wasOverridden(application, proposed: proposed, final: final))
  }

  func testRecordingCountsHitsOverridesAndFlagsARuleOverriddenTwice() {
    let learned = rule(when: .init(payeeToken: "shopee"), then: .setCategory(household))
    var skill = IntakeSkill()
    skill.rules = [learned]
    let other = UUID()

    skill.record(ruleID: learned.id, overridden: false, at: now)
    skill.record(ruleID: learned.id, overridden: true, at: now.addingTimeInterval(60))
    skill.record(ruleID: other, overridden: true, at: now)
    XCTAssertEqual(skill.rules[0].hits, 2)
    XCTAssertEqual(skill.rules[0].overrides, 1)
    XCTAssertEqual(skill.rules[0].lastUsed, now.addingTimeInterval(60))
    XCTAssertFalse(skill.rules[0].isOverriddenTwice)

    skill.record(ruleID: learned.id, overridden: true, at: now.addingTimeInterval(120))
    XCTAssertEqual(skill.rules[0].overrides, 2)
    XCTAssertTrue(skill.rules[0].isOverriddenTwice)
    XCTAssertTrue(skill.rules[0].enabled, "flagged for removal, never removed or switched off by itself")
  }

  // MARK: Duplicate window

  func testDayWindowUsesTheAccountOverrideThenTheGlobalValueWithinOneToSeven() {
    var skill = IntakeSkill()
    skill.accounts = [
      IntakeAccountSkill(id: altitude, notes: "", dedupeDayWindow: 5),
      IntakeAccountSkill(id: uob, notes: "", dedupeDayWindow: 40),
      IntakeAccountSkill(id: everyday, notes: "", dedupeDayWindow: 0),
    ]
    XCTAssertEqual(skill.dayWindow(forAccount: nil), 3)
    XCTAssertEqual(skill.dayWindow(forAccount: "acct-unknown"), 3)
    XCTAssertEqual(skill.dayWindow(forAccount: altitude), 5)
    XCTAssertEqual(skill.dayWindow(forAccount: uob), 7)
    XCTAssertEqual(skill.dayWindow(forAccount: everyday), 1)
    skill.dedupe.dayWindow = 9
    XCTAssertEqual(skill.dayWindow(forAccount: "acct-unknown"), 7)
  }

  func testMatcherUsesTheAccountsOwnWindowForItsLines() {
    var skill = IntakeSkill()
    skill.accounts = [IntakeAccountSkill(id: altitude, notes: "", dedupeDayWindow: 5)]
    let matcher = IntakeMatcher(skill: skill)
    XCTAssertEqual(matcher.widestWindow, 5)

    // Five days apart, same amount and payee.
    let existing = IntakeCandidateRow(
      id: "row-1", accountID: altitude, date: "2026-06-25", amountMilli: -8_900, payeeName: "Grab", categoryID: nil, approved: true
    )
    let inAltitude = matcher.match(
      [line(payee: "Grab", account: altitude, date: "2026-06-30")],
      openAccountIDs: [everyday, altitude],
      candidates: [existing]
    )
    XCTAssertEqual(inAltitude.first?.targetTransactionID, "row-1", "DBS Altitude allows 5 days")

    let sameRowOtherAccount = IntakeCandidateRow(
      id: "row-2", accountID: everyday, date: "2026-06-25", amountMilli: -8_900, payeeName: "Grab", categoryID: nil, approved: true
    )
    let inEveryday = matcher.match(
      [line(payee: "Grab", account: everyday, date: "2026-06-30")],
      openAccountIDs: [everyday, altitude],
      candidates: [sameRowOtherAccount]
    )
    XCTAssertEqual(inEveryday.first?.kind, .add, "Everyday keeps the global 3 days")
    XCTAssertNil(inEveryday.first?.targetTransactionID)
  }

  // MARK: Decoding

  func testSkillFileWithUnknownRuleActionScopeAndSignLoadsAndKeepsTheRest() throws {
    let kept = UUID()
    let json = """
    {
      "version": 7,
      "locale": { "currency": "SGD", "timezone": "Asia/Singapore", "dateOrder": "ydm" },
      "dedupe": { "dayWindow": 99, "somethingNew": true },
      "notes": "Food delivery is Eating Out.",
      "accounts": [
        { "id": "acct-uob", "notes": "CR lines are cashback.", "dedupeDayWindow": 5 },
        { "notes": "no id, so unusable" }
      ],
      "rules": [
        {
          "id": "\(UUID().uuidString)",
          "scope": { "kind": "global" },
          "when": { "payeeToken": "grab" },
          "then": { "kind": "preferReceiptTotal" },
          "origin": { "decidedAt": "2026-10-02T09:41:00Z" },
          "hits": 1, "overrides": 0, "enabled": true, "createdAt": "2026-10-02T09:41:00Z"
        },
        {
          "id": "\(UUID().uuidString)",
          "scope": { "kind": "device" },
          "when": { "payeeToken": "grab" },
          "then": { "kind": "flag" },
          "origin": { "decidedAt": "2026-10-02T09:41:00Z" },
          "createdAt": "2026-10-02T09:41:00Z"
        },
        {
          "id": "\(UUID().uuidString)",
          "scope": { "kind": "global" },
          "when": { "payeeToken": "grab", "amountSign": "sideways" },
          "then": { "kind": "flag" },
          "origin": { "decidedAt": "2026-10-02T09:41:00Z" },
          "createdAt": "2026-10-02T09:41:00Z"
        },
        {
          "id": "\(kept.uuidString)",
          "scope": { "kind": "payee", "value": "kopitiam" },
          "when": { "payeeToken": "KOPITIAM*" },
          "then": { "kind": "setCategory", "value": "cat-eating-out" },
          "origin": { "jobID": "\(UUID().uuidString)", "decidedAt": "2026-10-02T09:41:00Z", "corrections": 4 },
          "hits": 11, "overrides": 1, "lastUsed": "2026-10-05T10:00:00Z", "enabled": true,
          "createdAt": "2026-10-02T09:41:00Z"
        }
      ]
    }
    """
    let skill = try IntakeSkillStore.decoder().decode(IntakeSkill.self, from: Data(json.utf8))
    XCTAssertEqual(skill.rules.map(\.id), [kept], "rules this build cannot read are skipped, the rest kept")
    XCTAssertEqual(skill.rules[0].then, .setCategory("cat-eating-out"))
    XCTAssertEqual(skill.rules[0].when.payeeToken, "kopitiam", "a hand-edited token is cleaned on load")
    XCTAssertEqual(skill.rules[0].origin.corrections, 4)
    XCTAssertEqual(skill.rules[0].hits, 11)
    XCTAssertEqual(skill.locale.dateOrder, .dmy, "an unknown date order falls back to the default")
    XCTAssertEqual(skill.dedupe.dayWindow, 7, "out-of-range window is clamped")
    XCTAssertEqual(skill.notes, "Food delivery is Eating Out.")
    XCTAssertEqual(skill.accounts.map(\.id), ["acct-uob"])
    XCTAssertEqual(skill.accounts.first?.dedupeDayWindow, 5)
  }

  func testNotesLongerThanTheCapAreCutOnLoad() throws {
    let long = String(repeating: "a", count: IntakeSkill.notesLimit + 500)
    let data = try JSONSerialization.data(withJSONObject: ["notes": long])
    let skill = try IntakeSkillStore.decoder().decode(IntakeSkill.self, from: data)
    XCTAssertEqual(skill.notes.count, 4_000)
  }

  func testAnEmptyOrUnreadableFileGivesTheDefaultSkill() throws {
    let skill = try IntakeSkillStore.decoder().decode(IntakeSkill.self, from: Data("{}".utf8))
    XCTAssertEqual(skill, IntakeSkill())
    XCTAssertEqual(skill.locale.currency, "SGD")
    XCTAssertEqual(skill.locale.dateOrder, .dmy)
    XCTAssertEqual(skill.dedupe.dayWindow, 3)
  }

  // MARK: Store

  func testStoreRoundTripsAtomicallyAndRefusesToOverwriteAFileItCannotRead() throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("HowMuchTests-skill-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }

    let store = IntakeSkillStore(container: container)
    XCTAssertEqual(store.skill, IntakeSkill())
    XCTAssertFalse(store.isReadOnly, "a missing file is a fresh start, not a failure")
    let added = rule(when: .init(payeeToken: "kopitiam"), then: .setCategory(eatingOut))
    XCTAssertTrue(store.update { $0.notes = "Hello"; $0.add(added) })

    let url = container.appendingPathComponent("Intake/skill.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    let reloaded = IntakeSkillStore(container: container)
    XCTAssertEqual(reloaded.skill.notes, "Hello")
    XCTAssertEqual(reloaded.skill.rules.map(\.id), [added.id])

    try Data("not json".utf8).write(to: url)
    let broken = IntakeSkillStore(container: container)
    XCTAssertEqual(broken.skill, IntakeSkill())
    XCTAssertTrue(broken.isReadOnly)
    XCTAssertFalse(broken.update { $0.notes = "Overwrite" }, "must not replace a file it could not read")
    XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8))
    XCTAssertEqual(broken.skill, IntakeSkill())
  }

  func testRulesThisBuildCannotReadSurviveASave() throws {
    let kept = UUID()
    let json = """
    { "rules": [
      { "id": "\(UUID().uuidString)", "scope": { "kind": "global" }, "when": { "payeeToken": "grab" },
        "then": { "kind": "preferReceiptTotal" }, "createdAt": "2026-10-02T09:41:00Z" },
      { "id": "\(kept.uuidString)", "scope": { "kind": "global" }, "when": { "payeeToken": "kopitiam" },
        "then": { "kind": "flag" }, "createdAt": "2026-10-02T09:41:00Z" } ],
      "accounts": [ { "notes": "no id" } ] }
    """
    var skill = try IntakeSkillStore.decoder().decode(IntakeSkill.self, from: Data(json.utf8))
    XCTAssertEqual(skill.rules.map(\.id), [kept])
    XCTAssertEqual(skill.unreadRules.count, 1)
    XCTAssertEqual(skill.unreadAccounts.count, 1)
    skill.notes = "Changed"

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(skill)
    let again = try IntakeSkillStore.decoder().decode(IntakeSkill.self, from: data)
    XCTAssertEqual(again.unreadRules, skill.unreadRules)
    XCTAssertEqual(again.unreadAccounts, skill.unreadAccounts)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rules = try XCTUnwrap(object["rules"] as? [[String: Any]])
    XCTAssertEqual(rules.count, 2)
    XCTAssertTrue(rules.contains { ($0["then"] as? [String: Any])?["kind"] as? String == "preferReceiptTotal" })
  }

  func testAnUnreadableEnabledAccountOrPayeeValueNeverBroadensOrReEnablesARule() throws {
    func decode(_ body: String) throws -> IntakeSkill {
      let json = """
      { "rules": [ { "id": "\(UUID().uuidString)", "scope": { "kind": "global" },
        \(body), "then": { "kind": "flag" }, "createdAt": "2026-10-02T09:41:00Z" } ] }
      """
      return try IntakeSkillStore.decoder().decode(IntakeSkill.self, from: Data(json.utf8))
    }
    for body in [
      #""when": { "payeeToken": "grab", "accountID": 7 }"#,
      #""when": { "payeeToken": 7 }"#,
      #""when": { "payeeToken": "grab" }, "enabled": "no""#,
    ] {
      let skill = try decode(body)
      XCTAssertTrue(skill.rules.isEmpty, body)
      XCTAssertEqual(skill.unreadRules.count, 1, body)
    }
  }

  func testAccountWindowIsClampedWhenTheFileIsRead() throws {
    let json = #"{ "accounts": [ { "id": "a", "dedupeDayWindow": 40 }, { "id": "b", "dedupeDayWindow": -3 } ] }"#
    let skill = try IntakeSkillStore.decoder().decode(IntakeSkill.self, from: Data(json.utf8))
    XCTAssertEqual(skill.account("a")?.dedupeDayWindow, 7)
    XCTAssertEqual(skill.account("b")?.dedupeDayWindow, 1)
  }

  func testClearAllMemoryRemovesRulesAndSuppressionsButKeepsTheOwnersInstructions() {
    var skill = IntakeSkill()
    skill.notes = "Keep me"
    skill.accounts = [IntakeAccountSkill(id: altitude, notes: "Keep me too", dedupeDayWindow: nil)]
    skill.rules = [rule(when: .init(payeeToken: "kopitiam"), then: .setCategory(eatingOut))]
    skill.suppress("category|kopitiam|cat-eating-out", at: now)
    skill.markOffered(UUID())
    skill.clearMemory()
    XCTAssertTrue(skill.offeredJobIDs.isEmpty)
    XCTAssertTrue(skill.rules.isEmpty)
    XCTAssertTrue(skill.suppressed.isEmpty)
    XCTAssertEqual(skill.notes, "Keep me")
    XCTAssertEqual(skill.accounts.count, 1)
  }

  func testAddingARuleReplacesTheSameMatchAndActionKindButNotOtherKinds() {
    let first = rule(scope: .payee("shopee"), when: .init(payeeToken: "shopee"), then: .setCategory(household))
    let rename = rule(scope: .payee("shopee"), when: .init(payeeToken: "shopee"), then: .renamePayee("Shopee"))
    let second = rule(scope: .payee("shopee"), when: .init(payeeToken: "shopee"), then: .setCategory(groceries))
    var skill = IntakeSkill()
    skill.add(first)
    skill.add(rename)
    skill.add(second)
    XCTAssertEqual(Set(skill.rules.map(\.id)), [rename.id, second.id])
  }

  func testGlobalWithAPayeeIsTheSameRuleAsAPayeeScope() {
    let payee = rule(scope: .payee("shopee"), when: .init(payeeToken: "shopee"), then: .setCategory(household))
    let global = rule(scope: .global, when: .init(payeeToken: "shopee"), then: .setCategory(groceries))
    var skill = IntakeSkill()
    skill.add(payee)
    skill.add(global)
    XCTAssertEqual(skill.rules.map(\.id), [global.id])
  }

  func testAnAllAccountsRuleReplacesOlderAccountRulesForTheSameTokenAndFamilyButNotTheOtherWayRound() {
    let uobRule = rule(scope: .account(uob), when: .init(payeeToken: "shopee", accountID: uob), then: .setCategory(household))
    let allAccounts = rule(scope: .payee("shopee"), when: .init(payeeToken: "shopee"), then: .setCategory(groceries))
    let otherFamily = rule(scope: .account(uob), when: .init(payeeToken: "shopee", accountID: uob), then: .renamePayee("Shopee"))
    var skill = IntakeSkill()
    skill.add(uobRule)
    skill.add(otherFamily)
    skill.add(allAccounts)
    XCTAssertEqual(Set(skill.rules.map(\.id)), [allAccounts.id, otherFamily.id], "the newer owner choice wins")

    let altitudeRule = rule(
      scope: .account(altitude), when: .init(payeeToken: "shopee", accountID: altitude), then: .setCategory(transport)
    )
    skill.add(altitudeRule)
    XCTAssertEqual(Set(skill.rules.map(\.id)), [allAccounts.id, otherFamily.id, altitudeRule.id])
  }

  func testSuppressionLastsThirtyDaysAndIsForgottenAfterwards() {
    var skill = IntakeSkill()
    skill.suppress("category|kopitiam|cat-eating-out", at: now)
    XCTAssertTrue(skill.isSuppressed("category|kopitiam|cat-eating-out", at: now.addingTimeInterval(29 * 86_400)))
    XCTAssertFalse(skill.isSuppressed("category|kopitiam|cat-eating-out", at: now.addingTimeInterval(31 * 86_400)))
    XCTAssertFalse(skill.isSuppressed("category|kopitiam|cat-groceries", at: now), "only that exact suggestion")
  }

  // MARK: Summary

  func testSummaryIsTheCharacterCountOnly() {
    var skill = IntakeSkill()
    XCTAssertEqual(skill.summary, "No instructions yet")
    skill.notes = String(repeating: "a", count: 1_912)
    XCTAssertEqual(skill.summary, "1.9k characters")
    skill.notes = "Short"
    XCTAssertEqual(skill.summary, "5 characters")
  }

  // MARK: Reading guidance

  func testPromptGuidanceCombinesGlobalAndAccountNotesWithinTheCap() {
    var skill = IntakeSkill()
    XCTAssertNil(skill.promptGuidance(accountID: altitude))
    skill.notes = "  Food delivery is Eating Out.  "
    skill.accounts = [IntakeAccountSkill(id: altitude, notes: "PAYMENT - THANK YOU is a transfer.", dedupeDayWindow: nil)]
    let guidance = skill.promptGuidance(accountID: altitude)
    XCTAssertTrue(guidance?.contains("Food delivery is Eating Out.") == true)
    XCTAssertTrue(guidance?.contains("PAYMENT - THANK YOU is a transfer.") == true)
    XCTAssertFalse(skill.promptGuidance(accountID: uob)?.contains("PAYMENT") == true)

    skill.notes = String(repeating: "x", count: IntakeSkill.notesLimit)
    XCTAssertLessThanOrEqual(skill.promptGuidance(accountID: nil)?.count ?? 0, IntakeSkill.promptGuidanceLimit)
  }

  // MARK: Remember this?

  func testOffersAtMostOneRuleAndPrefersTheCategoryCorrectionSeenMostOften() throws {
    let jobID = UUID()
    let kopi1 = applied(payee: "KOPITIAM AMK", proposedCategory: nil, category: eatingOut)
    let kopi2 = applied(payee: "KOPITIAM BEDOK", proposedCategory: groceries, category: eatingOut)
    let rename = applied(payee: "SHOPEE SG", proposedCategory: nil, category: nil, finalPayee: "Shopee")
    let suggestion = try XCTUnwrap(
      IntakeRuleSuggester.suggest(applied: [rename, kopi1, kopi2], jobID: jobID, skill: IntakeSkill(), now: now)
    )
    XCTAssertEqual(suggestion.rule(scope: .payee).when.payeeToken, "kopitiam")
    XCTAssertEqual(suggestion.rule(scope: .payee).then, .setCategory(eatingOut))
    XCTAssertEqual(suggestion.corrections, 2)
    XCTAssertEqual(suggestion.rule(scope: .payee).origin.jobID, jobID)
    XCTAssertEqual(suggestion.rule(scope: .payee).origin.corrections, 2)
  }

  // Failure mode: offering a category rule the engine never applies to a category the reader took from the document.
  func testNoCategoryRuleIsOfferedForARowWhoseCategoryTheReaderSet() {
    let kopi = applied(payee: "KOPITIAM AMK", proposedCategory: groceries, category: eatingOut)
    XCTAssertNil(
      IntakeRuleSuggester.suggest(
        applied: [kopi], jobID: UUID(), skill: IntakeSkill(), now: now, readerCategoryRows: [kopi.id]
      )
    )
  }

  func testCategoryCorrectionOutranksARenameWhenCountsTie() throws {
    let rename = applied(payee: "SHOPEE SG", proposedCategory: nil, category: nil, finalPayee: "Shopee")
    let kopi = applied(payee: "KOPITIAM AMK", proposedCategory: nil, category: eatingOut)
    let suggestion = try XCTUnwrap(
      IntakeRuleSuggester.suggest(applied: [rename, kopi], jobID: UUID(), skill: IntakeSkill(), now: now)
    )
    XCTAssertEqual(suggestion.rule(scope: .payee).then, .setCategory(eatingOut))
  }

  func testRenameIsOfferedWhenItIsTheOnlyCorrection() throws {
    let rename = applied(payee: "SHOPEE SG", proposedCategory: nil, category: nil, finalPayee: "Shopee")
    let suggestion = try XCTUnwrap(
      IntakeRuleSuggester.suggest(applied: [rename], jobID: UUID(), skill: IntakeSkill(), now: now)
    )
    XCTAssertEqual(suggestion.rule(scope: .payee).when.payeeToken, "shopee")
    XCTAssertEqual(suggestion.rule(scope: .payee).then, .renamePayee("Shopee"))
  }

  func testNothingIsOfferedWithoutAPayeeOrCategoryCorrection() {
    // Approved as read; an amount edit; a row the owner never applied; a transfer.
    let untouched = applied(payee: "KOPITIAM AMK", proposedCategory: eatingOut, category: eatingOut)
    var amountEdit = applied(payee: "KOPITIAM AMK", proposedCategory: eatingOut, category: eatingOut)
    amountEdit.draft.amountMagnitudeMilli += 100
    var unapplied = applied(payee: "KOPITIAM AMK", proposedCategory: nil, category: eatingOut)
    unapplied.isApplied = false
    var rejected = applied(payee: "KOPITIAM AMK", proposedCategory: nil, category: eatingOut)
    rejected.decision = .rejected
    var transfer = applied(payee: "KOPITIAM AMK", proposedCategory: nil, category: eatingOut)
    transfer.draft.transferAccountID = everyday
    XCTAssertNil(
      IntakeRuleSuggester.suggest(
        applied: [untouched, amountEdit, unapplied, rejected, transfer], jobID: UUID(), skill: IntakeSkill(), now: now
      )
    )
  }

  func testNothingIsOfferedForADismissedOrAlreadyKnownRule() throws {
    let kopi = applied(payee: "KOPITIAM AMK", proposedCategory: nil, category: eatingOut)
    var skill = IntakeSkill()
    let first = try XCTUnwrap(IntakeRuleSuggester.suggest(applied: [kopi], jobID: UUID(), skill: skill, now: now))

    skill.suppress(first.key, at: now)
    XCTAssertNil(IntakeRuleSuggester.suggest(applied: [kopi], jobID: UUID(), skill: skill, now: now.addingTimeInterval(86_400)))
    XCTAssertNotNil(
      IntakeRuleSuggester.suggest(applied: [kopi], jobID: UUID(), skill: skill, now: now.addingTimeInterval(31 * 86_400))
    )

    var known = IntakeSkill()
    known.add(first.rule(scope: .payee))
    XCTAssertNil(IntakeRuleSuggester.suggest(applied: [kopi], jobID: UUID(), skill: known, now: now))
    // Switched off by the owner still counts as known: do not nag.
    known.rules[0].enabled = false
    XCTAssertNil(IntakeRuleSuggester.suggest(applied: [kopi], jobID: UUID(), skill: known, now: now))
  }

  func testNothingIsOfferedTwiceForOneBatch() throws {
    let kopi = applied(payee: "KOPITIAM AMK", proposedCategory: nil, category: eatingOut)
    let jobID = UUID()
    var skill = IntakeSkill()
    XCTAssertNotNil(IntakeRuleSuggester.suggest(applied: [kopi], jobID: jobID, skill: skill, now: now))
    skill.markOffered(jobID)
    XCTAssertNil(IntakeRuleSuggester.suggest(applied: [kopi], jobID: jobID, skill: skill, now: now))
    XCTAssertNotNil(IntakeRuleSuggester.suggest(applied: [kopi], jobID: UUID(), skill: skill, now: now))
  }

  func testAnExistingRuleOnlyBlocksTheSuggestionItCovers() throws {
    let kopiAtDBS = applied(payee: "KOPITIAM AMK", proposedCategory: nil, category: eatingOut, account: altitude)
    var skill = IntakeSkill()
    skill.add(
      rule(scope: .account(uob), when: .init(payeeToken: "kopitiam", accountID: uob), then: .setCategory(eatingOut))
    )
    XCTAssertNotNil(
      IntakeRuleSuggester.suggest(applied: [kopiAtDBS], jobID: UUID(), skill: skill, now: now),
      "a UOB rule does not block offering one for DBS"
    )
    var allAccounts = IntakeSkill()
    allAccounts.add(rule(scope: .payee("kopitiam"), when: .init(payeeToken: "kopitiam"), then: .setCategory(eatingOut)))
    XCTAssertNil(IntakeRuleSuggester.suggest(applied: [kopiAtDBS], jobID: UUID(), skill: allAccounts, now: now))
    var dbsOnly = IntakeSkill()
    dbsOnly.add(
      rule(scope: .account(altitude), when: .init(payeeToken: "kopitiam", accountID: altitude), then: .setCategory(eatingOut))
    )
    XCTAssertNil(IntakeRuleSuggester.suggest(applied: [kopiAtDBS], jobID: UUID(), skill: dbsOnly, now: now))
  }

  func testTheTokenComesFromTheReadersOwnPayeeNotTheRenamedOne() throws {
    var row = applied(payee: "Kopitiam", proposedCategory: nil, category: eatingOut)
    row.readPayee = "KOPITIAM AMK SINGAPORE SG"
    let suggestion = try XCTUnwrap(
      IntakeRuleSuggester.suggest(applied: [row], jobID: UUID(), skill: IntakeSkill(), now: now)
    )
    XCTAssertEqual(suggestion.rule(scope: .payee).when.payeeToken, "kopitiam")

    var renamedAway = applied(payee: "Coffee", proposedCategory: nil, category: nil, finalPayee: "Coffee corner")
    renamedAway.readPayee = "STARBUCKS COFFEE SG"
    let rename = try XCTUnwrap(
      IntakeRuleSuggester.suggest(applied: [renamedAway], jobID: UUID(), skill: IntakeSkill(), now: now)
    )
    XCTAssertEqual(rename.rule(scope: .payee).when.payeeToken, "starbucks")
  }

  func testDefaultScopeIsTheAccountForASingleAccountBatchAndThePayeeOtherwise() throws {
    let one = applied(payee: "KOPITIAM AMK", proposedCategory: nil, category: eatingOut, account: altitude)
    let single = try XCTUnwrap(IntakeRuleSuggester.suggest(applied: [one], jobID: UUID(), skill: IntakeSkill(), now: now))
    XCTAssertEqual(single.accountID, altitude)
    XCTAssertEqual(single.defaultScope, .account)
    XCTAssertEqual(single.rule(scope: .account).scope, .account(altitude))
    XCTAssertEqual(single.rule(scope: .account).when.accountID, altitude)
    XCTAssertEqual(single.rule(scope: .payee).scope, .payee("kopitiam"))
    XCTAssertNil(single.rule(scope: .payee).when.accountID)

    let other = applied(payee: "SHOPEE SG", proposedCategory: nil, category: household, account: uob)
    let mixed = try XCTUnwrap(
      IntakeRuleSuggester.suggest(applied: [one, other], jobID: UUID(), skill: IntakeSkill(), now: now)
    )
    XCTAssertNil(mixed.accountID)
    XCTAssertEqual(mixed.defaultScope, .payee)
  }

  func testAlsoNoticedCountsOnlyRulesThatFiredAndWereLeftAlone() throws {
    let existing = rule(when: .init(payeeToken: "grab"), then: .setCategory(transport))
    var skill = IntakeSkill()
    skill.add(existing)

    let kopi = applied(payee: "KOPITIAM AMK", proposedCategory: nil, category: eatingOut)
    var right1 = applied(payee: "GRAB", proposedCategory: transport, category: transport)
    right1.ruleApplications = [IntakeRuleApplication(ruleID: existing.id, effects: [.category])]
    var right2 = right1
    right2.id = UUID()
    var overridden = applied(payee: "GRAB", proposedCategory: transport, category: groceries)
    overridden.ruleApplications = [IntakeRuleApplication(ruleID: existing.id, effects: [.category])]

    let suggestion = try XCTUnwrap(
      IntakeRuleSuggester.suggest(applied: [kopi, right1, right2, overridden], jobID: UUID(), skill: skill, now: now)
    )
    XCTAssertEqual(suggestion.alsoNoticed?.ruleID, existing.id)
    XCTAssertEqual(suggestion.alsoNoticed?.count, 2)
  }

  // MARK: Helpers

  private func rule(
    scope: IntakeRuleScope = .global,
    when: IntakeRuleCondition,
    then: IntakeRuleAction,
    enabled: Bool = true,
    createdAt: Date? = nil
  ) -> IntakeRule {
    IntakeRule(scope: scope, when: when, then: then, enabled: enabled, createdAt: createdAt ?? now)
  }

  private func line(
    payee: String,
    account: String = "acct-altitude",
    direction: EntryDirection = .outflow,
    date: String = "2026-06-30"
  ) -> SlipMappedDraft {
    var draft = TransactionDraft()
    draft.direction = direction
    draft.amountMagnitudeMilli = 8_900
    draft.date = Date(isoDateString: date) ?? .distantPast
    draft.payeeName = payee
    draft.accountID = account
    return SlipMappedDraft(
      draft: draft,
      parsedAmount: true,
      parsedDate: true,
      parsedAccount: false,
      parsedCategory: false,
      parsedDirection: true,
      accountCandidates: [],
      categoryCandidates: []
    )
  }

  /// The category a line ends up with after `rules` run, nil when none applied.
  private func category(
    after rules: [IntakeRule],
    payee: String,
    account: String = "acct-altitude",
    direction: EntryDirection = .outflow
  ) -> String? {
    var read = line(payee: payee, account: account, direction: direction)
    _ = IntakeRuleEngine.apply(rules, to: &read, context: context)
    return read.draft.categoryID
  }

  /// A proposal the owner approved, with `proposedDraft` as the matcher made it
  /// and `draft` as saved.
  private func applied(
    payee: String,
    proposedCategory: String?,
    category: String?,
    finalPayee: String? = nil,
    account: String = "acct-altitude"
  ) -> IntakeProposal {
    var proposed = TransactionDraft()
    proposed.payeeName = payee
    proposed.accountID = account
    proposed.amountMagnitudeMilli = 8_900
    proposed.categoryID = proposedCategory
    var final = proposed
    final.categoryID = category
    final.payeeName = finalPayee ?? payee
    return IntakeProposal(
      kind: .add,
      confidence: 0.8,
      draft: final,
      proposedDraft: proposed,
      decision: .editedThenAccepted,
      isApplied: true
    )
  }
}
