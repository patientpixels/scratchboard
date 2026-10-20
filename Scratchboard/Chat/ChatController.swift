import AppKit

// Glue between ChatView's two text views and the ChatSession: key actions,
// focus, committing manual artefact edits and the shared undo stack.
final class ChatController: NSObject, NSTextViewDelegate {
  let session: ChatSession

  weak var artefactView: ChatTextView? {
    didSet {
      artefactView?.onResignFirstResponder = { [weak self] in self?.commitArtefact() }
    }
  }
  weak var promptView: ChatTextView?

  private var displayedVersion: Int?
  private weak var observedWindow: NSWindow?
  private var didFocusPrompt = false

  // Edits must not reach a session that was closed, e.g. while views tear down.
  private var isActive: Bool { AppState.shared.chat === session }

  init(session: ChatSession) {
    self.session = session
  }

  func perform(_ action: ChatKeyAction, in textView: ChatTextView) {
    switch action {
    case .send:
      send()
    case .close:
      close()
    case .copySelection:
      textView.copy(nil)
    case .undo:
      undo(with: textView.undoManager)
    case .redo:
      redo(with: textView.undoManager)
    case .focusArtefact:
      focus(artefactView)
    case .focusPrompt:
      focus(promptView)
    case .openPreferences:
      AppState.shared.openPreferences()
    case .cut:
      textView.cut(nil)
    case .paste:
      textView.paste(nil)
    case .selectAll:
      textView.selectAll(nil)
    }
  }

  func send() {
    commitArtefact()
    guard isActive, !session.isRunning, let promptView else { return }

    let prompt = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }

    session.send(prompt)
    replaceText(in: promptView, with: "")
  }

  func close() {
    commitArtefact()
    let appState = AppState.shared
    appState.endChat()
    appState.popup.close()
  }

  func commitArtefact() {
    guard isActive, let artefactView, artefactView.isEditable else { return }
    session.commitManualEdit(artefactView.string)
  }

  func undo(with undoManager: UndoManager?) {
    guard isActive else { return }
    breakUndoCoalescing()
    if let undoManager, undoManager.canUndo {
      undoManager.undo()
    } else {
      session.stepBack()
    }
  }

  func redo(with undoManager: UndoManager?) {
    guard isActive else { return }
    breakUndoCoalescing()
    if let undoManager, undoManager.canRedo {
      undoManager.redo()
    } else {
      session.stepForward()
    }
  }

  // Shows `version` in the artefact editor when the current version changed.
  func display(_ version: ArtefactVersion?) {
    guard let artefactView, displayedVersion != version?.number else { return }
    displayedVersion = version?.number
    replaceText(in: artefactView, with: version?.text ?? "")
  }

  func textViewDidMoveToWindow(_ textView: ChatTextView) {
    guard let window = textView.window else { return }

    session.undoManager = window.undoManager

    if observedWindow !== window {
      if let observedWindow {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow)
      }
      observedWindow = window
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(windowWillClose(_:)),
        name: NSWindow.willCloseNotification,
        object: window
      )
    }

    // SwiftUI may still move the view around; focus once it has settled.
    if textView.role == .prompt, !didFocusPrompt {
      DispatchQueue.main.async { [weak self] in
        guard let self, !didFocusPrompt else { return }
        didFocusPrompt = focus(promptView)
      }
    }
  }

  // The popup closes on outside clicks without the editor losing focus.
  @objc private func windowWillClose(_ notification: Notification) {
    commitArtefact()
  }

  @discardableResult
  private func focus(_ textView: ChatTextView?) -> Bool {
    guard let textView, let window = textView.window else { return false }
    return window.makeFirstResponder(textView)
  }

  private func breakUndoCoalescing() {
    artefactView?.breakUndoCoalescing()
    promptView?.breakUndoCoalescing()
  }

  private func replaceText(in textView: ChatTextView, with text: String) {
    if textView.string != text {
      textView.string = text
      textView.setSelectedRange(NSRange(location: 0, length: 0))
      textView.scrollToBeginningOfDocument(nil)
    }
    textView.breakUndoCoalescing()

    // The view's typing undo actions refer to the old text. Drop them once the
    // current undo/redo (which may have caused this change) has finished.
    DispatchQueue.main.async { [weak textView] in
      guard let textView, let storage = textView.textStorage else { return }
      textView.undoManager?.removeAllActions(withTarget: storage)
    }
  }

  // MARK: NSTextViewDelegate

  // Text edits and version changes share the window's undo stack.
  func undoManager(for view: NSTextView) -> UndoManager? {
    view.window?.undoManager
  }
}
