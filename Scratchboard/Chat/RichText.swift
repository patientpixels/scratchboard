import AppKit

// Rich text clips (#19). The model edits a small HTML subset, the "editing
// HTML"; Scratchboard does every conversion itself:
//
//   clip RTF/HTML → NSAttributedString → editing HTML   (`editingHTML(rtf:html:)`)
//   editing HTML → NSAttributedString                    (`attributedString(fromHTML:for:)`)
//   NSAttributedString → editing HTML                    (`html(from:)`, manual edits)
//   editing HTML → HTML + RTF + plain text               (`representations(forHTML:)`, pasteboard)
//
// Editing HTML uses only `allowedTags`: no CSS, classes, fonts or colours.
// Cocoa's own HTML exporter is verbose CSS, so the serializer here walks the
// attributed string's paragraphs (tables from NSTextTableBlock, lists from
// NSTextList) and runs (bold, italic, links) itself.
//
// NSAttributedString's HTML import uses WebKit and must run on the main actor.
enum RichText {
  static let allowedTags = "table, tr, th, td, p, br, b, i, a href, ul, ol, li, h1, h2, h3"

  // What a clip's rich content turns into.
  enum ClipContent: Equatable {
    // Editing HTML with structure plain text can't carry.
    case rich(String)
    // No rich content, or none worth keeping (only fonts and colours, or code).
    case plain
    // The clip has RTF or HTML that couldn't be read.
    case failed
  }

  // The three representations written to the pasteboard.
  struct Representations: Equatable {
    let plain: String
    let html: String
    let rtf: Data
  }

  enum Style {
    // Helvetica 12, like TextEdit: what other apps get in the RTF.
    case pasteboard
    // The chat's artefact editor.
    case editor
  }

  // Bigger clips stay plain text, so opening the chat never stalls.
  static let maxClipDataSize = 2_000_000

  // MARK: Clip → editing HTML

  // RTF is preferred, as it's what Cocoa apps put on the pasteboard first.
  static func editingHTML(rtf: Data?, html: Data?) -> ClipContent {
    guard rtf != nil || html != nil else { return .plain }
    guard (rtf?.count ?? 0) <= maxClipDataSize, (html?.count ?? 0) <= maxClipDataSize else { return .plain }

    let attributed = rtf.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
      ?? html.flatMap { NSAttributedString(html: $0, options: htmlOptions, documentAttributes: nil) }
    guard let attributed else { return .failed }
    guard !isCode(attributed) else { return .plain }

    let html = self.html(from: attributed)
    return hasStructure(html) ? .rich(html) : .plain
  }

  // Whether `html` holds anything beyond paragraphs and line breaks.
  static func hasStructure(_ html: String) -> Bool {
    ["<table", "<ul", "<ol", "<b>", "<i>", "<a ", "<h1", "<h2", "<h3"].contains { html.contains($0) }
  }

