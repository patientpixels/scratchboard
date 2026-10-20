import XCTest
@testable import Scratchboard

// Chat text never carries artefact content or echoes of the prompt (#15).
final class AssistantTextSanitizerTests: ChatTestCase {
  private func sanitize(_ text: String, streaming: Bool = false) -> String {
    ChatSession.sanitizeAssistantText(text, streaming: streaming)
  }

  func testPlainTextIsUntouched() {
    for text in ["Done.", "  Indented the list.\n\nAnything else?\n", "a < b, and <b>bold</b>", "Requests are welcome."] {
      XCTAssertEqual(sanitize(text), text)
      XCTAssertEqual(sanitize(text, streaming: true), text)
    }
  }

  func testRemovesCompleteArtefactBlock() {
    XCTAssertEqual(sanitize("Done.\n\n<artefact version=\"2\">\n  one\n  two\n</artefact>\n\nAnything else?"),
                   "Done.\n\nAnything else?")
    XCTAssertEqual(sanitize("Here: <ARTEFACT>x</Artefact> ok"), "Here:  ok")
  }

  func testRemovesEchoedPrompt() {
    let echo = "<artefact version=\"2\">\none\ntwo\n</artefact>\n\nRequest: indent"
    XCTAssertEqual(sanitize(echo), "")
    XCTAssertEqual(sanitize("Current version: v2\n" + echo), "")
    XCTAssertEqual(sanitize("Indented.\nRequest: indent"), "Indented.")
    XCTAssertEqual(sanitize("  current version: v3\nOk."), "Ok.")
  }

  func testRemovesUnterminatedBlock() {
    XCTAssertEqual(sanitize("Done.\n<artefact version=\"2\">\nhalf of the"), "Done.")
    XCTAssertEqual(sanitize("Done.\n<artefact version=\"2\""), "Done.")
  }

  func testHoldsBackPartialMarkersOnlyWhileStreaming() {
    for partial in ["Done.\n<arte", "Done. <", "Done.\nReq", "Done.\nCurrent ver"] {
      XCTAssertEqual(sanitize(partial, streaming: true), "Done.", partial)
      XCTAssertEqual(sanitize(partial), partial, partial)
    }
  }

  // MARK: In the session

  func testStreamedEchoNeverShowsAndLeavesNoEmptyEntry() async throws {
    let provider = ScriptedProvider([[
      .text("<artefact version=\"2\">\n"), .text("  one\n"),
      .wait(.milliseconds(200)),
      .text("</artefact>\n\nRequ"), .text("est: indent"),
      .call("write_artefact", .object(["text": .string("  one")]))
    ]])
    let session = try XCTUnwrap(ChatSession.open(for: textItem("one"), provider: provider, clipboard: clipboard))

    session.send("indent")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(kinds(session.transcript), ["user:indent"])
    try await waitUntil { !session.isRunning }

    XCTAssertEqual(kinds(session.transcript), ["user:indent", "version:2:assistant:-"])
  }

  func testPartialBlockDoesNotFlashWhileStreaming() async throws {
    let provider = ScriptedProvider([[
      .text("Indented.\n<arte"), .wait(.milliseconds(200)),
      .text("fact version=\"2\">\n  one"), .wait(.milliseconds(200)),
      .text("\n</artefact>\nAnything else?")
    ]])
    let origin = History.shared.add(textItem("one")).item
    let session = try XCTUnwrap(ChatSession.open(for: origin, provider: provider, clipboard: clipboard))

    session.send("indent")
    try await waitUntil { session.transcript.count == 2 }
    XCTAssertEqual(kinds(session.transcript), ["user:indent", "assistant:Indented."])
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(kinds(session.transcript), ["user:indent", "assistant:Indented."])
    try await waitUntil { !session.isRunning }

    XCTAssertEqual(kinds(session.transcript), ["user:indent", "assistant:Indented.\n\nAnything else?"])

    session.close()
    XCTAssertEqual(origin.editSession?.transcript, session.transcript)
  }

  func testTextAfterToolCallStartsNewEntry() async throws {
    let provider = ScriptedProvider([[
      .text("Sure.\nRe"),
      .call("write_artefact", .object(["text": .string("B")])),
      .text("Request: x\nDone.")
    ]])
    let session = try XCTUnwrap(ChatSession.open(for: textItem("A"), provider: provider, clipboard: clipboard))

    session.send("x")
    try await waitUntil { !session.isRunning }

    XCTAssertEqual(kinds(session.transcript), [
      "user:x", "assistant:Sure.\nRe", "version:2:assistant:-", "assistant:Done."
    ])
  }
}
