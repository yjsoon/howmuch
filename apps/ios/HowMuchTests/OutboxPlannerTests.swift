import XCTest
@testable import HowMuch

/// The functional core of the offline outbox: coalescing, replay order,
/// outcome mapping and balance deltas. No network, no model, no disk.
final class OutboxPlannerTests: XCTestCase {
  // MARK: - Fixtures

  private let epoch = Date(timeIntervalSince1970: 1_790_000_000)
  private var nextUUID = 0

  private func uuid() -> UUID {
    nextUUID += 1
    return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", nextUUID))!
  }

  private func command(
    _ kind: OutboxCommand.Kind,
    id transactionID: String = "t1",
    base: Transaction? = nil,
    state: OutboxCommand.State = .queued
  ) -> OutboxCommand {
    OutboxCommand(
      id: uuid(),
      transactionID: transactionID,
      connectionFingerprint: "fp",
      createdAt: epoch,
      kind: kind,
      state: state,
      baseSnapshot: base
    )
  }

  private func request(
    account: String = "a1",
    amount: Int = -10_000,
    payeeID: String? = nil,
    memo: String? = nil,
    cleared: ClearedState? = nil,
    approved: Bool = true,
    subtransactions: [TransactionSubtransactionWriteRequest] = [],
    importID: String? = nil
  ) -> TransactionWriteRequest {
    TransactionWriteRequest(
      accountID: account,
      date: "2026-09-26",
      amount: amount,
      payeeID: payeeID,
      payeeName: nil,
      categoryID: nil,
      memo: memo,
      cleared: cleared,
      approved: approved,
      flagColor: nil,
      subtransactions: subtransactions,
      importID: importID
    )
  }

  private func row(
    _ id: String = "t1",
    account: String = "a1",
    amount: Int = -10_000,
    cleared: ClearedState = .uncleared,
    approved: Bool = true,
    payeeID: String? = nil,
    transferAccountID: String? = nil,
    transferTransactionID: String? = nil,
    parentTransactionID: String? = nil,
    subtransactions: [Subtransaction] = []
  ) -> Transaction {
    Transaction(
      id: id,
      date: "2026-09-20",
      amount: amount,
      memo: nil,
      cleared: cleared,
      approved: approved,
      flagColor: nil,
      flagName: nil,
      accountID: account,
      accountName: account,
      payeeID: payeeID,
      payeeName: nil,
      categoryID: nil,
      categoryName: nil,
      transferAccountID: transferAccountID,
      transferTransactionID: transferTransactionID,
      parentTransactionID: parentTransactionID,
      matchedTransactionID: nil,
      importID: nil,
      importPayeeName: nil,
      importPayeeNameOriginal: nil,
      deleted: false,
      subtransactions: subtransactions
    )
  }

  private func enqueueAll(_ commands: [OutboxCommand], onto queue: [OutboxCommand] = []) -> [OutboxCommand] {
    commands.reduce(queue) { OutboxPlanner.enqueue($1, onto: $0) }
  }

  private func delta(balance: Int = 0, cleared: Int = 0, uncleared: Int = 0) -> DeleteBalanceDelta.Delta {
    DeleteBalanceDelta.Delta(balance: balance, cleared: cleared, uncleared: uncleared)
  }

  // MARK: - Coalescing

  func testFirstCommandIsAppendedAndStamped() {
    let queue = enqueueAll([command(.approve, id: "t1"), command(.approve, id: "t2")])
    XCTAssertEqual(queue.map(\.seq), [1, 2])
    XCTAssertEqual(queue.map(\.transactionID), ["t1", "t2"])
  }

  func testCreateThenUpdateStaysACreateWithTheNewBodyAndOriginalImportID() {
    let queue = enqueueAll([
      command(.create(request(cleared: .cleared, importID: "imp-1"))),
      command(.update(request(amount: -25_000, memo: "lunch"))),
    ])
    XCTAssertEqual(queue.count, 1)
    XCTAssertEqual(
      queue[0].kind,
      .create(request(amount: -25_000, memo: "lunch", cleared: .cleared, importID: "imp-1")),
      "an edit omits cleared, so the create keeps its own"
    )
  }

