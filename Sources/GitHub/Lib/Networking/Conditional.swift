/// Result of a conditional GET request.
public enum Conditional<Value> {
    case modified(Value, etag: String?)
    case notModified
}

extension Conditional: Sendable where Value: Sendable {}
