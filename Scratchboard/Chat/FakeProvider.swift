#if DEBUG
import Foundation

// Deterministic provider for tests and UI development. Replies to every prompt
// by upper-casing the current artefact via `write_artefact`, unless the prompt
// starts with "?" in which case it only answers in chat.
nonisolated struct FakeProvider: LLMProvider {
  var displayName = "Fake"
  var delay: Duration = .milliseconds(20)
  // Supplies the current artefact text; set by whoever wires the fake up.
  var currentArtefact: @Sendable () async -> String = { "" }

  func run(
    instructions: String,
    messages: [LLMMessage],
    tools: [LLMTool]
  ) -> AsyncThrowingStream<LLMEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let prompt = messages.last?.content ?? ""
          for word in ["Sure", ", ", "done."] {
            try await Task.sleep(for: delay)
            continuation.yield(.textDelta(word))
          }
          if !prompt.hasPrefix("?"), let tool = tools.first(where: { $0.name == "write_artefact" }) {
            let text = await currentArtefact().uppercased()
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
}
#endif
