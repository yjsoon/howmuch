import BackgroundTasks
import Foundation
import Observation
import UIKit
import UserNotifications
import os

/// Where a tap on an Inbox notification, or a `howmuch://inbox` link, lands.
enum IntakeDestination: Equatable {
  /// The Inbox list.
  case list
  /// One batch's review screen.
  case batch(UUID)
}

/// Local notifications for Inbox batches. Nothing here is remote push and no
/// device token leaves the phone. A notification never applies anything:
/// Review and Open Inbox open the app, Later clears it, and Discard (the only
/// background mutation) goes through `IntakeCoordinator.discard`.
@MainActor
@Observable
final class IntakeNotifier {
  static let shared = IntakeNotifier()

  /// Ready to review and Needs you: Review, Later.
  static let reviewCategory = "halation.inbox"
  /// Failed: Open Inbox, Discard.
  static let failedCategory = "halation.inbox.failed"
  static let summaryIdentifier = "halation.inbox.summary"

  enum ActionID {
    static let review = "halation.inbox.review"
    static let later = "halation.inbox.later"
    static let openInbox = "halation.inbox.open"
    static let discard = "halation.inbox.discard"
  }

  private enum Kind {
    static let ready = "ready"
    static let needsYou = "needsYou"
    static let failed = "failed"
    static let summary = "summary"
  }

  /// Set by a notification tap or an Inbox link. `RootView` consumes it.
  var pendingRoute: IntakeDestination?

  @ObservationIgnored private let center: UNUserNotificationCenter
  @ObservationIgnored private let delegate = IntakeNotificationDelegate()
  @ObservationIgnored private var lastBadge: Int?

