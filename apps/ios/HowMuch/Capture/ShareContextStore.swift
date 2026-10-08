import Foundation

struct ShareAccount: Codable, Equatable, Sendable, Identifiable {
  var id: String
  var name: String
  var isClosed: Bool
}

/// What the share extension may know about the signed-in app: written by the
/// app, read by the extension. Never holds a session token.
struct ShareContext: Codable, Equatable, Sendable {
  var isSignedIn: Bool
  var lastUsedOpenAccountID: String?
  var accounts: [ShareAccount]
  var writtenAt: Date

  var openAccounts: [ShareAccount] {
    accounts.filter { !$0.isClosed }
  }

  /// Last-used open account, else the first open account.
  var defaultAccountID: String? {
    let open = openAccounts
    if let last = lastUsedOpenAccountID, open.contains(where: { $0.id == last }) {
      return last
    }
    return open.first?.id
  }
}

struct ShareContextStore: Sendable {
  let fileURL: URL

  init(container: URL = InboxStore.defaultContainer()) {
    fileURL = container
      .appendingPathComponent("Intake", isDirectory: true)
      .appendingPathComponent("share-context.json")
  }

  static let shared = ShareContextStore()

  func read() -> ShareContext? {
    guard let data = try? Data(contentsOf: fileURL) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(ShareContext.self, from: data)
  }

  func write(_ context: ShareContext) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(context) else {
      return
    }
    let directory = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: fileURL, options: .atomic)
  }

  func remove() {
    try? FileManager.default.removeItem(at: fileURL)
  }
}
