#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Synchronization

// Exposes an LLMTool to FoundationModels, which runs the tool loop itself.
@available(macOS 26, *)
nonisolated struct AppleTool: Tool {
  let name: String
  let description: String
  let parameters: GenerationSchema
  private let execute: @Sendable (JSONValue) async throws -> String
  private let counter: AppleToolCallCounter
  private let emit: @Sendable (LLMEvent) -> Void

  init(
    _ tool: LLMTool,
    counter: AppleToolCallCounter,
    emit: @escaping @Sendable (LLMEvent) -> Void
  ) throws {
    name = tool.name
    description = tool.description
    parameters = try AppleSchema.generationSchema(name: tool.name, parameters: tool.parameters)
    execute = tool.execute
    self.counter = counter
    self.emit = emit
  }

  @concurrent func call(arguments: GeneratedContent) async throws -> String {
    try counter.increment()
    try Task.checkCancellation()
    let json = JSONValue(arguments)
    emit(.toolCall(name: name, arguments: json))
    let result = try await execute(json)
    emit(.toolResult(name: name, result: result))
    return result
  }
}

@available(macOS 26, *)
nonisolated final class AppleToolCallCounter: Sendable {
  private let count = Mutex(0)

  func increment() throws {
    try count.withLock { count in
      count += 1
      if count > maxToolIterations {
        throw LLMError.tooManyToolIterations
      }
    }
  }
}

// Converts the JSON Schema subset used by the app's tools: objects, strings
// (optionally `enum`), integers, numbers, booleans and arrays.
@available(macOS 26, *)
nonisolated enum AppleSchema {
  static func generationSchema(name: String, parameters: JSONValue) throws -> GenerationSchema {
    try GenerationSchema(root: dynamicSchema(name: name, json: parameters), dependencies: [])
  }

  static func dynamicSchema(name: String, json: JSONValue) throws -> DynamicGenerationSchema {
    let description = json["description"]?.stringValue
    if case .array(let choices)? = json["enum"] {
      return DynamicGenerationSchema(
        name: name,
        description: description,
        anyOf: choices.compactMap(\.stringValue)
      )
    }

    switch json["type"]?.stringValue {
    case "object":
      guard case .object(let properties)? = json["properties"] ?? .object([:]) else {
        throw LLMError.invalidResponse("Unsupported tool schema for \(name)")
      }
      var required: [String] = []
      if case .array(let names)? = json["required"] {
        required = names.compactMap(\.stringValue).filter { properties[$0] != nil }
      }
      let order = required + properties.keys.filter { !required.contains($0) }.sorted()
      return DynamicGenerationSchema(
        name: name,
        description: description,
        properties: try order.map { key in
          let property = properties[key] ?? .object([:])
          return DynamicGenerationSchema.Property(
            name: key,
            description: property["description"]?.stringValue,
            schema: try dynamicSchema(name: "\(name)_\(key)", json: property),
            isOptional: !required.contains(key)
          )
        }
      )
    case "array":
      return DynamicGenerationSchema(
        arrayOf: try dynamicSchema(name: "\(name)_item", json: json["items"] ?? .object([:])),
        minimumElements: json["minItems"]?.intValue,
        maximumElements: json["maxItems"]?.intValue
      )
    case "string":
      return DynamicGenerationSchema(type: String.self)
    case "integer":
      return DynamicGenerationSchema(type: Int.self)
    case "number":
      return DynamicGenerationSchema(type: Double.self)
    case "boolean":
      return DynamicGenerationSchema(type: Bool.self)
    default:
      throw LLMError.invalidResponse("Unsupported tool schema for \(name)")
    }
  }
}

@available(macOS 26, *)
nonisolated extension JSONValue {
  init(_ content: GeneratedContent) {
    switch content.kind {
    case .null:
      self = .null
    case .bool(let value):
      self = .bool(value)
    case .number(let value):
      self = .number(value)
    case .string(let value):
      self = .string(value)
    case .array(let elements):
      self = .array(elements.map(JSONValue.init))
    case .structure(let properties, _):
      self = .object(properties.mapValues(JSONValue.init))
    @unknown default:
      self = (try? JSONValue.parse(content.jsonString)) ?? .null
    }
  }
}
#endif