  private static let logger = Logger(subsystem: "sg.soon.howmuch", category: "IntakeNotifier")

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  /// At launch, before the app finishes launching, so a tap that cold-starts
  /// the app is delivered.
  func activate() {
    center.delegate = delegate
    let review = UNNotificationAction(identifier: ActionID.review, title: "Review", options: [.foreground])
    let later = UNNotificationAction(identifier: ActionID.later, title: "Later", options: [])
    let openInbox = UNNotificationAction(identifier: ActionID.openInbox, title: "Open Inbox", options: [.foreground])
    let discard = UNNotificationAction(
      identifier: ActionID.discard,
      title: "Discard",
      options: [.destructive, .authenticationRequired]
    )
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.reviewCategory,
        actions: [review, later],
        intentIdentifiers: [],
        options: []
      ),
      UNNotificationCategory(
        identifier: Self.failedCategory,
        actions: [openInbox, discard],
        intentIdentifiers: [],
        options: []
      ),
    ])
  }

  // MARK: Authorisation

  /// Asks the first time a job reaches Ready, or a share is first taken, and
  /// only while the owner can see the prompt. Denied means nothing more.
  private func authorisationStatus(requestIfNeeded: Bool) async -> UNAuthorizationStatus {
    var status = await center.notificationSettings().authorizationStatus
    if status == .notDetermined, requestIfNeeded, UIApplication.shared.applicationState == .active {
      let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
      status = granted ? .authorized : .denied
      if granted {
        // The badge could not be set before; set it now.
        refreshBadge()
      }
    }
    return status
  }

  private static func canPost(_ status: UNAuthorizationStatus) -> Bool {
    status == .authorized || status == .provisional || status == .ephemeral
  }

  /// The drain took a share job. For someone whose first jobs were read in the
  /// background, this is where they are first asked.
  func shareAdopted() {
    Task { _ = await authorisationStatus(requestIfNeeded: true) }
  }

  // MARK: Badge

  /// The app badge is Ready plus Needs you. Called on every job change.
  func updateBadge(_ count: Int) {
    guard lastBadge != count else {
      return
    }
    lastBadge = count
    if count == 0 {
      center.removeDeliveredNotifications(withIdentifiers: [Self.summaryIdentifier])
    }
    let center = center
    Task { [weak self] in
      do {
        try await center.setBadgeCount(count)
      } catch {
        // Not allowed (yet): forget it, so the next change or foreground tries again.
        if self?.lastBadge == count {
          self?.lastBadge = nil
        }
      }
    }
  }

  /// Sets the badge again from the current jobs.
  func refreshBadge() {
    lastBadge = nil
    updateBadge(IntakeCoordinator.shared.attentionCount)
  }

  /// Signed out: nothing left to say, and no badge.
  func clearAll() {
    center.removeAllDeliveredNotifications()
    center.removeAllPendingNotificationRequests()
    lastBadge = nil
    updateBadge(0)
  }

  // MARK: Posting

  /// A job moved to `job.state`. Only a move into Ready, Needs you or Failed
  /// posts; a move out of them takes the notification back.
  func jobDidChange(_ job: IntakeJob, previous: IntakeJobState?, accountName: String?) {
    guard job.state != previous else {
      return
    }
    switch job.state {
    case .proposed, .needsYou, .failed:
      Task { await deliver(job) }
    case .queued, .reading, .applied, .discarded:
      clear(job.id)
      Task { await reconcileSummary() }
    }
  }

  func clear(_ jobID: UUID) {
    let identifier = jobID.uuidString
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  private func deliver(_ job: IntakeJob) async {
    let status = await authorisationStatus(requestIfNeeded: job.state == .proposed)
    guard Self.canPost(status) else {
      return
    }
    // No banner while the owner is looking at the app.
    guard UIApplication.shared.applicationState != .active else {
      return
    }
    // The owner may have acted on it while this waited.
    guard IntakeCoordinator.shared.job(job.id)?.state == job.state else {
      return
    }
    if job.state != .failed {
      let waiting = Self.waitingJobs()
      if waiting.count >= 2 {
        await postSummary(waiting, alert: true)
        return
      }
    }
    await postSingle(job, alert: true)
  }

  /// Ready plus Needs you, as the coordinator has them now.
  private static func waitingJobs() -> [IntakeJob] {
    IntakeCoordinator.shared.jobs
      .filter { $0.state == .proposed || $0.state == .needsYou }
      .sorted { $0.createdAt < $1.createdAt }
  }

  private func postSingle(_ job: IntakeJob, alert: Bool) async {
    let content = UNMutableNotificationContent()
    content.sound = alert ? .default : nil
    content.threadIdentifier = job.id.uuidString
    var userInfo: [String: Any] = ["jobID": job.id.uuidString]
    switch job.state {
    case .failed:
      content.title = Self.failedTitle
      content.body = Self.failedBody(job)
      content.categoryIdentifier = Self.failedCategory
      userInfo["kind"] = Kind.failed
    case .needsYou:
      content.title = Self.needsYouTitle
      content.body = Self.needsYouBody(job)
      content.categoryIdentifier = Self.reviewCategory
      userInfo["kind"] = Kind.needsYou
    default:
      content.title = Self.readyTitle
      content.body = Self.readyBody(job, accountName: IntakeCoordinator.shared.accountName(for: job))
      content.categoryIdentifier = Self.reviewCategory
      userInfo["kind"] = Kind.ready
    }
    content.userInfo = userInfo
    await add(content, identifier: job.id.uuidString)
  }

  /// One notification for every batch waiting, replacing their own. Rebuilt
  /// from the current jobs each time, so its count is never stale.
  private func postSummary(_ waiting: [IntakeJob], alert: Bool) async {
    let content = UNMutableNotificationContent()
    content.sound = alert ? .default : nil
    content.title = Self.summaryTitle(count: waiting.count)
    content.body = Self.summaryBody
    content.categoryIdentifier = Self.reviewCategory
    content.threadIdentifier = Self.summaryIdentifier
    content.userInfo = [
      "kind": Kind.summary,
      "batchCount": waiting.count,
      "jobIDs": waiting.map { $0.id.uuidString },
    ]
    center.removeDeliveredNotifications(withIdentifiers: waiting.map { $0.id.uuidString })
    await add(content, identifier: Self.summaryIdentifier)
  }

  /// A batch left Ready or Needs you. If a summary is showing, bring it up to
  /// date: its new count, or (down to one) that batch's own notification, or
  /// nothing.
  private func reconcileSummary() async {
    let delivered = await center.deliveredNotifications()
    guard let summary = delivered.first(where: { $0.request.identifier == Self.summaryIdentifier }) else {
      return
    }
    let waiting = Self.waitingJobs()
    switch waiting.count {
    case 0:
      center.removeDeliveredNotifications(withIdentifiers: [Self.summaryIdentifier])
    case 1:
      center.removeDeliveredNotifications(withIdentifiers: [Self.summaryIdentifier])
      await postSingle(waiting[0], alert: false)
    default:
      if summary.request.content.userInfo["batchCount"] as? Int != waiting.count {
        await postSummary(waiting, alert: false)
      }
    }
  }

  private func add(_ content: UNMutableNotificationContent, identifier: String) async {
    do {
      try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    } catch {
      Self.logger.error("Couldn't post notification: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: Responses

  /// A tap or an action button. Review, Open Inbox and a plain tap open the
  /// app; Later clears; Discard is the only thing that changes a job.
  func handle(action: String, jobID: UUID?, kind: String?) {
    switch action {
    case ActionID.discard:
      if let jobID {
        IntakeCoordinator.shared.discard(jobID)
        clear(jobID)
      }
    case ActionID.later:
      if kind == Kind.summary {
        center.removeDeliveredNotifications(withIdentifiers: [Self.summaryIdentifier])
      } else if let jobID {
        clear(jobID)
      }
    case ActionID.openInbox:
      pendingRoute = .list
    case ActionID.review, UNNotificationDefaultActionIdentifier:
      if kind == Kind.failed || kind == Kind.summary {
        pendingRoute = .list
      } else if let jobID, IntakeCoordinator.shared.job(jobID) != nil {
        pendingRoute = .batch(jobID)
      } else {
        pendingRoute = .list
      }
    default:
      break
    }
  }

  // MARK: Copy

  static let readyTitle = "Ready to review"
  static let needsYouTitle = "Halation needs you"
  static let failedTitle = "Couldn’t read this"
  static let summaryBody = "Open Halation to review them."

  static func summaryTitle(count: Int) -> String {
    "\(count) batches waiting"
  }

  /// "1 correction found · 1 new, from 2 DBS screenshots". Zero parts are left out.
  static func readyBody(_ job: IntakeJob, accountName: String?) -> String {
    let counts = job.counts
    var parts: [String] = []
    if counts.fixed > 0 {
      parts.append(counts.fixed == 1 ? "1 correction found" : "\(counts.fixed) corrections found")
    }
    if counts.added > 0 { parts.append("\(counts.added) new") }
    if counts.possibleDuplicates > 0 {
      parts.append("\(counts.possibleDuplicates) possible \(counts.possibleDuplicates == 1 ? "duplicate" : "duplicates")")
    }
    if counts.alreadyIn > 0 { parts.append("\(counts.alreadyIn) already in") }
    let found = parts.isEmpty ? "Nothing to add" : parts.joined(separator: " · ")
    return "\(found), from \(job.sourceDescription(accountName: accountName))"
  }

  static func needsYouBody(_ job: IntakeJob) -> String {
    job.failureMessage ?? "Choose an account to continue."
  }

  static func failedBody(_ job: IntakeJob) -> String {
    job.failureMessage ?? "Open the Inbox to try again."
  }
}

/// Receives taps. Not main-actor isolated: UserNotifications calls it on its
/// own queue, and each response hops to the main actor to act.
final class IntakeNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  // The completion-handler form, not `async`: with the async form UIKit can finish
  // the response off the main thread and assert "Call must be made on main thread".
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    let jobID = (info["jobID"] as? String).flatMap { UUID(uuidString: $0) }
    let kind = info["kind"] as? String
    let action = response.actionIdentifier
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        IntakeNotifier.shared.handle(action: action, jobID: jobID, kind: kind)
      }
      completionHandler()
    }
  }
}

