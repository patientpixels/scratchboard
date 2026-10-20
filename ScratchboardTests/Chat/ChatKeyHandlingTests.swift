import AppKit
import Sauce
import XCTest
@testable import Scratchboard

@MainActor
final class ChatKeyHandlingTests: XCTestCase {
  let appState = AppState.shared
  let history = History.shared

  override func setUp() {
    super.setUp()
    MainActor.assumeIsolated {
      History.shared.clearAll()
    }
  }

  override func tearDown() {
    MainActor.assumeIsolated {
      AppState.shared.endChat()
      History.shared.clearAll()
    }
    super.tearDown()
  }

  func testTabStartsChat() {
    XCTAssertEqual(KeyChord(.tab, []), .startChat)
    XCTAssertNotEqual(KeyChord(.tab, [.shift]), .startChat)
  }

  func testStartChatWithTextItem() {
    let item = history.add(textItem("hello"))
    appState.navigator.select(item: item)

    appState.startChat()

    XCTAssertNotNil(appState.chat)
    XCTAssertEqual(appState.chat?.current?.text, "hello")
  }

  func testStartChatWithImageItemDoesNothing() {
    let item = history.add(imageItem())
    appState.navigator.select(item: item)

    appState.startChat()

    XCTAssertNil(appState.chat)
  }

  func testStartChatWithoutSelectionDoesNothing() {
    appState.navigator.select(item: nil)

    appState.startChat()

    XCTAssertNil(appState.chat)
  }

  func testEndChatResetsState() {
    let item = history.add(textItem("hello"))
    appState.navigator.select(item: item)
    appState.startChat()

    appState.endChat()

    XCTAssertNil(appState.chat)
  }

  func testPopupResetEndsChat() {
    let item = history.add(textItem("hello"))
    appState.navigator.select(item: item)
    appState.startChat()

    appState.popup.reset()

    XCTAssertNil(appState.chat)
  }

  func testChatKeys() {
    func action(
      _ key: Key,
      _ modifiers: NSEvent.ModifierFlags = [],
      _ role: ChatTextView.Role = .prompt,
      selection: Bool = false,
      empty: Bool = false
    ) -> ChatKeyAction? {
      ChatKeyAction(key: key, modifiers: modifiers, role: role, hasSelection: selection, isEmpty: empty)
    }

    XCTAssertNil(action(.return))
    XCTAssertNil(action(.return, [], .artefact))
    XCTAssertEqual(action(.return, empty: true), .copyAndClose)
    XCTAssertEqual(action(.keypadEnter, empty: true), .copyAndClose)
    XCTAssertNil(action(.return, [], .artefact, empty: true))
    XCTAssertNil(action(.return, [.shift], empty: true))
    XCTAssertEqual(action(.return, [.command]), .send)
    XCTAssertEqual(action(.escape), .close)
    XCTAssertEqual(action(.c, [.command]), .close)
    XCTAssertEqual(action(.c, [.command], selection: true), .copySelection)
    XCTAssertEqual(action(.z, [.command]), .undo)
    XCTAssertEqual(action(.z, [.command, .shift]), .redo)
    XCTAssertEqual(action(.tab), .focusArtefact)
    XCTAssertNil(action(.tab, [], .artefact))
    XCTAssertEqual(action(.tab, [.shift], .artefact), .focusPrompt)
    XCTAssertNil(action(.a))
  }

  func testEventLabels() {
    let id = UUID()
    XCTAssertEqual(TranscriptEntry.version(id: id, number: 3, author: .assistant, restoredFrom: nil)
      .eventLabel(previousNumber: 2), "→ v3")
    XCTAssertEqual(TranscriptEntry.version(id: id, number: 4, author: .user, restoredFrom: nil)
      .eventLabel(previousNumber: 3), "you edited → v4")
    XCTAssertEqual(TranscriptEntry.version(id: id, number: 5, author: .assistant, restoredFrom: 2)
      .eventLabel(previousNumber: 4), "restored v2 → v5")
    XCTAssertEqual(TranscriptEntry.pointer(id: id, number: 2).eventLabel(previousNumber: 3), "undo → v2")
    XCTAssertEqual(TranscriptEntry.pointer(id: id, number: 3).eventLabel(previousNumber: 2), "redo → v3")
    XCTAssertNil(TranscriptEntry.user(id: id, text: "hi").eventLabel(previousNumber: 1))
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

  private func imageItem() -> HistoryItem {
    let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
      NSColor.red.setFill()
      rect.fill()
      return true
    }
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [
      HistoryItemContent(type: NSPasteboard.PasteboardType.tiff.rawValue, value: image.tiffRepresentation)
    ]
    item.numberOfCopies = 1
    item.title = item.generateTitle()
    return item
  }
}
