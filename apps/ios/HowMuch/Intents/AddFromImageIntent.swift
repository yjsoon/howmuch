import AppIntents
import UniformTypeIdentifiers

struct AddFromImageIntent: AppIntent {
  static var title: LocalizedStringResource = "Add from Image"
  static var description = IntentDescription(
    "Opens Halation to read a screenshot or receipt. Nothing is saved until you confirm."
  )
  static let supportedModes: IntentModes = .foreground(.immediate)

  @Parameter(title: "Image")
  var image: IntentFile

  static var parameterSummary: some ParameterSummary {
    Summary("Add from \(\.$image)")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    let write: InboxWrite
    do {
      write = try InboxIntentHandoff.imageWrite(image.data, filename: Self.filename(for: image))
    } catch InboxIntentHandoff.Error.empty {
      throw $image.needsValueError()
    }
    try InboxIntentHandoff.enqueue(write)
    return .result()
  }

  static func filename(for file: IntentFile) -> String {
    if let type = file.type {
      if type.conforms(to: .jpeg) {
        return "payload.jpg"
      }
      if type.conforms(to: .png) {
        return "payload.png"
      }
      if type.conforms(to: .heic) || type.conforms(to: .heif) {
        return "payload.heic"
      }
      if type.conforms(to: .webP) {
        return "payload.webp"
      }
    }
    return "payload.img"
  }
}
