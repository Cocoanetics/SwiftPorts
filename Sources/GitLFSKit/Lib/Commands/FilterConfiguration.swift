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
            path = URL(fileURLWithPath: options.file, relativeTo: Shell.currentDirectory)
        } else {
            path = URL(fileURLWithPath: SwiftGit.GitClient.configFile(for: options.system ? .system : .global),
                       relativeTo: Shell.currentDirectory)
        }
        try await Shell.authorize(path)
        return FilterConfiguration(path: path.resolvingSymlinksInPath())
    }

    func value(_ key: String) throws -> String {
        if !FileManager.default.fileExists(atPath: path.path) { return "" }
        var config: OpaquePointer?
        try check(git_config_open_ondisk(&config, path.path))
        defer { git_config_free(config) }
        var buffer = git_buf()
        let code = git_config_get_string_buf(&buffer, config, key)
        if code == GIT_ENOTFOUND.rawValue { return "" }
        try check(code)
        defer { git_buf_dispose(&buffer) }
        return buffer.ptr.map { String(cString: $0) } ?? ""
    }

    func set(_ key: String, _ value: String) throws {
        var config: OpaquePointer?
        // open_ondisk allows a file which doesn't yet exist, as `git config` does.
        try check(git_config_open_ondisk(&config, path.path))
        defer { git_config_free(config) }
        try check(git_config_set_multivar(config, key, ".*", value))
    }

    /// `git config --remove-section filter.lfs`, retaining other sections verbatim.
    func uninstall() async throws -> Bool {
        let lock = URL(fileURLWithPath: path.path + ".lock")
        try await Shell.authorize(lock)
        try Data().write(to: lock, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: lock) }
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        let original = try String(contentsOf: path, encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #"(?im)^[ \t]*\[filter(?:[ \t]+"lfs"|\.lfs)\][^\n]*(?:\n(?![ \t]*\[)[^\n]*)*\n?"#)
        let range = NSRange(original.startIndex..., in: original)
        guard expression.firstMatch(in: original, range: range) != nil else { return false }
        let text = expression.stringByReplacingMatches(in: original, range: range, withTemplate: "")
        try text.write(to: lock, atomically: false, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        if let mode = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: lock.path)
        }
        try renameReplacing(lock.path, path.path)
        return true
    }

    private func check(_ code: Int32) throws {
        guard code < 0 else { return }
        let message = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "configuration error"
        throw LFSFailure(message)
    }
}
