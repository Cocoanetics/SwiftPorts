import Foundation
import ShellKit
import SwiftGit

/// The access mode `lfs.<url>.access` names (`creds.AccessMode`).
public struct LFSAccess: Sendable, Equatable {
    /// `none`, `basic`, `negotiate`, or whatever else was configured, lowercased.
    /// `private` is reported as `basic`.
    public var mode: String
    /// The URL with any userinfo removed, which is also the config key's middle.
    public var url: String

    public init(mode: String, url: String) {
        self.mode = mode
        self.url = url
    }
}

/// Which LFS endpoint a download or upload talks to (`lfsapi.EndpointFinder`).
public final class LFSEndpointFinder: @unchecked Sendable {
    let client: GitClient
    let configuration: LFSConfiguration
    let aliases: AliasMaps
    let urlConfig: LFSURLConfig
    let gitProtocol: String
    /// `nil` when HEAD is unborn or detached, matching git-lfs's failed `ResolveRef`.
    let branch: String?
    let remoteNames: [String]
    let fetchHead: String?
    private let lock = NSLock()
    private var urlAccess: [String: String] = [:]

    public init(_ client: GitClient) async {
        self.client = client
        let configuration = await LFSConfiguration.load(client)
        self.configuration = configuration
        aliases = AliasMaps(configuration: configuration)
        urlConfig = LFSURLConfig(configuration: configuration)
        let protocolName = configuration.get("lfs.gitprotocol") ?? ""
        gitProtocol = protocolName.isEmpty ? "https" : protocolName
        branch = try? await client.currentBranch()
        remoteNames = (try? await client.remoteList()) ?? []
        fetchHead = await Self.readFetchHead(try? await client.gitDir())
    }

    /// `Endpoint`. An empty `remote` resolves `origin` after `lfs.url`.
    public func endpoint(operation: String, remote: String = "") -> LFSEndpoint {
        var resolved = resolve(operation: operation, remote: remote)
        resolved.operation = operation
        return resolved
    }

    /// `AccessFor`. The result is cached for this finder.
    public func access(for rawURL: String) -> LFSAccess {
        let url = Self.urlWithoutAuth(rawURL)
        if let cached = cachedAccess(url) { return LFSAccess(mode: cached, url: url) }
        let mode = gitAccess(url)
        storeAccess(url, mode)
        return LFSAccess(mode: mode, url: url)
    }

    /// `SetAccess`: `none` or an empty mode unsets `lfs.<url>.access`; anything
    /// else is written to the repository config. The cache updates either way.
    public func setAccess(_ access: LFSAccess) async {
        let key = "lfs.\(access.url).access"
        if access.mode.isEmpty || access.mode == "none" {
            storeAccess(access.url, "none")
            _ = try? await client.configUnset(key)
            return
        }
        storeAccess(access.url, access.mode)
        try? await client.configSet(key, access.mode)
    }

    /// The `Endpoint=` / `Endpoint (<remote>)=` lines of `git lfs env`.
    /// The default line is printed only when the selected remote is `origin`.
    /// Autodetect does not apply here; `git lfs env` doesn't use it either.
    public func environmentEndpoints() -> [String: String] {
        let selected = configuredDownloadRemote()
        var lines: [String: String] = [:]
        if selected == "origin" {
            let endpoint = self.endpoint(operation: "download", remote: "origin")
            if !endpoint.url.isEmpty {
                lines["Endpoint"] = described(endpoint)
            }
        }
        for remote in configuration.remotes {
            if selected == "origin" && remote == "origin" { continue }
            lines["Endpoint (\(remote))"] = described(self.endpoint(operation: "download", remote: remote))
        }
        return lines
    }

    func extraHeaders(for url: String) -> [(name: String, value: String)] {
        urlConfig.extraHeaders(for: url)
    }

    var cacheCredentials: Bool {
        LFSConfiguration.bool(configuration.get("lfs.cachecredentials"), fallback: true)
    }

    func useHTTPPath(for url: String) -> Bool {
        urlConfig.bool(prefix: "credential", url: url, key: "usehttppath", fallback: false)
    }

