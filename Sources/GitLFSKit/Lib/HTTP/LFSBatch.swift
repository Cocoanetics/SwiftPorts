import Foundation
import HTTPTypes
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `lfshttp.MediaType` and the charset `NewRequest` puts on `Content-Type`.
public enum LFSMediaType {
    public static let json = "application/vnd.git-lfs+json"
    public static let requestContentType = json + "; charset=utf-8"
}

/// `tq.ObjectError`. ``description`` is `ObjectError.Error`.
public struct LFSObjectError: Error, Sendable, Equatable, CustomStringConvertible, Encodable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "[\(code)] \(message)" }
}

/// `tq.batchRef`. An empty name is omitted; the object itself is always sent.
public struct LFSBatchRef: Sendable, Equatable, Encodable {
    public var name: String

    public init(name: String = "") { self.name = name }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !name.isEmpty { try container.encode(name, forKey: .name) }
    }

    private enum CodingKeys: String, CodingKey { case name }
}

/// One `actions` or `_links` entry (`tq.Action`).
public struct LFSBatchAction: Sendable, Equatable {
    public var href: String
    public var header: [String: String]
    public var expiresAt: Date?
    /// Seconds from ``requestedAt``. Non-zero wins over ``expiresAt``.
    public var expiresIn: Int
    /// When the batch request was sent (`Action.createdAt`).
    public var requestedAt: Date

    /// `tq.objectExpirationToTransfer`.
    public static let expirationLead: TimeInterval = 5

    public init(
        href: String,
        header: [String: String] = [:],
        expiresAt: Date? = nil,
        expiresIn: Int = 0,
        requestedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.href = href
        self.header = header
        self.expiresAt = expiresAt
        self.expiresIn = expiresIn
        self.requestedAt = requestedAt
    }

    /// `tools.TimeAtOrIn`. A non-zero ``expiresIn`` wins over ``expiresAt``.
    public func expiration() -> Date? {
        if expiresIn != 0 {
            return requestedAt.addingTimeInterval(TimeInterval(expiresIn))
        }
        return expiresAt
    }

    /// Already expired, or expiring within `lead` (`tools.IsExpiredAtOrIn`).
    public func isExpired(
        within lead: TimeInterval = LFSBatchAction.expirationLead, now: Date = Date()
    ) -> Bool {
        guard let expiration = expiration() else { return false }
        return expiration < now.addingTimeInterval(lead)
    }
}

extension LFSBatchAction: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(href, forKey: .href)
        if !header.isEmpty { try container.encode(header, forKey: .header) }
        if let expiresAt { try container.encode(expiresAt, forKey: .expiresAt) }
        if expiresIn != 0 { try container.encode(expiresIn, forKey: .expiresIn) }
    }

    private enum CodingKeys: String, CodingKey {
        case href, header
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
    }
}

/// One batch object (`tq.Transfer`). Empty `name`, `path`, `authenticated`,
/// `actions`, `_links` and `error` are left out, matching `encoding/json`.
public struct LFSBatchObject: Sendable, Equatable {
    public var name: String
    public var oid: String
    public var size: Int64
    public var authenticated: Bool
    public var actions: [String: LFSBatchAction]
    public var links: [String: LFSBatchAction]
    public var error: LFSObjectError?
    public var path: String

    public init(oid: String, size: Int64, name: String = "", path: String = "") {
        self.name = name
        self.oid = oid
        self.size = size
        self.authenticated = false
        self.actions = [:]
        self.links = [:]
        self.error = nil
        self.path = path
    }

    /// `Transfer.Rel`: an `actions` entry wins over `_links`.
    public func action(named name: String) -> LFSBatchAction? {
        if let action = actions[name] { return action }
        return links[name]
    }

    /// `Wrapf(o.Error, "[%v] %v", o.Oid, o.Error.Message)`.
    /// The server's message is kept on both sides of the colon.
    public var errorText: String? {
        guard let error else { return nil }
        return "[\(oid)] \(error.message): \(error)"
    }

    mutating func stamp(_ requestedAt: Date) {
        for name in Array(actions.keys) {
            guard var action = actions[name] else { continue }
            action.requestedAt = requestedAt
            actions[name] = action
        }
        for name in Array(links.keys) {
            guard var action = links[name] else { continue }
            action.requestedAt = requestedAt
            links[name] = action
        }
    }
}

