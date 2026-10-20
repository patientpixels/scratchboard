import Foundation

// Collects one streamed /chat/completions response from its server-sent event
// lines: assistant text plus tool calls whose fragments arrive across chunks.
nonisolated struct OpenAIStreamAccumulator {
  struct ToolCall: Equatable {
    var id: String?
    var name = ""
    var arguments = ""
  }

  private(set) var text = ""
  // Thinking, which isn't shown. Ollama sometimes files a Qwen model's whole
  // answer here (when the model doesn't close its thinking after a tool call).
  private(set) var reasoning = ""
  private(set) var isDone = false
  private var calls: [Int: ToolCall] = [:]
  private var sawData = false
  private var unparsed = ""

  var toolCalls: [ToolCall] {
    calls.sorted { $0.key < $1.key }.map(\.value)
  }

  // Returns the text delta carried by `line`, if any.
  mutating func consume(_ line: String) throws -> String? {
    guard line.hasPrefix("data:") else {
      collectUnparsed(line)
      return nil
    }

    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    sawData = true
    if payload == "[DONE]" {
      isDone = true
      return nil
    }

    let chunk: Chunk
    do {
      chunk = try Self.decoder.decode(Chunk.self, from: Data(payload.utf8))
    } catch {
      throw LLMError.invalidResponse("Malformed stream chunk: \(payload.prefix(200))")
    }

    if let error = chunk.error {
      let description = error["message"]?.stringValue ?? (try? error.jsonString()) ?? "Unknown error"
      if Self.isContextLengthError((try? error.jsonString()) ?? description) {
        throw LLMError.contextTooLong
      }
      throw LLMError.invalidResponse(description)
    }

    guard let delta = chunk.choices?.first?.delta else { return nil }
    for (position, fragment) in (delta.toolCalls ?? []).enumerated() {
      let index = fragment.index ?? position
      var call = calls[index] ?? ToolCall()
      if let id = fragment.id, !id.isEmpty { call.id = id }
      if let name = fragment.function?.name, !name.isEmpty { call.name = name }
      call.arguments += fragment.function?.arguments ?? ""
      calls[index] = call
    }

    reasoning += delta.reasoning ?? delta.reasoningContent ?? ""
    guard let content = delta.content, !content.isEmpty else { return nil }
    text += content
    return content
  }

  // Call once the byte stream ended.
  func finish() throws {
    guard sawData else {
      if Self.isContextLengthError(unparsed) { throw LLMError.contextTooLong }
      throw LLMError.invalidResponse(unparsed.isEmpty ? "Empty response" : unparsed)
    }
  }

  static func isContextLengthError(_ text: String) -> Bool {
    let text = text.lowercased()
    return [
      "context_length_exceeded",
      "context length",
      "context window",
      "maximum context",
      "prompt is too long"
    ].contains { text.contains($0) }
  }

  private mutating func collectUnparsed(_ line: String) {
    let isSSEField = line.isEmpty || line.hasPrefix(":") || line.hasPrefix("event:")
      || line.hasPrefix("id:") || line.hasPrefix("retry:")
    guard !isSSEField, unparsed.count < 2_000 else { return }
    unparsed += (unparsed.isEmpty ? "" : "\n") + line
  }

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  private struct Chunk: Decodable {
    struct Choice: Decodable {
      let delta: Delta?
    }

    struct Delta: Decodable {
      let content: String?
      let reasoning: String?
      let reasoningContent: String?
      let toolCalls: [ToolCallDelta]?
    }

    struct ToolCallDelta: Decodable {
      let index: Int?
      let id: String?
      let function: FunctionDelta?
    }

    struct FunctionDelta: Decodable {
      let name: String?
      let arguments: String?
    }

    let choices: [Choice]?
    let error: JSONValue?
  }
}