    /// `GitRemoteURL`. An empty `pushurl` that is set hides `url`. A remote
    /// git knows but that has no URL is named by itself.
    func gitRemoteURL(_ remote: String, upload: Bool) -> String {
        if upload {
            let push = configuration.getAll("remote.\(remote).pushurl")
            if !push.isEmpty { return push.last ?? "" }
        }
        if let url = configuration.get("remote.\(remote).url") { return url }
        if remoteNames.contains(remote) { return remote }
        return ""
    }

    private func resolve(operation: String, remote: String) -> LFSEndpoint {
        let upload = operation == "upload"
        if upload, let push = configuration.get("lfs.pushurl") {
            return derived(push, upload: true, clone: false)
        }
        if let url = configuration.get("lfs.url") {
            return derived(url, upload: upload, clone: false)
        }
        if !remote.isEmpty && remote != "origin" {
            let named = remoteEndpoint(operation: operation, remote: remote)
            if !named.url.isEmpty { return named }
        }
        return remoteEndpoint(operation: operation, remote: "origin")
    }

    private func remoteEndpoint(operation: String, remote: String) -> LFSEndpoint {
        let remote = remote.isEmpty ? "origin" : remote
        let upload = operation == "upload"
        if upload, let push = configuration.get("remote.\(remote).lfspushurl") {
            return derived(push, upload: true, clone: false)
        }
        if let url = configuration.get("remote.\(remote).lfsurl") {
            return derived(url, upload: upload, clone: false)
        }
        let git = gitRemoteURL(remote, upload: upload)
        if !git.isEmpty { return derived(git, upload: upload, clone: true) }
        if remote == "origin", let fetchHead {
            // FETCH_HEAD is only ever a download URL.
            return derived(fetchHead, upload: false, clone: true)
        }
        return LFSEndpoint()
    }

    private func derived(_ raw: String, upload: Bool, clone: Bool) -> LFSEndpoint {
        if clone {
            return LFSEndpointDerivation.fromCloneURL(raw, upload: upload, gitProtocol: gitProtocol, aliases: aliases)
        }
        return LFSEndpointDerivation.fromURL(raw, upload: upload, gitProtocol: gitProtocol, aliases: aliases)
    }

    private func described(_ endpoint: LFSEndpoint) -> String {
        "\(endpoint.url) (auth=\(access(for: endpoint.url).mode))"
    }

    private func gitAccess(_ url: String) -> String {
        guard let value = urlConfig.get(prefix: "lfs", url: url, key: "access"), !value.isEmpty else {
            return "none"
        }
        let mode = value.lowercased()
        return mode == "private" ? "basic" : mode
    }

    private func cachedAccess(_ url: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return urlAccess[url]
    }

    private func storeAccess(_ url: String, _ mode: String) {
        lock.lock()
        urlAccess[url] = mode
        lock.unlock()
    }

    /// `urlWithoutAuth`: a URL with no `@` is kept verbatim, so it isn't re-encoded.
    static func urlWithoutAuth(_ raw: String) -> String {
        guard raw.contains("@") else { return raw }
        var parsed = LFSURL.parse(raw)
        guard parsed.username != nil || parsed.password != nil else { return raw }
        parsed.username = nil
        parsed.password = nil
        return parsed.string()
    }

    private static func readFetchHead(_ gitDir: String?) async -> String? {
        guard var dir = gitDir, !dir.isEmpty else { return nil }
        while dir.hasSuffix("/") { dir.removeLast() }
        let path = dir + "/FETCH_HEAD"
        let url = URL(fileURLWithPath: path)
        _ = try? await Shell.authorize(url)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: false).first else { return nil }
        return extractRemoteURL(String(line).trimmingCharacters(in: .newlines))
    }

    /// `ExtractRemoteUrl`. The URL class does not include `@`.
    static func extractRemoteURL(_ line: String) -> String? {
        let pattern = "^[a-f0-9]{40,64}\t(not-for-merge)?\t(tag |branch |)'.+' of ([/.:_a-zA-Z0-9-]+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 4,
              let url = Range(match.range(at: 3), in: line) else { return nil }
        return String(line[url])
    }
}
