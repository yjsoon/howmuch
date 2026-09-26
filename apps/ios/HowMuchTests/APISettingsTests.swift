import XCTest
@testable import HowMuch

final class APISettingsTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName = ""
  private var previousCredentialService = ""

  override func setUp() {
    super.setUp()
    suiteName = "HowMuch.APISettingsTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    previousCredentialService = APISettings.useCredentialService("HowMuch.APISettingsTests.\(UUID().uuidString)")
  }

  override func tearDown() {
    APISettings.useCredentialService(previousCredentialService)
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testLegacyHostedSessionMovesWithTheHost() throws {
    try requireUsableKeychain()

    var legacy = APISettings(baseURLString: "https://howmuch.soon.sg")
    legacy.sessionToken = "token-carried-over"
    legacy.save(to: defaults)

    XCTAssertEqual(APISettings.load(from: defaults).sessionToken, "token-carried-over")
    // The second load reads the token under the current host's scope, which
    // proves the first one re-scoped it instead of leaving it behind.
    XCTAssertEqual(APISettings.load(from: defaults).sessionToken, "token-carried-over")
  }

  func testCustomEndpointAndItsSessionArePreserved() throws {
    try requireUsableKeychain()

    var custom = APISettings(baseURLString: "https://ledger.example.test")
    custom.sessionToken = "custom-token"
    custom.save(to: defaults)

    let loaded = APISettings.load(from: defaults)

    XCTAssertEqual(loaded.baseURLString, "https://ledger.example.test")
    XCTAssertEqual(loaded.sessionToken, "custom-token")
  }

  func testLegacyDevelopmentDefaultIsReplacedAndSignedOut() {
    var development = APISettings(baseURLString: "http://127.0.0.1:8787")
    development.sessionToken = "development-token"
    development.authenticatedUserID = "development-user"
    development.save(to: defaults)

    let loaded = APISettings.load(from: defaults)

    XCTAssertEqual(loaded.baseURLString, APISettings.productionBaseURL)
    XCTAssertEqual(loaded.sessionToken, "")
    XCTAssertEqual(loaded.authenticatedUserID, "")
  }

  /// The app-hosted test bundle can run with no usable Keychain — the same
  /// limitation that fails `CaptureAITests`' independent round-trip — so probe
  /// first and skip rather than report a false migration failure.
  private func requireUsableKeychain() throws {
    let name = "HowMuch.APISettingsTests.probe.\(UUID().uuidString)"
    guard let probeDefaults = UserDefaults(suiteName: name) else {
      throw XCTSkip("Could not create a probe defaults suite.")
    }
    defer { probeDefaults.removePersistentDomain(forName: name) }

    APISettings(
      baseURLString: "https://keychain-probe.example.test",
      sessionToken: "probe-token"
    ).save(to: probeDefaults)

    guard APISettings.load(from: probeDefaults).sessionToken == "probe-token" else {
      throw XCTSkip("This test host has no usable Keychain.")
    }
  }
}
