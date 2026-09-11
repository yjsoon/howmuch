import XCTest
@testable import HowMuch

final class CaptureAssistantPresenceTests: XCTestCase {
  func testTypewriterRevealsCharactersByElapsedTime() {
    let text = "Having a look."
    XCTAssertEqual(
      CaptureAssistantPresence.revealedText(text, elapsed: 0, reduceMotion: false),
      ""
    )
    let halfElapsed = Double(text.count) / (2 * CaptureAssistantPresence.waitingCharactersPerSecond)
    XCTAssertEqual(
      CaptureAssistantPresence.revealedText(text, elapsed: halfElapsed, reduceMotion: false).count,
      text.count / 2
    )
    XCTAssertEqual(
      CaptureAssistantPresence.revealedText(text, elapsed: 10, reduceMotion: false),
      text
    )
    XCTAssertEqual(
      CaptureAssistantPresence.revealedText(text, elapsed: 0, reduceMotion: true),
      text
    )
  }

  func testWaitingScriptIsStableAndVariesByMessage() {
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let a = CaptureAssistantPresence.script(messageID: first, hasAttachments: false, phase: nil)
    let again = CaptureAssistantPresence.script(messageID: first, hasAttachments: false, phase: nil)
    XCTAssertEqual(a, again)
    XCTAssertEqual(Set(a).count, a.count, "A turn should not repeat the same waiting line")
    XCTAssertEqual(a.count, 4)
    let b = CaptureAssistantPresence.script(messageID: second, hasAttachments: false, phase: nil)
    XCTAssertNotEqual(a, b)
  }

  func testWaitingCopyCyclesToTheNextLineAfterAPause() {
    let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let script = CaptureAssistantPresence.script(messageID: id, hasAttachments: false, phase: nil)
    let early = CaptureAssistantPresence.waitingFrame(
      messageID: id,
      hasAttachments: false,
      phase: nil,
      elapsed: 0.2,
      reduceMotion: false
    )
    XCTAssertEqual(early.fullLine, script[0])
    XCTAssertTrue(script[0].hasPrefix(early.visibleText))
    XCTAssertTrue(early.showsCursor)

    let afterFirst =
      Double(script[0].count) / CaptureAssistantPresence.waitingCharactersPerSecond
      + CaptureAssistantPresence.pauseAfterLine
      + 0.05
    let next = CaptureAssistantPresence.waitingFrame(
      messageID: id,
      hasAttachments: false,
      phase: nil,
      elapsed: afterFirst,
      reduceMotion: false
    )
    XCTAssertEqual(next.fullLine, script[1])
  }

  func testReduceMotionShowsTheCurrentLineInFull() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let script = CaptureAssistantPresence.script(messageID: id, hasAttachments: false, phase: nil)
    let frame = CaptureAssistantPresence.waitingFrame(
      messageID: id,
      hasAttachments: false,
      phase: nil,
      elapsed: 0,
      reduceMotion: true
    )
    XCTAssertEqual(frame.visibleText, script[0])
    XCTAssertFalse(frame.showsCursor)
  }

  func testPhotoTurnsUseSlipCopyAndFetchingNamesTheLedger() {
    let id = UUID(uuidString: "99999999-0000-0000-0000-000000000001")!
    let spoken = CaptureAssistantPresence.script(messageID: id, hasAttachments: false, phase: nil)
    let photo = CaptureAssistantPresence.script(messageID: id, hasAttachments: true, phase: nil)
    XCTAssertNotEqual(spoken[0], photo[0])
    XCTAssertTrue(CaptureAssistantPresence.imageLines.contains(photo[0]))

    let fetching = CaptureAssistantPresence.script(messageID: id, hasAttachments: false, phase: .fetching)
    XCTAssertTrue(CaptureAssistantPresence.fetchingLines.contains(fetching[1]))
    let reduced = CaptureAssistantPresence.waitingFrame(
      messageID: id,
      hasAttachments: false,
      phase: .fetching,
      elapsed: 0,
      reduceMotion: true
    )
    XCTAssertEqual(reduced.visibleText, fetching[1])
  }

  func testLongWaitLandsOnTheLastLineFullyTyped() {
    let id = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
    let script = CaptureAssistantPresence.script(messageID: id, hasAttachments: false, phase: nil)
    let frame = CaptureAssistantPresence.waitingFrame(
      messageID: id,
      hasAttachments: false,
      phase: nil,
      elapsed: 12,
      reduceMotion: false
    )
    XCTAssertEqual(frame.fullLine, script.last)
    XCTAssertEqual(frame.visibleText, script.last)
    XCTAssertTrue(frame.showsCursor)
  }
}
