import Foundation
import Security

struct APIEnvelope<Payload: Decodable>: Decodable {
  let data: Payload
}

struct ServerErrorEnvelope: Decodable {
  let error: ServerError
}

struct ServerError: Decodable {
  let id: String
  let detail: String
  let name: String?
  let currentReconciledBalance: Int?
  let projectedReconciledBalance: Int?
  let statementBalance: Int?
  let difference: Int?
}

struct APISettings: Codable, Equatable {
  static let userDefaultsKey = "HowMuch.APISettings"
  static let productionBaseURL = "https://howmuch.soon.sg"
  private static let legacyBaseURL = "http://127.0.0.1:8787"
#if DEBUG
  /// A development-signed build may receive these once at launch through
  /// `devicectl`'s process environment. This marker makes the hand-off
  /// one-time: subsequent launches use the normal Keychain-backed settings.
  private static let debugBootstrapAppliedKey = "HowMuch.DebugBootstrapApplied"
#endif

  var baseURLString = productionBaseURL
  var username = ""
  var sessionToken = ""
  var authenticatedUserID = ""
  /// The server chooses the usable plan after sign-in. Leaving this empty on
  /// a fresh install prevents requests from accidentally targeting the old
  /// development-only `local-plan` identifier.
  var planID = ""

  var trimmedBaseURL: String {
    baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  /// A stable identity for the server that owns this session. The value is
  /// deliberately derived from the URL rather than from the user or plan so
  /// that a token can never be sent to a different endpoint after a setting
  /// change.
  var normalizedBaseURLString: String? {
    Self.normalizedBaseURLString(from: trimmedBaseURL)
  }

  static func normalizedBaseURLString(from value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host?.lowercased(),
      !host.isEmpty,
      Self.allowsHTTPSOrLocalHTTP(scheme, host: host),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      return nil
    }

    var normalized = components
    normalized.scheme = scheme
    normalized.host = host
    if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
      normalized.port = nil
    }

    var path = components.percentEncodedPath
    while path.hasSuffix("/") {
      path.removeLast()
    }
    while path.hasPrefix("/") {
      path.removeFirst()
    }
    normalized.percentEncodedPath = path.isEmpty ? "" : "/" + path
    return normalized.string
  }

  var connectionFingerprint: String {
    [normalizedBaseURLString ?? trimmedBaseURL, planID, authenticatedUserID].joined(separator: "|")
  }

  func matchesCurrentOrLegacyOutboxStamp(_ stamp: String) -> Bool {
    stamp == connectionFingerprint
      || stamp == [trimmedBaseURL, planID, authenticatedUserID].joined(separator: "|")
  }

  /// Account presentation preferences belong to one authenticated plan.
  /// Canonicalising the endpoint prevents harmless URL spelling differences
  /// from creating or, worse, sharing the wrong preference scope.
  var viewPrefsScopeKey: String? {
    guard
      isAuthenticated,
      let endpoint = normalizedBaseURLString,
      !authenticatedUserID.isEmpty,
      !planID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return [endpoint, authenticatedUserID, planID].joined(separator: "|")
  }

  var baseURL: URL? {
    guard
      let components = URLComponents(string: trimmedBaseURL),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host,
      !host.isEmpty,
      Self.allowsHTTPSOrLocalHTTP(scheme, host: host),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else {
      return nil
    }
    return components.url
  }

  static func allowsHTTPSOrLocalHTTP(_ scheme: String, host: String) -> Bool {
    scheme == "https" || (scheme == "http" && isLocalNetworkHost(host))
  }

  static func isLocalNetworkHost(_ host: String) -> Bool {
    let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" {
      return true
    }
    if host.hasSuffix(".local") {
      let prefix = host.dropLast(6)
      return !prefix.isEmpty && prefix.last != "."
    }
    if host.contains(":") {
      return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
    }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count == 4 else {
      return false
    }
    var parts: [UInt8] = []
    parts.reserveCapacity(4)
    for label in labels {
      let text = String(label)
      guard let octet = UInt8(text), String(octet) == text else {
        return false
      }
      parts.append(octet)
    }
    if parts[0] == 127 || parts[0] == 10 || parts[0] == 169 && parts[1] == 254 {
      return true
    }
    if parts[0] == 192 && parts[1] == 168 {
      return true
    }
    if parts[0] == 172 && (16 ... 31).contains(parts[1]) {
      return true
    }
    return false
  }

  var browserSetupURL: URL? {
    guard let baseURL, baseURL.scheme == "https",
          var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    else {
      return nil
    }
    components.path = "/"
    return components.url
  }

  var isConfigured: Bool {
    baseURL != nil
  }

  var refusesPublicHTTP: Bool {
    guard
      let components = URLComponents(string: trimmedBaseURL),
      components.scheme?.lowercased() == "http",
      let host = components.host,
      !host.isEmpty
    else {
      return false
    }
    return !Self.isLocalNetworkHost(host)
  }

  var isAuthenticated: Bool {
    !sessionToken.isEmpty && !authenticatedUserID.isEmpty
  }

  /// Keeps an already-selected accessible plan, otherwise adopts the only
  /// plan the signed-in user can read. Ambiguous servers intentionally retain
  /// the existing value so a user cannot be moved to an unintended plan.
  func resolvedPlanID(from plans: [PlanSummary]) -> String? {
    let currentPlanID = planID.trimmingCharacters(in: .whitespacesAndNewlines)
    if plans.contains(where: { $0.id == currentPlanID }) {
      return currentPlanID
    }
    guard plans.count == 1 else {
      return nil
    }
    return plans[0].id
  }

  static func load(
    from defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> APISettings {
#if DEBUG
    if !defaults.bool(forKey: debugBootstrapAppliedKey),
       let bootstrap = debugBootstrapSettings(from: environment) {
      // `save` writes the opaque token only to the endpoint-scoped Keychain
      // item; the UserDefaults payload intentionally remains public settings.
      bootstrap.save(to: defaults)
      defaults.set(true, forKey: debugBootstrapAppliedKey)
      // A forced termination may follow this first launch immediately. Flush
      // the endpoint/plan and marker before a relaunch needs the Keychain token.
      defaults.synchronize()
      return bootstrap
    }
#endif
    guard
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(APISettings.self, from: data)
    else {
      return APISettings()
    }
    var settings = decoded
    if settings.normalizedBaseURLString == normalizedBaseURLString(from: legacyBaseURL) {
      settings.baseURLString = productionBaseURL
      settings.sessionToken = ""
      settings.authenticatedUserID = ""
      settings.save(to: defaults)
      return settings
    }

    if let normalizedBaseURL = decoded.normalizedBaseURLString,
       let token = CredentialStore.load(for: normalizedBaseURL) {
      settings.sessionToken = token
    } else if decoded.normalizedBaseURLString == normalizedBaseURLString(from: productionBaseURL),
              let legacyToken = CredentialStore.loadLegacy() {
      // Versions before endpoint scoping used one global Keychain account.
      // Only migrate it when UserDefaults proves the saved endpoint is the
      // production service; custom endpoints must never inherit that token.
      settings.sessionToken = legacyToken
      settings.save(to: defaults)
      return settings
    } else {
      settings.sessionToken = ""
    }
    return settings
  }

#if DEBUG
  private static func debugBootstrapSettings(from environment: [String: String]) -> APISettings? {
    guard
      let submittedURL = environment["HOWMUCH_BOOTSTRAP_BASE_URL"],
      let normalizedURL = normalizedBaseURLString(from: submittedURL),
      let normalizedProductionURL = normalizedBaseURLString(from: productionBaseURL),
      normalizedURL == normalizedProductionURL,
      URLComponents(string: normalizedURL)?.scheme?.lowercased() == "https",
      let username = environment["HOWMUCH_BOOTSTRAP_USERNAME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !username.isEmpty,
      let planID = environment["HOWMUCH_BOOTSTRAP_PLAN_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !planID.isEmpty,
      let sessionToken = environment["HOWMUCH_BOOTSTRAP_SESSION_TOKEN"],
      !sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }

    // The launch contract deliberately contains a username, not a separately
    // identifying profile payload. It is sufficient for the local signed-in
    // state; every request is still authenticated by the opaque session token.
    return APISettings(
      baseURLString: normalizedURL,
      username: username,
      sessionToken: sessionToken,
      authenticatedUserID: username,
      planID: planID
    )
  }
#endif

  func save(to defaults: UserDefaults = .standard) {
    CredentialStore.save(sessionToken, for: normalizedBaseURLString)
    var publicSettings = self
    publicSettings.sessionToken = ""
    guard let data = try? JSONEncoder().encode(publicSettings) else {
      return
    }
    defaults.set(data, forKey: Self.userDefaultsKey)
  }
}

private enum CredentialStore {
  private static let service = Bundle.main.bundleIdentifier ?? "HowMuch"
  private static let legacyAccount = "session-token"
  private static let accountPrefix = "session-token:"

  static func load(for normalizedBaseURL: String) -> String? {
    load(account: accountPrefix + normalizedBaseURL)
  }

  static func loadLegacy() -> String? {
    load(account: legacyAccount)
  }

  private static func load(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  static func save(_ token: String, for normalizedBaseURL: String?) {
    guard let normalizedBaseURL else {
      removeLegacy()
      return
    }

    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: accountPrefix + normalizedBaseURL,
    ]
    SecItemDelete(identity as CFDictionary)
    removeLegacy()
    guard !token.isEmpty, let data = token.data(using: .utf8) else {
      return
    }
    var item = identity
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }

  private static func removeLegacy() {
    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: legacyAccount,
    ]
    SecItemDelete(identity as CFDictionary)
  }

}

