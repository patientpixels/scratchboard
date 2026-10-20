import XCTest
@testable import Scratchboard

// swiftlint:disable type_body_length file_length
final class OpenAICompatibleProviderTests: XCTestCase {
  private let baseURL = URL(string: "https://api.example.com/v1")!

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
  }

  override func tearDown() {
    StubURLProtocol.reset()
    super.tearDown()
  }

  // MARK: - Request

  func testEndpointJoining() {
    let cases = [
      "https://api.openai.com/v1": "https://api.openai.com/v1/chat/completions",
      "http://localhost:11434/v1": "http://localhost:11434/v1/chat/completions",
      "https://openrouter.ai/api/v1": "https://openrouter.ai/api/v1/chat/completions",
      "https://api.anthropic.com/v1/": "https://api.anthropic.com/v1/chat/completions",
      "https://api.anthropic.com/v1//": "https://api.anthropic.com/v1/chat/completions"
    ]
    for (base, expected) in cases {
      let provider = OpenAICompatibleProvider(baseURL: URL(string: base)!, model: "m", apiKey: nil)
      XCTAssertEqual(provider.endpoint.absoluteString, expected)
    }
  }

  func testRequestShape() async throws {
    StubURLProtocol.enqueue(chunks: [sse(text("ok")), done])
    let provider = makeProvider(baseURL: URL(string: "https://api.anthropic.com/v1/")!, apiKey: "sk-test")
    let tool = makeTool("write_artefact")

    _ = try await collect(provider.run(
      instructions: "Be brief.",
      messages: [LLMMessage(role: .user, content: "Hi"), LLMMessage(role: .assistant, content: "Hello")],
      tools: [tool]
    ))

    let request = try XCTUnwrap(StubURLProtocol.requests.first)
    XCTAssertEqual(request.url, "https://api.anthropic.com/v1/chat/completions")
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.headers["Authorization"], "Bearer sk-test")
    XCTAssertEqual(request.headers["Content-Type"], "application/json")
    XCTAssertEqual(request.body["model"], .string("gpt-test"))
    XCTAssertEqual(request.body["stream"], .bool(true))
    XCTAssertEqual(request.body["messages"], .array([
      message("system", "Be brief."),
      message("user", "Hi"),
      message("assistant", "Hello")
    ]))
    XCTAssertEqual(request.body["tools"], .array([
      .object([
        "type": .string("function"),
        "function": .object([
          "name": .string("write_artefact"),
          "description": .string("Does write_artefact"),
          "parameters": tool.parameters
        ])
      ])
    ]))
  }

  func testRequestOmitsEmptyToolsAndAuthorization() async throws {
    StubURLProtocol.enqueue(chunks: [sse(text("ok")), done])
    StubURLProtocol.enqueue(chunks: [sse(text("ok")), done])

    _ = try await collect(makeProvider(apiKey: nil).run(instructions: "", messages: [user("Hi")], tools: []))
    _ = try await collect(makeProvider(apiKey: "").run(instructions: "", messages: [user("Hi")], tools: []))

    XCTAssertEqual(StubURLProtocol.requests.count, 2)
    for request in StubURLProtocol.requests {
      XCTAssertNil(request.headers["Authorization"])
      XCTAssertNil(request.body["tools"])
      XCTAssertEqual(request.body["messages"], .array([message("user", "Hi")]))
    }
  }

  // MARK: - Streaming

  func testStreamsText() async throws {
    StubURLProtocol.enqueue(chunks: [
      ": OPENROUTER PROCESSING\n\n",
      sse(#"{"choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#),
      sse(text("Hel")),
      "event: message\n" + sse(text("lo")),
      sse(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
      done,
      sse(text("ignored"))
    ])

    let events = try await collect(makeProvider().run(instructions: "", messages: [user("Hi")], tools: []))

    XCTAssertEqual(events, [.textDelta("Hel"), .textDelta("lo")])
    XCTAssertEqual(StubURLProtocol.requests.count, 1)
  }

  func testStreamWithoutDoneStillCompletes() async throws {
    StubURLProtocol.enqueue(chunks: [sse(text("Hi"))])

    let events = try await collect(makeProvider().run(instructions: "", messages: [user("Hi")], tools: []))

    XCTAssertEqual(events, [.textDelta("Hi")])
  }

  func testToolCallWithArgumentsSplitAcrossChunks() async throws {
    let stream = [
      sse(toolDelta(index: 0, id: "call_1", name: "write_artefact", arguments: "")),
      sse(toolDelta(index: 0, arguments: "{\"te")),
      sse(toolDelta(index: 0, arguments: "xt\": \"HE")),
      sse(toolDelta(index: 0, arguments: "LLO\"}")),
      sse(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
      done
    ].joined()
    // Split the raw bytes at arbitrary points, including mid-line.
    let parts = stride(from: 0, to: stream.count, by: 37).map { offset in
      String(stream.dropFirst(offset).prefix(37))
    }
    StubURLProtocol.enqueue(chunks: parts)
    StubURLProtocol.enqueue(chunks: [sse(text("Done.")), done])
    let tool = makeTool("write_artefact")

    let events = try await collect(makeProvider().run(instructions: "", messages: [user("Shout")], tools: [tool]))

    let arguments = JSONValue.object(["text": .string("HELLO")])
    XCTAssertEqual(events, [
      .toolCall(name: "write_artefact", arguments: arguments),
      .toolResult(name: "write_artefact", result: "write_artefact ok"),
      .textDelta("Done.")
    ])
    XCTAssertEqual(StubURLProtocol.requests.count, 2)
    XCTAssertEqual(StubURLProtocol.requests[1].body["messages"], .array([
      message("user", "Shout"),
      .object([
        "role": .string("assistant"),
        "content": .null,
        "tool_calls": .array([toolCallMessage(id: "call_1", name: "write_artefact", arguments: "{\"text\": \"HELLO\"}")])
      ]),
      toolResultMessage(id: "call_1", content: "write_artefact ok")
    ]))
  }

  func testTwoToolCallsInOneRound() async throws {
    StubURLProtocol.enqueue(chunks: [
      sse(text("Let me do both.")),
      sse(toolDelta(index: 0, id: "a", name: "first", arguments: "{\"n\":")),
      sse(toolDelta(index: 1, id: "b", name: "second", arguments: "{}")),
      sse(toolDelta(index: 0, arguments: "1}")),
      done
    ])
    StubURLProtocol.enqueue(chunks: [sse(text("Both done.")), done])

    let events = try await collect(makeProvider().run(
      instructions: "",
      messages: [user("Go")],
      tools: [makeTool("first"), makeTool("second")]
    ))

    XCTAssertEqual(events, [
      .textDelta("Let me do both."),
      .toolCall(name: "first", arguments: .object(["n": .number(1)])),
      .toolResult(name: "first", result: "first ok"),
      .toolCall(name: "second", arguments: .object([:])),
      .toolResult(name: "second", result: "second ok"),
      .textDelta("Both done.")
    ])
    XCTAssertEqual(StubURLProtocol.requests[1].body["messages"], .array([
      message("user", "Go"),
      .object([
        "role": .string("assistant"),
        "content": .string("Let me do both."),
        "tool_calls": .array([
          toolCallMessage(id: "a", name: "first", arguments: "{\"n\":1}"),
          toolCallMessage(id: "b", name: "second", arguments: "{}")
        ])
      ]),
      toolResultMessage(id: "a", content: "first ok"),
      toolResultMessage(id: "b", content: "second ok")
    ]))
  }

  func testMultiRoundLoopEndsInText() async throws {
    StubURLProtocol.enqueue(chunks: [sse(toolDelta(index: 0, id: "c1", name: "step", arguments: "{}")), done])
    StubURLProtocol.enqueue(chunks: [sse(toolDelta(index: 0, id: "c2", name: "step", arguments: "{}")), done])
    StubURLProtocol.enqueue(chunks: [sse(text("Finished.")), done])

    let events = try await collect(makeProvider().run(
      instructions: "System",
      messages: [user("Go")],
      tools: [makeTool("step")]
    ))

    XCTAssertEqual(events, [
      .toolCall(name: "step", arguments: .object([:])),
      .toolResult(name: "step", result: "step ok"),
      .toolCall(name: "step", arguments: .object([:])),
      .toolResult(name: "step", result: "step ok"),
      .textDelta("Finished.")
    ])
    let messageCounts = StubURLProtocol.requests.map { request -> Int in
      guard case .array(let messages) = request.body["messages"] else { return -1 }
      return messages.count
    }
    XCTAssertEqual(messageCounts, [2, 4, 6])
  }

  func testMissingToolCallIDGetsGenerated() async throws {
    StubURLProtocol.enqueue(chunks: [sse(toolDelta(index: 0, name: "step", arguments: "{}")), done])
    StubURLProtocol.enqueue(chunks: [sse(text("ok")), done])

    _ = try await collect(makeProvider().run(instructions: "", messages: [user("Go")], tools: [makeTool("step")]))

    guard case .array(let messages) = StubURLProtocol.requests[1].body["messages"] else {
      return XCTFail("Missing messages")
    }
    let callID = messages[1]["tool_calls"].flatMap { value -> JSONValue? in
      guard case .array(let calls) = value else { return nil }
      return calls.first?["id"]
    }
    XCTAssertNotNil(callID?.stringValue)
    XCTAssertEqual(callID, messages[2]["tool_call_id"])
  }

  // MARK: - Tool errors

  func testInvalidToolArgumentsAreReportedToModel() async throws {
    StubURLProtocol.enqueue(chunks: [sse(toolDelta(index: 0, id: "c1", name: "step", arguments: "{not json")), done])
    StubURLProtocol.enqueue(chunks: [sse(text("Sorry.")), done])
    let counter = Counter()
    let tool = makeTool("step", counter: counter)

    let events = try await collect(makeProvider().run(instructions: "", messages: [user("Go")], tools: [tool]))

    XCTAssertEqual(events, [.textDelta("Sorry.")])
    XCTAssertEqual(counter.value, 0)
    let result = try XCTUnwrap(lastMessage(of: StubURLProtocol.requests[1]))
    XCTAssertEqual(result["role"], .string("tool"))
    XCTAssertEqual(result["tool_call_id"], .string("c1"))
    XCTAssertTrue(result["content"]?.stringValue?.hasPrefix("Error:") == true)
  }

  func testUnknownToolIsReportedToModel() async throws {
    StubURLProtocol.enqueue(chunks: [sse(toolDelta(index: 0, id: "c1", name: "nope", arguments: "{}")), done])
    StubURLProtocol.enqueue(chunks: [sse(text("Oops.")), done])

    let events = try await collect(makeProvider().run(
      instructions: "",
      messages: [user("Go")],
      tools: [makeTool("step")]
    ))

    XCTAssertEqual(events, [.textDelta("Oops.")])
    let result = try XCTUnwrap(lastMessage(of: StubURLProtocol.requests[1]))
    XCTAssertTrue(result["content"]?.stringValue?.contains("nope") == true)
  }

  func testThrowingToolIsReportedToModel() async throws {
    StubURLProtocol.enqueue(chunks: [sse(toolDelta(index: 0, id: "c1", name: "fail", arguments: "{}")), done])
    StubURLProtocol.enqueue(chunks: [sse(text("Hm.")), done])
    let tool = LLMTool(name: "fail", description: "", parameters: .object([:])) { _ in
      throw LLMError.unavailable("No such version")
    }

    let events = try await collect(makeProvider().run(instructions: "", messages: [user("Go")], tools: [tool]))

    XCTAssertEqual(events, [
      .toolCall(name: "fail", arguments: .object([:])),
      .toolResult(name: "fail", result: "Error: No such version"),
      .textDelta("Hm.")
    ])
    XCTAssertEqual(lastMessage(of: StubURLProtocol.requests[1])?["content"], .string("Error: No such version"))
  }

  func testTooManyToolIterations() async throws {
    for round in 0..<maxToolIterations + 1 {
      StubURLProtocol.enqueue(chunks: [sse(toolDelta(index: 0, id: "c\(round)", name: "step", arguments: "{}")), done])
    }
    let counter = Counter()

    await assertThrows(LLMError.tooManyToolIterations) {
      _ = try await self.collect(self.makeProvider().run(
        instructions: "",
        messages: [self.user("Go")],
        tools: [self.makeTool("step", counter: counter)]
      ))
    }
    XCTAssertEqual(StubURLProtocol.requests.count, maxToolIterations)
    XCTAssertEqual(counter.value, maxToolIterations)
  }

  // MARK: - Errors

  func testHTTPError() async throws {
    let body = #"{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}"#
    StubURLProtocol.enqueue(status: 401, chunks: [body])

    await assertThrows(LLMError.http(status: 401, body: body)) {
      _ = try await self.collect(self.makeProvider().run(instructions: "", messages: [self.user("Hi")], tools: []))
    }
  }

  func testContextLengthErrors() async throws {
    let bodies = [
      #"{"error":{"message":"This model's maximum context length is 128000 tokens.","code":"context_length_exceeded"}}"#,
      #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 210000 tokens"}}"#
    ]
    for body in bodies {
      StubURLProtocol.enqueue(status: 400, chunks: [body])
      await assertThrows(LLMError.contextTooLong) {
        _ = try await self.collect(self.makeProvider().run(instructions: "", messages: [self.user("Hi")], tools: []))
      }
    }
  }

  func testContextLengthErrorInsideStream() async throws {
    StubURLProtocol.enqueue(chunks: [sse(#"{"error":{"message":"x","code":"context_length_exceeded"}}"#)])

    await assertThrows(LLMError.contextTooLong) {
      _ = try await self.collect(self.makeProvider().run(instructions: "", messages: [self.user("Hi")], tools: []))
    }
  }

  func testMalformedStream() async throws {
    StubURLProtocol.enqueue(chunks: [sse(text("Hi")), "data: {not json\n\n"])

    var events: [LLMEvent] = []
    do {
      for try await event in makeProvider().run(instructions: "", messages: [user("Hi")], tools: []) {
        events.append(event)
      }
      XCTFail("Expected an error")
    } catch let error as LLMError {
      guard case .invalidResponse = error else { return XCTFail("Unexpected error \(error)") }
    }
    XCTAssertEqual(events, [.textDelta("Hi")])
  }

  func testNonStreamingBodyIsInvalidResponse() async throws {
    StubURLProtocol.enqueue(chunks: [#"{"id":"x","choices":[]}"#])

    do {
      _ = try await collect(makeProvider().run(instructions: "", messages: [user("Hi")], tools: []))
      XCTFail("Expected an error")
    } catch let error as LLMError {
      guard case .invalidResponse = error else { return XCTFail("Unexpected error \(error)") }
    }
  }

  // MARK: - Cancellation

  func testCancellingConsumerCancelsRequest() async throws {
    let stopped = expectation(description: "request stopped")
    StubURLProtocol.onStop = { stopped.fulfill() }
    StubURLProtocol.enqueue(chunks: [sse(text("Hel"))], hang: true)
    let received = expectation(description: "first delta")
    let stream = makeProvider().run(instructions: "", messages: [user("Hi")], tools: [])

    let task = Task {
      for try await _ in stream {
        received.fulfill()
      }
    }
    await fulfillment(of: [received], timeout: 5)
    task.cancel()
    await fulfillment(of: [stopped], timeout: 5)
  }

  // MARK: - Helpers

  private func makeProvider(baseURL: URL? = nil, apiKey: String? = "key") -> OpenAICompatibleProvider {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return OpenAICompatibleProvider(
      baseURL: baseURL ?? self.baseURL,
      model: "gpt-test",
      apiKey: apiKey,
      session: URLSession(configuration: configuration)
    )
  }

  private func makeTool(_ name: String, counter: Counter? = nil) -> LLMTool {
    LLMTool(
      name: name,
      description: "Does \(name)",
      parameters: .object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])])
      ])
    ) { _ in
      counter?.increment()
      return "\(name) ok"
    }
  }

  private func collect(_ stream: AsyncThrowingStream<LLMEvent, Error>) async throws -> [LLMEvent] {
    var events: [LLMEvent] = []
    for try await event in stream {
      events.append(event)
    }
    return events
  }

  private func assertThrows(
    _ expected: LLMError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? LLMError, expected, file: file, line: line)
    }
  }

  private func lastMessage(of request: StubURLProtocol.Recorded) -> JSONValue? {
    guard case .array(let messages) = request.body["messages"] else { return nil }
    return messages.last
  }

  private func user(_ content: String) -> LLMMessage {
    LLMMessage(role: .user, content: content)
  }

  private func message(_ role: String, _ content: String) -> JSONValue {
    .object(["role": .string(role), "content": .string(content)])
  }

  private func toolCallMessage(id: String, name: String, arguments: String) -> JSONValue {
    .object([
      "id": .string(id),
      "type": .string("function"),
      "function": .object(["name": .string(name), "arguments": .string(arguments)])
    ])
  }

  private func toolResultMessage(id: String, content: String) -> JSONValue {
    .object(["role": .string("tool"), "tool_call_id": .string(id), "content": .string(content)])
  }

  private let done = "data: [DONE]\n\n"

  private func sse(_ json: String) -> String {
    "data: \(json)\n\n"
  }

  private func text(_ content: String) -> String {
    chunk(delta: .object(["content": .string(content)]))
  }

  private func toolDelta(index: Int, id: String? = nil, name: String? = nil, arguments: String) -> String {
    var function: [String: JSONValue] = ["arguments": .string(arguments)]
    if let name { function["name"] = .string(name) }
    var call: [String: JSONValue] = ["index": .number(Double(index)), "function": .object(function)]
    if let id {
      call["id"] = .string(id)
      call["type"] = .string("function")
    }
    return chunk(delta: .object(["tool_calls": .array([.object(call)])]))
  }

  private func chunk(delta: JSONValue) -> String {
    let value = JSONValue.object([
      "id": .string("chatcmpl-1"),
      "object": .string("chat.completion.chunk"),
      "choices": .array([.object(["index": .number(0), "delta": delta])])
    ])
    // swiftlint:disable:next force_try
    return try! value.jsonString()
  }
}
// swiftlint:enable type_body_length file_length

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }

  func increment() {
    lock.withLock { count += 1 }
  }
}

