// What the register shows while outbox commands wait. See
// docs/plans/offline-writes.md P1.
//
// A pure projection: server rows in, the rows as they will be once every
// queued, in-flight or rejected command lands. Nothing here is persisted; the
// outbox is the record, and discarding a command simply drops its effect.

import Foundation

enum OutboxOverlay {
  /// Name lookups for rows an edit points at new accounts, payees or
  /// categories. The server fills these in; until it answers, the local
  /// reference data does.
  struct Names {
    var accountName: (String) -> String? = { _ in nil }
    var categoryName: (String) -> String? = { _ in nil }
    var payeeName: (String) -> String? = { _ in nil }
    var transferAccountID: (String) -> String? = { _ in nil }
  }

  /// `rows` with every command's effect applied, in the register's order.
  /// A queued delete hides the row and, like the server, its transfer's other
  /// side; deleting the mirrored side of a split line keeps the parent and
  /// only unlinks its line.
  static func apply(_ commands: [OutboxCommand], to rows: [Transaction], names: Names) -> [Transaction] {
    guard !commands.isEmpty, !rows.isEmpty else {
      return rows
    }
    let byRow = Dictionary(grouping: commands.sorted { $0.seq < $1.seq }, by: \.transactionID)
    var removed: Set<String> = []
    var unlinks: [SplitMirrorLink] = []
    var mirrorEdits: [String: Transaction] = [:]
    var reordered = false

    var next = rows.map { row -> Transaction in
      guard let rowCommands = byRow[row.id] else {
        return row
      }
      var current = row
      for command in rowCommands {
        switch command.kind {
        case .create:
          continue
        case .update(let request):
          let edited = applying(request, to: current, names: names)
          reordered = reordered || edited.date != current.date
          current = edited
        case .cleared(_, let cleared, let approve):
          current = current.withCleared(cleared)
          if approve, !current.approved {
            current = current.withApproved(true)
          }
        case .approve:
          if !current.approved {
            current = current.withApproved(true)
          }
        case .delete:
          let link = SplitMirrorLink(
            id: row.id,
            parentTransactionID: row.parentTransactionID,
            transferTransactionID: row.transferTransactionID
          )
          removed.insert(row.id)
          if row.parentTransactionID == nil {
            removed.formUnion(row.linkedTransferIDs)
          }
          // A split parent whose line names this row forgets it; a row that
          // is not a split mirror matches no line and changes nothing. A
          // legacy mirror without parent metadata is found by its line.
          unlinks.append(link)
        }
      }
      if current.subtransactions.isEmpty,
         let mirrorID = current.transferTransactionID,
         mirrorID == row.transferTransactionID,
         current.amount != row.amount || current.date != row.date || current.memo != row.memo {
        mirrorEdits[mirrorID] = current
      }
      return current
    }

    if !mirrorEdits.isEmpty {
      next = next.map { row in
        guard let source = mirrorEdits[row.id], byRow[row.id] == nil else {
          return row
        }
        reordered = reordered || source.date != row.date
        return row.mirroring(source)
      }
    }
    if !removed.isEmpty {
      next.removeAll { removed.contains($0.id) }
    }
    for link in unlinks {
      next = SplitMirrorUnlink.applying(link, to: next)
    }
    if reordered {
      next.sort { ($0.date, $0.id) > ($1.date, $1.id) }
    }
    return next
  }

