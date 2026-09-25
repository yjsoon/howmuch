// Not wired in yet — see docs/plans/offline-writes.md P1.
//
// One durable write waiting to reach the server. The outbox holds at most one
// command per transaction that is not in flight; `OutboxPlanner.enqueue`
// folds later changes into it. An in-flight command is never rewritten: a
// change made while it is on the wire queues behind it instead.

import Foundation

struct OutboxCommand: Codable, Equatable, Identifiable {
  enum Kind: Codable, Equatable {
    /// A new row. The request's `importID` is the replay key, so a create
    /// whose response was lost cannot post the money twice.
    case create(TransactionWriteRequest)
    /// A full-body edit. `cleared` is nil unless a cleared toggle was folded
    /// into it.
    case update(TransactionWriteRequest)
    /// The guarded compare-and-set status change. `approve` is true when an
    /// approval was folded in; it is sent as a follow-up approve once the
    /// status change lands.
    case cleared(expected: ClearedState, cleared: ClearedState, approve: Bool)
    case approve
    /// `expectedApproved` follows the register's convention: `false` guards
    /// an unapproved row, nil sends no guard.
    case delete(expectedApproved: Bool?)
  }

  enum State: Codable, Equatable {
    case queued
    case inFlight
    /// The server refused it (a 400, say). It stays on disk until the user
    /// retries or discards it.
    case rejected(message: String, code: Int?)
  }

  let id: UUID
  var seq: Int
  let transactionID: String
  let connectionFingerprint: String
  let createdAt: Date
  var kind: Kind
  var state: State
  /// The row as it was before the first queued change. Discard reverts to
  /// it; nil for a create, or for a command queued behind an in-flight create.
  var baseSnapshot: Transaction?

  init(
    id: UUID,
    seq: Int = 0,
    transactionID: String,
    connectionFingerprint: String,
    createdAt: Date,
    kind: Kind,
    state: State = .queued,
    baseSnapshot: Transaction? = nil
  ) {
    self.id = id
    self.seq = seq
    self.transactionID = transactionID
    self.connectionFingerprint = connectionFingerprint
    self.createdAt = createdAt
    self.kind = kind
    self.state = state
    self.baseSnapshot = baseSnapshot
  }

  var isInFlight: Bool {
    state == .inFlight
  }
}

extension TransactionWriteRequest {
  /// A copy with the status fields swapped. The planner uses it to fold a
  /// cleared toggle or an approval into a queued create or edit.
  func replacing(
    cleared: ClearedState?? = .none,
    approved: Bool? = nil,
    importID: String?? = .none
  ) -> TransactionWriteRequest {
    TransactionWriteRequest(
      accountID: accountID,
      date: date,
      amount: amount,
      payeeID: payeeID,
      payeeName: payeeName,
      categoryID: categoryID,
      memo: memo,
      cleared: cleared ?? self.cleared,
      approved: approved ?? self.approved,
      flagColor: flagColor,
      subtransactions: subtransactions,
      importID: importID ?? self.importID
    )
  }
}
