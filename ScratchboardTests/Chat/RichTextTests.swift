import AppKit
import XCTest
@testable import Scratchboard

@MainActor
final class RichTextTests: XCTestCase {
  // A 4×3 table, as editing HTML.
  static let table = """
    <table>
    <tr><th>Name</th><th>Qty</th><th>Price</th></tr>
    <tr><td>Apples</td><td>3</td><td>1.20</td></tr>
    <tr><td>Pears</td><td>5</td><td>0.80</td></tr>
    <tr><td>Plums</td><td>12</td><td>2.10</td></tr>
    </table>
    """

  static let tablePlainText = "Name\tQty\tPrice\nApples\t3\t1.20\nPears\t5\t0.80\nPlums\t12\t2.10"

  // The same table as a web page might put it on the pasteboard.
  static let verboseTable = """
    <html><head><style>td { font-family: Georgia; color: #333; }</style></head><body>
    <table class="data" border="1" cellpadding="4" style="width: 100%; border-collapse: collapse">
    <thead><tr><th style="background: #eee">Name</th><th>Qty</th><th>Price</th></tr></thead>
    <tbody>
    <tr><td><span style="font-size: 13px">Apples</span></td><td align="right">3</td><td>1.20</td></tr>
    <tr><td>Pears</td><td align="right">5</td><td><font color="red">0.80</font></td></tr>
    <tr><td>Plums</td><td align="right">12</td><td>2.10</td></tr>
    </tbody></table></body></html>
    """

  static let inline = """
    <p>Hello <b>bold</b>, <i>italic</i>, <b><i>both</i></b> and \
    <a href="https://example.com/a?b=1&amp;c=2">a link</a>.<br>Second line &amp; &lt;more&gt;</p>
    """

  private func cocoaHTML(_ html: String) throws -> NSAttributedString {
    try XCTUnwrap(NSAttributedString(
      html: Data(html.utf8),
      options: [.characterEncoding: String.Encoding.utf8.rawValue],
      documentAttributes: nil
    ))
  }