/// View options remembered across launches, persisted like the connection
/// settings. Defaults apply whenever a stored blob is missing or unreadable.
struct ViewPrefs: Codable, Equatable {
  /// Legacy unscoped key. It remains readable for one-time migration but all
  /// new writes go through the scoped preference store.
  static let userDefaultsKey = "HowMuch.ViewPrefs"

  var lastUsedAccountID: String?
  /// Whether the spending report includes bookkeeping ("quiet") category
  /// groups; mirrors the web app's persisted includeQuietSpending pref.
  var includeQuietSpending: Bool?
  /// Account presentation preferences are cached locally and synced separately
  /// from the server's immutable account source list.
  var favouriteAccountIDs: [String] = []
  /// Legacy global order retained so existing installs can seed every new
  /// group's manual order deterministically.
  var accountOrder: [String] = []
  /// Manual order is now specific to the displayed group. This lets, for
  /// example, a favourite account sit first in Favourites without moving the
  /// same account within Cash.
  var accountOrderByGroup: [String: [String]] = [:]
  var accountGroupSorts: [String: AccountGroupSort] = [:]
  var customAccountGroups: [CustomAccountGroup] = []

  private enum CodingKeys: String, CodingKey {
    case lastUsedAccountID
    case includeQuietSpending
    case favouriteAccountIDs
    case accountOrder
    case accountOrderByGroup
    case accountGroupSorts
    case customAccountGroups
  }

  init(
    lastUsedAccountID: String? = nil,
    includeQuietSpending: Bool? = nil,
    favouriteAccountIDs: [String] = [],
    accountOrder: [String] = [],
    accountOrderByGroup: [String: [String]] = [:],
    accountGroupSorts: [String: AccountGroupSort] = [:],
    customAccountGroups: [CustomAccountGroup] = []
  ) {
    self.lastUsedAccountID = lastUsedAccountID
    self.includeQuietSpending = includeQuietSpending
    self.favouriteAccountIDs = favouriteAccountIDs
    self.accountOrder = accountOrder
    self.accountOrderByGroup = accountOrderByGroup
    self.accountGroupSorts = accountGroupSorts
    self.customAccountGroups = customAccountGroups
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    lastUsedAccountID = try container.decodeIfPresent(String.self, forKey: .lastUsedAccountID)
    includeQuietSpending = try container.decodeIfPresent(Bool.self, forKey: .includeQuietSpending)
    favouriteAccountIDs = try container.decodeIfPresent([String].self, forKey: .favouriteAccountIDs) ?? []
    accountOrder = try container.decodeIfPresent([String].self, forKey: .accountOrder) ?? []
    accountOrderByGroup = try container.decodeIfPresent([String: [String]].self, forKey: .accountOrderByGroup) ?? [:]
    accountGroupSorts = try container.decodeIfPresent([String: AccountGroupSort].self, forKey: .accountGroupSorts) ?? [:]
    customAccountGroups = try container.decodeIfPresent([CustomAccountGroup].self, forKey: .customAccountGroups) ?? []
    self = structurallyNormalised()
  }

  static func load(from defaults: UserDefaults = .standard) -> ViewPrefs {
    guard
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(ViewPrefs.self, from: data)
    else {
      return ViewPrefs()
    }
    return decoded
  }

  func save(to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else {
      return
    }
    defaults.set(data, forKey: Self.userDefaultsKey)
  }

  /// Normalises persisted structure without deciding whether an account ID is
  /// still valid. Account membership is pruned only after an authoritative
  /// reference refresh succeeds.
  func structurallyNormalised() -> ViewPrefs {
    var result = self
    result.favouriteAccountIDs = result.favouriteAccountIDs.uniqueNonEmptyStrings
    result.accountOrder = result.accountOrder.uniqueNonEmptyStrings
    result.accountOrderByGroup = result.accountOrderByGroup.reduce(into: [:]) { output, item in
      guard !item.key.isEmpty else { return }
      output[item.key] = item.value.uniqueNonEmptyStrings
    }

    var usedIDs: Set<String> = []
    result.customAccountGroups = result.customAccountGroups.compactMap { group in
      let id = group.id.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !id.isEmpty,
        !CustomAccountGroup.reservedIDs.contains(id.lowercased()),
        !name.isEmpty,
        usedIDs.insert(id).inserted
      else {
        return nil
      }
      return CustomAccountGroup(id: id, name: name, accountIDs: group.accountIDs.uniqueNonEmptyStrings)
    }

    let validGroupIDs = CustomAccountGroup.reservedIDs.union(result.customAccountGroups.map(\.id))
    result.accountGroupSorts = result.accountGroupSorts.filter { validGroupIDs.contains($0.key) }
    result.accountOrderByGroup = result.accountOrderByGroup.filter { validGroupIDs.contains($0.key) }
    return result
  }
}

/// The account-only subset shared by every client for one user and plan.
/// Device-specific navigation and report preferences remain in `ViewPrefs`.
struct AccountPresentationPreferences: Codable, Equatable {
  var favouriteAccountIDs: [String]
  var accountOrder: [String]
  var accountOrderByGroup: [String: [String]]
  var accountGroupSorts: [String: AccountGroupSort]
  var customAccountGroups: [CustomAccountGroup]

  init(_ preferences: ViewPrefs) {
    favouriteAccountIDs = preferences.favouriteAccountIDs
    accountOrder = preferences.accountOrder
    accountOrderByGroup = preferences.accountOrderByGroup
    accountGroupSorts = preferences.accountGroupSorts
    customAccountGroups = preferences.customAccountGroups
  }

  func applying(to preferences: ViewPrefs) -> ViewPrefs {
    var result = preferences
    result.favouriteAccountIDs = favouriteAccountIDs
    result.accountOrder = accountOrder
    result.accountOrderByGroup = accountOrderByGroup
    result.accountGroupSorts = accountGroupSorts
    result.customAccountGroups = customAccountGroups
    return result.structurallyNormalised()
  }

  static func merging(
    baseline: AccountPresentationPreferences,
    local: AccountPresentationPreferences,
    remote: AccountPresentationPreferences
  ) -> AccountPresentationPreferences {
    let groups = mergeCustomGroups(baseline: baseline.customAccountGroups, local: local.customAccountGroups, remote: remote.customAccountGroups)
    return AccountPresentationPreferences(
      favouriteAccountIDs: local.favouriteAccountIDs != baseline.favouriteAccountIDs ? local.favouriteAccountIDs : remote.favouriteAccountIDs,
      accountOrder: local.accountOrder != baseline.accountOrder ? local.accountOrder : remote.accountOrder,
      accountOrderByGroup: mergeMap(baseline: baseline.accountOrderByGroup, local: local.accountOrderByGroup, remote: remote.accountOrderByGroup),
      accountGroupSorts: mergeMap(baseline: baseline.accountGroupSorts, local: local.accountGroupSorts, remote: remote.accountGroupSorts),
      customAccountGroups: groups
    )
  }

