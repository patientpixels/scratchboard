import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Scratchboard

final class AppleProviderTests: XCTestCase {
  private let writeArtefactSchema = JSONValue.object([
    "type": .string("object"),
    "properties": .object([
      "text": .object(["type": .string("string"), "description": .string("The full new artefact text")])
    ]),
    "required": .array([.string("text")])
  ])

  // MARK: Prompt trimming

  func testEstimatedTokensRoundsUp() {
    XCTAssertEqual(ApplePrompt.estimatedTokens(""), 0)
    XCTAssertEqual(ApplePrompt.estimatedTokens("a"), 1)
    XCTAssertEqual(ApplePrompt.estimatedTokens("abcd"), 2)
    XCTAssertEqual(ApplePrompt.estimatedTokens("abcde"), 3)
  }

  func testBudgetLeavesHalfForResponse() {
    let instructions = String(repeating: "a", count: 184)
    // (4096 - (92 + 8)) / 2
    XCTAssertEqual(ApplePrompt.budget(contextSize: 4096, instructions: instructions, tools: []), 1998)

    let tool = LLMTool(name: "write_artefact", description: "Writes", parameters: writeArtefactSchema) { _ in "" }
    XCTAssertLessThan(
      ApplePrompt.budget(contextSize: 4096, instructions: instructions, tools: [tool]),
      1998
    )
    XCTAssertEqual(ApplePrompt.budget(contextSize: 10, instructions: instructions, tools: []), 0)
  }

  func testFitKeepsEverythingThatFits() throws {
    let messages = [
      LLMMessage(role: .user, content: "one"),
      LLMMessage(role: .assistant, content: "two"),
      LLMMessage(role: .user, content: "three")
    ]
    let (history, prompt) = try ApplePrompt.fit(messages, budget: 1000)
    XCTAssertEqual(history, Array(messages.prefix(2)))
    XCTAssertEqual(prompt, messages[2])
  }

  func testFitDropsOldestMessagesFirst() throws {
    let long = String(repeating: "x", count: 100) // 50 tokens + 8
    let messages = [
      LLMMessage(role: .user, content: "old " + long),
      LLMMessage(role: .assistant, content: "older reply " + long),
      LLMMessage(role: .user, content: "recent " + long),
      LLMMessage(role: .assistant, content: "recent reply " + long),
      LLMMessage(role: .user, content: "now " + long)
    ]
    // The last message plus two earlier ones fit.
    let (history, prompt) = try ApplePrompt.fit(messages, budget: 3 * 66)
    XCTAssertEqual(history, Array(messages[2...3]))
    XCTAssertEqual(prompt, messages[4])
  }

  func testFitDoesNotStartHistoryWithAssistantMessage() throws {
    let long = String(repeating: "x", count: 100)
    let messages = [
      LLMMessage(role: .user, content: long),
      LLMMessage(role: .assistant, content: long),
      LLMMessage(role: .user, content: long)
    ]
    let (history, _) = try ApplePrompt.fit(messages, budget: 2 * 58 + 10)
    XCTAssertEqual(history, [])
  }

  func testFitKeepsLastMessageWholeOrThrows() throws {
    let artefact = String(repeating: "x", count: 1000) // 500 tokens + 8
    let messages = [LLMMessage(role: .user, content: "hi"), LLMMessage(role: .user, content: artefact)]

    let (history, prompt) = try ApplePrompt.fit(messages, budget: 508)
    XCTAssertEqual(history, [])
    XCTAssertEqual(prompt.content, artefact)

    XCTAssertThrowsError(try ApplePrompt.fit(messages, budget: 507)) { error in
      XCTAssertEqual(error as? LLMError, .contextTooLong)
    }
  }

  func testFitWithoutMessages() throws {
    let (history, prompt) = try ApplePrompt.fit([], budget: 10)
    XCTAssertEqual(history, [])
    XCTAssertEqual(prompt.content, "")
  }

  func testFitKeepsAtMostFourEarlierMessages() throws {
    let messages = (1...7).map { LLMMessage(role: $0 % 2 == 1 ? .user : .assistant, content: "m\($0)") }
    let (history, prompt) = try ApplePrompt.fit(messages, budget: 1000)
    XCTAssertEqual(history.map(\.content), ["m3", "m4", "m5", "m6"])
    XCTAssertEqual(prompt.content, "m7")
  }

