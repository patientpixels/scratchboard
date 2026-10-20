import AppKit
import CoreGraphics
import Foundation

nonisolated enum ScreenRegionCaptureResult: Equatable, Sendable {
  // Esc in the selection, or nothing was written.
  case cancelled
  // Encoded image (PNG) of the selected region.
  case image(Data)
}

nonisolated protocol ScreenRegionCapturing: Sendable {
  func captureRegion() async -> ScreenRegionCaptureResult
}

// The system's interactive region selection: `screencapture -i -x` into the
// app's temporary directory (the container's tmp when sandboxed). The app
// sandbox lets apps run /usr/sbin tools, and Apple's sandbox profile has a
// rule for screencapture's interactive mode, so this works sandboxed.
// screencapture checks the Screen Recording permission against the
// responsible process, i.e. Scratchboard.
nonisolated struct InteractiveScreenCapture: ScreenRegionCapturing {
  func captureRegion() async -> ScreenRegionCaptureResult {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("screen-capture-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-i", "-x", url.path]
    do {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
          try process.run()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    } catch {
      NSLog("Failed to run screencapture: \(error)")
      return .cancelled
    }

    guard let data = try? Data(contentsOf: url), !data.isEmpty else {
      return .cancelled
    }
    return .image(data)
  }
}

struct ScreenRecordingPermission {
  var isGranted: @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }
  // Shows the system prompt the first time; later calls return right away.
  var request: @MainActor () -> Void = { _ = CGRequestScreenCaptureAccess() }
}

// Capture a screen region, recognise its text, copy it as a clip and open the
// chat on it so the recognised text can be reviewed and fixed (#12).
final class ScreenTextCapture {
  enum Outcome: Equatable {
    case busy
    case cancelled
    case noText
    // Text is on the clipboard but no chat opened (e.g. Scratchboard is
    // ignoring copies, so the clip didn't land in history).
    case copied
    case chatStarted
  }

  static let noTextMessage = "No text found"
  static let permissionMessage = "Scratchboard can't see other apps' windows. " +
    "Allow it in System Settings → Privacy & Security → Screen Recording."

  static let shared = ScreenTextCapture()

  private let capturer: any ScreenRegionCapturing
  private let clipboard: Clipboard
  private let provider: @MainActor () -> (any LLMProvider)?
  private let storedItem: @MainActor (HistoryItem) -> HistoryItemDecorator?
  private let closePanel: @MainActor () -> Void
  private let openPanel: @MainActor () -> Void
  private let permission: ScreenRecordingPermission
  private let notify: @MainActor (String) -> Void

  private(set) var isCapturing = false
  // The item the clipboard's latest check produced.
  private var copiedItem: HistoryItem?

  // Tests inject the capture, a private pasteboard and keep the clip out of
  // `History.shared` and the real panel.
  init(
    capturer: any ScreenRegionCapturing = InteractiveScreenCapture(),
    clipboard: Clipboard = .shared,
    provider: @escaping @MainActor () -> (any LLMProvider)? = LLMProviderFactory.makeCurrent,
    storedItem: @escaping @MainActor (HistoryItem) -> HistoryItemDecorator? = { History.shared.storedItem(for: $0) },
    closePanel: @escaping @MainActor () -> Void = {
      if !AppState.shared.popup.isClosed() { AppState.shared.popup.close() }
    },
    openPanel: @escaping @MainActor () -> Void = { AppState.shared.popup.open(height: AppState.shared.popup.height) },
    permission: ScreenRecordingPermission = ScreenRecordingPermission(),
    notify: @escaping @MainActor (String) -> Void = { Notifier.notify(body: $0, sound: nil) }
  ) {
    self.capturer = capturer
    self.clipboard = clipboard
    self.provider = provider
    self.storedItem = storedItem
    self.closePanel = closePanel
    self.openPanel = openPanel
    self.permission = permission
    self.notify = notify
    clipboard.onNewCopy { [weak self] item in self?.copiedItem = item }
  }

  func start() {
    Task { _ = await run() }
  }

  @discardableResult
  func run() async -> Outcome {
    guard !isCapturing else { return .busy }
    isCapturing = true
    defer { isCapturing = false }

    // The selection overlay needs the screen; a chat can't open over another.
    closePanel()

    let result = await capturer.captureRegion()
    let isPermitted = permission.isGranted()
    if !isPermitted {
      permission.request()
      notify(Self.permissionMessage)
    }

    guard case .image(let data) = result else { return .cancelled }

    let text = (await TextRecognizer.recognizeText(imageData: data) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      if isPermitted {
        notify(Self.noTextMessage)
      }
      return .noText
    }

    // The normal copy path, so the text lands in history like any copy.
    copiedItem = nil
    clipboard.copyInScratchboard(text)
    guard let copiedItem, let item = storedItem(copiedItem) else { return .copied }
    self.copiedItem = nil

    let appState = AppState.shared
    openPanel()
    appState.navigator.select(item: item)
    appState.startChat(provider: provider, clipboard: clipboard)
    return appState.chat != nil ? .chatStarted : .copied
  }
}
