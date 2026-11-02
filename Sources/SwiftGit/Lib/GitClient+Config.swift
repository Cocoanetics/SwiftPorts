import Foundation
import CGitKit
import GitKit
import ShellKit

// Sandbox-aware delegation onto the pure `Repository` config operations
// (`GitKit/Repository+Config.swift`). Each call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off.
extension GitClient {

    /// Read a config value (`git config --get <name>`). Returns nil
    /// when the key isn't set. Outside a repository, reads the global
    /// and system config, as git does.
    public func configGet(_ name: String, scope: ConfigScope? = nil) async throws -> String? {
        if scope == .global || scope == .system {
            return try await withDefaultConfig(scope: scope, missing: .empty) {
                try Self.configString(name, in: $0, withIncludes: false)
            }
        }
        do {
            return try await withRepository { try $0.configGet(name, scope: scope) }
        } catch let error as Libgit2Error where scope == nil && Self.isNoRepository(error) {
            return try await withDefaultConfig(scope: nil, missing: .empty) {
                try Self.configString(name, in: $0)
            }
        }
    }

    /// Set a config value, matching `git config <name> <value>`.
    /// `--global` works anywhere, and creates `~/.gitconfig` if there is none.
    public func configSet(_ name: String, _ value: String, scope: ConfigScope = .local) async throws {
        if scope == .global || scope == .system {
            try await withDefaultConfig(scope: scope, missing: .create) { config in
                try self.requireDirectory(of: Self.configFilePath(scope))
                try Self.check(git_config_set_string(config, name, value))
            }
            return
        }
        try await withRepository { repository in
            // git's lock failure comes in git's words, for the repository's own file too.
            let file = try Self.localConfigFile(of: repository)
            try self.requireDirectory(of: file.path, named: file.name)
            try repository.configSet(name, value, scope: scope)
        }
    }

    /// `git config --unset <name> [<value-pattern>]`: removes the one entry
    /// of `name`, or the one whose value `pattern` admits
    /// (``ConfigValuePattern``). Returns true if removed, false if there
    /// was nothing to remove. Several entries to remove are git's
    /// `warning: <name> has multiple values` (status 5), a pattern it can't
    /// compile its `error: invalid pattern: …` (6), a key it can't parse
    /// its `error: key does not contain a section: …` (2) or
    /// `error: invalid key: …` (1). The file is rewritten as git rewrites
    /// it: the entry's line goes, and a section it leaves empty goes too.
    @discardableResult
    public func configUnset(
        _ name: String, matching pattern: String? = nil, scope: ConfigScope = .local
    ) async throws -> Bool {
        let key: String
        do { key = try Self.normalizedKey(name) } catch let error as CommandLineConfigError {
            // git_config_parse_key: a missing section or variable name is
            // CONFIG_NO_SECTION_OR_NAME, anything else CONFIG_INVALID_KEY.
            let status: Int32 = error.reason.hasPrefix("key does not contain") ? 2 : 1
            throw GitDiagnosticError(lines: ["error: \(error.reason)"], exitCode: status)
        }
        if scope == .global || scope == .system {
            let path = Self.configFilePath(scope)
            return try await withDefaultConfig(scope: scope, missing: .emptyForWrite) { _ in
                // git locks the file first, whether or not the key is there.
                try self.requireDirectory(of: path)
                return try self.unset(key, matching: pattern, in: self.location(of: path), named: path)
            }
        }
        return try await withRepository { repository in
            let file = try Self.localConfigFile(of: repository)
            try self.requireDirectory(of: file.path, named: file.name)
            return try self.unset(key, matching: pattern, in: file.path, named: file.name)
        }
    }