  private func rtf(_ attributed: NSAttributedString) throws -> Data {
    try attributed.data(
      from: NSRange(location: 0, length: attributed.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
  }

  // MARK: Serializer

  func testTableSerializesToCompactHTMLWithoutCSS() throws {
    let html = RichText.html(from: try cocoaHTML(Self.verboseTable))

    XCTAssertEqual(html, Self.table)
    for noise in ["style", "class", "font", "color", "border", "<span", "<thead"] {
      XCTAssertFalse(html.contains(noise), noise)
    }
  }

  func testRTFTableHasTheSameStructure() throws {
    let rtf = try rtf(try cocoaHTML(Self.table))
    XCTAssertTrue(String(decoding: rtf, as: UTF8.self).contains("\\trowd"))

    XCTAssertEqual(RichText.editingHTML(rtf: rtf, html: nil), .rich(Self.table))
    // RTF is preferred over HTML.
    XCTAssertEqual(RichText.editingHTML(rtf: rtf, html: Data("<p><b>other</b></p>".utf8)), .rich(Self.table))
  }

  func testTextEditTableKeepsBoldCellsAsTD() throws {
    let rtf = Data(#"""
      {\rtf1\ansi\ansicpg1252\cocoartf2822
      {\fonttbl\f0\fswiss\fcharset0 Helvetica;\f1\fswiss\fcharset0 Helvetica-Bold;}
      \pard\pardirnatural\partightenfactor0
      \f0\fs24 \cf0 Before\
      \itap1\trowd \taflags1 \trgaph108\trleft-108
      \clvertalc \clwWidth1000\clftsWidth2 \clbrdrt\brdrs\brdrw20 \clbrdrb\brdrs\brdrw20 \gaph\cellx4320
      \clvertalc \clwWidth1000\clftsWidth2 \clbrdrt\brdrs\brdrw20 \clbrdrb\brdrs\brdrw20 \gaph\cellx8640
      \pard\intbl\itap1\pardeftab720\partightenfactor0
      \f1\b \cf0 Name\cell
      \pard\intbl\itap1\pardeftab720\partightenfactor0
      \cf0 Qty\cell \row

      \itap1\trowd \taflags1 \trgaph108\trleft-108
      \clvertalc \clwWidth1000\clftsWidth2 \clbrdrt\brdrs\brdrw20 \clbrdrb\brdrs\brdrw20 \gaph\cellx4320
      \clvertalc \clwWidth1000\clftsWidth2 \clbrdrt\brdrs\brdrw20 \clbrdrb\brdrs\brdrw20 \gaph\cellx8640
      \pard\intbl\itap1\pardeftab720\partightenfactor0
      \f0\b0 \cf0 Apples\cell
      \pard\intbl\itap1\pardeftab720\partightenfactor0
      \cf0 3\cell \lastrow\row
      \pard\pardirnatural\partightenfactor0
      \cf0 After}
      """#.utf8)

    XCTAssertEqual(RichText.editingHTML(rtf: rtf, html: nil), .rich("""
      <p>Before</p>
      <table>
      <tr><td><b>Name</b></td><td><b>Qty</b></td></tr>
      <tr><td>Apples</td><td>3</td></tr>
      </table>
      <p>After</p>
      """))
  }

  func testBoldItalicAndLinksSurviveFromHTMLAndRTF() throws {
    let attributed = try cocoaHTML(Self.inline)
    XCTAssertEqual(RichText.html(from: attributed), Self.inline)

    let fromRTF = try XCTUnwrap(NSAttributedString(rtf: try rtf(attributed), documentAttributes: nil))
    XCTAssertEqual(RichText.html(from: fromRTF), Self.inline)
  }

  func testListsAndHeadings() throws {
    let html = """
      <h1>Title</h1>
      <h2>Part</h2>
      <h3>Small</h3>
      <ul>
      <li>One</li>
      <li>Two
      <ul>
      <li>Inner</li>
      </ul></li>
      </ul>
      <ol>
      <li>First</li>
      <li>Second</li>
      </ol>
      <p>End</p>
      """
    let attributed = try XCTUnwrap(RichText.attributedString(fromHTML: html))

    XCTAssertEqual(RichText.html(from: attributed), html)
    XCTAssertEqual(
      RichText.plainText(from: attributed),
      "Title\nPart\nSmall\n• One\n• Two\n\t• Inner\n1. First\n2. Second\nEnd"
    )
  }

  // MARK: Round trip

  func testEditingHTMLRoundTripIsStable() throws {
    let samples = [
      Self.table,
      Self.inline,
      "<table>\n<tr><td><b>Name</b></td><td>Qty</td></tr>\n<tr><td colspan=\"2\">Total</td></tr>\n</table>\n"
        + "<p>After</p>",
      "<table>\n<tr><td>A<br>B</td><td></td></tr>\n</table>",
      "<p>Ünïcode € 日本</p>\n<p>Second paragraph</p>"
    ]
    for html in samples {
      for style in [RichText.Style.pasteboard, .editor] {
        let attributed = try XCTUnwrap(RichText.attributedString(fromHTML: html, for: style))
        XCTAssertEqual(RichText.html(from: attributed), html, "\(style)")
      }
    }
  }

  // MARK: Pasteboard representations

  func testRepresentationsOfATable() throws {
    let representations = try XCTUnwrap(RichText.representations(forHTML: Self.table))

    XCTAssertTrue(String(decoding: representations.rtf, as: UTF8.self).contains("\\trowd"))
    XCTAssertEqual(representations.plain, Self.tablePlainText)
    XCTAssertEqual(representations.html, "<meta charset=\"utf-8\">" + Self.table)

    let rtf = try XCTUnwrap(NSAttributedString(rtf: representations.rtf, documentAttributes: nil))
    XCTAssertEqual(RichText.html(from: rtf), Self.table)
  }

  // MARK: Clips and model output

  func testClipsWithoutStructureStayPlain() {
    XCTAssertEqual(RichText.editingHTML(rtf: nil, html: nil), .plain)
    // Only colours and fonts.
    XCTAssertEqual(
      RichText.editingHTML(rtf: nil, html: Data("<p style='color: red; font-family: Georgia'>Hello</p>".utf8)),
      .plain
    )
    // Code from an editor, bold keywords and all.
    XCTAssertEqual(
      RichText.editingHTML(rtf: nil, html: Data("<pre><b>let</b> x = <i>1</i></pre>".utf8)),
      .plain
    )
    XCTAssertEqual(RichText.editingHTML(rtf: Data("not rtf".utf8), html: nil), .failed)
  }

  func testNormalizeBringsModelHTMLIntoTheSubset() {
    XCTAssertEqual(
      RichText.normalize(
        "<div><strong>Hi</strong> <em>there</em></div><table class='x'><tr><td style='color:red'>a</td></tr></table>"
      ),
      "<p><b>Hi</b> <i>there</i></p>\n<table>\n<tr><td>a</td></tr>\n</table>"
    )
    XCTAssertEqual(RichText.normalize("```html\n\(Self.table)\n```"), Self.table)
    XCTAssertEqual(
      RichText.normalize("Just text\nwith 1 < 2 & lines"),
      "<p>Just text</p>\n<p>with 1 &lt; 2 &amp; lines</p>"
    )
  }
}
