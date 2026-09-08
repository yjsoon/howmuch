import Foundation

enum CaptureAIPhase: String, Sendable {
  case waiting = "Waiting for response"
  case receiving = "Receiving response"
  case checking = "Checking response"
  case fetching = "Fetching recorded transactions"
}

struct CaptureAIActivity: Equatable {
  var provider: String
  var startedAt: Date
  var phase: CaptureAIPhase = .waiting
}

/// Per-request ephemeral transport: no cookies, cache, redirects, service tokens, or automatic retries.
struct CaptureAIClient: Sendable {
  private let session: URLSession
  static let maximumBytes = 1_048_576

  init(configuration: URLSessionConfiguration = .ephemeral) {
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 45
    configuration.timeoutIntervalForResource = 120
    session = URLSession(configuration: configuration, delegate: CaptureAINoRedirect(), delegateQueue: nil)
  }

  func extract(
    configuration: CaptureAIConfiguration,
    context: CaptureTurnContext,
    accounts: [Account],
    categories: [CategoryGroup],
    conversationID: UUID,
    progress: @escaping @Sendable (CaptureAIPhase) async -> Void
  ) async throws -> CaptureTurnPayload {
    defer { session.invalidateAndCancel() }
    do {
      let request = try Self.request(configuration: configuration, context: context,
                                     accounts: accounts, categories: categories, conversationID: conversationID)
      try Task.checkCancellation()
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else { throw CaptureAIError.network }
      switch http.statusCode {
      case 200: break
      case 401, 403: throw CaptureAIError.authentication
      case 402, 429: throw CaptureAIError.rateLimit
      case 500...599: throw CaptureAIError.network
      default: throw CaptureAIError.rejected
      }
      var parser = CaptureAIStream(api: configuration.model.api)
      var buffer = Data()
      var count = 0
      var didReceiveText = false
      let isSSE = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
      for try await byte in bytes {
        try Task.checkCancellation()
        count += 1
        guard count <= Self.maximumBytes else { throw CaptureAIError.tooLarge }
        if isSSE, byte == 10 {
          guard let line = String(data: buffer, encoding: .utf8) else { throw CaptureAIError.invalidResponse }
          buffer.removeAll(keepingCapacity: true)
          try parser.consume(line: line.hasSuffix("\r") ? String(line.dropLast()) : line)
          if !didReceiveText, !parser.text.isEmpty {
            didReceiveText = true
            await progress(.receiving)
          }
          if parser.isComplete { break }
        } else {
          buffer.append(byte)
        }
      }
      try Task.checkCancellation()
      await progress(.checking)
      let text: String
      if isSSE {
        // Only a protocol-level successful terminal event authorizes decoding, never a parseable prefix.
        guard parser.isComplete else { throw CaptureAIError.incomplete }
        text = parser.text
      } else {
        text = try CaptureAIStream.nonStreaming(buffer, api: configuration.model.api)
      }
      return try CaptureTurnPayload.decodeRemote(Data(text.utf8))
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as CaptureAIError {
      throw error
    } catch let error as URLError {
      if error.code == .cancelled { throw CancellationError() }
      throw error.code == .timedOut ? CaptureAIError.timedOut : CaptureAIError.network
    } catch {
      // Provider bodies / decoding errors can contain financial data or echo credentials.
      throw CaptureAIError.invalidResponse
    }
  }

  static func request(
    configuration: CaptureAIConfiguration,
    context: CaptureTurnContext,
    accounts: [Account],
    categories: [CategoryGroup],
    conversationID: UUID
  ) throws -> URLRequest {
    let base = try CaptureAISelection.validatedBaseURL(configuration.baseURL.absoluteString)
    guard !configuration.apiKey.isEmpty,
          !configuration.apiKey.contains(where: \.isNewline) else { throw CaptureAIError.key }
    let prompt = CaptureInterpreterPrompt.prefix(context: context, accounts: accounts, categoryGroups: categories)
      + context.text
    guard prompt.utf8.count <= 65_536 else { throw CaptureAIError.tooLarge }
    let schema = CaptureTurnPayload.remoteSchema
    let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
    let instructions = CaptureInterpreterPrompt.instructions
      .replacingOccurrences(of: "on-device capture helper", with: "capture helper")
      + "\nReturn exactly one JSON object matching this schema. All fields are required. Use empty strings/arrays for unused fields. Do not include markdown, tools, or additional keys.\n"
      + "Use yyyy-MM-dd for every nonempty date field, including spend dates.\n"
      + schemaText
    let model = configuration.model
    var body: [String: Any] = ["model": model.id, "stream": true]
    let format: [String: Any] = model.format == .jsonSchema
      ? ["type": "json_schema", "name": "capture_turn", "strict": true, "schema": schema]
      : ["type": "json_object"]
    if model.api == .responses {
      body["instructions"] = instructions
      body["input"] = prompt
      body["text"] = ["format": format]
      body["max_output_tokens"] = 4096
      body["store"] = false
    } else {
      body["messages"] = [["role": "system", "content": instructions], ["role": "user", "content": prompt]]
      body["max_tokens"] = 4096
      body["response_format"] = model.format == .jsonSchema
        ? ["type": "json_schema", "json_schema": ["name": "capture_turn", "strict": true, "schema": schema]]
        : ["type": "json_object"]
    }
    switch model.reasoning {
    case .openAI:
      if model.api == .responses { body["reasoning"] = ["effort": "none"] }
      else { body["reasoning_effort"] = "none" }
    case .openRouter: body["reasoning"] = ["enabled": false]
    case .deepSeek: body["thinking"] = ["type": "disabled"]
    case .providerDefault: break
    }
    if configuration.providerID == "openrouter" {
      body["provider"] = ["require_parameters": true, "data_collection": "deny"]
    }
    var request = URLRequest(url: base.appendingPathComponent(model.api.path))
    request.httpMethod = "POST"
    request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("HowMuch/1.0", forHTTPHeaderField: "User-Agent")
    if configuration.providerID == "opencode-go" {
      request.setValue(conversationID.uuidString, forHTTPHeaderField: "x-opencode-session")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }
}

final class CaptureAINoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

/// SSE framing is separate from transport so terminal/error/truncation behavior is fixture-testable.
struct CaptureAIStream {
  let api: CaptureAIAPI
  private(set) var text = ""
  private(set) var isComplete = false
  private var dataLines: [String] = []
  private var stopped = false

  init(api: CaptureAIAPI) {
    self.api = api
  }

  mutating func consume(line: String) throws {
    guard !isComplete else { return }
    if line.hasPrefix("data:") {
      var data = String(line.dropFirst(5))
      if data.hasPrefix(" ") { data.removeFirst() }
      dataLines.append(data)
    } else if line.isEmpty, !dataLines.isEmpty {
      let data = dataLines.joined(separator: "\n")
      dataLines.removeAll(keepingCapacity: true)
      if data == "[DONE]" {
        guard api == .chatCompletions, stopped else { throw CaptureAIError.incomplete }
        isComplete = true
        return
      }
      guard let value = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
        throw CaptureAIError.invalidResponse
      }
      if let error = value["error"], !(error is NSNull) { throw CaptureAIError.rejected }
      if api == .responses {
        switch value["type"] as? String {
        case "response.output_text.delta":
          guard let delta = value["delta"] as? String else { throw CaptureAIError.invalidResponse }
          text += delta
        case "response.completed":
          guard let response = value["response"] as? [String: Any] else { throw CaptureAIError.invalidResponse }
          text = try Self.responseText(response)
          isComplete = true
        case "response.failed", "response.incomplete", "error", "response.refusal.delta", "response.refusal.done":
          throw CaptureAIError.incomplete
        default: break // lifecycle, usage, and reasoning events aren't financial results
        }
      } else {
        guard let choices = value["choices"] as? [[String: Any]], choices.count <= 1 else {
          throw CaptureAIError.invalidResponse
        }
        guard let choice = choices.first else { return } // optional usage-only event
        guard (choice["index"] as? Int) == 0 else { throw CaptureAIError.invalidResponse }
        if let delta = choice["delta"] as? [String: Any] {
          try Self.rejectActionsOrRefusal(delta)
          if let content = delta["content"] as? String, !content.isEmpty {
            guard !stopped else { throw CaptureAIError.invalidResponse }
            text += content
          }
        }
        if let reason = choice["finish_reason"] as? String {
          guard reason == "stop" else { throw CaptureAIError.incomplete }
          stopped = true
        }
      }
    }
  }

  static func nonStreaming(_ data: Data, api: CaptureAIAPI) throws -> String {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CaptureAIError.invalidResponse
    }
    if let error = value["error"], !(error is NSNull) { throw CaptureAIError.rejected }
    if api == .responses { return try responseText(value) }
    guard let choices = value["choices"] as? [[String: Any]], choices.count == 1,
          choices[0]["finish_reason"] as? String == "stop",
          let message = choices[0]["message"] as? [String: Any],
          message["role"] as? String == "assistant",
          let content = message["content"] as? String else { throw CaptureAIError.incomplete }
    try rejectActionsOrRefusal(message)
    return content
  }

