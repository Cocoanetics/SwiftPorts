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
        let prefix = cwd == root ? "" : String(cwd.dropFirst(root.count + 1)) + "/"
        let autocrlf = try await client.configGet("core.autocrlf") ?? ""
        let defaultEnding = ["true", "t", "1"].contains(autocrlf.lowercased()) ? "\r\n" : Self.osLineEnding
        let ending = known.first { $0.source == ".gitattributes" }?.lineEnding ?? defaultEnding
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
                let base = (file as NSString).lastPathComponent
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
        return indexed.compactMap { file in
            guard file.hasPrefix(prefix) else { return nil }
            let relative = String(file.dropFirst(prefix.count))
            if pattern.hasPrefix("/") && safe.contains("*") && relative.contains("/") { return nil }
            return git_pathspec_matches_path(spec, 0, relative) == 1 ? relative : nil
        }
    }

    private static var osLineEnding: String {
        #if os(Windows)
        "\r\n"
        #else
        "\n"
        #endif
    }
}
