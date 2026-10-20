import AppKit
import Defaults
import Foundation
import Observation
import SwiftData

nonisolated enum ArtefactAuthor: String, Codable, Sendable {
  case original
  case assistant
  case user
}

nonisolated struct ArtefactVersion: Identifiable, Equatable, Codable, Sendable {
  // 1-based; v1 is the original clip.
  let number: Int
  let text: String
  let author: ArtefactAuthor
  let createdAt: Date

  var id: Int { number }
}

nonisolated enum TranscriptEntry: Identifiable, Equatable, Codable, Sendable {
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
// API contract:
// - Every change of the current version writes it to the pasteboard as a
//   transient item.
// - `undoManager`: when set, version changes register undo actions on it so
//   text edits and version changes share one stack. When it has nothing to
//   undo, the UI calls `stepBack()` / `stepForward()`.
// - `close()` cancels a running turn, persists the session (unless "Keep edit
//   history" is off) and, if the current version isn't v1, saves it as a
//   history item linked to the session.
// State lives in memory; it's written to an `EditSession` only on close.
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
  // The history item saved on close, if any.
  @ObservationIgnored private(set) var savedItem: HistoryItem?

  @ObservationIgnored private let provider: (any LLMProvider)?
  @ObservationIgnored private let clipboard: Clipboard
  @ObservationIgnored private let item: HistoryItem
  @ObservationIgnored private var stored: EditSession?
  @ObservationIgnored private var turn: UUID?
  @ObservationIgnored private var turnTask: Task<Void, Never>?
  @ObservationIgnored private var isClosed = false
  // Tools run on the main actor while earlier stream events may still be
  // buffered. A tool's transcript entry is held until the consumer has seen
  // its `.toolCall` event, so it lands after the text streamed before it.
  @ObservationIgnored private var executedTools = 0
  @ObservationIgnored private var seenToolCalls = 0
  @ObservationIgnored private var heldEntries: [(tool: Int, entry: TranscriptEntry)] = []

  // Resumes the session linked to `item` at the version the item corresponds
  // to, or starts a new one with the item's text as v1. Returns nil for clips
  // without text.
  static func open(
    for item: HistoryItem,
    provider: (any LLMProvider)?,
    clipboard: Clipboard = .shared
  ) -> ChatSession? {
    guard let text = item.text else { return nil }

    let session = ChatSession(item: item, provider: provider, clipboard: clipboard)
    if let stored = item.editSession, !stored.isDeleted, case let versions = stored.versions, !versions.isEmpty {
      session.stored = stored
      session.versions = versions
      session.transcript = stored.transcript
      let number = item.editSessionVersion ?? stored.currentNumber
      session.currentNumber = versions.indices.contains(number - 1) ? number : versions.count
    } else {
      session.versions = [ArtefactVersion(number: 1, text: text, author: .original, createdAt: .now)]
    }
    return session
  }

  private init(item: HistoryItem, provider: (any LLMProvider)?, clipboard: Clipboard) {
    self.item = item
    self.provider = provider
    self.clipboard = clipboard
  }

  // Appends the prompt to the transcript and runs one agent turn.
  func send(_ prompt: String) {
    guard !isClosed, !isRunning, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }

    transcript.append(.user(id: UUID(), text: prompt))
    guard let provider else {
      transcript.append(.error(id: UUID(), message: "No AI provider is set up. Choose one in Settings → AI."))
      return
    }

    let turn = UUID()
    self.turn = turn
    executedTools = 0
    seenToolCalls = 0
    isRunning = true
    let stream = provider.run(
      instructions: Self.instructions,
      messages: renderMessages(),
      tools: ArtefactTools.make(for: self, turn: turn)
    )
    turnTask = Task { [weak self] in
      await self?.consume(stream, turn: turn)
    }
  }

  // Cancels the running turn, keeping whatever has streamed so far.
  func cancel() {
    guard let turnTask else { return }
    turnTask.cancel()
    endTurn()
  }

  // Appends `text` as a user-authored version, unless it equals the current one.
  func commitManualEdit(_ text: String) {
    guard !isClosed, text != current?.text else { return }
    appendVersion(text, author: .user, restoredFrom: nil)
  }

  // Moves the current-version pointer; returns false at the ends.
  @discardableResult
  func stepBack() -> Bool { step(to: currentNumber - 1) }

  @discardableResult
  func stepForward() -> Bool { step(to: currentNumber + 1) }

  func close() {
    guard !isClosed else { return }
    cancel()
    isClosed = true
    undoManager?.removeAllActions(withTarget: self)

    let session = Defaults[.keepEditHistory] ? persist() : nil
    if currentNumber != 1, let current {
      saveToHistory(current, linkingTo: session)
    }
    if session != nil {
      Storage.shared.deleteOrphanedEditSessions()
    }
  }

  // MARK: Tools

  func writeArtefact(_ text: String, turn: UUID) throws -> String {
    guard self.turn == turn else { throw CancellationError() }
    executedTools += 1
    guard text != current?.text else {
      return "The text is identical to v\(currentNumber), so no new version was created."
    }

    appendVersion(text, author: .assistant, restoredFrom: nil)
    return "Saved as v\(currentNumber), which is now the current version."
  }

  func restoreVersion(_ number: Int, turn: UUID) throws -> String {
    guard self.turn == turn else { throw CancellationError() }
    executedTools += 1
    guard let version = versions.first(where: { $0.number == number }) else {
      return "Error: v\(number) doesn't exist. Versions are v1 to v\(versions.count)."
    }
    guard number != currentNumber else {
      return "v\(number) is already the current version."
    }

    appendVersion(version.text, author: .assistant, restoredFrom: number)
    return "Restored v\(number) as v\(currentNumber), which is now the current version."
  }

  // MARK: Turn

  private func consume(_ stream: AsyncThrowingStream<LLMEvent, Error>, turn: UUID) async {
    do {
      for try await event in stream {
        guard self.turn == turn else { return }
        switch event {
        case .textDelta(let delta):
          appendAssistantText(delta)
        case .toolCall:
          seenToolCalls += 1
          releaseHeldEntries(upTo: seenToolCalls)
        case .toolResult:
          break
        }
      }
    } catch {
      if self.turn == turn, !(error is CancellationError) {
        releaseHeldEntries()
        transcript.append(.error(id: UUID(), message: error.localizedDescription))
      }
    }

    guard self.turn == turn else { return }
    endTurn()
  }

  private func endTurn() {
    releaseHeldEntries()
    turn = nil
    turnTask = nil
    isRunning = false
  }

  private func releaseHeldEntries(upTo tool: Int = .max) {
    while let first = heldEntries.first, first.tool <= tool {
      transcript.append(first.entry)
      heldEntries.removeFirst()
    }
  }

  private func appendAssistantText(_ delta: String) {
    if case .assistant(let id, let text) = transcript.last {
      transcript[transcript.count - 1] = .assistant(id: id, text: text + delta)
    } else {
      transcript.append(.assistant(id: UUID(), text: delta))
    }
  }

  // MARK: Versions

  private func appendVersion(_ text: String, author: ArtefactAuthor, restoredFrom: Int?) {
    let version = ArtefactVersion(number: versions.count + 1, text: text, author: author, createdAt: .now)
    versions.append(version)
    let entry = TranscriptEntry.version(id: UUID(), number: version.number, author: author, restoredFrom: restoredFrom)
    if turn != nil, author == .assistant, seenToolCalls < executedTools {
      heldEntries.append((executedTools, entry))
    } else {
      transcript.append(entry)
    }

    let previous = currentNumber
    currentNumber = version.number
    copyCurrent()
    registerUndo(movingTo: previous)
  }

  private func step(to number: Int) -> Bool {
    guard !isClosed, versions.indices.contains(number - 1) else { return false }
    movePointer(to: number)
    return true
  }

  private func movePointer(to number: Int) {
    currentNumber = number
    transcript.append(.pointer(id: UUID(), number: number))
    copyCurrent()
  }

  // Undoing moves the pointer back; the undo action registers its own inverse,
  // which the undo manager files as redo.
  private func registerUndo(movingTo number: Int) {
    undoManager?.registerUndo(withTarget: self) { session in
      MainActor.assumeIsolated {
        guard !session.isClosed, session.currentNumber != number,
              session.versions.indices.contains(number - 1) else {
          return
        }
        let previous = session.currentNumber
        session.movePointer(to: number)
        session.registerUndo(movingTo: previous)
      }
    }
  }

  private func copyCurrent() {
    guard let current else { return }
    clipboard.copyUnrecorded(current.text, transient: true)
  }

  // MARK: Persistence

  private func persist() -> EditSession? {
    guard stored != nil || versions.count > 1 || !transcript.isEmpty else { return nil }

    let session: EditSession
    if let stored {
      session = stored
    } else {
      session = EditSession()
      Storage.shared.context.insert(session)
      if !item.isDeleted, item.modelContext != nil {
        item.editSession = session
        item.editSessionVersion = 1
      }
    }

    session.versions = versions
    session.transcript = transcript
    session.currentNumber = currentNumber
    session.updatedAt = .now
    return session
  }

  private func saveToHistory(_ version: ArtefactVersion, linkingTo session: EditSession?) {
    let historyItem = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(version.text.utf8)),
      HistoryItemContent(type: NSPasteboard.PasteboardType.fromScratchboard.rawValue, value: Data())
    ])
    Storage.shared.context.insert(historyItem)
    historyItem.application = Bundle.main.bundleIdentifier
    historyItem.title = historyItem.generateTitle()
    if let session {
      historyItem.editSession = session
      historyItem.editSessionVersion = version.number
    }

    clipboard.copyUnrecorded(version.text, transient: false)
    savedItem = History.shared.add(historyItem).item
  }
}
