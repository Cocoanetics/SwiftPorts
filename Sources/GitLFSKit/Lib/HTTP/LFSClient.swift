import Foundation
import HTTPTypes
import HTTPTypesFoundation
import ShellKit
import SwiftGit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why an LFS HTTP request failed, in git-lfs's words.
public struct LFSClientError: Error, Equatable, CustomStringConvertible, Sendable {
    public let description: String
    let retryInTransferQueue: Bool
    let transferResult: LFSTransferHTTPResult?

    public init(_ description: String) {
        self.description = description
        retryInTransferQueue = true
        transferResult = nil
    }

    init(_ description: String, retryInTransferQueue: Bool) {
        self.description = description
        self.retryInTransferQueue = retryInTransferQueue
        transferResult = nil
    }

    init(_ description: String, transferResult: LFSTransferHTTPResult) {
        self.description = description
        retryInTransferQueue = true
        self.transferResult = transferResult
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.description == rhs.description
    }
}

/// Body of an authenticated LFS request. `.file` and `.stream` are not copied
/// into a `Data` buffer. `.stream` is `URLRequest.httpBodyStream`, which
/// `URLSession` reads once.
public enum LFSRequestBody: @unchecked Sendable {
    case data(Data)
    case file(URL)
    case stream(InputStream)
}

/// Sends an LFS request the way `lfsapi.Client.DoWithAuth` does: `http.<url>.extraHeader`
/// on every attempt, and credentials only once access is no longer `none`
/// (URL-embedded, then `~/.netrc`, then the caller's `CredentialProvider`).
/// A 401 selects the next access mode — `basic` when the server doesn't say —
/// writes `lfs.<url>.access`, and retries. `User-Agent` is `git-lfs`.
///
/// Authentication is implemented once, on ``send(_:body:operation:remote:)``.
/// That entry point takes an `HTTPRequest` (`HTTPTypes` / `HTTPTypesFoundation`).
/// ``data(for:operation:remote:)`` adapts a `URLRequest` onto it.
public final class LFSClient: @unchecked Sendable {
    public let finder: LFSEndpointFinder
    public let ssh: LFSSSHResolver
    let context: LFSCredentialContext
    let session: URLSession
    /// Which access modes this client may still try. Shared by concurrent
    /// requests, so every read and write takes ``modesLock``.
    private let modesLock = NSLock()
    private var modes = ["none", "negotiate", "basic"]

    /// `configuration` builds the session when `session` is nil, so a test can
    /// inject `protocolClasses` without a second authentication path.
    public init(
        git: GitClient,
        credentials: CredentialProvider? = nil,
        configuration: URLSessionConfiguration = .default,
        session: URLSession? = nil
    ) async {
        let finder = await LFSEndpointFinder(git)
        self.finder = finder
        ssh = LFSSSHResolver(finder: finder)
        context = LFSCredentialContext(
            netrc: await NetrcFile.load(home: Shell.env("HOME")),
            provider: credentials,
            cacheEnabled: finder.cacheCredentials)
        self.session = session ?? URLSession(configuration: configuration)
    }

    /// `DoAPIRequestWithAuth` for an `HTTPRequest`. `operation` defaults from
    /// the method (`POST`/`PUT` upload, anything else download). A nil `remote`
    /// is the selected download or upload remote. `.file` uses
    /// `URLSession.upload(fromFile:)`, which does not read the file into memory.
    @discardableResult
    public func send(
        _ request: HTTPRequest,
        body: LFSRequestBody? = nil,
        operation: String? = nil,
        remote: String? = nil
    ) async throws -> (Data, HTTPResponse) {
        let operation = Self.operation(of: request, override: operation)
        let remote = try await resolvedRemote(remote, operation: operation)
        let endpoint = finder.endpoint(operation: operation, remote: remote)
        var request = request
        var resolved = endpoint
        var sshHeaders: [String: String] = [:]
        let base = endpoint.url.hasSuffix("/") ? endpoint.url : endpoint.url + "/"
        if let url = request.url?.absoluteString, url == endpoint.url || url.hasPrefix(base) {
            let response = try await ssh.resolve(endpoint, method: request.method.rawValue)
            if !response.href.isEmpty {
                resolved.url = response.href
                request.url = try Self.sshRequestURL(
                    href: response.href, endpointURL: endpoint.url, requestURL: request.url)
            }
            sshHeaders = response.header
        }
        try Self.requireHTTP(resolved)
        let starting = finder.access(for: endpoint.url)
        let attempts = starting.mode == "none" ? 4 : 3
        for index in 0..<attempts {
            if let payload = try await perform(
                &request, body: body, endpoint: endpoint, operation: operation,
                remote: remote, sshHeaders: sshHeaders) {
                return (payload.0, Self.makeResponse(payload.1))
            }
            if index == attempts - 1 { break }
        }
        throw LFSClientError("too many authentication attempts")
    }

