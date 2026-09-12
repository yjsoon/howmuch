import Foundation

/// One independently fetchable unit of server state. Slices exist at the
/// granularity of a *request cost*, not of a view: `/accounts` is a single GET
/// that already carries balances, while `.referenceData` is the five-request
/// batch (plan settings, accounts, categories, payees, account preferences)
/// and `.ledger` is the first transaction page plus the unapproved scan.
///
/// Refreshing after a write means naming the smallest set of slices the local
/// apply could not reproduce — see `RefreshPlanner`.
enum RefreshSlice: String, CaseIterable, Hashable, Sendable {
  /// `GET /v1/plans/{id}/accounts` — one request, carries every balance.
  case accounts
  /// `GET /v1/plans/{id}/payees` — one request.
  case payees
  /// The five-request reference batch. Reserved for changes a local apply
  /// plus the two slices above cannot reproduce.
  case referenceData
  /// First transaction page plus the unapproved queue scan.
  case ledger
  case schedules
  /// The four Reflect reports, gated by `ReportsRefreshPolicy`.
  case reports
}

/// Which slices each tab's pull-to-refresh owns. A tab refreshes what it
/// shows and nothing else, so pulling on Accounts never touches reports.
enum TabRefresh {
  /// Accounts shows balances and groupings. The New/Scheduled tile counts are
  /// deliberately left to their own panes rather than dragging the ledger
  /// scan onto every pull here.
  static let accounts: Set<RefreshSlice> = [.accounts]

  /// The Accounts placeholder for a failed or missing reference load lives
  /// inside the same scrollable view as the pull, so the pull is also the
  /// reader's retry for it. One GET of balances would leave categories,
  /// payees and plan settings missing, so an unloaded reference batch makes
  /// this pull fetch the batch instead.
  static func accounts(referencePhase: LoadPhase) -> Set<RefreshSlice> {
    referencePhase == .loaded ? accounts : [.referenceData]
  }
  /// The register shows the ledger page and, in the inbox scope, the
  /// unapproved queue — both come from the one `.ledger` slice.
  static let register: Set<RefreshSlice> = [.ledger]
  static let reflect: Set<RefreshSlice> = [.reports]
}

/// A write the app performed, described in the terms the refresh decision
/// needs. Payload flags exist only where the server response cannot carry the
/// whole effect back — a transfer writes a mirror row on the other account
/// that no single-transaction response returns.
enum MutationKind: Equatable, Sendable {
  case clearedToggled
  /// `changesAccount`: the row moved to a different account. `touchesTransfer`:
  /// the row is, was, or became one half of a transfer pair. `hasNewPayee`:
  /// the save named a payee the server had to provision.
  case transactionEdited(changesAccount: Bool, touchesTransfer: Bool, hasNewPayee: Bool)
  case transactionsCreated(hasTransfer: Bool, hasNewPayee: Bool)
  case transactionDeleted
  case transactionsApproved
  case accountCreated
  case accountUpdated
  case accountReconciled
  case scheduleSaved
  case scheduleDeleted
  case scheduledOccurrenceEntered(isTransfer: Bool)
}

/// The functional core of #179: mutation kind in, set of slices to refetch
/// out. Every rule here assumes the caller has already applied the server's
/// returned row(s) locally; a slice is listed only for state the response
/// could not carry back.
enum RefreshPlanner {
  static func slices(after mutation: MutationKind) -> Set<RefreshSlice> {
    switch mutation {
    // The PATCH returns the saved row; only the account's cleared/uncleared
    // balances are recomputed server-side. One follow-up GET, no more.
    case .clearedToggled:
      return [.accounts]

    // The PATCH returns the edited row. Balances move, so accounts must be
    // refetched; a transfer's mirror row and a row that changed account both
    // leave ledger state the response cannot describe.
    case .transactionEdited(let changesAccount, let touchesTransfer, let hasNewPayee):
      var slices: Set<RefreshSlice> = [.accounts]
      if changesAccount || touchesTransfer {
        slices.insert(.ledger)
      }
      if hasNewPayee {
        slices.insert(.payees)
      }
      return slices

    // Created rows are inserted from their POST responses. A transfer's
    // mirror row is not returned, and a payee created by name is not in the
    // local payee list.
    case .transactionsCreated(let hasTransfer, let hasNewPayee):
      var slices: Set<RefreshSlice> = [.accounts]
      if hasTransfer {
        slices.insert(.ledger)
      }
      if hasNewPayee {
        slices.insert(.payees)
      }
      return slices

    // The delete path already removes the row and every linked transfer id
    // it knows about, so only balances need refetching.
    case .transactionDeleted:
      return [.accounts]

    // Approval flips a flag. It moves no money, so nothing needs refetching;
    // the approved ids are applied locally as each batch succeeds.
    case .transactionsApproved:
      return []

    // The POST returns the new account, which the caller inserts. The server
    // also provisions the account's "Transfer : …" payee, which it does not
    // return; it holds no opening-balance transaction, so the ledger is
    // untouched.
    case .accountCreated:
      return [.payees]

    // The PATCH returns the updated account and the transfer payee rename is
    // mirrored locally, so nothing is left to fetch.
    case .accountUpdated:
      return []

    // Reconciling flips many rows to reconciled and can write an adjustment
    // transaction; the response names the ids but returns no rows. Its
    // `account` payload is applied directly, so no accounts GET is needed.
    case .accountReconciled:
      return [.ledger]

    // Both responses carry the saved (or deleted) schedule, which the caller
    // applies to the local list.
    case .scheduleSaved, .scheduleDeleted:
      return []

    // The response carries both the created transaction and the advanced
    // schedule; only balances, and a transfer's mirror row, are left.
    case .scheduledOccurrenceEntered(let isTransfer):
      return isTransfer ? [.accounts, .ledger] : [.accounts]
    }
  }

