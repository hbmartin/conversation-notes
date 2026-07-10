import Foundation

/// The subset of the Anthropic Messages API wire format this app uses.
/// Snake_case is handled with explicit `CodingKeys` throughout.

enum AnthropicModel {
  static let opus = "claude-opus-4-8"
}

// MARK: - JSONValue

/// An arbitrary JSON value, used for tool input/schema literals and for round-tripping content
/// block types we don't model explicitly.
enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([JSONValue].self) {
      self = .array(array)
    } else if let object = try? container.decode([String: JSONValue].self) {
      self = .object(object)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value"
      )
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let string): try container.encode(string)
    case .number(let number): try container.encode(number)
    case .bool(let bool): try container.encode(bool)
    case .null: try container.encodeNil()
    case .array(let array): try container.encode(array)
    case .object(let object): try container.encode(object)
    }
  }
}

extension JSONValue {
  init(parsing json: String) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
  }

  func encodedData() throws -> Data {
    try JSONEncoder().encode(self)
  }
}

// MARK: - Request

struct MessagesRequest: Encodable, Sendable {
  var model: String = AnthropicModel.opus
  var maxTokens: Int
  var system: String?
  var messages: [AnthropicMessage]
  var tools: [AnthropicTool]?
  var outputConfig: OutputConfig?

  private enum CodingKeys: String, CodingKey {
    case model
    case maxTokens = "max_tokens"
    case system
    case messages
    case tools
    case outputConfig = "output_config"
  }
}

struct AnthropicMessage: Codable, Equatable, Sendable {
  var role: Role
  var content: [ContentBlock]

  enum Role: String, Codable, Sendable {
    case user
    case assistant
  }
}

enum ContentBlock: Codable, Equatable, Sendable {
  case text(String)
  case toolUse(id: String, name: String, input: JSONValue)
  case toolResult(toolUseID: String, content: String, isError: Bool?)
  /// Thinking blocks and any future block types round-trip verbatim so echoing assistant
  /// content back to the API never corrupts a turn.
  case unknown(JSONValue)

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case id
    case name
    case input
    case toolUseID = "tool_use_id"
    case content
    case isError = "is_error"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "text":
      self = .text(try container.decode(String.self, forKey: .text))
    case "tool_use":
      self = .toolUse(
        id: try container.decode(String.self, forKey: .id),
        name: try container.decode(String.self, forKey: .name),
        input: try container.decode(JSONValue.self, forKey: .input)
      )
    case "tool_result":
      self = .toolResult(
        toolUseID: try container.decode(String.self, forKey: .toolUseID),
        content: try container.decode(String.self, forKey: .content),
        isError: try container.decodeIfPresent(Bool.self, forKey: .isError)
      )
    default:
      self = .unknown(try JSONValue(from: decoder))
    }
  }

  func encode(to encoder: any Encoder) throws {
    switch self {
    case .text(let text):
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .toolUse(let id, let name, let input):
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("tool_use", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(name, forKey: .name)
      try container.encode(input, forKey: .input)
    case .toolResult(let toolUseID, let content, let isError):
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("tool_result", forKey: .type)
      try container.encode(toolUseID, forKey: .toolUseID)
      try container.encode(content, forKey: .content)
      try container.encodeIfPresent(isError, forKey: .isError)
    case .unknown(let raw):
      try raw.encode(to: encoder)
    }
  }
}

struct AnthropicTool: Encodable, Equatable, Sendable {
  var name: String
  var description: String
  var strict = true
  var inputSchema: JSONValue

  private enum CodingKeys: String, CodingKey {
    case name
    case description
    case strict
    case inputSchema = "input_schema"
  }
}

struct OutputConfig: Encodable, Sendable {
  var format: Format?

  struct Format: Encodable, Sendable {
    var type = "json_schema"
    var schema: JSONValue
  }
}

// MARK: - Response

struct MessagesResponse: Decodable, Sendable {
  var id: String
  var model: String
  var content: [ContentBlock]
  var stopReason: StopReason
  var usage: Usage

  private enum CodingKeys: String, CodingKey {
    case id
    case model
    case content
    case stopReason = "stop_reason"
    case usage
  }

  struct Usage: Decodable, Sendable {
    var inputTokens: Int
    var outputTokens: Int

    private enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case outputTokens = "output_tokens"
    }
  }
}

extension MessagesResponse {
  var text: String {
    content
      .compactMap {
        if case .text(let text) = $0 { return text } else { return nil }
      }
      .joined()
  }

  var firstToolUse: (id: String, name: String, input: JSONValue)? {
    for block in content {
      if case .toolUse(let id, let name, let input) = block {
        return (id, name, input)
      }
    }
    return nil
  }
}

enum StopReason: Equatable, Sendable, Decodable {
  case endTurn
  case toolUse
  case maxTokens
  case refusal
  case stopSequence
  case pauseTurn
  case unknown(String)

  init(from decoder: any Decoder) throws {
    switch try decoder.singleValueContainer().decode(String.self) {
    case "end_turn": self = .endTurn
    case "tool_use": self = .toolUse
    case "max_tokens": self = .maxTokens
    case "refusal": self = .refusal
    case "stop_sequence": self = .stopSequence
    case "pause_turn": self = .pauseTurn
    case let other: self = .unknown(other)
    }
  }
}

struct APIErrorEnvelope: Decodable, Sendable {
  var error: Inner

  struct Inner: Decodable, Sendable {
    var type: String
    var message: String
  }
}