    /// `DoAPIRequestWithAuth` for an already built `URLRequest`. The request is
    /// sent through ``send(_:body:operation:remote:)``.
    @discardableResult
    public func data(for request: URLRequest, operation: String? = nil, remote: String? = nil) async throws -> Data {
        guard let http = request.httpRequest else {
            throw LFSClientError("invalid URL: \(request.url?.absoluteString ?? "")")
        }
        let body = Self.requestBody(request)
        let (data, _) = try await send(http, body: body, operation: operation, remote: remote)
        return data
    }

    /// Object bytes use `DoWithAuthNoRetry`, followed by at most one retry
    /// for a 401 that was sent without authorization. Completed HTTP failures
    /// retain their headers for the basic adapters and retry policy.
    func transfer(
        _ original: HTTPRequest, body: LFSRequestBody? = nil,
        operation: String, remote: String?, authenticated: Bool,
        accessURL: String? = nil,
        stream: LFSTransferStream = LFSTransferStream()
    ) async throws -> LFSTransferHTTPResult {
        let remote = try await resolvedRemote(remote, operation: operation)
        let endpoint = finder.endpoint(operation: operation, remote: remote)
        var request = original
        let base = endpoint.url.hasSuffix("/") ? endpoint.url : endpoint.url + "/"
        var resolved = endpoint
        var sshHeaders: [String: String] = [:]
        if let url = request.url?.absoluteString, url == endpoint.url || url.hasPrefix(base) {
            let response = try await ssh.resolve(endpoint, method: request.method.rawValue)
            if !response.href.isEmpty {
                resolved.url = response.href
                request.url = try Self.sshRequestURL(
                    href: response.href, endpointURL: endpoint.url, requestURL: request.url)
            }
            sshHeaders = response.header
        }
        try Self.requireHTTP(resolved)
        try Self.requireHTTP(LFSEndpoint(url: request.url?.absoluteString ?? ""))
        for attempt in 0...1 {
            let access = finder.access(for: accessURL ?? endpoint.url)
            applyExtra(&request, finder.extraHeaders(for: request.url?.absoluteString ?? endpoint.url))
            for (key, value) in sshHeaders {
                if let name = HTTPField.Name(key) { request.headerFields[name] = value }
            }
            let applied: LFSAppliedCredential = authenticated ? .skipped : try applyCredentials(
                &request, access: access, endpoint: endpoint, operation: operation, remote: remote)
            request.headerFields[.userAgent] = "git-lfs"
            guard let urlRequest = URLRequest(httpRequest: request) else {
                throw LFSClientError("invalid URL: \(request.url?.absoluteString ?? "")")
            }
            // `basicUploadAdapter.makeRequest` resends after a 401 with a body
            // that has no progress callback, so an upload's bytes count once.
            var attemptStream = stream
            if attempt > 0, body != nil { attemptStream.progress = nil }
            let result = try await LFSTransferDelegate(stream: attemptStream).execute(
                urlRequest, body: body, configuration: session.configuration)
            if (200..<300).contains(result.status), case .helper(let filled) = applied {
                context.approve(filled)
            }
            if result.status == 401, case .helper(let filled) = applied { context.reject(filled) }
            guard result.status == 401, !authenticated, attempt == 0,
                  !Self.hasAuthorization(request) else { return result }
            let promoted = promote(result.response, from: access.mode)
            if promoted != access.mode {
                await finder.setAccess(LFSAccess(mode: promoted, url: access.url))
            }
        }
        preconditionFailure("The final transfer attempt always returns")
    }

