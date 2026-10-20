#if DEBUG
import Foundation

// Deterministic provider for tests and UI development (launch with --fake-llm).
// Replies to every prompt by upper-casing the current artefact via
// `write_artefact`, unless the prompt starts with "?" in which case it only
// answers in chat.
nonisolated struct FakeProvider: LLMProvider {
  var displayName = "Fake"
  var delay: Duration = .milliseconds(20)

  func run(
    instructions: String,
    messages: [LLMMessage],
    tools: [LLMTool]
  ) -> AsyncThrowingStream<LLMEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let message = messages.last?.content ?? ""
          let prompt = message.components(separatedBy: "Request: ").last ?? message
          for word in ["Sure", ", ", "done."] {
            try await Task.sleep(for: delay)
            continuation.yield(.textDelta(word))
          }
          if !prompt.hasPrefix("?"), let tool = tools.first(where: { $0.name == "write_artefact" }) {
            let text = Self.currentArtefact(in: message).uppercased()
            let arguments = JSONValue.object(["text": .string(text)])
            continuation.yield(.toolCall(name: tool.name, arguments: arguments))
            let result = try await tool.execute(arguments)
            continuation.yield(.toolResult(name: tool.name, result: result))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // ChatSession renders the current version as <artefact version="N">…</artefact>
  // in the last user message.
  private static func currentArtefact(in message: String) -> String {
    guard let start = message.range(of: "\">\n"),
          let end = message.range(of: "\n</artefact>", options: .backwards),
          start.upperBound <= end.lowerBound else {
      return ""
    }
    return String(message[start.upperBound..<end.lowerBound])
  }
}
#endif
