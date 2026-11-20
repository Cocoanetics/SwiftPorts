import Foundation
import ShellKit
import SwiftGit

/// git-lfs's merged config (`config.Configuration` / `readGitConfig`):
/// `.lfsconfig` first, then `git config --list`, so a git-config value
/// wins. Only the keys git-lfs allows are taken from `.lfsconfig`.
struct LFSConfiguration: Sendable {
    private var values: [String: [String]] = [:]
    /// First-seen order, which is the order aliases are applied in.
    private var sequence: [(key: String, value: String)] = []
    /// Remote names in the order their `remote.<name>.*` keys were first seen.
    private(set) var remotes: [String] = []

    func get(_ key: String) -> String? { values[Self.fold(key)]?.last }

    func getAll(_ key: String) -> [String] { values[Self.fold(key)] ?? [] }

    /// Every entry in read order (`.lfsconfig`, then git config, lowest level first).
    var entries: [(key: String, value: String)] { sequence }

    /// git-lfs `config.Bool`: an empty string keeps `fallback`; `true`/`1`/`on`/`yes`/`t`
    /// are true; anything else, including `false`, is false.
    static func bool(_ value: String?, fallback: Bool) -> Bool {
        guard let value, !value.isEmpty else { return fallback }
        switch value.lowercased() {
        case "true", "1", "on", "yes", "t": return true
        default: return false
        }
    }

    /// `GitFetcher.caseFoldKey`: lowercase the first and last dot-separated
    /// parts and keep the middle, so a URL or remote name stays as written.
    static func fold(_ key: String) -> String {
        let parts = splitDots(key)
        guard parts.count >= 3 else { return key.lowercased() }
        let middle = parts[1..<parts.count - 1].joined(separator: ".")
        return parts[0].lowercased() + "." + middle + "." + parts[parts.count - 1].lowercased()
    }

    static func splitDots(_ key: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in key {
            if character == "." {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// `NewIn`: a `.lfsconfig` git can't read prints
    /// `Error reading `git config`: …` and, as `Sources` does, drops both
    /// sources. A missing file is not an error.
    static func load(_ client: GitClient, showWarnings: Bool = false) async -> LFSConfiguration {
        do {
            return try await reading(client, showWarnings: showWarnings)
        } catch {
            LFSStandardError.write("Error reading `git config`: \(error)\n")
            return LFSConfiguration()
        }
    }

    private static func reading(_ client: GitClient, showWarnings: Bool) async throws -> LFSConfiguration {
        var configuration = LFSConfiguration()
        var ignored: [String] = []
        if let data = try await lfsconfig(client) {
            let parsed = try LFSConfigFile.parse(data).map { "\($0.key)=\($0.value)" }
            ignored = configuration.ingest(parseLines(parsed), onlySafe: true, showWarnings: showWarnings)
        }
        let lines = try await client.configLines()
        let git = parseLines(lines)
        _ = configuration.ingest(git, onlySafe: false, showWarnings: showWarnings)
        if !ignored.isEmpty {
            var warning = "warning: These unsafe '.lfsconfig' keys were ignored:\n\n"
            for key in ignored { warning += "  \(key)\n" }
            LFSStandardError.write(warning)
        }
        return configuration
    }

    /// git-lfs scans `git config --list` by newline, ignoring rows without
    /// an equals sign. Embedded newlines therefore truncate a value.
    private static func parseLines(_ lines: [String]) -> [(key: String, value: String)] {
        lines.flatMap { $0.components(separatedBy: "\n") }.compactMap { line in
            guard let equals = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<equals]), String(line[line.index(after: equals)...]))
        }
    }

    /// `.lfsconfig` at the work tree root, else the index, else `HEAD`
    /// (`Configuration.Sources`). A bare repository reads `HEAD` only.
    private static func lfsconfig(_ client: GitClient) async throws -> Data? {
        let bare = (try? await client.isInsideWorkTree()) != true
        if !bare {
            if let data = try await worktreeFile(client) { return data }
            if let indexed = await indexedBlob(client) { return indexed }
        }
        return try? await client.catFileBlob("HEAD:.lfsconfig")
    }

    private static func worktreeFile(_ client: GitClient) async throws -> Data? {
        guard let top = try await client.toplevel() else { return nil }
        let root = top.hasSuffix("/") ? String(top.dropLast()) : top
        let path = root + "/.lfsconfig"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        try await Shell.authorize(URL(fileURLWithPath: path))
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ReadError("open .lfsconfig: permission denied")
        }
        return data
    }

    /// `:.lfsconfig`, or the index entry's blob when that revspec won't resolve.
    private static func indexedBlob(_ client: GitClient) async -> Data? {
        if let data = try? await client.catFileBlob(":.lfsconfig") { return data }
        guard let entries = try? await client.indexedEntries(),
              let entry = entries.first(where: { $0.path == ".lfsconfig" && $0.stage == 0 })
        else { return nil }
        return try? await client.catFileBlob(entry.oid)
    }

    private mutating func ingest(
        _ rows: [(key: String, value: String)], onlySafe: Bool, showWarnings: Bool
    ) -> [String] {
        var ignored: [String] = []
        var seen: Set<String> = []
        for row in rows {
            let key = Self.fold(row.key)
            if showWarnings, !seen.insert(key).inserted, key.hasPrefix("lfs."),
               let previous = get(key), previous != row.value {
                let values = getAll(key).map(\.goQuoted).joined(separator: " ")
                LFSStandardError.write("warning: These `git config` values clash:\n"
                    + "  git config \(key.goQuoted) = [\(values)]\n"
                    + "  git config \(key.goQuoted) = \(row.value.goQuoted)\n")
            }
            if onlySafe && !Self.allowed(key) {
                ignored.append(key)
                continue
            }
            sequence.append((key, row.value))
            values[key, default: []].append(row.value)
            noteRemote(key)
        }
        return ignored
    }

    /// `readGitConfig`'s allowlist (`git_fetcher.go`).
    static func allowed(_ key: String) -> Bool {
        let parts = splitDots(key)
        if parts.count == 4 && parts[0] == "lfs" && parts[1] == "extension" {
            // `clean` and `smudge` are refused; `priority` is kept.
            return parts[3] == "priority"
        }
        if parts.count > 1 && parts[0] == "remote" {
            return parts.count >= 3 && parts.last == "lfsurl"
        }
        if parts.count > 2 && parts[0] == "lfs" && parts.last == "access" { return true }
        return safeKeys.contains(key)
    }

    private mutating func noteRemote(_ key: String) {
        let parts = Self.splitDots(key)
        guard parts.count >= 3, parts[0] == "remote" else { return }
        let name = parts[1..<parts.count - 1].joined(separator: ".")
        guard !name.isEmpty, !remotes.contains(name) else { return }
        remotes.append(name)
    }

    /// `safeKeys` in `config/git_fetcher.go`.
    private static let safeKeys: Set<String> = [
        "lfs.allowincompletepush",
        "lfs.fetchexclude",
        "lfs.fetchinclude",
        "lfs.gitprotocol",
        "lfs.locksverify",
        "lfs.pushurl",
        "lfs.skipdownloaderrors",
        "lfs.url"
    ]

    private struct ReadError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
