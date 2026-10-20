import AppKit
import Defaults
import XCTest
@testable import Scratchboard

// AppState resuming the last chat when the panel opens. The panel itself isn't
// opened; `resumeChat()` is what it calls.
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

    XCTAssertTrue(appState.resumeChat())

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

    XCTAssertTrue(appState.resumeChat())

    XCTAssertEqual(appState.chat?.currentNumber, 1)
    XCTAssertEqual(appState.chat?.versions.map(\.text), ["hello", "B", "C"])
  }

  func testDoesNotResumeAfterAnotherCopy() throws {
    let session = try startChat()
    session.copySelection("hel")
    appState.endChat()

    pasteboard.clearContents()
    pasteboard.setString("elsewhere", forType: .string)

    XCTAssertFalse(appState.resumeChat())
    XCTAssertNil(appState.chat)
    XCTAssertNil(appState.lastChat)
  }

  func testDoesNotResumeChatThatNeverWrote() throws {
    _ = try startChat()
    appState.endChat()

    XCTAssertFalse(appState.resumeChat())
    XCTAssertNil(appState.chat)
  }

  func testPrivateModeKeepsSessionInMemoryForResume() throws {
    Defaults[.keepEditHistory] = false
    let session = try startChat()
    session.commitManualEdit("B")
    session.stepBack()
    appState.endChat()
    XCTAssertTrue(appState.lastChat === session)

    XCTAssertTrue(appState.resumeChat())

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

  // Closing these chats at v1 keeps History.shared empty: the test host's
  // (hidden) panel keeps stale list rows alive while `chat` toggles.
  private func startChat() throws -> ChatSession {
    appState.navigator.select(item: HistoryItemDecorator(textItem("hello")))
    appState.startChat(provider: { nil }, clipboard: Clipboard(pasteboard: pasteboard))
    return try XCTUnwrap(appState.chat)
  }
}
