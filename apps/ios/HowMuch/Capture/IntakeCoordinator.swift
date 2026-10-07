import Foundation
import Observation
import UIKit
import os

extension InboxItem {
  /// Share-sheet entries and the clipboard offer's "Add these transactions?"
  /// become intake jobs. App Intents keep the conversation flow.
  var isIntakeJobSource: Bool {
    source == .shareSheet || source == .detectedScreenshot
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
  /// Identifies the drain that owns `drainTask`, so a finished (or cancelled)
  /// drain's tail never clears a newer one.
  @ObservationIgnored private var drainToken = UUID()
  /// Bumped by `cancelDrain`. A drain loop stops when its epoch is stale.
  @ObservationIgnored private var drainEpoch = 0
  @ObservationIgnored private var redrainRequested = false
  @ObservationIgnored private var jobTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
  @ObservationIgnored private var approving: Set<UUID> = []
  /// Account names by ID, refreshed on each drain, for notification copy.
  @ObservationIgnored private var accountNames: [String: String] = [:]
  @ObservationIgnored private let hashIndex: IntakeHashIndex
  /// Shares whose files could not all be found; left alone until the next drain re-adopts them.
  @ObservationIgnored private var unadoptable: Set<UUID> = []

  /// Applied and discarded jobs (and quarantined folders) are kept this long, then pruned.
  private static let retention: TimeInterval = 30 * 24 * 3600
  static let differentBudgetMessage = "From a different budget"
  static let statementMessage = "Statements come in a later version."
  static let addAccountMessage = "Add an account to continue"
  static let missingFilesMessage = "Some shared files are missing. Share it again."
  /// How long a share with missing files is retried before it is given up on.
  private static let missingFilesGrace: TimeInterval = 3600
  /// "Likely" is 0.75 up to 0.9; lines read by the fallback never reach "Sure".
  static let fallbackConfidenceCap = 0.85
  static let fallbackReason = "Read without Apple Intelligence"

  init(
    inbox: InboxStore = IntakeJobStore.isUnitTestHost
      ? InboxStore(container: IntakeJobStore.sharedContainer)
      : .shared,
    store: IntakeJobStore = .shared,
    hashIndex: IntakeHashIndex = IntakeJobStore.isUnitTestHost
      ? IntakeHashIndex(container: IntakeJobStore.sharedContainer)
      : .shared
  ) {
    self.inbox = inbox
    self.store = store
    self.hashIndex = hashIndex
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
    publishAttention()
  }

  /// A read is under way or waiting: the app should ask iOS for time to finish it.
  var isBusy: Bool {
    drainTask != nil || jobs.contains { $0.state == .reading || $0.state == .queued }
  }

  /// Keeps the app icon badge at Ready plus Needs you.
  private func publishAttention() {
    IntakeNotifier.shared.updateBadge(attentionCount)
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
    accountNames = Dictionary(model.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    prepareJobs(model: model)
    if let running = drainTask, !running.isCancelled {
      redrainRequested = true
      return
    }
    // A cancelled drain may still be winding down: the new one waits for it,
    // so two never read the same job at once.
    let previous = drainTask
    let epoch = drainEpoch
    let token = UUID()
    drainToken = token
    drainTask = Task { [weak self] in
      await previous?.value
      guard let self else {
        return
      }
      repeat {
        self.redrainRequested = false
        await self.processPending(model: model, epoch: epoch)
      } while self.redrainRequested && self.drainEpoch == epoch && !Task.isCancelled
      if self.drainToken == token {
        self.drainTask = nil
      }
    }
  }

  /// Resolves once the drain in flight (if any) has finished or been cancelled.
  func waitForDrain() async {
    await drainTask?.value
  }

  /// Stops reading. A job being read stays `reading` (a cancelled read saves
  /// nothing) and is picked up by the next drain. Used when iOS ends the
  /// time it gave the app in the background.
  func cancelDrain() {
    drainEpoch += 1
    redrainRequested = false
    drainTask?.cancel()
    for entry in jobTasks.values {
      entry.task.cancel()
    }
  }

  /// Notification copy: the name of the account a job was shared to, if known.
  func accountName(for job: IntakeJob) -> String? {
    job.accountID.flatMap { accountNames[$0] }
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
    publishAttention()
    syncHashIndex()
  }

  /// Rewrites the duplicate-share index for the extension: every job from the
  /// last 30 days that is still worth warning about. A discarded or failed job
  /// is not (sharing it again is the point), and neither is one with no hash.
  private func syncHashIndex() {
    var contents = IntakeHashIndex.Contents()
    for job in store.list() where job.state != .discarded && job.state != .failed {
      let entry = IntakeHashEntry(jobID: job.id, sharedAt: job.createdAt)
      if let hash = job.contentHash, !hash.isEmpty,
         contents.content[hash].map({ $0.sharedAt < job.createdAt }) ?? true {
        contents.content[hash] = entry
      }
      for file in job.sourceFiles {
        if let hash = file.sha256, !hash.isEmpty,
           contents.sources[hash].map({ $0.sharedAt < job.createdAt }) ?? true {
          contents.sources[hash] = entry
        }
      }
    }
    hashIndex.replace(contents)
  }

  /// Moves claimed `Reading/` entries into `Jobs/`. Also picks up entries an
  /// earlier launch claimed but never turned into a job.
  private func adoptInbox(model: AppModel) {
    unadoptable = []
    _ = try? inbox.claimInbox(where: { $0.isIntakeJobSource })
    let planID = model.settings.planID
    var adoptedAny = false
    defer {
      if adoptedAny {
        // Background-first users are asked the first time a share is taken.
        IntakeNotifier.shared.shareAdopted()
      }
    }
    for item in inbox.loadReading(where: { $0.isIntakeJobSource }) {
      do {
        _ = try store.adopt(
          item,
          planID: planID.isEmpty ? nil : planID,
          connectionFingerprint: planID.isEmpty ? nil : model.settings.connectionFingerprint
        )
        inbox.discardReading(item.id)
        adoptedAny = true
      } catch IntakeJobStoreError.missingSource {
        unadoptable.insert(item.id)
        giveUpOnMissingFiles(
          item,
          planID: planID.isEmpty ? nil : planID,
          connectionFingerprint: planID.isEmpty ? nil : model.settings.connectionFingerprint
        )
      } catch {
        unadoptable.insert(item.id)
        Self.logger.error("Couldn't adopt share \(item.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// A share whose files are gone is not retried for ever. A leftover Reading
  /// folder of a job that is already past reading is just removed. Otherwise,
  /// after a grace period, the folder is quarantined and the batch is shown as failed.
  private func giveUpOnMissingFiles(_ item: InboxItem, planID: String?, connectionFingerprint: String?) {
    let existing = store.load(item.id)
    if let existing, existing.state != .reading, existing.state != .queued {
      inbox.discardReading(item.id)
      return
    }
    guard Date().timeIntervalSince(item.createdAt) > Self.missingFilesGrace else {
      return
    }
    inbox.quarantineReading(item.id)
    var job = existing ?? IntakeJob(
      id: item.id,
      createdAt: item.createdAt,
      origin: IntakeOrigin(source: item.source),
      sourceFiles: item.sources,
      accountID: item.accountID,
      decideAccount: item.decideAccount,
      hint: item.hint,
      note: item.note,
      contentHash: item.contentHash,
      planID: planID,
      connectionFingerprint: connectionFingerprint
    )
    job.state = .failed
    job.failureMessage = Self.missingFilesMessage
    save(job)
  }

  private func processPending(model: AppModel, epoch: Int) async {
    // A batch that was waiting for an account is read once there is one.
    if !model.openAccounts.isEmpty {
      for job in jobs where job.state == .needsYou && job.failureMessage == Self.addAccountMessage {
        var waiting = job
        waiting.state = .reading
        waiting.failureMessage = nil
        save(waiting)
      }
    }
    let pending = jobs
      .filter { ($0.state == .reading || $0.state == .queued) && !unadoptable.contains($0.id) }
      .sorted { $0.createdAt < $1.createdAt }
    for job in pending {
      if Task.isCancelled || drainEpoch != epoch {
        return
      }
      await run(job.id, model: model).value
    }
    for job in jobs where job.state == .proposed && job.duplicateCheckLimited {
      await rematchAfterOffline(job.id, model: model)
    }
  }

  /// The one task reading a job, created on demand.
  @discardableResult
  private func run(_ id: UUID, model: AppModel) -> Task<Void, Never> {
    // A cancelled read may still be winding down: ignore it, and start after it.
    if let existing = jobTasks[id], !existing.task.isCancelled {
      return existing.task
    }
    let previous = jobTasks[id]?.task
    let token = UUID()
    let task = Task { [weak self] in
      await previous?.value
      await self?.process(id, model: model)
      if self?.jobTasks[id]?.token == token {
        self?.jobTasks[id] = nil
      }
    }
    jobTasks[id] = (token, task)
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

    // Reading is on this device and the document is fine, so missing reference
    // data (offline at launch, a headless run) is not a failure. The job keeps
    // its state and is read on the next drain. A fresh share is adopted as
    // `.reading` before this point, and the flag is cleared again when the read
    // really starts below, so either state may wait.
    func markWaiting() {
      if var waiting = readable(id), !waiting.waitingForAccounts {
        waiting.waitingForAccounts = true
        save(waiting)
      }
    }
    guard await awaitReferenceData(model) else {
      markWaiting()
      return
    }
    if model.openAccounts.isEmpty {
      // Accounts loaded and there are none to file against (a new budget):
      // ask for one. Nothing is known yet if they did not load, so wait.
      guard model.referencePhase == .loaded, var current = readable(id) else {
        markWaiting()
        return
      }
      current.state = .needsYou
      current.waitingForAccounts = false
      current.failureMessage = Self.addAccountMessage
      save(current)
      return
    }
    guard var reading = readable(id) else {
      return
    }
    reading.state = .reading
    reading.waitingForAccounts = false
    reading.failureMessage = nil
    save(reading)

    let accounts = model.openAccounts
    // The owner's notes go to the model reader only; the line parser reads none.
    let guidance = IntakeSkillStore.shared.skill.promptGuidance(
      accountID: reading.decideAccount ? nil : reading.accountID
    )
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
      let background = Self.isReadingInBackground
      let text: String
      do {
        text = try await recognise(file, at: url, strict: background)
      } catch {
        // Vision failed (not "found no text"). A foreground read can try again.
        leaveForForeground(id)
        return
      }
      guard readable(id) != nil else {
        return
      }
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        readAnyText = true
      }
      var drafts: [SlipMappedDraft]
      do {
        drafts = try await SlipReader.shared.interpretOrThrow(
          text: text,
          accounts: accounts,
          categoryGroups: model.categoryGroups,
          payees: model.payees,
          guidance: guidance
        )
      } catch {
        if background, readable(id) != nil {
          // The model failed (not "returned no spends"). Don't settle for the
          // line parser in the background: wait for a foreground read.
          leaveForForeground(id)
          return
        }
        drafts = []
      }
      guard readable(id) != nil else {
        return
      }
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
    let skill = IntakeSkillStore.shared.skill
    let matcher = IntakeMatcher(skill: skill)
    var set = IntakeCandidateSet(rows: [], transactions: [:], isComplete: true)
    // "New" in the share sheet means add everything as new.
    if hint != .new, let first = extracted.map(\.draft.date).min(), let last = extracted.map(\.draft.date).max() {
      let calendar = Calendar.current
      let from = calendar.date(byAdding: .day, value: -matcher.widestWindow, to: first) ?? first
      let to = calendar.date(byAdding: .day, value: matcher.widestWindow, to: last) ?? last
      set = await model.intakeCandidates(accountIDs: nil, from: from, to: to)
    }
    // Match the lines as read, so a learned rule can never turn a row that is
    // already in the register into a Fix. Rules then apply to New rows only.
    var proposals = matcher.match(
      extracted,
      openAccountIDs: Set(model.openAccounts.map(\.id)),
      candidates: set.rows,
      hint: hint,
      duplicateCheckLimited: !set.isComplete
    )
    // Counting a use waits for Approve, so reading a job again never counts twice.
    IntakeRuleEngine.applyLearned(
      skill.rules, to: &proposals, reads: extracted, context: IntakeRuleContext.make(model: model)
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
        proposals[index].reasons.append(Self.fallbackReason)
      }
    }
    return (proposals, !set.isComplete)
  }

  /// A job matched while offline is matched again once the register can be
  /// searched in full, so long as the owner has not touched any row.
  private func rematchAfterOffline(_ id: UUID, model: AppModel) async {
    guard !approving.contains(id), let job = self.job(id), job.state == .proposed, job.duplicateCheckLimited,
          !job.extractions.isEmpty,
          job.proposals.allSatisfy(\.isUntouched) else {
      return
    }
    let result = await propose(
      job.extractions,
      sourceIndexes: job.extractionSourceIndexes,
      fallbackIndexes: job.fallbackExtractionIndexes,
      hint: job.hint,
      model: model
    )
    guard !result.limited, !approving.contains(id), var current = self.job(id), current.state == .proposed,
          current.duplicateCheckLimited, current.proposals.allSatisfy(\.isUntouched) else {
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

  /// True when the app is not in front: a background refresh or the time
  /// iOS gives after backgrounding.
  private static var isReadingInBackground: Bool {
    UIApplication.shared.applicationState != .active
  }

  /// Puts a job whose read failed in the background back in the queue, so the
  /// next foreground drain reads it with the full pipeline.
  private func leaveForForeground(_ id: UUID) {
    guard var job = readable(id) else {
      return
    }
    job.state = .queued
    save(job)
  }

  /// With `strict`, an OCR failure throws instead of reading as no text.
  private func recognise(_ file: InboxSourceFile, at url: URL, strict: Bool) async throws -> String {
    switch file.kind {
    case .image:
      let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
      guard let data else {
        return ""
      }
      if strict {
        return try await SlipImageText.recognizeOrThrow(data)
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
    var plannedTargets = Set<String>()
    for proposal in start.proposals where !proposal.isApplied && proposal.decision != .rejected && proposal.kind != .alreadyIn {
      if proposal.kind == .edit {
        guard proposal.appliesOnApproval else {
          plans[proposal.id] = .decline
          continue
        }
        guard let target = proposal.targetTransactionID else {
          plans[proposal.id] = .skip("Couldn’t find the original transaction")
          continue
        }
        let live: Transaction
        switch await model.intakeLiveTransaction(id: target) {
        case .found(let row):
          live = row
        case .gone:
          plans[proposal.id] = .skip("Couldn’t find the original transaction")
          continue
        case .unavailable:
          plans[proposal.id] = .skip("Couldn’t check the original transaction. Try again when you’re online.")
          continue
        }
        let fields = IntakeMatcher.pendingFixFields(
          wanted: proposal.changedFields,
          draft: proposal.draft,
          live: live,
          allowContainment: start.hint != .fix
        )
        if let refusal = Self.fixRefusal(fields: fields, live: live) {
          plans[proposal.id] = .skip(refusal)
          continue
        }
        var plan: Plan = fields.isEmpty
          ? .unchanged
          : .apply(Self.editDraft(fields: fields, from: proposal, base: live))
        if case .apply = plan, !plannedTargets.insert(target).inserted {
          // Two rows must not both rewrite one transaction.
          plan = .skip("Another row already fixes this transaction.")
        }
        plans[proposal.id] = plan
      } else if proposal.isIncomplete {
        plans[proposal.id] = .skip("Needs an amount and an account")
      } else if proposal.appliesOnApproval {
        plans[proposal.id] = .apply(proposal.draft)
      } else {
        plans[proposal.id] = .decline
      }
    }

    // The job may have been discarded or changed while the live rows were read.
    guard var job = self.job(id), job.state == .proposed else {
      return false
    }
    // Something else changed the rows (a new match, a changed account) while
    // the live rows were read: the plans no longer describe the batch.
    guard job.proposals == start.proposals else {
      model.showSaveMessage("The batch changed. Review it and approve again.", kind: .failure)
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
    var ruleOutcomes: [(ruleID: UUID, overridden: Bool)] = []
    for index in job.proposals.indices {
      switch plans[job.proposals[index].id] {
      case .apply:
        job.proposals[index].isApplied = true
        let applied = job.proposals[index]
        for application in applied.ruleApplications where Self.ruleWroteField(application, in: applied) {
          ruleOutcomes.append((
            ruleID: application.ruleID,
            overridden: IntakeRuleEngine.wasOverridden(
              application, proposed: applied.proposedDraft, final: applied.draft
            )
          ))
        }
        if applied.draft != applied.proposedDraft || applied.flippedFrom != nil {
          job.proposals[index].decision = .editedThenAccepted
        } else if !applied.decision.isAccepted {
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
    // A rule counts a use once its row is saved (approving again after a failed
    // save would count twice), and an override when the owner changed what it set.
    IntakeSkillStore.shared.record(ruleOutcomes)

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

  /// A rule counts a hit when what it set was saved. On a Fix only the payee and
  /// category it changed on the saved row count.
  private static func ruleWroteField(_ application: IntakeRuleApplication, in proposal: IntakeProposal) -> Bool {
    guard proposal.kind == .edit else {
      return true
    }
    return application.effects.contains { effect in
      switch effect {
      case .category: proposal.changedFields.contains(.category)
      case .payee: proposal.changedFields.contains(.payee)
      case .transfer, .review: false
      }
    }
  }

  /// Rejects the batch: nothing is saved, any read in progress is cancelled,
  /// and the shared files are deleted.
  func discard(_ id: UUID) {
    jobTasks[id]?.task.cancel()
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
      syncHashIndex()
    }
  }

  /// Reads a failed job again from the files it kept.
  func retry(_ id: UUID, model: AppModel) {
    guard var job = self.job(id), job.state == .failed,
          !Self.isFromAnotherBudget(job, model: model) else {
      return
    }
    // The files are gone: reading again cannot help, so it stays failed.
    guard !job.sourceFiles.contains(where: {
      !FileManager.default.fileExists(atPath: store.sourceURL($0, jobID: id).path)
    }) else {
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
    if job.failureMessage == Self.addAccountMessage {
      // Never read: there was no account to file against. Read it now.
      var waiting = job
      waiting.accountID = accountID
      waiting.decideAccount = false
      waiting.state = .reading
      waiting.failureMessage = nil
      if save(waiting) {
        drain(model: model)
      }
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

  // MARK: Review edits

  /// What decides whether a New row must be matched again after an edit.
  private static func matchKey(_ draft: TransactionDraft) -> String {
    "\(draft.signedMilliunits)|\(draft.date.isoDateString)|\(draft.accountID)"
  }

  /// Ticks or unticks one row. Only a job waiting for review changes, and a
  /// row already applied never does.
  func setDecision(_ decision: IntakeDecision, proposal proposalID: UUID, in id: UUID, model: AppModel) {
    mutateProposal(proposalID, in: id, model: model) { proposal in
      proposal.decision = decision
    }
  }

  /// Replaces what a row will save with the reviewer's edit. Returns why the
  /// edit was refused, or nil. A Fix recomputes which fields differ from the
  /// row it targets and refuses account, direction or split changes, and
  /// amount or date changes on a reconciled row. A New row whose amount,
  /// direction, date or account changed is matched again.
  @discardableResult
  func updateDraft(_ draft: TransactionDraft, proposal proposalID: UUID, in id: UUID, model: AppModel) -> String? {
    guard let job = self.job(id), job.state == .proposed, !approving.contains(id),
          let current = job.proposals.first(where: { $0.id == proposalID }), !current.isApplied else {
      return nil
    }
    var fields: [IntakeField]?
    if current.kind == .edit {
      if draft.accountID != current.draft.accountID || draft.direction != current.draft.direction
        || draft.isSplit || draft.transferAccountID != current.draft.transferAccountID {
        return Self.fixScopeMessage
      }
      if let snapshot = current.targetSnapshot {
        let changed = IntakeMatcher.editedDifferences(
          draft: draft,
          proposed: current.proposedDraft,
          parsedCategory: draft.categoryID != nil,
          live: snapshot,
          allowContainment: job.hint != .fix
        )
        if let refusal = Self.fixRefusal(fields: changed, live: snapshot) {
          mutateProposal(proposalID, in: id, model: model) { $0.issue = refusal }
          return refusal
        }
        fields = changed
      }
    }
    let rematch = (current.kind == .add || current.kind == .possibleDuplicate)
      && Self.matchKey(draft) != Self.matchKey(current.draft)
    mutateProposal(proposalID, in: id, model: model) { proposal in
      proposal.draft = draft
      proposal.issue = nil
      if let fields {
        proposal.changedFields = fields
      }
    }
    if rematch {
      Task { await rematchRow(proposalID, in: id, model: model) }
    }
    return nil
  }

  /// Sets the account on one row, clearing a self-transfer as the share sheet does.
  @discardableResult
  func setAccount(_ accountID: String, proposal proposalID: UUID, in id: UUID, model: AppModel) -> String? {
    guard var draft = job(id)?.proposals.first(where: { $0.id == proposalID })?.draft else {
      return nil
    }
    SlipAccountPick.apply(accountID, to: &draft)
    return updateDraft(draft, proposal: proposalID, in: id, model: model)
  }

  /// Sets the account on every row of a job waiting for review that would
  /// create a transaction. Fixes and Already in rows keep the account of the
  /// row they target. Rows whose account changed are matched again.
  func setAccountForAll(_ accountID: String, in id: UUID, model: AppModel) {
    guard model.openAccounts.contains(where: { $0.id == accountID }),
          var job = self.job(id), job.state == .proposed, !approving.contains(id) else {
      return
    }
    var changedIDs: [UUID] = []
    for index in job.proposals.indices {
      let proposal = job.proposals[index]
      guard !proposal.isApplied, proposal.kind == .add || proposal.kind == .possibleDuplicate else {
        continue
      }
      SlipAccountPick.apply(accountID, to: &job.proposals[index].draft)
      if job.proposals[index].draft != proposal.draft {
        changedIDs.append(proposal.id)
      }
    }
    guard !changedIDs.isEmpty else {
      return
    }
    job.accountID = accountID
    guard save(job) else {
      model.showSaveMessage("Couldn’t save this change. Try again.", kind: .failure)
      return
    }
    Task {
      for proposalID in changedIDs {
        await rematchRow(proposalID, in: id, model: model)
      }
    }
  }

  /// Turns a New (or Possible duplicate) row into a Fix of one of its
  /// candidates, ticked because the reviewer chose it. Needs the live row, so
  /// it does nothing when that cannot be read.
  @discardableResult
  func flipToFix(_ proposalID: UUID, candidate candidateID: String, in id: UUID, model: AppModel) async -> Bool {
    let live: Transaction
    switch await model.intakeLiveTransaction(id: candidateID) {
    case .found(let row):
      live = row
    case .gone:
      model.showSaveMessage("Couldn’t read that transaction. Try again.", kind: .failure)
      return false
    case .unavailable:
      model.showSaveMessage("Couldn’t check that transaction. Try again when you’re online.", kind: .failure)
      return false
    }
    var flipped = false
    // Checked against the job as it is now, with no await before the change:
    // a re-match may have given another row this target since the sheet opened.
    guard let current = self.job(id),
          !current.proposals.contains(where: { $0.id != proposalID && $0.targetTransactionID == candidateID }) else {
      model.showSaveMessage("Another row already fixes this transaction.", kind: .failure)
      return false
    }
    let allowContainment = current.hint != .fix
    mutateProposal(proposalID, in: id, model: model) { proposal in
      guard proposal.kind == .add || proposal.kind == .possibleDuplicate, proposal.candidateIDs.contains(candidateID) else {
        return
      }
      proposal.flippedFrom = proposal.kind
      proposal.preFlipDecision = proposal.decision
      proposal.kind = .edit
      proposal.targetTransactionID = candidateID
      proposal.targetSnapshot = live
      proposal.changedFields = IntakeMatcher.editedDifferences(
        draft: proposal.draft,
        proposed: proposal.proposedDraft,
        parsedCategory: proposal.draft.categoryID != nil,
        live: live,
        allowContainment: allowContainment
      )
      proposal.reasons.removeAll { $0.hasPrefix("Reconciled") }
      if live.cleared == .reconciled {
        proposal.reasons.append("Reconciled · stays reconciled")
      }
      proposal.issue = nil
      proposal.decision = .accepted
      flipped = true
    }
    if !flipped {
      model.showSaveMessage("Couldn’t change this row. Try again.", kind: .failure)
    }
    return flipped
  }

  /// Undoes `flipToFix`: back to the kind and the tick the row had before.
  func flipToNew(_ proposalID: UUID, in id: UUID, model: AppModel) {
    mutateProposal(proposalID, in: id, model: model) { proposal in
      guard proposal.kind == .edit, let original = proposal.flippedFrom else {
        return
      }
      proposal.kind = original
      proposal.flippedFrom = nil
      proposal.targetTransactionID = nil
      proposal.targetSnapshot = nil
      proposal.changedFields = []
      proposal.reasons.removeAll { $0.hasPrefix("Reconciled") }
      proposal.issue = nil
      proposal.decision = proposal.preFlipDecision ?? .pending
      proposal.preFlipDecision = nil
    }
  }

  /// Matches one New or Possible duplicate row again after the reviewer
  /// changed its amount, direction, date or account. The reviewer's draft is
  /// kept; the kind, candidates and reasons follow the register. Rows the
  /// rest of the batch already targets are not offered. Unless it is still a
  /// confident New, the row is unticked so it is not approved on a stale tick.
  /// With `rulesOnly` (a rule changed, not the row), an incomplete register search
  /// (offline) keeps the row's existing match and only refreshes the rules' effects:
  /// rules never change the amount, date or account the match rests on.
  private func rematchRow(
    _ proposalID: UUID,
    in id: UUID,
    model: AppModel,
    rulesOnly: Bool = false
  ) async {
    guard let job = self.job(id), job.state == .proposed, !approving.contains(id),
          let index = job.proposals.firstIndex(where: { $0.id == proposalID }) else {
      return
    }
    let start = job.proposals[index]
    guard start.kind == .add || start.kind == .possibleDuplicate, !start.isApplied,
          start.draft.amountMagnitudeMilli > 0 else {
      return
    }
    let matcher = IntakeMatcher(skill: IntakeSkillStore.shared.skill)
    var set = IntakeCandidateSet(rows: [], transactions: [:], isComplete: true)
    if job.hint != .new {
      let calendar = Calendar.current
      let from = calendar.date(byAdding: .day, value: -matcher.widestWindow, to: start.draft.date) ?? start.draft.date
      let to = calendar.date(byAdding: .day, value: matcher.widestWindow, to: start.draft.date) ?? start.draft.date
      set = await model.intakeCandidates(accountIDs: nil, from: from, to: to)
    }
    guard let latest = self.job(id), latest.state == .proposed, !approving.contains(id),
          let current = latest.proposals.first(where: { $0.id == proposalID }),
          current.draft == start.draft, !current.isApplied else {
      // Edited again meanwhile: that edit matches the row itself.
      return
    }
    let claimed = Set(latest.proposals.filter { $0.id != proposalID }.compactMap(\.targetTransactionID))
    // What the owner edited stays theirs; rules only touch the rest.
    let editedCategory = current.draft.categoryID != current.proposedDraft.categoryID
    let editedPayee = current.draft.payeeName != current.proposedDraft.payeeName
    let editedTransfer = current.draft.transferAccountID != current.proposedDraft.transferAccountID
    var skipping = Set<IntakeRuleEffect>()
    if editedCategory { skipping.insert(.category) }
    if editedPayee { skipping.insert(.payee) }
    if editedTransfer { skipping.insert(.transfer) }

    var read: SlipMappedDraft
    // With the reader's extraction to hand, the rules' own effects are undone and
    // applied afresh (the account may have changed, so a different rule may fit).
    let rulesApply: Bool
    if latest.extractions.count == latest.proposals.count,
       let position = latest.proposals.firstIndex(where: { $0.id == proposalID }) {
      read = latest.extractions[position]
      read.draft = current.draft
      let asRead = latest.extractions[position].draft
      if !current.ruleApplications.isEmpty {
        if !editedTransfer, !editedPayee {
          read.draft.payeeName = asRead.payeeName
          read.draft.payeeID = asRead.payeeID
        }
        if !editedTransfer {
          read.draft.transferAccountID = asRead.transferAccountID
          if read.draft.transferAccountID == read.draft.accountID {
            read.draft.transferAccountID = nil
            read.draft.payeeID = nil
          }
        }
        if !editedCategory, !editedTransfer {
          read.draft.categoryID = asRead.categoryID
        }
      }
      rulesApply = true
    } else {
      read = SlipMappedDraft(
        draft: current.draft,
        parsedAmount: true,
        parsedDate: true,
        parsedAccount: true,
        parsedCategory: current.draft.categoryID != nil,
        parsedDirection: true,
        accountCandidates: [],
        categoryCandidates: []
      )
      rulesApply = false
    }
    var result = matcher.match(
      [read],
      openAccountIDs: Set(model.openAccounts.map(\.id)),
      candidates: set.rows.filter { !claimed.contains($0.id) },
      hint: latest.hint,
      duplicateCheckLimited: !set.isComplete
    )
    if rulesApply {
      // Also re-applies the flag cap, so a flagged row stays unticked.
      IntakeRuleEngine.applyLearned(
        IntakeSkillStore.shared.skill.rules,
        to: &result,
        reads: [read],
        context: IntakeRuleContext.make(model: model),
        skipping: skipping
      )
    }
    guard let match = result.first else {
      return
    }
    let keepMatch = rulesOnly && !set.isComplete
    mutateProposal(proposalID, in: id, model: model) { proposal in
      // A row first read without Apple Intelligence keeps that note and its cap.
      let readByFallback = proposal.reasons.contains(Self.fallbackReason)
      if keepMatch {
        // The search was incomplete, so the match stays as it was (and so does its
        // confidence, bar a flag rule's cap).
        if match.ruleApplications.contains(where: { $0.effects.contains(.review) }) {
          proposal.confidence = min(proposal.confidence, IntakeRuleEngine.flaggedConfidenceCap)
        }
      } else {
        proposal.kind = match.kind
        proposal.confidence = match.confidence
        proposal.targetTransactionID = match.targetTransactionID
        proposal.targetSnapshot = match.targetTransactionID.flatMap { set.transactions[$0] }
        proposal.changedFields = match.changedFields
        proposal.candidateIDs = match.candidateIDs
      }
      if rulesApply {
        // The reasons, including any learned rule's, are the fresh match's; a kept
        // match keeps its own reasons and takes only the fresh rule lines.
        if keepMatch {
          let ruleLines = match.reasons.filter { $0.hasPrefix(IntakeRuleEngine.reasonPrefix) }
          proposal.reasons = ruleLines + proposal.reasons.filter { !$0.hasPrefix(IntakeRuleEngine.reasonPrefix) }
        } else {
          proposal.reasons = match.reasons
        }
        proposal.ruleApplications = match.ruleApplications
        proposal.readPayee = match.readPayee
        proposal.draft = match.draft
        var proposed = proposal.proposedDraft
        if !editedCategory, !editedTransfer { proposed.categoryID = match.draft.categoryID }
        if !editedPayee, !editedTransfer {
          proposed.payeeName = match.draft.payeeName
          proposed.payeeID = match.draft.payeeID
        }
        if !editedTransfer { proposed.transferAccountID = match.draft.transferAccountID }
        proposal.proposedDraft = proposed
      } else if !keepMatch {
        proposal.reasons = proposal.reasons.filter { $0.hasPrefix(IntakeRuleEngine.reasonPrefix) } + match.reasons
      }
      if readByFallback {
        proposal.confidence = min(proposal.confidence, Self.fallbackConfidenceCap)
        proposal.reasons.append(Self.fallbackReason)
      }
      proposal.flippedFrom = nil
      proposal.preFlipDecision = nil
      proposal.issue = nil
      switch proposal.kind {
      case .add, .possibleDuplicate, .alreadyIn:
        proposal.decision = .pending
      case .edit:
        proposal.decision = .rejected
      }
    }
  }

  /// A rule was deleted, switched off, edited or cleared: reads the untouched rows
  /// of batches waiting for review again, so effects of rules that no longer exist
  /// (and their lines in Why) go. Rows the owner has touched keep their choices.
  func reapplyRules(model: AppModel) {
    Task {
      for job in jobs where job.state == .proposed {
        for proposal in job.proposals where proposal.isUntouched {
          switch proposal.kind {
          case .add, .possibleDuplicate:
            await rematchRow(proposal.id, in: job.id, model: model, rulesOnly: true)
          case .edit, .alreadyIn:
            refreshNotAppliedNote(proposal.id, in: job.id, model: model)
          }
        }
      }
    }
  }

  private func refreshNotAppliedNote(_ proposalID: UUID, in id: UUID, model: AppModel) {
    guard let job = self.job(id), job.extractions.count == job.proposals.count,
          let position = job.proposals.firstIndex(where: { $0.id == proposalID }) else {
      return
    }
    let read = job.extractions[position]
    let context = IntakeRuleContext.make(model: model)
    let rules = IntakeSkillStore.shared.skill.rules
    mutateProposal(proposalID, in: id, model: model) { proposal in
      proposal.reasons.removeAll { $0 == IntakeRuleEngine.notAppliedReason }
      var list = [proposal]
      IntakeRuleEngine.applyLearned(rules, to: &list, reads: [read], context: context)
      proposal = list[0]
    }
  }

  /// Applies `change` to one row and saves. A refused or failed change leaves
  /// the row as it was; a failed save tells the owner.
  @discardableResult
  private func mutateProposal(
    _ proposalID: UUID,
    in id: UUID,
    model: AppModel,
    _ change: (inout IntakeProposal) -> Void
  ) -> Bool {
    guard var job = self.job(id), job.state == .proposed,
          !approving.contains(id),
          let index = job.proposals.firstIndex(where: { $0.id == proposalID }),
          !job.proposals[index].isApplied else {
      return false
    }
    let before = job.proposals[index]
    change(&job.proposals[index])
    guard job.proposals[index] != before else {
      return true
    }
    guard save(job) else {
      model.showSaveMessage("Couldn’t save this change. Try again.", kind: .failure)
      return false
    }
    return true
  }

  func sourceURL(_ file: InboxSourceFile, jobID: UUID) -> URL {
    store.sourceURL(file, jobID: jobID)
  }

  /// Removes one finished job from the Inbox.
  func remove(_ id: UUID) {
    store.delete(id)
    reload()
    syncHashIndex()
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
      case .amount:
        draft.direction = proposal.draft.direction
        draft.amountMagnitudeMilli = proposal.draft.amountMagnitudeMilli
      case .date:
        draft.date = proposal.draft.date
      case .memo:
        draft.memo = proposal.draft.memo
      case .unknown:
        break
      }
    }
    draft.approved = base.approved
    return draft
  }

  static let fixScopeMessage = "Only payee, category, amount, date and memo can be fixed here"
  static let reconciledFixMessage = "Reconciled · amount and date can’t be changed here"

  /// Why a Fix with these fields cannot be written to this row, if it cannot:
  /// amount and date on a reconciled row, or on a split or transfer.
  static func fixRefusal(fields: [IntakeField], live: Transaction) -> String? {
    guard fields.contains(.amount) || fields.contains(.date) else {
      return nil
    }
    if live.cleared == .reconciled {
      return reconciledFixMessage
    }
    if live.isSplit || live.transferAccountID != nil {
      return "Splits and transfers can’t be changed here"
    }
    return nil
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
    let previous = jobs.first { $0.id == job.id }?.state
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
    publishAttention()
    if (previous == .failed) != (next.state == .failed) {
      // A failed share can be sent again without a warning.
      syncHashIndex()
    }
    IntakeNotifier.shared.jobDidChange(next, previous: previous, accountName: accountName(for: next))
    return true
  }
}

extension IntakeRuleContext {
  /// What the register looks like now, for applying learned rules to a line.
  @MainActor
  static func make(model: AppModel) -> IntakeRuleContext {
    var context = IntakeRuleContext()
    for account in model.openAccounts {
      context.openAccountIDs.insert(account.id)
      if account.onBudget {
        context.onBudgetAccountIDs.insert(account.id)
      }
    }
    for account in model.accounts {
      context.accountNames[account.id] = account.name
    }
    for group in model.categoryGroups where !group.deleted {
      for category in group.categories where !category.deleted {
        context.categoryIDs.insert(category.id)
        context.categoryNames[category.id] = category.name
      }
    }
    for payee in model.payees where payee.deleted != true {
      if let target = payee.transferAccountId {
        context.transferPayees[target] = IntakeTransferPayee(id: payee.id, name: payee.name)
      }
    }
    return context
  }
}
