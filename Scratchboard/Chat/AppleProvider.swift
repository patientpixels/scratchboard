import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Apple's on-device model via FoundationModels (macOS 26+).
nonisolated struct AppleProvider: LLMProvider {
  var displayName: String { "Apple Intelligence" }

  // nil when usable, otherwise a user-facing reason (older macOS, Apple
  // Intelligence turned off, model not downloaded, unsupported device).
  static var unavailableReason: String? {
    #if canImport(FoundationModels)
    if #available(macOS 26, *) {
      switch SystemLanguageModel.default.availability {
      case .available:
        return nil
      case .unavailable(.deviceNotEligible):
        return "This Mac doesn't support Apple Intelligence."
      case .unavailable(.appleIntelligenceNotEnabled):
        return "Turn on Apple Intelligence in System Settings."
      case .unavailable(.modelNotReady):
        return "Apple Intelligence is still downloading its model. Try again later."
      case .unavailable:
        return "Apple Intelligence isn't available."
      }
    }
    #endif
    return "Requires macOS 26 with Apple Intelligence."
  }

  func run(
    instructions: String,
    messages: [LLMMessage],
    tools: [LLMTool]
  ) -> AsyncThrowingStream<LLMEvent, Error> {
    AsyncThrowingStream { continuation in
      #if canImport(FoundationModels)
      if #available(macOS 26, *) {
        let task = Task {
          do {
            try await Self.respond(
              instructions: instructions,
              messages: messages,
              tools: tools,
              continuation: continuation
            )
            continuation.finish()
          } catch {
            continuation.finish(throwing: Self.mapError(error))
          }
        }
        continuation.onTermination = { _ in task.cancel() }
        return
      }
      #endif
      continuation.finish(throwing: LLMError.unavailable(Self.unavailableReason ?? ""))
    }
  }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
nonisolated extension AppleProvider {
  private static func respond(
    instructions: String,
    messages: [LLMMessage],
    tools: [LLMTool],
    continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
  ) async throws {
    if let reason = unavailableReason {
      throw LLMError.unavailable(reason)
    }

    let model = SystemLanguageModel.default
    let counter = AppleToolCallCounter()
    let appleTools = try tools.map { tool in
      try AppleTool(tool, counter: counter) { continuation.yield($0) }
    }
    let budget = ApplePrompt.budget(
      contextSize: model.contextSize,
      instructions: instructions,
      tools: tools
    )
    let (history, prompt) = try ApplePrompt.fit(messages, budget: budget)

    let session = LanguageModelSession(
      model: model,
      tools: appleTools,
      instructions: Instructions(ApplePrompt.instructions(instructions, history: history))
    )
    var delta = AppleStreamDelta()
    for try await snapshot in session.streamResponse(to: prompt.content) {
      let text = delta.delta(for: snapshot.content)
      if !text.isEmpty {
        continuation.yield(.textDelta(text))
      }
    }
  }

  static func mapError(_ error: Error) -> Error {
    switch error {
    case let error as LanguageModelSession.ToolCallError:
      // Errors thrown by the app's tools (incl. the tool-call limit).
      return error.underlyingError
    case let error as LanguageModelSession.GenerationError:
      switch error {
      case .exceededContextWindowSize:
        return LLMError.contextTooLong
      case .guardrailViolation:
        return LLMError.invalidResponse("Apple Intelligence's safety guardrails blocked this request.")
      case .refusal:
        return LLMError.invalidResponse("Apple Intelligence declined this request.")
      case .unsupportedLanguageOrLocale:
        return LLMError.unavailable("Apple Intelligence doesn't support this language.")
      case .assetsUnavailable:
        return LLMError.unavailable("The Apple Intelligence model isn't ready. Try again later.")
      case .rateLimited, .concurrentRequests:
        return LLMError.unavailable("Apple Intelligence is busy. Try again in a moment.")
      default:
        return LLMError.invalidResponse(error.localizedDescription)
      }
    case is LLMError, is CancellationError:
      return error
    default:
      // E.g. untyped token generation failures surfaced as NSError.
      return LLMError.invalidResponse("Apple Intelligence couldn't generate a response.")
    }
  }
}
#endif