  func testCreateFoldsInAClearedToggle() {
    let queue = enqueueAll([
      command(.create(request(cleared: .uncleared, importID: "imp"))),
      command(.cleared(expected: .uncleared, cleared: .cleared, approve: false)),
    ])
    XCTAssertEqual(queue.map(\.kind), [.create(request(cleared: .cleared, importID: "imp"))])
  }

  func testCreateFoldsInAnApproval() {
    let queue = enqueueAll([
      command(.create(request(approved: false))),
      command(.approve),
    ])
    XCTAssertEqual(queue.map(\.kind), [.create(request(approved: true))])
  }

  func testCreateThenDeleteCancelsBoth() {
    let queue = enqueueAll([
      command(.approve, id: "other"),
      command(.create(request())),
      command(.delete(expectedApproved: nil)),
    ])
    XCTAssertEqual(queue.map(\.transactionID), ["other"])
  }

  func testRepeatedUpdatesKeepTheLastBodyAndTheFirstBase() {
    let first = row(amount: -1_000)
    let queue = enqueueAll([
      command(.update(request(amount: -2_000)), base: first),
      command(.update(request(amount: -3_000)), base: row(amount: -2_000)),
    ])
    XCTAssertEqual(queue.count, 1)
    XCTAssertEqual(queue[0].kind, .update(request(amount: -3_000)))
    XCTAssertEqual(queue[0].baseSnapshot, first)
  }

  func testUpdateThenClearedCarriesTheStatus() {
    let base = row(cleared: .uncleared)
    let queue = enqueueAll([
      command(.update(request(amount: -2_000)), base: base),
      command(.cleared(expected: .uncleared, cleared: .cleared, approve: false), base: base),
    ])
    XCTAssertEqual(queue.map(\.kind), [.update(request(amount: -2_000, cleared: .cleared))])
  }

  func testUpdateCarryingClearedDropsItWhenToggledBack() {
    let base = row(cleared: .uncleared)
    let queue = enqueueAll([
      command(.update(request()), base: base),
      command(.cleared(expected: .uncleared, cleared: .cleared, approve: false), base: base),
      command(.cleared(expected: .cleared, cleared: .uncleared, approve: false), base: base),
    ])
    XCTAssertEqual(queue.map(\.kind), [.update(request(cleared: nil))])
  }

  func testLaterUpdateKeepsACarriedStatus() {
    let base = row(cleared: .uncleared)
    let queue = enqueueAll([
      command(.cleared(expected: .uncleared, cleared: .cleared, approve: false), base: base),
      command(.update(request(amount: -4_000)), base: base),
      command(.update(request(amount: -5_000)), base: base),
    ])
    XCTAssertEqual(queue.map(\.kind), [.update(request(amount: -5_000, cleared: .cleared))])
  }

  func testClearedToggledBackIsRemoved() {
    let base = row(cleared: .uncleared)
    let queue = enqueueAll([
      command(.cleared(expected: .uncleared, cleared: .cleared, approve: false), base: base),
      command(.cleared(expected: .cleared, cleared: .uncleared, approve: false), base: base),
    ])
    XCTAssertEqual(queue, [])
  }

  func testClearedToggledBackKeepsAFoldedApproval() {
    let base = row(cleared: .uncleared, approved: false)
    let queue = enqueueAll([
      command(.cleared(expected: .uncleared, cleared: .cleared, approve: false), base: base),
      command(.approve, base: base),
      command(.cleared(expected: .cleared, cleared: .uncleared, approve: false), base: base),
    ])
    XCTAssertEqual(queue.map(\.kind), [.approve])
  }

