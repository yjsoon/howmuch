import Security
import XCTest
@testable import HowMuch

@MainActor
final class CaptureAITests: XCTestCase {
  func testBundledCatalogHasRequestedProvidersModelsAndProtocols() throws {
    let catalog = try CaptureAICatalog.load()
    XCTAssertEqual(Set(catalog.providers.map(\.id)), ["opencode-go", "openrouter", "openai", "deepseek"])
    let expected: [String: [String]] = [
      "opencode-go": ["gpt-5.6-luna", "deepseek-v4-flash-vision-exp"],
      "openrouter": ["openai/gpt-5.6-luna", "deepseek/deepseek-v4-flash-vision-exp"],
      "openai": ["gpt-5.6-luna"], "deepseek": ["deepseek-v4-flash-vision-exp"],
    ]
    for provider in catalog.providers {
      XCTAssertEqual(provider.models.map(\.id), expected[provider.id])
      for model in provider.models {
        var selection = CaptureAISelection(providerID: provider.id, modelID: model.id)
        let resolved = try selection.resolve(in: catalog)
        XCTAssertEqual(resolved.0.absoluteString, provider.baseURL)
        XCTAssertEqual(resolved.1, model)
        selection.modelID = "retired-model"
        XCTAssertThrowsError(try selection.resolve(in: catalog), "Never silently substitute another model")
      }
    }
  }

