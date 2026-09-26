import Foundation

enum RegisterApproval {
  static let batchLimit = 100

  struct Row: Equatable, Sendable {
    let id: String
    let approved: Bool
    let deleted: Bool
  }

  struct Session: Equatable, Sendable {
    var confirmed: Set<String>
    var pending: Set<String>

    static let empty = Session(confirmed: [], pending: [])
  }

  struct Chunk: Equatable, Sendable {
    let ids: [String]

    var count: Int { ids.count }

    fileprivate init(ids: [String]) {
      self.ids = ids
    }
  }

  struct Plan: Equatable, Sendable {
    let chunks: [Chunk]

    var ids: [String] { chunks.flatMap(\.ids) }

    fileprivate init(chunks: [Chunk]) {
      self.chunks = chunks
    }
  }

  static func resolvedIDs(_ session: Session) -> Set<String> {
    session.pending.union(session.confirmed)
  }

  static func looksApproved(_ row: Row, session: Session) -> Bool {
    row.approved || resolvedIDs(session).contains(row.id)
  }

  static func eligibleIDs(in rows: [Row], session: Session = .empty) -> [String] {
    // Same test as `looksApproved`, with the union taken once, not per row.
    let resolved = resolvedIDs(session)
    return rows.compactMap { row in
      if row.approved || resolved.contains(row.id) || row.deleted {
        return nil
      }
      return row.id
    }
  }

  static func plan(submitted rows: [Row], session: Session = .empty) -> Plan? {
    plan(ids: rows.map(\.id), rows: rows, session: session)
  }

  static func plan(ids: [String], rows: [Row], session: Session = .empty) -> Plan? {
    let eligible = Set(eligibleIDs(in: rows, session: session))
    var planned: [String] = []
    var seen = Set<String>()
    for id in ids where eligible.contains(id) && seen.insert(id).inserted {
      planned.append(id)
    }
    guard !planned.isEmpty else {
      return nil
    }
    var chunks: [Chunk] = []
    var offset = 0
    while offset < planned.count {
      let end = min(offset + batchLimit, planned.count)
      chunks.append(Chunk(ids: Array(planned[offset..<end])))
      offset = end
    }
    return Plan(chunks: chunks)
  }

  static func begin(_ session: Session, ids: [String]) -> Session? {
    if ids.isEmpty || ids.contains(where: session.pending.contains) {
      return nil
    }
    var pending = session.pending
    pending.formUnion(ids)
    return Session(confirmed: session.confirmed, pending: pending)
  }

  static func finish(_ session: Session, ids: [String]) -> Session {
    var confirmed = session.confirmed
    var pending = session.pending
    for id in ids {
      pending.remove(id)
      confirmed.insert(id)
    }
    return Session(confirmed: confirmed, pending: pending)
  }

  static func fail(_ session: Session, ids: [String], approvedCount: Int) -> Session {
    var confirmed = session.confirmed
    var pending = session.pending
    for id in ids {
      pending.remove(id)
    }
    for id in ids.prefix(approvedCount) {
      confirmed.insert(id)
    }
    return Session(confirmed: confirmed, pending: pending)
  }

  static func approveSelectedLabel(_ count: Int) -> String {
    "Approve \(count) selected"
  }

  static func approveAllLabel(_ count: Int) -> String {
    "Approve all (\(count))"
  }

  static func approvedToast(_ count: Int) -> String {
    "\(count) transaction\(count == 1 ? "" : "s") approved."
  }

  static func interruptedToast(approvedCount: Int, uncertainCount: Int) -> String {
    "\(approvedToast(approvedCount)) \(uncertainCount) may not have been approved."
  }
}

extension Transaction {
  var approvalRow: RegisterApproval.Row {
    RegisterApproval.Row(id: id, approved: approved, deleted: deleted)
  }
}
