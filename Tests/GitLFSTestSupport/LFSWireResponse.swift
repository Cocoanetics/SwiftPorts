import Foundation

struct LFSWireResponse: Sendable {
    static let mediaType = "application/vnd.git-lfs+json"

    var status: Int
    var headers: [String: String]
    var body: Data
    var fault: String?

    static func json(status: Int, message: String, fault: String?, extra: [String: String] = [:]) -> LFSWireResponse {
        let payload = lfsJSON(MessageBody(message: message)) ?? Data()
        var headers = extra
        headers["Content-Type"] = mediaType
        return LFSWireResponse(status: status, headers: headers, body: payload, fault: fault).withLength()
    }

    static func json<T: Encodable>(_ value: T, fault: String?) -> LFSWireResponse {
        guard let payload = lfsJSON(value) else {
            return json(status: 500, message: "Internal Server Error", fault: nil)
        }
        return LFSWireResponse(
            status: 200,
            headers: ["Content-Type": mediaType],
            body: payload,
            fault: fault
        ).withLength()
    }

    static func bytes(_ body: Data, fault: String?) -> LFSWireResponse {
        LFSWireResponse(
            status: 200,
            headers: ["Content-Type": "application/octet-stream"],
            body: body,
            fault: fault
        ).withLength()
    }

    static func empty() -> LFSWireResponse {
        LFSWireResponse(status: 200, headers: [:], body: Data(), fault: nil).withLength()
    }

    func withLength() -> LFSWireResponse {
        var copy = self
        copy.headers["Content-Length"] = String(body.count)
        return copy
    }

    func loggedHeaders() -> [String: String] {
        var lowered: [String: String] = [:]
        for (name, value) in headers {
            lowered[name.lowercased()] = value
        }
        return lowered
    }
}

private struct MessageBody: Encodable {
    var message: String
}

func lfsJSON<T: Encodable>(_ value: T) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(value)
}
