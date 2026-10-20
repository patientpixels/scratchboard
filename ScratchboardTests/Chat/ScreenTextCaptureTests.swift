import AppKit
import Defaults
import XCTest
@testable import Scratchboard

// Black text on white, large enough for Vision to read reliably. No text
// gives a blank image.
@MainActor
func renderedTextPNG(_ text: String?) throws -> Data {
  let size = NSSize(width: 900, height: 200)
  let rep = try XCTUnwrap(NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  ))
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor.white.setFill()
  NSRect(origin: .zero, size: size).fill()
  if let text {
    (text as NSString).draw(
      at: NSPoint(x: 30, y: 70),
      withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]
    )
  }
  NSGraphicsContext.restoreGraphicsState()
  return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
}

@MainActor
final class TextRecognizerTests: XCTestCase {
  func testRecognizesRenderedText() async throws {
    let text = await TextRecognizer.recognizeText(imageData: try renderedTextPNG("Hello Scratchboard"))
    XCTAssertEqual(text?.trimmingCharacters(in: .whitespacesAndNewlines), "Hello Scratchboard")
  }

  func testBlankImageHasNoText() async throws {
    let text = await TextRecognizer.recognizeText(imageData: try renderedTextPNG(nil))
    XCTAssertEqual(text, "")
  }

  func testUnreadableDataGivesNil() async {
    let text = await TextRecognizer.recognizeText(imageData: Data("not an image".utf8))
    XCTAssertNil(text)
  }
}

private struct FakeCapture: ScreenRegionCapturing {
  let result: ScreenRegionCaptureResult

  func captureRegion() async -> ScreenRegionCaptureResult { result }
}

// The flow after the region is selected. The clip goes to a private pasteboard
// and is never added to History.shared: the test host's hidden panel would
// keep rendering its row once chat toggles (see ChatTextRoutingTests).
@MainActor
final class ScreenTextCaptureTests: ChatTestCase {
  private var notifications: [String] = []
  private var panelOpens = 0
  private var panelCloses = 0
  private var permissionRequests = 0

  override func tearDown() async throws {
    AppState.shared.endChat()
    AppState.shared.lastChat = nil
    AppState.shared.navigator.select(item: nil)
    try await super.tearDown()
  }

  private func makeCapture(
    _ result: ScreenRegionCaptureResult,
    permitted: Bool = true
  ) -> ScreenTextCapture {
    ScreenTextCapture(
      capturer: FakeCapture(result: result),
      clipboard: clipboard,
      provider: { nil },
      storedItem: { item in
        Storage.shared.context.insert(item)
        return HistoryItemDecorator(item)
      },
      closePanel: { self.panelCloses += 1 },
      openPanel: { self.panelOpens += 1 },
      permission: ScreenRecordingPermission(
        isGranted: { permitted },
        request: { self.permissionRequests += 1 }
      ),
      notify: { self.notifications.append($0) }
    )
  }

  func testTextBecomesClipAndOpensChat() async throws {
    let capture = makeCapture(.image(try renderedTextPNG("Hello Scratchboard")))

    let outcome = await capture.run()

    XCTAssertEqual(outcome, .chatStarted)
    let chat = try XCTUnwrap(AppState.shared.chat)
    XCTAssertEqual(chat.current?.text, "Hello Scratchboard")
    let item = try XCTUnwrap(AppState.shared.navigator.leadHistoryItem?.item)
    XCTAssertEqual(item.text, "Hello Scratchboard")
    XCTAssertTrue(chat.belongs(to: item))
    XCTAssertEqual(pasteboard.string(forType: .string), "Hello Scratchboard")
    XCTAssertEqual(panelCloses, 1)
    XCTAssertEqual(panelOpens, 1)
    XCTAssertEqual(notifications, [])
    XCTAssertEqual(permissionRequests, 0)
    XCTAssertFalse(capture.isCapturing)
  }

  func testNoTextMeansNoClip() async throws {
    let changeCount = pasteboard.changeCount
    let capture = makeCapture(.image(try renderedTextPNG(nil)))

    let outcome = await capture.run()

    XCTAssertEqual(outcome, .noText)
    XCTAssertEqual(pasteboard.changeCount, changeCount)
    XCTAssertNil(AppState.shared.chat)
    XCTAssertEqual(panelOpens, 0)
    XCTAssertEqual(notifications, [ScreenTextCapture.noTextMessage])
  }

  func testCancelDoesNothing() async {
    let changeCount = pasteboard.changeCount
    let capture = makeCapture(.cancelled)

    let outcome = await capture.run()

    XCTAssertEqual(outcome, .cancelled)
    XCTAssertEqual(pasteboard.changeCount, changeCount)
    XCTAssertNil(AppState.shared.chat)
    XCTAssertEqual(panelOpens, 0)
    XCTAssertEqual(notifications, [])
  }

  func testMissingPermissionPointsToSettings() async throws {
    let changeCount = pasteboard.changeCount
    let capture = makeCapture(.image(try renderedTextPNG(nil)), permitted: false)

    let outcome = await capture.run()

    XCTAssertEqual(outcome, .noText)
    XCTAssertEqual(pasteboard.changeCount, changeCount)
    XCTAssertEqual(notifications, [ScreenTextCapture.permissionMessage])
    XCTAssertEqual(permissionRequests, 1)
  }

  func testIgnoredCopyLeavesTextWithoutChat() async throws {
    let capture = makeCapture(.image(try renderedTextPNG("Hello Scratchboard")))
    let ignoreEvents = Defaults[.ignoreEvents]
    Defaults[.ignoreEvents] = true
    defer { Defaults[.ignoreEvents] = ignoreEvents }

    let outcome = await capture.run()

    XCTAssertEqual(outcome, .copied)
    XCTAssertEqual(pasteboard.string(forType: .string), "Hello Scratchboard")
    XCTAssertNil(AppState.shared.chat)
    XCTAssertEqual(panelOpens, 0)
  }
}
