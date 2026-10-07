import BackgroundTasks
import Foundation
import Observation
import UIKit
import UserNotifications
import os

/// Where a tap on an Inbox notification, or a `howmuch://inbox` link, lands.
enum IntakeRoute: Equatable {
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
  /// Batches ready within this long of each other become one summary.
  static let coalesceWindow: TimeInterval = 10 * 60

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
  var pendingRoute: IntakeRoute?

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
    Task {
      // Fails quietly when the owner has not allowed badges.
      try? await center.setBadgeCount(count)
    }
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
      Task { await deliver(job, accountName: accountName) }
    case .queued, .reading, .applied, .discarded:
      clear(job.id)
    }
  }

  func clear(_ jobID: UUID) {
    let identifier = jobID.uuidString
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  private func deliver(_ job: IntakeJob, accountName: String?) async {
    var status = await center.notificationSettings().authorizationStatus
    // Ask the first time a job reaches Ready, and only while the owner can see
    // the prompt. Denied means nothing more, ever.
    if status == .notDetermined, job.state == .proposed,
       UIApplication.shared.applicationState == .active {
      let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
      status = granted ? .authorized : .denied
    }
    guard status == .authorized || status == .provisional || status == .ephemeral else {
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

    let content = UNMutableNotificationContent()
    content.sound = .default
    content.threadIdentifier = job.id.uuidString
    var identifier = job.id.uuidString
    var userInfo: [String: Any] = ["jobID": job.id.uuidString]

    switch job.state {
    case .failed:
      content.title = Self.failedTitle
      content.body = Self.failedBody(job)
      content.categoryIdentifier = Self.failedCategory
      userInfo["kind"] = Kind.failed
    default:
      content.categoryIdentifier = Self.reviewCategory
      let siblings = await recentReviewNotifications(excluding: job.id)
      if siblings.isEmpty {
        if job.state == .needsYou {
          content.title = Self.needsYouTitle
          content.body = Self.needsYouBody(job)
          userInfo["kind"] = Kind.needsYou
        } else {
          content.title = Self.readyTitle
          content.body = Self.readyBody(job, accountName: accountName)
          userInfo["kind"] = Kind.ready
        }
      } else {
        // Replace the earlier ones with one summary.
        let total = siblings.reduce(1) { $0 + ((($1.request.content.userInfo["batchCount"]) as? Int) ?? 1) }
        center.removeDeliveredNotifications(withIdentifiers: siblings.map(\.request.identifier))
        identifier = Self.summaryIdentifier
        content.threadIdentifier = Self.summaryIdentifier
        content.title = Self.summaryTitle(count: total)
        content.body = Self.summaryBody
        userInfo = ["kind": Kind.summary, "batchCount": total]
      }
    }
    content.userInfo = userInfo
    do {
      try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    } catch {
      Self.logger.error("Couldn't post notification: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Delivered review notifications (including an earlier summary) posted
  /// within the coalescing window.
  private func recentReviewNotifications(excluding jobID: UUID) async -> [UNNotification] {
    let cutoff = Date().addingTimeInterval(-Self.coalesceWindow)
    return await center.deliveredNotifications().filter {
      $0.request.content.categoryIdentifier == Self.reviewCategory
        && $0.date >= cutoff
        && $0.request.identifier != jobID.uuidString
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
      if let jobID {
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
    "\(count) batches ready to review"
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
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let info = response.notification.request.content.userInfo
    let jobID = (info["jobID"] as? String).flatMap { UUID(uuidString: $0) }
    let kind = info["kind"] as? String
    let action = response.actionIdentifier
    await MainActor.run {
      IntakeNotifier.shared.handle(action: action, jobID: jobID, kind: kind)
    }
  }
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
  private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

  /// Must run before the app finishes launching.
  func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      Task { @MainActor in
        IntakeBackgroundRefresh.shared.handle(refresh)
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

  private func handle(_ task: BGAppRefreshTask) {
    guard let model, model.settings.isAuthenticated else {
      task.setTaskCompleted(success: true)
      return
    }
    schedule()
    let coordinator = IntakeCoordinator.shared
    let work = Task { @MainActor in
      coordinator.drain(model: model)
      await coordinator.waitForDrain()
      task.setTaskCompleted(success: !Task.isCancelled)
    }
    task.expirationHandler = {
      // Jobs being read stay reading and resume on the next drain.
      Task { @MainActor in
        coordinator.cancelDrain()
        work.cancel()
      }
    }
  }

  /// The app moved to the background. Queue a refresh if the Inbox has work,
  /// and ask for time to finish a read that is under way.
  func appDidEnterBackground() {
    guard let model, model.settings.isAuthenticated else {
      return
    }
    if hasPendingWork {
      schedule()
    }
    let coordinator = IntakeCoordinator.shared
    guard coordinator.isBusy, backgroundTaskID == .invalid else {
      return
    }
    backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "intake-drain") { [weak self] in
      MainActor.assumeIsolated {
        coordinator.cancelDrain()
        self?.endBackgroundTask()
      }
    }
    coordinator.drain(model: model)
    Task { @MainActor [weak self] in
      await coordinator.waitForDrain()
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTaskID != .invalid else {
      return
    }
    UIApplication.shared.endBackgroundTask(backgroundTaskID)
    backgroundTaskID = .invalid
  }
}
