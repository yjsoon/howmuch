import XCTest
@testable import HowMuch

/// Expectations come from docs/plans/share-intake.md section 6, not from the
/// matcher's code. Failure modes these tests exist for (the Share-to-Halation
/// E2E flows cannot reach them cheaply):
/// - a day window that is off by one, or breaks across a month end;
/// - a refund (same amount, opposite sign) treated as the original spend;
/// - a line with no date, or two equally good rows, silently becoming a Fix of
///   the wrong row;
/// - an approved row scoring higher than an unapproved one;
/// - widening to other accounts when the chosen account already has a match;
/// - a proposal naming a transaction ID the matcher was never given;
/// - one existing row absorbing two lines of the same document.
final class IntakeMatcherTests: XCTestCase {
  private let everyday = "acct-everyday"
  private let travel = "acct-travel"
  private let closed = "acct-closed"
  private lazy var openIDs: Set<String> = [everyday, travel]
  private let matcher = IntakeMatcher()

  // MARK: Window

  func testDayWindowIsInclusiveAcrossMonthEnd() {
    let read = line(8_900, date: "2026-06-30", payee: "Grab")
    for date in ["2026-06-27", "2026-06-30", "2026-07-01", "2026-07-03"] {
      let proposals = matcher.match([read], openAccountIDs: openIDs, candidates: [row("a", date: date, payee: "Grab")])
      XCTAssertEqual(proposals.first?.targetTransactionID, "a", "\(date) is within 3 days of 30 June")
    }
    for date in ["2026-06-26", "2026-07-04"] {
      let proposals = matcher.match([read], openAccountIDs: openIDs, candidates: [row("a", date: date, payee: "Grab")])
      XCTAssertEqual(proposals.first?.kind, .add, "\(date) is more than 3 days from 30 June")
      XCTAssertNil(proposals.first?.targetTransactionID)
      XCTAssertEqual(proposals.first?.candidateIDs, [])
    }
  }

  func testWindowIsConfigurable() {
    let read = line(8_900, date: "2026-06-30", payee: "Grab")
    let candidates = [row("a", date: "2026-07-04", payee: "Grab")]
    XCTAssertEqual(IntakeMatcher(dayWindow: 5).match([read], openAccountIDs: openIDs, candidates: candidates)
      .first?.targetTransactionID, "a")
    XCTAssertEqual(IntakeMatcher(dayWindow: 3).match([read], openAccountIDs: openIDs, candidates: candidates)
      .first?.kind, .add)
  }

  // MARK: Direction and amount

  func testSameAmountOppositeDirectionIsAPossibleDuplicateNeverAFix() {
    // A refund of the same amount: shown beside the original, never edited.
    let refund = row("refund", amount: 8_900, payee: "Grab")
    let proposals = matcher.match(
      [line(8_900, payee: "Grab", direction: .outflow)], openAccountIDs: openIDs, candidates: [refund]
    )
    XCTAssertEqual(proposals.first?.kind, .possibleDuplicate)
    XCTAssertNil(proposals.first?.targetTransactionID)
    XCTAssertEqual(proposals.first?.candidateIDs, ["refund"])
  }

  func testSameDirectionRowOutranksAnOppositeOne() {
    let proposals = matcher.match(
      [line(8_900, payee: "Grab")],
      openAccountIDs: openIDs,
      candidates: [row("refund", amount: 8_900, payee: "Grab"), row("spend", payee: "Grab")]
    )
    XCTAssertEqual(proposals[0].kind, .alreadyIn)
    XCTAssertEqual(proposals[0].targetTransactionID, "spend")
  }

  func testDifferentAmountIsNoMatch() {
    let proposals = matcher.match(
      [line(8_900, payee: "Grab")], openAccountIDs: openIDs, candidates: [row("a", amount: -8_901, payee: "Grab")]
    )
    XCTAssertEqual(proposals.first?.kind, .add)
    XCTAssertEqual(proposals.first?.candidateIDs, [])
  }

