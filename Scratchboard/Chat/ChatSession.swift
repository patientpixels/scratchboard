import AppKit
import Foundation
import Observation

enum ArtefactAuthor: String, Codable, Sendable {
  case original
  case assistant
  case user
}

struct ArtefactVersion: Identifiable, Equatable, Sendable {
  // 1-based; v1 is the original clip.
  let number: Int
  let text: String
  let author: ArtefactAuthor
  let createdAt: Date

  var id: Int { number }
}

enum TranscriptEntry: Identifiable, Equatable, Sendable {
  case user(id: UUID, text: String)
  // Grows while streaming.
  case assistant(id: UUID, text: String)
  // A new version was appended ("→ v3", "you edited → v4", "restored v2 → v5").
  case version(id: UUID, number: Int, author: ArtefactAuthor, restoredFrom: Int?)
  // The current-version pointer moved via undo/redo ("undo → v2").
  case pointer(id: UUID, number: Int)
  case error(id: UUID, message: String)

  var id: UUID {
    switch self {
    case .user(let id, _), .assistant(let id, _), .version(let id, _, _, _),
         .pointer(let id, _), .error(let id, _):
      return id
    }
  }
}

// Runtime controller for one edit session on a clip: an append-only list of
// artefact versions, a current-version pointer, and a transcript. See
// docs/plan-v0.1.md.
//
// API contract (UI builds against this; bodies are implemented separately):
// - Every change of the current version writes it to the pasteboard as a
//   transient item.
// - `undoManager`: when set, version changes register undo actions on it so
//   text edits and version changes share one stack. When it has nothing to
//   undo, the UI calls `stepBack()` / `stepForward()`.
// - `close()` cancels a running turn, commits pending state, persists the
//   session (unless "Keep edit history" is off) and, if the current version
//   isn't v1, saves it as a history item linked to the session.
@MainActor
@Observable
final class ChatSession {
  private(set) var versions: [ArtefactVersion] = []
  private(set) var currentNumber: Int = 1
  private(set) var transcript: [TranscriptEntry] = []
  private(set) var isRunning = false

  var current: ArtefactVersion? { versions.first { $0.number == currentNumber } }
  var providerName: String? { provider?.displayName }

  @ObservationIgnored weak var undoManager: UndoManager?
  @ObservationIgnored private let provider: (any LLMProvider)?

  // Resumes the session linked to `item`, or starts a new one with the
  // item's text as v1. Returns nil for clips without text.
  static func open(for item: HistoryItem, provider: (any LLMProvider)?) -> ChatSession? {
    guard let text = item.text else { return nil }
    let session = ChatSession(provider: provider)
    session.versions = [ArtefactVersion(number: 1, text: text, author: .original, createdAt: .now)]
    return session
  }

  private init(provider: (any LLMProvider)?) {
    self.provider = provider
  }

  // Appends the prompt to the transcript and runs one agent turn.
  func send(_ prompt: String) {}

  // Cancels the running turn, keeping whatever has streamed so far.
  func cancel() {}

  // Appends `text` as a user-authored version, unless it equals the current one.
  func commitManualEdit(_ text: String) {}

  // Moves the current-version pointer; returns false at the ends.
  @discardableResult
  func stepBack() -> Bool { false }

  @discardableResult
  func stepForward() -> Bool { false }

  func close() {}
}
