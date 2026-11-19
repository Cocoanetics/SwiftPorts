import Foundation
import CGitKit
import ShellKit
import SwiftGit

/// The single config file selected by git-lfs's FilterOptions.
struct FilterConfiguration {
    let path: URL

    static func open(_ options: FilterOptions, client: SwiftGit.GitClient) async throws -> FilterConfiguration {
        let path: URL
        if options.local || options.worktree {
            let repo = try await LFSRepository.open(client)
            let worktreeConfig = try await client.configBool("extensions.worktreeconfig") == true
            if options.worktree && worktreeConfig {
                path = repo.gitDirectory.appendingPathComponent("config.worktree")
            } else {
                path = repo.commonDirectory.appendingPathComponent("config")
            }
        } else if !options.file.isEmpty {
            // Honour a path-mapped shell: `/workspace/settings.cfg` is not a host path.
            path = Shell.resolve(options.file)
        } else {
            path = URL(fileURLWithPath: SwiftGit.GitClient.configFile(for: options.system ? .system : .global),
                       relativeTo: Shell.currentDirectory)
        }
        try await Shell.authorize(path)
        return FilterConfiguration(path: path.resolvingSymlinksInPath())
    }

    func value(_ key: String) async throws -> String {
        if !FileManager.default.fileExists(atPath: path.path) { return "" }
        // libgit2 follows [include] while parsing. Authorise each file before it is opened.
        return try await withAuthorizedConfigIncludes {
            var config: OpaquePointer?
            try self.check(git_config_open_ondisk(&config, self.path.path))
            defer { git_config_free(config) }
            var buffer = git_buf()
            let code = git_config_get_string_buf(&buffer, config, key)
            defer { git_buf_dispose(&buffer) }
            if code == GIT_ENOTFOUND.rawValue { return "" }
            try self.check(code)
            return buffer.ptr.map { String(cString: $0) } ?? ""
        }
    }

    func set(_ key: String, _ value: String) async throws {
        try await withAuthorizedConfigIncludes {
            var config: OpaquePointer?
            // open_ondisk allows a file which doesn't yet exist, as `git config` does.
            try self.check(git_config_open_ondisk(&config, self.path.path))
            defer { git_config_free(config) }
            try self.check(git_config_set_multivar(config, key, ".*", value))
        }
    }

    /// `git config --remove-section filter.lfs`, retaining other sections verbatim.
    /// Section names are case-insensitive; a quoted or dotted subsection is not,
    /// so `[filter "LFS"]` is a different section and stays.
    func uninstall() async throws -> Bool {
        let lock = URL(fileURLWithPath: path.path + ".lock")
        try await Shell.authorize(lock)
        try Data().write(to: lock, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: lock) }
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        let original = try String(contentsOf: path, encoding: .utf8)
        guard let text = removingLFSFilter(original) else { return false }
        try text.write(to: lock, atomically: false, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        if let mode = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: lock.path)
        }
        try renameReplacing(lock.path, path.path)
        return true
    }

    private func removingLFSFilter(_ original: String) -> String? {
        var kept = ""
        var skipping = false
        var removed = false
        var index = original.startIndex
        while index < original.endIndex {
            let newline = original[index...].firstIndex(of: "\n") ?? original.endIndex
            let lineEnd = newline == original.endIndex ? newline : original.index(after: newline)
            let content = original[index..<newline]
            let bare = content.hasSuffix("\r") ? content.dropLast() : content
            if bare.first(where: { !$0.isWhitespace }) == "[" {
                skipping = Self.isFilterLFS(bare)
                if skipping { removed = true }
            }
            if !skipping { kept += original[index..<lineEnd] }
            index = lineEnd
        }
        return removed ? kept : nil
    }

    /// `[filter "lfs"]` and `[filter.lfs]`, with a case-insensitive section name.
    private static func isFilterLFS(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "[", let close = trimmed.firstIndex(of: "]") else { return false }
        let body = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            .trimmingCharacters(in: .whitespaces)
        let section: String
        let subsection: String?
        if let quote = body.firstIndex(of: "\"") {
            section = body[..<quote].trimmingCharacters(in: .whitespaces)
            let after = body[body.index(after: quote)...]
            if let end = after.firstIndex(of: "\"") { subsection = String(after[..<end]) }
            else { subsection = nil }
        } else if let dot = body.firstIndex(of: ".") {
            section = body[..<dot].trimmingCharacters(in: .whitespaces)
            subsection = body[body.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        } else {
            section = String(body)
            subsection = nil
        }
        return section.lowercased() == "filter" && subsection == "lfs"
    }

    private func check(_ code: Int32) throws {
        guard code < 0 else { return }
        let message = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "configuration error"
        throw LFSFailure(message)
    }
}
