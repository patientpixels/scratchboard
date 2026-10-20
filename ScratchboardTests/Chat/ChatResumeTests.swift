import AppKit
import Defaults
import XCTest
@testable import Scratchboard

// AppState resuming the last chat: the panel opens on the list
// (`prepareResume()`), and Tab on the chat's clip goes back into it.
@MainActor
final class ChatResumeTests: XCTestCase {
  private let appState = AppState.shared
  private let savedKeepEditHistory = Defaults[.keepEditHistory]
  // XCTest creates an instance per test, so each test gets its own pasteboard.
  private nonisolated let pasteboardName = NSPasteboard.Name("ScratchboardTests.\(UUID().uuidString)")
  private var pasteboard: NSPasteboard { NSPasteboard(name: pasteboardName) }

  override func setUp() {
    super.setUp()
    MainActor.assumeIsolated {
      Defaults[.keepEditHistory] = true
      AppState.shared.lastChat = nil
      History.shared.clearAll()
    }
  }

  override func tearDown() {
    let pasteboardName = pasteboardName
    let savedKeepEditHistory = savedKeepEditHistory
    MainActor.assumeIsolated {
      AppState.shared.endChat()
      AppState.shared.lastChat = nil
      AppState.shared.navigator.select(item: nil)
      Defaults[.keepEditHistory] = savedKeepEditHistory
      History.shared.clearAll()
      NSPasteboard(name: pasteboardName).releaseGlobally()
    }
    super.tearDown()
  }

  func testResumesWhenNothingElseWasCopied() throws {
    let session = try startChat()
    session.copySelection("hel")
    appState.endChat()
    XCTAssertNil(appState.chat)

    XCTAssertTrue(resume(session))

    XCTAssertTrue(appState.chat === session)
    XCTAssertNil(appState.lastChat)
    session.commitManualEdit("changed")
    XCTAssertEqual(session.current?.text, "changed")
  }

  func testResumesAtCurrentVersion() throws {
    let session = try startChat()
    session.commitManualEdit("B")
    session.commitManualEdit("C")
    session.stepBack()
    session.stepBack()
    appState.endChat()

    XCTAssertTrue(resume(session))

    XCTAssertEqual(appState.chat?.currentNumber, 1)
    XCTAssertEqual(appState.chat?.versions.map(\.text), ["hello", "B", "C"])
  }

  func testDoesNotResumeAfterAnotherCopy() throws {
    let session = try startChat()
    session.copySelection("hel")
    appState.endChat()

    pasteboard.clearContents()
    pasteboard.setString("elsewhere", forType: .string)

    appState.prepareResume()
    XCTAssertNil(appState.lastChat)
    XCTAssertFalse(resume(session))
  }

  func testDoesNotResumeChatThatNeverWrote() throws {
    let session = try startChat()
    appState.endChat()

    XCTAssertFalse(resume(session))
  }

  func testPanelOpensOnListWithoutResuming() throws {
    let session = try startChat()
    session.copySelection("hel")
    appState.endChat()

    appState.prepareResume()

    XCTAssertNil(appState.chat)
    XCTAssertTrue(appState.lastChat === session)
  }

  func testPrivateModeKeepsSessionInMemoryForResume() throws {
    Defaults[.keepEditHistory] = false
    let session = try startChat()
    session.commitManualEdit("B")
    session.stepBack()
    appState.endChat()
    XCTAssertTrue(appState.lastChat === session)

    XCTAssertTrue(resume(session))

    XCTAssertTrue(appState.chat === session)
    XCTAssertEqual(session.versions.map(\.text), ["hello", "B"])
    XCTAssertEqual(session.currentNumber, 1)
  }

  func testStartingAnotherChatDropsLastChat() throws {
    let session = try startChat()
    session.copySelection("hel")
    appState.endChat()

    _ = try startChat()

    XCTAssertNil(appState.lastChat)
  }

  // What the panel does on open, then Tab on the still-selected clip.
  private func resume(_ session: ChatSession) -> Bool {
    appState.prepareResume()
    appState.startChat(provider: { nil }, clipboard: Clipboard(pasteboard: pasteboard))
    return appState.chat === session
  }

  // Closing these chats at v1 keeps History.shared empty: the test host's
  // (hidden) panel keeps stale list rows alive while `chat` toggles.
  private func startChat() throws -> ChatSession {
    appState.navigator.select(item: HistoryItemDecorator(textItem("hello")))
    appState.startChat(provider: { nil }, clipboard: Clipboard(pasteboard: pasteboard))
    return try XCTUnwrap(appState.chat)
  }
}