  func testApprovalAndClearedFoldIntoOneCommandEitherWay() {
    let base = row(approved: false)
    let approveFirst = enqueueAll([
      command(.approve, base: base),
      command(.cleared(expected: .uncleared, cleared: .cleared, approve: false), base: base),
    ])
    let clearedFirst = enqueueAll([
      command(.cleared(expected: .uncleared, cleared: .cleared, approve: false), base: base),
      command(.approve, base: base),
    ])
    let expected = OutboxCommand.Kind.cleared(expected: .uncleared, cleared: .cleared, approve: true)
    XCTAssertEqual(approveFirst.map(\.kind), [expected])
    XCTAssertEqual(clearedFirst.map(\.kind), [expected])
  }

  func testApprovalFoldsIntoAnUpdateEitherWay() {
    let base = row(approved: false)
    let approveFirst = enqueueAll([
      command(.approve, base: base),
      command(.update(request(approved: false)), base: base),
    ])
    let updateFirst = enqueueAll([
      command(.update(request(approved: false)), base: base),
      command(.approve, base: base),
    ])
    XCTAssertEqual(approveFirst.map(\.kind), [.update(request(approved: true))])
    XCTAssertEqual(updateFirst.map(\.kind), [.update(request(approved: true))])
  }

  func testRepeatedApprovalsCollapse() {
    XCTAssertEqual(enqueueAll([command(.approve), command(.approve)]).map(\.kind), [.approve])
  }

  func testAnyChangeThenDeleteBecomesADeleteGuardedByTheBase() {
    let unapproved = row(approved: false)
    let kinds: [OutboxCommand.Kind] = [
      .update(request()),
      .cleared(expected: .uncleared, cleared: .cleared, approve: false),
      .approve,
    ]
    for kind in kinds {
      let queue = enqueueAll([
        command(kind, base: unapproved),
        command(.delete(expectedApproved: nil), base: unapproved.withApproved(true)),
      ])
      XCTAssertEqual(queue.map(\.kind), [.delete(expectedApproved: false)], "\(kind)")
      XCTAssertEqual(queue[0].baseSnapshot, unapproved, "\(kind)")
    }
    let approved = enqueueAll([
      command(.update(request()), base: row(approved: true)),
      command(.delete(expectedApproved: false), base: row(approved: true)),
    ])
    XCTAssertEqual(approved.map(\.kind), [.delete(expectedApproved: nil)])
  }

  func testNothingFoldsIntoADelete() {
    let queue = enqueueAll([
      command(.delete(expectedApproved: nil), base: row()),
      command(.update(request())),
      command(.approve),
    ])
    XCTAssertEqual(queue.map(\.kind), [.delete(expectedApproved: nil)])
  }

  func testReplayedCreateIsIgnored() {
    let queue = enqueueAll([
      command(.create(request(importID: "imp"))),
      command(.create(request(amount: -1, importID: "imp"))),
    ])
    XCTAssertEqual(queue.map(\.kind), [.create(request(importID: "imp"))])
  }

  func testInFlightCommandIsNeverRewrittenAndTheChangeQueuesBehindIt() {
    let inFlight = command(.create(request(importID: "imp")), state: .inFlight)
    var queue = [inFlight]
    queue = enqueueAll([
      command(.update(request(amount: -2_000))),
      command(.update(request(amount: -3_000))),
      command(.approve),
    ], onto: queue)
    XCTAssertEqual(queue.count, 2)
    XCTAssertEqual(queue[0], inFlight)
    XCTAssertEqual(queue[1].kind, .update(request(amount: -3_000)))
    XCTAssertEqual(queue[1].state, .queued)
  }

  func testDeleteBehindAnInFlightCreateIsKept() {
    let inFlight = command(.create(request()), state: .inFlight)
    let queue = enqueueAll([command(.delete(expectedApproved: nil))], onto: [inFlight])
    XCTAssertEqual(queue.map(\.kind), [.create(request()), .delete(expectedApproved: nil)])
    XCTAssertEqual(queue[0], inFlight)
  }

