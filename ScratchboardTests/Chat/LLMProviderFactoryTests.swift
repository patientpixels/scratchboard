import XCTest
import Defaults
@testable import Scratchboard

@MainActor
class LLMProviderFactoryTests: XCTestCase {
  let savedProvider = Defaults[.aiProvider]
  let savedBaseURL = Defaults[.aiBaseURL]
  let savedModel = Defaults[.aiModel]
  let savedOllamaBaseURL = Defaults[.ollamaBaseURL]
  let savedOllamaModel = Defaults[.ollamaModel]

  var savedKeychain: (any SecretStore)!
  var store: InMemorySecretStore!

  override func setUp() async throws {
    try await super.setUp()
    savedKeychain = Keychain.shared
    store = InMemorySecretStore()
    Keychain.shared = store
  }

  override func tearDown() async throws {
    try await super.tearDown()
    Defaults[.aiProvider] = savedProvider
    Defaults[.aiBaseURL] = savedBaseURL
    Defaults[.aiModel] = savedModel
    Defaults[.ollamaBaseURL] = savedOllamaBaseURL
    Defaults[.ollamaModel] = savedOllamaModel
    Keychain.shared = savedKeychain
  }

  // MARK: - URL validation

  func testValidatedBaseURLAcceptsHTTPAndHTTPS() {
    XCTAssertEqual(
      LLMProviderFactory.validatedBaseURL("https://api.openai.com/v1"),
      URL(string: "https://api.openai.com/v1")
    )
    XCTAssertEqual(
      LLMProviderFactory.validatedBaseURL("http://localhost:11434/v1"),
      URL(string: "http://localhost:11434/v1")
    )
    XCTAssertEqual(
      LLMProviderFactory.validatedBaseURL("  https://api.anthropic.com/v1/\n"),
      URL(string: "https://api.anthropic.com/v1/")
    )
    XCTAssertNotNil(LLMProviderFactory.validatedBaseURL("HTTPS://openrouter.ai/api/v1"))
  }

  func testValidatedBaseURLRejectsInvalid() {
    XCTAssertNil(LLMProviderFactory.validatedBaseURL(""))
    XCTAssertNil(LLMProviderFactory.validatedBaseURL("   "))
    XCTAssertNil(LLMProviderFactory.validatedBaseURL("api.openai.com/v1"))
    XCTAssertNil(LLMProviderFactory.validatedBaseURL("localhost:11434"))
    XCTAssertNil(LLMProviderFactory.validatedBaseURL("ftp://example.com"))
    XCTAssertNil(LLMProviderFactory.validatedBaseURL("file:///etc/passwd"))
    XCTAssertNil(LLMProviderFactory.validatedBaseURL("https://"))
    XCTAssertNil(LLMProviderFactory.validatedBaseURL("https://exa mple.com"))
  }

  // MARK: - Selection

  func testOllamaWithModel() throws {
    let resolution = LLMProviderFactory.resolve(
      config(kind: .ollama, baseURL: "http://localhost:11434/v1", model: " qwen3:8b ", apiKey: "sk-ignored")
    )
    let ollama = try XCTUnwrap(provider(resolution) as? OpenAICompatibleProvider)
    XCTAssertEqual(ollama.baseURL, URL(string: "http://localhost:11434/v1"))
    XCTAssertEqual(ollama.model, "qwen3:8b")
    XCTAssertNil(ollama.apiKey)
    XCTAssertNil(ollama.reasoningEffort)
  }

  func testOllamaWithoutModel() {
    for model in ["", "  "] {
      let resolution = LLMProviderFactory.resolve(config(kind: .ollama, model: model))
      XCTAssertEqual(reason(resolution), "Choose an Ollama model in Settings → AI")
    }
  }

  func testOllamaInvalidBaseURL() {
    let resolution = LLMProviderFactory.resolve(config(kind: .ollama, baseURL: "localhost:11434", model: "qwen3:8b"))
    XCTAssertEqual(reason(resolution), "Set a valid Ollama URL in Settings → AI")
  }

  func testOpenAICompatible() throws {
    let resolution = LLMProviderFactory.resolve(
      config(baseURL: "https://openrouter.ai/api/v1", model: " openai/gpt-4.1 ", apiKey: "sk-123")
    )
    let openAI = try XCTUnwrap(provider(resolution) as? OpenAICompatibleProvider)
    XCTAssertEqual(openAI.baseURL, URL(string: "https://openrouter.ai/api/v1"))
    XCTAssertEqual(openAI.model, "openai/gpt-4.1")
    XCTAssertEqual(openAI.apiKey, "sk-123")
  }

  func testOpenAICompatibleWithoutKey() throws {
    for key in [nil, "", "  "] {
      let resolution = LLMProviderFactory.resolve(
        config(baseURL: "http://localhost:11434/v1", model: "llama3.2", apiKey: key)
      )
      let openAI = try XCTUnwrap(provider(resolution) as? OpenAICompatibleProvider)
      XCTAssertNil(openAI.apiKey)
    }
  }

