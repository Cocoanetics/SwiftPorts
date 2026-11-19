import Foundation
import CGitKit
import ShellKit
import SwiftGit

extension TrackOptions {
    func edit(
        _ patterns: [String], known: [AttributePath], repo: LFSRepository, client: SwiftGit.GitClient
    ) async throws -> LFSCommandResult {
        var result = LFSCommandResult()
        let path = Shell.currentDirectory.appendingPathComponent(".gitattributes")
        try await Shell.authorize(path)
        let root = repo.workingDirectory?.standardizedFileURL.path ?? ""
        let cwd = Shell.currentDirectory.standardizedFileURL.path
        // libgit2's workdir and Shell's cwd spell the same directory differently
        // on Windows (`C:/repo/`, `C:\repo`, `/C:/repo`). A raw string compare
        // then treats the root as a subdirectory and drops every indexed file.
        let prefix = Self.repositoryPrefix(cwd: cwd, root: root)
        let autocrlf = try await client.configGet("core.autocrlf") ?? ""
        let defaultEnding = ["true", "t", "1"].contains(autocrlf.lowercased()) ? "\r\n" : Self.osLineEnding
        // An empty recorded ending means the file had no newline; fall back to autocrlf.
        let recorded = known.first { $0.source == ".gitattributes" }?.lineEnding ?? defaultEnding
        let ending = recorded.isEmpty ? defaultEnding : recorded
        let modify = !noModifyAttrs && !dryRun
        var changed: [String: String] = [:]
        var order: [String] = []
        for argument in patterns {
            var pattern = Self.trimCurrent(argument)
            let encoded = Self.escape(pattern, literal: filename)
            if filename { pattern = encoded }
            if modify && known.contains(where: {
                Self.unescape($0.pattern) == prefix + pattern
                    && ((lockable && $0.lockable) || (notLockable && !$0.lockable) || (!lockable && !notLockable))
            }) {
                result.stdout += "\(pattern.goQuoted) already supported\n"
                continue
            }
            if changed[pattern] == nil { order.append(pattern) }
            changed[pattern] = "\(encoded) filter=lfs diff=lfs merge=lfs -text\(lockable ? " lockable" : "")\(ending)"
            result.stdout += "Tracking \(Self.unescape(encoded).goQuoted)\n"
        }
        var output = ""
        if modify {
            let original: String
            do {
                original = FileManager.default.fileExists(atPath: path.path)
                    ? try String(contentsOf: path, encoding: .utf8) : ""
            } catch {
                result.stdout += "Error reading '.gitattributes' file\n"
                return result
            }
            for line in Self.lines(original) {
                guard let field = line.split(whereSeparator: { $0.isWhitespace }).first else { continue }
                let pattern = Self.unescape(String(field))
                if let replacement = changed.removeValue(forKey: pattern) { output += replacement }
                else { output += line + ending }
            }
        }
        let indexed = try await client.indexedPaths()
        var modified = false
        for pattern in order where changed[pattern] != nil {
            if verbose { result.stdout += "Searching for files matching pattern: \(pattern)\n" }
            let files = try matchingFiles(pattern, indexed: indexed, prefix: prefix)
            if verbose {
                result.stdout += "Found \(files.count) files previously added to Git matching pattern: \(pattern)\n"
            }
            var forbidden = false
            for file in files {
                let base = Self.pathBasename(file)
                if base.hasPrefix(".git") || base.hasPrefix(".lfs") {
                    forbidden = true
                    result.stdout += "Pattern '\(pattern)' matches forbidden file '\(file)'. "
                        + "If you would like to track \(file), modify '.gitattributes' manually.\n"
                }
            }
            if forbidden { continue }
            if modify { output += changed[pattern] ?? "" }
            modified = true
            for file in files {
                if verbose || dryRun { result.stdout += "Touching \(file.goQuoted)\n" }
                if !dryRun {
                    let url = Shell.currentDirectory.appendingPathComponent(file)
                    try await Shell.authorize(url)
                    do { try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
                    catch {
                        result.fail("Error marking \(file.goQuoted) modified: \(error.localizedDescription)")
                    }
                }
            }
        }
        if modify {
            do { try output.write(to: path, atomically: false, encoding: .utf8) }
            catch { result.stdout += "Error opening '.gitattributes' file\n" }
        }
        if result.status == 0 && !modified && !changed.isEmpty { result.status = 1 }
        return result
    }

    private func matchingFiles(_ pattern: String, indexed: [String], prefix: String) throws -> [String] {
        var spec: OpaquePointer?
        let safe = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        let code = safe.withCString { value in
            var pointer: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: value)
            return withUnsafeMutablePointer(to: &pointer) { array in
                var strings = git_strarray(strings: array, count: 1)
                return git_pathspec_new(&spec, &strings)
            }
        }
        guard code == 0 else { return [] }
        defer { git_pathspec_free(spec) }
        // `git ls-files -x` matches a slash-free pattern against the basename,
        // so `model.bin` touches `assets/model.bin`. Pathspec compares the whole path.
        let rootWildcard = pattern.hasPrefix("/") && safe.contains("*")
        return indexed.compactMap { file in
            guard file.hasPrefix(prefix) else { return nil }
            let relative = String(file.dropFirst(prefix.count))
            if rootWildcard && relative.contains("/") { return nil }
            // `git ls-files -x` matches a slash-free pattern against the basename.
            // NSString.lastPathComponent splits on `\` on Windows and leaves
            // `assets/model.bin` whole, so the pathspec never matches.
            let candidate = safe.contains("/") || safe.contains("\\") ? relative : Self.pathBasename(relative)
            return git_pathspec_matches_path(spec, 0, candidate) == 1 ? relative : nil
        }
    }