  private init(
    favouriteAccountIDs: [String],
    accountOrder: [String],
    accountOrderByGroup: [String: [String]],
    accountGroupSorts: [String: AccountGroupSort],
    customAccountGroups: [CustomAccountGroup]
  ) {
    self.favouriteAccountIDs = favouriteAccountIDs
    self.accountOrder = accountOrder
    self.accountOrderByGroup = accountOrderByGroup
    self.accountGroupSorts = accountGroupSorts
    self.customAccountGroups = customAccountGroups
  }
}

private func mergeMap<Value: Equatable>(baseline: [String: Value], local: [String: Value], remote: [String: Value]) -> [String: Value] {
  var result = remote
  for key in Set(baseline.keys).union(local.keys) where local[key] != baseline[key] {
    result[key] = local[key]
  }
  return result
}

private func mergeCustomGroups(
  baseline: [CustomAccountGroup],
  local: [CustomAccountGroup],
  remote: [CustomAccountGroup]
) -> [CustomAccountGroup] {
  let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
  let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
  let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
  let localChangedOrder = local.map(\.id) != baseline.map(\.id)
  let preferredOrder = localChangedOrder
    ? local.map(\.id) + remote.map(\.id).filter { baselineByID[$0] == nil && localByID[$0] == nil }
    : remote.map(\.id)
  return preferredOrder.compactMap { id in
    localByID[id] != baselineByID[id] ? localByID[id] : remoteByID[id]
  }
}

struct SyncedAccountPreferences: Codable, Equatable {
  let preferences: AccountPresentationPreferences
  let revision: Int
}

private extension Array where Element == String {
  var uniqueNonEmptyStrings: [String] {
    var seen: Set<String> = []
    return compactMap { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
        return nil
      }
      return trimmed
    }
  }
}

/// Versioned, connection/user/plan-scoped preference envelope.
struct ScopedViewPrefsStore: Codable, Equatable {
  static let userDefaultsKey = "HowMuch.ViewPrefsByScope"

  var scopes: [String: ViewPrefs] = [:]
  var syncedAccountPreferences: [String: SyncedAccountPreferences] = [:]
  var didMigrateLegacy = false

  private enum CodingKeys: String, CodingKey {
    case scopes
    case syncedAccountPreferences
    case didMigrateLegacy
  }

  init(
    scopes: [String: ViewPrefs] = [:],
    syncedAccountPreferences: [String: SyncedAccountPreferences] = [:],
    didMigrateLegacy: Bool = false
  ) {
    self.scopes = scopes.mapValues { $0.structurallyNormalised() }
    self.syncedAccountPreferences = syncedAccountPreferences
    self.didMigrateLegacy = didMigrateLegacy
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let scopeContainer = try? container.nestedContainer(
      keyedBy: ViewPrefsScopeCodingKey.self,
      forKey: .scopes
    ) {
      scopes = scopeContainer.allKeys.reduce(into: [:]) { decoded, key in
        guard let preferences = try? scopeContainer.decode(ViewPrefs.self, forKey: key) else {
          return
        }
        decoded[key.stringValue] = preferences.structurallyNormalised()
      }
    } else {
      scopes = [:]
    }
    syncedAccountPreferences = try container.decodeIfPresent(
      [String: SyncedAccountPreferences].self,
      forKey: .syncedAccountPreferences
    ) ?? [:]
    didMigrateLegacy = try container.decodeIfPresent(Bool.self, forKey: .didMigrateLegacy) ?? false
  }

  static func load(from defaults: UserDefaults = .standard) -> ScopedViewPrefsStore {
    guard
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(ScopedViewPrefsStore.self, from: data)
    else {
      return ScopedViewPrefsStore()
    }
    return decoded
  }

  mutating func activate(scope: String, legacy: ViewPrefs) -> ViewPrefs {
    if let existing = scopes[scope] {
      if !didMigrateLegacy {
        didMigrateLegacy = true
        save()
      }
      return existing.structurallyNormalised()
    }
    if !didMigrateLegacy {
      let migrated = legacy.structurallyNormalised()
      scopes[scope] = migrated
      didMigrateLegacy = true
      save()
      return migrated
    }
    return ViewPrefs()
  }

  /// An unscoped legacy blob cannot safely be assigned to a user who signs in
  /// later: that user may not be the person who created it. Authenticated cold
  /// launches migrate above; signed-out cold launches deliberately discard the
  /// migration opportunity while leaving any already-scoped preferences intact.
  mutating func discardUnscopedLegacyMigration() {
    guard !didMigrateLegacy else { return }
    didMigrateLegacy = true
    save()
  }

  mutating func set(_ preferences: ViewPrefs, for scope: String) {
    scopes[scope] = preferences.structurallyNormalised()
    save()
  }

  mutating func markAccountPreferencesSynced(_ snapshot: SyncedAccountPreferences, for scope: String) {
    syncedAccountPreferences[scope] = snapshot
    save()
  }

  func save(to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else {
      return
    }
    defaults.set(data, forKey: Self.userDefaultsKey)
  }
}

private struct ViewPrefsScopeCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    return nil
  }
}

/// Sorting is intentionally local to an account group. Names and manual order
/// stay useful offline, while usage is refreshed from the ledger when needed.
enum AccountGroupSort: String, Codable, CaseIterable, Identifiable {
  case manual
  case alphabetical
  case mostUsedLast30Days

  var id: String { rawValue }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self = AccountGroupSort(rawValue: (try? container.decode(String.self)) ?? "") ?? .manual
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  var title: String {
    switch self {
    case .manual: "Manual"
    case .alphabetical: "Alphabetical"
    case .mostUsedLast30Days: "Most used (30 days)"
    }
  }
}

/// A synced account collection. Membership is deliberately represented by IDs
/// so account balances and names remain authoritative API data.
struct CustomAccountGroup: Codable, Equatable, Hashable, Identifiable {
  static let reservedIDs: Set<String> = ["favourites", "cash", "credit", "tracking", "closed"]
  static let reservedNameKeys: Set<String> = Set(["Favourites", "Cash", "Credit", "Tracking", "Closed"].map(normalisedNameKey))

  var id: String
  var name: String
  var accountIDs: [String]

  static func normalisedNameKey(_ name: String) -> String {
    name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }
}

struct UserPayload: Decodable {
  let user: APIUser
}

struct APIUser: Decodable {
  let id: String
  let username: String?
}

struct AuthTokenPayload: Decodable {
  let token: String
  let expiresAt: Int
  let user: APIUser
}

struct AuthStatusPayload: Decodable {
  let setupRequired: Bool
  let bootstrapRequired: Bool
  let user: APIUser?
}

struct PlansPayload: Decodable {
  let plans: [PlanSummary]
}

struct PlanSummary: Decodable, Equatable, Identifiable {
  let id: String
  let name: String
}

struct ReferenceData {
  let planSettings: PlanSettings
  let accounts: [Account]
  let categoryGroups: [CategoryGroup]
  let payees: [Payee]
  let accountPreferences: SyncedAccountPreferences?
}

struct AccountPreferencesPayload: Codable {
  let accountPreferences: APIAccountPreferences?
  let accountPreferencesRevision: Int
}

struct AccountPreferencesWriteRequest: Encodable {
  let accountPreferences: APIAccountPreferences
  let expectedRevision: Int
}

struct APIAccountPreferences: Codable {
  let favouriteAccountIds: [String]
  let accountOrder: [String]
  let accountOrderByGroup: [String: [String]]
  let accountGroupSorts: [String: AccountGroupSort]
  let customAccountGroups: [APICustomAccountGroup]

