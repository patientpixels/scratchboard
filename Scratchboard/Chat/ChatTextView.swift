import AppKit
import Sauce

// The chat's keys (docs/plan-v0.1.md → Interaction), resolved per text view.
// Keys without an action are left to NSTextView (↩ inserts a newline, Tab in
// the artefact inserts a tab).
enum ChatKeyAction: Equatable {
  case send
  case close
  case copySelection
  case undo
  case redo
  case focusArtefact
  case focusPrompt
  case openPreferences
  case cut
  case paste
  case selectAll

  init?(key: Key, modifiers: NSEvent.ModifierFlags, role: ChatTextView.Role, hasSelection: Bool) {
    switch (key, modifiers) {
    case (.return, [.command]), (.keypadEnter, [.command]):
      self = .send
    case (.escape, _):
      self = .close
    case (.c, [.command]):
      self = hasSelection ? .copySelection : .close
    case (.z, [.command]):
      self = .undo
    case (.z, [.command, .shift]):
      self = .redo
    case (.tab, []) where role == .prompt,
         (.tab, [.shift]) where role == .prompt:
      self = .focusArtefact
    case (.tab, [.shift]) where role == .artefact:
      self = .focusPrompt
    case (.comma, [.command]):
      self = .openPreferences
    case (.x, [.command]):
      self = .cut
    case (.v, [.command]):
      self = .paste
    case (.a, [.command]):
      self = .selectAll
    default:
      return nil
    }
  }
}

final class ChatTextView: NSTextView {
  enum Role {
    case artefact
    case prompt
  }

  var role: Role = .prompt
  weak var controller: ChatController?
  var onResignFirstResponder: (() -> Void)?

  var placeholder: String? {
    didSet { needsDisplay = true }
  }

  static func makeScrollView(role: Role, controller: ChatController) -> NSScrollView {
    let textView = ChatTextView(usingTextLayoutManager: true)
    textView.role = role
    textView.controller = controller
    textView.delegate = controller
    textView.isEditable = true
    textView.isSelectable = true
    textView.allowsUndo = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.drawsBackground = false
    textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    textView.textColor = .labelColor
    textView.textContainerInset = NSSize(width: 0, height: 2)
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false

    let scrollView = NSScrollView()
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    return scrollView
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if window?.firstResponder === self, handle(event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if handle(event) {
      return
    }
    super.keyDown(with: event)
  }

  private func handle(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown,
          !hasMarkedText(),
          let controller,
          let (key, modifiers) = KeyChord.keyAndModifiers(event),
          let action = ChatKeyAction(
            key: key,
            modifiers: modifiers,
            role: role,
            hasSelection: selectedRanges.contains { $0.rangeValue.length > 0 }
          ) else {
      return false
    }

    controller.perform(action, in: self)
    return true
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned {
      onResignFirstResponder?()
    }
    return resigned
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    controller?.textViewDidMoveToWindow(self)
  }

  override func didChangeText() {
    super.didChangeText()
    if placeholder != nil {
      needsDisplay = true
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard string.isEmpty, let placeholder else { return }
    let origin = textContainerOrigin
    let rect = NSRect(
      x: origin.x,
      y: origin.y,
      width: bounds.width - origin.x * 2,
      height: bounds.height - origin.y
    )
    (placeholder as NSString).draw(
      with: rect,
      options: [.usesLineFragmentOrigin],
      attributes: [
        .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        .foregroundColor: NSColor.placeholderTextColor
      ]
    )
  }
}
