import SwiftUI
import UIKit
import XCTest
@testable import HowMuch

@MainActor
final class IPadLayoutTests: XCTestCase {
  func testRegularAccountsShowsListAndRegisterTogether() async {
    let harness = SnapshotHarness.make()
    harness.model.ledgerPhase = .loaded
    guard let surface = SnapshotSurface(
      root: AccountsView()
        .environment(harness.model)
        .environment(\.horizontalSizeClass, .regular),
      size: CGSize(width: 1180, height: 820)
    ) else {
      XCTFail("regular accounts split needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    let appeared = await surface.waitUntil {
      surface.firstControl(labelContains: "Everyday") != nil
    }
    XCTAssertTrue(appeared, "regular accounts must show Everyday: \(surface.accessibilityLabels())")

    let captured = await surface.captureUntilOCR(
      contains: ["Everyday"],
      timeoutNanoseconds: 1_500_000_000
    )
    attachImage(captured.image, name: "regular-accounts-split")
    XCTAssertFalse(
      captured.isBlank,
      "regular accounts split rendered a blank surface. OCR: [\(captured.text)]"
    )

    let hasEveryday = captured.text.localizedStandardContains("Everyday")
      || surface.firstControl(labelContains: "Everyday") != nil
    XCTAssertTrue(hasEveryday, "regular split must keep Everyday in the list. OCR: [\(captured.text)] AX: \(surface.accessibilityLabels())")

    let hasRegisterChrome = captured.text.localizedStandardContains("Search")
      || surface.firstControl(labelContains: "Search") != nil
      || captured.text.localizedStandardContains("No Transactions")
      || surface.firstControl(labelContains: "No Transactions") != nil
    XCTAssertTrue(
      hasRegisterChrome,
      "regular split must show register chrome beside the list. OCR: [\(captured.text)] AX: \(surface.accessibilityLabels())"
    )
  }

  func testCompactAccountsStillPushesSingleColumn() async {
    let harness = SnapshotHarness.make()
    guard let surface = SnapshotSurface(
      root: AccountsView()
        .environment(harness.model)
        .environment(\.horizontalSizeClass, .compact),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("compact accounts overview needs a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    let appeared = await surface.waitUntil {
      surface.firstControl(label: "New Account") != nil
        || surface.firstControl(labelContains: "Everyday") != nil
    }
    XCTAssertTrue(appeared, "compact accounts must show the overview: \(surface.accessibilityLabels())")

    let captured = await surface.captureUntilOCR(
      contains: ["Accounts"],
      timeoutNanoseconds: 1_500_000_000
    )
    attachImage(captured.image, name: "compact-accounts-overview")
    XCTAssertFalse(
      captured.isBlank,
      "compact accounts overview rendered a blank surface. OCR: [\(captured.text)]"
    )

    let hasAccountsTitle = captured.text.localizedStandardContains("Accounts")
      || surface.firstControl(label: "Accounts") != nil
    XCTAssertTrue(hasAccountsTitle, "compact accounts must keep the Accounts title. OCR: [\(captured.text)] AX: \(surface.accessibilityLabels())")

    let hasShortcut = captured.text.localizedStandardContains("New")
      || captured.text.localizedStandardContains("Scheduled")
      || captured.text.localizedStandardContains("All")
      || surface.firstControl(label: "New") != nil
      || surface.firstControl(label: "Scheduled") != nil
      || surface.firstControl(label: "All") != nil
    XCTAssertTrue(hasShortcut, "compact accounts must keep ledger shortcuts. OCR: [\(captured.text)] AX: \(surface.accessibilityLabels())")

    let hasEveryday = captured.text.localizedStandardContains("Everyday")
      || surface.firstControl(labelContains: "Everyday") != nil
    XCTAssertTrue(hasEveryday, "compact accounts must list Everyday. OCR: [\(captured.text)] AX: \(surface.accessibilityLabels())")
  }

  func testPlanAndReflectSurfacesDoNotLeakFocusedRegister() {
    let model = AppModel()
    model.activeCaptureSurface = .accounts
    model.beginFocusedRegisterAccount("acct-everyday")
    XCTAssertEqual(model.visibleRegisterAccountID, "acct-everyday")
    XCTAssertEqual(model.addTransactionsOrigin(), .visibleRegister(accountID: "acct-everyday"))

    model.activeCaptureSurface = .plan
    XCTAssertNil(model.visibleRegisterAccountID)
    XCTAssertEqual(model.addTransactionsOrigin(), .lastUsedOpen)

    model.activeCaptureSurface = .reflect
    XCTAssertNil(model.visibleRegisterAccountID)
    XCTAssertEqual(model.addTransactionsOrigin(), .lastUsedOpen)

    model.activeCaptureSurface = .accounts
    XCTAssertEqual(model.visibleRegisterAccountID, "acct-everyday")
    XCTAssertEqual(model.addTransactionsOrigin(), .visibleRegister(accountID: "acct-everyday"))
  }

  func testRegularPaneWaitsForAccountsThenPicksDefault() {
    var pane: AccountsPane?
    pane = AccountsPaneSelection.reconciled(
      current: pane,
      isRegularWidth: true,
      knownAccountIDs: [],
      canChooseDefault: false,
      defaultPane: .all
    )
    XCTAssertNil(pane, "must not pin .all while accounts are still loading")

    pane = AccountsPaneSelection.reconciled(
      current: pane,
      isRegularWidth: true,
      knownAccountIDs: ["acct-rainy", "acct-everyday"],
      canChooseDefault: true,
      defaultPane: .account("acct-everyday")
    )
    XCTAssertEqual(pane, .account("acct-everyday"))
  }

  func testRegularPaneReplacesDeletedAccount() {
    let pane = AccountsPaneSelection.reconciled(
      current: .account("acct-gone"),
      isRegularWidth: true,
      knownAccountIDs: ["acct-everyday"],
      canChooseDefault: true,
      defaultPane: .account("acct-everyday")
    )
    XCTAssertEqual(pane, .account("acct-everyday"))
  }

  func testCompactClearsPaneSoOverviewDoesNotAutoPush() {
    let pane = AccountsPaneSelection.reconciled(
      current: .account("acct-everyday"),
      isRegularWidth: false,
      knownAccountIDs: ["acct-everyday"],
      canChooseDefault: true,
      defaultPane: .account("acct-everyday")
    )
    XCTAssertNil(pane)
  }

  func testRegularKeepsExplicitAllWhenAccountsArrive() {
    let pane = AccountsPaneSelection.reconciled(
      current: .all,
      isRegularWidth: true,
      knownAccountIDs: ["acct-everyday"],
      canChooseDefault: true,
      defaultPane: .account("acct-everyday")
    )
    XCTAssertEqual(pane, .all)
  }

  func testDefaultSelectionPrefersFavouriteThenFirstOpen() {
    let everyday = Account(
      id: "acct-everyday",
      name: "Everyday",
      icon: nil,
      type: "checking",
      onBudget: true,
      closed: false,
      balance: 0,
      clearedBalance: 0,
      unclearedBalance: 0,
      lastReconciledDate: nil,
      deleted: false
    )
    let travel = Account(
      id: "acct-travel",
      name: "Travel",
      icon: nil,
      type: "checking",
      onBudget: true,
      closed: false,
      balance: 0,
      clearedBalance: 0,
      unclearedBalance: 0,
      lastReconciledDate: nil,
      deleted: false
    )
    XCTAssertEqual(
      AccountsPane.defaultSelection(openAccounts: [everyday, travel], isFavourite: { $0 == "acct-travel" }),
      .account("acct-travel")
    )
    XCTAssertEqual(
      AccountsPane.defaultSelection(openAccounts: [everyday, travel], isFavourite: { _ in false }),
      .account("acct-everyday")
    )
    XCTAssertEqual(
      AccountsPane.defaultSelection(openAccounts: [], isFavourite: { _ in false }),
      .all
    )
  }

  func testAppTabCaptureSurfaceMapsPlanAndReflect() {
    XCTAssertEqual(AppTab.accounts.captureSurface, .accounts)
    XCTAssertEqual(AppTab.rewards.captureSurface, .rewards)
    XCTAssertEqual(AppTab.assistant.captureSurface, .assistant)
    XCTAssertEqual(AppTab.plan.captureSurface, .plan)
    XCTAssertEqual(AppTab.reflect.captureSurface, .reflect)
    XCTAssertNil(AppTab.add.captureSurface)
  }

  private func attachImage(_ image: UIImage, name: String) {
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
