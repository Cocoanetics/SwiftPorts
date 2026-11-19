import Foundation

/// `http.<url>.<key>` / `lfs.<url>.<key>` matching (`config.URLConfig`).
/// The best host wins, then the best path, then an exact username. With
/// nothing specific, `prefix.key` is the fallback.
struct LFSURLConfig: Sendable {
    let configuration: LFSConfiguration

    func get(prefix: String, url: String, key: String) -> String? {
        let values = getAll(prefix: prefix, url: url, key: key)
        return values.last
    }

    func getAll(prefix: String, url: String, key: String) -> [String] {
        let prefix = prefix.lowercased()
        let key = key.lowercased()
        if let matched = matchedKey(prefix: prefix, url: url, key: key) {
            let values = configuration.getAll(matched)
            if !values.isEmpty { return values }
        }
        return configuration.getAll(prefix + "." + key)
    }

    func bool(prefix: String, url: String, key: String, fallback: Bool) -> Bool {
        LFSConfiguration.bool(get(prefix: prefix, url: url, key: key), fallback: fallback)
    }

    /// `Name: value` entries of `http.<url>.extraHeader`, canonicalized the
    /// way `textproto.CanonicalMIMEHeaderKey` does, without repeating a value.
    func extraHeaders(for url: String) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = []
        for header in getAll(prefix: "http", url: url, key: "extraHeader") {
            guard let colon = header.firstIndex(of: ":") else { continue }
            let name = canonicalMIME(String(header[..<colon]))
            let value = String(header[header.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if headers.contains(where: { $0.name == name && $0.value == value }) { continue }
            headers.append((name, value))
        }
        return headers
    }

    private func matchedKey(prefix: String, url raw: String, key: String) -> String? {
        let search = LFSURL.parse(raw)
        guard !search.scheme.isEmpty else { return nil }
        let suffix = "." + key
        let stem = prefix + "."
        var bestHost = 0
        var bestPath = 0
        var bestUser = 0
        var best: String?
        // Higher-priority entries were appended later; walk them first so an
        // equal score keeps the one git would read last.
        for entry in configuration.entries.reversed() {
            let name = entry.key
            guard name.hasPrefix(stem), name.hasSuffix(suffix) else { continue }
            let middle = name.dropFirst(stem.count).dropLast(suffix.count)
            guard !middle.isEmpty else { continue }
            let config = LFSURL.parse(String(middle))
            guard config.scheme == search.scheme else { continue }
            let hostScore = compareHosts(search.host, config.host)
            if hostScore == 0 || hostScore < bestHost { continue }
            if port(of: search) != port(of: config) { continue }
            let pathScore = comparePaths(search.path, config.path)
            if pathScore == 0 { continue }
            var userMatch = 0
            if let configured = config.username {
                guard search.username == configured else { continue }
                userMatch = 1
            }
            if hostScore > bestHost || pathScore > bestPath || (pathScore == bestPath && userMatch > bestUser) {
                bestHost = hostScore
                bestPath = pathScore
                bestUser = userMatch
                best = name
            }
        }
        return best
    }

    private func port(of url: LFSURL) -> String {
        if !url.port.isEmpty { return url.port }
        switch url.scheme {
        case "http": return "80"
        case "https": return "443"
        case "ssh": return "22"
        default: return ""
        }
    }

    /// Score is `labels + 1`, minus one per `*`. A different label count, or
    /// a label that isn't `*` and isn't equal, does not match.
    private func compareHosts(_ search: String, _ config: String) -> Int {
        let left = search.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let right = config.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard left.count == right.count else { return 0 }
        var score = left.count + 1
        for (wanted, pattern) in zip(left, right) {
            if pattern == "*" {
                score -= 1
                continue
            }
            if wanted != pattern { return 0 }
        }
        return score
    }

    /// Slash-delimited elements. A search element `name.git` matches a
    /// configured `name` when `info`/`lfs` follow it, for one point instead of two.
    private func comparePaths(_ search: String, _ config: String) -> Int {
        let searchParts = fields(search)
        let configParts = fields(config)
        guard searchParts.count >= configParts.count else { return 0 }
        var score = 1
        for (index, element) in configParts.enumerated() {
            let wanted = searchParts[index]
            if element == wanted {
                score += 2
                continue
            }
            if isDefaultLFS(wanted, searchParts, index + 1),
               wanted.hasSuffix(".git"),
               String(wanted.dropLast(4)) == element {
                score += 1
                continue
            }
            return 0
        }
        return score
    }

    private func fields(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private func isDefaultLFS(_ path: String, _ parts: [String], _ index: Int) -> Bool {
        guard path.count >= 5, path.hasSuffix(".git"), index <= parts.count - 2 else { return false }
        return parts[index] == "info" && parts[index + 1] == "lfs"
    }

    /// `textproto.CanonicalMIMEHeaderKey`.
    static func canonicalMIME(_ key: String) -> String {
        var text = ""
        var capitalize = true
        for character in key {
            if character == "-" {
                text.append("-")
                capitalize = true
            } else if capitalize {
                text.append(contentsOf: character.uppercased())
                capitalize = false
            } else {
                text.append(contentsOf: character.lowercased())
            }
        }
        return text
    }

    private func canonicalMIME(_ key: String) -> String { Self.canonicalMIME(key) }
}
