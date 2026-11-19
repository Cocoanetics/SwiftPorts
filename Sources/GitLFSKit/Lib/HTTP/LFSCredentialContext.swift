import Foundation
import SwiftGit

/// A credential git-lfs would take from netrc, its memory cache, or
/// `git credential fill`. The provider stands in for the helper.
struct LFSFilledCredential: Equatable, Sendable {
    var username: String
    var password: String
    /// `netrc`, `cache` or `provider`.
    var source: String
    var protocolName: String
    var host: String
    var path: String

    var authorization: String? { LFSBasicAuth.header(username: username, password: password) }
}

enum LFSBasicAuth {
    /// `Basic ` + standard base64 of `user:pass`. Empty user and password set nothing.
    static func header(username: String, password: String) -> String? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }
}

/// netrc, then the in-memory cache (`lfs.cachecredentials`, default on), then the provider.
/// Approve of a netrc credential clears its skip and does not cache it.
/// Reject of a netrc credential skips that host. Reject of anything else drops the cache entry.
final class LFSCredentialContext: @unchecked Sendable {
    let netrc: NetrcFile?
    let provider: CredentialProvider?
    let cacheEnabled: Bool
    private let lock = NSLock()
    private var skippedHosts: Set<String> = []
    private var cache: [String: LFSFilledCredential] = [:]

    init(netrc: NetrcFile?, provider: CredentialProvider?, cacheEnabled: Bool) {
        self.netrc = netrc
        self.provider = provider
        self.cacheEnabled = cacheEnabled
    }

    func fill(url: LFSURL, useHTTPPath: Bool) -> LFSFilledCredential? {
        let host = url.hostPort
        let path = useHTTPPath && url.path.hasPrefix("/") ? String(url.path.dropFirst()) : (useHTTPPath ? url.path : "")
        if let netrc, let hostname = NetrcHost.name(of: host), !isSkipped(hostname),
           let machine = netrc.find(host: hostname, login: url.username ?? "") {
            return LFSFilledCredential(
                username: machine.login, password: machine.password, source: "netrc",
                protocolName: url.scheme, host: host, path: path)
        }
        let key = cacheKey(protocolName: url.scheme, host: host, path: path)
        if cacheEnabled, let cached = cached(key) { return cached }
        return providerCredential(url: url, host: host, path: path)
    }

    func approve(_ credential: LFSFilledCredential) {
        if credential.source == "netrc" {
            guard let hostname = NetrcHost.name(of: credential.host) else { return }
            lock.lock()
            skippedHosts.remove(hostname)
            lock.unlock()
            return
        }
        guard cacheEnabled else { return }
        lock.lock()
        cache[cacheKey(credential)] = credential
        lock.unlock()
    }

    func reject(_ credential: LFSFilledCredential) {
        if credential.source == "netrc" {
            guard let hostname = NetrcHost.name(of: credential.host) else { return }
            lock.lock()
            skippedHosts.insert(hostname)
            lock.unlock()
            return
        }
        lock.lock()
        cache.removeValue(forKey: cacheKey(credential))
        lock.unlock()
    }

    private func providerCredential(url: LFSURL, host: String, path: String) -> LFSFilledCredential? {
        guard let provider, let foundation = URL(string: url.string()) else { return nil }
        switch provider(foundation, url.username, .userPassword) {
        case .userPassword(let username, let password):
            return LFSFilledCredential(
                username: username, password: password, source: "provider",
                protocolName: url.scheme, host: host, path: path)
        case .token(let token, let username):
            return LFSFilledCredential(
                username: username, password: token, source: "provider",
                protocolName: url.scheme, host: host, path: path)
        default:
            return nil
        }
    }

    private func isSkipped(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return skippedHosts.contains(host)
    }

    private func cached(_ key: String) -> LFSFilledCredential? {
        lock.lock()
        defer { lock.unlock() }
        guard var found = cache[key] else { return nil }
        found.source = "cache"
        return found
    }

    private func cacheKey(_ credential: LFSFilledCredential) -> String {
        cacheKey(protocolName: credential.protocolName, host: credential.host, path: credential.path)
    }

    private func cacheKey(protocolName: String, host: String, path: String) -> String {
        "\(protocolName)//\(host)//\(path)"
    }
}
