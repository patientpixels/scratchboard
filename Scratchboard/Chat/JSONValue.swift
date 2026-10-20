import Foundation

// Minimal JSON value used for tool parameter schemas and tool-call arguments.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  subscript(key: String) -> JSONValue? {
    guard case .object(let object) = self else { return nil }
    return object[key]
  }

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var intValue: Int? {
    guard case .number(let value) = self else { return nil }
    return Int(exactly: value)
  }

  static func parse(_ json: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
  }

  func jsonString() throws -> String {
    String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
  }
}
