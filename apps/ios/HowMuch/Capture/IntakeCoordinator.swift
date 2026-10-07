import Foundation
import Observation
import os

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
///
/// Work runs in unstructured tasks the coordinator owns, so leaving the Inbox
/// screen never cancels a read. Only discarding a job cancels its read, and a
/// cancelled read saves nothing. Every step that follows an `await` re-reads
/// the job and stops if it is no longer being read.
@MainActor
@Observable
final class IntakeCoordinator {
  static let shared = IntakeCoordinator()

  private static let logger = Logger(subsystem: "sg.soon.howmuch", category: "IntakeCoordinator")

  /// Newest first, without discarded jobs.
  private(set) var jobs: [IntakeJob] = []

  @ObservationIgnored private let inbox: InboxStore
  @ObservationIgnored private let store: IntakeJobStore
  @ObservationIgnored private var drainTask: Task<Void, Never>?
  @ObservationIgnored private var redrainRequested = false
  @ObservationIgnored private var jobTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var approving: Set<UUID> = []

  /// Applied and discarded jobs (and quarantined folders) are kept this long, then pruned.
  private static let retention: TimeInterval = 30 * 24 * 3600
  static let differentBudgetMessage = "From a different budget"
  static let statementMessage = "Statements come in a later version."
  /// "Likely" is 0.75 up to 0.9; lines read by the fallback never reach "Sure".
  static let fallbackConfidenceCap = 0.85

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

  /// Jobs that are not finished: the Accounts band shows only these.
  var activeJobs: [IntakeJob] {
    jobs.filter(\.isActive)
  }

