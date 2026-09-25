import XCTest
@testable import HowMuch

final class LocalEngineTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appending(path: "LocalEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private var databaseURL: URL {
    directory.appending(path: "howmuch.sqlite")
  }

  private let config = LocalEngineConfig(apiToken: "test-token", defaultPlanId: "plan_test", timeZone: "Asia/Singapore")

  func testPendingMigrationsSkipAppliedOnesAndKeepD1Order() {
    let available = [
      LocalMigration(name: "0002_b.sql", sql: ""),
      LocalMigration(name: "0001_a.sql", sql: ""),
      LocalMigration(name: "0003_c.sql", sql: ""),
    ]

    let pending = LocalMigration.pending(available: available, applied: ["0002_b.sql"])

    XCTAssertEqual(pending.map(\.name), ["0001_a.sql", "0003_c.sql"])
  }

  func testBundleShipsEveryMigration() throws {
    let migrations = try LocalMigration.bundled()
    XCTAssertFalse(migrations.isEmpty)
    XCTAssertEqual(migrations.first?.name, "0001_initial.sql")
  }

  func testMigrationsApplyOnceAndAreRecorded() throws {
    let migrations = try LocalMigration.bundled()
    let database = try LocalDatabase(url: databaseURL)

    let first = try database.migrate(migrations)
    let second = try database.migrate(migrations)

    XCTAssertEqual(first, migrations.map(\.name))
    XCTAssertEqual(second, [])
    let recorded = try database.query("SELECT count(*) AS count FROM _local_migrations").first?["count"] as? Int64
    XCTAssertEqual(recorded, Int64(migrations.count))
    let foreignKeys = try database.query("PRAGMA foreign_keys").first?["foreign_keys"] as? Int64
    XCTAssertEqual(foreignKeys, 1)
  }

  func testReopeningAnExistingDatabaseKeepsItsData() async throws {
    let first = LocalEngine(databaseURL: databaseURL)
    let created = try await first.handle(
      config: config,
      method: "POST",
      path: "/v1/plans/plan_test/accounts",
      query: nil,
      headers: ["Authorization": "Bearer test-token", "Content-Type": "application/json"],
      body: Data(#"{"account":{"name":"Wallet","type":"cash","balance":0}}"#.utf8)
    )
    XCTAssertEqual(created.status, 201)

    // A second engine over the same file finds every migration applied.
    let second = LocalEngine(databaseURL: databaseURL)
    let listed = try await second.handle(
      config: config,
      method: "GET",
      path: "/v1/plans/plan_test/accounts",
      query: nil,
      headers: ["Authorization": "Bearer test-token"],
      body: nil
    )
    XCTAssertEqual(listed.status, 200)
    XCTAssertTrue(String(decoding: listed.body, as: UTF8.self).contains("Wallet"))
  }

  func testEngineRejectsAnotherToken() async throws {
    let engine = LocalEngine(databaseURL: databaseURL)
    let response = try await engine.handle(
      config: config,
      method: "GET",
      path: "/v1/plans",
      query: nil,
      headers: ["Authorization": "Bearer someone-else"],
      body: nil
    )
    XCTAssertEqual(response.status, 401)
  }

  func testScheduledMaterialisationRunsWithNothingDue() async throws {
    let engine = LocalEngine(databaseURL: databaseURL)
    let summary = try await engine.runScheduledMaterialization(config: config)
    XCTAssertEqual(summary.occurrenceCount, 0)
    XCTAssertEqual(summary.failureCount, 0)
  }
}
