import XCTest
@testable import HowMuch

@MainActor
final class IntentCatalogTests: XCTestCase {
  private var directory: URL!
  private var store: IntentCatalogStore!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    store = IntentCatalogStore(directory: directory)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testProjectedOpenAccountIDsMatchAppModel() {
    var settings = APISettings()
    settings.baseURLString = "https://howmuch.example.test"
    settings.planID = "local-plan"
    settings.authenticatedUserID = "user-1"
    settings.sessionToken = "token"

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs())
    model.accounts = [
      Self.account(id: "acct-everyday", name: "Everyday Account", closed: false),
      Self.account(id: "acct-rainy", name: "Rainy Day Saver", closed: false),
      Self.account(id: "acct-closed", name: "Old Card", closed: true),
    ]

    let snapshot = IntentCatalogSnapshot.project(
      fingerprint: model.settings.connectionFingerprint,
      accounts: model.accounts,
      categoryGroups: model.categoryGroups,
      payees: model.payees
    )
    XCTAssertEqual(snapshot.openAccounts.map(\.id), model.openAccounts.map(\.id))
  }

  func testPublishThenLoadMatchesOpenAccounts() {
    var settings = APISettings()
    settings.baseURLString = "https://howmuch.example.test"
    settings.planID = "local-plan"
    settings.authenticatedUserID = "user-1"
    settings.sessionToken = "token"

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs())
    model.accounts = [
      Self.account(id: "acct-everyday", name: "Everyday Account", closed: false),
      Self.account(id: "acct-closed", name: "Old Card", closed: true),
    ]
    model.publishIntentCatalog(using: store)
    store.waitForPendingWrites()

    let loaded = store.load(fingerprint: model.settings.connectionFingerprint)
    XCTAssertEqual(loaded?.openAccounts.map(\.id), model.openAccounts.map(\.id))
  }

  func testSecondFingerprintCannotReadTheFirstPlan() {
    let first = IntentCatalogSnapshot.project(
      fingerprint: "plan-a",
      accounts: [Self.account(id: "acct-everyday", name: "Everyday Account", closed: false)],
      categoryGroups: [],
      payees: []
    )
    store.write(first)
    XCTAssertNil(store.load(fingerprint: "plan-b"))
    XCTAssertEqual(store.load(fingerprint: "plan-a")?.openAccounts.map(\.id), ["acct-everyday"])
  }

  func testWipeRemovesTheFile() {
    let snapshot = IntentCatalogSnapshot.project(
      fingerprint: "plan-a",
      accounts: [Self.account(id: "acct-everyday", name: "Everyday Account", closed: false)],
      categoryGroups: [],
      payees: []
    )
    store.write(snapshot)
    XCTAssertNotNil(store.load(fingerprint: "plan-a"))
    store.wipe(fingerprint: "plan-a")
    XCTAssertNil(store.load(fingerprint: "plan-a"))
  }

  func testWipeAllClearsEveryFingerprint() {
    store.write(
      IntentCatalogSnapshot.project(
        fingerprint: "plan-a",
        accounts: [Self.account(id: "acct-everyday", name: "Everyday Account", closed: false)],
        categoryGroups: [],
        payees: []
      )
    )
    store.write(
      IntentCatalogSnapshot.project(
        fingerprint: "plan-b",
        accounts: [Self.account(id: "acct-travel", name: "Travel Card", closed: false)],
        categoryGroups: [],
        payees: []
      )
    )
    store.wipeAll()
    XCTAssertNil(store.load(fingerprint: "plan-a"))
    XCTAssertNil(store.load(fingerprint: "plan-b"))
  }

  func testAppModelWipeClearsTheStore() {
    var settings = APISettings()
    settings.baseURLString = "https://howmuch.example.test"
    settings.planID = "local-plan"
    settings.authenticatedUserID = "user-1"
    settings.sessionToken = "token"

    let model = AppModel(settings: settings, viewPrefs: ViewPrefs())
    model.accounts = [Self.account(id: "acct-everyday", name: "Everyday Account", closed: false)]
    model.publishIntentCatalog(using: store)
    store.waitForPendingWrites()
    XCTAssertNotNil(store.load(fingerprint: model.settings.connectionFingerprint))

    model.wipeIntentCatalog(using: store)
    XCTAssertNil(store.load(fingerprint: model.settings.connectionFingerprint))
  }

  func testScheduledWriteDoesNotLandAfterWipe() {
    let snapshot = IntentCatalogSnapshot.project(
      fingerprint: "plan-a",
      accounts: [Self.account(id: "acct-everyday", name: "Everyday Account", closed: false)],
      categoryGroups: [],
      payees: []
    )
    store.scheduleWrite(snapshot)
    store.wipeAll()
    store.waitForPendingWrites()
    XCTAssertNil(store.load(fingerprint: "plan-a"))
  }

  func testPickerPayeesDropDeletedAndKeepTransfers() {
    let snapshot = IntentCatalogSnapshot.project(
      fingerprint: "plan-a",
      accounts: [],
      categoryGroups: [],
      payees: [
        Payee(id: "payee-fairprice", name: "FairPrice Finest", transferAccountId: nil, deleted: false),
        Payee(id: "payee-transfer", name: "Travel Card", transferAccountId: "acct-travel", deleted: nil),
        Payee(id: "payee-gone", name: "Deleted Shop", transferAccountId: nil, deleted: true),
      ]
    )
    XCTAssertEqual(snapshot.pickerPayees.map(\.id), ["payee-fairprice", "payee-transfer"])
  }

  func testPickerCategoriesDemoteQuietAndDropDeleted() {
    let hidden = CategoryGroup(
      id: "grp-hidden",
      name: "Hidden Categories",
      hidden: true,
      deleted: false,
      categories: [Category(id: "cat-internal", categoryGroupID: "grp-hidden", name: "Internal", deleted: false)]
    )
    let groceries = CategoryGroup(
      id: "grp-spend",
      name: "Everyday",
      hidden: false,
      deleted: false,
      categories: [
        Category(id: "cat-groceries", categoryGroupID: "grp-spend", name: "Groceries", deleted: false),
        Category(id: "cat-gone", categoryGroupID: "grp-spend", name: "Old", deleted: true),
      ]
    )
    let snapshot = IntentCatalogSnapshot.project(
      fingerprint: "plan-a",
      accounts: [],
      categoryGroups: [hidden, groceries],
      payees: []
    )
    XCTAssertEqual(snapshot.pickerCategories.map(\.id), ["cat-groceries", "cat-internal"])
    XCTAssertEqual(snapshot.pickerCategories.map(\.isQuiet), [false, true])
  }

  private static func account(id: String, name: String, closed: Bool) -> Account {
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
      deleted: false
    )
  }
}