  func testRequestUsesEachCatalogProtocolAndOnlyTheProviderKey() throws {
    let id = UUID()
    for provider in CaptureAICatalog.bundled.providers {
      for model in provider.models {
        let config = CaptureAIConfiguration(providerID: provider.id, providerName: provider.name,
          baseURL: URL(string: provider.baseURL)!, model: model, apiKey: "fixture-ai-key")
        let request = try CaptureAIClient.request(configuration: config, context: Self.context,
          accounts: [], categories: [], conversationID: id)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(request.url?.absoluteString, provider.baseURL + "/" + model.api.path)
        XCTAssertEqual(body["model"] as? String, model.id)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-ai-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "HowMuch/1.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-session"), provider.id == "opencode-go" ? id.uuidString : nil)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["previous_response_id"])
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("fixture-ai-key"))
        if model.api == .responses {
          XCTAssertEqual(body["store"] as? Bool, false)
          XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
          let text = try XCTUnwrap(body["text"] as? [String: Any])
          XCTAssertEqual((text["format"] as? [String: Any])?["type"] as? String, "json_schema")
        } else {
          let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
          XCTAssertTrue(messages[0]["content"]?.contains("JSON object") == true)
          XCTAssertTrue(messages[1]["content"]?.contains("Lunch $12") == true)
          if provider.id == "openrouter" {
            XCTAssertEqual((body["provider"] as? [String: Any])?["data_collection"] as? String, "deny")
            XCTAssertEqual((body["provider"] as? [String: Any])?["require_parameters"] as? Bool, true)
            XCTAssertEqual((body["reasoning"] as? [String: Bool])?["enabled"], false)
          } else {
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
            XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
          }
        }
      }
    }
  }

  func testSettingsRequireConsentKeepKeysOutOfPreferencesAndScopeKeysToEndpoint() throws {
    let suite = "howmuch.byok.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let keys = CaptureAIMemoryKeys()
    let settings = CaptureAISettings(defaults: defaults, keys: keys)
    XCTAssertNil(try settings.configuration())
    var selection = CaptureAISelection(providerID: "opencode-go", modelID: "gpt-5.6-luna")
    try settings.save(selection, keyChange: "first-fixture-key")
    XCTAssertThrowsError(try settings.configuration()) { XCTAssertEqual($0 as? CaptureAIError, .consent) }
    selection.allowsRemote = true
    try settings.save(selection)
    XCTAssertEqual(try settings.configuration()?.apiKey, "first-fixture-key")
    XCTAssertFalse(String(decoding: defaults.data(forKey: CaptureAISettings.defaultsKey)!, as: UTF8.self).contains("fixture-key"))
    try settings.save(selection, keyChange: "replacement-fixture-key")
    XCTAssertEqual(try settings.configuration()?.apiKey, "replacement-fixture-key")
    let reloaded = CaptureAISettings(defaults: defaults, keys: keys)
    XCTAssertEqual(try reloaded.configuration()?.model.id, "gpt-5.6-luna")
    XCTAssertEqual(try reloaded.configuration()?.apiKey, "replacement-fixture-key")
    try settings.save(selection, keyChange: "")
    XCTAssertThrowsError(try settings.configuration()) { XCTAssertEqual($0 as? CaptureAIError, .key) }
    XCTAssertFalse(settings.hasKey(for: selection))

    let custom = CaptureAISelection(providerID: "custom", modelID: "model", customBaseURL: "https://one.example/v1/", allowsRemote: true)
    try settings.save(custom, keyChange: "custom-fixture-key")
    var changed = custom
    changed.customBaseURL = "https://two.example/v1"
    try settings.save(changed)
    XCTAssertThrowsError(try settings.configuration()) { XCTAssertEqual($0 as? CaptureAIError, .key) }
    XCTAssertTrue(settings.hasKey(for: custom))
    keys.failWrites = true
    XCTAssertThrowsError(try settings.save(custom, keyChange: "should-not-save"))
    XCTAssertEqual(settings.selection, changed)
    XCTAssertEqual(CaptureAISettings(defaults: defaults, keys: keys).selection, changed)
  }

  func testKeychainCanReplaceAndDeleteOnlyItsOwnCredential() throws {
    let keys = CaptureAIKeychain(service: "howmuch.byok.test.\(UUID().uuidString)")
    defer { try? keys.save("", id: "one"); try? keys.save("", id: "two") }
    try keys.save("synthetic-one", id: "one")
    try keys.save("synthetic-two", id: "two")
    try keys.save("synthetic-replacement", id: "one")
    XCTAssertEqual(try keys.load("one"), "synthetic-replacement")
    try keys.save("", id: "one")
    XCTAssertNil(try keys.load("one"))
    XCTAssertEqual(try keys.load("two"), "synthetic-two")
  }

  func testEndpointAndPayloadValidationFailClosed() throws {
    for endpoint in ["http://example.com/v1", "https://user:password@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/#fragment", "not-a-url"] {
      XCTAssertThrowsError(try CaptureAISelection.validatedBaseURL(endpoint))
    }
    XCTAssertEqual(try CaptureAISelection.validatedBaseURL(" https://EXAMPLE.com/v1/ ").absoluteString, "https://example.com/v1")
    let payload = Self.payload
    XCTAssertEqual(try CaptureTurnPayload.decodeRemote(JSONEncoder().encode(payload)), payload)
    XCTAssertThrowsError(try CaptureTurnPayload.decodeRemote(Data("{}".utf8)))
    var mixed = payload
    mixed.kind = "query"
    mixed.queryKind = "today"
    XCTAssertThrowsError(try CaptureTurnPayload.decodeRemote(JSONEncoder().encode(mixed)))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
    object["commit"] = true
    XCTAssertThrowsError(try CaptureTurnPayload.decodeRemote(JSONSerialization.data(withJSONObject: object)))
    var invalid = payload
    invalid.spends[0].amount = "not an amount"
    XCTAssertThrowsError(try CaptureTurnPayload.decodeRemote(JSONEncoder().encode(invalid)))
  }

  func testMalformedRemoteDatesCannotFallBackToToday() throws {
    for date in ["not a date", "2026-02-30", "2026-13-01"] {
      var payload = Self.payload
      payload.spends[0].date = date
      XCTAssertThrowsError(try CaptureTurnPayload.decodeRemote(JSONEncoder().encode(payload)),
        "A supplied invalid date must not become a saveable draft with today's date")
    }
    for date in ["", "2026-09-08", "2028-02-29"] {
      var payload = Self.payload
      payload.spends[0].date = date
      XCTAssertEqual(try CaptureTurnPayload.decodeRemote(JSONEncoder().encode(payload)), payload)
    }
  }

  func testMalformedRemoteAmountsAreRejected() throws {
    for amount in ["1 2", "1 .25", "1\t2", "1\n2", "12\n", " 12", "12 ", "1.-2",
      "--1", "-+1", "1,234", "$12", "12 dollars", "1e3", "1.2345", "+", "-", ".",
      "9223372036854776"] {
      var payload = Self.payload
      payload.spends[0].amount = amount
      XCTAssertThrowsError(try CaptureTurnPayload.decodeRemote(JSONEncoder().encode(payload)),
        "Malformed amount \(amount.debugDescription) must not become a saveable draft")
    }
    var partial = Self.payload
    partial.spends[0].amount = ""
    XCTAssertEqual(try CaptureTurnPayload.decodeRemote(JSONEncoder().encode(partial)), partial)
  }

  func testRemoteDecimalAmountsPreserveMagnitudeThroughMapping() async throws {
    let cases: [(String, Int)] = [
      ("0", 0), ("12", 12_000), ("12.34", 12_340), ("12.345", 12_345),
      ("+12.345", 12_345), ("-12.345", 12_345), (".125", 125), ("-.125", 125),
      ("0012.300", 12_300), ("9007199254740.991", 9_007_199_254_740_991),
    ]
    for (amount, expected) in cases {
      var payload = Self.payload
      payload.spends[0].amount = amount
      let text = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
      let event = Self.json(["type": "response.completed", "response": Self.responseObject(text)])
      CaptureAIStub.configure(body: "data: \(event)\r\n\r\n")
      let result = await CaptureInterpreter(backend: .remote(Self.configuration(.responses)), remoteClient: Self.client()).interpret(
        context: Self.context, accounts: [], categoryGroups: [], payees: [])
      let value = try result.get()
      XCTAssertEqual(value.1.count, 1)
      XCTAssertEqual(value.1.first?.mapped.draft.amountMagnitudeMilli, expected, amount)
    }
  }

  func testStreamRequiresSuccessfulTerminalAndRejectsTruncationRefusalOrToolCalls() throws {
    let text = String(decoding: try JSONEncoder().encode(Self.payload), as: UTF8.self)
    var parser = CaptureAIStream(api: .chatCompletions)
    try Self.feed(Self.chatDelta(text), into: &parser)
    XCTAssertFalse(parser.isComplete, "Valid JSON isn't a completed generation")
    var premature = parser
    XCTAssertThrowsError(try Self.feed("[DONE]", into: &premature))
    for reason in ["length", "content_filter", "tool_calls", "insufficient_system_resource"] {
      var truncated = parser
      XCTAssertThrowsError(try Self.feed(Self.chatFinish(reason), into: &truncated))
    }
    for delta in [["refusal": "No"], ["tool_calls": "unexpected"]] {
      var rejected = parser
      let value: [String: Any] = ["choices": [["index": 0, "delta": delta]]]
      XCTAssertThrowsError(try Self.feed(Self.json(value), into: &rejected))
    }
    try Self.feed(Self.chatFinish("stop"), into: &parser)
    XCTAssertFalse(parser.isComplete)
    try Self.feed("[DONE]", into: &parser)
    XCTAssertTrue(parser.isComplete)
    XCTAssertEqual(try CaptureTurnPayload.decodeRemote(Data(parser.text.utf8)), Self.payload)

    var responses = CaptureAIStream(api: .responses)
    try Self.feed(Self.json(["type": "response.output_text.delta", "delta": text]), into: &responses)
    XCTAssertFalse(responses.isComplete)
    var incomplete = responses
    XCTAssertThrowsError(try Self.feed(Self.json(["type": "response.incomplete"]), into: &incomplete))
    try Self.feed(Self.json(["type": "response.completed", "response": Self.responseObject(text)]), into: &responses)
    XCTAssertTrue(responses.isComplete)
    XCTAssertEqual(responses.text, text)

    XCTAssertEqual(try CaptureAIStream.nonStreaming(
      JSONSerialization.data(withJSONObject: Self.responseObject(text)), api: .responses), text)
    let chat: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": text]]]]
    XCTAssertEqual(try CaptureAIStream.nonStreaming(JSONSerialization.data(withJSONObject: chat), api: .chatCompletions), text)
    XCTAssertThrowsError(try CaptureAIStream.nonStreaming(Data("{}".utf8), api: .responses))
    XCTAssertThrowsError(try CaptureAIStream.nonStreaming(Data("{}".utf8), api: .chatCompletions))
  }

  func testRemoteTransportStreamsBothProtocolsThroughExistingMappingWithoutSaving() async throws {
    let outboxBefore = OutboxStore.load()
    for api in CaptureAIAPI.allCases {
      let text = String(decoding: try JSONEncoder().encode(Self.payload), as: UTF8.self)
      let events = api == .responses
        ? [Self.json(["type": "response.output_text.delta", "delta": text]), Self.json(["type": "response.completed", "response": Self.responseObject(text)])]
        : [Self.chatDelta(text), Self.chatFinish("stop"), "[DONE]"]
      CaptureAIStub.configure(body: events.map { "data: \($0)\r\n\r\n" }.joined())
      let client = Self.client()
      let recorder = CaptureAIPhaseRecorder()
      let result = await CaptureInterpreter(backend: .remote(Self.configuration(api)), remoteClient: client).interpret(
        context: Self.context, accounts: [], categoryGroups: [], payees: [],
        progress: { await recorder.append($0) }
      )
      let value = try result.get()
      XCTAssertEqual(value.0.intent, .add)
      XCTAssertEqual(value.1.count, 1)
      XCTAssertEqual(value.1.first?.mapped.draft.payeeName, "Lunch")
      XCTAssertEqual(value.1.first?.mapped.draft.amountMagnitudeMilli, 12_000)
      let phases = await recorder.values
      XCTAssertTrue(phases.contains(.receiving))
      XCTAssertTrue(phases.contains(.checking))
    }
    XCTAssertEqual(OutboxStore.load().map(\.id), outboxBefore.map(\.id))
  }

  func testHTTPFailuresDoNotExposeProviderBodiesAndCancellationStopsTransport() async throws {
    for (code, expected) in [(401, CaptureAIError.authentication), (429, .rateLimit), (500, .network), (302, .rejected)] {
      CaptureAIStub.configure(status: code, body: "sensitive provider echo fixture-api-key")
      do {
        _ = try await Self.client().extract(configuration: Self.configuration(.responses), context: Self.context,
          accounts: [], categories: [], conversationID: UUID(), progress: { _ in })
        XCTFail("HTTP \(code) must not succeed")
      } catch {
        XCTAssertEqual(error as? CaptureAIError, expected)
        XCTAssertFalse(error.localizedDescription.contains("sensitive"))
        XCTAssertFalse(error.localizedDescription.contains("fixture-api-key"))
      }
    }
    CaptureAIStub.configure(body: "", hang: true)
    let task = Task {
      try await Self.client().extract(configuration: Self.configuration(.responses), context: Self.context,
        accounts: [], categories: [], conversationID: UUID(), progress: { _ in })
    }
    for _ in 0..<100 where !CaptureAIStub.started { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(CaptureAIStub.started)
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled transport must not complete") }
    catch { XCTAssertTrue(error is CancellationError) }
    for _ in 0..<100 where !CaptureAIStub.stopped { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(CaptureAIStub.stopped)
  }

  func testRedirectDelegateNeverForwardsCredentials() async {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = URL(string: "https://byok.invalid/v1/responses")!
    let task = session.dataTask(with: url) // never resumed
    let delegate = CaptureAINoRedirect()
    let finished = expectation(description: "redirect denied")
    delegate.urlSession(session, task: task,
      willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!,
      newRequest: URLRequest(url: URL(string: "https://other.invalid")!)) { request in
        XCTAssertNil(request)
        finished.fulfill()
      }
    await fulfillment(of: [finished], timeout: 1)
  }

  func testDeadlinePreservesFrozenInputAndBlocksLateProgress() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = CaptureWorkspace(store: CaptureWorkspaceStore(rootURL: directory))
    let session = CaptureSession(scopeKey: "byok-fixture", origin: .lastUsedOpen, selectedAccountID: nil)
    workspace.current = session
    session.composerText = "Lunch $12"
    let frozen = session.freezeComposerTurn(accountName: "Everyday", localDate: "2026-09-08")
    let token = session.beginTurn(provider: "Fixture provider")
    let gate = CaptureAITestGate()
    workspace.runConversationTurn(timeout: .milliseconds(30)) {
      await gate.wait()
      session.updateAIPhase(.receiving, generation: token.generation)
      _ = session.finishTurn(generation: token.generation)
    }
    for _ in 0..<100 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(session.isBusy)
    XCTAssertNil(session.aiActivity)
    XCTAssertEqual(session.messages.last?.replyState, .failed)
    XCTAssertEqual(session.messages.last?.frozenTurn, frozen)
    XCTAssertTrue(session.canRetry(session.messages.last!))
    let retry = session.prepareRetry(replyID: frozen.replyMessageID)
    XCTAssertEqual(retry, frozen)
    let next = session.beginTurn(provider: "New provider")
    await gate.release()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(session.matchesTurn(generation: next.generation))
    XCTAssertEqual(session.aiActivity?.provider, "New provider")
    XCTAssertEqual(session.aiActivity?.phase, .waiting)
    XCTAssertTrue(session.drafts.isEmpty)
    workspace.cancelOwnedConversationWork()
    session.cancelTurn()
  }

  static var context: CaptureTurnContext {
    CaptureTurnContext(text: "Lunch $12", selectedAccountName: "Everyday", selectedAccountID: "everyday",
      today: "2026-09-08", drafts: [], priorInstructions: [], priorAnswers: [], attachmentTranscripts: [])
  }

  static var payload: CaptureTurnPayload {
    CaptureTurnPayload(kind: "add", feedback: "Lunch is ready for review. It isn't saved yet.",
      spends: [CaptureTurnSpend(amount: "12", payee: "Lunch")])
  }

  static func configuration(_ api: CaptureAIAPI) -> CaptureAIConfiguration {
    CaptureAIConfiguration(providerID: "custom", providerName: "Fixture", baseURL: URL(string: "https://byok.invalid/v1")!,
      model: CaptureAIModel(id: "fixture-model", name: "Fixture model", api: api, format: .jsonObject, reasoning: .providerDefault),
      apiKey: "fixture-api-key")
  }

  static func client() -> CaptureAIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CaptureAIStub.self]
    return CaptureAIClient(configuration: config)
  }

  static func json(_ value: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
  }

  static func chatDelta(_ text: String) -> String {
    json(["choices": [["index": 0, "delta": ["content": text]]]])
  }

  static func chatFinish(_ reason: String) -> String {
    json(["choices": [["index": 0, "delta": [:], "finish_reason": reason]]])
  }

  static func responseObject(_ text: String) -> [String: Any] {
    ["status": "completed", "output": [["type": "message", "role": "assistant",
      "content": [["type": "output_text", "text": text]]]]]
  }

  static func feed(_ data: String, into parser: inout CaptureAIStream) throws {
    try parser.consume(line: "data: " + data)
    try parser.consume(line: "")
  }
}