  // Text set entirely in a monospaced font is code (e.g. copied from an
  // editor with syntax colours) and is edited as plain text.
  private static func isCode(_ attributed: NSAttributedString) -> Bool {
    let string = attributed.string as NSString
    var sawText = false
    var allMonospaced = true
    attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, stop in
      guard !string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      sawText = true
      guard let font = value as? NSFont,
            font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace) else {
        allMonospaced = false
        stop.pointee = true
        return
      }
    }
    return sawText && allMonospaced
  }

  // MARK: Editing HTML → attributed string

  static func attributedString(fromHTML html: String, for style: Style = .pasteboard) -> NSAttributedString? {
    let font = switch style {
    case .pasteboard: "font-family: Helvetica; font-size: 12px;"
    case .editor: "font-family: -apple-system, 'Helvetica Neue', Helvetica; font-size: \(Int(NSFont.systemFontSize))px;"
    }
    let document = """
      <!DOCTYPE html><html><head><meta charset="utf-8"><style>
      body { \(font) }
      table { border-collapse: collapse; }
      td, th { border: 1px solid #999999; padding: 2px 6px; }
      </style></head><body>\(html)</body></html>
      """
    return NSAttributedString(html: Data(document.utf8), options: htmlOptions, documentAttributes: nil)
  }

  private static let htmlOptions: [NSAttributedString.DocumentReadingOptionKey: Any] = [
    .documentType: NSAttributedString.DocumentType.html,
    .characterEncoding: String.Encoding.utf8.rawValue
  ]

  // Brings HTML written by the model into the subset: tags outside it are
  // dropped or mapped (strong → b, div → p, …), code fences are removed and
  // text without any tags becomes paragraphs. Nil if it can't be read.
  static func normalize(_ text: String) -> String? {
    var html = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if html.hasPrefix("```"), html.hasSuffix("```"), let firstLine = html.firstIndex(of: "\n") {
      html = String(html[html.index(after: firstLine)..<html.index(html.endIndex, offsetBy: -3)])
    }
    if html.range(of: #"</?[a-zA-Z][^>]*>"#, options: .regularExpression) == nil {
      html = html
        .components(separatedBy: .newlines)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { "<p>\(escape($0))</p>" }
        .joined(separator: "\n")
    }
    guard let attributed = attributedString(fromHTML: html) else { return nil }
    return self.html(from: attributed)
  }

  // MARK: Editing HTML → pasteboard

  static func representations(forHTML html: String) -> Representations? {
    guard let attributed = attributedString(fromHTML: html, for: .pasteboard),
          let rtf = rtfData(from: attributed) else {
      return nil
    }
    // Without a charset, some apps read the HTML as Latin-1.
    return Representations(plain: plainText(from: attributed), html: "<meta charset=\"utf-8\">" + html, rtf: rtf)
  }

  static func rtfData(from attributed: NSAttributedString) -> Data? {
    // Without colours the text adapts to the target (e.g. dark mode).
    let text = NSMutableAttributedString(attributedString: attributed)
    let range = NSRange(location: 0, length: text.length)
    text.removeAttribute(.foregroundColor, range: range)
    return try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
  }

  // The attributed string's text, except that each table row becomes one
  // line of tab-separated cells and list items get "• " / "1. " markers.
  static func plainText(from attributed: NSAttributedString) -> String {
    let string = attributed.string as NSString
    var lines: [String] = []
    var row: (table: NSTextTable, number: Int, cells: [String])?
    var cell: NSTextTableBlock?
    var counters = ListCounters()

    func flushRow() {
      if let row {
        lines.append(row.cells.joined(separator: "\t"))
      }
      row = nil
      cell = nil
    }

    for paragraph in paragraphs(of: attributed) {
      var text = string.substring(with: paragraph.range).replacingOccurrences(of: "\u{2028}", with: "\n")

      if let block = tableCell(paragraph.style) {
        text = text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        if row?.table !== block.table || row?.number != block.startingRow {
          flushRow()
          row = (block.table, block.startingRow, [])
        }
        if cell === block, var cells = row?.cells, let last = cells.popLast() {
          cells.append(last.isEmpty ? text : text.isEmpty ? last : last + " " + text)
          row?.cells = cells
        } else {
          // Pad for cells spanning from above or the left.
          while (row?.cells.count ?? 0) < block.startingColumn {
            row?.cells.append("")
          }
          row?.cells.append(text)
          for _ in 1..<max(block.columnSpan, 1) {
            row?.cells.append("")
          }
        }
        cell = block
        continue
      }
      flushRow()

      let lists = paragraph.style?.textLists ?? []
      if let list = lists.last {
        let number = counters.next(for: lists)
        let item = stripMarker(text, list: list, number: number)
        let marker = list.isOrdered ? "\(number)." : "•"
        lines.append(String(repeating: "\t", count: lists.count - 1) + marker + " " + item)
      } else {
        counters.reset()
        lines.append(text)
      }
    }
    flushRow()

    var result = lines.joined(separator: "\n")
    while result.hasSuffix("\n") { result.removeLast() }
    return result
  }

  // MARK: Attributed string → editing HTML

  static func html(from attributed: NSAttributedString) -> String {
    var serializer = HTMLSerializer(attributed)
    return serializer.serialize()
  }

  // MARK: Helpers

  fileprivate struct Paragraph {
    // Without the paragraph separator.
    let range: NSRange
    let style: NSParagraphStyle?
  }

  fileprivate static func paragraphs(of attributed: NSAttributedString) -> [Paragraph] {
    let string = attributed.string as NSString
    var result: [Paragraph] = []
    var location = 0
    while location < string.length {
      var end = 0
      var contentsEnd = 0
      string.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
      let style = attributed.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
      result.append(Paragraph(range: NSRange(location: location, length: contentsEnd - location), style: style))
      location = max(end, location + 1)
    }
    return result
  }

  // The outermost table cell a paragraph is in; nested tables are flattened.
  fileprivate static func tableCell(_ style: NSParagraphStyle?) -> NSTextTableBlock? {
    style?.textBlocks.lazy.compactMap { $0 as? NSTextTableBlock }.first
  }

  // HTML import puts list markers into the text ("\t•\tItem"); RTF import
  // doesn't.
  fileprivate static func stripMarker(_ text: String, list: NSTextList, number: Int) -> String {
    let prefix = "\t" + list.marker(forItemNumber: number) + "\t"
    return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
  }

  fileprivate static func escape(_ text: String, quotes: Bool = false) -> String {
    var result = text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    if quotes {
      result = result.replacingOccurrences(of: "\"", with: "&quot;")
    }
    return result
  }

  // Item numbers per list, for markers.
  fileprivate struct ListCounters {
    private var counts: [ObjectIdentifier: Int] = [:]
    private var current: [ObjectIdentifier] = []

    // The number of the next item in the innermost of `lists`. Counters of
    // lists that ended (not in `lists` anymore) restart.
    mutating func next(for lists: [NSTextList]) -> Int {
      let ids = lists.map(ObjectIdentifier.init)
      for id in current where !ids.contains(id) {
        counts[id] = nil
      }
      current = ids
      guard let list = lists.last else { return 1 }
      let id = ObjectIdentifier(list)
      let number = counts[id].map { $0 + 1 } ?? list.startingItemNumber
      counts[id] = number
      return number
    }

    mutating func reset() {
      counts = [:]
      current = []
    }
  }
}

