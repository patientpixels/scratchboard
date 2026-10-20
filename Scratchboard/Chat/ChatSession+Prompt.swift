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
    - Never put artefact content in your chat replies. Reply in one short sentence about what you \
    changed, or ask a short question if the request is unclear.
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
}
