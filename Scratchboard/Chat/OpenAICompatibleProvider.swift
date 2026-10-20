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

  func run(
    instructions: String,
    messages: [LLMMessage],
    tools: [LLMTool]
  ) -> AsyncThrowingStream<LLMEvent, Error> {
    AsyncThrowingStream { $0.finish(throwing: LLMError.unavailable("Not implemented yet")) }
  }
}
