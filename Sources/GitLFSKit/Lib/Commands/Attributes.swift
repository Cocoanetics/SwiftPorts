import Foundation
import ShellKit
import SwiftGit

/// Reads attribute sources in git-lfs's precedence order, expanding attribute macros.
struct Attributes {
    var macros: [String: [String]] = ["binary": ["-diff", "-merge", "-text"]]

    mutating func paths(
        _ repo: LFSRepository, client: SwiftGit.GitClient, includeExternal: Bool = true
    ) async throws -> [AttributePath] {
        guard let root = repo.workingDirectory else { return [] }
        var external: [AttributePath] = []
        // System and global files are optional. A rooted sandbox denies `/etc/gitattributes`
        // even when it is absent; that must not fail `git lfs track`.
        if Shell.env("GIT_ATTR_NOSYSTEM") != "1" {
            let system = Shell.env("GIT_ATTR_SYSTEM") ?? (Shell.env("PREFIX") ?? "") + "/etc/gitattributes"
            external += try await readOptional(
                URL(fileURLWithPath: system), source: system, prefix: "", readMacros: true)
        }
        let global = try await globalAttributesPath(client)
        let globalPaths = try await readOptional(
            URL(fileURLWithPath: global, relativeTo: root), source: global, prefix: "", readMacros: true)
        let indexed = try await client.indexedPaths()
        var files = Set(indexed.filter { ($0 as NSString).lastPathComponent == ".gitattributes" })
        for entry in try await client.status().entries
        where (entry.path as NSString).lastPathComponent == ".gitattributes" {
            files.insert(entry.path)
        }
        let info = repo.gitDirectory.appendingPathComponent("info/attributes")
        let infoSource = relative(info, to: root)
        var sources = files.map { (url: root.appendingPathComponent($0), source: $0) }
        if FileManager.default.fileExists(atPath: info.path) { sources.append((info, infoSource)) }
        // Upstream reads the more specific sources first. In particular, a macro
        // defined in the root file hasn't yet been seen while reading nested files.
        sources.sort {
            $0.source.utf8.count == $1.source.utf8.count
                ? $0.source < $1.source : $0.source.utf8.count > $1.source.utf8.count
        }
        var local: [AttributePath] = []
        for file in sources {
            let directory = (file.source as NSString).deletingLastPathComponent
            local += try await read(file.url, source: file.source, prefix: directory,
                                    readMacros: file.source == ".gitattributes" || file.source == infoSource)
        }
        return includeExternal ? local + globalPaths + external : local
    }

    /// `$XDG_CONFIG_HOME/git/attributes`, else `$HOME/.config/git/attributes`.
    /// An absent HOME uses the shell's home, which is the sandbox home when one is set,
    /// rather than the host's `/.config/git/attributes`.
    private func globalAttributesPath(_ client: SwiftGit.GitClient) async throws -> String {
        if let configured = try await client.configGet("core.attributesfile") {
            return expandHome(configured)
        }
        if let xdg = Shell.env("XDG_CONFIG_HOME"), !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("git/attributes")
        }
        if let home = Shell.env("HOME"), !home.isEmpty {
            return home + "/.config/git/attributes"
        }
        return Shell.homeDirectory.appendingPathComponent(".config/git/attributes").path
    }

    private func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        let home = Shell.env("HOME").flatMap { $0.isEmpty ? nil : $0 } ?? Shell.homeDirectory.path
        return home + path.dropFirst()
    }

    private mutating func readOptional(
        _ url: URL, source: String, prefix: String, readMacros: Bool
    ) async throws -> [AttributePath] {
        do { return try await read(url, source: source, prefix: prefix, readMacros: readMacros) }
        catch is Sandbox.Denial { return [] }
    }

    private mutating func read(
        _ url: URL, source: String, prefix: String, readMacros: Bool
    ) async throws -> [AttributePath] {
        try await Shell.authorize(url)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let ending = TrackOptions.attributeLineEnding(text)
        var paths: [AttributePath] = []
        for raw in TrackOptions.lines(text) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let pattern: String
            let applied: String
            if line.hasPrefix("\"") {
                guard let last = line.dropFirst().lastIndex(of: "\""), last > line.startIndex else { return [] }
                let quoted = String(line[...last])
                guard let decoded = try? GoQuotedLiteral.unquote(quoted) else { return [] }
                pattern = decoded
                applied = String(line[line.index(after: last)...])
            } else {
                let fields = line.split(separator: " ", maxSplits: 1)
                pattern = String(fields[0])
                applied = fields.count > 1 ? String(fields[1]) : ""
            }
            let values = applied.split(separator: " ").map(String.init)
            if pattern.hasPrefix("[attr]") {
                if readMacros { macros[String(pattern.dropFirst(6))] = values }
                continue
            }
            var attributes: [String: String] = [:]
            expand(values, into: &attributes, seen: [])
            let lockable = attributes["lockable"] == "true"
            guard attributes["filter"] != nil || lockable else { continue }
            let joined = prefix.isEmpty ? pattern : (prefix as NSString).appendingPathComponent(pattern)
            paths.append(AttributePath(pattern: joined, source: source, lineEnding: ending,
                                       lockable: lockable, tracked: attributes["filter"] == "lfs"))
        }
        return paths
    }

    private func expand(_ values: [String], into attributes: inout [String: String], seen: Set<String>) {
        for value in values where !value.isEmpty {
            if value.hasPrefix("!") {
                // `!macro` marks every attribute in the macro unspecified and keeps the alias.
                // A plain `!filter` only unsets that key. `-name` stays false and is not expanded.
                let name = String(value.dropFirst())
                if let macro = macros[name] {
                    for token in macro { attributes[Self.key(token)] = "" }
                }
                attributes[name] = ""
            } else if value.hasPrefix("-") {
                attributes[String(value.dropFirst())] = "false"
            } else {
                let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    .map(String.init)
                if parts.count == 2 {
                    attributes[parts[0]] = parts[1]
                } else {
                    attributes[value] = "true"
                    if let macro = macros[value], !seen.contains(value) {
                        expand(macro, into: &attributes, seen: seen.union([value]))
                    }
                }
            }
        }
    }

    private static func key(_ token: String) -> String {
        if token.hasPrefix("-") || token.hasPrefix("!") { return String(token.dropFirst()) }
        if let eq = token.firstIndex(of: "=") { return String(token[..<eq]) }
        return token
    }

    private func relative(_ file: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.path + "/"
        let name = file.standardizedFileURL.path
        return name.hasPrefix(base) ? String(name.dropFirst(base.count)) : name
    }
}
