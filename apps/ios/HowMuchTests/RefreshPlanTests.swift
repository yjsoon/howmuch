import XCTest
@testable import HowMuch

/// The functional core of #179: which slices a mutation makes stale, how
/// back-to-back refresh requests coalesce, and when the Reflect reports may be
/// served from cache (#180). No network, no model, no view.
final class RefreshPlanTests: XCTestCase {
  // MARK: - Mutation → slice table

  func testClearedToggleRefreshesBalancesOnly() {
    XCTAssertEqual(
      RefreshPlanner.slices(after: .clearedToggled),
      [.accounts],
      "a cleared toggle applies the returned row locally, so only the account balances are left to read"
    )
    XCTAssertFalse(
      RefreshPlanner.invalidatesPlanAndReports(after: .clearedToggled),
      "clearing moves no money: the plan and the reports read amounts, not cleared state"
    )
  }

  func testOrdinaryEditRefreshesBalancesOnly() {
    let slices = RefreshPlanner.slices(
      after: .transactionEdited(changesAccount: false, touchesTransfer: false, hasNewPayee: false)
    )
    XCTAssertEqual(slices, [.accounts])
    XCTAssertFalse(slices.contains(.referenceData))
    XCTAssertFalse(slices.contains(.schedules))
  }

  func testEditThatMovesAccountOrTouchesATransferAlsoRefreshesTheLedger() {
    XCTAssertEqual(
      RefreshPlanner.slices(
        after: .transactionEdited(changesAccount: true, touchesTransfer: false, hasNewPayee: false)
      ),
      [.accounts, .ledger]
    )
    XCTAssertEqual(
      RefreshPlanner.slices(
        after: .transactionEdited(changesAccount: false, touchesTransfer: true, hasNewPayee: false)
      ),
      [.accounts, .ledger],
      "a transfer's mirror row lives on another account and is not returned by the write"
    )
  }

  func testEditThatNamesANewPayeeAlsoRefreshesThePayeeList() {
    XCTAssertEqual(
      RefreshPlanner.slices(
        after: .transactionEdited(changesAccount: false, touchesTransfer: false, hasNewPayee: true)
      ),
      [.accounts, .payees],
      "a payee the server provisioned during the save is absent from the local pickers until it is read"
    )
  }

  func testCreatesAddLedgerOnlyForTransfersAndPayeesOnlyForNewNames() {
    XCTAssertEqual(
      RefreshPlanner.slices(after: .transactionsCreated(hasTransfer: false, hasNewPayee: false)),
      [.accounts]
    )
    XCTAssertEqual(
      RefreshPlanner.slices(after: .transactionsCreated(hasTransfer: true, hasNewPayee: false)),
      [.accounts, .ledger]
    )
    XCTAssertEqual(
      RefreshPlanner.slices(after: .transactionsCreated(hasTransfer: false, hasNewPayee: true)),
      [.accounts, .payees]
    )
  }

  func testDeleteRefreshesBalancesOnly() {
    XCTAssertEqual(RefreshPlanner.slices(after: .transactionDeleted), [.accounts])
  }

  func testApprovalRefreshesLedgerForCascadedRows() {
    XCTAssertEqual(
      RefreshPlanner.slices(after: .transactionsApproved),
      [.ledger],
      "approval can cascade from a split to unloaded mirrors, so the first ledger page and its count must reconcile"
    )
    XCTAssertFalse(RefreshPlanner.invalidatesPlanAndReports(after: .transactionsApproved))
  }

  func testAccountWritesStayOffTheLedger() {
    XCTAssertEqual(
      RefreshPlanner.slices(after: .accountCreated),
      [.payees],
      "a new account provisions its transfer payee server-side but holds no opening-balance transaction"
    )
    XCTAssertEqual(
      RefreshPlanner.slices(after: .accountUpdated),
      [],
      "the PATCH returns the account and the transfer payee rename is mirrored locally"
    )
  }

  func testReconcileRefreshesTheLedgerButNotTheAccountsList() {
    XCTAssertEqual(
      RefreshPlanner.slices(after: .accountReconciled),
      [.ledger],
      "the reconcile response carries the account with its new balances, so only the flipped rows must be re-read"
    )
  }

  func testScheduleWritesRefreshNothing() {
    XCTAssertEqual(RefreshPlanner.slices(after: .scheduleSaved), [])
    XCTAssertEqual(RefreshPlanner.slices(after: .scheduleDeleted), [])
  }

  func testEnteringAnOccurrenceRefreshesBalancesAndTransfersOnly() {
    XCTAssertEqual(
      RefreshPlanner.slices(after: .scheduledOccurrenceEntered(isTransfer: false)),
      [.accounts]
    )
    XCTAssertEqual(
      RefreshPlanner.slices(after: .scheduledOccurrenceEntered(isTransfer: true)),
      [.accounts, .ledger]
    )
  }

  func testNoMutationEverRefetchesReferenceDataOrReports() {
    let mutations: [MutationKind] = [
      .clearedToggled,
      .transactionEdited(changesAccount: true, touchesTransfer: true, hasNewPayee: true),
      .transactionsCreated(hasTransfer: true, hasNewPayee: true),
      .transactionDeleted,
      .transactionsApproved,
      .accountCreated,
      .accountUpdated,
      .accountReconciled,
      .scheduleSaved,
      .scheduleDeleted,
      .scheduledOccurrenceEntered(isTransfer: true),
    ]
    for mutation in mutations {
      let slices = RefreshPlanner.slices(after: mutation)
      XCTAssertFalse(
        slices.contains(.referenceData),
        "\(mutation) must not drag the five-request reference batch behind a write"
      )
      XCTAssertFalse(
        slices.contains(.reports),
        "\(mutation) must mark the reports stale, not refetch them behind a write"
      )
    }
  }

