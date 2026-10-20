import Foundation
import XCTest
@testable import Scratchboard

// Model evaluation, not a regular test: runs the real chat loop (instructions,
// tools, OpenAI-compatible provider) against local models on fixed clips and
// prompts and prints a Markdown report. Run with `scripts/eval <model>...`;
// skipped unless SCRATCHBOARD_EVAL_MODELS is set.
final class ModelEvalTests: ChatTestCase {
  private struct EvalTask {
    let name: String
    let clip: String
    let prompt: String
    let check: (String) -> Bool
  }

  private struct Row {
    let model: String
    let task: String
    let passed: Bool
    let toolCalled: Bool
    let leaked: Bool
    let seconds: Double
    let error: String?
    let result: String
  }

  private static let instructionsClip = """
  Copy a few lines of text from anywhere. History starts empty, so you need something to work on.
  ⇧⌘C opens the panel. Arrow to the clip.
  Tab opens the chat, then type a prompt, e.g. "make this a bullet list". ↩ adds a newline, ⌘↩ sends.
  The new version (v2) shows at the top and is already on the clipboard. Send another prompt, or edit the text yourself (Tab jumps from the prompt to the text).
  ⌘Z / ⇧⌘Z step back and forward through versions. The transcript keeps everything.
  Esc closes, then ⌘V anywhere pastes the current version.
  Open the panel again and press Tab on the same clip: the session resumes where you left off.
  """

  private static let typoClip = """
  Thnaks for the quick turnarund on the contract. I've reviwed sections 2 and 3 and have a few \
  questoins about the payment terms before we sign.
  """

  private static let csvClip = """
  name, role, start
  Ada, engineer, 2024
  Grace, admiral, 2023
  """

