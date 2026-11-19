import Foundation
import ShellKit
import SwiftGit

/// Reads attribute sources in git-lfs's precedence order, expanding attribute macros.
struct Attributes {
    var macros: [String: [String]] = ["binary": ["-diff", "-merge", "-text"]]

    mutating func paths(_ repo: LFSRepository, client: SwiftGit.GitClient) async throws -> [AttributePath] {
        guard let root = repo.workingDirectory else { return [] }
        var external: [AttributePath] = []
        let system = Shell.env("GIT_ATTR_SYSTEM") ?? (Shell.env("PREFIX") ?? "") + "/etc/gitattributes"
        if Shell.env("GIT_ATTR_NOSYSTEM") != "1" {
            external += try await read(URL(fileURLWithPath: system), source: system, prefix: "", readMacros: true)
        }
        let global = try await client.configGet("core.attributesfile")
            ?? (Shell.env("XDG_CONFIG_HOME") ?? (Shell.env("HOME") ?? "") + "/.config") + "/git/attributes"
        let expanded = global.hasPrefix("~/") ? (Shell.env("HOME") ?? "") + global.dropFirst() : global
        let globalPaths = try await read(URL(fileURLWithPath: expanded, relativeTo: root),
                                         source: String(expanded), prefix: "", readMacros: true)
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
        return local + globalPaths + external
    }

    private mutating func read(
        _ url: URL, source: String, prefix: String, readMacros: Bool
    ) async throws -> [AttributePath] {
        try await Shell.authorize(url)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let ending = text.contains("\r\n") ? "\r\n" : "\n"
        var paths: [AttributePath] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let pattern: String
            let applied: String
            if line.hasPrefix("\""), let last = line.dropFirst().lastIndex(of: "\""),
               let decoded = try? JSONDecoder().decode(String.self, from: Data(line[...last].utf8)) {
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
        for value in values {
            let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if value.hasPrefix("-") || value.hasPrefix("!") {
                attributes[String(value.dropFirst())] = value.hasPrefix("-") ? "false" : ""
            } else if parts.count == 2 {
                attributes[parts[0]] = parts[1]
            } else {
                attributes[value] = "true"
                if let macro = macros[value], !seen.contains(value) {
                    expand(macro, into: &attributes, seen: seen.union([value]))
                }
            }
        }
    }

    private func relative(_ file: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.path + "/"
        let name = file.standardizedFileURL.path
        return name.hasPrefix(base) ? String(name.dropFirst(base.count)) : name
    }
}
