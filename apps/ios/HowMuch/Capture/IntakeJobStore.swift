import Foundation

/// Persists intake jobs in the app group as `Jobs/{id}/job.json`, with the
/// shared files under `Jobs/{id}/sources/`. Main app only: the share extension
/// writes the inbox, never jobs. Use from the main actor.
final class IntakeJobStore {
  static let shared = IntakeJobStore(container: InboxStore.defaultContainer())

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

  /// Newest first. A folder whose `job.json` cannot be read is skipped, not deleted.
  func list() -> [IntakeJob] {
    let urls = (try? fileManager.contentsOfDirectory(
      at: jobsDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    return urls
      .compactMap { UUID(uuidString: $0.lastPathComponent) }
      .compactMap { load($0) }
      .sorted { $0.createdAt > $1.createdAt }
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
  func adopt(_ item: InboxItem) throws -> IntakeJob {
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
        state: .reading
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