  init(_ preferences: AccountPresentationPreferences) {
    favouriteAccountIds = preferences.favouriteAccountIDs
    accountOrder = preferences.accountOrder
    accountOrderByGroup = preferences.accountOrderByGroup
    accountGroupSorts = preferences.accountGroupSorts
    customAccountGroups = preferences.customAccountGroups.map(APICustomAccountGroup.init)
  }

  var presentationPreferences: AccountPresentationPreferences {
    var preferences = ViewPrefs()
    preferences.favouriteAccountIDs = favouriteAccountIds
    preferences.accountOrder = accountOrder
    preferences.accountOrderByGroup = accountOrderByGroup
    preferences.accountGroupSorts = accountGroupSorts
    preferences.customAccountGroups = customAccountGroups.map(\.customAccountGroup)
    return AccountPresentationPreferences(preferences.structurallyNormalised())
  }
}

struct APICustomAccountGroup: Codable {
  let id: String
  let name: String
  let accountIds: [String]

  init(_ group: CustomAccountGroup) {
    id = group.id
    name = group.name
    accountIds = group.accountIDs
  }

  var customAccountGroup: CustomAccountGroup {
    CustomAccountGroup(id: id, name: name, accountIDs: accountIds)
  }
}

struct PlanSettingsPayload: Decodable {
  let settings: PlanSettings
}

struct AccountsPayload: Decodable {
  let accounts: [Account]
}

struct AccountPayload: Decodable {
  let account: Account
}

struct AccountIconWriteRequest: Encodable {
  let account: AccountWriteBody

  init(icon: String? = nil, name: String? = nil) {
    account = AccountWriteBody(icon: icon, name: name)
  }

  struct AccountWriteBody: Encodable {
    let icon: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
      case icon, name
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encodeIfPresent(icon, forKey: .icon)
      try container.encodeIfPresent(name, forKey: .name)
    }
  }
}

struct CategoriesPayload: Decodable {
  let categoryGroups: [CategoryGroup]
}

struct PayeesPayload: Decodable {
  let payees: [Payee]
}

struct PlanMonthPayload: Decodable {
  let month: PlanMonth
  let serverKnowledge: Int?
}

struct PlanAssignmentRequest: Encodable {
  private let category: Category

  init(budgeted: Int) {
    category = Category(budgeted: budgeted)
  }

  private struct Category: Encodable {
    let budgeted: Int
  }
}

struct PlanTargetRequest: Encodable {
  private let category: Category

  init(target: PlanTargetPayload?) {
    category = Category(target: target)
  }

  private struct Category: Encodable {
    let target: PlanTargetPayload?

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(target, forKey: .target)
    }

    private enum CodingKeys: String, CodingKey {
      case target
    }
  }
}

struct PlanTargetRestoreRequest: Encodable {
  private let category = Category()

  private struct Category: Encodable {
    let restoreTarget = true
  }
}

struct PlanTargetPayload: Encodable {
  let goalType: String
  let goalTarget: Int
  let goalTargetMonth: String?
}

/// A monthly planning snapshot. Imported values stay read-only unless a
/// HowMuch-owned assignment or target overlay is present.
struct PlanMonth: Decodable {
  let month: String
  let note: String?
  let income: Int?
  let budgeted: Int?
  let activity: Int?
  let toBeBudgeted: Int?
  let ageOfMoney: Int?
  let deleted: Bool?
  let categories: [PlanMonthCategory]
}

struct PlanMonthCategory: Decodable, Identifiable, Hashable {
  let id: String
  let name: String
  let categoryGroupID: String
  let hidden: Bool?
  let originalCategoryGroupID: String?
  let note: String?
  let budgeted: Int?
  let activity: Int?
  let balance: Int?
  let goalType: String?
  let goalDay: Int?
  let goalCadence: Int?
  let goalCadenceFrequency: Int?
  let goalCreationMonth: String?
  let goalTarget: Int?
  let goalTargetMonth: String?
  let goalPercentageComplete: Int?
  let goalMonthsToBudget: Int?
  let goalUnderFunded: Int?
  let goalOverallFunded: Int?
  let goalOverallLeft: Int?
  let goalNeededForSpending: Int?
  let goalNeedsWholeAmount: Bool?
  let targetSource: String?
  let deleted: Bool?

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    // `convertFromSnakeCase` normalises the API's `*_id` suffix to `*Id`.
    // Swift acronym spelling therefore needs the same explicit bridge used by
    // Category, Transaction, and the report models below.
    case categoryGroupID = "categoryGroupId"
    case hidden
    case originalCategoryGroupID = "originalCategoryGroupId"
    case note
    case budgeted
    case activity
    case balance
    case goalType
    case goalDay
    case goalCadence
    case goalCadenceFrequency
    case goalCreationMonth
    case goalTarget
    case goalTargetMonth
    case goalPercentageComplete
    case goalMonthsToBudget
    case goalUnderFunded
    case goalOverallFunded
    case goalOverallLeft
    case goalNeededForSpending
    case goalNeedsWholeAmount
    case targetSource
    case deleted
  }

  var hasTarget: Bool {
    goalType != nil || (goalTarget ?? 0) != 0
  }

  var targetProgress: Double? {
    if let goalPercentageComplete {
      return min(max(Double(goalPercentageComplete) / 100, 0), 1)
    }
    guard let goalTarget, goalTarget > 0 else {
      return nil
    }
    return min(max(Double(balance ?? 0) / Double(goalTarget), 0), 1)
  }
}

struct Payee: Decodable, Identifiable, Hashable {
  let id: String
  let name: String
  let transferAccountId: String?
  let deleted: Bool?

  var isTransferPayee: Bool {
    transferAccountId != nil
  }

  func withName(_ name: String) -> Payee {
    Payee(id: id, name: name, transferAccountId: transferAccountId, deleted: deleted)
  }
}

struct TransactionsPayload: Decodable {
  let transactions: [Transaction]
  let serverKnowledge: Int?
  let hasMore: Bool?
  let nextOffset: Int?
}

/// One bounded, newest-first ledger page from the HowMuch transaction API.
/// Deleted rows are removed by `APIClient` before the page reaches the UI.
struct TransactionPage {
  let transactions: [Transaction]
  let hasMore: Bool
  let nextOffset: Int?
  let serverKnowledge: Int?
}

struct TransactionPayload: Decodable {
  let transaction: Transaction
  let serverKnowledge: Int?
}

struct ScheduledTransactionsPayload: Decodable {
  let scheduledTransactions: [ScheduledTransaction]
  let serverKnowledge: Int?
}

struct PlanSettings: Decodable {
  let dateFormat: DateFormat?
  let currencyFormat: CurrencyFormat?
  let display: DisplaySettings?
}

struct DateFormat: Decodable {
  let format: String?
}

struct CurrencyFormat: Decodable {
  let isoCode: String?
  let exampleFormat: String?
  let decimalDigits: Int?
  let decimalSeparator: String?
  let groupSeparator: String?
  let symbolFirst: Bool?
  let currencySymbol: String?
}

struct DisplaySettings: Decodable {
  let flagNames: [String]?

  private enum CodingKeys: String, CodingKey {
    case flagNames
  }

  init(flagNames: [String]? = nil) {
    self.flagNames = flagNames
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    if let array = try? container.decodeIfPresent([String?].self, forKey: .flagNames) {
      flagNames = array.compactMap { value in
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
          return nil
        }
        return trimmed
      }
      return
    }

    if let mapping = try? container.decodeIfPresent([String: String].self, forKey: .flagNames) {
      flagNames = mapping
        .sorted { $0.key < $1.key }
        .map(\.value)
      return
    }

    flagNames = nil
  }
}

struct Account: Decodable, Identifiable, Hashable {
  let id: String
  let name: String
  let icon: String?
  let type: String
  let onBudget: Bool
  let closed: Bool
  let balance: Int
  let clearedBalance: Int
  let unclearedBalance: Int
  let deleted: Bool

  var displayIcon: String {
    AccountIcon.displayGlyph(stored: icon, accountType: type)
  }

  func withIcon(_ icon: String) -> Account {
    withIdentity(name: name, icon: icon)
  }

