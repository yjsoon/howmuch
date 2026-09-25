import XCTest
@testable import HowMuch

final class CaptureOriginTests: XCTestCase {
  func testRegisterPlusUsesThatOpenAccount() {
    let context = CaptureAccountContext.resolve(
      origin: .visibleRegister(accountID: "acct-travel"),
      openAccounts: Self.open,
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: "acct-travel"
    )
    XCTAssertEqual(context.selectedAccountID, "acct-travel")
    XCTAssertEqual(context.origin, .visibleRegister(accountID: "acct-travel"))
  }

  func testOverviewPlusUsesLastUsedOpenNotFocusedRegister() {
    let context = CaptureAccountContext.resolve(
      origin: .lastUsedOpen,
      openAccounts: Self.open,
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: "acct-travel"
    )
    XCTAssertEqual(context.selectedAccountID, "acct-everyday")
  }

  func testHomeScreenIgnoresLeftoverVisibleRegister() {
    let context = CaptureAccountContext.resolve(
      origin: .homeScreenShortcut,
      openAccounts: Self.open,
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: "acct-travel"
    )
    XCTAssertEqual(context.selectedAccountID, "acct-everyday")
    XCTAssertTrue(context.origin.ignoresVisibleRegister)
  }

  func testClosedLastUsedFallsBackToFirstOpen() {
    let context = CaptureAccountContext.resolve(
      origin: .lastUsedOpen,
      openAccounts: Self.open,
      lastUsedAccountID: "acct-closed"
    )
    XCTAssertEqual(context.selectedAccountID, "acct-everyday")
  }

  func testDeletedOrMissingLastUsedFallsBackToFirstOpen() {
    let context = CaptureAccountContext.resolve(
      origin: .lastUsedOpen,
      openAccounts: Self.open,
      lastUsedAccountID: "acct-gone"
    )
    XCTAssertEqual(context.selectedAccountID, "acct-everyday")
  }

  func testNoOpenAccountsRequiresChoice() {
    let closed = [
      Self.account("acct-closed", "Closed Card", closed: true),
    ]
    let context = CaptureAccountContext.resolve(
      origin: .lastUsedOpen,
      openAccounts: closed,
      lastUsedAccountID: "acct-closed"
    )
    XCTAssertNil(context.selectedAccountID)
    XCTAssertTrue(context.needsAccountChoice)
  }

  func testPresetDraftKeepsExplicitAccount() {
    let context = CaptureAccountContext.resolve(
      origin: .presetDraft,
      openAccounts: Self.open,
      lastUsedAccountID: "acct-everyday",
      focusedRegisterAccountID: "acct-travel",
      presetAccountID: "acct-rainy"
    )
    XCTAssertEqual(context.selectedAccountID, "acct-rainy")
  }

  func testPresetDraftFallsBackWhenExplicitAccountClosed() {
    let context = CaptureAccountContext.resolve(
      origin: .presetDraft,
      openAccounts: Self.open,
      lastUsedAccountID: "acct-everyday",
      presetAccountID: "acct-closed"
    )
    XCTAssertEqual(context.selectedAccountID, "acct-everyday")
  }

  func testInboxUsesLastUsedNotFocusedRegister() {
    let context = CaptureAccountContext.resolve(
      origin: .inbox,
      openAccounts: Self.open,
      lastUsedAccountID: "acct-rainy",
      focusedRegisterAccountID: "acct-travel"
    )
    XCTAssertEqual(context.selectedAccountID, "acct-rainy")
  }

  func testNeverSelectsClosedOrDeletedAccount() {
    let mixed = [
      Self.account("acct-closed", "Closed", closed: true),
      Self.account("acct-deleted", "Deleted", deleted: true),
      Self.account("acct-everyday", "Everyday"),
    ]
    let fromRegister = CaptureAccountContext.resolve(
      origin: .visibleRegister(accountID: "acct-closed"),
      openAccounts: mixed,
      lastUsedAccountID: "acct-deleted"
    )
    XCTAssertEqual(fromRegister.selectedAccountID, "acct-everyday")
  }

  @MainActor
  func testVisibleRegisterOnCurrentSurfaceDoesNotLeakWhenDestinationChanges() {
    let model = AppModel()
    model.activeCaptureSurface = .accounts
    model.beginFocusedRegisterAccount("acct-everyday")
    XCTAssertEqual(model.visibleRegisterAccountID, "acct-everyday")
    XCTAssertEqual(model.addTransactionsOrigin(), .visibleRegister(accountID: "acct-everyday"))
    model.activeCaptureSurface = .assistant
    XCTAssertNil(model.visibleRegisterAccountID)
    XCTAssertEqual(model.addTransactionsOrigin(), .lastUsedOpen)
    model.activeCaptureSurface = .accounts
    XCTAssertEqual(model.visibleRegisterAccountID, "acct-everyday")
  }

  func testExplicitRetryRefreshesFailedReference() {
    XCTAssertTrue(CaptureAdmissionGate.shouldRefreshReference(phase: .failed("offline"), explicitRetry: true))
    XCTAssertFalse(CaptureAdmissionGate.shouldRefreshReference(phase: .failed("offline"), explicitRetry: false))
    XCTAssertTrue(CaptureAdmissionGate.shouldRefreshReference(phase: .idle, explicitRetry: false))
    XCTAssertFalse(CaptureAdmissionGate.shouldRefreshReference(phase: .loaded, explicitRetry: false))
  }

