import Foundation
import Observation

extension InboxItem {
  /// Share-sheet entries become intake jobs. Every other source (App Intents,
  /// the clipboard offer) keeps the conversation flow.
  var isIntakeJobSource: Bool {
    source == .shareSheet
  }
}

/// Turns share-sheet entries into jobs, reads them on device, proposes what to
/// add or fix, and applies what the owner approves. Reading never writes to the
/// ledger: only `approve` does, through `AppModel.commit` and the outbox.
@MainActor
@Observable
final class IntakeCoordinator {
  static let shared = IntakeCoordinator()

  /// Newest first, without discarded jobs.
  private(set) var jobs: [IntakeJob] = []

  @ObservationIgnored private let inbox: InboxStore
  @ObservationIgnored private let store: IntakeJobStore
  @ObservationIgnored private var processing: Set<UUID> = []

  /// Applied and discarded jobs are kept this long, then pruned.
  private static let retention: TimeInterval = 30 * 24 * 3600

  init(inbox: InboxStore = .shared, store: IntakeJobStore = .shared) {
    self.inbox = inbox
    self.store = store
    reload()
  }

  // MARK: Reading the list

  func job(_ id: UUID) -> IntakeJob? {
    jobs.first { $0.id == id }
  }

  /// Jobs waiting on the owner: Ready to review plus Needs you.
  var attentionCount: Int {
    jobs.count { $0.state == .proposed || $0.state == .needsYou }
  }

  /// The most urgent jobs first, for the Accounts band.
  var mostUrgent: [IntakeJob] {
    jobs.sorted { lhs, rhs in
      if lhs.urgencyRank != rhs.urgencyRank { return lhs.urgencyRank < rhs.urgencyRank }
      return lhs.createdAt > rhs.createdAt
    }
  }

  func thumbnailSource(for job: IntakeJob) -> [InboxItem] {
    [InboxItem(
      id: job.id,
      source: .shareSheet,
      sources: job.sourceFiles,
      directory: store.sourcesDirectory(for: job.id),
      createdAt: job.createdAt
    )]
  }

  func reload() {
    jobs = store.list().filter { $0.state != .discarded }
  }

  // MARK: Draining the inbox

  /// Claims share-sheet entries, makes a job for each, and reads every job that
  /// still needs reading (including one a killed app left half done). Safe to
  /// call from several places at once: a job is only ever read by one caller.
  func drain(model: AppModel) async {
    guard model.settings.isAuthenticated else {
      return
    }
    adoptInbox()
    prune()
    let pending = jobs
      .filter { ($0.state == .reading || $0.state == .queued) && !processing.contains($0.id) }
      .sorted { $0.createdAt < $1.createdAt }
    for job in pending {
      await process(job.id, model: model)
    }
  }

  /// Moves claimed `Reading/` entries into `Jobs/`. Also picks up entries an
  /// earlier launch claimed but never turned into a job.
  private func adoptInbox() {
    _ = try? inbox.claimInbox(where: { $0.isIntakeJobSource })
    for item in inbox.loadReading(where: { $0.isIntakeJobSource }) {
      guard (try? store.adopt(item)) != nil else {
        continue
      }
      inbox.discardReading(item.id)
    }
    reload()
  }

  private func prune() {
    let cutoff = Date().addingTimeInterval(-Self.retention)
    for job in store.list() where job.updatedAt < cutoff && (job.state == .applied || job.state == .discarded) {
      store.delete(job.id)
    }
    reload()
  }

  // MARK: Reading a job

  private func process(_ id: UUID, model: AppModel) async {
    guard processing.insert(id).inserted, var job = self.job(id) else {
      return
    }
    defer { processing.remove(id) }

    guard await awaitReferenceData(model) else {
      job.state = .failed
      job.failureMessage = CaptureAdmissionGate.stalledMessage
      save(job)
      return
    }
    job.state = .reading
    job.failureMessage = nil
    save(job)

    let accounts = model.openAccounts
    var extracted: [SlipMappedDraft] = []
    var readAnyText = false
    for file in job.sourceFiles {
      let url = store.sourceURL(file, jobID: id)
      guard FileManager.default.fileExists(atPath: url.path) else {
        continue
      }
      let text = await recognise(file, at: url)
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        readAnyText = true
      }
      extracted.append(contentsOf: await SlipReader.shared.interpret(
        text: text,
        accounts: accounts,
        categoryGroups: model.categoryGroups,
        payees: model.payees
      ))
    }

