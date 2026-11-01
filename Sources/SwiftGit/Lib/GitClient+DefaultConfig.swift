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
        /// As `empty`, for a change (an unset): git still has to lock the
        /// file, which fails where its directory isn't.
        case emptyForWrite
        /// git's "unable to read config file" error.
        case fail
    }

    /// The file `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` names for `scope`,
    /// which git takes as is: an empty value is a file called `''`.
    static func configFileOverride(_ scope: ConfigScope) -> String? {
        let variable = scope == .global ? "GIT_CONFIG_GLOBAL" : "GIT_CONFIG_SYSTEM"
        return Shell.current.environment[variable]
    }

    /// Whether the scope's file is there, judged by its path alone: the one
    /// the environment names, the system file (an explicit `--system` also
    /// reads it when `GIT_CONFIG_NOSYSTEM` has emptied libgit2's search
    /// path), or the one `--global` picks.
    private func configFileExists(_ scope: ConfigScope) -> Bool {
        let path = Self.configFilePath(scope)
        return !path.isEmpty && FileManager.default.fileExists(atPath: location(of: path))
    }

    /// git's lock failure for a config file it can't lock: its directory
    /// isn't there or isn't writable (the lock is a file next to it), or
    /// the lock is already held.
    func requireDirectory(of path: String) throws {
        guard !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: location(of: path)).deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
            && isDirectory.boolValue
        guard exists, FileManager.default.isWritableFile(atPath: directory) else {
            throw Libgit2Error(
                code: GIT_ENOTFOUND.rawValue, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                message: "could not lock config file \(path): "
                    + (exists ? "Permission denied" : "No such file or directory"))
        }
        // Another process holds the lock.
        if FileManager.default.fileExists(atPath: location(of: path) + ".lock") {
            throw Libgit2Error(
                code: GIT_EEXISTS.rawValue, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                message: "could not lock config file \(path): File exists")
        }
    }

    /// The file git reads and writes for `scope`, as it names it.
    public static func configFile(for scope: ConfigScope) -> String {
        configFilePath(scope)
    }

    /// Where a config file named `path` is: a relative name is the shell's
    /// working directory's, as git has it; messages keep it as typed.
    func location(of path: String) -> String {
        path.isEmpty ? path : URL(fileURLWithPath: path, relativeTo: workingDirectory).path
    }

    /// The path git names for a scope's file.
    static func configFilePath(_ scope: ConfigScope) -> String {
        if let path = configFileOverride(scope) { return path }
        return scope == .global ? globalConfigPath() : systemConfigPath()
    }

    /// The file `--global` works on, as git picks it: `~/.gitconfig` if it
    /// is there, else the XDG file if that is, else `~/.gitconfig` to start.
    /// Worked out from the shell's environment, as the sandbox bridge sets
    /// libgit2's search paths from it.
    static func globalConfigPath() -> String {
        let sandbox = Shell.current.sandbox
        let home = Libgit2Sandboxing.shared.home(for: sandbox) + "/.gitconfig"
        if FileManager.default.fileExists(atPath: home) { return home }
        let xdg = Libgit2Sandboxing.shared.xdgConfigHome(for: sandbox) + "/git/config"
        return FileManager.default.fileExists(atPath: xdg) ? xdg : home
    }

    /// Where the system config is: `GIT_CONFIG_SYSTEM`, else libgit2's
    /// search path for that level, or, when the level is disabled
    /// (`GIT_CONFIG_NOSYSTEM`, which an explicit `--system` ignores in git
    /// too), the usual place.
    public static func systemConfigPath() -> String {
        if let path = configFileOverride(.system) { return path }
        // The first directory of libgit2's search path that has the file.
        var found = git_buf()
        defer { git_buf_dispose(&found) }
        if git_config_find_system(&found) == 0, let path = found.ptr { return String(cString: path) }
        var buffer = [CChar](repeating: 0, count: 4096)
        let level = Int32(GIT_CONFIG_LEVEL_SYSTEM.rawValue)
        if swiftports_libgit2_get_search_path(level, &buffer, buffer.count) == 0 {
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
        if scope == .global, Self.configFileOverride(.global) == nil,
           Libgit2Sandboxing.shared.homeIsUnset(for: Shell.current.sandbox) {
            throw GitDiagnosticError(lines: ["fatal: $HOME not set"], exitCode: 128)
        }
        try await authorizeConfigFile(of: scope, writing: missing == .create || missing == .emptyForWrite)
        // A scope's own file is opened by itself: the default config
        // would parse the files it supersedes (a bad ~/.gitconfig
        // under GIT_CONFIG_GLOBAL) as well.
        return try await isolatedGated {
            guard let scope, scope != .local else {
                // Libgit2Sandboxing has switched off the levels the
                // environment replaces; its files and entries come in here.
                var base: OpaquePointer?
                try Self.check(git_config_open_default(&base))
                defer { git_config_free(base) }
                try Self.installEnvironmentConfig(into: base, repo: nil)
                return try body(base)
            }
            let file = try self.openScopedConfig(scope, missing: missing)
            defer { git_config_free(file) }
            return try body(file)
        }
    }

    /// A file the environment names is the user's pick, not libgit2's
    /// search, and the global file sits under the home libgit2 is pointed
    /// at, which may be outside the sandbox: both must be allowed.
    private func authorizeConfigFile(of scope: ConfigScope?, writing: Bool) async throws {
        guard scope != .local else { return }
        try await authorizeSelectedFile(of: scope, writing: writing)
        // An unscoped read also touches the XDG file; GIT_CONFIG_GLOBAL
        // stands in for both home files (authorised by `environmentConfig()`).
        guard Shell.current.sandbox != nil, scope == nil else { return }
        guard Self.configFileOverride(.global) == nil else { return }
        let xdg = Libgit2Sandboxing.shared.xdgConfigHome(for: Shell.current.sandbox) + "/git/config"
        try await Shell.authorize(URL(fileURLWithPath: xdg))
    }

    private func authorizeSelectedFile(of scope: ConfigScope?, writing: Bool) async throws {
        if scope == .system {
            // A sandbox reads the host's system file (the default one, or the
            // one GIT_CONFIG_SYSTEM names) only when the embedder allows it;
            // changing it is always the sandbox's business.
            let system = Self.configFilePath(.system)
            let reading = Shell.current.sandbox != nil && !GitSandboxPolicy.allowsHostSystemConfig
            if writing || reading, !system.isEmpty, writing || location(of: system) != "/dev/null" {
                try await Shell.authorize(URL(fileURLWithPath: location(of: system)))
            }
        } else if let scope, let named = Self.configFileOverride(scope), !named.isEmpty {
            // `/dev/null` reads as an empty config; nothing of the host's is in it.
            if writing || location(of: named) != "/dev/null" {
                try await Shell.authorize(URL(fileURLWithPath: location(of: named)))
            }
        } else if scope == nil, Self.configFileOverride(.global) != nil {
            // GIT_CONFIG_GLOBAL stands in for both home files; the file it
            // names is let in by `environmentConfig()`.
            return
        } else {
            let home = Libgit2Sandboxing.shared.home(for: Shell.current.sandbox)
            try await Shell.authorize(URL(fileURLWithPath: home).appendingPathComponent(".gitconfig"))
            try await Shell.authorize(URL(fileURLWithPath: Self.globalConfigPath()))
        }
    }

    /// The config of one scope's file, which the caller frees. An absent
    /// file is handled as `missing` says.
    private func openScopedConfig(_ scope: ConfigScope, missing: MissingConfigFile) throws -> OpaquePointer? {
        var file: OpaquePointer?
        let path = Self.configFilePath(scope)
        let level = scope == .global ? GIT_CONFIG_LEVEL_GLOBAL : GIT_CONFIG_LEVEL_SYSTEM
        if configFileExists(scope) {
            // A file that is there but can't be read: git's words.
            guard FileManager.default.isReadableFile(atPath: location(of: path)) else {
                throw Libgit2Error(
                    code: GIT_EUSER.rawValue, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                    message: "unable to access '\(path)': Permission denied")
            }
        } else {
            switch missing {
            case .fail:
                throw Libgit2Error(
                    code: GIT_ENOTFOUND.rawValue, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                    message: "unable to read config file '\(path)': No such file or directory")
            case .empty:
                try Self.check(git_config_new(&file))
                return file
            case .emptyForWrite:
                try requireDirectory(of: path)
                try Self.check(git_config_new(&file))
                return file
            case .create:
                try requireDirectory(of: path)
                // git can't write a file called `''` either.
                guard !path.isEmpty else {
                    throw Libgit2Error(
                        code: GIT_EEXISTS.rawValue, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                        message: "could not write config file : Is a directory")
                }
            }
        }
        try Self.check(git_config_new(&file))
        try Self.check(git_config_add_file_ondisk(file, location(of: path), level, nil, 1))
        return file
    }

    /// The value of `name`. With `withIncludes` off (an explicit scope), a
    /// value that came from an `[include]`d file is not there, as git has it.
    static func configString(_ name: String, in config: OpaquePointer?, withIncludes: Bool = true) throws -> String? {
        guard withIncludes else { return try ownConfigString(name, in: config) }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        let result = git_config_get_string_buf(&buffer, config, name)
        if result == GIT_ENOTFOUND.rawValue { return nil }
        try check(result)
        // A key without a value is found, with an empty one.
        return buffer.ptr.map { String(cString: $0) } ?? ""
    }

    /// The last value of `name` the file itself has, not an included one.
    private static func ownConfigString(_ name: String, in config: OpaquePointer?) throws -> String? {
        var iterator: UnsafeMutablePointer<git_config_iterator>?
        let started = git_config_multivar_iterator_new(&iterator, config, name, nil)
        if started == GIT_ENOTFOUND.rawValue { return nil }
        try check(started)
        defer { git_config_iterator_free(iterator) }
        var found: String?
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let result = git_config_next(&entry, iterator)
            if result == GIT_ITEROVER.rawValue { break }
            try check(result)
            guard let entry = entry?.pointee, entry.include_depth == 0 else { continue }
            found = entry.value.map { String(cString: $0) } ?? ""
        }
        return found
    }

    /// One entry of a listing: where it comes from (`--show-origin`'s text)
    /// and what it says.
    struct ListedConfigEntry {
        let level: Int32
        let offset: Int
        let origin: String
        let name: String
        /// `nil` for a key without a value.
        let value: String?

        /// `name=value`, or just `name` for a key without a value.
        var line: String { value.map { "\(name)=\($0)" } ?? name }
    }

    /// The entries `git config --list` prints for `config`, lowest level
    /// first (libgit2 iterates the highest first) and each file top to
    /// bottom. With `level`, only that level's entries; `base` is the work
    /// tree's top, which the repository's own files are shown relative to.
    func configEntries(
        in config: OpaquePointer?, level only: git_config_level_t? = nil, withIncludes: Bool = true,
        base: String? = nil
    ) throws -> [ListedConfigEntry] {
        var iterator: UnsafeMutablePointer<git_config_iterator>?
        try Self.check(git_config_iterator_new(&iterator, config))
        defer { git_config_iterator_free(iterator) }
        var entries: [ListedConfigEntry] = []
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let result = git_config_next(&entry, iterator)
            if result == GIT_ITEROVER.rawValue { break }
            try Self.check(result)
            guard let entry = entry?.pointee, let name = entry.name else { continue }
            if let only, entry.level != only { continue }
            if !withIncludes && entry.include_depth > 0 { continue }
            entries.append(ListedConfigEntry(
                level: Int32(entry.level.rawValue), offset: entries.count,
                origin: originName(of: entry, base: base),
                name: String(cString: name), value: entry.value.map { String(cString: $0) }))
        }
        return entries.sorted { ($0.level, $0.offset) < ($1.level, $1.offset) }
    }
}
