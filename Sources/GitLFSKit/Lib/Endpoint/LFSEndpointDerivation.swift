import Foundation
import ShellKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Android)
import Android
#endif

/// `lfsapi.endpointGitFinder.NewEndpoint` and `lfshttp.EndpointFrom*`.
enum LFSEndpointDerivation {
    static func fromCloneURL(
        _ raw: String, upload: Bool, gitProtocol: String, aliases: AliasMaps, base: String
    ) -> LFSEndpoint {
        var endpoint = fromURL(raw, upload: upload, gitProtocol: gitProtocol, aliases: aliases, base: base)
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

    static func fromURL(
        _ raw: String, upload: Bool, gitProtocol: String, aliases: AliasMaps, base: String
    ) -> LFSEndpoint {
        let raw = aliases.replace(raw, upload: upload)
        if raw.hasPrefix("/") { return fromLocalPath(raw, base: base) }
        #if os(Windows)
        if raw.contains(":\\") || raw.hasPrefix("\\\\") { return fromLocalPath(raw, base: base) }
        #endif
        guard let scheme = LFSURL.scheme(of: raw) else {
            if fileExists(raw, base: base) { return fromLocalPath(raw, base: base) }
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
            if fileExists(raw, base: base) { return fromLocalPath(raw, base: base) }
            // A bare alias such as `host:repo` is an opaque URL to Go's
            // net/url. Preserve that spelling; LFSURL.string() would turn
            // it into `host://repo` and insert two slashes into the SSH path.
            return fromBareSSH(raw)
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
    static func fromLocalPath(_ path: String, base: String) -> LFSEndpoint {
        let url = rewriteLocalPath(path, base: base)
        return LFSEndpoint(url: url, originalURL: url)
    }

    static func rewriteLocalPath(_ path: String, base: String) -> String {
        var path = path
        var slash = ""
        let absolute = absolutePath(path, base: base)
        if !absolute.hasPrefix("/") { slash = "/" }
        path = absolute
        let leaf = (path as NSString).lastPathComponent
        var gitpath: String
        if leaf == ".git" {
            gitpath = path
            path = (path as NSString).deletingLastPathComponent
        } else {
            gitpath = (path as NSString).appendingPathComponent(".git")
        }
        if fileExists(gitpath, base: base) {
            path = gitpath
        } else if !fileExists(path, base: base) {
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

    static func fileExists(_ path: String, base: String) -> Bool {
        FileManager.default.fileExists(atPath: located(path, base: base))
    }

    /// `filepath.Abs`, then `filepath.Clean`. A relative path joins `base`,
    /// the repository directory git-lfs would have been run in, rather than
    /// the process's current directory. That join uses `os.Getwd`, and `PWD`
    /// comes from the bound shell, not the host process.
    /// Symlinks inside the relative path itself are left alone.
    static func absolutePath(_ path: String, base: String) -> String {
        absolutePath(path, base: base, pwd: Shell.env("PWD"))
    }

    static func absolutePath(_ path: String, base: String, pwd: String?) -> String {
        clean(located(path, base: base, pwd: pwd))
    }

    /// An absolute path stays put. A relative one is joined onto `base`
    /// the way `filepath.Abs` joins onto the process directory.
    static func located(_ path: String, base: String) -> String {
        located(path, base: base, pwd: Shell.env("PWD"))
    }

    static func located(_ path: String, base: String, pwd: String?) -> String {
        if (path as NSString).isAbsolutePath || base.isEmpty { return path }
        let root = getwd(base, pwd: pwd) ?? base
        return (root as NSString).appendingPathComponent(path)
    }

    /// `os.Getwd` after the process directory is `base`. An absolute `PWD`
    /// that names that directory is returned unchanged, so a symlink the
    /// caller entered through stays in the path. Otherwise the kernel path:
    /// on Darwin, `/var` is `/private/var`.
    static func getwd(_ base: String, pwd: String?) -> String? {
        #if os(Windows)
        _ = pwd
        let resolved = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        return resolved.isEmpty ? nil : resolved
        #else
        if let pwd, (pwd as NSString).isAbsolutePath, sameFile(pwd, base) {
            return pwd
        }
        guard let resolved = realpath(base, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
        #endif
    }

    #if !os(Windows)
    /// `os.SameFile`: same device and inode. `stat` follows the last symlink.
    private static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = identity(lhs), let right = identity(rhs) else { return false }
        return left.dev == right.dev && left.ino == right.ino
    }

    private static func identity(_ path: String) -> (dev: UInt64, ino: UInt64)? {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
        return (UInt64(truncatingIfNeeded: info.st_dev), UInt64(truncatingIfNeeded: info.st_ino))
    }
    #endif

    /// `filepath.Clean`. A Windows drive or UNC share is a volume, so `..`
    /// that walks off `C:\` stays on that drive (`C:\server.git`).
    static func clean(_ path: String) -> String {
        if let cleaned = windowsClean(path) { return cleaned }
        return slashClean(path, separator: "/")
    }

    /// `C:` or `\\server\share`, after `/` has been normalized to `\`.
    private static func volumeName(_ path: String) -> String {
        if path.count >= 2 {
            let start = path.startIndex
            let second = path.index(after: start)
            if path[second] == ":", isASCIILetter(path[start]) {
                return String(path[start...second])
            }
        }
        guard path.hasPrefix("\\\\") else { return "" }
        let pieces = path.dropFirst(2).split(separator: "\\", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count >= 2, !pieces[0].isEmpty, !pieces[1].isEmpty else { return "" }
        return "\\\\" + pieces[0] + "\\" + pieces[1]
    }

    /// Nil when `path` is a Unix path. Otherwise `filepath.Clean` on Windows.
    private static func windowsClean(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "/", with: "\\")
        let volume = volumeName(normalized)
        let backslash = path.contains("\\") && !path.hasPrefix("/")
        guard !volume.isEmpty || backslash else { return nil }
        var rest = String(normalized.dropFirst(volume.count))
        let rooted = rest.hasPrefix("\\")
        if rooted { rest.removeFirst() }
        var stack: [String] = []
        var leading = 0
        for part in rest.split(separator: "\\", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !stack.isEmpty {
                    stack.removeLast()
                } else if !rooted {
                    leading += 1
                }
                continue
            }
            stack.append(String(part))
        }
        let tail = (Array(repeating: "..", count: leading) + stack).joined(separator: "\\")
        if rooted { return volume + "\\" + tail }
        if tail.isEmpty { return volume.isEmpty ? "\\" : volume }
        return volume + tail
    }

    private static func slashClean(_ path: String, separator: Character) -> String {
        let rooted = path.hasPrefix(String(separator))
        var stack: [String] = []
        for part in path.split(separator: separator, omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !rooted {
                    stack.append("..")
                }
                continue
            }
            stack.append(String(part))
        }
        let joined = stack.joined(separator: String(separator))
        if rooted { return String(separator) + joined }
        return joined.isEmpty ? "." : joined
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value, character.unicodeScalars.count == 1 else {
            return false
        }
        return (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
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