  // MARK: Strong, weak, none

  func testIdenticalStrongMatchIsAlreadyIn() {
    let proposals = matcher.match(
      [line(8_900, payee: "GRAB*A-5X7K9QWE SINGAPORE SG")],
      openAccountIDs: openIDs,
      candidates: [row("a", payee: "Grab")]
    )
    XCTAssertEqual(proposals.count, 1)
    XCTAssertEqual(proposals[0].kind, .alreadyIn)
    XCTAssertEqual(proposals[0].targetTransactionID, "a")
    XCTAssertEqual(proposals[0].changedFields, [])
    XCTAssertFalse(proposals[0].appliesOnApproval)
  }

  func testStrongMatchDifferingOnlyInPayeeIsAnEdit() {
    let proposals = matcher.match(
      [line(8_900, payee: "Sheng Siong Supermarke")],
      openAccountIDs: openIDs,
      candidates: [row("a", payee: "Sheng Siong")]
    )
    XCTAssertEqual(proposals[0].kind, .edit)
    XCTAssertEqual(proposals[0].targetTransactionID, "a")
    XCTAssertEqual(proposals[0].changedFields, [.payee])
    XCTAssertTrue(proposals[0].appliesOnApproval)
  }

  func testStrongMatchDifferingOnlyInCategoryIsAnEdit() {
    var read = line(8_900, payee: "Grab")
    read.draft.categoryID = "cat-transport"
    read.parsedCategory = true
    let proposals = matcher.match(
      [read], openAccountIDs: openIDs, candidates: [row("a", payee: "Grab", categoryID: "cat-eating-out")]
    )
    XCTAssertEqual(proposals[0].kind, .edit)
    XCTAssertEqual(proposals[0].changedFields, [.category])
  }

  func testWeakMatchIsAPossibleDuplicateNeverAnEdit() {
    // Same amount, same day, unrelated merchant: could be two coffees.
    let proposals = matcher.match(
      [line(8_900, payee: "Kopitiam")], openAccountIDs: openIDs, candidates: [row("a", payee: "Sheng Siong")]
    )
    XCTAssertEqual(proposals[0].kind, .possibleDuplicate)
    XCTAssertNil(proposals[0].targetTransactionID)
    XCTAssertEqual(proposals[0].candidateIDs, ["a"])
    XCTAssertFalse(proposals[0].appliesOnApproval)
  }

  func testLineWithoutADateIsNeverStrong() {
    var read = line(8_900, payee: "Grab")
    read.parsedDate = false
    let proposals = matcher.match(
      [read], openAccountIDs: openIDs, candidates: [row("a", payee: "Grab")]
    )
    XCTAssertEqual(proposals[0].kind, .possibleDuplicate)
    XCTAssertNil(proposals[0].targetTransactionID)
  }

  func testWeakMatchInAnotherAccountUnderADifferentPayeeIsPlainNewKeepingCandidates() {
    // Chosen account has nothing, so the search widens; the only hit is a
    // coincidence of amount under another merchant.
    let proposals = matcher.match(
      [line(8_900, payee: "Kopitiam", account: everyday)],
      openAccountIDs: openIDs,
      candidates: [row("t", account: travel, payee: "Sheng Siong")]
    )
    XCTAssertEqual(proposals[0].kind, .add)
    XCTAssertNil(proposals[0].targetTransactionID)
    XCTAssertEqual(proposals[0].candidateIDs, ["t"])
    XCTAssertTrue(proposals[0].appliesOnApproval)
  }

  func testApprovedFlagDoesNotChangeTheScore() {
    // Identical but for approval: if approval scored, one would win.
    let proposals = matcher.match(
      [line(8_900, payee: "Grab")],
      openAccountIDs: openIDs,
      candidates: [row("a", payee: "Grab", approved: true), row("b", payee: "Grab", approved: false)]
    )
    XCTAssertEqual(proposals[0].kind, .possibleDuplicate)
    XCTAssertNil(proposals[0].targetTransactionID)
  }

