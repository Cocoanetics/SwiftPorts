import Foundation
import ShellKit
import SwiftGit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why an LFS HTTP request failed, in git-lfs's words.
public struct LFSClientError: Error, Equatable, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Sends an LFS request the way `lfsapi.Client.DoWithAuth` does: `http.<url>.extraHeader`
/// on every attempt, and credentials only once access is no longer `none`
/// (URL-embedded, then `~/.netrc`, then the caller's `CredentialProvider`).
/// A 401 selects the next access mode — `basic` when the server doesn't say —
/// writes `lfs.<url>.access`, and retries. `User-Agent` is `git-lfs`.
public final class LFSClient: @unchecked Sendable {
    public let finder: LFSEndpointFinder
    let context: LFSCredentialContext
    let session: URLSession
    private var modes = ["none", "negotiate", "basic"]

    public init(git: GitClient, credentials: CredentialProvider? = nil, session: URLSession? = nil) async {
        let finder = await LFSEndpointFinder(git)
        self.finder = finder
        context = LFSCredentialContext(
            netrc: NetrcFile.load(home: Shell.env("HOME")),
            provider: credentials,
            cacheEnabled: finder.cacheCredentials)
        self.session = session ?? URLSession(configuration: .default)
    }

    /// `DoAPIRequestWithAuth` for an already built request. `operation` defaults
    /// from the method (`GET`/`HEAD` download, anything else upload). A nil
    /// `remote` is the selected download or upload remote.
    @discardableResult
    public func data(for request: URLRequest, operation: String? = nil, remote: String? = nil) async throws -> Data {
        let operation = Self.operation(of: request, override: operation)
        let remote = try await resolvedRemote(remote, operation: operation)
        let endpoint = finder.endpoint(operation: operation, remote: remote)
        try Self.requireHTTP(endpoint)
        var request = request
        let starting = finder.access(for: endpoint.url)
        let attempts = starting.mode == "none" ? 4 : 3
        for index in 0..<attempts {
            if try await perform(&request, endpoint: endpoint, operation: operation, remote: remote) {
                return body()
            }
            if index == attempts - 1 { break }
        }
        throw LFSClientError("too many authentication attempts")
    }

    /// The body of the attempt ``perform`` just accepted.
    private var carried: Data?
    private func body() -> Data {
        defer { carried = nil }
        return carried ?? Data()
    }

    /// Performs one attempt. Returns true when the response is success and ``carried`` holds the body.
    private func perform(
        _ request: inout URLRequest, endpoint: LFSEndpoint, operation: String, remote: String
    ) async throws -> Bool {
        let access = finder.access(for: endpoint.url)
        applyExtra(&request, finder.extraHeaders(for: request.url?.absoluteString ?? endpoint.url))
        let applied = try applyCredentials(
            &request, access: access, endpoint: endpoint, operation: operation, remote: remote)
        request.setValue("git-lfs", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            let method = request.httpMethod ?? "GET"
            throw LFSClientError("Invalid HTTP status for \(method) \(request.url?.absoluteString ?? ""): 0")
        }
        if (200..<300).contains(http.statusCode) {
            if case .helper(let filled) = applied { context.approve(filled) }
            carried = data
            return true
        }
        if http.statusCode < 400 {
            carried = data
            return true
        }
        let message = Self.httpMessage(status: http.statusCode, body: data, url: request.url)
        guard http.statusCode == 401 else { throw LFSClientError(message) }
        if applied.stopsRetry, request.value(forHTTPHeaderField: "Authorization") != nil {
            throw LFSClientError("Authentication required: \(message)")
        }
        if case .helper(let filled) = applied {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            context.reject(filled)
        }
        let promoted = promote(http, from: access.mode)
        if promoted != access.mode {
            await finder.setAccess(LFSAccess(mode: promoted, url: access.url))
        }
        return false
    }

    private func resolvedRemote(_ remote: String?, operation: String) async throws -> String {
        if let remote { return remote }
        return operation == "upload" ? finder.uploadRemote() : await finder.downloadRemote()
    }

    private func applyCredentials(
        _ request: inout URLRequest, access: LFSAccess, endpoint: LFSEndpoint,
        operation: String, remote: String
    ) throws -> LFSAppliedCredential {
        if access.mode == "negotiate" || access.mode == "none" || Self.hasAuthorization(request) {
            return .skipped
        }
        if let embedded = embeddedPassword(request: request, endpoint: endpoint, operation: operation, remote: remote) {
            LFSStandardError.write("warning: current Git remote contains credentials\n")
            if let header = LFSBasicAuth.header(username: embedded.user, password: embedded.password) {
                request.setValue(header, forHTTPHeaderField: "Authorization")
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
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return .helper(filled)
    }

    private func embeddedPassword(
        request: URLRequest, endpoint: LFSEndpoint, operation: String, remote: String
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
        request: URLRequest, endpoint: LFSEndpoint, operation: String, remote: String
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

    private func sameOrigin(_ request: URLRequest, as api: LFSURL) -> Bool {
        let parsed = LFSURL.parse(request.url?.absoluteString ?? "")
        return parsed.scheme == api.scheme && parsed.hostPort == api.hostPort
    }

    private func promote(_ response: HTTPURLResponse, from current: String) -> String {
        let remaining = modes.filter { $0 != current }
        let chosen = remaining.first { Self.authenticateTokens(response).contains($0) } ?? "basic"
        if chosen != current { modes = remaining }
        return chosen
    }

    private func applyExtra(_ request: inout URLRequest, _ headers: [(name: String, value: String)]) {
        for header in headers {
            let existing = request.value(forHTTPHeaderField: header.name) ?? ""
            let values = existing.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if values.contains(header.value) { continue }
            if existing.isEmpty {
                request.setValue(header.value, forHTTPHeaderField: header.name)
            } else {
                request.addValue(header.value, forHTTPHeaderField: header.name)
            }
        }
    }

    /// `getReqOperation`: `POST` and `PUT` upload; every other method downloads.
    static func operation(of request: URLRequest, override: String?) -> String {
        if let override { return override }
        switch (request.httpMethod ?? "GET").uppercased() {
        case "POST", "PUT": return "upload"
        default: return "download"
        }
    }

    static func hasAuthorization(_ request: URLRequest) -> Bool {
        if let value = request.value(forHTTPHeaderField: "Authorization"), !value.isEmpty { return true }
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return items.contains { $0.name == "token" && !($0.value ?? "").isEmpty }
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
        case 429: return "Rate limit exceeded: \(target)"
        case 500: return "Server error: \(target)"
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
