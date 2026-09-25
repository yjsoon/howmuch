// Not wired in yet — see docs/plans/offline-writes.md P1.
//
// The functional core of the offline outbox: how a new change folds into the
// queue, what a replay pass sends and in which order, what each server answer
// means for the command, and how queued changes move the balances on screen.
// No IO, no clock, no ids minted here: callers pass them in.

import Foundation

enum OutboxPlanner {
  // MARK: - Coalescing

  /// Adds `incoming` to `queue`, folding it into the transaction's queued
  /// command when there is one. Keeps at most one command per transaction
  /// that is not in flight, and never rewrites an in-flight command: a change
  /// made while one is on the wire queues behind it as a dependent.
  static func enqueue(_ incoming: OutboxCommand, onto queue: [OutboxCommand]) -> [OutboxCommand] {
    let sameRow = queue.filter { $0.transactionID == incoming.transactionID }
    // A row on its way out takes no further changes, and a create for an id
    // already in the outbox is a replay of the same capture.
    if sameRow.contains(where: { if case .delete = $0.kind { return true }; return false }) {
      return queue
    }
    if case .create = incoming.kind, !sameRow.isEmpty {
      return queue
    }

    var next = queue
    guard let index = next.lastIndex(where: {
      $0.transactionID == incoming.transactionID && !$0.isInFlight
    }) else {
      var appended = incoming
      appended.seq = (queue.map(\.seq).max() ?? 0) + 1
      appended.state = .queued
      next.append(appended)
      return next
    }

    let existing = next[index]
    guard let kind = merged(existing, incoming) else {
      next.remove(at: index)
      return next
    }
    var folded = existing
    folded.kind = kind
    folded.state = .queued
    next[index] = folded
    return next
  }

  /// The kind the queued command becomes once `incoming` is folded in, or
  /// nil when the two cancel out.
  private static func merged(_ existing: OutboxCommand, _ incoming: OutboxCommand) -> OutboxCommand.Kind? {
    let base = existing.baseSnapshot
    switch (existing.kind, incoming.kind) {
    case (.delete, _), (_, .create):
      return existing.kind

    case (.create, .delete):
      return nil
    case (_, .delete(let expectedApproved)):
      // Guard against the row as the server last had it, not as edited here.
      return .delete(expectedApproved: base.map { $0.approved ? nil : false } ?? expectedApproved)

    case (.create(let request), .update(let edit)):
      return .create(edit.replacing(
        cleared: .some(edit.cleared ?? request.cleared),
        importID: .some(request.importID ?? edit.importID)
      ))
    case (.create(let request), .cleared(_, let cleared, let approve)):
      return .create(request.replacing(cleared: .some(cleared), approved: approve ? true : nil))
    case (.create(let request), .approve):
      return .create(request.replacing(approved: true))

    case (.update(let request), .update(let edit)):
      return .update(edit.cleared == nil ? edit.replacing(cleared: .some(request.cleared)) : edit)
    case (.update(let request), .cleared(_, let cleared, let approve)):
      let carried: ClearedState? = cleared == base?.cleared ? nil : cleared
      return .update(request.replacing(cleared: .some(carried), approved: approve ? true : nil))
    case (.update(let request), .approve):
      return .update(request.replacing(approved: true))

    case (.cleared(let expected, let cleared, let approve), .update(let edit)):
      let carried = edit.cleared ?? (cleared == expected ? nil : cleared)
      return .update(edit.replacing(cleared: .some(carried), approved: approve ? true : nil))
    case (.cleared(let expected, _, let approve), .cleared(_, let cleared, let alsoApprove)):
      if cleared == expected {
        return approve || alsoApprove ? .approve : nil
      }
      return .cleared(expected: expected, cleared: cleared, approve: approve || alsoApprove)
    case (.cleared(let expected, let cleared, _), .approve):
      return .cleared(expected: expected, cleared: cleared, approve: true)

    case (.approve, .update(let edit)):
      return .update(edit.replacing(approved: true))
    case (.approve, .cleared(let expected, let cleared, _)):
      return .cleared(expected: expected, cleared: cleared, approve: true)
    case (.approve, .approve):
      return .approve
    }
  }

  // MARK: - Replay

  enum Stage: Int, CaseIterable, Comparable {
    case create
    case update
    case cleared
    case approve
    case delete