  private static func lines(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  private let tasks: [EvalTask] = [
    EvalTask(name: "indent", clip: instructionsClip, prompt: "indent") { result in
      let original = lines(instructionsClip)
      let edited = lines(result)
      return edited.count == original.count
        && edited.allSatisfy { $0.first == " " || $0.first == "\t" }
        && edited.map { $0.trimmingCharacters(in: .whitespaces) } == original
    },
    EvalTask(name: "bullets", clip: instructionsClip, prompt: "make this a bullet list") { result in
      let bullets = lines(result).filter { line in
        ["- ", "* ", "• ", "– "].contains { line.trimmingCharacters(in: .whitespaces).hasPrefix($0) }
      }
      return bullets.count >= 6 && result.contains("Esc closes") && result.contains("Copy a few lines")
    },
    EvalTask(name: "shorter", clip: instructionsClip, prompt: "shorter") { result in
      let ratio = Double(result.count) / Double(instructionsClip.count)
      return ratio > 0.2 && ratio < 0.8
    },
    EvalTask(name: "typos", clip: typoClip, prompt: "fix typos") { result in
      let fixed = ["Thanks", "turnaround", "reviewed", "questions"].allSatisfy(result.contains)
      let leftover = ["Thnaks", "turnarund", "reviwed", "questoins"].contains(where: result.contains)
      let ratio = Double(result.count) / Double(typoClip.count)
      return fixed && !leftover && ratio > 0.85 && ratio < 1.15
    },
    EvalTask(name: "table", clip: csvClip, prompt: "make this a markdown table") { result in
      // GitHub-flavoured Markdown doesn't require leading pipes.
      let rows = lines(result).filter { $0.contains("|") }
      return rows.count >= 4 && result.contains("---") && result.contains("Ada") && result.contains("Grace")
    }
  ]

  private var environment: [String: String] { ProcessInfo.processInfo.environment }

  func testModels() async throws {
    let models = (environment["SCRATCHBOARD_EVAL_MODELS"] ?? "")
      .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !models.isEmpty else { throw XCTSkip("Set SCRATCHBOARD_EVAL_MODELS (see scripts/eval)") }
    let runs = Int(environment["SCRATCHBOARD_EVAL_RUNS"] ?? "") ?? 2
    let baseURL = try XCTUnwrap(URL(string: environment["SCRATCHBOARD_EVAL_BASE_URL"].flatMap { $0.isEmpty ? nil : $0 }
      ?? "http://localhost:11434/v1"))

    var rows: [Row] = []
    var loadTimes: [String: Double] = [:]
    for model in models {
      let provider = OpenAICompatibleProvider(baseURL: baseURL, model: model, apiKey: nil)
      loadTimes[model] = await warmUp(provider)
      for task in tasks {
        for _ in 1...runs {
          rows.append(await evaluate(task, model: model, provider: provider))
        }
      }
    }
    print(report(rows, models: models, runs: runs, loadTimes: loadTimes))
  }

  // Loads the model so the first task doesn't pay for it.
  private func warmUp(_ provider: OpenAICompatibleProvider) async -> Double {
    let start = ContinuousClock.now
    let stream = provider.run(instructions: "Reply with OK.", messages: [LLMMessage(role: .user, content: "Hi")], tools: [])
    do {
      for try await _ in stream {}
    } catch {}
    return (ContinuousClock.now - start).seconds
  }

  private func evaluate(_ task: EvalTask, model: String, provider: OpenAICompatibleProvider) async -> Row {
    let recorder = RecordingProvider(provider)
    guard let session = ChatSession.open(for: textItem(task.clip), provider: recorder, clipboard: clipboard) else {
      return Row(model: model, task: task.name, passed: false, toolCalled: false, leaked: false,
                 seconds: 0, error: "no session", result: "")
    }

    let start = ContinuousClock.now
    session.send(task.prompt)
    while session.isRunning, ContinuousClock.now - start < .seconds(240) {
      try? await Task.sleep(for: .milliseconds(50))
    }
    if session.isRunning { session.cancel() }
    let seconds = (ContinuousClock.now - start).seconds

    let result = session.versions.count > 1 ? (session.current?.text ?? "") : ""
    let error = session.transcript.compactMap { entry -> String? in
      if case .error(_, let message) = entry { return message }
      return nil
    }.first
    let leaked = recorder.rawText.contains("<artefact") || recorder.rawText.contains("Request:")
      || (task.clip.count > 40 && recorder.rawText.contains(String(task.clip.prefix(40))))
    return Row(
      model: model,
      task: task.name,
      passed: !result.isEmpty && task.check(result),
      toolCalled: recorder.toolCalls > 0,
      leaked: leaked,
      seconds: seconds,
      error: error ?? (seconds >= 240 ? "timeout" : nil),
      result: result
    )
  }

  private func report(_ rows: [Row], models: [String], runs: Int, loadTimes: [String: Double]) -> String {
    func median(_ values: [Double]) -> Double {
      let sorted = values.sorted()
      return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    var out = ["SCRATCHBOARD_EVAL_REPORT_BEGIN", "# Model evaluation", "",
               "\(tasks.count) tasks × \(runs) runs per model, real chat loop via the OpenAI-compatible provider.", "",
               "| Model | Passed | Tool called | Leaked into chat | Median turn | Load |",
               "|---|---|---|---|---|---|"]
    for model in models {
      let modelRows = rows.filter { $0.model == model }
      out.append("| `\(model)` | \(modelRows.filter(\.passed).count)/\(modelRows.count) "
        + "| \(modelRows.filter(\.toolCalled).count)/\(modelRows.count) "
        + "| \(modelRows.filter(\.leaked).count) "
        + "| \(String(format: "%.1f s", median(modelRows.map(\.seconds)))) "
        + "| \(String(format: "%.1f s", loadTimes[model] ?? 0)) |")
    }

    out += ["", "## Per task", "", "| Model | " + tasks.map(\.name).joined(separator: " | ") + " |",
            "|---|" + tasks.map { _ in "---|" }.joined()]
    for model in models {
      let cells = tasks.map { task -> String in
        let taskRows = rows.filter { $0.model == model && $0.task == task.name }
        return "\(taskRows.filter(\.passed).count)/\(taskRows.count) · \(String(format: "%.0fs", median(taskRows.map(\.seconds))))"
      }
      out.append("| `\(model)` | " + cells.joined(separator: " | ") + " |")
    }

    out += ["", "## Failures", ""]
    for row in rows where !row.passed {
      let detail = row.error ?? (row.result.isEmpty ? "no new version" : "check failed")
      let excerpt = row.result.prefix(160).replacingOccurrences(of: "\n", with: "⏎")
      out.append("- `\(row.model)` \(row.task): \(detail)\(excerpt.isEmpty ? "" : " — `\(excerpt)`")")
    }
    out.append("SCRATCHBOARD_EVAL_REPORT_END")
    return out.joined(separator: "\n")
  }
}

// Passes events through and records what the model did before ChatSession
// sanitizes it.
private nonisolated final class RecordingProvider: LLMProvider, @unchecked Sendable {
  private let inner: any LLMProvider
  private let lock = NSLock()
  private var _rawText = ""
  private var _toolCalls = 0

  var displayName: String { inner.displayName }
  var rawText: String { lock.withLock { _rawText } }
  var toolCalls: Int { lock.withLock { _toolCalls } }

  init(_ inner: any LLMProvider) {
    self.inner = inner
  }

  func run(instructions: String, messages: [LLMMessage], tools: [LLMTool]) -> AsyncThrowingStream<LLMEvent, Error> {
    let upstream = inner.run(instructions: instructions, messages: messages, tools: tools)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await event in upstream {
            switch event {
            case .textDelta(let delta): lock.withLock { _rawText += delta }
            case .toolCall(let name, _) where name == "write_artefact": lock.withLock { _toolCalls += 1 }
            default: break
            }
            continuation.yield(event)
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

private extension Duration {
  var seconds: Double {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
