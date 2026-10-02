import AppIntents
import Foundation

enum InboxIntentHandoff {
  enum Error: Swift.Error, Equatable, CustomLocalizedStringResourceConvertible {
    case empty
    case payloadTooLarge

    var localizedStringResource: LocalizedStringResource {
      switch self {
      case .empty:
        return "Choose a value."
      case .payloadTooLarge:
        return "That file is too large for Halation. Use a smaller image or a shorter sentence."
      }
    }
  }

  static var store: InboxStore = .shared

  static func textWrite(_ text: String) throws -> InboxWrite {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw Error.empty
    }
    let data = Data(trimmed.utf8)
    guard data.count <= InboxStore.maxPayloadBytes else {
      throw Error.payloadTooLarge
    }
    return InboxWrite(
      source: .appIntent,
      kind: .text,
      filename: "payload.txt",
      data: data
    )
  }

  static func imageWrite(
    _ data: Data,
    filename: String,
    source: InboxSource = .appIntent
  ) throws -> InboxWrite {
    guard !data.isEmpty else {
      throw Error.empty
    }
    guard data.count <= InboxStore.maxPayloadBytes else {
      throw Error.payloadTooLarge
    }
    return InboxWrite(
      source: source,
      kind: .image,
      filename: filename,
      data: data
    )
  }

  @MainActor
  static func enqueue(_ write: InboxWrite) throws {
    try store.write(write)
    let fingerprint = IntentCatalogStore.shared.loadActive()?.connectionFingerprint
    CaptureRouter.shared.enqueue(
      CaptureRequest(kind: .inbox, connectionFingerprint: fingerprint, origin: .inbox)
    )
  }
}

struct AddFromTextIntent: AppIntent {
  static var title: LocalizedStringResource = "Add from Text"
  static var description = IntentDescription(
    "Opens Halation to read a sentence into a transaction. Nothing is saved until you confirm."
  )
  static let supportedModes: IntentModes = .foreground(.immediate)

  @Parameter(title: "Text")
  var text: String

  static var parameterSummary: some ParameterSummary {
    Summary("Add from \(\.$text)")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    let write: InboxWrite
    do {
      write = try InboxIntentHandoff.textWrite(text)
    } catch InboxIntentHandoff.Error.empty {
      throw $text.needsValueError()
    }
    try InboxIntentHandoff.enqueue(write)
    return .result()
  }
}