    /// The unset itself, on the file at `path` (named `named` to the user)
    /// once it is locked, in git's order: a file that isn't there has
    /// nothing to unset, then the pattern is compiled, then the file is
    /// read, and the matching entry cut out and the file put back.
    private func unset(_ key: String, matching pattern: String?, in path: String, named: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let matcher = try pattern.map { try ConfigValuePattern($0) }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw GitDiagnosticError(lines: ["error: opening \(named): Permission denied"], exitCode: 3)
        }
        let file = GitConfigFile.parse(data)
        if let line = file.badLine {
            throw GitDiagnosticError(lines: ["fatal: bad config line \(line) in file \(named)"], exitCode: 128)
        }
        let name = Array(key.utf8)
        let matched = file.entries.indices.filter {
            file.entries[$0].key == name && (matcher?.admitsForUnset(file.entries[$0].value) ?? true)
        }
        guard !matched.isEmpty else { return false }
        guard matched.count == 1 else {
            throw GitDiagnosticError(lines: ["warning: \(key) has multiple values"], exitCode: 5)
        }
        try Self.commit(file.removing(entriesAt: matched), to: path, named: named)
        return true
    }

    /// The repository's own config file (`<gitdir>/config`): where it is,
    /// and how git names it, relative to the top of the work tree wherever
    /// the command runs from (`.git/config`).
    static func localConfigFile(of repository: Repository) throws -> (path: String, name: String) {
        guard let repo = handle(of: repository) else {
            throw Libgit2Error(
                code: -1, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                message: "cannot reach GitKit's repository handle to find its config file")
        }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try check(git_repository_item_path(&buffer, repo, GIT_REPOSITORY_ITEM_CONFIG))
        let path = buffer.ptr.map { String(cString: $0) } ?? ""
        let base = (git_repository_workdir(repo) ?? git_repository_path(repo)).map { String(cString: $0) }
        if let base, path.hasPrefix(base) { return (path, String(path.dropFirst(base.count))) }
        return (path, path)
    }

    /// Puts `bytes` in the file at `path` the way git commits its lock
    /// file: written to `<path>.lock` with the file's own mode, then
    /// renamed over it.
    private static func commit(_ bytes: [UInt8], to path: String, named: String) throws {
        let lock = path + ".lock"
        var attributes: [FileAttributeKey: Any] = [:]
        #if !os(Windows)
        if let mode = try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] {
            attributes[.posixPermissions] = mode
        }
        #endif
        guard FileManager.default.createFile(atPath: lock, contents: Data(bytes), attributes: attributes) else {
            throw GitDiagnosticError(
                lines: ["error: could not lock config file \(named): Permission denied"], exitCode: 255)
        }
        #if os(Windows)
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: lock, toPath: path)
        #else
        guard rename(lock, path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: lock)
            throw GitDiagnosticError(lines: ["error: could not write config file \(named): \(reason)"], exitCode: 4)
        }
        #endif
    }

    /// Walk every config entry visible to the repo — matches `git config --list`.
    public func configList() async throws -> [(name: String, value: String)] {
        try await withRepository { try $0.configList() }
    }

    /// The lines `git config --list` prints, in its order: lowest level
    /// first, a key without a value as just its name. With `--global` or
    /// `--system` that file only (which must exist), with `--local` the
    /// repository's own; with no scope, every level, and outside a
    /// repository the global and system config. `showOrigin` puts where
    /// each came from before it (`file:<path>` or `command line:`, a tab).
    public func configLines(scope: ConfigScope? = nil, showOrigin: Bool = false) async throws -> [String] {
        try await configEntries(scope: scope).map { showOrigin ? "\($0.origin)\t\($0.line)" : $0.line }
    }

    /// `git config --get <name> [<value-pattern>]`, with `--show-origin`'s
    /// origin: the last value of `name` git reads (the one it shows), or
    /// the last one `pattern` admits (``ConfigValuePattern``), and where
    /// it comes from; `nil` when there is none. A key git can't parse is
    /// its `error: key does not contain a section: …` (status 1), a
    /// pattern it can't compile its `error: invalid pattern: …` (6),
    /// checked in that order before any config is read.
    public func configGetShowingOrigin(
        _ name: String, matching pattern: String? = nil, scope: ConfigScope? = nil
    ) async throws -> (origin: String, value: String)? {
        let key: String
        do { key = try Self.normalizedKey(name) } catch let error as CommandLineConfigError {
            // Config's own key check, which exits 1 where the environment's is fatal.
            throw GitDiagnosticError(lines: ["error: \(error.reason)"], exitCode: 1)
        }
        let matcher = try pattern.map { try ConfigValuePattern($0) }
        // A scope's file that isn't there has nothing, as for any get.
        guard let entry = try await configEntries(scope: scope, missing: .empty).last(where: {
            $0.name == key && (matcher?.admitsForGet($0.value) ?? true)
        }) else { return nil }
        return (entry.origin, entry.value ?? "")
    }

    func configEntries(scope: ConfigScope?, missing: MissingConfigFile = .fail) async throws -> [ListedConfigEntry] {
        if scope == .global || scope == .system {
            return try await withDefaultConfig(scope: scope, missing: missing) {
                try configEntries(in: $0, withIncludes: false)
            }
        }
        try await Shell.authorize(workingDirectory)
        let inRepository: [ListedConfigEntry]? = try await isolatedGated {
            var repo: OpaquePointer?
            var config: OpaquePointer?
            defer {
                git_config_free(config)
                git_repository_free(repo)
            }
            let opened = git_repository_open_ext(&repo, workingDirectory.path, 0, nil)
            if opened == GIT_ENOTFOUND.rawValue { return nil }
            try Self.check(opened)
            try Self.installEnvironmentConfig(intoRepository: repo)
            try Self.check(git_repository_config_snapshot(&config, repo))
            let base = (git_repository_workdir(repo) ?? git_repository_path(repo)).map { String(cString: $0) }
            try checkConfigSyntax(readBy: config, base: base)
            return try configEntries(
                in: config, level: scope == .local ? GIT_CONFIG_LEVEL_LOCAL : nil, base: base)
        }
        if let inRepository { return inRepository }
        if scope == .local {
            throw Libgit2Error(
                code: GIT_ENOTFOUND.rawValue, klass: Int32(GIT_ERROR_REPOSITORY.rawValue),
                message: "could not find repository at '\(workingDirectory.path)'")
        }
        return try await withDefaultConfig(scope: nil, missing: .empty) { try configEntries(in: $0) }
    }

    /// Whether `error` is libgit2 not finding a repository to open.
    public static func isNoRepository(_ error: Libgit2Error) -> Bool {
        error.code == GIT_ENOTFOUND.rawValue && error.klass == Int32(GIT_ERROR_REPOSITORY.rawValue)
    }

    /// Every value of a multi-valued key (`git config --get-all <name>`),
    /// in the order git reads them: system, global, then the
    /// repository's own config, each file top to bottom. A key without
    /// a value (`[remote "origin"] push`) gives an empty one.
    public func configGetAll(_ name: String) async throws -> [String] {
        try await withRepository { _ in try Self.configValues(name, in: workingDirectory) }
    }

    /// Every remote's `remote.<name>.push` values, in the order git reads
    /// them: lowest config level first, each file top to bottom.
    public func allRemotePushRefspecs() async throws -> [String] {
        try await withRepository { _ in
            try Self.configValues(matching: "^remote\\..*\\.push$", in: workingDirectory)
        }
    }

    /// `name`'s values, lowest config level first. libgit2 iterates its
    /// levels highest first, git reads them the other way round.
    static func configValues(_ name: String, in directory: URL) throws -> [String] {
        try configValues(in: directory) { config, iterator in
            git_config_multivar_iterator_new(&iterator, config, name, nil)
        }
    }

    /// The values of every key matching `regex`, in git's order.
    static func configValues(matching regex: String, in directory: URL) throws -> [String] {
        try configValues(in: directory) { config, iterator in
            git_config_iterator_glob_new(&iterator, config, regex)
        }
    }

    private static func configValues(
        in directory: URL,
        iterate: (OpaquePointer?, inout UnsafeMutablePointer<git_config_iterator>?) -> CInt
    ) throws -> [String] {
        var repo: OpaquePointer?
        var config: OpaquePointer?
        var iterator: UnsafeMutablePointer<git_config_iterator>?
        defer {
            git_config_iterator_free(iterator)
            git_config_free(config)
            git_repository_free(repo)
        }
        try check(git_repository_open_ext(&repo, directory.path, 0, nil))
        try installEnvironmentConfig(intoRepository: repo)
        try check(git_repository_config_snapshot(&config, repo))
        try check(iterate(config, &iterator))
        var values: [(level: Int, value: String)] = []
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let result = git_config_next(&entry, iterator)
            if result == GIT_ITEROVER.rawValue { break }
            try check(result)
            guard let entry = entry?.pointee else { continue }
            // A key without a value (`[foo] bar`) reads as empty, as
            // `git config --get-all` gives it.
            values.append((Int(entry.level.rawValue), entry.value.map { String(cString: $0) } ?? ""))
        }
        // A stable sort keeps each level's values in file order.
        return values.enumerated()
            .sorted { ($0.element.level, $0.offset) < ($1.element.level, $1.offset) }
            .map(\.element.value)
    }

    /// The first `remote.<name>.push` written without a value
    /// (`[remote "origin"] push`), which git refuses to run with, as git
    /// names it: the key, the file (relative to the work tree's top when
    /// in it, as git reads it from there) and the line.
    public func valuelessRemotePush() async throws -> (key: String, file: String, line: Int)? {
        try await withRepository { _ in try Self.valuelessRemotePush(in: workingDirectory) }
    }

    static func valuelessRemotePush(in directory: URL) throws -> (key: String, file: String, line: Int)? {
        var repo: OpaquePointer?
        var config: OpaquePointer?
        var iterator: UnsafeMutablePointer<git_config_iterator>?
        defer {
            git_config_iterator_free(iterator)
            git_config_free(config)
            git_repository_free(repo)
        }
        try check(git_repository_open_ext(&repo, directory.path, 0, nil))
        try installEnvironmentConfig(intoRepository: repo)
        try check(git_repository_config_snapshot(&config, repo))
        try check(git_config_iterator_glob_new(&iterator, config, "^remote\\..*\\.push$"))
        var found: [(key: String, path: String, level: Int)] = []
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let result = git_config_next(&entry, iterator)
            if result == GIT_ITEROVER.rawValue { break }
            try check(result)
            guard let entry = entry?.pointee, entry.value == nil,
                  let name = entry.name, let origin = entry.origin_path
            else { continue }
            found.append((String(cString: name), String(cString: origin), Int(entry.level.rawValue)))
        }
        // git reads the files lowest level first and stops at the first.
        guard let first = found.min(by: { $0.level < $1.level }) else { return nil }
        let line = valuelessLine(of: first.key, in: URL(fileURLWithPath: first.path)) ?? 0
        // Relative to where git reads it from: the work tree's top, or a
        // bare repository's own directory.
        var file = first.path
        let base = (git_repository_workdir(repo) ?? git_repository_path(repo)).map { String(cString: $0) }
        if let base, file.hasPrefix(base) {
            file = String(file.dropFirst(base.count))
        }
        return (first.key, file, line)
    }

    /// The line of `file` where `key` (`remote.origin.push`) is written
    /// without a value, counting from 1, as git reads the file.
    private static func valuelessLine(of key: String, in file: URL) -> Int? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let name = Array(key.utf8)
        return GitConfigFile.parse(data).entries.first { $0.key == name && $0.value == nil }?.line
    }

    /// Whether git takes `refspec` as a push refspec (refspec.c's
    /// `parse_refspec`): `:` (matching), else a source and an optional
    /// destination, both patterns or neither. The source may be empty
    /// (a deletion), an object ID or any revision, but must be a ref
    /// name when it's a pattern or there's no destination; a destination
    /// must be a ref name. A negative refspec (`^refs/heads/wip`) is a
    /// ref name or pattern alone: not forced, not empty, without a
    /// destination, not an object ID.
    public static func isValidPushRefspec(_ refspec: String) -> Bool {
        var body = Substring(refspec)
        let forced = body.hasPrefix("+")
        if forced { body = body.dropFirst() }
        if body.hasPrefix("^") {
            var name = body.dropFirst()
            // `^@` is `^HEAD` as well.
            if name == "@" { name = "HEAD" }
            guard !forced, !name.isEmpty, !name.contains(":"),
                  !(name.count == 40 && name.utf8.allSatisfy({ isASCIIHex($0) }))
            else { return false }
            return isRefName(name, pattern: name.contains("*"))
        }
        if body == ":" { return true }
        let colon = body.lastIndex(of: ":")
        var source = colon.map { body[..<$0] } ?? body
        // git reads a source of `@` alone as HEAD.
        if source == "@" { source = "HEAD" }
        let destination = colon.map { body[body.index(after: $0)...] }
        let globDestination = destination?.contains("*") ?? false
        let globSource = source.contains("*")
        if globSource, destination != nil, !globDestination { return false }
        if !globSource, globDestination { return false }
        if globSource, !isRefName(source, pattern: true) { return false }
        guard let destination else { return isRefName(source, pattern: globSource) }
        return !destination.isEmpty && isRefName(destination, pattern: globSource)
    }

    /// `refspec` with a source of `@` alone spelled out as HEAD, as
    /// git's parse_refspec reads it (`@:refs/heads/x`, `+@`, `^@`).
    public static func pushRefspecReadingAtAsHead(_ refspec: String) -> String {
        var prefix = ""
        var body = Substring(refspec)
        if body.hasPrefix("+") { prefix += "+"; body = body.dropFirst() }
        if body.hasPrefix("^") { prefix += "^"; body = body.dropFirst() }
        guard body == "@" || body.hasPrefix("@:") else { return refspec }
        return prefix + "HEAD" + body.dropFirst()
    }

    private static func isASCIIHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte | 0x20)
    }

    /// git's check_refname_format with one-level names allowed, and a
    /// `*` with `pattern`. libgit2's ALLOW_ONELEVEL takes only all-caps
    /// names (`HEAD`), so the name is checked under `refs/`, which keeps
    /// every rule for its components.
    private static func isRefName(_ name: Substring, pattern: Bool) -> Bool {
        // git forbids a refname that is `@` alone, which `refs/@` would hide.
        guard name != "@" else { return false }
        Libgit2.ensureInitialized()
        let candidate = name.hasPrefix("refs/") ? String(name) : "refs/\(name)"
        let flags = pattern ? UInt32(GIT_REFERENCE_FORMAT_REFSPEC_PATTERN.rawValue) : 0
        var buffer = [CChar](repeating: 0, count: candidate.utf8.count + 1)
        guard git_reference_normalize_name(&buffer, buffer.count, candidate, flags) == 0 else {
            return false
        }
        return String(cString: buffer) == candidate
    }

    /// A boolean config value as git reads one (`true`/`yes`/`on`, any
    /// nonzero integer, a key without a value), or `nil` when unset.
    /// Anything else throws git's "bad boolean config value".
    public func configBool(_ name: String) async throws -> Bool? {
        try await withRepository { _ in
            try Self.configEntry(name, in: workingDirectory).map { try Self.parseGitBool($0, key: name) }
        }
    }

    /// The config entry `name` as written, `nil` when it isn't set:
    /// `.some(nil)` for a key without a value (`[push] autoSetupRemote`),
    /// which ``configGet(_:scope:)`` reads as empty. GitKit keeps its
    /// repository handle to itself, so this opens its own.
    static func configEntry(_ name: String, in directory: URL) throws -> String?? {
        var repo: OpaquePointer?
        var config: OpaquePointer?
        var entry: UnsafeMutablePointer<git_config_entry>?
        defer {
            git_config_entry_free(entry)
            git_config_free(config)
            git_repository_free(repo)
        }
        try check(git_repository_open_ext(&repo, directory.path, 0, nil))
        try installEnvironmentConfig(intoRepository: repo)
        try check(git_repository_config_snapshot(&config, repo))
        let result = git_config_get_entry(&entry, config, name)
        if result == GIT_ENOTFOUND.rawValue { return nil }
        try check(result)
        return .some(entry?.pointee.value.map { String(cString: $0) })
    }

    /// Throws libgit2's error for a call that failed with `result`.
    static func check(_ result: CInt) throws {
        guard result < 0 else { return }
        let last = git_error_last()
        throw Libgit2Error(
            code: result, klass: last?.pointee.klass ?? 0,
            message: last?.pointee.message.map { String(cString: $0) } ?? "unknown error")
    }

    /// git's boolean parsing (`git_config_parse_bool`) and its error,
    /// which names the key the way git spells it (section and variable
    /// lowercased: `push.autosetupremote`). A key without a value is
    /// true; an empty value is false.
    /// An environment variable read as git reads a boolean one
    /// (`git_env_bool`): the config rules, with git's error for a value
    /// that is none (`GIT_ADVICE=bogus`).
    public static func parseGitBoolEnvironment(_ value: String, name: String) throws -> Bool {
        var parsed: CInt = 0
        let result = value.withCString { git_config_parse_bool(&parsed, $0) }
        guard result == 0 else {
            throw Libgit2Error(
                code: Int32(result), klass: 0,
                message: "bad boolean environment value '\(value)' for '\(name)'")
        }
        return parsed != 0
    }

    static func parseGitBool(_ value: String?, key: String) throws -> Bool {
        guard let value else { return true }
        var parsed: CInt = 0
        let result = value.withCString { git_config_parse_bool(&parsed, $0) }
        guard result == 0 else {
            var canonical = key.lowercased()
            if let first = key.firstIndex(of: "."), let last = key.lastIndex(of: "."), first < last {
                canonical = key[..<first].lowercased() + key[first..<last] + key[last...].lowercased()
            }
            throw Libgit2Error(
                code: Int32(result), klass: 0,
                message: "bad boolean config value '\(value)' for '\(canonical)'")
        }
        return parsed != 0
    }
}