extension LFSBatchObject: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !name.isEmpty { try container.encode(name, forKey: .name) }
        if !oid.isEmpty { try container.encode(oid, forKey: .oid) }
        try container.encode(size, forKey: .size)
        if authenticated { try container.encode(authenticated, forKey: .authenticated) }
        if !actions.isEmpty { try container.encode(actions, forKey: .actions) }
        if !links.isEmpty { try container.encode(links, forKey: .links) }
        if let error { try container.encode(error, forKey: .error) }
        if !path.isEmpty { try container.encode(path, forKey: .path) }
    }

    private enum CodingKeys: String, CodingKey {
        case name, oid, size, authenticated, actions, path, error
        case links = "_links"
    }
}

/// `tq.BatchResponse`, plus the endpoint the request was addressed to.
public struct LFSBatchResponse: Sendable, Equatable {
    public var objects: [LFSBatchObject]
    public var transfer: String
    public var hashAlgorithm: String
    public var endpoint: LFSEndpoint

    public init(
        objects: [LFSBatchObject] = [],
        transfer: String = "",
        hashAlgorithm: String = "",
        endpoint: LFSEndpoint = LFSEndpoint()
    ) {
        self.objects = objects
        self.transfer = transfer
        self.hashAlgorithm = hashAlgorithm
        self.endpoint = endpoint
    }

    mutating func stamp(_ requestedAt: Date) {
        for index in objects.indices {
            objects[index].stamp(requestedAt)
        }
    }

    func expiresSoon(_ operation: String, now: Date = Date()) -> Bool {
        objects.contains { object in
            guard let action = object.action(named: operation) else { return false }
            return action.isExpired(now: now)
        }
    }
}

/// Adapters this build can name. Only `basic` is registered, and
/// `lfs.basictransfersonly=true` is that same list. `ssh`, `tus` and
/// `lfs-standalone-file` are not advertised.
enum LFSTransferAdapters {
    static let registered = ["basic"]

    static func names(basicTransfersOnly: Bool) -> [String] {
        if basicTransfersOnly { return ["basic"] }
        return registered
    }

    /// `tqClient.Batch` drops `transfers` when the list is exactly `["basic"]`.
    static func advertised(_ names: [String]) -> [String]? {
        if names.count == 1, names.first == "basic" { return nil }
        if names.isEmpty { return nil }
        return names
    }
}

// Field order is encoding/json struct order. JSONEncoder does not keep it.
enum LFSBatchEncoding {
    static func data(
        operation: String,
        objects: [LFSBatchObject],
        transfers: [String],
        ref: LFSBatchRef
    ) -> Data {
        var json = JSONText()
        json.beginObject()
        json.key("operation")
        json.string(operation)
        json.key("objects")
        json.beginArray()
        for object in objects { write(object, into: &json) }
        json.endArray()
        if let names = LFSTransferAdapters.advertised(transfers) {
            json.key("transfers")
            json.beginArray()
            for name in names { json.string(name) }
            json.endArray()
        }
        json.key("ref")
        write(ref, into: &json)
        json.key("hash_algo")
        json.string("sha256")
        json.endObject()
        return json.data
    }

    private static func write(_ ref: LFSBatchRef, into json: inout JSONText) {
        json.beginObject()
        if !ref.name.isEmpty {
            json.key("name")
            json.string(ref.name)
        }
        json.endObject()
    }

    private static func write(_ object: LFSBatchObject, into json: inout JSONText) {
        json.beginObject()
        if !object.name.isEmpty {
            json.key("name")
            json.string(object.name)
        }
        if !object.oid.isEmpty {
            json.key("oid")
            json.string(object.oid)
        }
        json.key("size")
        json.number(object.size)
        if object.authenticated {
            json.key("authenticated")
            json.bool(true)
        }
        if !object.actions.isEmpty {
            write(object.actions, key: "actions", into: &json)
        }
        if !object.links.isEmpty {
            write(object.links, key: "_links", into: &json)
        }
        if let error = object.error { write(error, into: &json) }
        if !object.path.isEmpty {
            json.key("path")
            json.string(object.path)
        }
        json.endObject()
    }

    private static func write(
        _ actions: [String: LFSBatchAction], key: String, into json: inout JSONText
    ) {
        json.key(key)
        json.beginObject()
        for name in actions.keys.sorted() {
            guard let action = actions[name] else { continue }
            json.key(name)
            write(action, into: &json)
        }
        json.endObject()
    }

