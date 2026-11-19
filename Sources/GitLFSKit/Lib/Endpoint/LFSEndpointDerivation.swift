import Foundation

/// `lfsapi.endpointGitFinder.NewEndpoint` and `lfshttp.EndpointFrom*`.
enum LFSEndpointDerivation {
    static func fromCloneURL(_ raw: String, upload: Bool, gitProtocol: String, aliases: AliasMaps) -> LFSEndpoint {
        var endpoint = fromURL(raw, upload: upload, gitProtocol: gitProtocol, aliases: aliases)
        if endpoint.url == LFSEndpoint.unknown { return endpoint }
        if endpoint.url.hasSuffix("/") { endpoint.url.removeLast() }
        if endpoint.url.hasPrefix("file://") { return endpoint }
        if LFSURL.pathExtension(endpoint.url) == ".git" {
            endpoint.url += "/info/lfs"
        } else {
            endpoint.url += ".git/info/lfs"
        }
        return endpoint
    }

    static func fromURL(_ raw: String, upload: Bool, gitProtocol: String, aliases: AliasMaps) -> LFSEndpoint {
        let raw = aliases.replace(raw, upload: upload)
        if raw.hasPrefix("/") { return fromLocalPath(raw) }
        #if os(Windows)
        if raw.contains(":\\") || raw.hasPrefix("\\\\") { return fromLocalPath(raw) }
        #endif
        guard let scheme = LFSURL.scheme(of: raw) else {
            if fileExists(raw) { return fromLocalPath(raw) }
            return fromBareSSH(raw)
        }
        switch scheme {
        case "ssh", "git+ssh", "ssh+git":
            return fromSSH(LFSURL.parse(raw))
        case "http", "https":
            let text = LFSURL.parse(raw).string()
            return LFSEndpoint(url: text, originalURL: text)
        case "git":
            var parsed = LFSURL.parse(raw)
            parsed.scheme = gitProtocol
            return LFSEndpoint(url: parsed.string())
        case "file":
            let text = LFSURL.parse(raw).string()
            return LFSEndpoint(url: text, originalURL: text)
        default:
            if raw.hasPrefix(scheme + "::") { return LFSEndpoint(url: raw) }
            if fileExists(raw) { return fromLocalPath(raw) }
            return fromBareSSH(LFSURL.parse(raw).string())
        }
    }

    /// `EndpointFromSshUrl`.
    static func fromSSH(_ url: LFSURL) -> LFSEndpoint {
        let hostport = url.hostPort
        guard let match = sshHost(hostport) else { return LFSEndpoint(url: LFSEndpoint.unknown) }
        let user = url.username ?? ""
        let userAndHost = user.isEmpty ? match.host : "\(user)@\(match.host)"
        let metadata = LFSSSHMetadata(
            user: user, host: match.host, port: match.port,
            path: url.path, userAndHost: userAndHost)
        let https = "https://\(match.host)\(LFSURL.escapedPath(url.path))"
        return LFSEndpoint(url: https, ssh: metadata, originalURL: url.string())
    }

    /// `EndpointFromBareSshUrl`. A leading slash is then stripped from the SSH path.
    static func fromBareSSH(_ raw: String) -> LFSEndpoint {
        let parts = splitColon(raw)
        guard parts.count >= 2 else { return LFSEndpoint(url: raw) }
        let newPath: String
        if parts.count > 2 {
            var head = parts
            if head[0].hasPrefix("[") { head[0].removeFirst() }
            if head[1].hasSuffix("]") { head[1].removeLast() }
            newPath = head[0] + ":" + head[1...].joined(separator: "/")
        } else {
            newPath = parts.joined(separator: "/")
        }
        var endpoint = fromSSH(LFSURL.parse("ssh://\(newPath)"))
        if endpoint.ssh.path.hasPrefix("/") { endpoint.ssh.path.removeFirst() }
        return endpoint
    }

    /// `git.RewriteLocalPathAsURL`, then an endpoint whose URL is that result.
    static func fromLocalPath(_ path: String) -> LFSEndpoint {
        let url = rewriteLocalPath(path)
        return LFSEndpoint(url: url, originalURL: url)
    }

