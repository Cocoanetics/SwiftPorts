import Foundation

/// A pipeline input value for `POST /projects/:id/pipeline`: a string,
/// integer, float, boolean, or array of strings (glab's `string(…)`,
/// `int(…)`, `float(…)`, `bool(…)`, `array(…)` input types).
public enum PipelineInputValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case float(Double)
    case bool(Bool)
    case array([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .float(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .array(try container.decode([String].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .float(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        }
    }
}
