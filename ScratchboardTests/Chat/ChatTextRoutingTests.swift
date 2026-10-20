import AppKit
import Sauce
import XCTest
@testable import Scratchboard

// Drives the chat's text views (as ChatView sets them up) with key events in a
// plain window. ChatSession bodies are out of scope; only routing is checked.
@MainActor
final class ChatTextRoutingTests: XCTestCase {
  private let appState = AppState.shared
  private var window: NSWindow!
  private var controller: ChatController!
  private var artefact: ChatTextView!
  private var prompt: ChatTextView!
  // XCTest creates an instance per test, so each test gets its own pasteboard.
  private nonisolated let pasteboardName = NSPasteboard.Name("ScratchboardTests.\(UUID().uuidString)")

  // Sync on purpose: an async setUp runs inside a main-queue block, so the
  // main-queue work ChatController schedules would never run while spinning.
  private func setUpChat() throws {
    History.shared.clearAll()
    // Not added to History.shared: the test host's (never shown) panel renders
    // that list whenever the run loop spins, and keeps removed rows alive. A
    // row for an item deleted by `clearAll()` after closing the chat linked it
    // to an edit session would be re-rendered and crash on its contents.
    let item = HistoryItemDecorator(textItem("hello"))
    appState.navigator.select(item: item)
    appState.startChat(provider: { nil }, clipboard: Clipboard(pasteboard: NSPasteboard(name: pasteboardName)))
    let session = try XCTUnwrap(appState.chat)

    controller = ChatController(session: session)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false

    let artefactScrollView = ChatTextView.makeScrollView(role: .artefact, controller: controller)
    let promptScrollView = ChatTextView.makeScrollView(role: .prompt, controller: controller)
    artefact = try XCTUnwrap(artefactScrollView.documentView as? ChatTextView)
    prompt = try XCTUnwrap(promptScrollView.documentView as? ChatTextView)
    controller.artefactView = artefact
    controller.promptView = prompt
    controller.display(session.current)

    artefactScrollView.frame = NSRect(x: 0, y: 200, width: 400, height: 200)
    promptScrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    contentView.addSubview(artefactScrollView)
    contentView.addSubview(promptScrollView)
    window.contentView = contentView
    spinRunLoop()
  }

  override func tearDown() {
    let pasteboardName = pasteboardName
    MainActor.assumeIsolated {
      AppState.shared.endChat()
      AppState.shared.lastChat = nil
      AppState.shared.navigator.select(item: nil)
      History.shared.clearAll()
      NSPasteboard(name: pasteboardName).releaseGlobally()
    }
    super.tearDown()
  }

  func testSetup() throws {
    try setUpChat()
    XCTAssertEqual(artefact.string, "hello")
    XCTAssertTrue(window.firstResponder === prompt)
    XCTAssertNotNil(window.undoManager)
    XCTAssertTrue(prompt.undoManager === window.undoManager)
    XCTAssertTrue(artefact.undoManager === window.undoManager)
  }

  func testTabMovesFocus() throws {
    try setUpChat()
    press(.tab)
    XCTAssertTrue(window.firstResponder === artefact)

    artefact.setSelectedRange(NSRange(location: 0, length: 0))
    press(.tab)
    XCTAssertTrue(window.firstResponder === artefact)
    XCTAssertEqual(artefact.string, "\thello")

    press(.tab, [.shift])
    XCTAssertTrue(window.firstResponder === prompt)
  }

  func testReturnInsertsNewlineAndCommandReturnSends() throws {
    try setUpChat()
    prompt.insertText("hi", replacementRange: prompt.selectedRange())

    press(.return)
    XCTAssertEqual(prompt.string, "hi\n")

    press(.return, [.command])
    XCTAssertEqual(prompt.string, "")
    XCTAssertNotNil(appState.chat)
  }

  func testEscapeCloses() throws {
    try setUpChat()
    press(.escape)
    XCTAssertNil(appState.chat)
  }

  func testCommandCWithoutSelectionCloses() throws {
    try setUpChat()
    press(.c, [.command])
    XCTAssertNil(appState.chat)
  }