  func testChangingARejectedCommandRequeuesIt() {
    let rejected = command(.create(request(amount: 0)), state: .rejected(message: "Amount required", code: 400))
    let queue = enqueueAll([command(.update(request(amount: -1_000)))], onto: [rejected])
    XCTAssertEqual(queue.count, 1)
    XCTAssertEqual(queue[0].id, rejected.id)
    XCTAssertEqual(queue[0].state, .queued)
    XCTAssertEqual(queue[0].kind, .create(request(amount: -1_000)))
  }

  /// Random op sequences, with commands going in flight between ops: at most
  /// one command per row is not in flight, and an in-flight command is never
  /// touched.
  func testRandomSequencesKeepOneQueuedCommandPerRowAndLeaveInFlightAlone() {
    var generator = SplitMix64(seed: 0x5EED)
    let rows = ["t1", "t2", "t3"]
    for _ in 0..<300 {
      var queue: [OutboxCommand] = []
      var inFlightSeen: [UUID: OutboxCommand] = [:]
      for _ in 0..<Int.random(in: 1...25, using: &generator) {
        let id = rows.randomElement(using: &generator)!
        let base = row(id, cleared: Bool.random(using: &generator) ? .cleared : .uncleared)
        let kind: OutboxCommand.Kind
        switch Int.random(in: 0..<5, using: &generator) {
        case 0: kind = .create(request(amount: Int.random(in: -9...9, using: &generator)))
        case 1: kind = .update(request(amount: Int.random(in: -9...9, using: &generator)))
        case 2:
          let flip = Bool.random(using: &generator)
          kind = .cleared(expected: flip ? .cleared : .uncleared, cleared: flip ? .uncleared : .cleared, approve: false)
        case 3: kind = .approve
        default: kind = .delete(expectedApproved: nil)
        }
        queue = OutboxPlanner.enqueue(command(kind, id: id, base: base), onto: queue)

        if Int.random(in: 0..<4, using: &generator) == 0,
           let index = queue.indices.filter({ !queue[$0].isInFlight }).randomElement(using: &generator) {
          queue[index].state = .inFlight
        }
        if Int.random(in: 0..<6, using: &generator) == 0,
           let index = queue.indices.filter({ queue[$0].isInFlight }).randomElement(using: &generator) {
          inFlightSeen[queue[index].id] = nil
          queue.remove(at: index)
        }
        for command in queue where command.isInFlight {
          if let seen = inFlightSeen[command.id] {
            XCTAssertEqual(command, seen, "an in-flight command was rewritten")
          }
          inFlightSeen[command.id] = command
        }
        for id in rows {
          let waiting = queue.filter { $0.transactionID == id && !$0.isInFlight }
          XCTAssertLessThanOrEqual(waiting.count, 1, "row \(id) has \(waiting.count) queued commands")
        }
        XCTAssertEqual(Set(queue.map(\.id)).count, queue.count)
      }
      for (id, seen) in inFlightSeen {
        XCTAssertEqual(queue.first { $0.id == id }, seen, "an in-flight command went missing")
      }
    }
  }

  // MARK: - Replay

  func testPlanSendsStagesInOrderAndKeepsQueueOrderWithinEach() {
    let queue = enqueueAll([
      command(.delete(expectedApproved: nil), id: "d1", base: row("d1")),
      command(.approve, id: "p1"),
      command(.cleared(expected: .uncleared, cleared: .cleared, approve: false), id: "c1"),
      command(.update(request()), id: "u1"),
      command(.create(request()), id: "n1"),
      command(.create(request()), id: "n2"),
      command(.cleared(expected: .cleared, cleared: .uncleared, approve: true), id: "c2"),
    ])
    let plan = OutboxPlanner.plan(queue)
    XCTAssertEqual(plan.batches.map(\.stage), [.create, .update, .cleared, .approve, .delete])
    XCTAssertEqual(plan.batches.map { $0.commands.map(\.transactionID) }, [["n1", "n2"], ["u1"], ["c1", "c2"], ["p1"], ["d1"]])
    XCTAssertEqual(plan.deferred, [])
  }