  func testOpenAICompatibleInvalidBaseURL() {
    let resolution = LLMProviderFactory.resolve(config(baseURL: "localhost:11434", model: "llama3.2"))
    XCTAssertEqual(reason(resolution), "Set a valid base URL in Settings → AI")
  }

  func testOpenAICompatibleMissingModel() {
    let resolution = LLMProviderFactory.resolve(config(baseURL: "https://api.openai.com/v1", model: "  "))
    XCTAssertEqual(reason(resolution), "Set a model in Settings → AI")
  }

  func testFakeOverridesConfiguration() {
    let resolution = LLMProviderFactory.resolve(
      config(kind: .ollama, model: "", useFake: true)
    )
    XCTAssertTrue(provider(resolution) is FakeProvider)
  }

  // MARK: - Current configuration

  func testMakeCurrentReadsDefaultsAndKeychain() throws {
    Defaults[.aiProvider] = .openAICompatible
    Defaults[.aiBaseURL] = "https://api.openai.com/v1"
    Defaults[.aiModel] = "gpt-4.1-mini"
    try store.set("sk-from-keychain", for: Keychain.aiAPIKey)

    let openAI = try XCTUnwrap(LLMProviderFactory.makeCurrent() as? OpenAICompatibleProvider)
    XCTAssertEqual(openAI.baseURL, URL(string: "https://api.openai.com/v1"))
    XCTAssertEqual(openAI.model, "gpt-4.1-mini")
    XCTAssertEqual(openAI.apiKey, "sk-from-keychain")
    XCTAssertNil(LLMProviderFactory.unavailableReason())
  }

  func testMakeCurrentNilWithReason() {
    Defaults[.aiProvider] = .openAICompatible
    Defaults[.aiBaseURL] = "https://api.openai.com/v1"
    Defaults[.aiModel] = ""

    XCTAssertNil(LLMProviderFactory.makeCurrent())
    XCTAssertEqual(LLMProviderFactory.unavailableReason(), "Set a model in Settings → AI")
  }

  func testCurrentOllamaKeepsItsOwnSettings() throws {
    Defaults[.aiProvider] = .ollama
    Defaults[.ollamaBaseURL] = "http://127.0.0.1:11434/v1"
    Defaults[.ollamaModel] = "qwen3:8b"
    Defaults[.aiBaseURL] = "https://api.openai.com/v1"
    Defaults[.aiModel] = "gpt-4.1-mini"
    try store.set("sk-unused", for: Keychain.aiAPIKey)

    let configuration = LLMProviderFactory.Configuration.current
    XCTAssertEqual(configuration.kind, .ollama)
    XCTAssertEqual(configuration.baseURL, "http://127.0.0.1:11434/v1")
    XCTAssertEqual(configuration.model, "qwen3:8b")
    XCTAssertNil(configuration.apiKey)

    Defaults[.aiProvider] = .openAICompatible
    XCTAssertEqual(LLMProviderFactory.Configuration.current.baseURL, "https://api.openai.com/v1")
    XCTAssertEqual(LLMProviderFactory.Configuration.current.model, "gpt-4.1-mini")
    XCTAssertEqual(Defaults[.ollamaModel], "qwen3:8b")
  }

  func testCurrentOllamaWithoutModel() {
    Defaults[.aiProvider] = .ollama
    Defaults[.ollamaModel] = ""

    XCTAssertNil(LLMProviderFactory.makeCurrent())
    XCTAssertEqual(LLMProviderFactory.unavailableReason(), "Choose an Ollama model in Settings → AI")
  }

  func testStoredLegacyAppleProviderFallsBackToOllama() {
    Defaults.Keys.aiProvider.suite.set("apple", forKey: Defaults.Keys.aiProvider.name)

    XCTAssertEqual(Defaults[.aiProvider], .ollama)
    XCTAssertEqual(LLMProviderFactory.Configuration.current.kind, .ollama)
  }

  // MARK: - Helpers

  private func config(
    kind: LLMProviderKind = .openAICompatible,
    baseURL: String = "https://api.openai.com/v1",
    model: String = "gpt-4.1-mini",
    apiKey: String? = nil,
    useFake: Bool = false
  ) -> LLMProviderFactory.Configuration {
    LLMProviderFactory.Configuration(
      kind: kind,
      baseURL: baseURL,
      model: model,
      apiKey: apiKey,
      useFake: useFake
    )
  }

  private func provider(_ resolution: LLMProviderFactory.Resolution) -> (any LLMProvider)? {
    if case .provider(let provider) = resolution { return provider }
    return nil
  }

  private func reason(_ resolution: LLMProviderFactory.Resolution) -> String? {
    if case .unavailable(let reason) = resolution { return reason }
    return nil
  }
}
