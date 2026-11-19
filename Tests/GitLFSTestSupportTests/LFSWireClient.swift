import Foundation
import Testing
import GitLFSTestSupport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct WireBody: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    func value(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

struct BatchDocument: Decodable, Sendable {
    var transfer: String
    var objects: [BatchObject]

    func object(_ oid: String) -> BatchObject? {
        objects.first { $0.oid == oid }
    }
}

struct BatchObject: Decodable, Sendable {
    var oid: String
    var size: Int
    var actions: [String: BatchAction]?
    var error: BatchErrorBody?
}

struct BatchAction: Decodable, Sendable {
    var href: String
    var header: [String: String]
    var expiresAt: String

    enum CodingKeys: String, CodingKey {
        case href
        case header
        case expiresAt = "expires_at"
    }
}

struct BatchErrorBody: Decodable, Sendable {
    var code: Int
    var message: String
}

struct ErrorEnvelope: Decodable {
    var message: String
}

enum LFSWireClient {
    static let mediaType = "application/vnd.git-lfs+json"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static func postBatch(
        _ server: LFSTestServer, operation: String, objects: [(oid: String, size: Int)]
    ) async throws -> WireBody {
        let payload = BatchPost(
            operation: operation,
            objects: objects.map { ObjectPost(oid: $0.oid, size: $0.size) }
        )
        let url = try url(server, "/objects/batch")
        return try await send(request(url, method: "POST", body: try encode(payload), json: true))
    }

    static func document(_ response: WireBody) throws -> BatchDocument {
        try JSONDecoder().decode(BatchDocument.self, from: response.body)
    }

    static func get(_ href: String) async throws -> WireBody {
        let url = try #require(URL(string: href))
        return try await send(request(url, method: "GET", body: nil, json: false))
    }

    static func put(_ href: String, body: Data) async throws -> WireBody {
        let url = try #require(URL(string: href))
        var call = request(url, method: "PUT", body: body, json: false)
        call.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return try await send(call)
    }

    static func verify(_ href: String, oid: String, size: Int) async throws -> WireBody {
        let url = try #require(URL(string: href))
        let payload = VerifyPost(oid: oid, size: size)
        return try await send(request(url, method: "POST", body: try encode(payload), json: true))
    }

    private static func url(_ server: LFSTestServer, _ path: String) throws -> URL {
        try #require(URL(string: server.endpoint.absoluteString + path))
    }

    private static func request(_ url: URL, method: String, body: Data?, json: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if json {
            request.setValue(mediaType, forHTTPHeaderField: "Accept")
            request.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }

    private static func send(_ request: URLRequest) async throws -> WireBody {
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String {
                headers[name.lowercased()] = text
            }
        }
        if let retryAfter = http.value(forHTTPHeaderField: "Retry-After") {
            headers["retry-after"] = retryAfter
        }
        return WireBody(status: http.statusCode, headers: headers, body: data)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

private struct BatchPost: Encodable {
    var operation: String
    var transfers = ["basic"]
    var objects: [ObjectPost]
}

private struct ObjectPost: Encodable {
    var oid: String
    var size: Int
}

private struct VerifyPost: Encodable {
    var oid: String
    var size: Int
}
