import SwiftUI

// Takes over the panel while chatting on a clip: artefact editor, transcript,
// prompt. Keys are routed by ChatTextView → ChatController.
struct ChatView: View {
  let chat: ChatSession

  @State private var controller: ChatController

  init(chat: ChatSession) {
    self.chat = chat
    self._controller = State(initialValue: ChatController(session: chat))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text(chat.current.map(\.headerLabel) ?? "")
          .font(.headline)
          .foregroundStyle(.secondary)
        Spacer()
        if chat.isRunning {
          ProgressView()
            .controlSize(.small)
        }
      }
      .frame(height: Popup.itemHeight)
      .padding(.horizontal, Popup.horizontalPadding)

      ArtefactEditorView(
        controller: controller,
        version: chat.current,
        isEditable: !chat.isRunning
      )
      .padding(.horizontal, Popup.horizontalPadding)
      .padding(.vertical, Popup.verticalPadding)
      .background {
        RoundedRectangle(cornerRadius: Popup.cornerRadius, style: .continuous)
          .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
      }
      .frame(minHeight: 80, maxHeight: .infinity)

      Divider()
        .padding(.vertical, Popup.verticalSeparatorPadding)

      // Shares the height with the artefact: the conversation matters as much.
      TranscriptView(transcript: chat.transcript)
        .frame(minHeight: 120, maxHeight: .infinity)

      Divider()
        .padding(.vertical, Popup.verticalSeparatorPadding)

      HStack(alignment: .bottom, spacing: 6) {
        PromptEditorView(controller: controller, placeholder: placeholder)
          .frame(height: 54)
        Text("⌘↩")
          .foregroundStyle(.tertiary)
          .padding(.bottom, 2)
      }
      .padding(.horizontal, Popup.horizontalPadding)
    }
    .padding(.horizontal, Popup.horizontalPadding)
    .padding(.vertical, Popup.verticalPadding * 2)
  }

  private var placeholder: String {
    if let providerName = chat.providerName {
      return "Ask \(providerName)…"
    }
    return "No AI provider — set one up in Settings (⌘,)"
  }
}

private struct ArtefactEditorView: NSViewRepresentable {
  let controller: ChatController
  let version: ArtefactVersion?
  let isEditable: Bool

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = ChatTextView.makeScrollView(role: .artefact, controller: controller)
    if let textView = scrollView.documentView as? ChatTextView {
      textView.setAccessibilityLabel("Artefact")
      controller.artefactView = textView
    }
    controller.display(version)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? ChatTextView else { return }
    textView.isEditable = isEditable
    textView.textColor = isEditable ? .labelColor : .secondaryLabelColor
    controller.display(version)
  }
}

private struct PromptEditorView: NSViewRepresentable {
  let controller: ChatController
  let placeholder: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = ChatTextView.makeScrollView(role: .prompt, controller: controller)
    if let textView = scrollView.documentView as? ChatTextView {
      textView.setAccessibilityLabel("Prompt")
      controller.promptView = textView
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? ChatTextView else { return }
    if textView.placeholder != placeholder {
      textView.placeholder = placeholder
    }
  }
}

private struct TranscriptView: View {
  let transcript: [TranscriptEntry]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(rows, id: \.entry.id) { row in
            TranscriptRowView(entry: row.entry, previousNumber: row.previousNumber)
              .id(row.entry.id)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Popup.horizontalPadding)
        .textSelection(.enabled)
      }
      .excludeFromWindowMovableByBackground()
      .onAppear { scrollToBottom(proxy) }
      .onChange(of: transcript) { scrollToBottom(proxy) }
    }
  }

  // Pairs each entry with the current version before it, to tell undo from redo.
  private var rows: [(entry: TranscriptEntry, previousNumber: Int)] {
    var number = 1
    return transcript.map { entry in
      defer {
        switch entry {
        case .version(_, let newNumber, _, _), .pointer(_, let newNumber):
          number = newNumber
        default:
          break
        }
      }
      return (entry, number)
    }
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy) {
    guard let last = transcript.last else { return }
    proxy.scrollTo(last.id, anchor: .bottom)
  }
}

private struct TranscriptRowView: View {
  let entry: TranscriptEntry
  let previousNumber: Int

  var body: some View {
    switch entry {
    case .user(_, let text):
      message(text, from: "you")
    case .assistant(_, let text):
      message(text, from: "ai")
    case .version, .pointer:
      Text(entry.eventLabel(previousNumber: previousNumber) ?? "")
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    case .error(_, let message):
      Text(message)
        .foregroundStyle(.red)
    }
  }

  private func message(_ text: String, from sender: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(sender)
        .foregroundStyle(.secondary)
        .frame(width: 26, alignment: .leading)
      Text(text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension ArtefactVersion {
  var headerLabel: String {
    switch author {
    case .original: "v\(number) · original"
    case .assistant: "v\(number) · assistant"
    case .user: "v\(number) · you edited"
    }
  }
}

extension TranscriptEntry {
  // "→ v3", "you edited → v4", "restored v2 → v5", "undo → v2", "redo → v3".
  func eventLabel(previousNumber: Int) -> String? {
    switch self {
    case .version(_, let number, _, let restoredFrom?):
      "restored v\(restoredFrom) → v\(number)"
    case .version(_, let number, .user, nil):
      "you edited → v\(number)"
    case .version(_, let number, _, nil):
      "→ v\(number)"
    case .pointer(_, let number):
      "\(number < previousNumber ? "undo" : "redo") → v\(number)"
    default:
      nil
    }
  }
}