  func testPlanDefersDependentsAndSkipsInFlightAndRejected() {
    let queue = [
      command(.create(request()), id: "t1", state: .inFlight),
      command(.update(request()), id: "t1"),
      command(.update(request()), id: "t2", state: .rejected(message: "No", code: 400)),
      command(.approve, id: "t3"),
    ].enumerated().map { index, command in
      var command = command
      command.seq = index + 1
      return command
    }
    let plan = OutboxPlanner.plan(queue)
    XCTAssertEqual(plan.batches.map(\.stage), [.approve])
    XCTAssertEqual(plan.batches.flatMap(\.commands).map(\.transactionID), ["t3"])
    XCTAssertEqual(plan.deferred.map(\.transactionID), ["t1"])
  }

  func testEmptyQueuePlansNothing() {
    XCTAssertEqual(OutboxPlanner.plan([]), OutboxPlanner.Plan(batches: [], deferred: []))
  }

  // MARK: - Outcomes

  func testOutcomeMapping() {
    typealias Result = OutboxPlanner.ServerResult
    let create = OutboxCommand.Kind.create(request())
    let update = OutboxCommand.Kind.update(request())
    let cleared = OutboxCommand.Kind.cleared(expected: .uncleared, cleared: .cleared, approve: false)
    let delete = OutboxCommand.Kind.delete(expectedApproved: nil)
    let cases: [(OutboxCommand.Kind, Result, OutboxPlanner.Action)] = [
      (create, .succeeded, .complete),
      (.approve, .succeeded, .complete),
      (.cleared(expected: .uncleared, cleared: .cleared, approve: true), .succeeded, .continueAs(.approve)),
      (delete, .status(404, message: "Not found"), .complete),
      (update, .status(404, message: "Not found"), .reject(message: "Not found", code: 404)),
      (cleared, .status(409, message: "Changed"), .refetchAndCompare),
      (update, .status(409, message: "Changed"), .reject(message: "Changed", code: 409)),
      (create, .status(400, message: "Bad amount"), .reject(message: "Bad amount", code: 400)),
      (delete, .status(400, message: "Approved"), .reject(message: "Approved", code: 400)),
      (create, .status(422, message: "Invalid"), .reject(message: "Invalid", code: 422)),
      (create, .offline, .retryLater),
      (cleared, .offline, .retryLater),
      (create, .status(500, message: "Boom"), .retryLater),
      (delete, .status(503, message: "Busy"), .retryLater),
      (update, .status(401, message: "Signed out"), .retryLater),
      (update, .status(429, message: "Slow down"), .retryLater),
    ]
    for (kind, result, expected) in cases {
      XCTAssertEqual(OutboxPlanner.action(for: kind, result: result), expected, "\(kind) / \(result)")
    }
  }

  // MARK: - Balance deltas

  func testCreateAddsToItsAccount() {
    let deltas = OutboxPlanner.balanceDeltas(
      [command(.create(request(amount: -10_000, cleared: .uncleared)))],
      rowsByID: [:]
    )
    XCTAssertEqual(deltas, ["a1": delta(balance: -10_000, uncleared: -10_000)])
  }

  func testCreatedTransferMirrorsToTheResolvedAccount() {
    let deltas = OutboxPlanner.balanceDeltas(
      [command(.create(request(amount: -10_000, payeeID: "p-savings", cleared: .cleared)))],
      rowsByID: [:],
      transferAccountIDsByPayeeID: ["p-savings": "savings"]
    )
    XCTAssertEqual(deltas, [
      "a1": delta(balance: -10_000, cleared: -10_000),
      "savings": delta(balance: 10_000, uncleared: 10_000),
    ])
  }

