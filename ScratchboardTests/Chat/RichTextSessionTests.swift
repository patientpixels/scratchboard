import AppKit
import XCTest
@testable import Scratchboard

// Chat sessions on rich text clips (#19). The clips are never added to
// History.shared while AppState.chat changes (see ChatTextRoutingTests).
final class RichTextSessionTests: ChatTestCase {
  private static let table = RichTextTests.table

  private static let tableWithRow = """
    <table>
    <tr><th>Name</th><th>Qty</th><th>Price</th></tr>
    <tr><td>Apples</td><td>3</td><td>1.20</td></tr>
    <tr><td>Pears</td><td>5</td><td>0.80</td></tr>
    <tr><td>Plums</td><td>12</td><td>2.10</td></tr>
    <tr><td>Figs</td><td>7</td><td>3.00</td></tr>
    </table>
    """

  private static let plainWithRow = RichTextTests.tablePlainText + "\nFigs\t7\t3.00"

  // A clip as TextEdit copies it: RTF plus the flattened text.
  private func richItem(_ html: String = table) throws -> HistoryItem {
    let attributed = try XCTUnwrap(RichText.attributedString(fromHTML: html))
    let rtf = try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [
      HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: rtf),
      HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(attributed.string.utf8))
    ]
    item.title = item.generateTitle()
    return item
  }

  private func assertRichPasteboard(
    html: String,
    plain: String,
    transient: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    assertPasteboard(plain, transient: transient, file: file, line: line)
    XCTAssertEqual(pasteboard.string(forType: .html), "<meta charset=\"utf-8\">" + html, file: file, line: line)
    let rtf = pasteboard.data(forType: .rtf) ?? Data()
    XCTAssertTrue(String(decoding: rtf, as: UTF8.self).contains("\\trowd"), file: file, line: line)
    XCTAssertEqual(
      NSAttributedString(rtf: rtf, documentAttributes: nil).map(RichText.html(from:)),
      html,
      file: file,
      line: line
    )
  }

  private func assertPlainOnly(file: StaticString = #filePath, line: UInt = #line) {
    let types = pasteboard.types ?? []
    XCTAssertFalse(types.contains(.html), file: file, line: line)
    XCTAssertFalse(types.contains(.rtf), file: file, line: line)
  }

  // MARK: Opening

  func testRichClipOpensWithEditingHTML() throws {
    let session = try XCTUnwrap(ChatSession.open(for: try richItem(), provider: nil, clipboard: clipboard))

    XCTAssertEqual(session.format, .html)
    XCTAssertEqual(session.current?.format, .html)
    XCTAssertEqual(session.versions.map(\.text), [Self.table])
    XCTAssertEqual(session.transcript, [])
  }

  func testUnreadableFormattingFallsBackToPlainText() throws {
    let item = textItem("Name\tQty")
    item.contents.append(HistoryItemContent(type: NSPasteboard.PasteboardType.rtf.rawValue, value: Data("junk".utf8)))

    let session = try XCTUnwrap(ChatSession.open(for: item, provider: nil, clipboard: clipboard))

    XCTAssertEqual(session.format, .plain)
    XCTAssertEqual(session.versions.map(\.text), ["Name\tQty"])
    XCTAssertTrue(kinds(session.transcript).first?.hasPrefix("error:") == true)
  }

  // MARK: Pasteboard

  func testModelHTMLIsNormalizedAndWrittenAsHTMLRTFAndText() async throws {
    let messy = Self.tableWithRow.replacingOccurrences(of: "<table>", with: "<table style=\"width:100%\" class=\"t\">")
    let provider = ScriptedProvider([[
      .call("write_artefact", .object(["text": .string("```html\n\(messy)\n```")])),
      .text("Added figs.")
    ]])
    let session = try XCTUnwrap(ChatSession.open(for: try richItem(), provider: provider, clipboard: clipboard))

    session.send("add figs")
    try await waitUntil { !session.isRunning }

    XCTAssertEqual(session.versions.map(\.text), [Self.table, Self.tableWithRow])
    XCTAssertEqual(session.current?.format, .html)
    assertRichPasteboard(
      html: Self.tableWithRow,
      plain: Self.plainWithRow,
      transient: true
    )

    let instructions = try XCTUnwrap(provider.instructions.first)
    XCTAssertEqual(instructions, ChatSession.htmlInstructions)
    XCTAssertTrue(instructions.contains("simplified HTML"))
    XCTAssertTrue(instructions.contains(RichText.allowedTags))
    XCTAssertTrue(try XCTUnwrap(provider.messages.first?.last?.content).contains(Self.table))
  }

  func testEveryVersionChangeWritesRichRepresentations() throws {
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    let session = try XCTUnwrap(ChatSession.open(for: try richItem(), provider: nil, clipboard: clipboard))
    session.undoManager = undoManager

    undoManager.beginUndoGrouping()
    session.commitManualEdit(Self.tableWithRow)
    undoManager.endUndoGrouping()
    XCTAssertEqual(session.current?.format, .html)
    assertRichPasteboard(html: Self.tableWithRow, plain: Self.plainWithRow, transient: true)

    undoManager.undo()
    XCTAssertEqual(session.currentNumber, 1)
    assertRichPasteboard(html: Self.table, plain: RichTextTests.tablePlainText, transient: true)

    XCTAssertTrue(session.stepForward())
    assertRichPasteboard(html: Self.tableWithRow, plain: Self.plainWithRow, transient: true)
  }

  func testCloseSavesHTMLRTFAndTextToHistory() throws {
    let origin = History.shared.add(try richItem()).item
    let session = try XCTUnwrap(ChatSession.open(for: origin, provider: nil, clipboard: clipboard))
    session.commitManualEdit(Self.tableWithRow)

    session.close()

    let plain = Self.plainWithRow
    assertRichPasteboard(html: Self.tableWithRow, plain: plain, transient: false)
    let saved = try XCTUnwrap(session.savedItem)
    XCTAssertEqual(saved.text, plain)
    let html = saved.htmlData.map { String(decoding: $0, as: UTF8.self) }
    XCTAssertEqual(html, "<meta charset=\"utf-8\">" + Self.tableWithRow)
    XCTAssertEqual(saved.rtf.map(RichText.html(from:)), Self.tableWithRow)
    XCTAssertTrue(saved.fromScratchboard)

    // The stored session resumes as rich text.
    let stored = try XCTUnwrap(origin.editSession)
    XCTAssertEqual(stored.versions.map(\.format), [.html, .html])
    let resumed = try XCTUnwrap(ChatSession.open(for: saved, provider: nil, clipboard: clipboard))
    XCTAssertEqual(resumed.format, .html)
    XCTAssertEqual(resumed.current?.text, Self.tableWithRow)
  }

  func testPlainClipStillWritesPlainTextOnly() async throws {
    let provider = ScriptedProvider([[.call("write_artefact", .object(["text": .string("<b>B</b>")]))]])
    let origin = History.shared.add(textItem("A")).item
    let session = try XCTUnwrap(ChatSession.open(for: origin, provider: provider, clipboard: clipboard))
    XCTAssertEqual(session.format, .plain)

    session.send("change")
    try await waitUntil { !session.isRunning }
    XCTAssertEqual(session.current?.text, "<b>B</b>")
    XCTAssertEqual(session.current?.format, .plain)
    XCTAssertEqual(provider.instructions.first, ChatSession.instructions)
    assertPasteboard("<b>B</b>", transient: true)
    assertPlainOnly()

    session.close()
    assertPasteboard("<b>B</b>", transient: false)
    assertPlainOnly()
    let saved = try XCTUnwrap(session.savedItem)
    XCTAssertEqual(saved.contents.map(\.type).sorted(), [
      NSPasteboard.PasteboardType.fromScratchboard.rawValue,
      NSPasteboard.PasteboardType.string.rawValue
    ].sorted())
  }

  // MARK: Stored sessions

  func testVersionsStoredWithoutFormatDecodeAsPlain() throws {
    let legacy = Data("""
      [{"number":1,"text":"A","author":"original","createdAt":0},
       {"number":2,"text":"B","author":"assistant","createdAt":1}]
      """.utf8)
    let session = EditSession()
    session.versionsData = legacy

    XCTAssertEqual(session.versions.map(\.text), ["A", "B"])
    XCTAssertEqual(session.versions.map(\.format), [.plain, .plain])

    session.versions = [ArtefactVersion(number: 1, text: Self.table, author: .original, createdAt: .now, format: .html)]
    XCTAssertEqual(session.versions.map(\.format), [.html])
  }
}
