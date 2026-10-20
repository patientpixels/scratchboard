import Foundation

// Fits the conversation into the on-device model's small context window.
nonisolated enum ApplePrompt {
  // Measured on the on-device tokenizer: prose ~3, code ~2.4, JSON ~1.8.
  static let charactersPerToken = 2
  // Role markers and turn boundaries.
  static let tokensPerMessage = 8
  // The small model loses track of the current request with longer history.
  static let maxHistoryMessages = 4

  static func estimatedTokens(_ text: String) -> Int {
    (text.count + charactersPerToken - 1) / charactersPerToken
  }

  // Tokens available for the messages. Half of what remains after the
  // instructions and tool definitions is left for the response, which may
  // rewrite the whole artefact in a tool call.
  static func budget(contextSize: Int, instructions: String, tools: [LLMTool]) -> Int {
    let toolTokens = tools.reduce(0) { total, tool in
      let schema = (try? tool.parameters.jsonString()) ?? ""
      return total + estimatedTokens(tool.name + tool.description + schema) + tokensPerMessage
    }
    let fixed = estimatedTokens(instructions) + tokensPerMessage + toolTokens
    return max(0, (contextSize - fixed) / 2)
  }

  // Keeps the last message whole and as many of the most recent earlier
  // messages as fit (at most `maxHistoryMessages`), dropping the oldest first.
  static func fit(
    _ messages: [LLMMessage],
    budget: Int
  ) throws -> (history: [LLMMessage], prompt: LLMMessage) {
    guard let prompt = messages.last else {
      return ([], LLMMessage(role: .user, content: ""))
    }
    var remaining = budget - estimatedTokens(prompt.content) - tokensPerMessage
    guard remaining >= 0 else { throw LLMError.contextTooLong }

    var history: [LLMMessage] = []
    for message in messages.dropLast().suffix(maxHistoryMessages).reversed() {
      remaining -= estimatedTokens(message.content) + tokensPerMessage
      guard remaining >= 0 else { break }
      history.insert(message, at: 0)
    }
    // History should open with a user turn.
    while history.first?.role == .assistant {
      history.removeFirst()
    }
    return (history, prompt)
  }

  // Earlier turns are appended to the instructions as text. Replaying them as
  // transcript entries makes the on-device model stop calling tools, and
  // putting them in the prompt makes it ignore the current request.
  static func instructions(_ instructions: String, history: [LLMMessage]) -> String {
    guard !history.isEmpty else { return instructions }
    let turns = history.map { "[\($0.role.rawValue)] \($0.content)" }.joined(separator: "\n\n")
    return "\(instructions)\n\n<earlier_conversation>\n\(turns)\n</earlier_conversation>"
  }
}

// Turns cumulative stream snapshots into deltas.
nonisolated struct AppleStreamDelta {
  private(set) var text = ""

  mutating func delta(for snapshot: String) -> String {
    guard !snapshot.isEmpty else { return "" }
    if snapshot.hasPrefix(text) {
      let delta = String(snapshot.dropFirst(text.count))
      text = snapshot
      return delta
    }
    // A new response started (e.g. after a tool call).
    let delta = text.isEmpty ? snapshot : "\n\n" + snapshot
    text = snapshot
    return delta
  }
}
