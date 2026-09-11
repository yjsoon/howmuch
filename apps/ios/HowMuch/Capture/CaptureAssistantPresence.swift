import Foundation

enum CaptureAssistantPresence: Sendable {
  static let waitingCharactersPerSecond = 22.0
  static let replyCharactersPerSecond = 34.0
  static let pauseAfterLine: TimeInterval = 0.65
  static let stoppedCopy = "Stopped — nothing was saved."
  static let workingAccessibilityLabel = "Working on a reply"

  struct Frame: Equatable, Sendable {
    var visibleText: String
    var fullLine: String
    var showsCursor: Bool
  }

  static let textLines = [
    "Just a moment.",
    "Having a look at that.",
    "On it — won't be long.",
    "Let me read that through.",
    "Give me a second.",
    "I'll sort that now.",
    "One tick.",
    "Still with you.",
    "Taking a look now.",
    "Won't keep you hanging.",
  ]

  static let imageLines = [
    "Reading the slip.",
    "Looking over that photo.",
    "Picking the details out.",
    "Still reading that.",
    "Give me a second with the photo.",
    "Working through the picture.",
  ]

  static let fetchingLines = [
    "Checking what you've recorded.",
    "Looking that up in the ledger.",
    "Pulling the recorded spending.",
  ]

  static func revealedText(
    _ text: String,
    elapsed: TimeInterval,
    reduceMotion: Bool,
    charactersPerSecond: Double = waitingCharactersPerSecond
  ) -> String {
    if reduceMotion || text.isEmpty {
      return text
    }
    guard charactersPerSecond > 0 else {
      return text
    }
    let visibleCount = min(text.count, max(0, Int(elapsed * charactersPerSecond)))
    if visibleCount <= 0 {
      return ""
    }
    if visibleCount >= text.count {
      return text
    }
    return String(text.prefix(visibleCount))
  }

  static func script(messageID: UUID, hasAttachments: Bool, phase: CaptureAIPhase?) -> [String] {
    let pool = hasAttachments ? imageLines : textLines
    let start = stableIndex(messageID, modulo: pool.count)
    let take = min(4, pool.count)
    var lines = (0..<take).map { pool[(start + $0) % pool.count] }
    if phase == .fetching {
      let fetch = fetchingLines[stableIndex(messageID, modulo: fetchingLines.count)]
      if lines.count > 1 {
        lines[1] = fetch
      } else {
        lines.append(fetch)
      }
    }
    return lines
  }

  static func waitingFrame(
    messageID: UUID,
    hasAttachments: Bool,
    phase: CaptureAIPhase?,
    elapsed: TimeInterval,
    reduceMotion: Bool
  ) -> Frame {
    let lines = script(messageID: messageID, hasAttachments: hasAttachments, phase: phase)
    return frame(lines: lines, elapsed: elapsed, reduceMotion: reduceMotion, phase: phase)
  }

  static func frame(
    lines: [String],
    elapsed: TimeInterval,
    reduceMotion: Bool,
    phase: CaptureAIPhase? = nil
  ) -> Frame {
    let lines = lines.isEmpty ? ["Just a moment."] : lines
    if reduceMotion {
      let line: String
      if phase == .fetching, lines.count > 1 {
        line = lines[1]
      } else {
        line = lines[0]
      }
      return Frame(visibleText: line, fullLine: line, showsCursor: false)
    }
    var remaining = max(0, elapsed)
    for (index, line) in lines.enumerated() {
      let typing = Double(max(line.count, 1)) / waitingCharactersPerSecond
      let isLast = index == lines.count - 1
      if isLast {
        let visible = revealedText(line, elapsed: remaining, reduceMotion: false)
        return Frame(visibleText: visible, fullLine: line, showsCursor: true)
      }
      let span = typing + pauseAfterLine
      if remaining < span {
        let inHold = remaining >= typing
        let visible = inHold ? line : revealedText(line, elapsed: remaining, reduceMotion: false)
        return Frame(visibleText: visible, fullLine: line, showsCursor: !inHold)
      }
      remaining -= span
    }
    let last = lines[lines.count - 1]
    return Frame(visibleText: last, fullLine: last, showsCursor: true)
  }

  static func stableIndex(_ id: UUID, modulo: Int) -> Int {
    guard modulo > 0 else {
      return 0
    }
    let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
    let sum = bytes.reduce(0) { $0 + Int($1) }
    return sum % modulo
  }
}
