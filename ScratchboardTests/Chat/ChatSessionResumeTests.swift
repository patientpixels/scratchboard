import AppKit
import Defaults
import XCTest
@testable import Scratchboard

// Reopening a closed session (the panel resumes the last chat) and copies
// made from inside the chat.
final class ChatSessionResumeTests: ChatTestCase {
  func testLastWriteIsOnPasteboardUntilSomethingElseIsCopied() throws {
    let origin = History.shared.add(textItem("A")).item
    let session = try XCTUnwrap(ChatSession.open(for: origin, provider: nil, clipboard: clipboard))
    XCTAssertFalse(session.isLastWriteOnPasteboard)

    session.commitManualEdit("B")
    XCTAssertTrue(session.isLastWriteOnPasteboard)
    session.close()
    XCTAssertTrue(session.isLastWriteOnPasteboard)

    pasteboard.clearContents()
    pasteboard.setString("elsewhere", forType: .string)
    XCTAssertFalse(session.isLastWriteOnPasteboard)
  }

  func testSessionThatNeverWroteIsNotOnPasteboard() throws {
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: nil, clipboard: clipboard))
    session.close()

    XCTAssertFalse(session.isLastWriteOnPasteboard)
  }

  func testReopenedSessionClosesWithoutDuplicates() throws {
    let origin = History.shared.add(textItem("A")).item
    let session = try XCTUnwrap(ChatSession.open(for: origin, provider: nil, clipboard: clipboard))
    session.commitManualEdit("B")
    session.close()
    let saved = try XCTUnwrap(session.savedItem)
    let changeCount = pasteboard.changeCount

    session.reopen()
    XCTAssertEqual(session.currentNumber, 2)
    session.close()

    XCTAssertTrue(session.savedItem === saved)
    XCTAssertEqual(History.shared.items.count, 2)
    XCTAssertEqual(try editSessionCount(), 1)
    XCTAssertEqual(origin.editSession?.versions.map(\.text), ["A", "B"])
    XCTAssertEqual(pasteboard.changeCount, changeCount)
    XCTAssertTrue(session.isLastWriteOnPasteboard)

    session.reopen()
    session.commitManualEdit("C")
    session.close()

    let latest = try XCTUnwrap(session.savedItem)
    XCTAssertEqual(latest.text, "C")
    XCTAssertEqual(History.shared.items.count, 3)
    XCTAssertEqual(try editSessionCount(), 1)
    let stored = try XCTUnwrap(origin.editSession)
    XCTAssertEqual(stored.versions.map(\.text), ["A", "B", "C"])
    XCTAssertEqual(stored.currentNumber, 3)
    XCTAssertTrue(latest.editSession === stored)
    XCTAssertEqual(latest.editSessionVersion, 3)
    assertPasteboard("C", transient: false)
  }

  func testReopenedPrivateSessionKeepsItsVersionsInMemory() throws {
    Defaults[.keepEditHistory] = false
    let origin = History.shared.add(textItem("A")).item
    let session = try XCTUnwrap(ChatSession.open(for: origin, provider: nil, clipboard: clipboard))
    session.commitManualEdit("B")
    session.close()

    session.reopen()
    XCTAssertEqual(session.versions.map(\.text), ["A", "B"])
    XCTAssertTrue(session.stepBack())
    XCTAssertTrue(session.stepForward())
    session.close()

    XCTAssertEqual(History.shared.items.count, 2)
    XCTAssertEqual(try editSessionCount(), 0)
    XCTAssertNil(origin.editSession)
    XCTAssertTrue(session.isLastWriteOnPasteboard)
  }

  func testCopiedSelectionIsTransientAndCountsAsOwnWrite() throws {
    let origin = History.shared.add(textItem("A")).item
    let session = try XCTUnwrap(ChatSession.open(for: origin, provider: nil, clipboard: clipboard))

    session.copySelection("part")

    assertPasteboard("part", transient: true)
    XCTAssertTrue(session.isLastWriteOnPasteboard)
    XCTAssertEqual(History.shared.items.map(\.text), ["A"])
  }

  func testCloseKeepsSelectionCopiedLast() throws {
    let origin = History.shared.add(textItem("A")).item
    let session = try XCTUnwrap(ChatSession.open(for: origin, provider: nil, clipboard: clipboard))
    session.commitManualEdit("B")
    session.copySelection("part")

    session.close()

    XCTAssertEqual(session.savedItem?.text, "B")
    assertPasteboard("part", transient: true)
    XCTAssertTrue(session.isLastWriteOnPasteboard)
  }
}