  func withIdentity(name: String, icon: String) -> Account {
    Account(
      id: id,
      name: name,
      icon: icon,
      type: type,
      onBudget: onBudget,
      closed: closed,
      balance: balance,
      clearedBalance: clearedBalance,
      unclearedBalance: unclearedBalance,
      deleted: deleted
    )
  }
}

struct CategoryGroup: Decodable, Identifiable, Hashable {
  /// Matches the API's COALESCE id for transactions without a category, so it
  /// can be used as a pseudo-category in report filters (as on the web).
  static let uncategorisedCategoryID = "uncategorised"

  let id: String
  let name: String
  let hidden: Bool
  let deleted: Bool
  let categories: [Category]

  /// Bookkeeping groups the YNAB import carries as ordinary groups ("Hidden
  /// Categories", "Non-Personal (Don't Summarise)", inflows). Mirrors the web
  /// app's quiet-group regex in lib/categories.ts so pickers and reports
  /// demote the same groups everywhere.
  var isQuiet: Bool {
    hidden || CategoryGroup.isQuietName(name)
  }

  static func isQuietName(_ name: String?) -> Bool {
    guard let name else {
      return false
    }
    let pattern = "hidden|non.personal|don.t summari[sz]e|inflow|credit card payments|internal"
    return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }
}

struct Category: Decodable, Identifiable, Hashable {
  let id: String
  let categoryGroupID: String
  let name: String
  let deleted: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case categoryGroupID = "categoryGroupId"
    case name
    case deleted
  }
}

enum ClearedState: String, Codable, CaseIterable, Identifiable {
  case uncleared
  case cleared
  case reconciled

  var id: String { rawValue }

  var title: String {
    switch self {
    case .uncleared:
      return "Uncleared"
    case .cleared:
      return "Cleared"
    case .reconciled:
      return "Reconciled"
    }
  }
}

enum FlagColour: String, Codable, CaseIterable, Identifiable {
  case none = ""
  case red
  case orange
  case yellow
  case green
  case blue
  case purple

  var id: String { rawValue }

  var title: String {
    rawValue.isEmpty ? "None" : rawValue.capitalized
  }
}

struct Transaction: Decodable, Identifiable, Hashable {
  let id: String
  let date: String
  let amount: Int
  let memo: String?
  let cleared: ClearedState
  let approved: Bool
  let flagColor: String?
  let flagName: String?
  let accountID: String
  let accountName: String
  let payeeID: String?
  let payeeName: String?
  let categoryID: String?
  let categoryName: String?
  let transferAccountID: String?
  let transferTransactionID: String?
  let parentTransactionID: String?
  let matchedTransactionID: String?
  let importID: String?
  let importPayeeName: String?
  let importPayeeNameOriginal: String?
  let deleted: Bool
  let subtransactions: [Subtransaction]

  private enum CodingKeys: String, CodingKey {
    case id
    case date
    case amount
    case memo
    case cleared
    case approved
    case flagColor
    case flagName
    case accountID = "accountId"
    case accountName
    case payeeID = "payeeId"
    case payeeName
    case categoryID = "categoryId"
    case categoryName
    case transferAccountID = "transferAccountId"
    case transferTransactionID = "transferTransactionId"
    case parentTransactionID = "parentTransactionId"
    case matchedTransactionID = "matchedTransactionId"
    case importID = "importId"
    case importPayeeName = "importPayeeName"
    case importPayeeNameOriginal = "importPayeeNameOriginal"
    case deleted
    case subtransactions
  }
}

extension Transaction {
  /// True when the row still needs a category: no category, not a transfer,
  /// and not a split (whose categories live on the subtransactions).
  var isUncategorised: Bool {
    categoryID == nil && transferAccountID == nil && subtransactions.isEmpty
  }

  var isSplit: Bool {
    !subtransactions.isEmpty
  }

  /// Single-transaction writes can omit `parentTransactionID`. Keep the list value.
  func preservingParent(from existing: Transaction) -> Transaction {
    guard parentTransactionID == nil, let parentTransactionID = existing.parentTransactionID else {
      return self
    }
    return Transaction(
      id: id,
      date: date,
      amount: amount,
      memo: memo,
      cleared: cleared,
      approved: approved,
      flagColor: flagColor,
      flagName: flagName,
      accountID: accountID,
      accountName: accountName,
      payeeID: payeeID,
      payeeName: payeeName,
      categoryID: categoryID,
      categoryName: categoryName,
      transferAccountID: transferAccountID,
      transferTransactionID: transferTransactionID,
      parentTransactionID: parentTransactionID,
      matchedTransactionID: matchedTransactionID,
      importID: importID,
      importPayeeName: importPayeeName,
      importPayeeNameOriginal: importPayeeNameOriginal,
      deleted: deleted,
      subtransactions: subtransactions
    )
  }
}

struct Subtransaction: Decodable, Hashable {
  let id: String
  let transactionID: String
  let amount: Int
  let memo: String?
  let payeeID: String?
  let payeeName: String?
  let categoryID: String?
  let categoryName: String?
  let transferAccountID: String?
  let transferTransactionID: String?
  let deleted: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case transactionID = "transactionId"
    case amount
    case memo
    case payeeID = "payeeId"
    case payeeName
    case categoryID = "categoryId"
    case categoryName
    case transferAccountID = "transferAccountId"
    case transferTransactionID = "transferTransactionId"
    case deleted
  }
}

/// An imported YNAB scheduled transaction. The API deliberately exposes this
/// as a read-only source mirror, so the app never offers an edit action here.
struct ScheduledTransaction: Decodable, Identifiable, Hashable {
  let id: String
  let dateFirst: String
  let dateNext: String
  let frequency: String
  let amount: Int
  let memo: String?
  let flagColor: String?
  let accountID: String
  let payeeID: String?
  let categoryID: String?
  let transferAccountID: String?
  let deleted: Bool
  let subtransactions: [ScheduledSubtransaction]

  private enum CodingKeys: String, CodingKey {
    case id
    case dateFirst = "dateFirst"
    case dateNext = "dateNext"
    case frequency
    case amount
    case memo
    case flagColor = "flagColor"
    case accountID = "accountId"
    case payeeID = "payeeId"
    case categoryID = "categoryId"
    case transferAccountID = "transferAccountId"
    case deleted
    case subtransactions
  }

  var isSplit: Bool {
    !activeSubtransactions.isEmpty
  }

  var activeSubtransactions: [ScheduledSubtransaction] {
    subtransactions.filter { !$0.deleted }
  }

  var recurrenceLabel: String {
    switch frequency {
    case "never": return "Does not repeat"
    case "daily": return "Repeats daily"
    case "weekly": return "Repeats weekly"
    case "everyOtherWeek": return "Repeats every other week"
    case "twiceAMonth": return "Repeats twice a month"
    case "every4Weeks": return "Repeats every 4 weeks"
    case "monthly": return "Repeats monthly"
    case "everyOtherMonth": return "Repeats every other month"
    case "every3Months": return "Repeats every 3 months"
    case "every4Months": return "Repeats every 4 months"
    case "twiceAYear": return "Repeats twice a year"
    case "yearly": return "Repeats yearly"
    case "everyOtherYear": return "Repeats every other year"
    default:
      let words = frequency
        .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        .lowercased()
      return "Repeats \(words)"
    }
  }
}

struct ScheduledSubtransaction: Decodable, Hashable {
  let id: String
  let scheduledTransactionID: String
  let amount: Int
  let memo: String?
  let payeeID: String?
  let categoryID: String?
  let transferAccountID: String?
  let deleted: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case scheduledTransactionID = "scheduledTransactionId"
    case amount
    case memo
    case payeeID = "payeeId"
    case categoryID = "categoryId"
    case transferAccountID = "transferAccountId"
    case deleted
  }
}

/// Response from entering one selected scheduled occurrence. The server
/// advances (or completes) the parent schedule atomically with the ledger
/// transaction, then the app refreshes every affected surface.
struct ScheduledOccurrencePayload: Decodable {
  let transaction: Transaction
  let scheduledTransaction: ScheduledTransaction
  let occurrenceDate: String
  let enteredDate: String
  let completed: Bool
  let replayed: Bool
}