  /// The most urgent unfinished jobs first, for the Accounts band.
  var mostUrgent: [IntakeJob] {
    activeJobs.sorted { lhs, rhs in
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

  /// Claims share-sheet entries, makes a job for each, and starts reading every
  /// job that still needs it (including one a killed app left half done). Safe
  /// to call from several places at once: there is one drain at a time, and a
  /// call made during a drain asks it to look again.
  func drain(model: AppModel) {
    guard model.settings.isAuthenticated else {
      return
    }
    prepareJobs(model: model)
    guard drainTask == nil else {
      redrainRequested = true
      return
    }
    drainTask = Task { [weak self] in
      guard let self else {
        return
      }
      repeat {
        self.redrainRequested = false
        await self.processPending(model: model)
      } while self.redrainRequested
      self.drainTask = nil
    }
  }

  /// One `list()` per drain: adopt new entries, prune, stamp the budget, mark
  /// jobs from another budget, and clear the marker of an interrupted approve.
  private func prepareJobs(model: AppModel) {
    adoptInbox(model: model)
    let cutoff = Date().addingTimeInterval(-Self.retention)
    var all: [IntakeJob] = []
    for job in store.list() {
      if job.updatedAt < cutoff, job.state == .applied || job.state == .discarded {
        store.delete(job.id)
      } else {
        all.append(job)
      }
    }
    store.pruneQuarantine(olderThan: cutoff)

    let planID = model.settings.planID
    for index in all.indices {
      var job = all[index]
      var changed = false
      if job.planID == nil, !planID.isEmpty {
        job.planID = planID
        job.connectionFingerprint = model.settings.connectionFingerprint
        changed = true
      }
      if Self.isFromAnotherBudget(job, model: model),
         job.state != .applied, job.state != .discarded, job.state != .failed {
        job.state = .failed
        job.failureMessage = Self.differentBudgetMessage
        changed = true
      }
      if job.applyStartedAt != nil, job.state == .proposed, !approving.contains(job.id) {
        // Interrupted mid-approve. Approving again is safe: creates carry their
        // import IDs and Fixes are re-checked against the live row.
        job.applyStartedAt = nil
        changed = true
      }
      if changed {
        job.updatedAt = Date()
        if (try? store.save(job)) != nil {
          all[index] = job
        }
      }
    }
    jobs = all.filter { $0.state != .discarded }
  }

  /// Moves claimed `Reading/` entries into `Jobs/`. Also picks up entries an
  /// earlier launch claimed but never turned into a job.
  private func adoptInbox(model: AppModel) {
    _ = try? inbox.claimInbox(where: { $0.isIntakeJobSource })
    let planID = model.settings.planID
    for item in inbox.loadReading(where: { $0.isIntakeJobSource }) {
      do {
        _ = try store.adopt(
          item,
          planID: planID.isEmpty ? nil : planID,
          connectionFingerprint: planID.isEmpty ? nil : model.settings.connectionFingerprint
        )
        inbox.discardReading(item.id)
      } catch {
        Self.logger.error("Couldn't adopt share \(item.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func processPending(model: AppModel) async {
    let pending = jobs
      .filter { $0.state == .reading || $0.state == .queued }
      .sorted { $0.createdAt < $1.createdAt }
    for job in pending {
      await run(job.id, model: model).value
    }
    for job in jobs where job.state == .proposed && job.duplicateCheckLimited {
      await rematchAfterOffline(job.id, model: model)
    }
  }

  /// The one task reading a job, created on demand.
  @discardableResult
  private func run(_ id: UUID, model: AppModel) -> Task<Void, Never> {
    if let existing = jobTasks[id] {
      return existing
    }
    let task = Task { [weak self] in
      await self?.process(id, model: model)
      self?.jobTasks[id] = nil
    }
    jobTasks[id] = task
    return task
  }

  static func isFromAnotherBudget(_ job: IntakeJob, model: AppModel) -> Bool {
    let planID = model.settings.planID
    guard let jobPlan = job.planID, !planID.isEmpty else {
      return false
    }
    if jobPlan != planID {
      return true
    }
    if let fingerprint = job.connectionFingerprint {
      return fingerprint != model.settings.connectionFingerprint
    }
    return false
  }

  // MARK: Reading a job

  /// The job, only while it is still waiting to be read and this task has not
  /// been cancelled. Every step after an `await` goes through this.
  private func readable(_ id: UUID) -> IntakeJob? {
    guard !Task.isCancelled, let job = self.job(id), job.state == .reading || job.state == .queued else {
      return nil
    }
    return job
  }

  private func process(_ id: UUID, model: AppModel) async {
    guard var job = readable(id) else {
      return
    }
    if Self.isFromAnotherBudget(job, model: model) {
      job.state = .failed
      job.failureMessage = Self.differentBudgetMessage
      save(job)
      return
    }
    if job.hint == .statement {
      job.state = .needsYou
      job.failureMessage = Self.statementMessage
      save(job)
      return
    }

    guard await awaitReferenceData(model) else {
      // A cancelled read leaves the job reading to be drained again.
      guard var current = readable(id) else {
        return
      }
      current.state = .failed
      current.failureMessage = CaptureAdmissionGate.stalledMessage
      save(current)
      return
    }
    guard var reading = readable(id) else {
      return
    }
    reading.state = .reading
    reading.failureMessage = nil
    save(reading)

    let accounts = model.openAccounts
    var extracted: [SlipMappedDraft] = []
    var sourceIndexes: [Int] = []
    var fallbackIndexes: [Int] = []
    var readAnyText = false
    for (index, file) in reading.sourceFiles.enumerated() {
      guard readable(id) != nil else {
        return
      }
      let url = store.sourceURL(file, jobID: id)
      guard FileManager.default.fileExists(atPath: url.path) else {
        continue
      }
      let text = await recognise(file, at: url)
      guard readable(id) != nil else {
        return
      }
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        readAnyText = true
      }
      var drafts = await SlipReader.shared.interpret(
        text: text,
        accounts: accounts,
        categoryGroups: model.categoryGroups,
        payees: model.payees
      )
      if drafts.isEmpty {
        // No Apple Intelligence (or the model declined): read the lines directly.
        drafts = IntakeLineParser.interpret(
          text: text,
          accounts: accounts,
          categoryGroups: model.categoryGroups,
          payees: model.payees
        )
        fallbackIndexes.append(contentsOf: (extracted.count..<(extracted.count + drafts.count)))
      }
      extracted.append(contentsOf: drafts)
      sourceIndexes.append(contentsOf: Array(repeating: index, count: drafts.count))
    }
    guard readable(id) != nil else {
      return
    }

    guard !extracted.isEmpty else {
      guard var current = readable(id) else {
        return
      }
      current.state = .failed
      current.failureMessage = readAnyText
        ? "Couldn’t read this. No transactions were found."
        : "Couldn’t read this. No text was found."
      save(current)
      return
    }

    let openIDs = Set(accounts.map(\.id))
    var needsYouMessage: String?
    if reading.decideAccount {
      // Only here does the reader's own account pick apply.
      if extracted.contains(where: { $0.draft.accountID.isEmpty }) {
        needsYouMessage = "Couldn’t tell which account this belongs to."
      }
    } else if let chosen = reading.accountID {
      if openIDs.contains(chosen) {
        // The account the owner chose wins over anything the document names.
        for index in extracted.indices {
          SlipAccountPick.apply(chosen, to: &extracted[index].draft)
        }
      } else {
        needsYouMessage = "The account you chose is closed. Choose another."
      }
    } else {
      for index in extracted.indices where extracted[index].draft.accountID.isEmpty {
        extracted[index].draft.seedIfNeeded(accounts: accounts, preferredAccountID: model.lastUsedOpenAccountID)
      }
    }

    let result = await propose(
      extracted,
      sourceIndexes: sourceIndexes,
      fallbackIndexes: fallbackIndexes,
      hint: reading.hint,
      model: model
    )
    guard var final = readable(id) else {
      return
    }
    final.extractions = extracted
    final.extractionSourceIndexes = sourceIndexes
    final.fallbackExtractionIndexes = fallbackIndexes
    final.proposals = result.proposals
    final.duplicateCheckLimited = result.limited
    final.state = needsYouMessage == nil ? .proposed : .needsYou
    final.failureMessage = needsYouMessage
    save(final)
  }

  private func propose(
    _ extracted: [SlipMappedDraft],
    sourceIndexes: [Int],
    fallbackIndexes: [Int] = [],
    hint: IntakeHint,
    model: AppModel
  ) async -> (proposals: [IntakeProposal], limited: Bool) {
    let matcher = IntakeMatcher()
    var set = IntakeCandidateSet(rows: [], transactions: [:], isComplete: true)
    // "New" in the share sheet means add everything as new.
    if hint != .new, let first = extracted.map(\.draft.date).min(), let last = extracted.map(\.draft.date).max() {
      let calendar = Calendar.current
      let from = calendar.date(byAdding: .day, value: -matcher.dayWindow, to: first) ?? first
      let to = calendar.date(byAdding: .day, value: matcher.dayWindow, to: last) ?? last
      set = await model.intakeCandidates(accountIDs: nil, from: from, to: to)
    }
    var proposals = matcher.match(
      extracted,
      openAccountIDs: Set(model.openAccounts.map(\.id)),
      candidates: set.rows,
      hint: hint,
      duplicateCheckLimited: !set.isComplete
    )
    for index in proposals.indices {
      if index < sourceIndexes.count {
        proposals[index].sourceFileIndex = sourceIndexes[index]
      }
      if let target = proposals[index].targetTransactionID {
        proposals[index].targetSnapshot = set.transactions[target]
      }
      if fallbackIndexes.contains(index) {
        // Read by line rules, not the model: at most Likely.
        proposals[index].confidence = min(proposals[index].confidence, Self.fallbackConfidenceCap)
        proposals[index].reasons.append("Read without Apple Intelligence")
      }
    }
    return (proposals, !set.isComplete)
  }

  /// A job matched while offline is matched again once the register can be
  /// searched in full, so long as the owner has not touched any row.
  private func rematchAfterOffline(_ id: UUID, model: AppModel) async {
    guard let job = self.job(id), job.state == .proposed, job.duplicateCheckLimited,
          !job.extractions.isEmpty,
          job.proposals.allSatisfy({ $0.decision == .pending && !$0.isApplied }) else {
      return
    }
    let result = await propose(
      job.extractions,
      sourceIndexes: job.extractionSourceIndexes,
      fallbackIndexes: job.fallbackExtractionIndexes,
      hint: job.hint,
      model: model
    )
    guard !result.limited, var current = self.job(id), current.state == .proposed,
          current.duplicateCheckLimited, current.proposals.allSatisfy({ $0.decision == .pending && !$0.isApplied }) else {
      return
    }
    current.proposals = result.proposals
    current.duplicateCheckLimited = false
    save(current)
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
        return !Task.isCancelled
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

  private enum Plan {
    case apply(TransactionDraft)
    /// The live row already has what the proposal wanted.
    case unchanged
    case skip(String)
    /// Not ticked: left out by Approve all.
    case decline
  }

  /// Applies every proposal Approve all covers through the normal commit path.
  /// Each Fix is checked again against the live row, and built on it, so other
  /// changes made since matching are kept and its approval is left as it is.
  /// Rows that cannot be applied (no amount, row gone) stay in the batch with a
  /// note; unticked rows are declined. The job is applied, and its files
  /// deleted, only once every row is decided.
  @discardableResult
  func approve(_ id: UUID, model: AppModel) async -> Bool {
    guard let start = self.job(id), start.state == .proposed,
          !Self.isFromAnotherBudget(start, model: model),
          approving.insert(id).inserted else {
      return false
    }
    defer { approving.remove(id) }

    var plans: [UUID: Plan] = [:]
    for proposal in start.proposals where !proposal.isApplied && proposal.decision != .rejected && proposal.kind != .alreadyIn {
      if proposal.kind == .edit {
        guard proposal.appliesOnApproval else {
          plans[proposal.id] = .decline
          continue
        }
        guard let target = proposal.targetTransactionID,
              let live = await model.intakeLiveTransaction(id: target) else {
          plans[proposal.id] = .skip("Couldn’t find the original transaction")
          continue
        }
        let wanted = proposal.changedFields
        let fields = IntakeMatcher.differences(
          draft: proposal.draft,
          parsedCategory: wanted.contains(.category),
          row: IntakeCandidateRow(transaction: live)
        ).filter { wanted.contains($0) }
        let plan: Plan = fields.isEmpty
          ? .unchanged
          : .apply(Self.editDraft(fields: fields, from: proposal, base: live))
        plans[proposal.id] = plan
      } else if proposal.isIncomplete {
        plans[proposal.id] = .skip("Needs an amount and an account")
      } else if proposal.appliesOnApproval {
        plans[proposal.id] = .apply(proposal.draft)
      } else {
        plans[proposal.id] = .decline
      }
    }

    // The job may have been discarded while the live rows were read.
    guard var job = self.job(id), job.state == .proposed else {
      return false
    }
    var drafts: [TransactionDraft] = []
    for proposal in job.proposals {
      if case .apply(let draft) = plans[proposal.id] {
        drafts.append(draft)
      }
    }

    job.applyStartedAt = Date()
    guard save(job) else {
      model.showSaveMessage("Couldn’t update the Inbox. Nothing was saved.", kind: .failure)
      return false
    }
    if !drafts.isEmpty {
      do {
        try model.commit(drafts)
      } catch {
        job.applyStartedAt = nil
        save(job)
        model.showSaveMessage(error.localizedDescription, kind: .failure)
        return false
      }
    }

    var addedNow = 0
    var fixedNow = 0
    var skipped = 0
    for index in job.proposals.indices {
      switch plans[job.proposals[index].id] {
      case .apply:
        job.proposals[index].isApplied = true
        if !job.proposals[index].decision.isAccepted {
          job.proposals[index].decision = .accepted
        }
        job.proposals[index].issue = nil
        if job.proposals[index].kind == .edit { fixedNow += 1 } else { addedNow += 1 }
      case .unchanged:
        job.proposals[index].isApplied = true
        job.proposals[index].kind = .alreadyIn
        job.proposals[index].changedFields = []
        job.proposals[index].issue = nil
      case .skip(let message):
        job.proposals[index].issue = message
        skipped += 1
      case .decline:
        job.proposals[index].decision = .rejected
      case nil:
        break
      }
    }
    job.applyStartedAt = nil
    let finished = job.proposals.allSatisfy(\.isResolved)
    if finished {
      let added = job.proposals.filter { $0.isApplied && ($0.kind == .add || $0.kind == .possibleDuplicate) }.count
      let fixed = job.proposals.filter { $0.isApplied && $0.kind == .edit }.count
      job.state = .applied
      job.appliedSummary = Self.appliedSummary(added: added, fixed: fixed)
      job.extractions = []
      job.extractionSourceIndexes = []
    }
    job.failureMessage = nil

    // The commit has happened. If the result cannot be saved the job stays as
    // it was on disk, with its files, and approving again is safe.
    let saved = save(job)
    if saved, finished {
      store.deleteSources(id)
    }
    guard saved else {
      model.showSaveMessage("Saved, but couldn’t update the Inbox. Open it again.", kind: .failure)
      return false
    }

    var toast = Self.appliedSummary(added: addedNow, fixed: fixedNow)
    if skipped > 0 {
      toast += ", \(skipped) skipped"
    }
    if !drafts.isEmpty {
      toast += " · Saved on device"
    }
    model.showSaveMessage(toast)
    return true
  }

  /// Rejects the batch: nothing is saved, any read in progress is cancelled,
  /// and the shared files are deleted.
  func discard(_ id: UUID) {
    jobTasks[id]?.cancel()
    guard var job = self.job(id) else {
      return
    }
    for index in job.proposals.indices where job.proposals[index].decision == .pending {
      job.proposals[index].decision = .rejected
    }
    job.state = .discarded
    job.extractions = []
    job.extractionSourceIndexes = []
    if save(job) {
      store.deleteSources(id)
    }
  }

  /// Reads a failed job again from the files it kept.
  func retry(_ id: UUID, model: AppModel) {
    guard var job = self.job(id), job.state == .failed,
          !Self.isFromAnotherBudget(job, model: model) else {
      return
    }
    job.state = .reading
    job.failureMessage = nil
    guard save(job) else {
      return
    }
    run(id, model: model)
  }

  /// Sets the account on every line of a Needs you job and matches again.
  func assignAccount(_ accountID: String, to id: UUID, model: AppModel) async {
    guard let job = self.job(id), job.state == .needsYou, job.hint != .statement,
          model.openAccounts.contains(where: { $0.id == accountID }) else {
      return
    }
    var extracted = job.extractions
    for index in extracted.indices {
      SlipAccountPick.apply(accountID, to: &extracted[index].draft)
    }
    let result = await propose(
      extracted,
      sourceIndexes: job.extractionSourceIndexes,
      fallbackIndexes: job.fallbackExtractionIndexes,
      hint: job.hint,
      model: model
    )
    // Discarded, or otherwise changed, while matching.
    guard var current = self.job(id), current.state == .needsYou else {
      return
    }
    current.accountID = accountID
    current.decideAccount = false
    current.extractions = extracted
    current.proposals = result.proposals
    current.duplicateCheckLimited = result.limited
    current.state = .proposed
    current.failureMessage = nil
    save(current)
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

  /// The live row with only the proposal's changed fields applied. Approval is
  /// left as the row has it: a Fix never approves a row for the owner.
  static func editDraft(fields: [IntakeField], from proposal: IntakeProposal, base: Transaction) -> TransactionDraft {
    var draft = TransactionDraft(transaction: base)
    for field in fields {
      switch field {
      case .payee:
        draft.payeeID = proposal.draft.payeeID
        draft.payeeName = proposal.draft.payeeName
      case .category:
        draft.categoryID = proposal.draft.categoryID
      case .amount, .date, .memo, .unknown:
        break
      }
    }
    draft.approved = base.approved
    return draft
  }

  static func appliedSummary(added: Int, fixed: Int) -> String {
    var parts: [String] = []
    if added > 0 { parts.append("\(added) added") }
    if fixed > 0 { parts.append("\(fixed) fixed") }
    return parts.isEmpty ? "Nothing to add" : parts.joined(separator: ", ")
  }

  /// Writes the job to disk, then to the list. A failed write is logged and
  /// leaves both as they were.
  @discardableResult
  private func save(_ job: IntakeJob) -> Bool {
    var next = job
    next.updatedAt = Date()
    do {
      try store.save(next)
    } catch {
      Self.logger.error("Couldn't save job \(job.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
      return false
    }
    if next.state == .discarded {
      jobs.removeAll { $0.id == next.id }
    } else if let index = jobs.firstIndex(where: { $0.id == next.id }) {
      jobs[index] = next
    } else {
      jobs.insert(next, at: 0)
      jobs.sort { $0.createdAt > $1.createdAt }
    }
    return true
  }
}
