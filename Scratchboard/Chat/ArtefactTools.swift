import Foundation

// Tools the model uses to change the artefact. Execution hops to the main
// actor and mutates the session, but only while the turn that created the
// tools is still running.
enum ArtefactTools {
  static let writeName = "write_artefact"
  static let restoreName = "restore_version"

  static func make(for session: ChatSession, turn: UUID) -> [LLMTool] {
    [
      LLMTool(
        name: writeName,
        description: """
          Replace the artefact with a new version. Pass the complete new text, exactly as it should be \
          pasted: no preamble, no explanations, no surrounding code fences.
          """,
        parameters: .object([
          "type": .string("object"),
          "properties": .object([
            "text": .object([
              "type": .string("string"),
              "description": .string("The complete text of the new version.")
            ])
          ]),
          "required": .array([.string("text")])
        ]),
        execute: { @MainActor [weak session] arguments in
          guard let session else { throw CancellationError() }
          guard let text = arguments["text"]?.stringValue else {
            return "Error: missing string argument \"text\"."
          }
          return try session.writeArtefact(text, turn: turn)
        }
      ),
      LLMTool(
        name: restoreName,
        description: """
          Make an earlier version current again by copying it as a new version. Use this instead of \
          rewriting an earlier version's text.
          """,
        parameters: .object([
          "type": .string("object"),
          "properties": .object([
            "version": .object([
              "type": .string("integer"),
              "description": .string("The number of the version to restore, e.g. 2 for v2.")
            ])
          ]),
          "required": .array([.string("version")])
        ]),
        execute: { @MainActor [weak session] arguments in
          guard let session else { throw CancellationError() }
          guard let number = versionNumber(arguments["version"] ?? arguments["n"]) else {
            return "Error: missing integer argument \"version\"."
          }
          return try session.restoreVersion(number, turn: turn)
        }
      )
    ]
  }

  // Accepts 2, "2" and "v2".
  nonisolated static func versionNumber(_ value: JSONValue?) -> Int? {
    if let number = value?.intValue {
      return number
    }
    guard var string = value?.stringValue?.trimmingCharacters(in: .whitespaces) else {
      return nil
    }
    if string.lowercased().hasPrefix("v") {
      string.removeFirst()
    }
    return Int(string)
  }
}
