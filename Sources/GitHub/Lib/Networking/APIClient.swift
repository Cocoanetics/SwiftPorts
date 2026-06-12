import Foundation
import HTTPTypes
import HTTPTypesFoundation
import Logging
import ShellKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal GitHub REST/GraphQL client.
///
/// Mirrors what upstream `gh` does in `api/client.go` +
/// `api/http_client.go`, stripped to the parts the no-auth surface
/// needs: pagination, rate-limit awareness, JSON decoding.
///
/// Built on `swift-http-types`: requests are `HTTPRequest`,
/// responses are `HTTPResponse`. `URLSession` is reached only via
/// `HTTPTypesFoundation`'s `data(for: HTTPRequest)` convenience.
public actor APIClient {
    public let configuration: Configuration
    private let session: URLSession
    private let logger: Logger

    public init(
        configuration: Configuration = .live(),
        session: URLSession = .shared,
        logger: Logger = Loggers.api
    ) {
        self.configuration = configuration
        self.session = session
        self.logger = logger
    }

    // MARK: REST

    /// `GET path` → decode body as `T`. `path` is relative to the
    /// configured API root (e.g. `"repos/cli/cli"`).
    public func get<T: Decodable>(
        _ path: String,
        as type: T.Type = T.self,
        query: [URLQueryItem] = []
    ) async throws -> T {
        let url = makeURL(path: path, query: query)
        let response = try await perform(method: .get, url: url, body: nil)
        return try decode(T.self, from: response)
    }

    /// `GET path` returning every page of a paginated list, walking
    /// `Link: rel="next"` headers until exhausted.
    public func paginate<T: Decodable>(
        _ path: String,
        as elementType: T.Type = T.self,
        query: [URLQueryItem] = [],
        maxPages: Int = 100
    ) async throws -> [T] {
        var url: URL? = makeURL(path: path, query: query)
        var pages = 0
        var collected: [T] = []
        while let next = url, pages < maxPages {
            try Task.checkCancellation()
            let response = try await perform(method: .get, url: next, body: nil)
            let page: [T] = try decode([T].self, from: response)
            collected.append(contentsOf: page)
            url = response.nextPageURL
            pages += 1
        }
        return collected
    }

    /// Low-level entry: arbitrary method, raw body, raw response. Used
    /// by `gh api` and by anything that needs Link/headers visibility.
    public func raw(
        method: HTTPRequest.Method,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        extraHeaders: HTTPFields = [:]
    ) async throws -> APIResponse {
        let url = makeURL(path: path, query: query)
        return try await perform(
            method: method,
            url: url,
            body: body,
            extraHeaders: extraHeaders
        )
    }

    /// Send an `Encodable` payload as a JSON body and decode the
    /// response into `Response`. Used by every write command —
    /// issues, releases, gists, etc.
    public func send<Body: Encodable, Response: Decodable>(
        method: HTTPRequest.Method,
        path: String,
        body: Body,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let encoded = try JSONEncoder.gitHub().encode(body)
        let response = try await perform(
            method: method,
            url: makeURL(path: path, query: []),
            body: encoded
        )
        return try decode(Response.self, from: response)
    }

    /// Send an `Encodable` payload, ignore the response body.
    /// Used by deletes / state-only patches.
    public func send<Body: Encodable>(
        method: HTTPRequest.Method,
        path: String,
        body: Body
    ) async throws {
        let encoded = try JSONEncoder.gitHub().encode(body)
        _ = try await perform(
            method: method,
            url: makeURL(path: path, query: []),
            body: encoded
        )
    }

    /// `DELETE path` — body-less.
    public func delete(_ path: String) async throws {
        _ = try await perform(
            method: .delete,
            url: makeURL(path: path, query: []),
            body: nil
        )
    }

    // MARK: URL building

    func makeURL(path: String, query: [URLQueryItem]) -> URL {
        // Absolute URL passed in (e.g. a paginated `next` link from GitHub).
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(
            url: configuration.apiRoot.appendingPathComponent(trimmed),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    // MARK: HTTP

    private func perform(
        method: HTTPRequest.Method,
        url: URL,
        body: Data?,
        extraHeaders: HTTPFields = [:]
    ) async throws -> APIResponse {
        // Sandbox boundary: every REST call (typed get/send/delete,
        // raw, paginate, plus the OAuthDeviceFlow + GraphQL clients
        // that go through this method) is gated here. ~60+ subcommand
        // call sites are subsumed by this single gate.
        try await Shell.authorize(url)
        var request = HTTPRequest(method: method, url: url)
        request.headerFields[.accept] = "application/vnd.github+json"
        request.headerFields[.gitHubAPIVersion] = "2022-11-28"
        request.headerFields[.userAgent] = configuration.userAgent
        if let token = configuration.token {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        if body != nil {
            request.headerFields[.contentType] = "application/json; charset=utf-8"
        }
        for field in extraHeaders {
            request.headerFields[field.name] = field.value
        }

        logger.debug("HTTP \(method.rawValue) \(url.absoluteString)")

        let (data, response): (Data, HTTPResponse)
        let metrics = TaskMetricsCollector()
        do {
            if let body {
                (data, response) = try await session.upload(for: request, from: body, delegate: metrics)
            } else {
                (data, response) = try await session.data(for: request, delegate: metrics)
            }
        } catch {
            throw APIError.transport(underlying: error)
        }

        let nextPage = response.headerFields[.link]
            .flatMap { LinkHeader.url(for: "next", in: $0) }
        let remaining = response.headerFields[.rateLimitRemaining]
            .flatMap(Int.init)
        let resetAt = response.headerFields[.rateLimitReset]
            .flatMap(TimeInterval.init)
            .map { Date(timeIntervalSince1970: $0) }
        let contentType = response.headerFields[.contentType]
        let scopes: [String]? = response.headerFields[.oauthScopes].map { value in
            value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        logger.debug(
            "HTTP \(response.status.code) (\(data.count) bytes; rate-remaining=\(remaining.map(String.init) ?? "?"))")

        let apiResponse = APIResponse(
            status: response.status.code,
            body: data,
            nextPageURL: nextPage,
            rateLimitRemaining: remaining,
            rateLimitResetAt: resetAt,
            contentType: contentType,
            oauthScopes: scopes,
            headerFields: Self.scrubbedHeaderFields(response.headerFields),
            httpVersion: Self.protoToken(fromNetworkProtocolName: metrics.protocolName),
            url: url
        )

        try checkStatus(apiResponse)
        return apiResponse
    }

    /// Map `URLSessionTaskMetrics`' ALPN-style protocol name to Go's
    /// `resp.Proto` form — what gh prints in the `--include` status
    /// line. nil when the transport didn't report one (or reported
    /// something Go has no token for).
    static func protoToken(fromNetworkProtocolName name: String?) -> String? {
        switch name {
        case "h2", "h2c": return "HTTP/2.0"
        case "http/1.1": return "HTTP/1.1"
        case "http/1.0": return "HTTP/1.0"
        case "h3": return "HTTP/3.0"
        default: return nil
        }
    }

    /// Drop the transfer headers that no longer describe `body` once
    /// the transport has transparently decompressed it. URLSession
    /// inflates compressed bodies but reports the original
    /// `Content-Encoding` / `Content-Length` fields; Go's transport
    /// deletes both when it inflates (h2_bundle.go `handleResponse`),
    /// so upstream `gh api --include` never shows them on compressed
    /// responses. Mirror Go so the fields always describe the bytes
    /// actually in `body`.
    static func scrubbedHeaderFields(_ fields: HTTPFields) -> HTTPFields {
        guard let encoding = fields[.contentEncoding] else { return fields }
        let transparentlyDecoded: Set<String> = ["gzip", "deflate", "br", "zstd"]
        guard transparentlyDecoded.contains(
            encoding.trimmingCharacters(in: .whitespaces).lowercased())
        else { return fields }
        var scrubbed = fields
        scrubbed[.contentEncoding] = nil
        scrubbed[.contentLength] = nil
        return scrubbed
    }

    // MARK: Status mapping

    private func checkStatus(_ r: APIResponse) throws {
        if (200..<300).contains(r.status) { return }
        if r.status == 404 { throw APIError.notFound(url: r.url) }
        if r.status == 401 { throw APIError.unauthenticated(url: r.url) }
        if r.status == 403,
           let remaining = r.rateLimitRemaining, remaining == 0 {
            throw APIError.rateLimited(
                resetAt: r.rateLimitResetAt,
                remaining: remaining,
                url: r.url)
        }
        let message = parseMessage(from: r.body) ?? ""
        throw APIError.http(status: r.status, message: message, url: r.url)
    }

    private func parseMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return object["message"] as? String
    }

    // MARK: Decoding

    private func decode<T: Decodable>(_ type: T.Type, from r: APIResponse) throws -> T {
        do {
            return try JSONDecoder.gitHub().decode(T.self, from: r.body)
        } catch {
            throw APIError.decoding(underlying: error, url: r.url)
        }
    }
}

// MARK: Task metrics

/// Captures the negotiated protocol from `URLSessionTaskMetrics` so
/// `gh api --include` can print the real `resp.Proto` like upstream
/// (e.g. a GitHub Enterprise host that only speaks HTTP/1.1). On
/// Darwin the callback fires per task; corelibs-foundation declares
/// it but never invokes it, so on Linux the value stays nil and
/// callers fall back.
private final class TaskMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?

    var protocolName: String? {
        lock.lock()
        defer { lock.unlock() }
        return name
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        // The last transaction is the one that produced the response
        // (earlier entries are redirects).
        let reported = metrics.transactionMetrics.last?.networkProtocolName
        lock.lock()
        name = reported
        lock.unlock()
    }
}

// MARK: GitHub-specific header field names

extension HTTPField.Name {
    static let gitHubAPIVersion = HTTPField.Name("X-GitHub-Api-Version")!
    static let rateLimitRemaining = HTTPField.Name("X-RateLimit-Remaining")!
    static let rateLimitReset = HTTPField.Name("X-RateLimit-Reset")!
    static let link = HTTPField.Name("Link")!
    static let oauthScopes = HTTPField.Name("X-OAuth-Scopes")!
}
