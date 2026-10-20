import AppKit
import Defaults
import XCTest
@testable import Scratchboard

final class ChatSessionPersistenceTests: ChatTestCase {
  func testCloseAtV1SavesNothing() throws {
    let item = History.shared.add(textItem("A")).item
    let session = try XCTUnwrap(ChatSession.open(for: item, provider: nil, clipboard: clipboard))
    let changeCount = pasteboard.changeCount

    session.close()

    XCTAssertNil(session.savedItem)
    XCTAssertEqual(History.shared.items.count, 1)
    XCTAssertEqual(try editSessionCount(), 0)
    XCTAssertNil(item.editSession)
    XCTAssertEqual(pasteboard.changeCount, changeCount)
  }

  func testCloseSavesCurrentVersionLinkedToPersistedSession() async throws {
    let provider = ScriptedProvider([[.text("Ok."), .call("write_artefact", .object(["text": .string("B")]))]])
    let origin = History.shared.add(textItem("A")).item
    let session = try XCTUnwrap(ChatSession.open(for: origin, provider: provider, clipboard: clipboard))
    session.send("change")
    try await waitUntil { !session.isRunning }

    session.close()

    let saved = try XCTUnwrap(session.savedItem)
    XCTAssertEqual(saved.text, "B")
    XCTAssertTrue(saved.fromScratchboard)
    XCTAssertEqual(History.shared.items.count, 2)
    assertPasteboard("B", transient: false)

    let stored = try XCTUnwrap(origin.editSession)
    XCTAssertEqual(try editSessionCount(), 1)
    XCTAssertTrue(saved.editSession === stored)
    XCTAssertEqual(origin.editSessionVersion, 1)
    XCTAssertEqual(saved.editSessionVersion, 2)
    XCTAssertEqual(stored.versions.map(\.text), ["A", "B"])
    XCTAssertEqual(stored.transcript, session.transcript)
    XCTAssertEqual(stored.currentNumber, 2)
  }

  func testReopeningResumesAtTheItemsVersion() throws {
    let origin = History.shared.add(textItem("A")).item
    let first = try XCTUnwrap(ChatSession.open(for: origin, provider: nil, clipboard: clipboard))
    first.commitManualEdit("B")
    first.close()

    let fromOrigin = try XCTUnwrap(ChatSession.open(for: origin, provider: nil, clipboard: clipboard))
    XCTAssertEqual(fromOrigin.currentNumber, 1)
    XCTAssertEqual(fromOrigin.versions.map(\.text), ["A", "B"])
    XCTAssertEqual(fromOrigin.transcript, first.transcript)
    XCTAssertTrue(fromOrigin.stepForward())
    fromOrigin.close()

    // Saving "B" again replaces the earlier copy (history deduplication).
    let saved = try XCTUnwrap(fromOrigin.savedItem)
    XCTAssertEqual(History.shared.items.count, 2)
    XCTAssertEqual(saved.editSessionVersion, 2)

    let fromSaved = try XCTUnwrap(ChatSession.open(for: saved, provider: nil, clipboard: clipboard))
    XCTAssertEqual(fromSaved.currentNumber, 2)
    fromSaved.commitManualEdit("C")
    fromSaved.close()

    XCTAssertEqual(try editSessionCount(), 1)
    let stored = try XCTUnwrap(origin.editSession)
    XCTAssertEqual(stored.versions.map(\.text), ["A", "B", "C"])
    let latest = try XCTUnwrap(fromSaved.savedItem)
    XCTAssertEqual(latest.text, "C")
    XCTAssertTrue(latest.editSession === stored)
    XCTAssertEqual(latest.editSessionVersion, 3)
  }

  func testPrivateModePersistsNothing() throws {
    Defaults[.keepEditHistory] = false
    let origin = History.shared.add(textItem("A")).item
    let session = try XCTUnwrap(ChatSession.open(for: origin, provider: nil, clipboard: clipboard))
    session.commitManualEdit("B")

    session.close()

    let saved = try XCTUnwrap(session.savedItem)
    XCTAssertEqual(saved.text, "B")
    XCTAssertNil(saved.editSession)
    XCTAssertNil(origin.editSession)
    XCTAssertEqual(try editSessionCount(), 0)
    assertPasteboard("B", transient: false)
  }

  func testPrivateModeLeavesStoredSessionUntouched() throws {
    let origin = History.shared.add(textItem("A")).item
    let first = try XCTUnwrap(ChatSession.open(for: origin, provider: nil, clipboard: clipboard))
    first.commitManualEdit("B")
    first.close()

    Defaults[.keepEditHistory] = false
    let resumed = try XCTUnwrap(ChatSession.open(for: origin, provider: nil, clipboard: clipboard))
    XCTAssertEqual(resumed.versions.count, 2)
    resumed.commitManualEdit("C")
    resumed.close()

    XCTAssertEqual(origin.editSession?.versions.map(\.text), ["A", "B"])
    XCTAssertNil(resumed.savedItem?.editSession)
  }

  func testCloseCancelsRunningTurnAndClearsUndo() async throws {
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let provider = ScriptedProvider([[.wait(.seconds(5))]])
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: provider, clipboard: clipboard))
    session.undoManager = undoManager
    undoManager.beginUndoGrouping()
    session.commitManualEdit("B")
    undoManager.endUndoGrouping()
    session.send("x")

    session.close()

    XCTAssertFalse(session.isRunning)
    XCTAssertFalse(undoManager.canUndo)
  }
}