    /// Prefer `httpBody`. When it is absent, forward `httpBodyStream`.
    private static func requestBody(_ request: URLRequest) -> LFSRequestBody? {
        if let payload = request.httpBody { return .data(payload) }
        if let stream = request.httpBodyStream { return .stream(stream) }
        return nil
    }

    /// Performs one attempt. The payload stays with this call: concurrent
    /// requests on the same client must not share a body buffer.
    private func perform(
        _ request: inout HTTPRequest, body: LFSRequestBody?, endpoint: LFSEndpoint,
        operation: String, remote: String, sshHeaders: [String: String]
    ) async throws -> (Data, HTTPURLResponse)? {
        let access = finder.access(for: endpoint.url)
        applyExtra(&request, finder.extraHeaders(for: request.url?.absoluteString ?? endpoint.url))
        for (key, value) in sshHeaders {
            if let name = HTTPField.Name(key) { request.headerFields[name] = value }
        }
        let applied = try applyCredentials(
            &request, access: access, endpoint: endpoint, operation: operation, remote: remote)
        request.headerFields[.userAgent] = "git-lfs"
        let (data, http) = try await execute(request, body: body)
        let result = LFSTransferHTTPResult(
            response: http, body: data, accepted: (200..<300).contains(http.statusCode))
        if (200..<300).contains(http.statusCode) {
            if case .helper(let filled) = applied { context.approve(filled) }
            return (data, http)
        }
        if http.statusCode < 400 {
            return (data, http)
        }
        let message = Self.httpMessage(status: http.statusCode, body: data, url: request.url)
        guard http.statusCode == 401 else {
            throw LFSClientError(message, transferResult: result)
        }
        if applied.stopsRetry, request.headerFields[.authorization] != nil {
            throw LFSClientError("Authentication required: \(message)", transferResult: result)
        }
        if case .helper(let filled) = applied {
            request.headerFields[.authorization] = nil
            context.reject(filled)
        }
        let promoted = promote(http, from: access.mode)
        if promoted != access.mode {
            await finder.setAccess(LFSAccess(mode: promoted, url: access.url))
        }
        return nil
    }

    /// `HTTPTypesFoundation` turns the `HTTPRequest` into a `URLRequest` here.
    /// A file body stays on `upload(fromFile:)` and is not buffered.
    private func execute(
        _ request: HTTPRequest, body: LFSRequestBody?
    ) async throws -> (Data, HTTPURLResponse) {
        guard var urlRequest = URLRequest(httpRequest: request) else {
            throw LFSClientError("invalid URL: \(request.url?.absoluteString ?? "")")
        }
        #if os(Windows)
        // swiftlint:disable:next todo
        // TODO: Remove alongside the transfer switch when the toolchain fixes
        // https://github.com/swiftlang/swift-corelibs-foundation/issues/5532
        if request.method == .put, let body, LFSCurlUpload.usesDefaultProtocols(session.configuration) {
            let result = try await LFSCurlUpload(stream: LFSTransferStream()).execute(
                urlRequest, body: body, configuration: session.configuration)
            return (result.body, result.response)
        }
        #endif
        let data: Data
        let response: URLResponse
        switch body {
        case .file(let file):
            (data, response) = try await session.upload(for: urlRequest, fromFile: file)
        case .data(let payload):
            urlRequest.httpBody = payload
            (data, response) = try await session.data(for: urlRequest)
        case .stream(let stream):
            urlRequest.httpBodyStream = stream
            (data, response) = try await session.data(for: urlRequest)
        case nil:
            (data, response) = try await session.data(for: urlRequest)
        }
        guard let http = response as? HTTPURLResponse else {
            let method = urlRequest.httpMethod ?? request.method.rawValue
            let target = urlRequest.url?.absoluteString ?? ""
            throw LFSClientError("Invalid HTTP status for \(method) \(target): 0")
        }
        return (data, http)
    }

    /// `HTTPURLResponse.httpResponse` drops headers when its dictionary cast
    /// fails. `Content-Type` is read back so a batch body can still be decoded.
    static func makeResponse(_ http: HTTPURLResponse) -> HTTPResponse {
        var response = http.httpResponse ?? HTTPResponse(status: .init(code: http.statusCode))
        if response.headerFields[.contentType] == nil,
           let type = http.value(forHTTPHeaderField: "Content-Type") {
            response.headerFields[.contentType] = type
        }
        return response
    }