  func testInstructionsIncludeHistory() {
    XCTAssertEqual(ApplePrompt.instructions("Be brief.", history: []), "Be brief.")
    XCTAssertEqual(
      ApplePrompt.instructions(
        "Be brief.",
        history: [LLMMessage(role: .user, content: "thanks"), LLMMessage(role: .assistant, content: "Welcome.")]
      ),
      "Be brief.\n\n<earlier_conversation>\n[user] thanks\n\n[assistant] Welcome.\n</earlier_conversation>"
    )
  }

  // MARK: Streaming

  func testStreamDeltaFromCumulativeSnapshots() {
    var delta = AppleStreamDelta()
    XCTAssertEqual(delta.delta(for: ""), "")
    XCTAssertEqual(delta.delta(for: "Hello"), "Hello")
    XCTAssertEqual(delta.delta(for: "Hello"), "")
    XCTAssertEqual(delta.delta(for: "Hello, world"), ", world")
    XCTAssertEqual(delta.delta(for: ""), "")
    // A new response after a tool call.
    XCTAssertEqual(delta.delta(for: "Done"), "\n\nDone")
    XCTAssertEqual(delta.delta(for: "Done."), ".")
    XCTAssertEqual(delta.text, "Done.")
  }

  // MARK: FoundationModels

  #if canImport(FoundationModels)
  func testSchemaConversion() throws {
    guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26") }
    let parameters = JSONValue.object([
      "type": .string("object"),
      "properties": .object([
        "text": .object(["type": .string("string"), "description": .string("New text")]),
        "version": .object(["type": .string("integer")]),
        "mode": .object(["type": .string("string"), "enum": .array([.string("a"), .string("b")])]),
        "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
        "force": .object(["type": .string("boolean")])
      ]),
      "required": .array([.string("version"), .string("text")])
    ])
    let schema = try AppleSchema.generationSchema(name: "edit", parameters: parameters)
    let json = try JSONValue.parse(String(decoding: try JSONEncoder().encode(schema), as: UTF8.self))

    XCTAssertEqual(json["type"], .string("object"))
    XCTAssertEqual(json["title"], .string("edit"))
    XCTAssertEqual(json["required"], .array([.string("version"), .string("text")]))
    XCTAssertEqual(
      json["x-order"],
      .array(["version", "text", "force", "mode", "tags"].map(JSONValue.string))
    )
    XCTAssertEqual(json["properties"]?["text"]?["type"], .string("string"))
    XCTAssertEqual(json["properties"]?["text"]?["description"], .string("New text"))
    XCTAssertEqual(json["properties"]?["version"]?["type"], .string("integer"))
    XCTAssertEqual(json["properties"]?["force"]?["type"], .string("boolean"))
    XCTAssertEqual(json["properties"]?["tags"]?["type"], .string("array"))
    XCTAssertTrue(try json.jsonString().contains("\"a\""), "enum choices are kept")
  }

  func testUnsupportedSchemaThrows() throws {
    guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26") }
    XCTAssertThrowsError(try AppleSchema.generationSchema(name: "x", parameters: .object(["type": .string("null")])))
  }