private extension NSTextList {
  var isOrdered: Bool {
    switch markerFormat {
    case .disc, .circle, .square, .hyphen, .box, .check, .diamond: false
    default: true
    }
  }
}

// Writes block structure (tables, lists, headings, paragraphs) one paragraph
// at a time, and inline formatting per attribute run.
private struct HTMLSerializer {
  private let attributed: NSAttributedString
  private let string: NSString
  private let bodySize: CGFloat
  private var out = ""

  private var table: NSTextTable?
  private var row: Int?
  private var cell: (block: NSTextTableBlock, tag: String, paragraphs: Int)?
  // Open lists, outermost first; `item` is whether an <li> is open.
  private var lists: [(list: NSTextList, item: Bool)] = []
  private var counters = RichText.ListCounters()

  init(_ attributed: NSAttributedString) {
    self.attributed = attributed
    self.string = attributed.string as NSString
    self.bodySize = Self.mostCommonFontSize(in: attributed)
  }

  mutating func serialize() -> String {
    for paragraph in RichText.paragraphs(of: attributed) {
      if let block = RichText.tableCell(paragraph.style) {
        closeLists()
        writeCell(paragraph, block: block)
        continue
      }
      closeTable()

      let paragraphLists = paragraph.style?.textLists ?? []
      if !paragraphLists.isEmpty {
        writeListItem(paragraph, lists: paragraphLists)
        continue
      }
      closeLists()
      counters.reset()

      guard !string.substring(with: paragraph.range).trimmingCharacters(in: .whitespaces).isEmpty else {
        continue
      }
      if let level = headingLevel(paragraph.range) {
        out += "<h\(level)>" + inline(paragraph.range, bold: false) + "</h\(level)>\n"
      } else {
        out += "<p>" + inline(paragraph.range) + "</p>\n"
      }
    }
    closeTable()
    closeLists()
    while out.hasSuffix("\n") { out.removeLast() }
    return out
  }

  // MARK: Tables

  private mutating func writeCell(_ paragraph: RichText.Paragraph, block: NSTextTableBlock) {
    if table !== block.table {
      closeTable()
      out += "<table>\n"
      table = block.table
    }
    if cell?.block !== block {
      closeCell()
      if row != block.startingRow {
        closeRow()
        out += "<tr>"
        row = block.startingRow
      }
      // HTML import makes <th> bold and centred; a bold, left-aligned cell
      // (TextEdit's header row) stays a <td> with <b>.
      let isHeader = paragraph.style?.alignment == .center && isBold(paragraph.range)
      let tag = isHeader ? "th" : "td"
      var attributes = ""
      if block.columnSpan > 1 { attributes += " colspan=\"\(block.columnSpan)\"" }
      if block.rowSpan > 1 { attributes += " rowspan=\"\(block.rowSpan)\"" }
      out += "<\(tag)\(attributes)>"
      cell = (block, tag, 0)
    }
    guard var current = cell else { return }
    if current.paragraphs > 0 {
      out += "<br>"
    }
    out += inline(paragraph.range, bold: current.tag != "th")
    current.paragraphs += 1
    cell = current
  }

  private mutating func closeCell() {
    guard let current = cell else { return }
    out += "</\(current.tag)>"
    cell = nil
  }

  private mutating func closeRow() {
    closeCell()
    guard row != nil else { return }
    out += "</tr>\n"
    row = nil
  }

  private mutating func closeTable() {
    closeRow()
    guard table != nil else { return }
    out += "</table>\n"
    table = nil
  }

  // MARK: Lists