    /// Path from the worktree root to the shell directory, with a trailing
    /// slash, or empty at the root. Git spells that directory with `/` and no
    /// trailing slash. On Windows `C:\repo`, `C:/repo/` and `/C:/repo` are the
    /// same folder; comparing the raw strings makes the root look nested.
    static func repositoryPrefix(cwd: String, root: String) -> String {
        let current = gitFilesystemPath(cwd)
        let base = gitFilesystemPath(root)
        if directoriesEqual(current, base) { return "" }
        let rooted = base.hasSuffix("/") ? base : base + "/"
        guard directoryHasPrefix(current, rooted) else { return "" }
        let relative = String(current.dropFirst(rooted.count))
        return relative.isEmpty ? "" : relative + "/"
    }

    /// Last component of a Git or Windows path. Index paths use `/`, which
    /// `NSString.lastPathComponent` does not split on Windows.
    static func pathBasename(_ path: String) -> String {
        guard let slash = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return path }
        return String(path[path.index(after: slash)...])
    }

    private static func gitFilesystemPath(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "\\", with: "/")
        // `/C:/repo` is the other spelling of `C:/repo`.
        if value.count >= 4, value.first == "/" {
            let drive = value.index(value.startIndex, offsetBy: 2)
            if value[drive] == ":" { value.removeFirst() }
        }
        while value.hasSuffix("/"), value.count > 1 {
            let trimmed = String(value.dropLast())
            if trimmed.count == 2, trimmed.last == ":" { break }
            value = trimmed
        }
        return value
    }

    private static func directoriesEqual(_ lhs: String, _ rhs: String) -> Bool {
        #if os(Windows)
        lhs.lowercased() == rhs.lowercased()
        #else
        lhs == rhs
        #endif
    }

    private static func directoryHasPrefix(_ path: String, _ prefix: String) -> Bool {
        #if os(Windows)
        path.lowercased().hasPrefix(prefix.lowercased())
        #else
        path.hasPrefix(prefix)
        #endif
    }

    private static var osLineEnding: String {
        #if os(Windows)
        "\r\n"
        #else
        "\n"
        #endif
    }
}