  func testGeneratedContentToJSONValue() throws {
    guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26") }
    let content = try GeneratedContent(json: #"{"text": "HI", "n": 2, "ok": true, "list": [1, null]}"#)
    let json = JSONValue(content)
    XCTAssertEqual(json, .object([
      "text": .string("HI"),
      "n": .number(2),
      "ok": .bool(true),
      "list": .array([.number(1), .null])
    ]))
    XCTAssertEqual(json["n"]?.intValue, 2)
  }

  func testToolEmitsEventsAndReturnsResult() async throws {
    guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26") }
    let events = EventRecorder()
    let tool = LLMTool(name: "write_artefact", description: "Writes", parameters: writeArtefactSchema) { arguments in
      "wrote \(arguments["text"]?.stringValue ?? "")"
    }
    let appleTool = try AppleTool(tool, counter: AppleToolCallCounter()) { events.append($0) }

    let result = try await appleTool.call(arguments: GeneratedContent(json: #"{"text": "HI"}"#))

    XCTAssertEqual(result, "wrote HI")
    XCTAssertEqual(events.all, [
      .toolCall(name: "write_artefact", arguments: .object(["text": .string("HI")])),
      .toolResult(name: "write_artefact", result: "wrote HI")
    ])
  }

  func testToolCallLimit() async throws {
    guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26") }
    let tool = LLMTool(name: "write_artefact", description: "Writes", parameters: writeArtefactSchema) { _ in "ok" }
    let appleTool = try AppleTool(tool, counter: AppleToolCallCounter()) { _ in }
    let arguments = try GeneratedContent(json: #"{"text": "HI"}"#)
    for _ in 0..<maxToolIterations {
      _ = try await appleTool.call(arguments: arguments)
    }
    do {
      _ = try await appleTool.call(arguments: arguments)
      XCTFail("Expected tooManyToolIterations")
    } catch {
      XCTAssertEqual(error as? LLMError, .tooManyToolIterations)
    }
  }

  func testErrorMapping() throws {
    guard #available(macOS 26, *) else { throw XCTSkip("Requires macOS 26") }
    let context = LanguageModelSession.GenerationError.Context(debugDescription: "")
    func map(_ error: Error) -> LLMError? { AppleProvider.mapError(error) as? LLMError }

    XCTAssertEqual(map(LanguageModelSession.GenerationError.exceededContextWindowSize(context)), .contextTooLong)
    guard case .invalidResponse? = map(LanguageModelSession.GenerationError.guardrailViolation(context)) else {
      return XCTFail("guardrail should map to invalidResponse")
    }
    guard case .unavailable? = map(LanguageModelSession.GenerationError.assetsUnavailable(context)) else {
      return XCTFail("assetsUnavailable should map to unavailable")
    }

    let tool = try AppleTool(
      LLMTool(name: "t", description: "", parameters: writeArtefactSchema) { _ in "" },
      counter: AppleToolCallCounter()
    ) { _ in }
    let toolError = LanguageModelSession.ToolCallError(tool: tool, underlyingError: LLMError.tooManyToolIterations)
    XCTAssertEqual(map(toolError), .tooManyToolIterations)
    XCTAssertTrue(AppleProvider.mapError(CancellationError()) is CancellationError)
    guard case .invalidResponse? = map(NSError(domain: "com.apple.tokengeneration", code: 10)) else {
      return XCTFail("unknown errors should map to invalidResponse")
    }
  }
  #endif

  // MARK: Live

  func testLiveToolCallUppercasesArtefact() async throws {
    if let reason = AppleProvider.unavailableReason {
      throw XCTSkip("Apple Intelligence unavailable: \(reason)")
    }
    let written = EventRecorder()
    let tool = LLMTool(
      name: "write_artefact",
      description: "Replace the artefact with new text, creating a new version.",
      parameters: writeArtefactSchema
    ) { _ in
      "Saved as v2."
    }
    let instructions = """
      You edit a text artefact for the user. To change it, call write_artefact with the complete new text. \
      Never put artefact text in chat. After the tool call, reply with one short sentence.
      """
    let messages = [
      LLMMessage(role: .user, content: "Current artefact (v1):\ngood morning\n\nRequest: thanks"),
      LLMMessage(role: .assistant, content: "You're welcome."),
      LLMMessage(role: .user, content: "Current artefact (v1):\nhello world\n\nRequest: make it upper case")
    ]

    var text = ""
    for try await event in AppleProvider().run(instructions: instructions, messages: messages, tools: [tool]) {
      written.append(event)
      if case .textDelta(let delta) = event { text += delta }
    }

    let calls = written.all.compactMap { event -> String? in
      guard case .toolCall("write_artefact", let arguments) = event else { return nil }
      return arguments["text"]?.stringValue
    }
    print("Live Apple provider events: \(written.all)")
    XCTAssertEqual(calls.first?.trimmingCharacters(in: .whitespacesAndNewlines), "HELLO WORLD")
    XCTAssertTrue(written.all.contains(.toolResult(name: "write_artefact", result: "Saved as v2.")))
    XCTAssertFalse(text.isEmpty)
  }
}

private final class EventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [LLMEvent] = []

  var all: [LLMEvent] { lock.withLock { events } }

  func append(_ event: LLMEvent) {
    lock.withLock { events.append(event) }
  }
}