  func testFixHintLeavesUnmatchedLinesUntickedWithAReason() {
    let proposals = matcher.match(
      [line(8_900, payee: "Grab")], openAccountIDs: openIDs, candidates: [], hint: .fix
    )
    XCTAssertEqual(proposals[0].kind, .add)
    XCTAssertTrue(proposals[0].reasons.contains("No matching transaction found"))
    XCTAssertFalse(proposals[0].appliesOnApproval)
  }

  func testLimitedDuplicateCheckLeavesNewLinesUnticked() {
    let proposals = matcher.match(
      [line(8_900, payee: "Grab")], openAccountIDs: openIDs, candidates: [], duplicateCheckLimited: true
    )
    XCTAssertEqual(proposals[0].kind, .add)
    XCTAssertTrue(proposals[0].reasons.contains("Duplicate check limited · offline"))
    XCTAssertFalse(proposals[0].appliesOnApproval)
  }

  func testNoCandidateIsAPlainAdd() {
    let proposals = matcher.match([line(8_900, payee: "Grab")], openAccountIDs: openIDs, candidates: [])
    XCTAssertEqual(proposals[0].kind, .add)
    XCTAssertEqual(proposals[0].candidateIDs, [])
    XCTAssertTrue(proposals[0].appliesOnApproval)
  }

  // MARK: Ambiguity

  func testEqualScoreTieIsAPossibleDuplicateAndNeverEdits() {
    // Two identical rows. The matcher cannot know which one the document means,
    // so it must not edit either, even though the payee differs.
    let proposals = matcher.match(
      [line(8_900, payee: "Sheng Siong Supermarke")],
      openAccountIDs: openIDs,
      candidates: [row("a", payee: "Sheng Siong"), row("b", payee: "Sheng Siong")]
    )
    XCTAssertEqual(proposals[0].kind, .possibleDuplicate)
    XCTAssertNil(proposals[0].targetTransactionID)
    XCTAssertEqual(Set(proposals[0].candidateIDs), ["a", "b"])
    XCTAssertFalse(proposals[0].appliesOnApproval)
  }

  func testTieOfIdenticalContentIsNotAnAlreadyInEither() {
    let proposals = matcher.match(
      [line(8_900, payee: "Grab")],
      openAccountIDs: openIDs,
      candidates: [row("a", payee: "Grab"), row("b", payee: "Grab")]
    )
    XCTAssertEqual(proposals[0].kind, .possibleDuplicate)
    XCTAssertNil(proposals[0].targetTransactionID)
  }

  func testCloserDateBreaksWhatWouldOtherwiseBeATie() {
    let proposals = matcher.match(
      [line(8_900, date: "2026-06-30", payee: "Grab")],
      openAccountIDs: openIDs,
      candidates: [row("far", date: "2026-07-02", payee: "Grab"), row("near", date: "2026-06-30", payee: "Grab")]
    )
    XCTAssertEqual(proposals[0].kind, .alreadyIn)
    XCTAssertEqual(proposals[0].targetTransactionID, "near")
  }

  // MARK: Account widening

  func testWidensToOtherOpenAccountsOnlyWhenChosenAccountHasNone() {
    let read = line(8_900, payee: "Grab", account: everyday)

    let elsewhere = matcher.match(
      [read], openAccountIDs: openIDs, candidates: [row("t", account: travel, payee: "Grab")]
    )
    XCTAssertEqual(elsewhere[0].targetTransactionID, "t", "No row in the chosen account, so widen")

    let chosenWins = matcher.match(
      [read],
      openAccountIDs: openIDs,
      candidates: [
        row("e", account: everyday, payee: "Kopitiam"),
        row("t", account: travel, payee: "Grab"),
      ]
    )
    XCTAssertNil(chosenWins[0].targetTransactionID)
    XCTAssertEqual(chosenWins[0].candidateIDs, ["e"], "The chosen account had a candidate, so do not widen")
  }

