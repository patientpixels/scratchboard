import Foundation

// A plain conversational message. Earlier turns' tool calls are flattened into
// text by ChatSession, so providers never need to replay provider-specific
// tool-call history.
nonisolated struct LLMMessage: Equatable, Sendable {
  enum Role: String, Sendable {
    case user
    case assistant
  }

  let role: Role
  let content: String
}

// A tool the model may call. Providers execute tools themselves while running
// the agent loop and feed the result back to the model.
nonisolated struct LLMTool: Sendable {
  let name: String
  let description: String
  // JSON Schema of the arguments object, e.g.
  // .object(["type": .string("object"), "properties": ..., "required": ...])
  let parameters: JSONValue
  // Receives the decoded arguments object, returns the tool result text.
  let execute: @Sendable (JSONValue) async throws -> String
}

nonisolated enum LLMEvent: Equatable, Sendable {
  // Incremental assistant chat text.
  case textDelta(String)
  // Emitted before the tool is executed.
  case toolCall(name: String, arguments: JSONValue)
  // Emitted after the tool was executed.
  case toolResult(name: String, result: String)
}

nonisolated enum LLMError: LocalizedError, Equatable {
  case unavailable(String)
  case http(status: Int, body: String)
  case invalidResponse(String)
  case contextTooLong
  case tooManyToolIterations

  var errorDescription: String? {
    switch self {
    case .unavailable(let reason): return reason
    case .http(let status, let body): return "HTTP \(status): \(body)"
    case .invalidResponse(let reason): return "Invalid response: \(reason)"
    case .contextTooLong: return "The text is too long for this model."
    case .tooManyToolIterations: return "The model kept calling tools without finishing."
    }
  }
}

nonisolated protocol LLMProvider: Sendable {
  // Shown in the prompt placeholder, e.g. "qwen3:8b" or "gpt-6-luna".
  var displayName: String { get }

  // Runs one agent turn: sends instructions + messages with tools, streams
  // text, executes tool calls and loops until the model answers without
  // calling a tool (at most `maxToolIterations` rounds). Cancelling the
  // consuming task must cancel the request.
  func run(
    instructions: String,
    messages: [LLMMessage],
    tools: [LLMTool]
  ) -> AsyncThrowingStream<LLMEvent, Error>
}

nonisolated let maxToolIterations = 8