  /// The row as a full-body edit will leave it. Fields the request does not
  /// carry (links, import metadata) keep the row's values.
  static func applying(_ request: TransactionWriteRequest, to row: Transaction, names: Names) -> Transaction {
    let isSplit = !request.subtransactions.isEmpty
    let samePayee = request.payeeID == row.payeeID
    let transferAccountID: String? = isSplit
      ? nil
      : request.payeeID.flatMap(names.transferAccountID) ?? (samePayee ? row.transferAccountID : nil)
    let transferTransactionID = transferAccountID != nil && transferAccountID == row.transferAccountID
      ? row.transferTransactionID
      : nil
    let categoryID = isSplit ? (row.isSplit ? row.categoryID : nil) : request.categoryID
    let categoryName: String? = {
      if isSplit {
        return row.isSplit ? row.categoryName : "Split"
      }
      return request.categoryID.flatMap { names.categoryName($0) ?? (request.categoryID == row.categoryID ? row.categoryName : nil) }
    }()
    let payeeName = request.payeeName
      ?? request.payeeID.flatMap(names.payeeName)
      ?? (samePayee ? row.payeeName : nil)
    let lines = request.subtransactions.enumerated().map { index, line in
      Subtransaction(
        id: line.id ?? "\(row.id)-pending-\(index)",
        transactionID: row.id,
        amount: line.amount,
        memo: line.memo,
        payeeID: line.payeeID,
        payeeName: line.payeeName ?? line.payeeID.flatMap(names.payeeName),
        categoryID: line.categoryID,
        categoryName: line.categoryID.flatMap(names.categoryName),
        transferAccountID: line.transferAccountID,
        transferTransactionID: line.transferTransactionID,
        deleted: false
      )
    }
    return Transaction(
      id: row.id,
      date: request.date,
      amount: request.amount,
      memo: request.memo,
      cleared: request.cleared ?? row.cleared,
      approved: request.approved || row.approved,
      flagColor: request.flagColor,
      flagName: request.flagColor == row.flagColor ? row.flagName : nil,
      accountID: request.accountID,
      accountName: names.accountName(request.accountID)
        ?? (request.accountID == row.accountID ? row.accountName : ""),
      payeeID: request.payeeID,
      payeeName: payeeName,
      categoryID: categoryID,
      categoryName: categoryName,
      transferAccountID: transferAccountID,
      transferTransactionID: transferTransactionID,
      parentTransactionID: row.parentTransactionID,
      matchedTransactionID: row.matchedTransactionID,
      importID: row.importID,
      importPayeeName: row.importPayeeName,
      importPayeeNameOriginal: row.importPayeeNameOriginal,
      deleted: row.deleted,
      subtransactions: lines
    )
  }
}

private extension Transaction {
  /// The far side of a whole-row transfer after its source was edited: the
  /// opposite amount, the same date and memo.
  func mirroring(_ source: Transaction) -> Transaction {
    Transaction(
      id: id,
      date: source.date,
      amount: -source.amount,
      memo: source.memo,
      cleared: cleared,
      approved: approved,
      flagColor: flagColor,
      flagName: flagName,
      accountID: accountID,
      accountName: accountName,
      payeeID: payeeID,
      payeeName: payeeName,
      categoryID: categoryID,
      categoryName: categoryName,
      transferAccountID: transferAccountID,
      transferTransactionID: transferTransactionID,
      parentTransactionID: parentTransactionID,
      matchedTransactionID: matchedTransactionID,
      importID: importID,
      importPayeeName: importPayeeName,
      importPayeeNameOriginal: importPayeeNameOriginal,
      deleted: deleted,
      subtransactions: subtransactions
    )
  }
}

/// Why a change could not be added to the outbox.
enum OutboxEnqueueRefusal: LocalizedError, Equatable {
  case rowIsBeingDeleted

  var errorDescription: String? {
    switch self {
    case .rowIsBeingDeleted:
      return "This transaction is waiting to be deleted. Discard that change in Accounts to edit it again."
    }
  }
}

extension OutboxCommand.Kind {
  var isCreate: Bool {
    if case .create = self {
      return true
    }
    return false
  }
}

extension OutboxCommand {
  /// True when landing this command approves a row the server still has
  /// unapproved. The "New" badge counts these as already approved.
  var carriesApproval: Bool {
    switch kind {
    case .approve:
      return true
    case .cleared(_, _, let approve):
      return approve
    case .update(let request):
      return request.approved && baseSnapshot?.approved == false
    case .create, .delete:
      return false
    }
  }

  /// The accounts this command's row touches: where it sits now and where it
  /// will sit, including a transfer's far side.
  var touchedAccountIDs: Set<String> {
    var ids: Set<String> = []
    if let base = baseSnapshot {
      ids.insert(base.accountID)
      if let far = base.transferAccountID {
        ids.insert(far)
      }
      ids.formUnion(base.subtransactions.compactMap(\.transferAccountID))
    }
    switch kind {
    case .create(let request), .update(let request):
      ids.insert(request.accountID)
      ids.formUnion(request.subtransactions.compactMap(\.transferAccountID))
    case .cleared, .approve, .delete:
      break
    }
    return ids
  }
}