  /// Whether the mutation can change a plan month or a Reflect report, and so
  /// must invalidate their lazily reloaded snapshots. These are markers, not
  /// fetches: the destinations reload when they next become visible.
  static func invalidatesPlanAndReports(after mutation: MutationKind) -> Bool {
    switch mutation {
    // Clearing moves no money and changes no category assignment: the plan
    // and every report read amounts, not cleared state.
    case .clearedToggled, .transactionsApproved, .accountUpdated,
         .scheduleSaved, .scheduleDeleted:
      return false
    case .transactionEdited, .transactionsCreated, .transactionDeleted,
         .accountCreated, .accountReconciled, .scheduledOccurrenceEntered:
      return true
    }
  }
}

/// One coalesced refresh request. `quiet` suppresses the loading phases (a
/// background refresh must not blank a loaded view); `force` overrides the
/// reports knowledge gate for an explicit pull-to-refresh.
struct RefreshRequest: Equatable, Sendable {
  var slices: Set<RefreshSlice>
  var quiet: Bool
  var force: Bool

  init(slices: Set<RefreshSlice>, quiet: Bool = true, force: Bool = false) {
    self.slices = RefreshRequest.normalised(slices)
    self.quiet = quiet
    self.force = force
  }

  static let none = RefreshRequest(slices: [], quiet: true, force: false)

  var isEmpty: Bool { slices.isEmpty }

  /// `.referenceData` already fetches accounts and payees, so keeping the
  /// narrower slices alongside it would duplicate requests.
  static func normalised(_ slices: Set<RefreshSlice>) -> Set<RefreshSlice> {
    guard slices.contains(.referenceData) else {
      return slices
    }
    return slices.subtracting([.accounts, .payees])
  }

  /// The debounce rule: while a refresh is in flight, later requests merge
  /// into a single queued request that runs once when it finishes. The union
  /// of slices is kept, and the loudest intent wins — one non-quiet or forced
  /// caller makes the merged request non-quiet or forced.
  func merging(_ other: RefreshRequest) -> RefreshRequest {
    RefreshRequest(
      slices: slices.union(other.slices),
      quiet: quiet && other.quiet,
      force: force || other.force
    )
  }
}

/// #180 (iOS half): the four reports are no longer fired on launch. They are
/// fetched when Reflect appears, and skipped when nothing can have changed
/// since the last successful fetch.
///
/// Staleness has two signals, because one alone is blind in one direction:
/// `serverKnowledge` is the plan cursor observed on ledger fetches and catches
/// changes made elsewhere, while `mutationGeneration`
/// (`AppModel.reportsRefreshGeneration`) catches this device's own writes,
/// which are applied locally and never re-read the ledger.
enum ReportsRefreshPolicy {
  static func shouldFetch(
    phase: LoadPhase,
    force: Bool,
    lastKnowledge: Int?,
    currentKnowledge: Int?,
    lastMutationGeneration: Int?,
    currentMutationGeneration: Int
  ) -> Bool {
    if phase == .loading {
      return false
    }
    if force {
      return true
    }
    if phase != .loaded {
      return true
    }
    // A stamped generation, not a stamped cursor, is what proves the reports
    // were ever loaded: a plan whose ledger has not been read yet has no
    // cursor to stamp, and that absence must not force a refetch every visit.
    guard let lastMutationGeneration else {
      return true
    }
    if lastMutationGeneration != currentMutationGeneration {
      return true
    }
    return currentKnowledge != lastKnowledge
  }
}