  func testClosedAccountsAreNeverSearched() {
    let proposals = matcher.match(
      [line(8_900, payee: "Grab", account: everyday)],
      openAccountIDs: openIDs,
      candidates: [row("c", account: closed, payee: "Grab")]
    )
    XCTAssertEqual(proposals[0].kind, .add)
    XCTAssertEqual(proposals[0].candidateIDs, [])
  }

  func testLineWithNoAccountSearchesAllOpenAccounts() {
    let proposals = matcher.match(
      [line(8_900, payee: "Grab", account: "")], openAccountIDs: openIDs, candidates: [row("t", account: travel, payee: "Grab")]
    )
    XCTAssertEqual(proposals[0].targetTransactionID, "t")
  }

  // MARK: Invariants

  func testTargetAndCandidateIDsAreAlwaysFromTheSuppliedRows() {
    let candidates = [
      row("a", payee: "Grab"),
      row("b", payee: "Grab"),
      row("c", amount: -4_500, payee: "Kopitiam", approved: false),
      row("d", account: travel, amount: -12_000, payee: "Sheng Siong"),
    ]
    let reads = [
      line(8_900, payee: "Grab"),
      line(4_500, payee: "Kopitiam Bishan"),
      line(12_000, payee: "Sheng Siong Supermarke", account: everyday),
      line(1_000, payee: "Nobody"),
    ]
    let supplied = Set(candidates.map(\.id))
    for proposal in matcher.match(reads, openAccountIDs: openIDs, candidates: candidates) {
      if let target = proposal.targetTransactionID {
        XCTAssertTrue(supplied.contains(target), "Unknown target \(target)")
      }
      XCTAssertTrue(Set(proposal.candidateIDs).isSubset(of: supplied))
    }
  }

  func testOneExistingRowIsNotClaimedByTwoLines() {
    // Two identical coffees on the document, one already in the register.
    let proposals = matcher.match(
      [line(4_500, payee: "Kopitiam"), line(4_500, payee: "Kopitiam")],
      openAccountIDs: openIDs,
      candidates: [row("a", amount: -4_500, payee: "Kopitiam")]
    )
    XCTAssertEqual(proposals.map(\.kind), [.alreadyIn, .add])
    XCTAssertEqual(proposals.compactMap(\.targetTransactionID), ["a"])
  }

  func testReturnsOneProposalPerLineInOrder() {
    let reads = [line(1_000, payee: "A"), line(2_000, payee: "B"), line(3_000, payee: "C")]
    let proposals = matcher.match(reads, openAccountIDs: openIDs, candidates: [])
    XCTAssertEqual(proposals.map(\.draft.amountMagnitudeMilli), [1_000, 2_000, 3_000])
  }

  // MARK: Helpers

  private func line(
    _ magnitude: Int,
    date: String = "2026-06-30",
    payee: String,
    direction: EntryDirection = .outflow,
    account: String? = nil
  ) -> SlipMappedDraft {
    var draft = TransactionDraft()
    draft.direction = direction
    draft.amountMagnitudeMilli = magnitude
    draft.date = Date(isoDateString: date) ?? .distantPast
    draft.payeeName = payee
    draft.accountID = account ?? everyday
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

  private func row(
    _ id: String,
    account: String? = nil,
    date: String = "2026-06-30",
    amount: Int = -8_900,
    payee: String,
    categoryID: String? = nil,
    approved: Bool = true
  ) -> IntakeCandidateRow {
    IntakeCandidateRow(
      id: id,
      accountID: account ?? everyday,
      date: date,
      amountMilli: amount,
      payeeName: payee,
      categoryID: categoryID,
      approved: approved
    )
  }
}