  func testCreatedSplitMirrorsItsTransferLines() {
    let lines = [
      TransactionSubtransactionWriteRequest(id: nil, amount: -6_000, payeeID: nil, payeeName: nil, categoryID: "food", memo: nil, transferAccountID: nil, transferTransactionID: nil),
      TransactionSubtransactionWriteRequest(id: nil, amount: -4_000, payeeID: nil, payeeName: nil, categoryID: nil, memo: nil, transferAccountID: "savings", transferTransactionID: nil),
    ]
    let deltas = OutboxPlanner.balanceDeltas(
      [command(.create(request(amount: -10_000, subtransactions: lines)))],
      rowsByID: [:]
    )
    XCTAssertEqual(deltas, [
      "a1": delta(balance: -10_000, uncleared: -10_000),
      "savings": delta(balance: 4_000, uncleared: 4_000),
    ])
  }

  func testDeleteMatchesTheExistingDeleteDelta() {
    let transfer = row(
      "t1", account: "a1", amount: -10_000, cleared: .cleared,
      transferAccountID: "savings", transferTransactionID: "t2"
    )
    let mirror = row("t2", account: "savings", amount: 10_000, cleared: .cleared)
    let rows = ["t1": transfer, "t2": mirror]
    let deltas = OutboxPlanner.balanceDeltas(
      [command(.delete(expectedApproved: nil), base: transfer)],
      rowsByID: rows
    )
    let existing = DeleteBalanceDelta.deltas(deleted: transfer, removedIDs: ["t1", "t2"], knownRows: rows)
    XCTAssertEqual(deltas, existing)
    XCTAssertEqual(deltas, [
      "a1": delta(balance: 10_000, cleared: 10_000),
      "savings": delta(balance: -10_000, cleared: -10_000),
    ])

    let farSideUnloaded = OutboxPlanner.balanceDeltas(
      [command(.delete(expectedApproved: nil), base: transfer)],
      rowsByID: ["t1": transfer]
    )
    XCTAssertEqual(
      farSideUnloaded,
      DeleteBalanceDelta.deltas(deleted: transfer, removedIDs: ["t1", "t2"], knownRows: ["t1": transfer])
    )
  }

  func testDeletingASplitMirrorLeavesTheParentAccountAlone() {
    // The mirrored side of a split line names the parent's account as its
    // transfer, but the server keeps the parent line when the mirror goes.
    let mirror = row(
      "m1", account: "savings", amount: 60_000, cleared: .cleared,
      transferAccountID: "everyday", transferTransactionID: "line-savings",
      parentTransactionID: "parent"
    )
    let deltas = OutboxPlanner.balanceDeltas(
      [command(.delete(expectedApproved: nil), id: "m1", base: mirror)],
      rowsByID: ["m1": mirror]
    )
    XCTAssertEqual(deltas, ["savings": delta(balance: -60_000, cleared: -60_000)])
    XCTAssertEqual(
      deltas,
      DeleteBalanceDelta.deltas(deleted: mirror, removedIDs: ["m1"], knownRows: ["m1": mirror])
    )
  }

  func testUpdateMovingAccountsShiftsTheWholeAmount() {
    let existing = row(account: "a1", amount: -10_000, cleared: .cleared)
    let deltas = OutboxPlanner.balanceDeltas(
      [command(.update(request(account: "a2", amount: -12_000)), base: existing)],
      rowsByID: ["t1": existing]
    )
    XCTAssertEqual(deltas, [
      "a1": delta(balance: 10_000, cleared: 10_000),
      "a2": delta(balance: -12_000, cleared: -12_000),
    ], "an edit that omits cleared keeps the row's status")
  }