// Serves queued canned responses, one per request, and records the requests.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Reply {
    var status: Int
    var chunks: [String]
    var hang: Bool
  }

  struct Recorded {
    let url: String?
    let method: String?
    let headers: [String: String]
    let body: JSONValue
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var replies: [Reply] = []
  nonisolated(unsafe) private static var recorded: [Recorded] = []
  nonisolated(unsafe) private static var stopHandler: (@Sendable () -> Void)?

  static var requests: [Recorded] { lock.withLock { recorded } }

  static var onStop: (@Sendable () -> Void)? {
    get { lock.withLock { stopHandler } }
    set { lock.withLock { stopHandler = newValue } }
  }

  static func enqueue(status: Int = 200, chunks: [String], hang: Bool = false) {
    lock.withLock { replies.append(Reply(status: status, chunks: chunks, hang: hang)) }
  }

  static func reset() {
    lock.withLock {
      replies = []
      recorded = []
      stopHandler = nil
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let body = Self.readBody(of: request)
    let reply: Reply? = Self.lock.withLock {
      Self.recorded.append(Recorded(
        url: request.url?.absoluteString,
        method: request.httpMethod,
        headers: request.allHTTPHeaderFields ?? [:],
        body: (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .null
      ))
      return Self.replies.isEmpty ? nil : Self.replies.removeFirst()
    }
    guard let reply, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }

    let response = HTTPURLResponse(
      url: url,
      statusCode: reply.status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": reply.status == 200 ? "text/event-stream" : "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in reply.chunks {
      client?.urlProtocol(self, didLoad: Data(chunk.utf8))
    }
    if !reply.hang {
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {
    Self.onStop?()
  }

  private static func readBody(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
