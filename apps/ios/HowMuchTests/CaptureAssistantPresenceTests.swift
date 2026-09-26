import XCTest
@testable import HowMuch

final class CaptureAssistantPresenceTests: XCTestCase {
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