    guard !extracted.isEmpty else {
      job.state = .failed
      job.failureMessage = readAnyText
        ? "Couldn’t read this. No transactions were found."
        : "Couldn’t read this. No text was found."
      save(job)
      return
    }

    let openIDs = Set(accounts.map(\.id))
    var needsYouMessage: String?
    if job.decideAccount {
      if extracted.contains(where: { $0.draft.accountID.isEmpty }) {
        needsYouMessage = "Couldn’t tell which account this belongs to."
      }
    } else if let chosen = job.accountID, !openIDs.contains(chosen) {
      needsYouMessage = "The account you chose is closed. Choose another."
    } else {
      let preferred = job.accountID ?? model.lastUsedOpenAccountID
      for index in extracted.indices where extracted[index].draft.accountID.isEmpty {
        extracted[index].draft.seedIfNeeded(accounts: accounts, preferredAccountID: preferred)
      }
    }

    job.extractions = extracted
    job.proposals = await propose(extracted, hint: job.hint, model: model)
    job.state = needsYouMessage == nil ? .proposed : .needsYou
    job.failureMessage = needsYouMessage
    save(job)
  }

  private func propose(_ extracted: [SlipMappedDraft], hint: IntakeHint, model: AppModel) async -> [IntakeProposal] {
    let matcher = IntakeMatcher()
    var candidates: [IntakeCandidateRow] = []
    // "New" in the share sheet means add everything as new.
    if hint != .new, let first = extracted.map(\.draft.date).min(), let last = extracted.map(\.draft.date).max() {
      let calendar = Calendar.current
      let from = calendar.date(byAdding: .day, value: -matcher.dayWindow, to: first) ?? first
      let to = calendar.date(byAdding: .day, value: matcher.dayWindow, to: last) ?? last
      candidates = await model.intakeCandidates(accountIDs: nil, from: from, to: to)
    }
    return matcher.match(extracted, openAccountIDs: Set(model.openAccounts.map(\.id)), candidates: candidates)
  }

  private func awaitReferenceData(_ model: AppModel) async -> Bool {
    if CaptureAdmissionGate.shouldRefreshReference(phase: model.referencePhase, explicitRetry: false) {
      await model.refreshAll(joinInFlight: true)
    }
    while true {
      switch CaptureAdmissionGate.referenceWait(
        referencePhase: model.referencePhase,
        isRefreshingAll: model.isRefreshingAll
      ) {
      case .admit:
        return true
      case .stalled:
        return false
      case .wait:
        try? await Task.sleep(for: .milliseconds(50))
        if Task.isCancelled {
          return false
        }
      }
    }
  }

  private func recognise(_ file: InboxSourceFile, at url: URL) async -> String {
    switch file.kind {
    case .image:
      let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
      guard let data else {
        return ""
      }
      return await SlipImageText.recognize(data)
    case .text:
      let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
      guard let data else {
        return ""
      }
      return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
    case .pdf:
      return await SlipPDFText.recognize(url).text
    }
  }

  // MARK: Decisions

  /// Applies every proposal Approve all covers (adds and fixes not rejected)
  /// through the normal commit path, then marks the job applied and deletes its
  /// files. Rows with no amount or account are skipped and the toast says so.
  @discardableResult
  func approve(_ id: UUID, model: AppModel) -> Bool {
    guard var job = self.job(id), job.state == .proposed else {
      return false
    }
    var drafts: [TransactionDraft] = []
    var applied: [UUID] = []
    var added = 0
    var fixed = 0
    var skipped = 0
    for proposal in job.proposals where proposal.appliesOnApproval {
      if proposal.kind == .edit {
        guard let target = proposal.targetTransactionID, let base = model.intakeTransaction(id: target) else {
          skipped += 1
          continue
        }
        drafts.append(Self.editDraft(for: proposal, base: base))
        fixed += 1
      } else {
        guard !proposal.isIncomplete else {
          skipped += 1
          continue
        }
        drafts.append(proposal.draft)
        added += 1
      }
      applied.append(proposal.id)
    }
    do {
      try model.commit(drafts)
    } catch {
      model.showSaveMessage(error.localizedDescription, kind: .failure)
      return false
    }
    for index in job.proposals.indices where applied.contains(job.proposals[index].id) {
      job.proposals[index].decision = .accepted
    }
    let summary = Self.appliedSummary(added: added, fixed: fixed)
    job.state = .applied
    job.failureMessage = nil
    job.appliedSummary = summary
    job.extractions = []
    store.deleteSources(id)
    save(job)
    var toast = summary
    if skipped > 0 {
      toast += ", \(skipped) skipped"
    }
    if !drafts.isEmpty {
      toast += " · Saved on device"
    }
    model.showSaveMessage(toast)
    return true
  }

  /// Rejects the batch: nothing is saved, and the shared files are deleted.
  func discard(_ id: UUID) {
    guard var job = self.job(id) else {
      return
    }
    for index in job.proposals.indices where job.proposals[index].decision == .pending {
      job.proposals[index].decision = .rejected
    }
    job.state = .discarded
    job.extractions = []
    store.deleteSources(id)
    save(job)
  }

  /// Reads a failed job again from the files it kept.
  func retry(_ id: UUID, model: AppModel) {
    guard var job = self.job(id), job.state == .failed else {
      return
    }
    job.state = .reading
    job.failureMessage = nil
    save(job)
    Task { await process(id, model: model) }
  }

  /// Sets the account on every line of a Needs you job and matches again.
  func assignAccount(_ accountID: String, to id: UUID, model: AppModel) async {
    guard var job = self.job(id), job.state == .needsYou,
          model.openAccounts.contains(where: { $0.id == accountID }) else {
      return
    }
    var extracted = job.extractions
    for index in extracted.indices {
      SlipAccountPick.apply(accountID, to: &extracted[index].draft)
    }
    job.accountID = accountID
    job.decideAccount = false
    job.extractions = extracted
    job.proposals = await propose(extracted, hint: job.hint, model: model)
    job.state = .proposed
    job.failureMessage = nil
    save(job)
  }

  /// Removes one finished job from the Inbox.
  func remove(_ id: UUID) {
    store.delete(id)
    reload()
  }

  func clearApplied() {
    for job in jobs where job.state == .applied {
      store.delete(job.id)
    }
    reload()
  }

  // MARK: Pure helpers

  /// The existing row with only the proposal's changed fields applied.
  static func editDraft(for proposal: IntakeProposal, base: Transaction) -> TransactionDraft {
    var draft = TransactionDraft(transaction: base)
    for field in proposal.changedFields {
      switch field {
      case .payee:
        draft.payeeID = proposal.draft.payeeID
        draft.payeeName = proposal.draft.payeeName
      case .category:
        draft.categoryID = proposal.draft.categoryID
      }
    }
    return draft
  }

  static func appliedSummary(added: Int, fixed: Int) -> String {
    var parts: [String] = []
    if added > 0 { parts.append("\(added) added") }
    if fixed > 0 { parts.append("\(fixed) fixed") }
    return parts.isEmpty ? "Nothing to add" : parts.joined(separator: ", ")
  }

  private func save(_ job: IntakeJob) {
    var next = job
    next.updatedAt = Date()
    try? store.save(next)
    if next.state == .discarded {
      jobs.removeAll { $0.id == next.id }
    } else if let index = jobs.firstIndex(where: { $0.id == next.id }) {
      jobs[index] = next
    } else {
      jobs.insert(next, at: 0)
      jobs.sort { $0.createdAt > $1.createdAt }
    }
  }
}
