import Crypto
import Foundation

/// Mutable batch state. Callers hold `LFSServerCore`'s lock.
private struct LFSServerState {
    var endpoint = "http://127.0.0.1"
    var objects: [String: Data] = [:]
    var log: [LFSRecordedRequest] = []
    var statusFault: LFSTestFault?
    var objectFaults: [String: LFSTestFault] = [:]

    mutating func handle(
        method: String, uri: String, headers: [String: String], body: Data
    ) -> LFSWireResponse {
        let response = route(method: method, uri: uri, body: body)
        log.append(LFSRecordedRequest(
            method: method,
            path: Self.path(of: uri),
            status: response.status,
            requestHeaders: headers,
            responseHeaders: response.loggedHeaders(),
            requestBody: body,
            responseBody: response.body,
            fault: response.fault
        ))
        return response
    }

    private mutating func route(method: String, uri: String, body: Data) -> LFSWireResponse {
        if let fault = statusFault {
            statusFault = nil
            return statusResponse(fault)
        }
        let parts = Self.parts(of: uri)
        if method == "POST", parts == ["objects", "batch"] {
            return respondBatch(body)
        }
        if parts.count == 2, parts[0] == "objects" {
            if method == "GET" { return respondGet(parts[1]) }
            if method == "PUT" { return respondPut(parts[1], body: body) }
        }
        if method == "POST", parts.count == 3, parts[0] == "objects", parts[2] == "verify" {
            return respondVerify(parts[1], body: body)
        }
        return .json(status: 404, message: "Not found", fault: nil)
    }

    private mutating func respondBatch(_ body: Data) -> LFSWireResponse {
        guard let request = try? JSONDecoder().decode(BatchRequest.self, from: body) else {
            return .json(status: 400, message: "bad request", fault: nil)
        }
        guard request.operation == "upload" || request.operation == "download" else {
            return .json(status: 422, message: objectMessage(422), fault: nil)
        }
        var encoded: [ObjectBody] = []
        var faults: [String] = []
        for object in request.objects {
            let (item, fault) = batchObject(request.operation, object)
            encoded.append(item)
            if let fault { faults.append(fault) }
        }
        let fault = faults.isEmpty ? nil : faults.joined(separator: ",")
        return .json(BatchResponse(objects: encoded), fault: fault)
    }

    private mutating func batchObject(
        _ operation: String, _ object: BatchObjectRequest
    ) -> (ObjectBody, String?) {
        if let code = consumeObjectStatus(object.oid) {
            let error = ErrorBody(code: code, message: objectMessage(code))
            let item = ObjectBody(oid: object.oid, size: object.size, actions: nil, error: error)
            return (item, String(code))
        }
        if operation == "upload", objects[object.oid] != nil {
            return (ObjectBody(oid: object.oid, size: object.size, actions: nil, error: nil), nil)
        }
        if operation == "download", objects[object.oid] == nil {
            let error = ErrorBody(code: 404, message: objectMessage(404))
            return (ObjectBody(oid: object.oid, size: object.size, actions: nil, error: error), nil)
        }
        let expired = consumeExpired(object.oid)
        let actions = transferActions(operation, oid: object.oid, expired: expired)
        let item = ObjectBody(oid: object.oid, size: object.size, actions: actions, error: nil)
        return (item, expired ? "expired" : nil)
    }

    private func transferActions(_ operation: String, oid: String, expired: Bool) -> [String: ActionBody] {
        let when = expired ? Date(timeIntervalSinceNow: -3600) : Date(timeIntervalSinceNow: 3600)
        let stamp = LFSTimestamp.rfc3339(when)
        let href = endpoint + "/objects/" + oid
        if operation == "download" {
            return ["download": ActionBody(href: href, header: [:], expiresAt: stamp)]
        }
        return [
            "upload": ActionBody(href: href, header: [:], expiresAt: stamp),
            "verify": ActionBody(href: href + "/verify", header: [:], expiresAt: stamp)
        ]
    }

    private mutating func respondGet(_ oid: String) -> LFSWireResponse {
        guard var payload = objects[oid] else {
            return .json(status: 404, message: objectMessage(404), fault: nil)
        }
        let fault = consumeDownloadCorruption(oid)
        switch fault {
        case .wrongSize:
            payload.append(0)
        case .wrongSHA256:
            corruptHash(&payload)
        default:
            break
        }
        return .bytes(payload, fault: fault?.logToken)
    }

    private func corruptHash(_ payload: inout Data) {
        // Keep the length so the failure is the digest. Empty input has one digest, so it grows.
        guard !payload.isEmpty else {
            payload = Data([0x01])
            return
        }
        payload[payload.startIndex] ^= 0xFF
    }

    private mutating func respondPut(_ oid: String, body: Data) -> LFSWireResponse {
        objects[oid] = body
        return .empty()
    }

