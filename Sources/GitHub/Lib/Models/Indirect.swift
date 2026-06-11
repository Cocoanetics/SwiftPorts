import Foundation

/// A reference-boxed value, so a struct can hold a value of its own
/// type (`Repository.parent` is itself a `Repository`; direct storage
/// would make the struct infinitely sized).
///
/// Encodes and decodes transparently — the box never appears in the
/// JSON. Optional wrapped values behave like plain optionals: a
/// missing key or JSON `null` decodes as `nil`, and `nil` is omitted
/// on encode (via the container overloads below; without them,
/// synthesized Codable would throw `.keyNotFound` on absent keys and
/// emit `"key": null` for `nil`).
@propertyWrapper
public struct Indirect<Wrapped> {
    // Immutability makes the box safe to share; the conditional
    // Sendable conformance below gates it on `Wrapped: Sendable`.
    private final class Box: @unchecked Sendable {
        let value: Wrapped
        init(_ value: Wrapped) { self.value = value }
    }

    private let box: Box

    public var wrappedValue: Wrapped { box.value }

    public init(wrappedValue: Wrapped) {
        box = Box(wrappedValue)
    }
}

extension Indirect: Sendable where Wrapped: Sendable {}

extension Indirect: Codable where Wrapped: Codable {
    public init(from decoder: Decoder) throws {
        self.init(wrappedValue: try Wrapped(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension KeyedDecodingContainer {
    public func decode<T: Codable>(
        _ type: Indirect<T?>.Type,
        forKey key: Key
    ) throws -> Indirect<T?> {
        Indirect(wrappedValue: try decodeIfPresent(Indirect<T>.self, forKey: key)?.wrappedValue)
    }
}

extension KeyedEncodingContainer {
    public mutating func encode<T: Codable>(
        _ value: Indirect<T?>,
        forKey key: Key
    ) throws {
        guard let wrapped = value.wrappedValue else { return }
        try encode(wrapped, forKey: key)
    }
}