    private static func write(_ action: LFSBatchAction, into json: inout JSONText) {
        json.beginObject()
        json.key("href")
        json.string(action.href)
        if !action.header.isEmpty {
            json.key("header")
            json.beginObject()
            for name in action.header.keys.sorted() {
                json.key(name)
                json.string(action.header[name] ?? "")
            }
            json.endObject()
        }
        if let expiresAt = action.expiresAt {
            json.key("expires_at")
            json.string(LFSTimestamp.string(from: expiresAt))
        }
        if action.expiresIn != 0 {
            json.key("expires_in")
            json.number(Int64(action.expiresIn))
        }
        json.endObject()
    }

    private static func write(_ error: LFSObjectError, into json: inout JSONText) {
        json.key("error")
        json.beginObject()
        json.key("code")
        json.number(Int64(error.code))
        json.key("message")
        json.string(error.message)
        json.endObject()
    }
}

/// Compact JSON with an explicit key order. A value written after ``key``
/// is not given its own comma.
private struct JSONText {
    private var text = ""
    private var atStart: [Bool] = []
    private var afterKey = false

    var data: Data { Data(text.utf8) }

    mutating func beginObject() {
        valuePrefix()
        text.append("{")
        atStart.append(true)
    }

    mutating func endObject() {
        text.append("}")
        if !atStart.isEmpty { atStart.removeLast() }
    }

    mutating func beginArray() {
        valuePrefix()
        text.append("[")
        atStart.append(true)
    }

    mutating func endArray() {
        text.append("]")
        if !atStart.isEmpty { atStart.removeLast() }
    }

    mutating func key(_ name: String) {
        comma()
        text.append("\"")
        appendEscaped(name)
        text.append("\":")
        afterKey = true
    }

    mutating func string(_ value: String) {
        valuePrefix()
        text.append("\"")
        appendEscaped(value)
        text.append("\"")
    }

    mutating func number(_ value: Int64) {
        valuePrefix()
        text.append(String(value))
    }

    mutating func bool(_ value: Bool) {
        valuePrefix()
        text.append(value ? "true" : "false")
    }

    private mutating func comma() {
        guard !atStart.isEmpty else { return }
        let index = atStart.count - 1
        if atStart[index] {
            atStart[index] = false
        } else {
            text.append(",")
        }
    }

    private mutating func valuePrefix() {
        if afterKey {
            afterKey = false
            return
        }
        comma()
    }

    /// `encoding/json` escapes controls, U+2028/U+2029, and `&`, `<`, `>`.
    private mutating func appendEscaped(_ value: String) {
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                text.append("\\\"")
            case 0x5C:
                text.append("\\\\")
            case 0x08:
                text.append("\\b")
            case 0x09:
                text.append("\\t")
            case 0x0A:
                text.append("\\n")
            case 0x0C:
                text.append("\\f")
            case 0x0D:
                text.append("\\r")
            case 0x26:
                text.append("\\u0026")
            case 0x3C:
                text.append("\\u003c")
            case 0x3E:
                text.append("\\u003e")
            default:
                let value = scalar.value
                if value < 0x20 || value == 0x2028 || value == 0x2029 {
                    text.append(String(format: "\\u%04x", value))
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
    }
}

enum LFSTimestamp {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

extension LFSClient {
    /// `tqClient.Batch`. `POST <endpoint>/objects/batch`. An empty object list
    /// does not hit the network. An action that is expired, or expires within
    /// 5 seconds, is retriable: the same batch is posted again, up to eight
    /// retries. There is no worker pool here.
    public func batch(
        operation: String,
        objects: [LFSBatchObject],
        ref: LFSBatchRef = LFSBatchRef(),
        remote: String? = nil
    ) async throws -> LFSBatchResponse {
        if objects.isEmpty { return LFSBatchResponse() }
        let resolved = await batchRemote(remote, operation: operation)
        let endpoint = finder.endpoint(operation: operation, remote: resolved)
        let basicOnly = LFSConfiguration.bool(
            finder.configuration.get("lfs.basictransfersonly"), fallback: false)
        let names = LFSTransferAdapters.names(basicTransfersOnly: basicOnly)
        let payload = LFSBatchEncoding.data(
            operation: operation, objects: objects, transfers: names, ref: ref)
        guard let url = Self.batchURL(endpoint.url) else {
            throw LFSClientError("invalid URL: \(endpoint.url)")
        }
        var http = HTTPRequest(method: .post, url: url)
        http.headerFields[.accept] = LFSMediaType.json
        http.headerFields[.contentType] = LFSMediaType.requestContentType

        // git-lfs `defaultMaxRetries`: eight retries after the first POST.
        var last = LFSBatchResponse(endpoint: endpoint)
        for _ in 0..<9 {
            let requestedAt = Date()
            let (data, response) = try await send(
                http, body: .data(payload), operation: operation, remote: remote)
            var decoded = try Self.decodeBatch(data, response: response, url: url)
            if !decoded.hashAlgorithm.isEmpty, decoded.hashAlgorithm != "sha256" {
                let rejected = decoded.hashAlgorithm.goQuoted
                throw LFSClientError("batch response: unsupported hash algorithm: \(rejected)")
            }
            if response.status.code != 200 {
                let target = Self.withoutQuery(url)
                let status = response.status.code
                throw LFSClientError("Invalid HTTP status for POST \(target): \(status)")
            }
            decoded.stamp(requestedAt)
            decoded.endpoint = endpoint
            last = decoded
            if !decoded.expiresSoon(operation) { return decoded }
        }
        return last
    }

