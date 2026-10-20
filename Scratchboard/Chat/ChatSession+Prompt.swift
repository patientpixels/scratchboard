import Foundation

extension ChatSession {
  static let instructions = """
    You are a writing assistant in Scratchboard, a clipboard manager. You and the user work on one \
    piece of text, the artefact, which started as a clip from their clipboard. Every change creates \
    a numbered version; v1 is the original clip. The current version is always on the user's \
    clipboard, ready to paste.

    - Change the artefact only by calling tools: write_artefact creates a new version from the \
    complete new text, restore_version makes an earlier version current again.
    - The text you pass to write_artefact is pasted as-is. Give the complete artefact with no \
    preamble, explanation or surrounding quotes, and don't wrap it in Markdown code fences unless \
    the artefact is code that should be fenced.
    - Always end your turn with a chat reply, also after using tools. Talk with the user: say what \
    you changed and why in a sentence or two, \
    point out anything you weren't sure about, and suggest a next step when it helps. If the request \
    is ambiguous, ask a short question instead of guessing, and don't change the artefact.
    - Never claim a change you didn't make with a tool call.
    - Never put artefact content in your chat replies.
    - If the user only asks something about the text, answer briefly without changing it.
    - The last user message shows the current version inside <artefact version="N"> tags, followed \
    by the request. Earlier versions appear in the conversation, labelled vN, so you can refer to \
    or restore them.
    """

  // Earlier turns are flattened into plain messages, with version events as
  // user-side notes carrying the full text. The last message is
  // self-contained (current version + request), so providers that trim
  // history still have what they need.
  func renderMessages() -> [LLMMessage] {
    guard let promptIndex = transcript.lastIndex(where: { if case .user = $0 { true } else { false } }),
          case .user(_, let prompt) = transcript[promptIndex],
          let current else {
      return []
    }

    var parts: [(LLMMessage.Role, String)] = []
    let history = transcript[..<promptIndex]
    if !history.isEmpty, let original = versions.first {
      parts.append((.user, "[v1, the original clip:]\n\(Self.block(original))"))
    }
    for entry in history {
      switch entry {
      case .user(_, let text):
        parts.append((.user, text))
      case .assistant(_, let text):
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          parts.append((.assistant, text))
        }
      case .version(_, let number, let author, let restoredFrom):
        guard let version = versions.first(where: { $0.number == number }) else { continue }
        let label = switch (author, restoredFrom) {
        case (_, let source?): "You restored v\(source) as v\(number):"
        case (.user, nil): "The user edited the artefact by hand, creating v\(number):"
        default: "You wrote v\(number):"
        }
        parts.append((.user, "[\(label)]\n\(Self.block(version))"))
      case .pointer(_, let number):
        parts.append((.user, "[The user made v\(number) the current version.]"))
      case .error:
        continue
      }
    }
    parts.append((.user, "Current version: v\(current.number)\n\(Self.block(current))\n\nRequest: \(prompt)"))

    var messages: [LLMMessage] = []
    for (role, content) in parts {
      if let last = messages.last, last.role == role {
        messages[messages.count - 1] = LLMMessage(role: role, content: last.content + "\n\n" + content)
      } else {
        messages.append(LLMMessage(role: role, content: content))
      }
    }
    return messages
  }

  private static func block(_ version: ArtefactVersion) -> String {
    "<artefact version=\"\(version.number)\">\n\(version.text)\n</artefact>"
  }

  // Small models sometimes echo the rendered prompt instead of chatting. Chat
  // text must never carry artefact content, so this removes artefact blocks
  // (unterminated ones up to the end) and lines echoing the scaffolding of the
  // last message. While `streaming`, a trailing start of either is held back
  // so it doesn't flash. Text without any of this is returned unchanged.
  // Some models copy the prompt's <artefact version="N"> wrapper into
  // write_artefact's text; the wrapper is never part of the artefact.
  nonisolated static func unwrapArtefactTags(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("<artefact"), trimmed.hasSuffix("</artefact>"),
          let open = trimmed.range(of: ">") else {
      return text
    }
    var inner = trimmed[open.upperBound..<trimmed.index(trimmed.endIndex, offsetBy: -"</artefact>".count)]
    if inner.hasPrefix("\n") { inner = inner.dropFirst() }
    if inner.hasSuffix("\n") { inner = inner.dropLast() }
    return String(inner)
  }

  nonisolated static func sanitizeAssistantText(_ text: String, streaming: Bool) -> String {
    var result = text.replacingOccurrences(
      of: #"<artefact\b(?:[^>]*>[\s\S]*?(?:</artefact\s*>|\z)|[^>]*\z)|</artefact\s*>"#,
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )

    var lines = result.components(separatedBy: "\n")
    lines.removeAll { line in
      let line = line.trimmingCharacters(in: .whitespaces).lowercased()
      return echoPrefixes.contains { line.hasPrefix($0) }
    }
    if streaming, let last = lines.last, isPartialMarker(last.trimmingCharacters(in: .whitespaces)) {
      lines.removeLast()
    }
    result = lines.joined(separator: "\n")
    if streaming, let tag = result.range(of: "<", options: .backwards),
       isPartialMarker(String(result[tag.lowerBound...])) {
      result.removeSubrange(tag.lowerBound...)
    }

    guard result != text else { return text }
    return result
      .replacingOccurrences(of: #"\n\s*\n(\s*\n)+"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static let echoPrefixes = ["request:", "current version:"]

  // Whether `text` could still grow into an artefact tag or an echo line.
  nonisolated private static func isPartialMarker(_ text: String) -> Bool {
    let text = text.lowercased()
    return !text.isEmpty && (echoPrefixes + ["<artefact"]).contains { $0.hasPrefix(text) }
  }
}
