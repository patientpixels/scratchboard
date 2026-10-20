import Foundation

// Apple's on-device model via FoundationModels (macOS 26+).
nonisolated struct AppleProvider: LLMProvider {
  var displayName: String { "Apple Intelligence" }

  // nil when usable, otherwise a user-facing reason (older macOS, Apple
  // Intelligence turned off, model not downloaded, unsupported device).
  static var unavailableReason: String? { "Not implemented yet" }

  func run(
    instructions: String,
    messages: [LLMMessage],
    tools: [LLMTool]
  ) -> AsyncThrowingStream<LLMEvent, Error> {
    AsyncThrowingStream { $0.finish(throwing: LLMError.unavailable("Not implemented yet")) }
  }
}