  func testUpdatedTransferMovesTheFarSideToo() {
    let existing = row(
      account: "a1", amount: -10_000, payeeID: "p-savings",
      transferAccountID: "savings", transferTransactionID: "t2"
    )
    let deltas = OutboxPlanner.balanceDeltas(
      [command(.update(request(amount: -15_000, payeeID: "p-savings")), base: existing)],
      rowsByID: ["t1": existing]
    )
    XCTAssertEqual(deltas, [
      "a1": delta(balance: -5_000, uncleared: -5_000),
      "savings": delta(balance: 5_000, uncleared: 5_000),
    ])

    let retargeted = OutboxPlanner.balanceDeltas(
      [command(.update(request(amount: -10_000, payeeID: "p-card")), base: existing)],
      rowsByID: ["t1": existing],
      transferAccountIDsByPayeeID: ["p-card": "card", "p-savings": "savings"]
    )
    XCTAssertEqual(retargeted, [
      "savings": delta(balance: -10_000, uncleared: -10_000),
      "card": delta(balance: 10_000, uncleared: 10_000),
    ])
  }

  func testClearedToggleMovesBetweenBucketsWithoutChangingTheBalance() {
    let existing = row(amount: -10_000, cleared: .uncleared)
    let deltas = OutboxPlanner.balanceDeltas(
      [command(.cleared(expected: .uncleared, cleared: .cleared, approve: false), base: existing)],
      rowsByID: ["t1": existing]
    )
    XCTAssertEqual(deltas, ["a1": delta(balance: 0, cleared: -10_000, uncleared: 10_000)])
  }

  func testClearedToggleOnATransferLeavesTheFarSideAlone() {
    let existing = row(
      amount: -10_000, cleared: .uncleared,
      transferAccountID: "savings", transferTransactionID: "t2"
    )
    let deltas = OutboxPlanner.balanceDeltas(
      [command(.cleared(expected: .uncleared, cleared: .cleared, approve: false), base: existing)],
      rowsByID: ["t1": existing]
    )
    XCTAssertEqual(deltas, ["a1": delta(balance: 0, cleared: -10_000, uncleared: 10_000)])
  }

  func testApprovalMovesNothingAndUnknownRowsAreSkipped() {
    XCTAssertEqual(OutboxPlanner.balanceDeltas([command(.approve, base: row())], rowsByID: ["t1": row()]), [:])
    XCTAssertEqual(OutboxPlanner.balanceDeltas([command(.update(request()))], rowsByID: [:]), [:])
  }

  func testChainedCommandsOnOneRowComposeAndCrossRowsSum() {
    let inFlightCreate = command(.create(request(amount: -10_000)), id: "n1", state: .inFlight)
    let queue = enqueueAll([
      command(.update(request(account: "a2", amount: -8_000)), id: "n1"),
      command(.create(request(amount: -1_000)), id: "n2"),
    ], onto: [inFlightCreate])
    let deltas = OutboxPlanner.balanceDeltas(queue, rowsByID: [:])
    XCTAssertEqual(deltas, [
      "a1": delta(balance: -1_000, uncleared: -1_000),
      "a2": delta(balance: -8_000, uncleared: -8_000),
    ])
  }

  func testCreateThenDeleteBehindInFlightNetsToZero() {
    let queue = enqueueAll(
      [command(.delete(expectedApproved: nil))],
      onto: [command(.create(request()), state: .inFlight)]
    )
    XCTAssertEqual(OutboxPlanner.balanceDeltas(queue, rowsByID: [:]), [:])
  }

  // MARK: - Attempted commands

  private func attempted(_ command: OutboxCommand) -> OutboxCommand {
    var command = command
    command.attempted = true
    command.seq = 1
    return command
  }

  func testNothingFoldsIntoAnAttemptedCreate() {
    // The server may hold it: a replay is answered from the import-id
    // dedupe with the row as first created, so a folded change would be lost.
    let create = attempted(command(.create(request(importID: "imp"))))
    for kind: OutboxCommand.Kind in [
      .update(request(amount: -2_000)),
      .cleared(expected: .uncleared, cleared: .cleared, approve: false),
      .approve,
    ] {
      let queue = OutboxPlanner.enqueue(command(kind), onto: [create])
      XCTAssertEqual(queue.count, 2, "\(kind) must queue behind the attempted create")
      XCTAssertEqual(queue[0], create)
      XCTAssertEqual(queue[1].kind, kind)
    }
  }