  func testAdmissionGateDoesNotFreezeBeforeReferenceLoads() {
    XCTAssertFalse(CaptureAdmissionGate.canAdmit(referencePhase: .idle))
    XCTAssertFalse(CaptureAdmissionGate.canAdmit(referencePhase: .loading))
  }

  func testReferenceWaitStopsOnlyWhenNothingWillLoadTheReference() {
    XCTAssertEqual(CaptureAdmissionGate.referenceWait(referencePhase: .loaded, isRefreshingAll: false), .admit)
    XCTAssertEqual(CaptureAdmissionGate.referenceWait(referencePhase: .loaded, isRefreshingAll: true), .admit)
    XCTAssertEqual(CaptureAdmissionGate.referenceWait(referencePhase: .failed("offline"), isRefreshingAll: false), .admit)
    XCTAssertEqual(CaptureAdmissionGate.referenceWait(referencePhase: .failed("offline"), isRefreshingAll: true), .admit)
    XCTAssertEqual(CaptureAdmissionGate.referenceWait(referencePhase: .loading, isRefreshingAll: false), .wait)
    XCTAssertEqual(CaptureAdmissionGate.referenceWait(referencePhase: .loading, isRefreshingAll: true), .wait)
    XCTAssertEqual(CaptureAdmissionGate.referenceWait(referencePhase: .idle, isRefreshingAll: true), .wait)
    XCTAssertEqual(CaptureAdmissionGate.referenceWait(referencePhase: .idle, isRefreshingAll: false), .stalled)
  }

  /// An offline warm launch turns the reference phase `.failed` over accounts
  /// the snapshot already put on screen. Those are enough to capture against.
  func testFailedRefreshBlocksAdmissionOnlyWithoutAccounts() {
    XCTAssertNil(CaptureAdmissionGate.blockingError(referencePhase: .failed("offline"), hasAccounts: true))
    XCTAssertEqual(
      CaptureAdmissionGate.blockingError(referencePhase: .failed("offline"), hasAccounts: false),
      "offline"
    )
    XCTAssertNil(CaptureAdmissionGate.blockingError(referencePhase: .loaded, hasAccounts: false))
    XCTAssertNil(CaptureAdmissionGate.blockingError(referencePhase: .loaded, hasAccounts: true))
  }

  func testAdmissionAfterRefreshRequiresCurrentRequestAndMatchingScope() {
    let request = CaptureRequest(kind: .blank, connectionFingerprint: "plan-a")
    let other = CaptureRequest(kind: .blank, connectionFingerprint: "plan-a")
    XCTAssertTrue(
      CaptureAdmissionGate.shouldAdmitAfterRefresh(
        request: request,
        presented: request,
        isCancelled: false,
        settingsScopeKey: "https://a|user-a|plan-a",
        workspaceScopeKey: "https://a|user-a|plan-a"
      )
    )
    XCTAssertTrue(
      CaptureAdmissionGate.shouldAdmitAfterRefresh(
        request: request,
        presented: request,
        isCancelled: false,
        settingsScopeKey: nil,
        workspaceScopeKey: nil
      )
    )
    XCTAssertFalse(
      CaptureAdmissionGate.shouldAdmitAfterRefresh(
        request: request,
        presented: request,
        isCancelled: true,
        settingsScopeKey: "https://a|user-a|plan-a",
        workspaceScopeKey: "https://a|user-a|plan-a"
      )
    )
    XCTAssertFalse(
      CaptureAdmissionGate.shouldAdmitAfterRefresh(
        request: request,
        presented: nil,
        isCancelled: false,
        settingsScopeKey: "https://a|user-a|plan-a",
        workspaceScopeKey: "https://a|user-a|plan-a"
      )
    )
    XCTAssertFalse(
      CaptureAdmissionGate.shouldAdmitAfterRefresh(
        request: request,
        presented: other,
        isCancelled: false,
        settingsScopeKey: "https://a|user-a|plan-a",
        workspaceScopeKey: "https://a|user-a|plan-a"
      )
    )
    XCTAssertFalse(
      CaptureAdmissionGate.shouldAdmitAfterRefresh(
        request: request,
        presented: request,
        isCancelled: false,
        settingsScopeKey: "https://a|user-a|plan-a",
        workspaceScopeKey: "https://b|user-b|plan-a"
      )
    )
  }

  func testLastUsedPreferredOverMostUsedOrdering() {
    let mostUsedFirst = [
      Self.account("acct-travel", "Travel Card"),
      Self.account("acct-everyday", "Everyday"),
    ]
    let context = CaptureAccountContext.resolve(
      origin: .lastUsedOpen,
      openAccounts: mostUsedFirst,
      lastUsedAccountID: "acct-everyday"
    )
    XCTAssertEqual(context.selectedAccountID, "acct-everyday")
  }

  private static let open = [
    account("acct-everyday", "Everyday"),
    account("acct-travel", "Travel Card"),
    account("acct-rainy", "Rainy Day Saver"),
  ]

  private static func account(
    _ id: String,
    _ name: String,
    closed: Bool = false,
    deleted: Bool = false
  ) -> Account {
    Account(
      id: id,
      name: name,
      icon: nil,
      type: "checking",
      onBudget: true,
      closed: closed,
      balance: 0,
      clearedBalance: 0,
      unclearedBalance: 0,
      lastReconciledDate: nil,
      deleted: deleted
    )
  }
}
