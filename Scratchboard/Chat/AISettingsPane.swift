import SwiftUI
import Defaults
import Settings
import enum Settings.Settings

struct AISettingsPane: View {
  @Default(.aiProvider) private var provider
  @Default(.aiBaseURL) private var baseURL
  @Default(.aiModel) private var model
  @Default(.keepEditHistory) private var keepEditHistory

  @State private var apiKey = ""
  @State private var savedAPIKey = ""
  @State private var keychainError: String?

  private let appleUnavailableReason = AppleProvider.unavailableReason

  var body: some View {
    Group {
      switch provider {
      case .apple:
        Settings.Container(contentWidth: 450) {
          providerSection
          appleStatusSection
          historySection
        }
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

  private var appleStatusSection: Settings.Section {
    Settings.Section(bottomDivider: true, label: { Text("Status:") }) {
      if let appleUnavailableReason {
        Label(appleUnavailableReason, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Label("Ready", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
      Text("Runs on this Mac. Nothing leaves your device.")
        .controlSize(.small)
        .foregroundStyle(.gray)
    }
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
        Ollama: http://localhost:11434/v1
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