/// Finishes a BGAppRefreshTask exactly once, from whichever of the expiry
/// handler (any queue) or the drain (main actor) gets there first.
final class IntakeRefreshCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false
  private let task: BGAppRefreshTask

  init(_ task: BGAppRefreshTask) {
    self.task = task
  }

  var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return finished
  }

  func complete(success: Bool) {
    lock.lock()
    let first = !finished
    finished = true
    lock.unlock()
    if first {
      task.setTaskCompleted(success: success)
    }
  }
}

/// One `beginBackgroundTask` identifier, so the handler and the waiter end
/// the one they belong to and no other.
final class IntakeBackgroundTaskBox: @unchecked Sendable {
  var id = UIBackgroundTaskIdentifier.invalid
}

/// Reads the Inbox queue when the app is not in front: a refresh iOS grants
/// every so often, and a short extension when the app backgrounds mid-read.
/// Reading is on-device, so nothing here touches a server beyond what the app
/// already does when it refreshes reference data.
@MainActor
final class IntakeBackgroundRefresh {
  static let shared = IntakeBackgroundRefresh()
  static let identifier = "sg.soon.howmuch.intake-refresh"
  static let interval: TimeInterval = 15 * 60

  private static let logger = Logger(subsystem: "sg.soon.howmuch", category: "IntakeBackgroundRefresh")

