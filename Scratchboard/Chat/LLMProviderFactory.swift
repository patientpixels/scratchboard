import Defaults
import Foundation

enum LLMProviderKind: String, CaseIterable, Identifiable, Defaults.Serializable {
  case apple
  case openAICompatible

  var id: Self { self }

  var title: String {
    switch self {
    case .apple: "Apple Intelligence"
    case .openAICompatible: "OpenAI-compatible"
    }
  }
}

@MainActor
enum LLMProviderFactory {
  struct Configuration {
    var kind: LLMProviderKind
    var baseURL: String
    var model: String
    var apiKey: String?
    var appleUnavailableReason: String?
    var useFake = false

    static var current: Configuration {
      let kind = Defaults[.aiProvider]
      return Configuration(
        kind: kind,
        baseURL: Defaults[.aiBaseURL],
        model: Defaults[.aiModel],
        apiKey: kind == .openAICompatible ? Keychain.shared.string(for: Keychain.aiAPIKey) : nil,
        appleUnavailableReason: kind == .apple ? AppleProvider.unavailableReason : nil,
        useFake: isFakeRequested
      )
    }

    private static var isFakeRequested: Bool {
      #if DEBUG
      return ProcessInfo.processInfo.arguments.contains("--fake-llm")
      #else
      return false
      #endif
    }
  }

  enum Resolution {
    case provider(any LLMProvider)
    case unavailable(String)
  }

  // The provider configured in Settings → AI, or nil if it isn't usable
  // (e.g. Apple Intelligence unavailable, missing base URL).
  static func makeCurrent() -> (any LLMProvider)? {
    if case .provider(let provider) = resolve(.current) {
      return provider
    }
    return nil
  }

  // Why makeCurrent() returns nil, or nil if it doesn't.
  static func unavailableReason() -> String? {
    if case .unavailable(let reason) = resolve(.current) {
      return reason
    }
    return nil
  }

  static func resolve(_ configuration: Configuration) -> Resolution {
    #if DEBUG
    if configuration.useFake {
      return .provider(FakeProvider())
    }
    #endif

    switch configuration.kind {
    case .apple:
      if let reason = configuration.appleUnavailableReason {
        return .unavailable(reason)
      }
      return .provider(AppleProvider())
    case .openAICompatible:
      guard let url = validatedBaseURL(configuration.baseURL) else {
        return .unavailable("Set a valid base URL in Settings → AI")
      }
      let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !model.isEmpty else {
        return .unavailable("Set a model in Settings → AI")
      }
      let apiKey = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
      return .provider(OpenAICompatibleProvider(
        baseURL: url,
        model: model,
        apiKey: apiKey?.isEmpty == false ? apiKey : nil
      ))
    }
  }

  // An absolute http(s) URL with a host, or nil.
  nonisolated static func validatedBaseURL(_ string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = components.host, !host.isEmpty,
          let url = components.url else {
      return nil
    }
    return url
  }
}