    private func batchRemote(_ remote: String?, operation: String) async -> String {
        if let remote { return remote }
        return operation == "upload" ? finder.uploadRemote() : await finder.downloadRemote()
    }

    /// `objects/batch` joined onto the endpoint path, with the query left in place.
    static func batchURL(_ endpoint: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        let path = components.percentEncodedPath
        if path.hasSuffix("/") {
            components.percentEncodedPath = path + "objects/batch"
        } else {
            components.percentEncodedPath = path + "/objects/batch"
        }
        return components.url
    }

    static func withoutQuery(_ url: URL) -> String {
        let absolute = url.absoluteString
        guard let index = absolute.firstIndex(of: "?") else { return absolute }
        return String(absolute[..<index])
    }

    static func decodeBatch(_ data: Data, response: HTTPResponse, url: URL) throws -> LFSBatchResponse {
        let type = response.headerFields[.contentType] ?? ""
        guard isBatchJSON(type) else {
            throw LFSClientError("batch response: Expected JSON type, got: \"\(type)\"")
        }
        do {
            return try JSONDecoder().decode(WireBatch.self, from: data).model()
        } catch {
            let target = url.absoluteString
            throw LFSClientError("batch response: Unable to parse HTTP response for POST \(target): \(error)")
        }
    }

    static func isBatchJSON(_ type: String) -> Bool {
        func matches(_ media: String) -> Bool {
            type == media || type.hasPrefix(media + ";")
        }
        return matches(LFSMediaType.json) || matches("application/json")
    }
}

private struct WireBatch: Decodable {
    var transfer: String?
    var hashAlgorithm: String?
    var objects: [WireObject]?

    enum CodingKeys: String, CodingKey {
        case transfer
        case hashAlgorithm = "hash_algo"
        case objects
    }

    func model() -> LFSBatchResponse {
        LFSBatchResponse(
            objects: (objects ?? []).map { $0.model() },
            transfer: transfer ?? "",
            hashAlgorithm: hashAlgorithm ?? "")
    }
}

private struct WireObject: Decodable {
    var name: String?
    var oid: String?
    var size: Int64?
    var authenticated: Bool?
    var actions: [String: WireAction]?
    var links: [String: WireAction]?
    var error: WireError?
    var path: String?

    enum CodingKeys: String, CodingKey {
        case name, oid, size, authenticated, actions, path, error
        case links = "_links"
    }

    func model() -> LFSBatchObject {
        var object = LFSBatchObject(oid: oid ?? "", size: size ?? 0, name: name ?? "", path: path ?? "")
        object.authenticated = authenticated ?? false
        object.actions = (actions ?? [:]).mapValues { $0.model() }
        object.links = (links ?? [:]).mapValues { $0.model() }
        if let error {
            object.error = LFSObjectError(code: error.code ?? 0, message: error.message ?? "")
        }
        return object
    }
}

private struct WireError: Decodable {
    var code: Int?
    var message: String?
}

private struct WireAction: Decodable {
    var href: String?
    var header: [String: String]?
    var expiresAt: Date?
    var expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case href, header
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        href = try container.decodeIfPresent(String.self, forKey: .href)
        header = try container.decodeIfPresent([String: String].self, forKey: .header)
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
        expiresAt = nil
        if let text = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
            guard let date = LFSTimestamp.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expiresAt, in: container, debugDescription: text)
            }
            expiresAt = date
        }
    }

    func model() -> LFSBatchAction {
        LFSBatchAction(
            href: href ?? "",
            header: header ?? [:],
            expiresAt: expiresAt,
            expiresIn: expiresIn ?? 0)
    }
}