  // MARK: - Tabs

  func testAccountsPullNeverAsksForReports() {
    XCTAssertEqual(TabRefresh.accounts, [.accounts])
    XCTAssertFalse(TabRefresh.accounts.contains(.reports))
    XCTAssertFalse(TabRefresh.accounts.contains(.ledger))
    XCTAssertEqual(TabRefresh.register, [.accounts, .ledger, .schedules])
    XCTAssertEqual(TabRefresh.reflect, [.reports])
  }

  func testAccountsPullRetriesTheWholeBatchWhenReferenceDataIsNotLoaded() {
    XCTAssertEqual(
      TabRefresh.accounts(referencePhase: .loaded),
      [.accounts],
      "the ordinary pull stays one GET"
    )
    for phase in [LoadPhase.idle, .failed("offline")] {
      XCTAssertEqual(
        TabRefresh.accounts(referencePhase: phase),
        [.referenceData],
        "the Accounts placeholder sits inside the pull, so \(phase) makes the pull its retry"
      )
    }
  }

  // MARK: - Debounce / coalescing

  func testMergingKeepsTheUnionAndTheLoudestIntent() {
    let background = RefreshRequest(slices: [.accounts], quiet: true, force: false)
    let pull = RefreshRequest(slices: [.ledger], quiet: false, force: true)
    let merged = background.merging(pull)
    XCTAssertEqual(merged.slices, [.accounts, .ledger])
    XCTAssertFalse(merged.quiet, "one non-quiet caller makes the coalesced pass non-quiet")
    XCTAssertTrue(merged.force, "one forced caller makes the coalesced pass forced")
  }

  func testMergingIsIdempotentForARepeatedRequest() {
    let request = RefreshRequest(slices: [.accounts], quiet: false)
    XCTAssertEqual(request.merging(request), request, "spamming pull-to-refresh must collapse to one pass")
  }

  func testAnEmptyRequestIsSkipped() {
    XCTAssertTrue(RefreshRequest(slices: []).isEmpty)
    XCTAssertTrue(RefreshRequest.none.isEmpty)
  }

  func testReferenceDataAbsorbsItsOwnNarrowerSlices() {
    let request = RefreshRequest(slices: [.referenceData, .accounts, .payees, .ledger])
    XCTAssertEqual(
      request.slices,
      [.referenceData, .ledger],
      "the reference batch already fetches accounts and payees; keeping both would double the requests"
    )
  }

  // MARK: - Reports cache (#180)

  func testReportsAreFetchedOnFirstAppearance() {
    XCTAssertTrue(
      ReportsRefreshPolicy.shouldFetch(
        phase: .idle,
        force: false,
        lastKnowledge: nil,
        currentKnowledge: 7,
        lastMutationGeneration: nil,
        currentMutationGeneration: 0
      )
    )
  }

  func testLoadedReportsAreServedFromCacheWhenNothingMoved() {
    XCTAssertFalse(
      ReportsRefreshPolicy.shouldFetch(
        phase: .loaded,
        force: false,
        lastKnowledge: 7,
        currentKnowledge: 7,
        lastMutationGeneration: 3,
        currentMutationGeneration: 3
      ),
      "a second visit with an unchanged cursor and no local writes must not refetch"
    )
  }

  func testAdvancedKnowledgeOrALocalWriteInvalidatesTheCache() {
    XCTAssertTrue(
      ReportsRefreshPolicy.shouldFetch(
        phase: .loaded,
        force: false,
        lastKnowledge: 7,
        currentKnowledge: 8,
        lastMutationGeneration: 3,
        currentMutationGeneration: 3
      ),
      "a cursor that advanced means someone else wrote to the plan"
    )
    XCTAssertTrue(
      ReportsRefreshPolicy.shouldFetch(
        phase: .loaded,
        force: false,
        lastKnowledge: 7,
        currentKnowledge: 7,
        lastMutationGeneration: 3,
        currentMutationGeneration: 4
      ),
      "this device's own writes are applied locally and never move the cursor, so they need their own signal"
    )
  }

  func testPullToRefreshForcesAFetchAndAnInFlightOneIsNotDuplicated() {
    XCTAssertTrue(
      ReportsRefreshPolicy.shouldFetch(
        phase: .loaded,
        force: true,
        lastKnowledge: 7,
        currentKnowledge: 7,
        lastMutationGeneration: 3,
        currentMutationGeneration: 3
      )
    )
    XCTAssertFalse(
      ReportsRefreshPolicy.shouldFetch(
        phase: .loading,
        force: true,
        lastKnowledge: nil,
        currentKnowledge: nil,
        lastMutationGeneration: nil,
        currentMutationGeneration: 0
      ),
      "a fetch already in flight must not be started twice"
    )
  }

  /// Leaving Reflect cancels its fetch, which returns the phase to `.idle`
  /// rather than to `.failed` or a stuck `.loading`. Coming back must fetch.
  func testACancelledFetchIsRetriedOnTheNextAppearance() {
    XCTAssertTrue(
      ReportsRefreshPolicy.shouldFetch(
        phase: .idle,
        force: false,
        lastKnowledge: 7,
        currentKnowledge: 7,
        lastMutationGeneration: 3,
        currentMutationGeneration: 3
      )
    )
  }

  func testAFailedFetchIsRetriedRatherThanCached() {
    XCTAssertTrue(
      ReportsRefreshPolicy.shouldFetch(
        phase: .failed("offline"),
        force: false,
        lastKnowledge: 7,
        currentKnowledge: 7,
        lastMutationGeneration: 3,
        currentMutationGeneration: 3
      )
    )
  }
}