  /// Set once when the app is created, so a launch for a refresh has a model.
  var model: AppModel?
  private var activeBackgroundTask: IntakeBackgroundTaskBox?

  /// Must run before the app finishes launching.
  func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { @Sendable task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      let completion = IntakeRefreshCompletion(refresh)
      // Installed before any hop to the main actor, so iOS can always end us.
      refresh.expirationHandler = { @Sendable in
        // Jobs being read stay reading and resume on the next drain.
        Task { @MainActor in
          IntakeCoordinator.shared.cancelDrain()
        }
        completion.complete(success: false)
      }
      Task { @MainActor in
        IntakeBackgroundRefresh.shared.handle(completion)
      }
    }
  }

  /// Share entries not yet taken, or jobs still to read.
  var hasPendingWork: Bool {
    IntakeCoordinator.shared.isBusy
      || InboxStore.shared.hasReadyInboxItems(matching: { $0.isIntakeJobSource })
      || InboxStore.shared.hasReadingItems(matching: { $0.isIntakeJobSource })
  }

  func schedule() {
    let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: Self.interval)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Not permitted (Background App Refresh off) or in the Simulator.
      Self.logger.info("Couldn't schedule refresh: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func handle(_ completion: IntakeRefreshCompletion) {
    guard !completion.isFinished else {
      return
    }
    guard let model, model.settings.isAuthenticated else {
      completion.complete(success: true)
      return
    }
    schedule()
    let coordinator = IntakeCoordinator.shared
    coordinator.drain(model: model)
    Task { @MainActor in
      await coordinator.waitForDrain()
      completion.complete(success: true)
    }
  }

  /// The app moved to the background while signed in. Always queue a refresh
  /// (a share made while the app is suspended is only seen by one), and ask
  /// for time to finish whatever the Inbox has under way.
  func appDidEnterBackground() {
    guard let model, model.settings.isAuthenticated else {
      return
    }
    schedule()
    let coordinator = IntakeCoordinator.shared
    guard hasPendingWork, activeBackgroundTask == nil else {
      return
    }
    let box = IntakeBackgroundTaskBox()
    box.id = UIApplication.shared.beginBackgroundTask(withName: "intake-drain") { @Sendable [weak self] in
      MainActor.assumeIsolated {
        coordinator.cancelDrain()
        self?.end(box)
      }
    }
    activeBackgroundTask = box
    coordinator.drain(model: model)
    Task { @MainActor [weak self] in
      await coordinator.waitForDrain()
      self?.end(box)
    }
  }

  private func end(_ box: IntakeBackgroundTaskBox) {
    guard box.id != .invalid else {
      return
    }
    UIApplication.shared.endBackgroundTask(box.id)
    box.id = .invalid
    if activeBackgroundTask === box {
      activeBackgroundTask = nil
    }
  }
}
