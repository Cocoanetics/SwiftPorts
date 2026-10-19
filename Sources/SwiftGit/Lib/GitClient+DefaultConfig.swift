import Foundation
import CGitKit
import GitKit
import ShellKit
import CLibgit2Shim

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

    /// The file `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` names for `scope`,
    /// which git takes as is: an empty value is a file called `''`.
    private static func configFileOverride(_ scope: ConfigScope) -> String? {
        let variable = scope == .global ? "GIT_CONFIG_GLOBAL" : "GIT_CONFIG_SYSTEM"
        return Shell.current.environment[variable]
    }

    /// Whether the scope's file is there. A file the environment names, and
    /// the system file, are judged by their path alone (an explicit
    /// `--system` also reads it when `GIT_CONFIG_NOSYSTEM` has emptied
    /// libgit2's search path); the global one is `~/.gitconfig` or the XDG
    /// file, as git looks.
    private func configFileExists(_ scope: ConfigScope) -> Bool {
        if Self.configFileOverride(scope) != nil || scope == .system {
            let path = Self.configFilePath(scope)
            return !path.isEmpty && FileManager.default.fileExists(atPath: location(of: path))
        }
        var path = git_buf()
        defer { git_buf_dispose(&path) }
        if git_config_find_global(&path) == 0 { return true }
        var xdg = git_buf()
        defer { git_buf_dispose(&xdg) }
        return git_config_find_xdg(&xdg) == 0
    }

    /// Where a config file named `path` is: a relative name is the shell's
    /// working directory's, as git has it; messages keep it as typed.
    func location(of path: String) -> String {
        path.isEmpty ? path : URL(fileURLWithPath: path, relativeTo: workingDirectory).path
    }

    /// The path git names for a scope's file.
    static func configFilePath(_ scope: ConfigScope) -> String {
        if let path = configFileOverride(scope) { return path }
        return scope == .global ? Libgit2Sandboxing.shared.globalHome + "/.gitconfig" : systemConfigPath()
    }

    /// Where the system config is: `GIT_CONFIG_SYSTEM`, else libgit2's
    /// search path for that level, or, when the level is disabled
    /// (`GIT_CONFIG_NOSYSTEM`, which an explicit `--system` ignores in git
    /// too), the usual place.
    public static func systemConfigPath() -> String {
        if let path = configFileOverride(.system) { return path }
        var buffer = [CChar](repeating: 0, count: 4096)
        let level = Int32(GIT_CONFIG_LEVEL_SYSTEM.rawValue)
        if swiftports_libgit2_get_search_path(level, &buffer, UInt(buffer.count)) == 0 {
            #if os(Windows)
            let separator: Character = ";"
            #else
            let separator: Character = ":"
            #endif
            if let directory = String(cString: buffer).split(separator: separator).first {
                return "\(directory)/gitconfig"
            }
        }
        #if os(Windows)
        return "C:/ProgramData/Git/config"
        #else
        return "/etc/gitconfig"
        #endif
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
            let path = Self.configFilePath(scope)
            let level = scope == .global ? GIT_CONFIG_LEVEL_GLOBAL : GIT_CONFIG_LEVEL_SYSTEM
            if self.configFileExists(scope) {
                if Self.configFileOverride(scope) == nil && scope == .global {
                    try Self.check(git_config_open_global(&file, base))
                } else {
                    try Self.check(git_config_new(&file))
                    try Self.check(git_config_add_file_ondisk(file, self.location(of: path), level, nil, 1))
                }
            } else {
                switch missing {
                case .fail:
                    throw Libgit2Error(
                        code: GIT_ENOTFOUND.rawValue, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                        message: "unable to read config file '\(path)': No such file or directory")
                case .empty:
                    try Self.check(git_config_new(&file))
                case .create:
                    // git can't write a file called `''` either.
                    guard !path.isEmpty else {
                        throw Libgit2Error(
                            code: GIT_EEXISTS.rawValue, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                            message: "could not write config file : Is a directory")
                    }
                    try Self.check(git_config_new(&file))
                    try Self.check(git_config_add_file_ondisk(file, self.location(of: path), level, nil, 1))
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

    /// What `git config --list` prints for `config`'s entries, lowest level
    /// first (libgit2 iterates the highest first) and each file top to
    /// bottom: `name=value`, or just `name` for a key without a value.
    /// With `level`, only that level's entries.
    static func configLines(in config: OpaquePointer?, level only: git_config_level_t? = nil) throws -> [String] {
        var iterator: UnsafeMutablePointer<git_config_iterator>?
        try check(git_config_iterator_new(&iterator, config))
        defer { git_config_iterator_free(iterator) }
        struct Listed { let level: Int32, offset: Int, line: String }
        var entries: [Listed] = []
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let result = git_config_next(&entry, iterator)
            if result == GIT_ITEROVER.rawValue { break }
            try check(result)
            guard let entry = entry?.pointee, let name = entry.name else { continue }
            if let only, entry.level != only { continue }
            let line = entry.value.map { "\(String(cString: name))=\(String(cString: $0))" } ?? String(cString: name)
            entries.append(Listed(level: Int32(entry.level.rawValue), offset: entries.count, line: line))
        }
        return entries.sorted { ($0.level, $0.offset) < ($1.level, $1.offset) }.map(\.line)
    }
}
