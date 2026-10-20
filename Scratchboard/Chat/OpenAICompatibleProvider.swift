import Foundation

// Streams /chat/completions from any OpenAI-compatible endpoint (OpenAI,
// OpenRouter, Ollama, LM Studio, Anthropic's compatibility endpoint) and runs
// the tool-calling loop.
nonisolated struct OpenAICompatibleProvider: LLMProvider {
  let baseURL: URL
  let model: String
  let apiKey: String?
  var session: URLSession = .shared

  var displayName: String { model }

  var endpoint: URL {
    var string = baseURL.absoluteString
    while string.hasSuffix("/") { string.removeLast() }
    return URL(string: string + "/chat/completions") ?? baseURL.appendingPathComponent("chat/completions")
  }

  func run(
    instructions: String,
    messages: [LLMMessage],
    tools: [LLMTool]
  ) -> AsyncThrowingStream<LLMEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await runLoop(instructions: instructions, messages: messages, tools: tools, continuation: continuation)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func runLoop(
    instructions: String,
    messages: [LLMMessage],
    tools: [LLMTool],
    continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
  ) async throws {
    var history: [JSONValue] = []
    if !instructions.isEmpty {
      history.append(.object(["role": .string("system"), "content": .string(instructions)]))
    }
    history += messages.map { .object(["role": .string($0.role.rawValue), "content": .string($0.content)]) }

    let toolSpecs: [JSONValue] = tools.map { tool in
      .object([
        "type": .string("function"),
        "function": .object([
          "name": .string(tool.name),
          "description": .string(tool.description),
          "parameters": tool.parameters
        ])
      ])
    }

    for round in 0..<maxToolIterations {
      let reply = try await streamRound(history: history, tools: toolSpecs, continuation: continuation)
      let calls = reply.toolCalls
      if calls.isEmpty { return }

      let ids = calls.indices.map { calls[$0].id ?? "call_\(round)_\($0)" }
      history.append(.object([
        "role": .string("assistant"),
        "content": reply.text.isEmpty ? .null : .string(reply.text),
        "tool_calls": .array(zip(ids, calls).map { id, call in
          .object([
            "id": .string(id),
            "type": .string("function"),
            "function": .object(["name": .string(call.name), "arguments": .string(call.arguments)])
          ])
        })
      ]))

      for (id, call) in zip(ids, calls) {
        let result = try await execute(call, tools: tools, continuation: continuation)
        history.append(.object(["role": .string("tool"), "tool_call_id": .string(id), "content": .string(result)]))
      }
    }
    throw LLMError.tooManyToolIterations
  }

  private func streamRound(
    history: [JSONValue],
    tools: [JSONValue],
    continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
  ) async throws -> OpenAIStreamAccumulator {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    if let apiKey, !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    var body: [String: JSONValue] = ["model": .string(model), "messages": .array(history), "stream": .bool(true)]
    if !tools.isEmpty { body["tools"] = .array(tools) }
    request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw LLMError.invalidResponse("Not an HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      var data = Data()
      for try await byte in bytes {
        data.append(byte)
        if data.count >= 64_000 { break }
      }
      let text = String(decoding: data, as: UTF8.self)
      if OpenAIStreamAccumulator.isContextLengthError(text) { throw LLMError.contextTooLong }
      throw LLMError.http(status: http.statusCode, body: text)
    }

    var accumulator = OpenAIStreamAccumulator()
    for try await line in bytes.lines {
      if let delta = try accumulator.consume(line) {
        continuation.yield(.textDelta(delta))
      }
      if accumulator.isDone { break }
    }
    try Task.checkCancellation()
    try accumulator.finish()
    return accumulator
  }

  // Runs one tool call. Problems the model can fix (unknown tool, bad
  // arguments, tool errors) go back to it as the result instead of failing.
  private func execute(
    _ call: OpenAIStreamAccumulator.ToolCall,
    tools: [LLMTool],
    continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
  ) async throws -> String {
    guard let tool = tools.first(where: { $0.name == call.name }) else {
      return "Error: there is no tool named \"\(call.name)\"."
    }

    let raw = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsed: JSONValue? = raw.isEmpty ? .object([:]) : try? JSONValue.parse(raw)
    guard let arguments = parsed, case .object = arguments else {
      return "Error: the arguments for \(tool.name) are not a valid JSON object. Call it again with valid arguments."
    }

    continuation.yield(.toolCall(name: tool.name, arguments: arguments))
    let result: String
    do {
      result = try await tool.execute(arguments)
    } catch let error as CancellationError {
      throw error
    } catch {
      result = "Error: \(error.localizedDescription)"
    }
    try Task.checkCancellation()
    continuation.yield(.toolResult(name: tool.name, result: result))
    return result
  }
}