@MainActor
final class CaptureAIMemoryKeys: CaptureAIKeyStore {
  var values: [String: String] = [:]
  var failWrites = false
  func load(_ id: String) throws -> String? { values[id] }
  func save(_ key: String, id: String) throws {
    if failWrites { throw CaptureAIError.keychain(errSecNotAvailable) }
    values[id] = key.isEmpty ? nil : key
  }
}

private actor CaptureAIPhaseRecorder {
  var values: [CaptureAIPhase] = []
  func append(_ phase: CaptureAIPhase) { values.append(phase) }
}

private actor CaptureAITestGate {
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async { await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(); continuation = nil }
}

private final class CaptureAIStub: URLProtocol {
  private static let lock = NSLock()
  private static var response = (status: 200, body: "", hang: false)
  private static var didStart = false
  private static var didStop = false
  static var started: Bool { lock.withLock { didStart } }
  static var stopped: Bool { lock.withLock { didStop } }
  static func configure(status: Int = 200, body: String, hang: Bool = false) {
    lock.withLock { response = (status, body, hang); didStart = false; didStop = false }
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = Self.lock.withLock { Self.didStart = true; return Self.response }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status,
      httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
    if response.hang { return }
    // Split UTF-8 and SSE framing across arbitrary network chunks.
    for byte in Data(response.body.utf8) { client?.urlProtocol(self, didLoad: Data([byte])) }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() { Self.lock.withLock { Self.didStop = true } }
}