struct ScheduledOccurrenceRequest: Encodable {
  let occurrenceDate: String
  let date: String
}

struct AccountReconciliationPayload: Decodable {
  let account: Account
  let reconciledTransactionIDs: [String]
  let reconciledTransactionCount: Int
  let statementDate: String
  let statementBalance: Int
  let priorReconciledBalance: Int
  let finalReconciledBalance: Int
  let replayed: Bool
}

/// A read-only reconciliation projection. It is deliberately separate from
/// the mutation response: the review screen must show the server's current
/// candidate set before it is safe to confirm.
struct AccountReconciliationPreview: Decodable {
  let account: Account
  let statementDate: String
  let currentReconciledBalance: Int
  let projectedReconciledBalance: Int
  let candidateTransactionIDs: [String]
  let candidateTransactionCount: Int
}

struct AccountReconciliationRequest: Encodable {
  let statementDate: String
  let statementBalance: Int
}

struct ReconciliationMismatchDetail: Equatable {
  let currentReconciledBalance: Int
  let projectedReconciledBalance: Int
  let statementBalance: Int
  let difference: Int
  let message: String
}

struct SpendingBreakdownReport: Decodable {
  let total: Int
  let groups: [SpendingBreakdownGroup]
}

struct SpendingBreakdownGroup: Decodable, Identifiable {
  var id: String { categoryID }

  let categoryID: String
  let categoryName: String
  let categoryGroupID: String
  let categoryGroupName: String
  let amount: Int
  let share: Double
  let transactionCount: Int

  private enum CodingKeys: String, CodingKey {
    case categoryID = "categoryId"
    case categoryName = "categoryName"
    case categoryGroupID = "categoryGroupId"
    case categoryGroupName = "categoryGroupName"
    case amount
    case share
    case transactionCount = "transactionCount"
  }
}

struct IncomeVsSpendingReport: Decodable {
  let interval: String
  let periods: [IncomeVsSpendingPeriod]
}

struct IncomeVsSpendingPeriod: Decodable, Identifiable {
  var id: String { period }

  let period: String
  let income: Int
  let spending: Int
  let net: Int
  let cumulativeNet: Int
}

struct NetWorthReport: Decodable {
  let periods: [NetWorthPeriod]
}

struct NetWorthPeriod: Decodable, Identifiable {
  var id: String { period }

  let period: String
  let endDate: String
  let netWorth: Int
  let delta: Int?
  let accounts: [NetWorthAccount]
}

struct NetWorthAccount: Decodable, Identifiable {
  var id: String { accountID }

  let accountID: String
  let accountName: String
  let balance: Int

  private enum CodingKeys: String, CodingKey {
    case accountID = "accountId"
    case accountName = "accountName"
    case balance
  }
}

struct AgeOfMoneyReport: Decodable {
  let interval: String
  let periods: [AgeOfMoneyPeriod]
}

struct AgeOfMoneyPeriod: Decodable, Identifiable {
  var id: String { period }

  let period: String
  let ageOfMoneyDays: Double?
  let spent: Int
  let unmatchedSpending: Int
}

struct TransactionWriteEnvelope: Encodable {
  let transaction: TransactionWriteRequest
}

struct TransactionApprovalEnvelope: Encodable {
  let transaction: TransactionApprovalRequest
}

struct TransactionApprovalRequest: Encodable {
  let approved: Bool
}

struct TransactionSubtransactionWriteRequest: Codable, Equatable {
  let id: String?
  let amount: Int
  let payeeID: String?
  let payeeName: String?
  let categoryID: String?
  let memo: String?
  let transferAccountID: String?
  /// Existing split-transfer mirrors must survive a parent edit. The API
  /// accepts this optional link and uses it instead of minting a new mirror.
  let transferTransactionID: String?
}

/// Create/update body. Encodes optional fields as explicit nulls so an update
/// can clear them — the API treats omitted keys as "keep existing".
/// Cleared status is the exception: edits omit it so the guarded status
/// endpoint remains its sole owner.
/// Decodable too, so offline captures can be persisted and replayed.
struct TransactionWriteRequest: Codable, Equatable {
  let accountID: String
  let date: String
  let amount: Int
  let payeeID: String?
  let payeeName: String?
  let categoryID: String?
  let memo: String?
  /// Nil only for edits, where status is owned by the register's guarded
  /// compare-and-set control rather than a potentially stale full form.
  let cleared: ClearedState?
  let approved: Bool
  let flagColor: String?
  let subtransactions: [TransactionSubtransactionWriteRequest]
  /// Client-minted create identity. The server returns the existing row when
  /// this value is replayed, so a lost response cannot double-post money.
  var importID: String?

  private enum CodingKeys: String, CodingKey {
    case accountID
    case date
    case amount
    case payeeID
    case payeeName
    case categoryID
    case memo
    case cleared
    case approved
    case flagColor
    case subtransactions
    case importID
  }

  init(
    accountID: String,
    date: String,
    amount: Int,
    payeeID: String?,
    payeeName: String?,
    categoryID: String?,
    memo: String?,
    cleared: ClearedState?,
    approved: Bool,
    flagColor: String?,
    subtransactions: [TransactionSubtransactionWriteRequest],
    importID: String? = nil
  ) {
    self.accountID = accountID
    self.date = date
    self.amount = amount
    self.payeeID = payeeID
    self.payeeName = payeeName
    self.categoryID = categoryID
    self.memo = memo
    self.cleared = cleared
    self.approved = approved
    self.flagColor = flagColor
    self.subtransactions = subtransactions
    self.importID = importID
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(accountID, forKey: .accountID)
    try container.encode(date, forKey: .date)
    try container.encode(amount, forKey: .amount)
    try container.encode(payeeID, forKey: .payeeID)
    try container.encode(payeeName, forKey: .payeeName)
    try container.encode(categoryID, forKey: .categoryID)
    try container.encode(memo, forKey: .memo)
    try container.encodeIfPresent(cleared, forKey: .cleared)
    try container.encode(approved, forKey: .approved)
    try container.encode(flagColor, forKey: .flagColor)
    try container.encode(subtransactions, forKey: .subtransactions)
    try container.encodeIfPresent(importID, forKey: .importID)
  }

  /// Captures made before split support did not persist this key. Keep those
  /// offline entries replayable instead of dropping the whole outbox on
  /// upgrade.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountID = try container.decode(String.self, forKey: .accountID)
    date = try container.decode(String.self, forKey: .date)
    amount = try container.decode(Int.self, forKey: .amount)
    payeeID = try container.decodeIfPresent(String.self, forKey: .payeeID)
    payeeName = try container.decodeIfPresent(String.self, forKey: .payeeName)
    categoryID = try container.decodeIfPresent(String.self, forKey: .categoryID)
    memo = try container.decodeIfPresent(String.self, forKey: .memo)
    cleared = try container.decodeIfPresent(ClearedState.self, forKey: .cleared)
    approved = try container.decode(Bool.self, forKey: .approved)
    flagColor = try container.decodeIfPresent(String.self, forKey: .flagColor)
    subtransactions = try container.decodeIfPresent([TransactionSubtransactionWriteRequest].self, forKey: .subtransactions) ?? []
    importID = try container.decodeIfPresent(String.self, forKey: .importID)
  }
}

struct PendingTransaction: Codable, Equatable, Identifiable {
  let id: UUID
  let request: TransactionWriteRequest
  let connectionFingerprint: String
  let capturedAt: Date
  /// Last non-transport failure from a sync attempt, e.g. a server rejection.
  var lastSyncError: String?

  init(request: TransactionWriteRequest, connectionFingerprint: String, capturedAt: Date = .now) {
    id = UUID()
    var request = request
    if request.importID == nil {
      request.importID = id.uuidString.lowercased()
    }
    self.request = request
    self.connectionFingerprint = connectionFingerprint
    self.capturedAt = capturedAt
  }
}

