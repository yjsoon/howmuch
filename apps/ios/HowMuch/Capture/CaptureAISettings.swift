import Foundation
import Observation
import Security

enum CaptureAIAPI: String, Codable, CaseIterable, Sendable {
  case chatCompletions
  case responses

  var path: String { self == .responses ? "responses" : "chat/completions" }
  var name: String { self == .responses ? "Responses" : "Chat Completions" }
}

struct CaptureAIModel: Codable, Equatable, Identifiable, Sendable {
  enum Format: String, Codable, Sendable { case jsonSchema, jsonObject }
  enum Reasoning: String, Codable, Sendable { case openAI, openRouter, deepSeek, providerDefault }
  var id: String
  var name: String
  var api: CaptureAIAPI
  var format: Format
  var reasoning: Reasoning
}

struct CaptureAIProvider: Decodable, Identifiable, Sendable {
  var id: String
  var name: String
  var baseURL: String
  var notice: String
  var documentationURL: URL
  var models: [CaptureAIModel]
}

struct CaptureAICatalog: Decodable {
  var providers: [CaptureAIProvider]

  static let bundled = (try? load()) ?? CaptureAICatalog(providers: [])

  static func load(bundle: Bundle = .main) throws -> CaptureAICatalog {
    guard let url = bundle.url(forResource: "AIModels", withExtension: "json") else {
      throw CaptureAIError.configuration
    }
    let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    guard Set(catalog.providers.map(\.id)).count == catalog.providers.count,
          !catalog.providers.isEmpty else { throw CaptureAIError.configuration }
    for provider in catalog.providers {
      _ = try CaptureAISelection.validatedBaseURL(provider.baseURL)
      guard !["on-device", "custom", ""].contains(provider.id),
            !provider.models.isEmpty,
            Set(provider.models.map(\.id)).count == provider.models.count,
            provider.models.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }) else {
        throw CaptureAIError.configuration
      }
    }
    return catalog
  }
}

/// Public preferences only. Secrets are stored separately, scoped to provider + endpoint.
struct CaptureAISelection: Codable, Equatable, Sendable {
  var providerID = "on-device"
  var modelID = ""
  var customBaseURL = ""
  var customAPI: CaptureAIAPI = .chatCompletions

  var isOnDevice: Bool { providerID == "on-device" }

  func resolve(in catalog: CaptureAICatalog) throws -> (URL, CaptureAIModel) {
    if providerID == "custom" {
      guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !modelID.contains(where: \.isNewline) else { throw CaptureAIError.configuration }
      return (try Self.validatedBaseURL(customBaseURL), CaptureAIModel(
        id: modelID, name: modelID, api: customAPI, format: .jsonObject, reasoning: .providerDefault
      ))
    }
    guard let provider = catalog.providers.first(where: { $0.id == providerID }),
          let model = provider.models.first(where: { $0.id == modelID }) else {
      throw CaptureAIError.configuration
    }
    return (try Self.validatedBaseURL(provider.baseURL), model)
  }

  func credentialID(in catalog: CaptureAICatalog) throws -> String {
    let (url, _) = try resolve(in: catalog)
    return "\(providerID)|\(url.absoluteString)"
  }

  static func validatedBaseURL(_ value: String) throws -> URL {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == "https",
          let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
          parts.query == nil, parts.fragment == nil else { throw CaptureAIError.endpoint }
    parts.scheme = "https"
    parts.host = host.lowercased()
    while parts.path.hasSuffix("/") { parts.path.removeLast() }
    guard let url = parts.url else { throw CaptureAIError.endpoint }
    return url
  }
}

struct CaptureAIConfiguration: Sendable {
  let providerID: String
  let providerName: String
  let baseURL: URL
  let model: CaptureAIModel
  let apiKey: String
}

@MainActor
protocol CaptureAIKeyStore {
  func load(_ id: String) throws -> String?
  func save(_ key: String, id: String) throws
}

struct CaptureAIKeychain: CaptureAIKeyStore {
  var service = "\(Bundle.main.bundleIdentifier ?? "sg.soon.howmuch").capture-ai"