  private static func rejectActionsOrRefusal(_ message: [String: Any]) throws {
    for key in ["refusal", "tool_calls", "function_call"] {
      if let value = message[key], !(value is NSNull) { throw CaptureAIError.rejected }
    }
  }

  private static func responseText(_ response: [String: Any]) throws -> String {
    guard response["status"] as? String == "completed",
          response["error"] == nil || response["error"] is NSNull,
          let output = response["output"] as? [[String: Any]] else { throw CaptureAIError.incomplete }
    let messages = output.filter { $0["type"] as? String == "message" }
    guard messages.count == 1,
          output.allSatisfy({ ["message", "reasoning"].contains($0["type"] as? String ?? "") }),
          messages[0]["role"] as? String == "assistant",
          let content = messages[0]["content"] as? [[String: Any]], content.count == 1,
          content[0]["type"] as? String == "output_text",
          let text = content[0]["text"] as? String else { throw CaptureAIError.invalidResponse }
    return text
  }
}

extension CaptureTurnPayload {
  private static var spendProperties: [String: Any] {
    var result: [String: Any] = [:]
    for name in ["targetDraftID", "amount", "payee", "category", "account", "date", "direction"] {
      result[name] = ["type": "string"]
    }
    result["isInflow"] = ["type": "boolean"]
    return result
  }