enum OutboxStore {
  static let userDefaultsKey = "HowMuch.Outbox"

  static func load(from defaults: UserDefaults = .standard) -> [PendingTransaction] {
    guard
      let data = defaults.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode([PendingTransaction].self, from: data)
    else {
      return []
    }
    return decoded
  }

  static func save(_ pending: [PendingTransaction], to defaults: UserDefaults = .standard) throws {
    let data = try JSONEncoder().encode(pending)
    defaults.set(data, forKey: userDefaultsKey)
  }
}

struct SaveMessage: Equatable, Identifiable {
  enum Kind: Equatable {
    case success
    case failure
  }

  let id: Int
  let text: String
  let kind: Kind
}

enum CommitRejection: LocalizedError, Equatable {
  case incomplete
  case invalidSplit(String)
  case persistFailed

  static func check(_ draft: TransactionDraft) throws {
    if let message = draft.splitValidationMessage {
      throw CommitRejection.invalidSplit(message)
    }
    guard draft.canSave else {
      throw CommitRejection.incomplete
    }
  }

  var errorDescription: String? {
    switch self {
    case .incomplete:
      return "Enter an amount and pick an account."
    case .invalidSplit(let message):
      return message
    case .persistFailed:
      return "Couldn’t save this transaction locally. Try again."
    }
  }
}

struct PendingRow: Identifiable, Equatable {
  enum Status: Equatable {
    case sending
    case waitingForConnection
    case rejected(String)
  }

  typealias ID = UUID

  let id: ID
  let accountID: String
  let accountName: String
  let isoDate: String
  let signedAmount: Int
  let payeeName: String?
  let categoryID: String?
  let categoryName: String?
  let memo: String?
  let flag: FlagColour
  let splitLineCount: Int
  let splitCategoryIDs: [String]
  let isCleared: Bool
  let status: Status

  init(
    pending: PendingTransaction,
    status: Status,
    accountName: String,
    categoryName: String?,
    payeeName: String?
  ) {
    let request = pending.request
    id = pending.id
    accountID = request.accountID
    self.accountName = accountName
    isoDate = request.date
    signedAmount = request.amount
    self.payeeName = payeeName ?? request.payeeName
    categoryID = request.categoryID
    self.categoryName = categoryName
    memo = request.memo
    flag = FlagColour(rawValue: request.flagColor ?? "") ?? .none
    splitLineCount = request.subtransactions.count
    splitCategoryIDs = request.subtransactions.compactMap(\.categoryID)
    isCleared = request.cleared != nil && request.cleared != .uncleared
    self.status = status
  }

  func matches(categoryID: String) -> Bool {
    self.categoryID == categoryID || splitCategoryIDs.contains(categoryID)
  }
}

struct PendingEdit: Equatable {
  let transactionID: String
  let isoDate: String
  let amount: Int
  let accountID: String
  let accountName: String
  let payeeID: String?
  let payeeName: String?
  let categoryID: String?
  let categoryName: String?
  let memo: String?
  let flagColor: String?
  let cleared: ClearedState?

  init?(
    draft: TransactionDraft,
    existing: Transaction,
    accountName: String,
    categoryName: String?,
    payeeName: String?
  ) {
    guard draft.isSplit == existing.isSplit else {
      return nil
    }
    transactionID = existing.id
    isoDate = draft.date.isoDateString
    amount = draft.signedMilliunits
    accountID = draft.accountID
    self.accountName = accountName
    payeeID = draft.payeeID
    self.payeeName = payeeName
    categoryID = draft.isSplit ? existing.categoryID : draft.categoryID
    self.categoryName = draft.isSplit ? existing.categoryName : categoryName
    memo = draft.memo.trimmedNil
    flagColor = draft.flag.rawValue.isEmpty ? nil : draft.flag.rawValue
    cleared = draft.shouldWriteCleared ? draft.clearedState : nil
  }

  func applied(to transaction: Transaction) -> Transaction {
    Transaction(
      id: transaction.id,
      date: isoDate,
      amount: amount,
      memo: memo,
      cleared: cleared ?? transaction.cleared,
      approved: transaction.approved,
      flagColor: flagColor,
      flagName: transaction.flagName,
      accountID: accountID,
      accountName: accountName,
      payeeID: payeeID,
      payeeName: payeeName,
      categoryID: categoryID,
      categoryName: categoryName,
      transferAccountID: transaction.transferAccountID,
      transferTransactionID: transaction.transferTransactionID,
      parentTransactionID: transaction.parentTransactionID,
      matchedTransactionID: transaction.matchedTransactionID,
      importID: transaction.importID,
      importPayeeName: transaction.importPayeeName,
      importPayeeNameOriginal: transaction.importPayeeNameOriginal,
      deleted: transaction.deleted,
      subtransactions: transaction.subtransactions
    )
  }
}

enum OutboxDrainTrigger: Equatable {
  case commit
  case refresh
  case manual
}

enum EntryDirection: String, CaseIterable, Identifiable {
  case outflow
  case inflow

  var id: String { rawValue }

  var title: String {
    switch self {
    case .outflow:
      return "− Outflow"
    case .inflow:
      return "+ Inflow"
    }
  }
}

/// Editable state behind both the Add Transaction sheet and the edit form.
struct TransactionSubtransactionDraft: Equatable {
  /// Existing IDs are preserved on edit. Fresh and duplicated lines omit IDs
  /// so the server creates a distinct graph rather than mutating the source.
  var id: String?
  var amountText: String
  var payeeID: String?
  var payeeName: String
  var categoryID: String?
  var transferAccountID: String?
  var transferTransactionID: String?
  /// The account paired with `transferTransactionID` when this line was
  /// loaded. Changing the target must mint a new mirror, not reuse the old
  /// mirror ID against a different account.
  private var mirroredTransferAccountID: String?
  var memo: String

  init(
    id: String? = nil,
    amountText: String = "0",
    payeeID: String? = nil,
    payeeName: String = "",
    categoryID: String? = nil,
    transferAccountID: String? = nil,
    transferTransactionID: String? = nil,
    mirroredTransferAccountID: String? = nil,
    memo: String = ""
  ) {
    self.id = id
    self.amountText = amountText
    self.payeeID = payeeID
    self.payeeName = payeeName
    self.categoryID = categoryID
    self.transferAccountID = transferAccountID
    self.transferTransactionID = transferTransactionID
    self.mirroredTransferAccountID = mirroredTransferAccountID ?? transferAccountID
    self.memo = memo
  }

  init(subtransaction: Subtransaction, preserveID: Bool = true) {
    id = preserveID ? subtransaction.id : nil
    amountText = MoneyCodec.displayString(for: subtransaction.amount, currencyFormat: nil)
    payeeID = subtransaction.payeeID
    payeeName = subtransaction.payeeName ?? ""
    categoryID = subtransaction.categoryID
    transferAccountID = subtransaction.transferAccountID
    transferTransactionID = subtransaction.transferTransactionID
    mirroredTransferAccountID = subtransaction.transferAccountID
    memo = subtransaction.memo ?? ""
  }

  var amount: Int? { MoneyCodec.milliunits(from: amountText) }

  func writeRequest() -> TransactionSubtransactionWriteRequest? {
    guard let amount else { return nil }
    let trimmedPayeeName = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    return TransactionSubtransactionWriteRequest(
      id: id,
      amount: amount,
      payeeID: transferAccountID == nil ? payeeID : nil,
      payeeName: transferAccountID == nil && !trimmedPayeeName.isEmpty ? trimmedPayeeName : nil,
      categoryID: transferAccountID == nil ? categoryID : nil,
      memo: memo.trimmedNil,
      transferAccountID: transferAccountID,
      transferTransactionID: transferAccountID == mirroredTransferAccountID ? transferTransactionID : nil
    )
  }
}

