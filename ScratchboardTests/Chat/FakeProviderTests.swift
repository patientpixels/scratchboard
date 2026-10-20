import XCTest
@testable import Scratchboard

final class FakeProviderTests: XCTestCase {
  func testUppercasesCurrentArtefactFromLastMessage() async throws {
    let written = WrittenText()
    let tool = LLMTool(name: "write_artefact", description: "", parameters: .object([:])) { arguments in
      await written.set(arguments["text"]?.stringValue)
      return "ok"
    }
    let message = "Current version: v2\n<artefact version=\"2\">\nhello\nworld\n</artefact>\n\nRequest: shout"
    let stream = FakeProvider(delay: .zero).run(
      instructions: "",
      messages: [LLMMessage(role: .user, content: message)],
      tools: [tool]
    )
    for try await _ in stream {}

    let text = await written.value
    XCTAssertEqual(text, "HELLO\nWORLD")
  }
}

private actor WrittenText {
  var value: String?
  func set(_ value: String?) { self.value = value }
}
