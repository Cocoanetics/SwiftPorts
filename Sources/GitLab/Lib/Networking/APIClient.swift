import Foundation
import HTTPTypes
import HTTPTypesFoundation
import Logging
import ShellKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal GitLab REST client. Built on `swift-http-types` like the
/// GitHub one, but uses GitLab's header-based pagination
/// (`X-Next-Page`) and bearer-style tokens (`PRIVATE-TOKEN` header,
/// historically — the v4 API also accepts `Authorization: Bearer <PAT>`,
/// which is what we send).
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

    /// `GET path` → decode body as `T`. `path` is relative to
    /// `apiRoot` (e.g. `"projects/foo%2Fbar/issues"`).
    public func get<T: Decodable>(
        _ path: String,
        as type: T.Type = T.self,
        query: [URLQueryItem] = []
    ) async throws -> T {
        let url = makeURL(path: path, query: query)
        let response = try await perform(method: .get, url: url, body: nil)
        return try decode(T.self, from: response)
    }

    /// Conditional `GET path` using `If-None-Match`. A `304 Not
    /// Modified` response is surfaced as ``Conditional/notModified``
    /// instead of a decoding error.
    public func get<T: Decodable>(
        _ path: String,
        as type: T.Type = T.self,
        query: [URLQueryItem] = [],
        ifNoneMatch: String?
    ) async throws -> Conditional<T> {
        var headers = HTTPFields()
        if let ifNoneMatch {
            headers[.ifNoneMatch] = ifNoneMatch
        }
        let url = makeURL(path: path, query: query)
        let response = try await perform(
            method: .get,
            url: url,
            body: nil,
            extraHeaders: headers)
        if response.status == 304 { return .notModified }
        return .modified(try decode(T.self, from: response), etag: response.etag)
    }

    /// `GET path`, walking `X-Next-Page` until exhausted or
    /// `maxPages` reached.
    public func paginate<T: Decodable>(
        _ path: String,
        as elementType: T.Type = T.self,
        query: [URLQueryItem] = [],
        maxPages: Int = 100
    ) async throws -> [T] {
        var pages = 0
        var collected: [T] = []
        var nextQuery = query
        while pages < maxPages {
            try Task.checkCancellation()
            let url = makeURL(path: path, query: nextQuery)
            let response = try await perform(method: .get, url: url, body: nil)
            let page: [T] = try decode([T].self, from: response)
            collected.append(contentsOf: page)
            guard let next = response.nextPage else { break }
            nextQuery = query.filter { $0.name != "page" }
                + [URLQueryItem(name: "page", value: String(next))]
            pages += 1
        }
        return collected
    }

    /// Send an `Encodable` payload, decode JSON response.
    public func send<Body: Encodable, Response: Decodable>(
        method: HTTPRequest.Method,
        path: String,
        body: Body,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let encoded = try JSONEncoder.gitLab().encode(body)
        let response = try await perform(
            method: method,
            url: makeURL(path: path, query: []),
            body: encoded)
        return try decode(Response.self, from: response)
    }

    /// Send an `Encodable` payload, ignore response body.
    public func send<Body: Encodable>(
        method: HTTPRequest.Method,
        path: String,
        body: Body
    ) async throws {
        let encoded = try JSONEncoder.gitLab().encode(body)
        _ = try await perform(
            method: method,
            url: makeURL(path: path, query: []),
            body: encoded)
    }

    public func delete(_ path: String) async throws {
        _ = try await perform(
            method: .delete,
            url: makeURL(path: path, query: []),
            body: nil)
    }

    /// Low-level entry: arbitrary method, raw body, raw response. Use
    /// when the endpoint isn't JSON (e.g. GitLab's job-trace
    /// `text/plain` stream) or when callers need response headers
    /// directly. Body decoding is the caller's responsibility.
    public func raw(
        method: HTTPRequest.Method,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        extraHeaders: HTTPFields = [:]
    ) async throws -> APIResponse {
        let url = makeURL(path: path, query: query)
        return try await perform(
            method: method, url: url, body: body, extraHeaders: extraHeaders)
    }

    // MARK: URL building

    func makeURL(path: String, query: [URLQueryItem]) -> URL {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        // GitLab REST routes contain pre-percent-encoded project paths
        // (`projects/group%2Fsub%2Frepo/issues`). Foundation's
        // `appendingPathComponent` would re-encode the `%`, so we
        // assemble the URL string manually.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let baseString = configuration.apiRoot.absoluteString
        let separator = baseString.hasSuffix("/") ? "" : "/"
        var components = URLComponents(string: baseString + separator + trimmed)!
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
        // raw, paginate) flows through here. ~50 GlabCommand subcommand
        // sites are subsumed by this single gate.
        try await Shell.authorize(url)
        var request = HTTPRequest(method: method, url: url)
        request.headerFields[.accept] = "application/json"
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
        do {
            if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch {
            throw APIError.transport(underlying: error)
        }

        let nextPage = response.headerFields[.gitlabNextPage].flatMap(Int.init)
        let totalPages = response.headerFields[.gitlabTotalPages].flatMap(Int.init)
        let total = response.headerFields[.gitlabTotal].flatMap(Int.init)
        let perPage = response.headerFields[.gitlabPerPage].flatMap(Int.init)
        let contentType = response.headerFields[.contentType]

        logger.debug("HTTP \(response.status.code) (\(data.count) bytes)")

        let apiResponse = APIResponse(
            status: response.status.code,
            body: data,
            url: url,
            nextPage: nextPage,
            totalPages: totalPages,
            total: total,
            perPage: perPage,
            contentType: contentType,
            headerFields: response.headerFields)

        try checkStatus(apiResponse)
        return apiResponse
    }

    // MARK: Status mapping

    private func checkStatus(_ r: APIResponse) throws {
        if (200..<300).contains(r.status) { return }
        // GitLab uses 304 across several write endpoints as a
        // no-op success, and conditional GETs use it for cache hits.
        // Both are successful at this layer; typed conditional callers
        // map it to `Conditional.notModified`.
        if r.status == 304 { return }
        if r.status == 404 { throw APIError.notFound(url: r.url) }
        if r.status == 401 { throw APIError.unauthenticated(url: r.url) }
        let message = parseMessage(from: r.body) ?? ""
        throw APIError.http(status: r.status, message: message, url: r.url)
    }

    private func parseMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        // GitLab error payloads vary: `{"message": "..."}` or
        // `{"error": "..."}` or `{"message": {field: [...]}}`.
        if let m = object["message"] as? String { return m }
        if let e = object["error"] as? String { return e }
        if let m = object["message"] as? [String: Any] {
            return m.map { "\($0): \($1)" }.joined(separator: "; ")
        }
        return nil
    }

    // MARK: Decoding

    private func decode<T: Decodable>(_ type: T.Type, from r: APIResponse) throws -> T {
        do {
            return try JSONDecoder.gitLab().decode(T.self, from: r.body)
        } catch {
            throw APIError.decoding(underlying: error, url: r.url)
        }
    }
}

// MARK: GitLab-specific header field names

extension HTTPField.Name {
    static let gitlabNextPage = HTTPField.Name("X-Next-Page")!
    static let gitlabTotalPages = HTTPField.Name("X-Total-Pages")!
    static let gitlabTotal = HTTPField.Name("X-Total")!
    static let gitlabPerPage = HTTPField.Name("X-Per-Page")!
}