  private func identity(_ id: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service, kSecAttrAccount as String: id]
  }

  func load(_ id: String) throws -> String? {
    var query = identity(id)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw CaptureAIError.keychain(status) }
    guard let data = result as? Data,
          let key = String(data: data, encoding: .utf8) else { throw CaptureAIError.keychain(errSecDecode) }
    return key
  }

  func save(_ key: String, id: String) throws {
    let query = identity(id)
    if key.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw CaptureAIError.keychain(status) }
      return
    }
    let values: [String: Any] = [kSecValueData as String: Data(key.utf8)]
    let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      var item = query.merging(values) { _, new in new }
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw CaptureAIError.keychain(added) }
    } else if status != errSecSuccess {
      throw CaptureAIError.keychain(status)
    }
  }
}

@MainActor
@Observable
final class CaptureAISettings {
  static let defaultsKey = "HowMuch.CaptureAI"
  let catalog: CaptureAICatalog
  private(set) var selection: CaptureAISelection
  private var credentialRevision = 0
  private let defaults: UserDefaults
  private let keys: any CaptureAIKeyStore

  init(defaults: UserDefaults = .standard, keys: (any CaptureAIKeyStore)? = nil,
       catalog: CaptureAICatalog = .bundled) {
    self.defaults = defaults
    self.keys = keys ?? CaptureAIKeychain()
    self.catalog = catalog
    selection = defaults.data(forKey: Self.defaultsKey)
      .flatMap { try? JSONDecoder().decode(CaptureAISelection.self, from: $0) } ?? CaptureAISelection()
  }

  var displayName: String {
    if selection.isOnDevice { return "On device" }
    return catalog.providers.first(where: { $0.id == selection.providerID })?.name ?? "Custom provider"
  }

  func hasKey(for selection: CaptureAISelection) -> Bool {
    _ = credentialRevision
    guard let id = try? selection.credentialID(in: catalog), let key = try? keys.load(id) else { return false }
    return !key.isEmpty
  }

  /// nil keeps the existing key; an empty string removes it. Save preferences only after Keychain succeeds.
  func save(_ next: CaptureAISelection, keyChange: String? = nil) throws {
    let data = try JSONEncoder().encode(next)
    if !next.isOnDevice {
      let id = try next.credentialID(in: catalog)
      if let keyChange {
        let trimmed = keyChange.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline) else { throw CaptureAIError.key }
        try keys.save(trimmed, id: id)
      }
    }
    defaults.set(data, forKey: Self.defaultsKey)
    selection = next
    credentialRevision += 1
  }

  func configuration() throws -> CaptureAIConfiguration? {
    _ = credentialRevision
    if selection.isOnDevice { return nil }
    let (url, model) = try selection.resolve(in: catalog)
    let id = try selection.credentialID(in: catalog)
    guard let key = try keys.load(id), !key.isEmpty else { throw CaptureAIError.key }
    return CaptureAIConfiguration(providerID: selection.providerID, providerName: displayName,
                                  baseURL: url, model: model, apiKey: key)
  }

  var status: CaptureIntelligenceStatus {
    if selection.isOnDevice { return .current }
    do {
      _ = try configuration()
      return .available
    } catch {
      return .error(error.localizedDescription)
    }
  }
}

enum CaptureAIError: Error, LocalizedError, Equatable {
  case endpoint, configuration, key, authentication, rateLimit, network
  case keychain(OSStatus)
  case rejected, incomplete, invalidResponse, tooLarge, timedOut

  var errorDescription: String? {
    switch self {
    case .endpoint: return "Enter an HTTPS base URL without credentials, a query, or a fragment."
    case .configuration: return "Choose an available provider and model in AI provider settings."
    case .key: return "Add a valid API key in AI provider settings."
    case .keychain(errSecMissingEntitlement): return "This build cannot store keys securely. Use a Halation build signed for Keychain access."
    case .keychain: return "The API key could not be accessed securely. Unlock this device and try again."
    case .authentication: return "The provider rejected this API key. Check AI provider settings."
    case .rateLimit: return "The provider's usage limit was reached. Check your quota or try again later."
    case .network: return "The AI provider could not be reached. Check your connection and try again."
    case .rejected: return "The provider could not complete this request. Check the model and API settings, or try again."
    case .incomplete: return "The provider stopped before finishing. Try a shorter request. Nothing was saved."
    case .invalidResponse: return "The provider returned an invalid transaction response. Nothing was changed."
    case .tooLarge: return "This request or response is too large. Try fewer transactions or a shorter attachment."
    case .timedOut: return "This reply took too long. Nothing was saved. Retry or add manually."
    }
  }
}