    private func resolvedRemote(_ remote: String?, operation: String) async throws -> String {
        if let remote { return remote }
        return operation == "upload" ? finder.uploadRemote() : await finder.downloadRemote()
    }

    private func applyCredentials(
        _ request: inout HTTPRequest, access: LFSAccess, endpoint: LFSEndpoint,
        operation: String, remote: String
    ) throws -> LFSAppliedCredential {
        if access.mode == "negotiate" || access.mode == "none" || Self.hasAuthorization(request) {
            return .skipped
        }
        if let embedded = embeddedPassword(request: request, endpoint: endpoint, operation: operation, remote: remote) {
            LFSStandardError.write("warning: current Git remote contains credentials\n")
            if let header = LFSBasicAuth.header(username: embedded.user, password: embedded.password) {
                request.headerFields[.authorization] = header
            }
            return .embedded
        }
        let raw = credentialURL(request: request, endpoint: endpoint, operation: operation, remote: remote)
        let parsed = LFSURL.parse(raw)
        let target = parsed.scheme.isEmpty ? raw : parsed.string()
        guard let filled = context.fill(url: parsed.scheme.isEmpty ? LFSURL.parse(target) : parsed,
                                        useHTTPPath: finder.useHTTPPath(for: target)) else {
            throw LFSClientError("Git credentials for \(target) not found.")
        }
        if let header = filled.authorization {
            request.headerFields[.authorization] = header
        }
        return .helper(filled)
    }

    private func embeddedPassword(
        request: HTTPRequest, endpoint: LFSEndpoint, operation: String, remote: String
    ) -> (user: String, password: String)? {
        let api = LFSURL.parse(endpoint.url)
        guard sameOrigin(request, as: api) else { return nil }
        if let password = api.password, let user = api.username { return (user, password) }
        guard !remote.isEmpty else { return nil }
        let git = finder.gitRemoteURL(remote, upload: operation == "upload")
        guard !git.isEmpty else { return nil }
        let parsed = LFSURL.parse(Self.fixSchemeless(git))
        guard parsed.scheme == api.scheme, parsed.hostPort == api.hostPort,
              let password = parsed.password, let user = parsed.username else { return nil }
        return (user, password)
    }

    private func credentialURL(
        request: HTTPRequest, endpoint: LFSEndpoint, operation: String, remote: String
    ) -> String {
        let api = LFSURL.parse(endpoint.url)
        if !sameOrigin(request, as: api) { return request.url?.absoluteString ?? endpoint.url }
        if !remote.isEmpty {
            let git = finder.gitRemoteURL(remote, upload: operation == "upload")
            if !git.isEmpty {
                let fixed = Self.fixSchemeless(git)
                let parsed = LFSURL.parse(fixed)
                if parsed.scheme == api.scheme && parsed.hostPort == api.hostPort { return fixed }
            }
        }
        return endpoint.url
    }

    private func sameOrigin(_ request: HTTPRequest, as api: LFSURL) -> Bool {
        let parsed = LFSURL.parse(request.url?.absoluteString ?? "")
        return parsed.scheme == api.scheme && parsed.hostPort == api.hostPort
    }

    private func promote(_ response: HTTPURLResponse, from current: String) -> String {
        modesLock.lock()
        defer { modesLock.unlock() }
        let remaining = modes.filter { $0 != current }
        let chosen = remaining.first { Self.authenticateTokens(response).contains($0) } ?? "basic"
        if chosen != current { modes = remaining }
        return chosen
    }

    private func applyExtra(_ request: inout HTTPRequest, _ headers: [(name: String, value: String)]) {
        for header in headers {
            guard let name = HTTPField.Name(header.name) else { continue }
            let existing = request.headerFields[name] ?? ""
            let values = existing.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if values.contains(header.value) { continue }
            if existing.isEmpty {
                request.headerFields[name] = header.value
            } else {
                request.headerFields[name] = existing + ", " + header.value
            }
        }
    }