  private mutating func writeListItem(_ paragraph: RichText.Paragraph, lists paragraphLists: [NSTextList]) {
    var common = 0
    while common < lists.count, common < paragraphLists.count, lists[common].list === paragraphLists[common] {
      common += 1
    }
    while lists.count > common {
      closeInnermostList()
    }
    if lists.count == paragraphLists.count, !lists.isEmpty {
      // Next item in the same list.
      out += "</li>\n"
      lists[lists.count - 1].item = false
    }
    while lists.count < paragraphLists.count {
      let list = paragraphLists[lists.count]
      if !lists.isEmpty { out += "\n" }
      out += list.isOrdered ? "<ol>\n" : "<ul>\n"
      lists.append((list, false))
    }

    let number = counters.next(for: paragraphLists)
    let text = string.substring(with: paragraph.range)
    let stripped = RichText.stripMarker(text, list: paragraphLists[paragraphLists.count - 1], number: number)
    let range = NSRange(
      location: paragraph.range.location + (text as NSString).length - (stripped as NSString).length,
      length: (stripped as NSString).length
    )
    out += "<li>" + inline(range)
    lists[lists.count - 1].item = true
  }

  private mutating func closeInnermostList() {
    guard let last = lists.popLast() else { return }
    if last.item { out += "</li>\n" }
    out += last.list.isOrdered ? "</ol>" : "</ul>"
    out += lists.isEmpty ? "\n" : ""
  }

  private mutating func closeLists() {
    while !lists.isEmpty {
      closeInnermostList()
    }
  }

  // MARK: Inline

  // Links outermost, then bold, then italic. `bold: false` leaves out <b>,
  // e.g. in headings and header cells, which are bold anyway.
  private func inline(_ range: NSRange, bold allowsBold: Bool = true) -> String {
    typealias Format = (link: String?, bold: Bool, italic: Bool)
    var result = ""
    var open: Format = (nil, false, false)
    // Spaces between runs don't start or end formatting; they go outside
    // the tags that change around them: "<b>a</b> <i>b</i>".
    var pendingSpace = ""

    func transition(to format: Format) {
      let closesLink = format.link != open.link
      let closesBold = closesLink || format.bold != open.bold
      let closesItalic = closesBold || format.italic != open.italic
      if closesItalic, open.italic { result += "</i>" }
      if closesBold, open.bold { result += "</b>" }
      if closesLink, open.link != nil { result += "</a>" }
      result += pendingSpace
      pendingSpace = ""
      if closesLink, let link = format.link { result += "<a href=\"\(RichText.escape(link, quotes: true))\">" }
      if closesBold, format.bold { result += "<b>" }
      if closesItalic, format.italic { result += "<i>" }
      open = format
    }

    attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
      let text = RichText.escape(string.substring(with: runRange))
        .replacingOccurrences(of: "\u{2028}", with: "<br>")
      let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
      let format: Format = (
        Self.linkString(attributes[.link]),
        allowsBold && traits.contains(.bold),
        traits.contains(.italic)
      )
      if format.link == open.link, text.trimmingCharacters(in: .whitespaces).isEmpty {
        pendingSpace += text
        return
      }
      transition(to: format)
      result += text
    }
    transition(to: (nil, false, false))
    return result
  }

  private static func linkString(_ value: Any?) -> String? {
    switch value {
    case let url as URL: url.absoluteString
    case let string as String: string
    default: nil
    }
  }

  // MARK: Fonts

  private func isBold(_ range: NSRange) -> Bool {
    var bold = true
    attributed.enumerateAttribute(.font, in: range) { value, runRange, stop in
      guard !string.substring(with: runRange).trimmingCharacters(in: .whitespaces).isEmpty else { return }
      if (value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) != true {
        bold = false
        stop.pointee = true
      }
    }
    return bold
  }

  // A bold paragraph set larger than the body text is a heading, by HTML's
  // default sizes: h1 2em, h2 1.5em, h3 1.17em.
  private func headingLevel(_ range: NSRange) -> Int? {
    guard range.length > 0, bodySize > 0, isBold(range) else { return nil }
    var size = CGFloat.greatestFiniteMagnitude
    attributed.enumerateAttribute(.font, in: range) { value, _, _ in
      size = min(size, (value as? NSFont)?.pointSize ?? 0)
    }
    switch size / bodySize {
    case 1.8...: return 1
    case 1.4...: return 2
    case 1.12...: return 3
    default: return nil
    }
  }

  private static func mostCommonFontSize(in attributed: NSAttributedString) -> CGFloat {
    var lengths: [CGFloat: Int] = [:]
    attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
      guard let font = value as? NSFont else { return }
      lengths[font.pointSize, default: 0] += range.length
    }
    return lengths.max { $0.value < $1.value }?.key ?? 0
  }
}