struct TransactionDraft: Equatable {
  var id: String?
  var importID: String?
  var direction: EntryDirection = .outflow
  /// Magnitude only; the Outflow/Inflow toggle owns the sign.
  var amountMagnitudeMilli = 0
  var payeeID: String?
  var payeeName = ""
  var accountID = ""
  var categoryID: String?
  /// Set when the chosen payee is another account's transfer payee; the API
  /// keeps the mirrored transaction on that account in step.
  var transferAccountID: String?
  /// Editable signed allocations for split transactions.
  var subtransactions: [TransactionSubtransactionDraft] = []
  var date = Date.now
  var isCleared = false
  var wasReconciled = false
  /// Cleared state when the editor opened. New captures have none, so Save
  /// always sends the toggle. Edits send it only when this differs.
  var loadedCleared: ClearedState?
  var flag: FlagColour = .none
  var memo = ""

  init() {
    importID = UUID().uuidString.lowercased()
  }

  init(transaction: Transaction) {
    id = transaction.id
    direction = transaction.amount < 0 ? .outflow : .inflow
    amountMagnitudeMilli = abs(transaction.amount)
    payeeID = transaction.payeeID
    payeeName = transaction.payeeName ?? ""
    accountID = transaction.accountID
    categoryID = transaction.categoryID
    // A split owns categorisation and transfer state on its lines. Do not
    // carry an old parent transfer into a split edit where the API would
    // reject the hybrid transaction.
    transferAccountID = transaction.isSplit ? nil : transaction.transferAccountID
    subtransactions = transaction.subtransactions.map { TransactionSubtransactionDraft(subtransaction: $0) }
    date = Date(isoDateString: transaction.date) ?? .now
    isCleared = transaction.cleared != .uncleared
    wasReconciled = transaction.cleared == .reconciled
    loadedCleared = transaction.cleared
    flag = FlagColour(rawValue: transaction.flagColor ?? "") ?? .none
    memo = transaction.memo ?? ""
  }

  /// A fresh draft copying an existing transaction's details, dated today and
  /// uncleared. Split allocations duplicate too, but always get fresh IDs.
  init(duplicating transaction: Transaction) {
    direction = transaction.amount < 0 ? .outflow : .inflow
    amountMagnitudeMilli = abs(transaction.amount)
    payeeID = transaction.payeeID
    payeeName = transaction.payeeName ?? ""
    accountID = transaction.accountID
    categoryID = transaction.categoryID
    transferAccountID = transaction.isSplit ? nil : transaction.transferAccountID
    subtransactions = transaction.subtransactions.map { TransactionSubtransactionDraft(subtransaction: $0, preserveID: false) }
    flag = FlagColour(rawValue: transaction.flagColor ?? "") ?? .none
    memo = transaction.memo ?? ""
    importID = UUID().uuidString.lowercased()
  }

  var isTransfer: Bool {
    transferAccountID != nil
  }

  var isSplit: Bool {
    !subtransactions.isEmpty
  }

  mutating func seedIfNeeded(accounts: [Account], preferredAccountID: String? = nil) {
    guard accountID.isEmpty else {
      return
    }
    if let preferredAccountID, accounts.contains(where: { $0.id == preferredAccountID && !$0.closed }) {
      accountID = preferredAccountID
    } else if let first = accounts.first(where: { !$0.closed }) ?? accounts.first {
      accountID = first.id
    }
  }

  var signedMilliunits: Int {
    if isSplit {
      return subtransactions.reduce(0) { $0 + ($1.amount ?? 0) }
    }
    return direction == .outflow ? -amountMagnitudeMilli : amountMagnitudeMilli
  }

  var splitValidationMessage: String? {
    guard isSplit else { return nil }
    guard subtransactions.count >= 2 else {
      return "A split transaction needs at least two lines."
    }
    guard subtransactions.allSatisfy({ $0.amount != nil }) else {
      return "Enter a signed amount for every split line."
    }
    return nil
  }

  mutating func enableSplit() {
    guard !isSplit else { return }
    subtransactions = [
      TransactionSubtransactionDraft(amountText: MoneyCodec.displayString(for: signedMilliunits, currencyFormat: nil)),
      TransactionSubtransactionDraft(),
    ]
    categoryID = nil
    transferAccountID = nil
  }

  mutating func disableSplit() {
    let total = signedMilliunits
    if total != 0 {
      direction = total < 0 ? .outflow : .inflow
    }
    amountMagnitudeMilli = abs(total)
    subtransactions = []
  }

  var canSave: Bool {
    // Imported zero-value rows may still need a memo, flag, or cleared-state
    // correction. New non-split zero captures remain invalid; zero-net splits
    // are legal YNAB reallocations.
    !accountID.isEmpty && splitValidationMessage == nil && (id != nil || amountMagnitudeMilli > 0 || isSplit)
  }

  /// Editing keeps a reconciled transaction reconciled while the toggle is on.
  var clearedState: ClearedState {
    guard isCleared else {
      return .uncleared
    }
    return wasReconciled ? .reconciled : .cleared
  }

  /// True when Save should send `cleared`. New rows always send it; edits
  /// send it only if the user moved the toggle, so an untouched form cannot
  /// write back a stale status after another client toggled the register.
  var shouldWriteCleared: Bool {
    guard let loadedCleared else {
      return true
    }
    if loadedCleared == .reconciled || wasReconciled {
      return false
    }
    return clearedState != loadedCleared
  }

  func writeRequest(includeCleared: Bool = true) -> TransactionWriteRequest {
    let trimmedPayee = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasParentTransfer = transferAccountID != nil
    return TransactionWriteRequest(
      accountID: accountID,
      date: date.isoDateString,
      amount: signedMilliunits,
      payeeID: isSplit && hasParentTransfer ? nil : payeeID,
      payeeName: isSplit && hasParentTransfer ? nil : (trimmedPayee.isEmpty ? nil : trimmedPayee),
      categoryID: isSplit ? nil : categoryID,
      memo: memo.trimmedNil,
      cleared: includeCleared ? clearedState : nil,
      approved: true,
      flagColor: flag.rawValue.isEmpty ? nil : flag.rawValue,
      subtransactions: subtransactions.compactMap { $0.writeRequest() },
      importID: importID
    )
  }
}

/// Date ranges for Reflect's "Preset" mode, matching YNAB's presets plus the
/// web app's "All" range.
enum ReportPreset: String, CaseIterable, Identifiable {
  case thisMonth
  case lastMonth
  case lastThreeMonths
  case lastSixMonths
  case lastTwelveMonths
  case yearToDate
  case allTime

  var id: String { rawValue }

  var title: String {
    switch self {
    case .thisMonth:
      return "This Month"
    case .lastMonth:
      return "Last Month"
    case .lastThreeMonths:
      return "Last 3 Months"
    case .lastSixMonths:
      return "Last 6 Months"
    case .lastTwelveMonths:
      return "Last 12 Months"
    case .yearToDate:
      return "Year to Date"
    case .allTime:
      return "All Time"
    }
  }

  /// `nil` bounds mean "unbounded": All Time sends no dates at all.
  func range(now: Date = .now, calendar: Calendar = .current) -> (from: Date?, to: Date?) {
    let monthStart = now.startOfMonth(calendar: calendar)
    switch self {
    case .thisMonth:
      return (monthStart, now)
    case .lastMonth:
      let previousStart = calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
      let previousEnd = calendar.date(byAdding: .day, value: -1, to: monthStart) ?? monthStart
      return (previousStart, previousEnd)
    case .lastThreeMonths:
      return (calendar.date(byAdding: .month, value: -2, to: monthStart) ?? monthStart, now)
    case .lastSixMonths:
      return (calendar.date(byAdding: .month, value: -5, to: monthStart) ?? monthStart, now)
    case .lastTwelveMonths:
      return (calendar.date(byAdding: .month, value: -11, to: monthStart) ?? monthStart, now)
    case .yearToDate:
      let components = calendar.dateComponents([.year], from: now)
      return (calendar.date(from: components) ?? now, now)
    case .allTime:
      return (nil, nil)
    }
  }
}

enum ReportInterval: String, CaseIterable, Identifiable {
  case week
  case month
  case year

  var id: String { rawValue }

  var title: String {
    switch self {
    case .week:
      return "By week"
    case .month:
      return "By month"
    case .year:
      return "By year"
    }
  }
}

extension String {
  var trimmedNil: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