    private mutating func respondVerify(_ oid: String, body: Data) -> LFSWireResponse {
        guard let request = try? JSONDecoder().decode(VerifyRequest.self, from: body) else {
            return .json(status: 400, message: "bad request", fault: nil)
        }
        guard request.oid == oid else {
            return .json(status: 422, message: objectMessage(422), fault: nil)
        }
        guard let stored = objects[oid] else {
            return .json(status: 404, message: objectMessage(404), fault: nil)
        }
        // A digest mismatch is not an object the server has. Drop it so the next
        // upload batch still offers an upload action. store(_:oid:) is unchanged.
        guard sha256Hex(stored) == oid else {
            objects.removeValue(forKey: oid)
            return .json(status: 422, message: objectMessage(422), fault: nil)
        }
        guard stored.count == request.size else {
            return .json(status: 422, message: objectMessage(422), fault: nil)
        }
        return .empty()
    }

    private func statusResponse(_ fault: LFSTestFault) -> LFSWireResponse {
        switch fault {
        case .unauthorized:
            return .json(status: 401, message: "Unauthorized", fault: fault.logToken)
        case .tooManyRequests(let retryAfter):
            return .json(
                status: 429, message: "Too many requests", fault: fault.logToken,
                extra: ["Retry-After": retryAfter]
            )
        case .serverError(let code):
            return .json(status: code, message: "Server error", fault: fault.logToken)
        default:
            return .json(status: 500, message: "Server error", fault: "500")
        }
    }

    private mutating func consumeObjectStatus(_ oid: String) -> Int? {
        guard case .objectStatus(_, let code) = objectFaults[oid] else { return nil }
        objectFaults.removeValue(forKey: oid)
        return code
    }

    private mutating func consumeExpired(_ oid: String) -> Bool {
        guard case .expired = objectFaults[oid] else { return false }
        objectFaults.removeValue(forKey: oid)
        return true
    }

    private mutating func consumeDownloadCorruption(_ oid: String) -> LFSTestFault? {
        switch objectFaults[oid] {
        case .wrongSize, .wrongSHA256:
            return objectFaults.removeValue(forKey: oid)
        default:
            return nil
        }
    }

    private static func path(of uri: String) -> String {
        let raw: String
        if uri.hasPrefix("http://") || uri.hasPrefix("https://"), let url = URL(string: uri) {
            raw = url.path
        } else {
            raw = uri
        }
        guard let query = raw.firstIndex(of: "?") else { return raw }
        return String(raw[..<query])
    }

    private static func parts(of uri: String) -> [String] {
        path(of: uri).split(separator: "/").map(String.init)
    }
}

final class LFSServerCore: @unchecked Sendable {
    private let lock = NSLock()
    private var state = LFSServerState()

    func setEndpoint(_ endpoint: URL) {
        var text = endpoint.absoluteString
        if text.hasSuffix("/") { text.removeLast() }
        lock.lock()
        state.endpoint = text
        lock.unlock()
    }

    func store(_ bytes: Data, oid: String) {
        lock.lock()
        state.objects[oid] = bytes
        lock.unlock()
    }

    func bytes(for oid: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return state.objects[oid]
    }

    func inject(_ fault: LFSTestFault) {
        lock.lock()
        defer { lock.unlock() }
        if fault.isStatusFault {
            state.statusFault = fault
        } else if let oid = fault.oid {
            state.objectFaults[oid] = fault
        }
    }

    func requests() -> [LFSRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return state.log
    }

    func handle(method: String, uri: String, headers: [String: String], body: Data) -> LFSWireResponse {
        lock.lock()
        defer { lock.unlock() }
        return state.handle(method: method, uri: uri, headers: headers, body: body)
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func objectMessage(_ code: Int) -> String {
    switch code {
    case 404:
        return "Object does not exist"
    case 410:
        return "Object has been removed"
    case 422:
        return "Validation error"
    default:
        return "Error"
    }
}

private enum LFSTimestamp {
    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

private struct BatchRequest: Decodable {
    var operation: String
    var objects: [BatchObjectRequest]
}

private struct BatchObjectRequest: Decodable {
    var oid: String
    var size: Int
}

private struct VerifyRequest: Decodable {
    var oid: String
    var size: Int
}

private struct BatchResponse: Encodable {
    var transfer = "basic"
    var objects: [ObjectBody]
}

private struct ObjectBody: Encodable {
    var oid: String
    var size: Int
    var actions: [String: ActionBody]?
    var error: ErrorBody?
}

private struct ActionBody: Encodable {
    var href: String
    var header: [String: String]
    var expiresAt: String

    enum CodingKeys: String, CodingKey {
        case href
        case header
        case expiresAt = "expires_at"
    }
}

private struct ErrorBody: Encodable {
    var code: Int
    var message: String
}
