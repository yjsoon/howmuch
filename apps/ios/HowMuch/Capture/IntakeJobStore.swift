import Foundation

/// Persists intake jobs in the app group as `Jobs/{id}/job.json`, with the
/// shared files under `Jobs/{id}/sources/`. Main app only: the share extension
/// writes the inbox, never jobs. Use from the main actor.
final class IntakeJobStore {
  static let shared = IntakeJobStore(container: IntakeJobStore.sharedContainer)

  /// The app group, except under the unit-test host: tests must not read jobs a
  /// simulator run left in the real container (they would render in snapshots).
  static let isUnitTestHost =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  static let sharedContainer: URL = {
    guard isUnitTestHost else {
      return InboxStore.defaultContainer()
    }
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("HowMuchTests-intake-\(UUID().uuidString)", isDirectory: true)
  }()

  let jobsDirectory: URL

  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(container: URL, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    jobsDirectory = container.appendingPathComponent("Jobs", isDirectory: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func directory(for id: UUID) -> URL {
    jobsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  func sourcesDirectory(for id: UUID) -> URL {
    directory(for: id).appendingPathComponent("sources", isDirectory: true)
  }

  func sourceURL(_ file: InboxSourceFile, jobID: UUID) -> URL {
    sourcesDirectory(for: jobID).appendingPathComponent(file.filename)
  }

  private func manifestURL(for id: UUID) -> URL {
    directory(for: id).appendingPathComponent("job.json")
  }

  func hasJob(_ id: UUID) -> Bool {
    fileManager.fileExists(atPath: manifestURL(for: id).path)
  }

  func load(_ id: UUID) -> IntakeJob? {
    guard let data = try? Data(contentsOf: manifestURL(for: id)) else {
      return nil
    }
    return try? decoder.decode(IntakeJob.self, from: data)
  }

  /// Where a job folder whose `job.json` cannot be read is moved, out of the
  /// way of `list()` but still on disk for inspection until `pruneQuarantine`.
  var quarantineDirectory: URL {
    jobsDirectory.appendingPathComponent("_quarantine", isDirectory: true)
  }

  /// Newest first. A job folder whose `job.json` is missing or unreadable is
  /// quarantined, not skipped forever and not deleted.
  func list() -> [IntakeJob] {
    let urls = (try? fileManager.contentsOfDirectory(
      at: jobsDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    var jobs: [IntakeJob] = []
    for url in urls {
      guard let id = UUID(uuidString: url.lastPathComponent) else {
        continue
      }
      if let job = load(id) {
        jobs.append(job)
      } else {
        quarantine(url)
      }
    }
    return jobs.sorted { $0.createdAt > $1.createdAt }
  }

  private func quarantine(_ url: URL) {
    try? fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
    var destination = quarantineDirectory.appendingPathComponent(url.lastPathComponent)
    if fileManager.fileExists(atPath: destination.path) {
      destination = quarantineDirectory.appendingPathComponent(
        "\(url.lastPathComponent)-\(Int(Date().timeIntervalSince1970))"
      )
    }
    try? fileManager.moveItem(at: url, to: destination)
  }

  /// Deletes quarantined folders last touched before `cutoff`.
  func pruneQuarantine(olderThan cutoff: Date) {
    let urls = (try? fileManager.contentsOfDirectory(
      at: quarantineDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    for url in urls {
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let modified, modified < cutoff {
        try? fileManager.removeItem(at: url)
      }
    }
  }

  /// Atomic: a reader sees the old file or the new one, never half of it.
  func save(_ job: IntakeJob) throws {
    try fileManager.createDirectory(at: directory(for: job.id), withIntermediateDirectories: true)
    let data = try encoder.encode(job)
    try data.write(to: manifestURL(for: job.id), options: .atomic)
  }

  /// Removes the job and everything it holds.
  func delete(_ id: UUID) {
    try? fileManager.removeItem(at: directory(for: id))
  }

  /// Removes the shared files but keeps the job record.
  func deleteSources(_ id: UUID) {
    try? fileManager.removeItem(at: sourcesDirectory(for: id))
  }

  /// Turns a claimed `Reading/{id}` item into a job in the `reading` state,
  /// moving its payload files into `sources/`. Safe to repeat after a crash:
  /// an existing job is kept and only files still in the Reading folder move.
  /// The caller discards the (now empty) Reading folder afterwards.
  func adopt(_ item: InboxItem, planID: String? = nil, connectionFingerprint: String? = nil) throws -> IntakeJob {
    let sources = sourcesDirectory(for: item.id)
    try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
    let job: IntakeJob
    if let existing = load(item.id) {
      job = existing
    } else {
      job = IntakeJob(
        id: item.id,
        createdAt: item.createdAt,
        origin: IntakeOrigin(source: item.source),
        sourceFiles: item.sources,
        accountID: item.accountID,
        decideAccount: item.decideAccount,
        hint: item.hint,
        note: item.note,
        contentHash: item.contentHash,
        state: .reading,
        planID: planID,
        connectionFingerprint: connectionFingerprint
      )
      try save(job)
    }
    for file in item.sources {
      let origin = item.payloadURL(for: file)
      let destination = sources.appendingPathComponent(file.filename)
      guard fileManager.fileExists(atPath: origin.path), !fileManager.fileExists(atPath: destination.path) else {
        continue
      }
      try fileManager.moveItem(at: origin, to: destination)
    }
    return job
  }
}
