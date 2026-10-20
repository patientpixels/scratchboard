import AppKit
import Defaults
import Foundation
import SwiftData
import XCTest
@testable import Scratchboard

// Gives each test a private pasteboard and a clean history.
@MainActor
class ChatTestCase: XCTestCase {
  private let savedKeepEditHistory = Defaults[.keepEditHistory]
  var pasteboard: NSPasteboard!
  var clipboard: Clipboard!

  override func setUp() async throws {
    try await super.setUp()
    History.shared.clearAll()
    Defaults[.keepEditHistory] = true
    pasteboard = NSPasteboard(name: NSPasteboard.Name("ScratchboardTests.\(UUID().uuidString)"))
    clipboard = Clipboard(pasteboard: pasteboard)
  }

  override func tearDown() async throws {
    Defaults[.keepEditHistory] = savedKeepEditHistory
    pasteboard.releaseGlobally()
    History.shared.clearAll()
    try await super.tearDown()
  }

  func assertPasteboard(
    _ string: String,
    transient: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(pasteboard.string(forType: .string), string, file: file, line: line)
    let types = pasteboard.types ?? []
    XCTAssertEqual(types.contains(.transient), transient, file: file, line: line)
    XCTAssertTrue(types.contains(.fromScratchboard), file: file, line: line)
  }

  func editSessionCount() throws -> Int {
    try Storage.shared.context.fetchCount(FetchDescriptor<EditSession>())
  }

  func kinds(_ transcript: [TranscriptEntry]) -> [String] {
    transcript.map { entry in
      switch entry {
      case .user(_, let text): "user:\(text)"
      case .assistant(_, let text): "assistant:\(text)"
      case .version(_, let number, let author, let restoredFrom):
        "version:\(number):\(author.rawValue):\(restoredFrom.map(String.init) ?? "-")"
      case .pointer(_, let number): "pointer:\(number)"
      case .error(_, let message): "error:\(message)"
      }
    }
  }
}

// Provider that plays back one scripted turn per `run` call and records what
// it was sent.
nonisolated final class ScriptedProvider: LLMProvider, @unchecked Sendable {
  enum Step: Sendable {
    case text(String)
    case call(String, JSONValue)
    case wait(Duration)
    case fail(LLMError)
  }

  let displayName = "Scripted"

  private let lock = NSLock()
  private var turns: [[Step]]
  private var _instructions: [String] = []
  private var _messages: [[LLMMessage]] = []
  private var _toolResults: [String] = []

  init(_ turns: [[Step]]) {
    self.turns = turns
  }

  var instructions: [String] { lock.withLock { _instructions } }
  var messages: [[LLMMessage]] { lock.withLock { _messages } }
  var toolResults: [String] { lock.withLock { _toolResults } }

  func run(
    instructions: String,
    messages: [LLMMessage],
    tools: [LLMTool]
  ) -> AsyncThrowingStream<LLMEvent, Error> {
    let steps = lock.withLock {
      _instructions.append(instructions)
      _messages.append(messages)
      return turns.isEmpty ? [] : turns.removeFirst()
    }

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for step in steps {
            switch step {
            case .text(let text):
              continuation.yield(.textDelta(text))
            case .call(let name, let arguments):
              guard let tool = tools.first(where: { $0.name == name }) else {
                throw LLMError.invalidResponse("Unknown tool \(name)")
              }
              continuation.yield(.toolCall(name: name, arguments: arguments))
              let result = try await tool.execute(arguments)
              self.lock.withLock { self._toolResults.append(result) }
              continuation.yield(.toolResult(name: name, result: result))
            case .wait(let duration):
              try await Task.sleep(for: duration)
            case .fail(let error):
              throw error
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

@MainActor
func waitUntil(
  timeout: Duration = .seconds(5),
  file: StaticString = #filePath,
  line: UInt = #line,
  _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else {
      XCTFail("Timed out waiting for condition", file: file, line: line)
      return
    }
    try await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor
func textItem(_ text: String) -> HistoryItem {
  let item = HistoryItem()
  Storage.shared.context.insert(item)
  item.contents = [
    HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))
  ]
  item.title = item.generateTitle()
  return item
}
