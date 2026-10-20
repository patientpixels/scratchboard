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

  // Sync on purpose: an async setUp runs inside a main-queue block, so the
  // main-queue work ChatController schedules would never run while spinning.
  private func setUpChat() throws {
    History.shared.clearAll()
    let item = History.shared.add(textItem("hello"))
    appState.navigator.select(item: item)
    appState.startChat()
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
    MainActor.assumeIsolated {
      AppState.shared.endChat()
      History.shared.clearAll()
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
    let characters: String
    switch key {
    case .tab: characters = modifiers.contains(.shift) ? "\u{19}" : "\t"
    case .return: characters = "\r"
    case .escape: characters = "\u{1b}"
    default: characters = key.rawValue
    }
    let event = NSEvent.keyEvent(
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
    // Mirrors NSApplication: key equivalents first, then the first responder.
    // The window isn't key, so NSWindow.sendEvent would drop the event.
    if modifiers.contains(.command), window.performKeyEquivalent(with: event) {
      return
    }
    window.firstResponder?.keyDown(with: event)
    spinRunLoop()
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
