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

// What an artefact's text is: plain text, or editing HTML for rich text clips
// (tables, formatting; see RichText).
nonisolated enum ArtefactFormat: String, Codable, Sendable {
  case plain
  case html
}

nonisolated struct ArtefactVersion: Identifiable, Equatable, Codable, Sendable {
  // 1-based; v1 is the original clip.
  let number: Int
  let text: String
  let author: ArtefactAuthor
  let createdAt: Date
  // Missing in sessions stored before rich text clips: plain.
  let format: ArtefactFormat

  var id: Int { number }

  init(number: Int, text: String, author: ArtefactAuthor, createdAt: Date, format: ArtefactFormat = .plain) {
    self.number = number
    self.text = text
    self.author = author
    self.createdAt = createdAt
    self.format = format
  }

  private enum CodingKeys: String, CodingKey {
    case number, text, author, createdAt, format
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    number = try container.decode(Int.self, forKey: .number)
    text = try container.decode(String.self, forKey: .text)
    author = try container.decode(ArtefactAuthor.self, forKey: .author)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    format = try container.decodeIfPresent(ArtefactFormat.self, forKey: .format) ?? .plain
  }
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
//   transient item. Rich text sessions (`format == .html`) write HTML, RTF
//   and plain text; plain ones plain text only.
// - `undoManager`: when set, version changes register undo actions on it so
//   text edits and version changes share one stack. When it has nothing to
//   undo, the UI calls `stepBack()` / `stepForward()`.
// - `close()` cancels a running turn, persists the session (unless "Keep edit
//   history" is off) and, if the current version isn't v1, saves it as a
//   history item linked to the session.
// - `reopen()` makes a closed session usable again (the panel resumes the last
//   chat while `isLastWriteOnPasteboard`). Closing it again updates the same
//   stored session and saves the current version only if it isn't saved yet.
// - Assistant text is sanitized: artefact blocks and echoed prompt lines never
//   reach the transcript.
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
  // Plain text, or editing HTML for clips with tables or formatting.
  let format: ArtefactFormat

  // True while the pasteboard still holds the session's last write (a
  // version, the saved final version or a copied selection), i.e. nothing
  // else has been copied since.
  var isLastWriteOnPasteboard: Bool {
    lastWriteChangeCount == clipboard.pasteboardChangeCount
  }

  // The clip Tab resumes this session from: the saved final version, or the
  // clip the session started from.
  var resumeItem: HistoryItem { savedItem ?? item }

  func belongs(to historyItem: HistoryItem) -> Bool {
    historyItem == item || historyItem == savedItem
  }

  @ObservationIgnored weak var undoManager: UndoManager?
  // The history item saved on close, if any.
  @ObservationIgnored private(set) var savedItem: HistoryItem?
  @ObservationIgnored private var savedNumber: Int?
  @ObservationIgnored private var lastWriteChangeCount: Int?
  @ObservationIgnored private var lastWriteIsSelection = false

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
  // The raw text streamed into the current assistant entry, which shows it
  // sanitized. The segment began when the transcript had `start` entries; it
  // has an entry only once something visible is left.
  @ObservationIgnored private var assistantSegment = (start: -1, id: UUID(), raw: "")
  // Pasteboard representations of HTML versions (versions never change), and
  // versions that couldn't be converted and went out as plain text.
  @ObservationIgnored private var representations: [Int: RichText.Representations] = [:]
  @ObservationIgnored private var failedConversions: Set<Int> = []

  // Resumes the session linked to `item` at the version the item corresponds
  // to, or starts a new one with the item's text as v1: as editing HTML if
  // the clip has tables or formatting (RTF or HTML content), else as plain
  // text. Returns nil for clips without text.
  static func open(
    for item: HistoryItem,
    provider: (any LLMProvider)?,
    clipboard: Clipboard = .shared
  ) -> ChatSession? {
    guard let text = item.text else { return nil }

    if let stored = item.editSession, !stored.isDeleted, case let versions = stored.versions, !versions.isEmpty {
      let session = ChatSession(item: item, format: versions[0].format, provider: provider, clipboard: clipboard)
      session.stored = stored
      session.versions = versions
      session.transcript = stored.transcript
      let number = item.editSessionVersion ?? stored.currentNumber
      session.currentNumber = versions.indices.contains(number - 1) ? number : versions.count
      return session
    }

    let content = RichText.editingHTML(rtf: item.rtfData, html: item.htmlData)
    if case .rich(let html) = content {
      let session = ChatSession(item: item, format: .html, provider: provider, clipboard: clipboard)
      session.versions = [ArtefactVersion(number: 1, text: html, author: .original, createdAt: .now, format: .html)]
      return session
    }

    let session = ChatSession(item: item, format: .plain, provider: provider, clipboard: clipboard)
    session.versions = [ArtefactVersion(number: 1, text: text, author: .original, createdAt: .now)]
    if content == .failed {
      session.transcript = [.error(
        id: UUID(),
        message: "Couldn't read the clip's formatting, so it's edited as plain text."
      )]
    }
    return session
  }

  private init(item: HistoryItem, format: ArtefactFormat, provider: (any LLMProvider)?, clipboard: Clipboard) {
    self.item = item
    self.format = format
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
      instructions: format == .html ? Self.htmlInstructions : Self.instructions,
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

  // Appends `text` (editing HTML in rich text sessions, see
  // `RichText.html(from:)`) as a user-authored version, unless it equals the
  // current one.
  func commitManualEdit(_ text: String) {
    guard !isClosed, text != current?.text else { return }
    appendVersion(text, author: .user, restoredFrom: nil, format: format)
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
    if currentNumber != 1, let current, !isSaved(current) {
      saveToHistory(current, linkingTo: session)
    }
    if session != nil {
      Storage.shared.deleteOrphanedEditSessions()
    }
  }

  // Makes a closed session usable again, at its current version. The undo
  // stack starts empty, as when reopening a stored session.
  func reopen() {
    isClosed = false
  }

  // Writes text selected in the chat to the pasteboard. It's scratch work, so
  // it's transient and doesn't end up in history.
  func copySelection(_ text: String) {
    write(text, transient: true, isSelection: true)
  }

  // MARK: Tools

  func writeArtefact(_ text: String, turn: UUID) throws -> String {
    guard self.turn == turn else { throw CancellationError() }
    executedTools += 1
    var text = Self.unwrapArtefactTags(text)
    // HTML is brought into the allowed subset, so every version converts
    // cleanly for pasting. Unreadable HTML is kept as written.
    if format == .html, let html = RichText.normalize(text) {
      text = html
    }
    guard text != current?.text else {
      return "The text is identical to v\(currentNumber), so no new version was created."
    }

    appendVersion(text, author: .assistant, restoredFrom: nil, format: format)
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

    appendVersion(version.text, author: .assistant, restoredFrom: number, format: version.format)
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
          showAssistantText(streaming: false)
          seenToolCalls += 1
          releaseHeldEntries(upTo: seenToolCalls)
        case .toolResult:
          break
        }
      }
    } catch {
      if self.turn == turn, !(error is CancellationError) {
        showAssistantText(streaming: false)
        releaseHeldEntries()
        transcript.append(.error(id: UUID(), message: error.localizedDescription))
      }
    }

    guard self.turn == turn else { return }
    endTurn()
  }

  private func endTurn() {
    showAssistantText(streaming: false)
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
    if !isInAssistantSegment {
      assistantSegment = (transcript.count, UUID(), "")
    }
    assistantSegment.raw += delta
    showAssistantText(streaming: true)
  }

  // Text streams into the last assistant entry until another entry follows.
  private var isInAssistantSegment: Bool {
    let (start, id, _) = assistantSegment
    return transcript.count == start || (transcript.count == start + 1 && transcript.last?.id == id)
  }

  // While streaming, a trailing partial artefact tag or echo line is held
  // back; once the text is complete (end of turn, tool call), it's shown.
  private func showAssistantText(streaming: Bool) {
    guard isInAssistantSegment else { return }
    let (start, id, raw) = assistantSegment
    let text = Self.sanitizeAssistantText(raw, streaming: streaming)
    let isVisible = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    switch (transcript.count > start, isVisible) {
    case (true, true): transcript[start] = .assistant(id: id, text: text)
    case (true, false): transcript.removeLast()
    case (false, true): transcript.append(.assistant(id: id, text: text))
    case (false, false): break
    }
  }

  // MARK: Versions

  private func appendVersion(_ text: String, author: ArtefactAuthor, restoredFrom: Int?, format: ArtefactFormat) {
    let version = ArtefactVersion(
      number: versions.count + 1, text: text, author: author, createdAt: .now, format: format
    )
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

  // Writes the current version to the pasteboard (transient), e.g. to replace
  // a selection copied from the chat.
  func copyCurrent() {
    guard let current else { return }
    write(current, transient: true)
  }

  private func write(_ version: ArtefactVersion, transient: Bool) {
    if let rich = pasteboardRepresentations(of: version) {
      write(rich.plain, html: rich.html, rtf: rich.rtf, transient: transient)
    } else {
      write(version.text, transient: transient)
    }
  }

  private func write(
    _ text: String,
    html: String? = nil,
    rtf: Data? = nil,
    transient: Bool,
    isSelection: Bool = false
  ) {
    clipboard.copyUnrecorded(text, html: html, rtf: rtf, transient: transient)
    lastWriteChangeCount = clipboard.pasteboardChangeCount
    lastWriteIsSelection = isSelection
  }

  // HTML, RTF and plain text for an HTML version; nil for plain versions and
  // versions that can't be converted, which go out as plain text (with an
  // error in the transcript, once per version).
  private func pasteboardRepresentations(of version: ArtefactVersion) -> RichText.Representations? {
    guard version.format == .html, !failedConversions.contains(version.number) else { return nil }
    if let cached = representations[version.number] {
      return cached
    }
    guard let converted = RichText.representations(forHTML: version.text) else {
      failedConversions.insert(version.number)
      let entry = TranscriptEntry.error(
        id: UUID(),
        message: "Couldn't convert v\(version.number) to formatted text, so it's on the clipboard as plain text."
      )
      // Written by a tool whose version entry is still held: after it.
      if turn != nil, seenToolCalls < executedTools {
        heldEntries.append((executedTools, entry))
      } else {
        transcript.append(entry)
      }
      return nil
    }
    representations[version.number] = converted
    return converted
  }

  // MARK: Persistence

  private func persist() -> EditSession? {
    guard stored != nil || versions.count > 1 || !transcript.isEmpty else { return nil }

    let session: EditSession
    if let stored, !stored.isDeleted {
      session = stored
    } else {
      session = EditSession()
      Storage.shared.context.insert(session)
      if !item.isDeleted, item.modelContext != nil {
        item.editSession = session
        item.editSessionVersion = 1
      }
      // Closing a reopened session updates this one.
      stored = session
    }

    session.versions = versions
    session.transcript = transcript
    session.currentNumber = currentNumber
    session.updatedAt = .now
    return session
  }

  private func saveToHistory(_ version: ArtefactVersion, linkingTo session: EditSession?) {
    var contents: [HistoryItemContent] = []
    if let rich = pasteboardRepresentations(of: version) {
      contents = [
        HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: rich.rtf),
        HistoryItemContent(type: NSPasteboard.PasteboardType.html.rawValue, value: Data(rich.html.utf8)),
        HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(rich.plain.utf8))
      ]
    } else {
      contents = [HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(version.text.utf8))]
    }
    contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.fromScratchboard.rawValue, value: Data()))
    let historyItem = HistoryItem(contents: contents)
    Storage.shared.context.insert(historyItem)
    historyItem.application = Bundle.main.bundleIdentifier
    historyItem.title = historyItem.generateTitle()
    if let session {
      historyItem.editSession = session
      historyItem.editSessionVersion = version.number
    }

    // A selection copied last is what the user wants to paste next.
    if !(lastWriteIsSelection && isLastWriteOnPasteboard) {
      write(version, transient: false)
    }
    savedItem = History.shared.add(historyItem).item
    savedNumber = version.number
  }

  // Whether an earlier close of this (reopened) session already saved `version`.
  private func isSaved(_ version: ArtefactVersion) -> Bool {
    guard let savedItem, !savedItem.isDeleted, savedItem.modelContext != nil else { return false }
    return savedNumber == version.number
  }
}