    static func < (lhs: Stage, rhs: Stage) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  struct Batch: Equatable {
    let stage: Stage
    let commands: [OutboxCommand]
  }

  struct Plan: Equatable {
    /// Non-empty batches in send order: creates, updates, cleared (bulk),
    /// approve (batch), delete (bulk). Each batch is in queue order.
    let batches: [Batch]
    /// Queued behind an in-flight command for the same row; they go on the
    /// next pass, once that command has settled.
    let deferred: [OutboxCommand]
  }

  /// What one replay pass sends. In-flight commands are already on the
  /// wire and rejected ones wait for Retry, so neither is planned.
  static func plan(_ queue: [OutboxCommand]) -> Plan {
    let busy = Set(queue.filter(\.isInFlight).map(\.transactionID))
    var ready: [Stage: [OutboxCommand]] = [:]
    var deferred: [OutboxCommand] = []
    for command in queue.sorted(by: { $0.seq < $1.seq }) where command.state == .queued {
      if busy.contains(command.transactionID) {
        deferred.append(command)
      } else {
        ready[stage(of: command.kind), default: []].append(command)
      }
    }
    let batches = Stage.allCases.compactMap { stage -> Batch? in
      guard let commands = ready[stage], !commands.isEmpty else { return nil }
      return Batch(stage: stage, commands: commands)
    }
    return Plan(batches: batches, deferred: deferred)
  }

  static func stage(of kind: OutboxCommand.Kind) -> Stage {
    switch kind {
    case .create: return .create
    case .update: return .update
    case .cleared: return .cleared
    case .approve: return .approve
    case .delete: return .delete
    }
  }

  // MARK: - Outcomes

  /// A server answer, reduced to what the outbox acts on.
  enum ServerResult: Equatable {
    case succeeded
    /// No connection, a timeout, or any other transport failure.
    case offline
    case status(Int, message: String)
  }

  enum Action: Equatable {
    /// Drop the command; the server has what it asked for.
    case complete
    /// The first half landed; keep the command queued as this kind.
    case continueAs(OutboxCommand.Kind)
    /// Leave it queued for the next pass.
    case retryLater
    /// The row changed underneath; read it again and compare before deciding.
    case refetchAndCompare
    /// Keep it on disk as rejected, with Retry and Discard.
    case reject(message: String, code: Int)
  }

  static func action(for kind: OutboxCommand.Kind, result: ServerResult) -> Action {
    switch result {
    case .succeeded:
      if case .cleared(_, _, true) = kind {
        return .continueAs(.approve)
      }
      return .complete
    case .offline:
      return .retryLater
    case .status(let code, let message):
      switch (kind, code) {
      case (.delete, 404):
        return .complete
      case (.cleared, 409):
        return .refetchAndCompare
      // Signed out, rate-limited or a server fault: not this command's
      // doing, so it waits rather than being marked rejected.
      case (_, 401), (_, 408), (_, 429), (_, 500...):
        return .retryLater
      default:
        return .reject(message: message, code: code)
      }
    }
  }

  // MARK: - Balances