  static var remoteSchema: [String: Any] {
    var properties: [String: Any] = [:]
    for name in ["feedback", "queryKind", "queryCategory", "queryAccount", "queryMerchant", "queryFrom", "queryTo"] {
      properties[name] = ["type": "string"]
    }
    properties["kind"] = ["type": "string", "enum": ["add", "update", "query", "unsupported"]]
    properties["applyToAllDrafts"] = ["type": "boolean"]
    properties["spends"] = ["type": "array", "items": [
      "type": "object", "properties": spendProperties,
      "required": spendProperties.keys.sorted(), "additionalProperties": false,
    ]]
    return ["type": "object", "properties": properties,
            "required": properties.keys.sorted(), "additionalProperties": false]
  }

  static func decodeRemote(_ data: Data) throws -> CaptureTurnPayload {
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == Set((remoteSchema["properties"] as? [String: Any] ?? [:]).keys),
            let spends = object["spends"] as? [[String: Any]], spends.count <= 50,
            spends.allSatisfy({ Set($0.keys) == Set(spendProperties.keys) }) else {
        throw CaptureAIError.invalidResponse
      }
      let payload = try JSONDecoder().decode(Self.self, from: data)
      guard ["add", "update", "query", "unsupported"].contains(payload.kind),
            (payload.kind == "add" || payload.kind == "update") || payload.spends.isEmpty,
            payload.kind != "query" || ["spending", "today", "spendingThisMonth", "compareCategory", "findMerchant"].contains(payload.queryKind),
            payload.spends.allSatisfy({
              ["", "inflow", "outflow"].contains($0.direction)
                && ($0.amount.isEmpty || MoneyCodec.milliunits(from: $0.amount) != nil)
                && ($0.date.isEmpty || LedgerQueryPlanner.parseISO($0.date, calendar: .current) != nil)
            }) else { throw CaptureAIError.invalidResponse }
      return payload
    } catch {
      throw CaptureAIError.invalidResponse
    }
  }
}
