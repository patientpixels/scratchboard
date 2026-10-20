import AppKit
import XCTest
@testable import Scratchboard

final class ChatSessionTests: ChatTestCase {
  // MARK: Opening

  func testOpenStartsWithClipAsV1() throws {
    let session = try XCTUnwrap(ChatSession.open(for: textItem("hello"), provider: nil, clipboard: clipboard))

    XCTAssertEqual(session.versions.map(\.text), ["hello"])
    XCTAssertEqual(session.current?.author, .original)
    XCTAssertEqual(session.currentNumber, 1)
    XCTAssertEqual(session.transcript, [])
    XCTAssertNil(session.providerName)
  }

  func testOpenReturnsNilForNonTextClip() {
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: Data([0x89]))
    ])
    XCTAssertNil(ChatSession.open(for: item, provider: nil, clipboard: clipboard))
  }

  // MARK: Agent turn

  func testTurnStreamsTextWritesVersionAndCopiesTransient() async throws {
    let provider = ScriptedProvider([[
      .text("Sure"), .text(", done."),
      .call("write_artefact", .object(["text": .string("HELLO")])),
      .text("Anything else?")
    ]])
    let session = try XCTUnwrap(ChatSession.open(for: textItem("hello"), provider: provider, clipboard: clipboard))
    XCTAssertEqual(session.providerName, "Scripted")

    session.send("shout")
    XCTAssertTrue(session.isRunning)
    try await waitUntil { !session.isRunning }

    XCTAssertEqual(session.versions.map(\.text), ["hello", "HELLO"])
    XCTAssertEqual(session.current?.author, .assistant)
    XCTAssertEqual(session.currentNumber, 2)
    XCTAssertEqual(kinds(session.transcript), [
      "user:shout", "assistant:Sure, done.", "version:2:assistant:-", "assistant:Anything else?"
    ])
    XCTAssertEqual(provider.toolResults, ["Saved as v2, which is now the current version."])
    assertPasteboard("HELLO", transient: true)
  }

  func testRestoreVersionCopiesAsNewVersion() async throws {
    let provider = ScriptedProvider([
      [.call("write_artefact", .object(["text": .string("B")]))],
      [.call("restore_version", .object(["version": .number(1)]))]
    ])
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: provider, clipboard: clipboard))

    session.send("change")
    try await waitUntil { !session.isRunning }
    session.send("go back")
    try await waitUntil { !session.isRunning }

    XCTAssertEqual(session.versions.map(\.text), ["A", "B", "A"])
    XCTAssertEqual(session.currentNumber, 3)
    XCTAssertEqual(kinds(session.transcript).last, "version:3:assistant:1")
    assertPasteboard("A", transient: true)
  }

  func testInvalidToolCallsReportErrorsWithoutChanges() async throws {
    let provider = ScriptedProvider([[
      .call("restore_version", .object(["version": .number(7)])),
      .call("restore_version", .object(["version": .string("v1")])),
      .call("write_artefact", .object([:])),
      .call("write_artefact", .object(["text": .string("A")]))
    ]])
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: provider, clipboard: clipboard))

    session.send("do things")
    try await waitUntil { !session.isRunning }

    XCTAssertEqual(session.versions.count, 1)
    XCTAssertEqual(provider.toolResults, [
      "Error: v7 doesn't exist. Versions are v1 to v1.",
      "v1 is already the current version.",
      "Error: missing string argument \"text\".",
      "The text is identical to v1, so no new version was created."
    ])
  }

  func testProviderErrorAppendsErrorEntry() async throws {
    let provider = ScriptedProvider([[.text("Hm"), .fail(.http(status: 500, body: "boom"))]])
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: provider, clipboard: clipboard))

    session.send("x")
    try await waitUntil { !session.isRunning }

    XCTAssertEqual(kinds(session.transcript), ["user:x", "assistant:Hm", "error:HTTP 500: boom"])
  }

  func testSendWithoutProviderAppendsError() throws {
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: nil, clipboard: clipboard))

    session.send("x")

    XCTAssertFalse(session.isRunning)
    XCTAssertEqual(kinds(session.transcript).first, "user:x")
    XCTAssertTrue(kinds(session.transcript).last?.hasPrefix("error:") == true)
  }

  func testEmptyPromptIsIgnored() throws {
    let provider = ScriptedProvider([])
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: provider, clipboard: clipboard))

    session.send("  \n")

    XCTAssertEqual(session.transcript, [])
    XCTAssertTrue(provider.messages.isEmpty)
  }

  func testCancelKeepsStreamedTextAndDropsLaterToolCalls() async throws {
    let provider = ScriptedProvider([[
      .text("Work"), .wait(.milliseconds(300)),
      .call("write_artefact", .object(["text": .string("B")]))
    ]])
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: provider, clipboard: clipboard))

    session.send("x")
    try await waitUntil { session.transcript.count == 2 }
    session.cancel()
    XCTAssertFalse(session.isRunning)
    try await Task.sleep(for: .milliseconds(400))

    XCTAssertEqual(kinds(session.transcript), ["user:x", "assistant:Work"])
    XCTAssertEqual(session.versions.count, 1)
  }

  // MARK: Messages

  func testLastMessageCarriesCurrentVersionAndRequest() async throws {
    let provider = ScriptedProvider([
      [.text("Done."), .call("write_artefact", .object(["text": .string("second")]))],
      []
    ])
    let session = try XCTUnwrap(ChatSession.open(for: textItem("first"), provider: provider, clipboard: clipboard))

    session.send("rewrite")
    try await waitUntil { !session.isRunning }
    session.commitManualEdit("third")
    session.stepBack()
    session.send("shorter")
    try await waitUntil { !session.isRunning }

    let firstTurn = try XCTUnwrap(provider.messages.first)
    XCTAssertEqual(firstTurn, [LLMMessage(
      role: .user,
      content: "Current version: v1\n<artefact version=\"1\">\nfirst\n</artefact>\n\nRequest: rewrite"
    )])

    let messages = try XCTUnwrap(provider.messages.last)
    XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user])
    XCTAssertEqual(messages[0].content, """
      [v1, the original clip:]
      <artefact version="1">
      first
      </artefact>

      rewrite
      """)
    XCTAssertEqual(messages[1].content, "Done.")
    XCTAssertEqual(messages[2].content, """
      [You wrote v2:]
      <artefact version="2">
      second
      </artefact>

      [The user edited the artefact by hand, creating v3:]
      <artefact version="3">
      third
      </artefact>

      [The user made v2 the current version.]

      Current version: v2
      <artefact version="2">
      second
      </artefact>

      Request: shorter
      """)
    XCTAssertTrue(provider.instructions.first?.contains("write_artefact") == true)
  }

  // MARK: Versions and undo

  func testManualEditAppendsUserVersionUnlessUnchanged() throws {
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: nil, clipboard: clipboard))
    let changeCount = pasteboard.changeCount

    session.commitManualEdit("A")
    XCTAssertEqual(session.versions.count, 1)
    XCTAssertEqual(pasteboard.changeCount, changeCount)

    session.commitManualEdit("B")
    XCTAssertEqual(session.versions.map(\.text), ["A", "B"])
    XCTAssertEqual(session.current?.author, .user)
    XCTAssertEqual(kinds(session.transcript), ["version:2:user:-"])
    assertPasteboard("B", transient: true)
  }

  func testUndoAndRedoMoveThePointer() throws {
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: nil, clipboard: clipboard))
    session.undoManager = undoManager

    for text in ["B", "C"] {
      undoManager.beginUndoGrouping()
      session.commitManualEdit(text)
      undoManager.endUndoGrouping()
    }

    undoManager.undo()
    XCTAssertEqual(session.currentNumber, 2)
    assertPasteboard("B", transient: true)
    undoManager.undo()
    XCTAssertEqual(session.currentNumber, 1)
    assertPasteboard("A", transient: true)
    XCTAssertFalse(undoManager.canUndo)

    undoManager.redo()
    XCTAssertEqual(session.currentNumber, 2)
    assertPasteboard("B", transient: true)

    XCTAssertEqual(session.versions.map(\.text), ["A", "B", "C"])
    XCTAssertEqual(kinds(session.transcript), [
      "version:2:user:-", "version:3:user:-", "pointer:2", "pointer:1", "pointer:2"
    ])
  }

  func testStepBackAndForwardStopAtTheEnds() throws {
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: nil, clipboard: clipboard))
    session.commitManualEdit("B")

    XCTAssertFalse(session.stepForward())
    XCTAssertTrue(session.stepBack())
    XCTAssertEqual(session.currentNumber, 1)
    assertPasteboard("A", transient: true)
    XCTAssertFalse(session.stepBack())
    XCTAssertTrue(session.stepForward())
    XCTAssertEqual(session.currentNumber, 2)
    XCTAssertEqual(kinds(session.transcript), ["version:2:user:-", "pointer:1", "pointer:2"])
  }

  func testTransientCopyIsNotRecordedByWatcher() {
    var recorded = false
    clipboard.onNewCopy { _ in recorded = true }

    clipboard.copyUnrecorded("secret", transient: true)
    clipboard.changeCount = -1
    clipboard.checkForChangesInPasteboard()

    XCTAssertFalse(recorded)
    assertPasteboard("secret", transient: true)
  }
}