  func testAnAttemptedCreateIsNeverCancelledLocally() {
    let create = attempted(command(.create(request())))
    let queue = OutboxPlanner.enqueue(command(.delete(expectedApproved: nil)), onto: [create])
    XCTAssertEqual(queue.map(\.kind), [.create(request()), .delete(expectedApproved: nil)])
  }

  func testLaterChangesFoldTogetherBehindAnAttemptedCommand() {
    let create = attempted(command(.create(request())))
    let queue = enqueueAll([
      command(.update(request(amount: -2_000))),
      command(.update(request(amount: -3_000))),
      command(.approve),
    ], onto: [create])
    XCTAssertEqual(queue.count, 2)
    XCTAssertEqual(queue[1].kind, .update(request(amount: -3_000)))
  }

  func testAttemptedStatusChangesAreNotUndoneLocally() {
    let toggle = attempted(command(.cleared(expected: .uncleared, cleared: .cleared, approve: false)))
    let queue = OutboxPlanner.enqueue(
      command(.cleared(expected: .cleared, cleared: .uncleared, approve: false)),
      onto: [toggle]
    )
    XCTAssertEqual(queue.count, 2, "the first toggle may have landed, so toggling back is its own change")
    let edit = attempted(command(.update(request(amount: -1_000))))
    XCTAssertEqual(OutboxPlanner.enqueue(command(.update(request(amount: -2_000))), onto: [edit]).count, 2)
  }

  func testARowSendsOneCommandPerPassOldestFirst() {
    let create = attempted(command(.create(request())))
    let queue = OutboxPlanner.enqueue(command(.update(request(amount: -2_000))), onto: [create])
    let plan = OutboxPlanner.plan(queue)
    XCTAssertEqual(plan.batches.map(\.stage), [.create])
    XCTAssertEqual(plan.deferred.map(\.kind), [.update(request(amount: -2_000))])
  }

  func testARefusedCreateHoldsBackItsChangesButNotADelete() {
    var refused = attempted(command(.create(request())))
    refused.state = .rejected(message: "Gone", code: 410)
    let withEdit = OutboxPlanner.enqueue(command(.update(request(amount: -2_000))), onto: [refused])
    XCTAssertEqual(OutboxPlanner.plan(withEdit).batches, [])
    let withDelete = OutboxPlanner.enqueue(command(.delete(expectedApproved: nil)), onto: [refused])
    XCTAssertEqual(OutboxPlanner.plan(withDelete).batches.map(\.stage), [.delete])
  }

  func testAttemptFlagsSurviveJSONAndDefaultToFalse() throws {
    var sent = command(.create(request()))
    sent.attempted = true
    sent.sentWithClientID = true
    let decoded = try JSONDecoder().decode(OutboxCommand.self, from: JSONEncoder().encode(sent))
    XCTAssertTrue(decoded.attempted)
    XCTAssertTrue(decoded.sentWithClientID)

    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sent)) as? [String: Any])
    object["attempted"] = nil
    object["sentWithClientID"] = nil
    let older = try JSONDecoder().decode(OutboxCommand.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertFalse(older.attempted)
    XCTAssertFalse(older.sentWithClientID)
  }

  // MARK: - Codable

  func testCommandsRoundTripThroughJSON() throws {
    let commands = [
      command(.create(request(cleared: .cleared, importID: "imp"))),
      command(.update(request(payeeID: "p", memo: "m")), base: row()),
      command(.cleared(expected: .uncleared, cleared: .cleared, approve: true), state: .inFlight),
      command(.approve, state: .rejected(message: "No", code: 400)),
      command(.delete(expectedApproved: false), state: .rejected(message: "Gone", code: nil)),
      command(.delete(expectedApproved: nil)),
    ]
    let data = try JSONEncoder().encode(commands)
    XCTAssertEqual(try JSONDecoder().decode([OutboxCommand].self, from: data), commands)
  }
}

/// A seeded generator so a failing random sequence reproduces.
private struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
