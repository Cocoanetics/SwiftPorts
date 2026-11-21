import Crypto
import Foundation
import NIOCore

/// Mutable batch state. Callers hold `LFSServerCore`'s lock.
private struct LFSServerState {
    var endpoint = "http://127.0.0.1"
    var objects: [String: Data] = [:]
    var log: [LFSRecordedRequest] = []
    var statusFault: LFSTestFault?
    var objectFaults: [String: LFSTestFault] = [:]

    mutating func handle(
        method: String, uri: String, headers: [String: String], body: Data, record: Bool = true
    ) -> LFSWireResponse {
        let response = route(method: method, uri: uri, body: body)
        if record { remember(method: method, uri: uri, headers: headers, body: body, response: response) }
        return response
    }

    mutating func remember(
        method: String, uri: String, headers: [String: String], body: Data, response: LFSWireResponse
    ) {
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
    }

    func isObjectTransfer(method: String, uri: String) -> Bool {
        guard method == "GET" || method == "PUT" else { return false }
        let parts = Self.parts(of: uri)
        return parts.count == 2 && parts[0] == "objects"
    }

    private mutating func route(method: String, uri: String, body: Data) -> LFSWireResponse {
        if let fault = statusFault {
            if case .repeatingServerError = fault {
                return statusResponse(fault)
            }
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
        if case .noAction = objectFaults[object.oid] {
            objectFaults.removeValue(forKey: object.oid)
            return (ObjectBody(oid: object.oid, size: object.size, actions: nil, error: nil), "no-action")
        }
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
        case .repeatingServerError:
            return .json(status: 500, message: "Server error", fault: fault.logToken)
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

/// How an object `GET` or `PUT` should be answered while an overlap hold is armed.
enum LFSObjectHoldPhase: Equatable {
    /// Answer immediately. The hold is inactive, this is not an object transfer,
    /// or this is the first object transfer of the hold.
    case bypass
    /// Keep the whole response until the hold releases.
    case hold
}

final class LFSServerCore: @unchecked Sendable {
    private let lock = NSLock()
    private var state = LFSServerState()
    /// Touched only on the server event loop.
    private var hold = LFSObjectHold()

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

    func handle(
        method: String, uri: String, headers: [String: String], body: Data, record: Bool = true
    ) -> LFSWireResponse {
        lock.lock()
        defer { lock.unlock() }
        return state.handle(method: method, uri: uri, headers: headers, body: body, record: record)
    }

    func record(method: String, uri: String, headers: [String: String], body: Data, response: LFSWireResponse) {
        lock.lock()
        defer { lock.unlock() }
        state.remember(method: method, uri: uri, headers: headers, body: body, response: response)
    }

    /// Arm the overlap hold. Call this on the server event loop.
    func armObjectHold(count: Int, timeout: TimeAmount, loop: EventLoop) {
        hold.arm(count: count, timeout: timeout, loop: loop)
    }

    /// Highest number of object transfers in flight since the last ``armObjectHold``.
    /// Call this on the server event loop.
    func peakObjectTransfers() -> Int {
        hold.peak
    }

    /// Drop a held response so shutdown can finish. Call this on the server event loop.
    func releaseObjectHold() {
        hold.release()
    }

    /// Count this request toward the overlap hold. Call this on the server event loop.
    func beginObjectHold(method: String, uri: String) -> LFSObjectHoldPhase {
        lock.lock()
        let transfer = state.isObjectTransfer(method: method, uri: uri)
        lock.unlock()
        return hold.begin(isObjectTransfer: transfer)
    }

    /// Park `promise` until enough object transfers overlap, then succeed it.
    /// Call this on the server event loop.
    func parkObjectHold(_ promise: EventLoopPromise<Void>) {
        hold.park(promise)
    }
}

/// Object `GET`/`PUT` responses parked until enough of them are in flight.
///
/// The event loop is the only thread that touches this value. The first
/// object transfer is answered in full: the queue does not start its other
/// workers until that response has succeeded. Later object transfers stay
/// unanswered until enough of them are in flight together.
private final class LFSObjectHold: @unchecked Sendable {
    private var target = 0
    private var started = 0
    private var peakCount = 0
    private var holding = false
    private var passedFirst = false
    private var timeoutTask: Scheduled<Void>?
    private var parked: [EventLoopPromise<Void>] = []

    var peak: Int { peakCount }

    func arm(count: Int, timeout: TimeAmount, loop: EventLoop) {
        release()
        target = max(1, count)
        started = 0
        peakCount = 0
        passedFirst = false
        holding = true
        timeoutTask = loop.scheduleTask(in: timeout) { [weak self] in
            self?.release()
        }
    }

    func begin(isObjectTransfer: Bool) -> LFSObjectHoldPhase {
        guard holding, isObjectTransfer else { return .bypass }
        if !passedFirst {
            passedFirst = true
            return .bypass
        }
        started += 1
        peakCount = max(peakCount, started)
        return .hold
    }

    func park(_ promise: EventLoopPromise<Void>) {
        parked.append(promise)
        if started >= target { release() }
    }

    func release() {
        guard holding || !parked.isEmpty else { return }
        holding = false
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = parked
        parked = []
        for promise in pending { promise.succeed(()) }
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
