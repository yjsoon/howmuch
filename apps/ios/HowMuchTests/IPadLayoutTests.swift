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
        .environment(RootChromeState())
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
        .environment(RootChromeState())
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

  func testCompactRefreshKeepsPushedRegister() {
    let pane = AccountsPaneSelection.reconciled(
      current: .account("acct-everyday"),
      isRegularWidth: false,
      knownAccountIDs: ["acct-everyday"],
      canChooseDefault: false,
      defaultPane: .all
    )
    XCTAssertEqual(pane, .account("acct-everyday"))
  }

  func testCompactPrunesDeletedAccount() {
    let pane = AccountsPaneSelection.reconciled(
      current: .account("acct-gone"),
      isRegularWidth: false,
      knownAccountIDs: ["acct-everyday"],
      canChooseDefault: true,
      defaultPane: .account("acct-everyday")
    )
    XCTAssertNil(pane)
  }

  func testLeavingRegularWidthClearsPaneSoCompactDoesNotAutoPush() {
    let pane = AccountsPaneSelection.afterSizeClassChange(
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

  func testPhoneDoesNotUseSidebarEvenWhenRegularWidth() {
    XCTAssertFalse(
      RootChrome.usesSidebar(idiom: .phone, horizontalSizeClass: .compact)
    )
    XCTAssertFalse(
      RootChrome.usesSidebar(idiom: .phone, horizontalSizeClass: .regular)
    )
  }

  func testPadRegularUsesSidebar() {
    XCTAssertTrue(
      RootChrome.usesSidebar(idiom: .pad, horizontalSizeClass: .regular)
    )
    XCTAssertFalse(
      RootChrome.usesSidebar(idiom: .pad, horizontalSizeClass: .compact)
    )
  }

  func testAppTabMapsCompactAndSidebarDestinations() {
    XCTAssertEqual(AppTab.compactDestinations, [.accounts, .rewards, .reflect])
    XCTAssertEqual(AppTab.accounts.captureSurface, .accounts)
    XCTAssertEqual(AppTab.rewards.captureSurface, .rewards)
    XCTAssertEqual(AppTab.reflect.captureSurface, .reflect)
    XCTAssertEqual(AppTab.plan.captureSurface, .plan)
    XCTAssertEqual(AppTab.assistant.captureSurface, .assistant)
    XCTAssertEqual(AppTab.accounts.compactBarSelection, .accounts)
    XCTAssertEqual(AppTab.rewards.compactBarSelection, .rewards)
    XCTAssertEqual(AppTab.reflect.compactBarSelection, .reflect)
    XCTAssertNil(AppTab.plan.compactBarSelection)
    XCTAssertNil(AppTab.assistant.compactBarSelection)
    XCTAssertEqual(CompactBarSelection.accounts.tab, .accounts)
    XCTAssertNil(CompactBarSelection.addTransactions.tab)
  }

  func testOpenMorePlanFromAccountsDoesNotLeakFocusedRegister() {
    let model = AppModel()
    let chrome = RootChromeState()
    chrome.tab = .accounts
    model.activeCaptureSurface = chrome.captureSurface
    model.beginFocusedRegisterAccount("acct-everyday")
    XCTAssertEqual(model.visibleRegisterAccountID, "acct-everyday")
    XCTAssertEqual(model.addTransactionsOrigin(), .visibleRegister(accountID: "acct-everyday"))

    chrome.openMore(.plan)
    model.activeCaptureSurface = chrome.captureSurface
    XCTAssertEqual(chrome.captureSurface, .plan)
    XCTAssertEqual(chrome.overflow(on: .accounts), .plan)
    XCTAssertNil(model.visibleRegisterAccountID)
    XCTAssertEqual(model.addTransactionsOrigin(), .lastUsedOpen)

    chrome.openMore(.plan)
    XCTAssertEqual(chrome.overflow(on: .accounts), .plan)

    chrome.openMore(.assistant)
    model.activeCaptureSurface = chrome.captureSurface
    XCTAssertEqual(chrome.captureSurface, .assistant)
    XCTAssertEqual(chrome.overflow(on: .accounts), .assistant)
    XCTAssertNil(model.visibleRegisterAccountID)
    XCTAssertEqual(model.addTransactionsOrigin(), .lastUsedOpen)

    chrome.dismissMore()
    model.activeCaptureSurface = chrome.captureSurface
    XCTAssertEqual(chrome.captureSurface, .accounts)
    XCTAssertNil(chrome.overflow(on: .accounts))
    XCTAssertEqual(model.visibleRegisterAccountID, "acct-everyday")
    XCTAssertEqual(model.addTransactionsOrigin(), .visibleRegister(accountID: "acct-everyday"))
  }

  func testMoreMenuItemsOmitOnlyTheNamedDestination() {
    XCTAssertEqual(MoreDestination.menuItems(omitting: nil), [.plan, .assistant])
    XCTAssertEqual(MoreDestination.menuItems(omitting: .plan), [.assistant])
    XCTAssertEqual(MoreDestination.menuItems(omitting: .assistant), [.plan])
  }

  func testOverflowItemsStayOnPhoneAndLeaveIPadSidebar() {
    XCTAssertEqual(
      MoreDestination.overflowItems(usesSidebar: false, omitting: nil),
      [.plan, .assistant]
    )
    XCTAssertEqual(
      MoreDestination.overflowItems(usesSidebar: true, omitting: nil),
      []
    )
    XCTAssertEqual(
      MoreDestination.overflowItems(usesSidebar: false, omitting: .plan),
      [.assistant]
    )
  }

  func testAdoptSidebarPromotesPhoneOverflowToTab() {
    let chrome = RootChromeState()
    chrome.tab = .accounts
    chrome.openMore(.plan)
    XCTAssertEqual(chrome.captureSurface, .plan)
    chrome.adoptSidebarLayout()
    XCTAssertEqual(chrome.tab, .plan)
    XCTAssertNil(chrome.overflow(on: .accounts))
    XCTAssertEqual(chrome.captureSurface, .plan)
  }

  func testAdoptCompactMovesSidebarTabIntoMore() {
    let chrome = RootChromeState()
    chrome.tab = .rewards
    chrome.tab = .assistant
    chrome.adoptCompactLayout()
    XCTAssertEqual(chrome.tab, .rewards)
    XCTAssertEqual(chrome.overflow(on: .rewards), .assistant)
    XCTAssertEqual(chrome.captureSurface, .assistant)
  }

  func testCompactBarTabIgnoresOverflowSelection() {
    let chrome = RootChromeState()
    XCTAssertEqual(chrome.compactBarTab, .accounts)

    chrome.tab = .rewards
    XCTAssertEqual(chrome.compactBarTab, .rewards)

    chrome.tab = .plan
    XCTAssertEqual(chrome.tab, .plan)
    XCTAssertEqual(chrome.compactBarTab, .rewards)

    chrome.tab = .assistant
    XCTAssertEqual(chrome.compactBarTab, .rewards)
  }

  func testCompactRootTabViewRendersThreeTabs() async {
    let harness = SnapshotHarness.make()
    let chrome = RootChromeState()
    guard let surface = SnapshotSurface(
      root: RootTabView(chrome: chrome, usesSidebar: false)
        .environment(harness.model)
        .environment(chrome)
        .environment(\.horizontalSizeClass, .compact),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("compact root tabs need a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    let appeared = await surface.waitUntil {
      surface.firstControl(label: "Accounts") != nil
        && surface.firstControl(label: "Rewards") != nil
        && surface.firstControl(label: "Reflect") != nil
        && surface.firstControl(label: "Add Transactions") != nil
        && surface.tabRowControl(label: "Assistant") != nil
    }
    XCTAssertTrue(
      appeared,
      "compact root must show three tabs plus Add and Assistant: \(surface.accessibilityLabels())"
    )
    XCTAssertNotNil(surface.firstControl(label: "More"), "Accounts must still host DestinationsMenu")
    XCTAssertEqual(chrome.compactBarTab, .accounts)
    XCTAssertNil(chrome.overflow(on: .accounts))

    guard let assistant = surface.tabRowControl(label: "Assistant") else {
      XCTFail("compact root must host a tab-row Assistant")
      return
    }
    if let accounts = surface.tabRowControl(label: "Accounts") {
      XCTAssertEqual(
        assistant.frame.midY,
        accounts.frame.midY,
        accuracy: 24,
        "Assistant must sit in the destination row"
      )
    }
    XCTAssertTrue(surface.activate(assistant))
    XCTAssertEqual(chrome.overflow(on: .accounts), .assistant)
    XCTAssertEqual(chrome.compactBarTab, .accounts)
    XCTAssertEqual(chrome.tab, .accounts)
  }

  func testSidebarRootTabViewDoesNotInstallTabRowAssistant() async {
    let harness = SnapshotHarness.make()
    let chrome = RootChromeState()
    guard let surface = SnapshotSurface(
      root: RootTabView(chrome: chrome, usesSidebar: true)
        .environment(harness.model)
        .environment(chrome)
        .environment(\.horizontalSizeClass, .regular),
      size: CGSize(width: 1180, height: 820)
    ) else {
      XCTFail("sidebar root tabs need a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    let appeared = await surface.waitUntil {
      surface.firstControl(label: "Assistant") != nil
    }
    XCTAssertTrue(appeared, "sidebar root must keep Assistant as a destination: \(surface.accessibilityLabels())")
    XCTAssertNil(surface.firstControl(label: "Add Transactions"), "sidebar must not host a search-role Add")
    XCTAssertNil(
      surface.tabRowOverlayButton(label: "Assistant"),
      "sidebar must not install a compact tab-row Assistant overlay"
    )
  }

  func testCompactRootTabViewAcceptsOverflowSelectionWithoutCrashing() async {
    let harness = SnapshotHarness.make()
    let chrome = RootChromeState()
    chrome.tab = .plan
    guard let surface = SnapshotSurface(
      root: RootTabView(chrome: chrome, usesSidebar: false)
        .environment(harness.model)
        .environment(chrome)
        .environment(\.horizontalSizeClass, .compact),
      size: CGSize(width: 390, height: 844)
    ) else {
      XCTFail("compact root tabs need a connected UIWindowScene")
      return
    }
    defer { surface.detach() }

    let appeared = await surface.waitUntil {
      surface.firstControl(label: "Accounts") != nil
    }
    XCTAssertTrue(
      appeared,
      "overflow selection must still render compact tabs: \(surface.accessibilityLabels())"
    )
    XCTAssertEqual(chrome.compactBarTab, .accounts)
  }

  private func attachImage(_ image: UIImage, name: String) {
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