  func testCommandCWithSelectionCopiesTransientAndKeepsResume() throws {
    try setUpChat()
    let session = try XCTUnwrap(appState.chat)
    press(.tab)
    artefact.setSelectedRange(NSRange(location: 0, length: 3))

    press(.c, [.command])

    XCTAssertTrue(appState.chat === session)
    let pasteboard = NSPasteboard(name: pasteboardName)
    XCTAssertEqual(pasteboard.string(forType: .string), "hel")
    XCTAssertTrue(pasteboard.types?.contains(.transient) ?? false)
    XCTAssertTrue(session.isLastWriteOnPasteboard)

    appState.endChat()
    appState.prepareResume()
    appState.startChat(provider: { nil }, clipboard: Clipboard(pasteboard: NSPasteboard(name: pasteboardName)))
    XCTAssertTrue(appState.chat === session)
  }

  func testCommandCWithPromptSelectionCopiesTransient() throws {
    try setUpChat()
    prompt.insertText("make it short", replacementRange: prompt.selectedRange())
    prompt.setSelectedRange(NSRange(location: 8, length: 5))

    press(.c, [.command])

    XCTAssertNotNil(appState.chat)
    let pasteboard = NSPasteboard(name: pasteboardName)
    XCTAssertEqual(pasteboard.string(forType: .string), "short")
    XCTAssertTrue(pasteboard.types?.contains(.transient) ?? false)
  }

  // Stands in for the transcript: any other text view in the chat's window.
  func testCommandCElsewhereCopiesSelectionTransient() throws {
    try setUpChat()
    let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    other.string = "assistant reply"
    window.contentView?.addSubview(other)
    window.makeFirstResponder(other)
    other.setSelectedRange(NSRange(location: 10, length: 5))

    controller.copyOrClose(in: window, event: keyEvent(.c, [.command]))

    XCTAssertNotNil(appState.chat)
    let pasteboard = NSPasteboard(name: pasteboardName)
    XCTAssertEqual(pasteboard.string(forType: .string), "reply")
    XCTAssertTrue(pasteboard.types?.contains(.transient) ?? false)
  }

  func testCommandCElsewhereWithoutSelectionCloses() throws {
    try setUpChat()
    let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    other.string = "assistant reply"
    window.contentView?.addSubview(other)
    window.makeFirstResponder(other)

    controller.copyOrClose(in: window, event: keyEvent(.c, [.command]))

    XCTAssertNil(appState.chat)
  }

  func testUndoRevertsPromptTyping() throws {
    try setUpChat()
    prompt.insertText("hi", replacementRange: prompt.selectedRange())
    XCTAssertTrue(window.undoManager?.canUndo ?? false)

    press(.z, [.command])
    XCTAssertEqual(prompt.string, "")
    XCTAssertNotNil(appState.chat)
  }

  func testVersionChangeDropsStaleTypingUndo() throws {
    try setUpChat()
    press(.tab)
    artefact.insertText("!", replacementRange: NSRange(location: 5, length: 0))
    XCTAssertTrue(window.undoManager?.canUndo ?? false)

    controller.display(ArtefactVersion(number: 2, text: "other", author: .assistant, createdAt: .now))
    spinRunLoop()

    XCTAssertEqual(artefact.string, "other")

    // The typing undo for "hello!" must not be applied to "other".
    press(.z, [.command])
    XCTAssertEqual(artefact.string, "other")
  }

  // MARK: Helpers

  private func press(_ key: Key, _ modifiers: NSEvent.ModifierFlags = []) {
    let event = keyEvent(key, modifiers)
    // Mirrors NSApplication: key equivalents first, then the first responder.
    // The window isn't key, so NSWindow.sendEvent would drop the event.
    if modifiers.contains(.command), window.performKeyEquivalent(with: event) {
      return
    }
    window.firstResponder?.keyDown(with: event)
    spinRunLoop()
  }

  private func keyEvent(_ key: Key, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    let characters: String
    switch key {
    case .tab: characters = modifiers.contains(.shift) ? "\u{19}" : "\t"
    case .return: characters = "\r"
    case .escape: characters = "\u{1b}"
    default: characters = key.rawValue
    }
    return NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: Sauce.shared.keyCode(for: key)
    )!
  }

  private func spinRunLoop() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  }

  private func textItem(_ value: String) -> HistoryItem {
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: value.data(using: .utf8))
    ]
    item.numberOfCopies = 1
    item.title = item.generateTitle()
    return item
  }
}
