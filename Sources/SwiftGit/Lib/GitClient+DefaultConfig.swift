import Foundation
import CGitKit
import GitKit
import ShellKit

// The config git reads outside any repository: the system and global files.
extension GitClient {

    /// What to do when the file of the `--global` or `--system` scope
    /// isn't there.
    enum MissingConfigFile {
        /// It reads as an empty config, so a get finds nothing and an
        /// unset removes nothing.
        case empty
        /// A write starts the file.
        case create
        /// git's "unable to read config file" error.
        case fail
    }

    /// Whether the scope's file is there: `~/.gitconfig` or the XDG one for
    /// global, as git looks, and the system file.
    static func configFileExists(_ scope: ConfigScope) -> Bool {
        var path = git_buf()
        defer { git_buf_dispose(&path) }
        if scope == .system { return git_config_find_system(&path) == 0 }
        if git_config_find_global(&path) == 0 { return true }
        var xdg = git_buf()
        defer { git_buf_dispose(&xdg) }
        return git_config_find_xdg(&xdg) == 0
    }

    /// The path git names for a scope's file.
    static func configFilePath(_ scope: ConfigScope) -> String {
        scope == .global ? Libgit2Sandboxing.shared.globalHome + "/.gitconfig" : "/etc/gitconfig"
    }

    /// Runs `body` on the config git reads outside any repository: the
    /// system and global files (or just `scope`'s), under the sandbox's
    /// view of home. `missing` says what a scope's absent file means.
    func withDefaultConfig<T>(
        scope: ConfigScope?, missing: MissingConfigFile = .fail, _ body: (OpaquePointer?) throws -> T
    ) async throws -> T {
        try await Shell.authorize(workingDirectory)
        return try Libgit2Sandboxing.shared.runIsolated(Shell.current.sandbox) {
            var base: OpaquePointer?
            try Self.check(git_config_open_default(&base))
            defer { git_config_free(base) }
            guard let scope, scope != .local else { return try body(base) }
            var file: OpaquePointer?
            defer { git_config_free(file) }
            let isGlobal = scope == .global
            if Self.configFileExists(scope) {
                try Self.check(isGlobal
                    ? git_config_open_global(&file, base)
                    : git_config_open_level(&file, base, GIT_CONFIG_LEVEL_SYSTEM))
            } else {
                let path = Self.configFilePath(scope)
                switch missing {
                case .fail:
                    throw Libgit2Error(
                        code: GIT_ENOTFOUND.rawValue, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                        message: "unable to read config file '\(path)': No such file or directory")
                case .empty:
                    try Self.check(git_config_new(&file))
                case .create:
                    try Self.check(git_config_new(&file))
                    try Self.check(git_config_add_file_ondisk(
                        file, path, isGlobal ? GIT_CONFIG_LEVEL_GLOBAL : GIT_CONFIG_LEVEL_SYSTEM, nil, 1))
                }
            }
            return try body(file)
        }
    }

    static func configString(_ name: String, in config: OpaquePointer?) throws -> String? {
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        let result = git_config_get_string_buf(&buffer, config, name)
        if result == GIT_ENOTFOUND.rawValue { return nil }
        try check(result)
        return buffer.ptr.map { String(cString: $0) }
    }

    static func configEntries(in config: OpaquePointer?) throws -> [(name: String, value: String)] {
        var iterator: UnsafeMutablePointer<git_config_iterator>?
        try check(git_config_iterator_new(&iterator, config))
        defer { git_config_iterator_free(iterator) }
        var entries: [(name: String, value: String)] = []
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let result = git_config_next(&entry, iterator)
            if result == GIT_ITEROVER.rawValue { break }
            try check(result)
            if let entry = entry?.pointee, let name = entry.name, let value = entry.value {
                entries.append((String(cString: name), String(cString: value)))
            }
        }
        return entries
    }
}
