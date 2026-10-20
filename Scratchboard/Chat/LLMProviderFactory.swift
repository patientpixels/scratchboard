import Defaults
import Foundation

enum LLMProviderKind: String, CaseIterable, Identifiable, Defaults.Serializable {
  case apple
  case openAICompatible

  var id: Self { self }
}

@MainActor
enum LLMProviderFactory {
  // The provider configured in Settings → AI, or nil if it isn't usable
  // (e.g. Apple Intelligence unavailable, missing base URL).
  static func makeCurrent() -> (any LLMProvider)? {
    #if DEBUG
    return FakeProvider()
    #else
    return nil
    #endif
  }
}