    /// `getReqOperation`: `POST` and `PUT` upload; every other method downloads.
    static func operation(of request: HTTPRequest, override: String?) -> String {
        if let override { return override }
        switch request.method.rawValue.uppercased() {
        case "POST", "PUT": return "upload"
        default: return "download"
        }
    }

    static func hasAuthorization(_ request: HTTPRequest) -> Bool {
        if let value = request.headerFields[.authorization], !value.isEmpty { return true }
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return items.contains { $0.name == "token" && !($0.value ?? "").isEmpty }
    }

    static func sshRequestURL(href: String, endpointURL: String, requestURL: URL?) throws -> URL {
        guard let requestURL,
              let request = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let endpoint = URLComponents(string: endpointURL),
              var resolved = URLComponents(string: href),
              request.percentEncodedPath.hasPrefix(endpoint.percentEncodedPath) else {
            throw LFSClientError("invalid URL: \(href)")
        }
        let suffix = request.percentEncodedPath.dropFirst(endpoint.percentEncodedPath.count)
            .drop(while: { $0 == "/" })
        if !suffix.isEmpty {
            if !resolved.percentEncodedPath.hasSuffix("/") { resolved.percentEncodedPath += "/" }
            resolved.percentEncodedPath += suffix
        }
        guard let url = resolved.url else { throw LFSClientError("invalid URL: \(href)") }
        return url
    }

    static func fixSchemeless(_ raw: String) -> String {
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") || raw.hasPrefix("ssh://") { return raw }
        guard let colon = raw.firstIndex(of: ":") else { return raw }
        if let slash = raw.firstIndex(of: "/"), slash < colon { return raw }
        var replaced = raw
        replaced.replaceSubrange(colon...colon, with: "/")
        return "//" + replaced
    }

    static func requireHTTP(_ endpoint: LFSEndpoint) throws {
        if endpoint.url.hasPrefix("file://") { LFSStandardError.write(fileHint) }
        guard endpoint.url.hasPrefix("http://") || endpoint.url.hasPrefix("https://") else {
            let fragment = endpoint.url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? endpoint.url
            throw LFSClientError("missing protocol: \(fragment.goQuoted)")
        }
    }

    static func authenticateTokens(_ response: HTTPURLResponse) -> Set<String> {
        var tokens: Set<String> = []
        for name in ["Lfs-Authenticate", "WWW-Authenticate"] {
            guard let value = response.value(forHTTPHeaderField: name) else { continue }
            let token = value.split(separator: " ", maxSplits: 1).first.map { String($0).lowercased() } ?? ""
            if !token.isEmpty { tokens.insert(token) }
        }
        return tokens
    }

    static func httpMessage(status: Int, body: Data, url: URL?) -> String {
        if let message = jsonMessage(body) { return message }
        let target = url?.absoluteString ?? ""
        switch status {
        case 400: return "Client error: \(target)"
        case 401, 403:
            return "Authorization error: \(target)\nCheck that you have proper access to the repository"
        case 404:
            return "Repository or object not found: \(target)\n"
                + "Check that it exists and that you have proper access to it"
        case 422: return "Unprocessable entity: \(target)"
        case 429: return "Rate limit exceeded: \(target)"
        case 500: return "Server error: \(target)"
        case 501: return "Not Implemented: \(target)"
        case 507: return "Insufficient server storage: \(target)"
        case 509: return "Bandwidth limit exceeded: \(target)"
        default:
            if status < 500 { return "Client error \(target) from HTTP \(status)" }
            return "Server error \(target) from HTTP \(status)"
        }
    }

    static func jsonMessage(_ body: Data) -> String? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = object["message"] as? String, !message.isEmpty else { return nil }
        return message
    }

    static let fileHint = """

    hint: The remote resolves to a file:// URL, which can only work with a
    hint: standalone transfer agent.  See section "Using a Custom Transfer Type
    hint: without the API server" in custom-transfers.md for details.
    """
}

/// What `getCreds` decided. `.embedded` and `.skipped` leave a caller-supplied
/// `Authorization` in place, which aborts the 401 retry.
private enum LFSAppliedCredential {
    case skipped
    case embedded
    case helper(LFSFilledCredential)

    var stopsRetry: Bool {
        if case .helper = self { return false }
        return true
    }
}
