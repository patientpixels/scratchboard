import SwiftUI
import Defaults
import Settings
import enum Settings.Settings

struct AISettingsPane: View {
  private enum OllamaStatus: Equatable {
    case checking
    case running(models: Int)
    case unreachable
    case failed(String)
  }

  @Default(.aiProvider) private var provider
  @Default(.ollamaBaseURL) private var ollamaBaseURL
  @Default(.ollamaModel) private var ollamaModel
  @Default(.aiBaseURL) private var baseURL
  @Default(.aiModel) private var model
  @Default(.keepEditHistory) private var keepEditHistory

  @State private var apiKey = ""
  @State private var savedAPIKey = ""
  @State private var keychainError: String?

  @State private var ollamaModels: [String] = []
  @State private var ollamaStatus = OllamaStatus.checking
  @State private var ollamaRefreshes = 0

  var body: some View {
    Group {
      switch provider {
      case .ollama:
        Settings.Container(contentWidth: 450) {
          providerSection
          ollamaURLSection
          ollamaStatusSection
          ollamaModelSection
          historySection
        }
        // Runs when the pane shows Ollama and on refresh, never at launch.
        .task(id: ollamaRefreshes) { await refreshOllamaModels() }
      case .openAICompatible:
        Settings.Container(contentWidth: 450) {
          providerSection
          baseURLSection
          modelSection
          apiKeySection
          historySection
        }
      }
    }
    .onAppear(perform: loadAPIKey)
    .onDisappear(perform: saveAPIKey)
    .task(id: apiKey) {
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      saveAPIKey()
    }
  }

  private var providerSection: Settings.Section {
    Settings.Section(label: { Text("Provider:") }) {
      Picker("", selection: $provider) {
        ForEach(LLMProviderKind.allCases) { kind in
          Text(kind.title)
        }
      }
      .labelsHidden()
      .frame(width: 200, alignment: .leading)
      .accessibilityLabel(Text("Provider"))
    }
  }

  private var ollamaURLSection: Settings.Section {
    Settings.Section(label: { Text("Base URL:") }) {
      TextField("", text: $ollamaBaseURL, prompt: Text("http://localhost:11434/v1"))
        .frame(width: 300)
        .accessibilityLabel(Text("Ollama base URL"))
        .onSubmit { ollamaRefreshes += 1 }
    }
  }

  private var ollamaStatusSection: Settings.Section {
    Settings.Section(label: { Text("Status:") }) {
      switch ollamaStatus {
      case .checking:
        Label("Checking…", systemImage: "ellipsis.circle")
          .foregroundStyle(.gray)
      case .running(let count):
        Label("Running · \(count) \(count == 1 ? "model" : "models")", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        if count == 0 {
          hint("Pull a model with tool support:\nollama pull <model>")
        }
      case .unreachable:
        Label("Can't reach Ollama at \(ollamaBaseURL)", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        hint("""
          Install and start Ollama, then pull a model:
          brew install ollama
          brew services start ollama
          ollama pull <model>
          """)
      case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var ollamaModelSection: Settings.Section {
    Settings.Section(bottomDivider: true, label: { Text("Model:") }) {
      HStack {
        Picker("", selection: $ollamaModel) {
          if ollamaModel.isEmpty {
            Text("Choose a model").tag("")
          }
          ForEach(ollamaModelChoices, id: \.self) { name in
            Text(name).tag(name)
          }
        }
        .labelsHidden()
        .frame(width: 270)
        .disabled(ollamaModelChoices.isEmpty)
        .accessibilityLabel(Text("Model"))
        Button {
          ollamaRefreshes += 1
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh models")
        .accessibilityLabel(Text("Refresh models"))
      }
      Text("Runs on this Mac. Nothing leaves your device.")
        .controlSize(.small)
        .foregroundStyle(.gray)
    }
  }

  // Keeps a chosen model selectable while Ollama is down.
  private var ollamaModelChoices: [String] {
    if ollamaModel.isEmpty || ollamaModels.contains(ollamaModel) {
      return ollamaModels
    }
    return ollamaModels + [ollamaModel]
  }

  private func hint(_ text: String) -> some View {
    Text(text)
      .controlSize(.small)
      .foregroundStyle(.gray)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var baseURLSection: Settings.Section {
    Settings.Section(label: { Text("Base URL:") }) {
      TextField("", text: $baseURL, prompt: Text("https://api.openai.com/v1"))
        .frame(width: 300)
        .accessibilityLabel(Text("Base URL"))
      if LLMProviderFactory.validatedBaseURL(baseURL) == nil {
        Text("Enter an http or https URL.")
          .controlSize(.small)
          .foregroundStyle(.red)
      }
      Text("""
        OpenAI: https://api.openai.com/v1
        OpenRouter: https://openrouter.ai/api/v1
        LM Studio: http://localhost:1234/v1
        Anthropic: https://api.anthropic.com/v1/
        """)
        .controlSize(.small)
        .foregroundStyle(.gray)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var modelSection: Settings.Section {
    Settings.Section(label: { Text("Model:") }) {
      TextField("", text: $model, prompt: Text("e.g. gpt-4.1-mini"))
        .frame(width: 300)
        .accessibilityLabel(Text("Model"))
    }
  }

  private var apiKeySection: Settings.Section {
    Settings.Section(bottomDivider: true, label: { Text("API key:") }) {
      SecureField("", text: $apiKey, prompt: Text("Optional for local servers"))
        .frame(width: 300)
        .accessibilityLabel(Text("API key"))
        .onSubmit(saveAPIKey)
      if let keychainError {
        Text(keychainError)
          .controlSize(.small)
          .foregroundStyle(.red)
      } else {
        Text("Stored in your Keychain.")
          .controlSize(.small)
          .foregroundStyle(.gray)
      }
    }
  }

  private var historySection: Settings.Section {
    Settings.Section(title: "") {
      Toggle("Keep edit history", isOn: $keepEditHistory)
      Text("When off, chats are kept in memory only and discarded on close.")
        .controlSize(.small)
        .foregroundStyle(.gray)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func refreshOllamaModels() async {
    guard let url = LLMProviderFactory.validatedBaseURL(ollamaBaseURL) else {
      ollamaModels = []
      ollamaStatus = .failed("Enter an http or https URL.")
      return
    }
    ollamaStatus = .checking
    do {
      let models = try await OpenAICompatibleProvider.models(baseURL: url)
      ollamaModels = models
      ollamaStatus = .running(models: models.count)
      if ollamaModel.isEmpty, let first = models.first {
        ollamaModel = first
      }
    } catch {
      guard !Task.isCancelled else { return }
      ollamaModels = []
      if case .unavailable? = error as? LLMError {
        ollamaStatus = .unreachable
      } else {
        ollamaStatus = .failed(error.localizedDescription)
      }
    }
  }

  private func loadAPIKey() {
    let stored = Keychain.shared.string(for: Keychain.aiAPIKey) ?? ""
    savedAPIKey = stored
    apiKey = stored
  }

  private func saveAPIKey() {
    let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value != savedAPIKey else { return }
    do {
      try Keychain.shared.set(value, for: Keychain.aiAPIKey)
      savedAPIKey = value
      keychainError = nil
    } catch {
      keychainError = error.localizedDescription
    }
  }
}

#Preview {
  AISettingsPane()
}
