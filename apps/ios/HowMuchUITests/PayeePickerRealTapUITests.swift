import ObjectiveC
import XCTest

/// Real-touch reproduction of the payee picker pop getting stuck when a payee
/// is tapped while the picker's own push/search animations are still running.
/// NOT FOR MERGING. Needs a local API on 127.0.0.1:8797 (see the PR body for
/// setup); it is not in the HowMuch scheme and runs only via HowMuchUITests.
final class PayeePickerRealTapUITests: XCTestCase {
  nonisolated(unsafe) static var skipQuiescence = false
  nonisolated(unsafe) static var installed = false

  static func installQuiescenceSwitch() {
    guard !installed, let cls = NSClassFromString("XCUIApplicationProcess") else { return }
    installed = true
    for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
      let selector = NSSelectorFromString(name)
      guard let method = class_getInstanceMethod(cls, selector) else {
        print("REPRO: missing \(name)")
        continue
      }
      typealias Original = @convention(c) (AnyObject, Selector) -> Bool
      let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
      let block: @convention(block) (AnyObject) -> Bool = { receiver in
        PayeePickerRealTapUITests.skipQuiescence || original(receiver, selector)
      }
      method_setImplementation(method, imp_implementationWithBlock(block))
    }
  }

  private var env: [String: String] { ProcessInfo.processInfo.environment }

  override func setUp() {
    continueAfterFailure = true
    Self.installQuiescenceSwitch()
  }

  @MainActor
  func testSignInToLocalServer() throws {
    let app = XCUIApplication()
    app.launch()
    if !app.textFields["Username"].waitForExistence(timeout: 5) {
      if app.buttons["Add Transaction"].exists { return }
    }
    let server = app.textFields.element(boundBy: 0)
    server.tap()
    server.press(forDuration: 1.2)
    if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
    server.typeText(XCUIKeyboardKey.delete.rawValue)
    server.typeText(env["REPRO_SERVER"] ?? "http://127.0.0.1:8797")
    app.textFields["Username"].tap()
    app.textFields["Username"].typeText("repro")
    app.secureTextFields["Password"].tap()
    app.secureTextFields["Password"].typeText("repro-password-123")
    app.buttons["Sign in"].tap()
    sleep(3)
    attach(app, "after-sign-in")
    if app.buttons["Save"].exists { app.buttons["Save"].tap() }
    sleep(2)
    attach(app, "after-save")
  }

  /// One synthesised HID event record holding both touches, so the gap between
  /// the push tap and the payee tap is exact rather than subject to XCTest's
  /// per-call latency.
  private func synthesize(_ taps: [(CGPoint, Double)]) -> Bool {
    guard let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type,
          let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type else {
      print("REPRO no synthesis classes")
      return false
    }
    typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> Unmanaged<AnyObject>
    typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Unmanaged<AnyObject>
    typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
    typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    typealias Synth = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool
    let alloc = NSSelectorFromString("alloc")
    let recordRaw = recordClass.perform(alloc)!.takeUnretainedValue()
    let initRecord = NSSelectorFromString("initWithName:interfaceOrientation:")
    let record = unsafeBitCast(recordRaw.method(for: initRecord), to: InitRecord.self)(recordRaw, initRecord, "payee-sweep", 1).takeUnretainedValue()
    for (point, offset) in taps {
      let pathRaw = pathClass.perform(alloc)!.takeUnretainedValue()
      let initPath = NSSelectorFromString("initForTouchAtPoint:offset:")
      let path = unsafeBitCast(pathRaw.method(for: initPath), to: InitPath.self)(pathRaw, initPath, point, offset).takeUnretainedValue()
      let lift = NSSelectorFromString("liftUpAtOffset:")
      unsafeBitCast(path.method(for: lift), to: Lift.self)(path, lift, offset + 0.06)
      let addSel = NSSelectorFromString("addPointerEventPath:")
      unsafeBitCast(record.method(for: addSel), to: Add.self)(record, addSel, path)
    }
    let synth = NSSelectorFromString("synthesizeWithError:")
    var error: Unmanaged<NSError>?
    let ok = unsafeBitCast(record.method(for: synth), to: Synth.self)(record, synth, &error)
    if !ok { print("REPRO synth error \(String(describing: error?.takeUnretainedValue()))") }
    return ok
  }

  /// Exact-gap sweep: the push tap and the payee tap travel in one HID record.
  @MainActor
  func testSynthesisedGapSweep() throws {
    let viaRow = env["REPRO_VIA_ROW"] == "1"
    let gaps = (env["REPRO_GAPS_MS"] ?? "300,350,400,450,500,550,600,650,700,750,800,900,1000")
      .split(separator: ",").compactMap { Int($0) }
    let rounds = Int(env["REPRO_ROUNDS"] ?? "1") ?? 1
    let relaunchEvery = Int(env["REPRO_RELAUNCH_EVERY"] ?? "1") ?? 1
    let app = XCUIApplication()
    let singleRecord = env["REPRO_SINGLE_RECORD"] == "1"
    var tally: [Int: (ok: Int, missed: Int, noSelect: Int, stuck: Int)] = [:]
    var openFailures = 0
    var payeeRowPoint = CGPoint.zero
    var stuck: [String] = []
    var iteration = 0
    var payeePoint: CGPoint?
    var pushPoint: CGPoint?
    var cancelPoint = CGPoint.zero
    app.launch()
    for round in 0..<rounds {
      for gap in gaps {
        if iteration > 0, iteration % relaunchEvery == 0 {
          app.terminate()
          app.launch()
        }
        iteration += 1
        guard openManualForm(app) else {
          openFailures += 1
          print("REPRO OPEN-FAILED iteration \(iteration) state=\(describeState(app))\n\(app.debugDescription.prefix(6000))")
          attach(app, "open-failed-\(iteration)")
          XCTFail("could not open manual form (iteration \(iteration))")
          app.terminate()
          app.launch()
          continue
        }
        if payeePoint == nil {
          let pushElement = viaRow ? payeeRow(app) : app.buttons["next"]
          let pf = pushElement.frame
          pushPoint = CGPoint(x: pf.midX, y: pf.midY)
          let rf = payeeRow(app).frame
          payeeRowPoint = CGPoint(x: rf.midX, y: rf.midY)
          let cf = app.buttons["Cancel"].frame
          cancelPoint = CGPoint(x: cf.midX, y: cf.midY)
          guard let vector = learnPayeePoint(app, viaRow: viaRow) else { XCTFail("no payee row"); return }
          payeePoint = CGPoint(x: vector.dx, y: vector.dy)
          print("REPRO push point \(pushPoint!) payee point \(payeePoint!) payee row \(payeeRowPoint) cancel \(cancelPoint)")
          guard openManualForm(app) else { XCTFail("reopen failed"); return }
        }
        let label = "r\(round) gap=\(gap)ms launchIter=\((iteration - 1) % relaunchEvery)"
        Self.skipQuiescence = true
        let sent: Bool
        if singleRecord {
          // One pointer: tap the push control, then re-press on the payee
          // `gap` ms after the first touch-down. Exact relative timing.
          sent = synthesizeDoublePress(first: pushPoint!, second: payeePoint!, gap: Double(gap) / 1000)
        } else {
          let t0 = Date()
          var ok = synthesize([(pushPoint!, 0)])
          let pushDone = Date()
          let wait = pushDone.addingTimeInterval(Double(gap) / 1000).timeIntervalSinceNow
          if wait > 0 { Thread.sleep(forTimeInterval: wait) }
          let t1 = Date()
          ok = synthesize([(payeePoint!, 0)]) && ok
          let t2 = Date()
          print("REPRO timing gap=\(gap) pushCall=\(ms(pushDone.timeIntervalSince(t0))) payeeStart=\(ms(t1.timeIntervalSince(pushDone))) payeeCall=\(ms(t2.timeIntervalSince(t1)))")
          sent = ok
        }
        Self.skipQuiescence = false
        guard sent else { XCTFail("synthesis failed"); return }
        var entry = tally[gap] ?? (0, 0, 0, 0)
        // Let any transition run to completion (UIKit's are well under 1 s).
        sleep(2)
        let firstState = describeState(app)
        if env["REPRO_SHOT_ALL"] == "1" { attach(app, "first-\(iteration)-gap\(gap)") }
        var state = firstState
        if state == "picker" {
          // The payee tap was swallowed (e.g. mid-push). Pick slowly instead.
          entry.missed += 1
          app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: payeePoint!.x, dy: payeePoint!.y)).tap()
          sleep(2)
          state = describeState(app)
        }
        var selected = state == "form" && !app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Choose Payee")).firstMatch.exists
        // Orphan check: the popped picker's search must not survive on the
        // form. It shows as a keyboard or stray search field, and it hides the
        // form's navigation bar (and Cancel with it).
        var keyboard = app.keyboards.firstMatch.exists
        var strayField = searchField(app).exists
        var cancelShown = app.buttons["Cancel"].exists
        var clean = state == "form" && !keyboard && !strayField && cancelShown
        if !clean {
          // A slow pop is not a stuck one: the baseline orphan never cleared.
          attach(app, "unsettled-\(iteration)")
          sleep(3)
          state = describeState(app)
          keyboard = app.keyboards.firstMatch.exists
          strayField = searchField(app).exists
          cancelShown = app.buttons["Cancel"].exists
          clean = state == "form" && !keyboard && !strayField && cancelShown
          selected = state == "form" && !app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Choose Payee")).firstMatch.exists
          print("REPRO recheck \(label) clean=\(clean) state=\(state)")
        }
        let outcome = "first=\(firstState) state=\(state) selected=\(selected) keyboard=\(keyboard) strayField=\(strayField) cancel=\(cancelShown)"
        if clean && selected {
          entry.ok += 1
          print("REPRO ok \(label) first=\(firstState)")
        } else if clean {
          entry.noSelect += 1
          print("REPRO noselect \(label) \(outcome)")
          attach(app, "noselect-\(iteration)")
        } else {
          entry.stuck += 1
          stuck.append(label)
          print("REPRO STUCK \(label) \(outcome)")
          attach(app, "stuck-\(iteration)")
          print("REPRO hierarchy:\n\(app.debugDescription.suffix(8000))")
          if env["REPRO_HALT_ON_STUCK"] == "1" {
            print("REPRO HALT leaving app in stuck state")
            sleep(900)
            XCTFail("stuck: \(label)")
            return
          }
        }
        // Fresh process for every iteration keeps each one independent.
        app.terminate()
        app.launch()
        tally[gap] = entry
      }
    }
    for gap in gaps { print("REPRO TALLY gap=\(gap) \(tally[gap] ?? (0, 0, 0, 0))") }
    print("REPRO SUMMARY synthesised viaRow=\(viaRow) single=\(singleRecord) iterations=\(iteration) stuck=\(stuck.count) openFailures=\(openFailures)")
    XCTAssertTrue(stuck.isEmpty, "stuck: \(stuck)")
  }

  @MainActor
  private func payeeRow(_ app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label BEGINSWITH[c] %@", "Choose Payee", "Payee")).firstMatch
  }

  private func synthesizeDoublePress(first: CGPoint, second: CGPoint, gap: Double) -> Bool {
    guard let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type,
          let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type else { return false }
    typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> Unmanaged<AnyObject>
    typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Unmanaged<AnyObject>
    typealias AtOffset = @convention(c) (AnyObject, Selector, Double) -> Void
    typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
    typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    typealias Synth = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool
    let alloc = NSSelectorFromString("alloc")
    let recordRaw = recordClass.perform(alloc)!.takeUnretainedValue()
    let initRecord = NSSelectorFromString("initWithName:interfaceOrientation:")
    let record = unsafeBitCast(recordRaw.method(for: initRecord), to: InitRecord.self)(recordRaw, initRecord, "double-press", 1).takeUnretainedValue()
    let pathRaw = pathClass.perform(alloc)!.takeUnretainedValue()
    let initPath = NSSelectorFromString("initForTouchAtPoint:offset:")
    let path = unsafeBitCast(pathRaw.method(for: initPath), to: InitPath.self)(pathRaw, initPath, first, 0).takeUnretainedValue()
    let lift = NSSelectorFromString("liftUpAtOffset:")
    let press = NSSelectorFromString("pressDownAtOffset:")
    let move = NSSelectorFromString("moveToPoint:atOffset:")
    unsafeBitCast(path.method(for: lift), to: AtOffset.self)(path, lift, 0.06)
    unsafeBitCast(path.method(for: move), to: Move.self)(path, move, second, max(0.07, gap - 0.001))
    unsafeBitCast(path.method(for: press), to: AtOffset.self)(path, press, max(0.08, gap))
    unsafeBitCast(path.method(for: lift), to: AtOffset.self)(path, lift, max(0.08, gap) + 0.06)
    let addSel = NSSelectorFromString("addPointerEventPath:")
    unsafeBitCast(record.method(for: addSel), to: Add.self)(record, addSel, path)
    let synth = NSSelectorFromString("synthesizeWithError:")
    var error: Unmanaged<NSError>?
    let ok = unsafeBitCast(record.method(for: synth), to: Synth.self)(record, synth, &error)
    if !ok { print("REPRO synth error \(String(describing: error?.takeUnretainedValue()))") }
    return ok
  }

  @MainActor
  func testPickerScreens() throws {
    let app = XCUIApplication()
    app.launch()
    let tag = env["REPRO_TAG"] ?? "default"
    guard openManualForm(app) else { XCTFail("open failed"); return }
    app.buttons["next"].tap()
    XCTAssertTrue(searchField(app).waitForExistence(timeout: 5))
    sleep(2)
    if app.buttons["Continue"].exists { app.buttons["Continue"].tap(); sleep(1) }
    attach(app, "payee-empty-\(tag)")
    app.typeText("Sta")
    sleep(1)
    attach(app, "payee-typed-\(tag)")
    XCTAssertTrue(app.buttons["Clear text"].exists)
    app.buttons["Clear text"].tap()
    sleep(1)
    let cleared = searchField(app).value as? String ?? ""
    XCTAssertTrue(cleared.isEmpty || cleared == "Search or add a payee", "clear left: \(cleared)")
  }

  /// Category picker: tap "Choose Category", then a category `gap` ms later.
  @MainActor
  func testCategoryFastTap() throws {
    let gaps = (env["REPRO_GAPS_MS"] ?? "0,200,300,375,400,425,500,700,1000")
      .split(separator: ",").compactMap { Int($0) }
    let rounds = Int(env["REPRO_ROUNDS"] ?? "2") ?? 2
    let app = XCUIApplication()
    app.launch()
    var rowPoint: CGPoint?
    var itemPoint: CGPoint?
    var stuck: [String] = []
    var ok = 0
    var missed = 0
    for round in 0..<rounds {
      for gap in gaps {
        guard openManualForm(app) else { XCTFail("open failed"); return }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Choose Category")).firstMatch
        if rowPoint == nil {
          let f = row.frame
          rowPoint = CGPoint(x: f.midX, y: f.midY)
          row.tap()
          let item = app.buttons[env["REPRO_CATEGORY"] ?? "Groceries"].firstMatch
          guard item.waitForExistence(timeout: 5) else { XCTFail("no category"); return }
          sleep(1)
          let itf = item.frame
          itemPoint = CGPoint(x: itf.midX, y: itf.midY)
          attach(app, "category-settled")
          print("REPRO category row \(rowPoint!) item \(itemPoint!)")
          app.terminate()
          app.launch()
          guard openManualForm(app) else { XCTFail("reopen failed"); return }
        }
        Self.skipQuiescence = true
        _ = synthesize([(rowPoint!, 0)])
        let wait = Date().addingTimeInterval(Double(gap) / 1000).timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        _ = synthesize([(itemPoint!, 0)])
        Self.skipQuiescence = false
        sleep(2)
        var onPicker = searchField(app).exists && !app.staticTexts["Add Transaction"].exists
        if onPicker {
          missed += 1
          app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: itemPoint!.x, dy: itemPoint!.y)).tap()
          sleep(2)
          onPicker = searchField(app).exists && !app.staticTexts["Add Transaction"].exists
        }
        let clean = app.staticTexts["Add Transaction"].exists && !app.keyboards.firstMatch.exists
          && !searchField(app).exists && app.buttons["Cancel"].exists
        let chosen = !row.exists
        let label = "r\(round) gap=\(gap)"
        if clean && chosen {
          ok += 1
          print("REPRO cat ok \(label)")
        } else {
          stuck.append(label)
          print("REPRO cat STUCK \(label) clean=\(clean) chosen=\(chosen) onPicker=\(onPicker)")
          attach(app, "cat-stuck-\(round)-\(gap)")
        }
        app.terminate()
        app.launch()
      }
    }
    print("REPRO CAT SUMMARY ok=\(ok) missed=\(missed) stuck=\(stuck.count)")
    XCTAssertTrue(stuck.isEmpty, "stuck: \(stuck)")
  }

  @MainActor
  private func openManualForm(_ app: XCUIApplication) -> Bool {
    let add = app.buttons["Add Transaction"].firstMatch
    guard add.waitForExistence(timeout: 15) else { return false }
    add.tap()
    guard app.buttons["1"].waitForExistence(timeout: 5) else { return false }
    app.buttons["1"].tap()
    app.buttons["2"].tap()
    return app.buttons["next"].waitForExistence(timeout: 2)
  }

  @MainActor
  private func learnPayeePoint(_ app: XCUIApplication, viaRow: Bool) -> CGVector? {
    app.buttons["next"].tap()
    let search = searchField(app)
    guard search.waitForExistence(timeout: 5) else { return nil }
    sleep(1)
    attach(app, "picker-settled")
    let keyboardTip = app.buttons["Continue"]
    if keyboardTip.exists { keyboardTip.tap(); sleep(1) }
    let row = app.buttons[env["REPRO_PAYEE"] ?? "SimplyGo"].firstMatch
    guard row.waitForExistence(timeout: 3) else { return nil }
    let frame = row.frame
    print("REPRO payee row frame \(frame)")
    let vector = CGVector(dx: frame.midX, dy: frame.midY)
    row.tap()
    let back = formIsBack(app)
    print("REPRO learn step: settled selection returned to form = \(back)")
    attach(app, "after-settled-selection")
    closeForm(app)
    return vector
  }

  @MainActor
  private func closeForm(_ app: XCUIApplication) {
    if searchField(app).exists, app.navigationBars.buttons.firstMatch.exists {
      app.navigationBars.buttons.firstMatch.tap()
    }
    let cancel = app.buttons["Cancel"]
    if cancel.waitForExistence(timeout: 2) { cancel.tap() }
    let discard = app.buttons["Discard"]
    if discard.waitForExistence(timeout: 1) { discard.tap() }
    let close = app.buttons["Close"]
    if close.waitForExistence(timeout: 2) { close.tap() }
  }

  private func ms(_ t: TimeInterval) -> Int { Int(t * 1000) }

  /// The picker's search field, whether system search or the inline field.
  @MainActor
  private func searchField(_ app: XCUIApplication) -> XCUIElement {
    let kinds = NSPredicate(
      format: "(elementType == %lu OR elementType == %lu) AND (placeholderValue BEGINSWITH[c] 'Search' OR label BEGINSWITH[c] 'Search')",
      XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.searchField.rawValue
    )
    return app.descendants(matching: .any).matching(kinds).firstMatch
  }

  @MainActor
  private func describeState(_ app: XCUIApplication) -> String {
    let title = app.staticTexts["Add Transaction"].exists
    let search = searchField(app).exists
    switch (title, search) {
    case (true, false): return "form"
    case (false, true): return "picker"
    default: return "other(title=\(title) search=\(search))"
    }
  }

  /// The manual form is back in front: its title shows and no payee search field remains.
  @MainActor
  private func formIsBack(_ app: XCUIApplication, timeout: TimeInterval = 4) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if app.staticTexts["Add Transaction"].exists && !searchField(app).exists { return true }
      Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    return false
  }

  @MainActor
  private func attach(_ app: XCUIApplication, _ name: String) {
    let shot = app.screenshot()
    if let dir = env["REPRO_SHOT_DIR"] {
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