  /// How the queued commands move each account's cleared and uncleared
  /// balances, relative to `rowsByID` (the rows as the server last sent
  /// them). Commands in any state count: a rejected command still shows until
  /// it is discarded, and an acknowledged one should stay applied until the
  /// accounts are read again.
  ///
  /// Transfers put the opposite amount on the other account. An existing
  /// row names that account; a request names only a payee, so
  /// `transferAccountIDsByPayeeID` resolves it. Without it, a new transfer
  /// counts on its own account only. A far side not in `rowsByID` counts as
  /// uncleared, as `DeleteBalanceDelta` does.
  static func balanceDeltas(
    _ commands: [OutboxCommand],
    rowsByID: [String: Transaction],
    transferAccountIDsByPayeeID: [String: String] = [:]
  ) -> [String: DeleteBalanceDelta.Delta] {
    var result: [String: DeleteBalanceDelta.Delta] = [:]
    func add(_ shape: Shape?, sign: Int) {
      for posting in shape?.postings ?? [] {
        var delta = result[posting.accountID, default: DeleteBalanceDelta.Delta()]
        let amount = sign * posting.amount
        delta.balance += amount
        if posting.cleared == .uncleared {
          delta.uncleared += amount
        } else {
          delta.cleared += amount
        }
        result[posting.accountID] = delta
      }
    }

    let byRow = Dictionary(grouping: commands.sorted { $0.seq < $1.seq }, by: \.transactionID)
    for id in byRow.keys.sorted() {
      let rowCommands = byRow[id] ?? []
      let known = rowsByID[id] ?? rowCommands.lazy.compactMap(\.baseSnapshot).first
      let before = known.flatMap { Shape(row: $0, rowsByID: rowsByID) }
      var after = before
      var isKnown = before != nil
      for command in rowCommands {
        switch command.kind {
        case .create(let request):
          after = Shape(request: request, previous: nil, payees: transferAccountIDsByPayeeID)
          isKnown = true
        case .update(let request):
          guard let previous = after else { continue }
          after = Shape(request: request, previous: previous, payees: transferAccountIDsByPayeeID)
        case .cleared(_, let cleared, _):
          after?.cleared = cleared
        case .approve:
          break
        case .delete:
          after = nil
        }
      }
      // An edit to a row we have never seen has nothing to measure against.
      guard isKnown else { continue }
      add(before, sign: -1)
      add(after, sign: 1)
    }
    return result.filter { $0.value != DeleteBalanceDelta.Delta() }
  }

  /// The parts of a row that touch balances.
  private struct Shape {
    struct Mirror {
      let accountID: String
      let transactionID: String?
      let amount: Int
      let cleared: ClearedState
    }

    var accountID: String
    var amount: Int
    var cleared: ClearedState
    var payeeID: String?
    /// The far side of a whole-row transfer.
    var transfer: Mirror?
    /// The far sides of split lines that are transfers.
    var lineTransfers: [Mirror]

    var postings: [Mirror] {
      let own = Mirror(accountID: accountID, transactionID: nil, amount: amount, cleared: cleared)
      return [own] + [transfer].compactMap { $0 } + lineTransfers
    }

    init?(row: Transaction, rowsByID: [String: Transaction]) {
      guard !row.deleted else { return nil }
      func farCleared(_ id: String?) -> ClearedState {
        id.flatMap { rowsByID[$0]?.cleared } ?? .uncleared
      }
      accountID = row.accountID
      amount = row.amount
      cleared = row.cleared
      payeeID = row.payeeID
      transfer = row.transferAccountID.map {
        Mirror(
          accountID: $0,
          transactionID: row.transferTransactionID,
          amount: -row.amount,
          cleared: farCleared(row.transferTransactionID)
        )
      }
      lineTransfers = row.subtransactions.compactMap { line in
        guard !line.deleted, let accountID = line.transferAccountID else { return nil }
        return Mirror(
          accountID: accountID,
          transactionID: line.transferTransactionID,
          amount: -line.amount,
          cleared: farCleared(line.transferTransactionID)
        )
      }
    }

    /// The row after `request` lands on `previous` (nil for a create). An
    /// edit that omits `cleared` keeps the row's status; a far side that
    /// survives the edit keeps its own.
    init(request: TransactionWriteRequest, previous: Shape?, payees: [String: String]) {
      accountID = request.accountID
      amount = request.amount
      cleared = request.cleared ?? previous?.cleared ?? .uncleared
      payeeID = request.payeeID
      if request.subtransactions.isEmpty {
        let target = request.payeeID.flatMap { payees[$0] }
          ?? (request.payeeID == previous?.payeeID ? previous?.transfer?.accountID : nil)
        let kept = previous?.transfer?.accountID == target ? previous?.transfer : nil
        transfer = target.map {
          Mirror(
            accountID: $0,
            transactionID: kept?.transactionID,
            amount: -request.amount,
            cleared: kept?.cleared ?? .uncleared
          )
        }
      } else {
        transfer = nil
      }
      lineTransfers = request.subtransactions.compactMap { line in
        guard let accountID = line.transferAccountID else { return nil }
        let kept = previous?.lineTransfers.first {
          $0.transactionID != nil && $0.transactionID == line.transferTransactionID
        }
        return Mirror(
          accountID: accountID,
          transactionID: line.transferTransactionID,
          amount: -line.amount,
          cleared: kept?.cleared ?? .uncleared
        )
      }
    }
  }
}