    static func rewriteLocalPath(_ path: String) -> String {
        var path = path
        var slash = ""
        let absolute = absolutePath(path)
        if !absolute.hasPrefix("/") { slash = "/" }
        path = absolute
        let base = (path as NSString).lastPathComponent
        var gitpath: String
        if base == ".git" {
            gitpath = path
            path = (path as NSString).deletingLastPathComponent
        } else {
            gitpath = (path as NSString).appendingPathComponent(".git")
        }
        if fileExists(gitpath) {
            path = gitpath
        } else if !fileExists(path) {
            return path
        }
        let slashed = path.replacingOccurrences(of: "\\", with: "/")
        return "file://\(slash)\(slashed)"
    }

    /// `^([^:]+)(?::(\d+))?$` against `url.URL.Host`.
    static func sshHost(_ hostport: String) -> (host: String, port: String)? {
        guard let colon = hostport.firstIndex(of: ":") else {
            guard !hostport.isEmpty else { return nil }
            return (hostport, "")
        }
        let host = String(hostport[..<colon])
        let port = String(hostport[hostport.index(after: colon)...])
        guard !host.isEmpty, !port.isEmpty, port.allSatisfy({ $0.isNumber }) else { return nil }
        return (host, port)
    }

    static func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// `filepath.Abs` without resolving symlinks, then `filepath.Clean`.
    static func absolutePath(_ path: String) -> String {
        let absolute: String
        if (path as NSString).isAbsolutePath {
            absolute = path
        } else {
            absolute = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        }
        return clean(absolute)
    }

    static func clean(_ path: String) -> String {
        let windows = path.contains("\\") && !path.hasPrefix("/")
        let slash: Character = windows ? "\\" : "/"
        var stack: [String] = []
        for part in path.split(separator: slash, omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            stack.append(String(part))
        }
        let joined = stack.joined(separator: String(slash))
        if path.hasPrefix(String(slash)) { return String(slash) + joined }
        return joined.isEmpty ? String(slash) : joined
    }

    static func splitColon(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in raw {
            if character == ":" {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }
}

/// `url.*.insteadof` / `url.*.pushinsteadof`. The alias (the config value)
/// is replaced by the URL it names. The lexicographically greatest matching
/// prefix wins, which is the longest when one match extends another.
struct AliasMaps: Sendable {
    var insteadOf: [String: String] = [:]
    var pushInsteadOf: [String: String] = [:]

    init(configuration: LFSConfiguration) {
        let suffix = ".insteadof"
        let pushSuffix = ".pushinsteadof"
        for entry in configuration.entries {
            guard entry.key.hasPrefix("url.") else { continue }
            if entry.key.hasSuffix(suffix) {
                store(&insteadOf, key: entry.key, value: entry.value, suffix: suffix)
            } else if entry.key.hasSuffix(pushSuffix) {
                store(&pushInsteadOf, key: entry.key, value: entry.value, suffix: pushSuffix)
            }
        }
    }

    func replace(_ raw: String, upload: Bool) -> String {
        if upload, let replaced = apply(pushInsteadOf, to: raw) { return replaced }
        return apply(insteadOf, to: raw) ?? raw
    }

    func replace(_ raw: String) -> String { replace(raw, upload: false) }

    private func apply(_ aliases: [String: String], to raw: String) -> String? {
        var longest = ""
        var found = false
        for alias in aliases.keys where raw.hasPrefix(alias) {
            if !found || longest < alias {
                longest = alias
                found = true
            }
        }
        guard found, let base = aliases[longest] else { return nil }
        return base + raw.dropFirst(longest.count)
    }

    private func store(_ aliases: inout [String: String], key: String, value: String, suffix: String) {
        guard !value.isEmpty else { return }
        let url = String(key.dropFirst("url.".count).dropLast(suffix.count))
        if let existing = aliases[value], existing != url {
            let quoted = value.goQuoted
            LFSStandardError.write("warning: Multiple 'url.*.\(suffix)' keys with the same alias: \(quoted)\n")
        }
        aliases[value] = url
    }
}
