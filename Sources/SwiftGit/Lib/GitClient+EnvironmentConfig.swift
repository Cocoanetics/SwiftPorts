import Foundation
import CGitKit
import GitKit
import ShellKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// What the shell's `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`,
/// `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` and
/// `GIT_CONFIG_PARAMETERS` (`git -c`) ask of the config every git command
/// reads.
///
/// libgit2 reads none of them itself (outside the `FROM_ENV` open flag, which
/// also reads `GIT_DIR` and more, and which GitKit's `Repository.open` doesn't
/// pass). `Libgit2Sandboxing` switches off the levels they replace; the files
/// and entries are added to the open config by
/// ``GitClient/installEnvironmentConfig(intoRepository:)``.
struct EnvironmentConfig: Equatable, Sendable {
    /// A config file as typed (what `--show-origin` prints) and as it
    /// resolves from the shell's working directory (what is opened).
    struct File: Equatable, Sendable {
        let typed: String
        let resolved: String
    }

    /// `GIT_CONFIG_GLOBAL` is set, even to nothing: git then reads that
    /// file instead of `~/.gitconfig` and the XDG one.
    var globalOverride = false
    /// The file `GIT_CONFIG_GLOBAL` names, `nil` for an empty value.
    var globalFile: File?
    /// `GIT_CONFIG_SYSTEM` is set (and the system config isn't off): git
    /// reads that file instead of `/etc/gitconfig`.
    var systemOverride = false
    /// The file `GIT_CONFIG_SYSTEM` names, `nil` for an empty value or one a
    /// sandbox won't read.
    var systemFile: File?
    /// One `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` pair, or one
    /// `GIT_CONFIG_PARAMETERS` entry, name normalized. `value` is `nil` for
    /// a valueless entry (`git -c name`), which reads as true; an empty one
    /// (`git -c name=`) reads as false.
    struct CommandLineEntry: Equatable, Sendable {
        let name: String
        let value: String?
        /// For an `include.path` entry, the file it includes, read right
        /// after it (``GitClient/resolveIncludes(_:)``); `nil` for one
        /// that isn't there, which git passes over.
        var include: String?
    }

    /// `GIT_CONFIG_COUNT`'s entries, then `GIT_CONFIG_PARAMETERS`', names
    /// normalized. Kept as pairs — not `name=value` strings — because a
    /// subsection may contain `=` (e.g. `url.https://x/?a=b.insteadOf`).
    var commandLine: [CommandLineEntry] = []

    static let none = EnvironmentConfig()

    /// Whether the open config has something to be given.
    var needsInstall: Bool {
        globalFile != nil || systemFile != nil || !commandLine.isEmpty
    }
}

/// git's "unable to parse command-line config": a `GIT_CONFIG_COUNT` or
/// `GIT_CONFIG_PARAMETERS` it can't read. It stops every command, each with
/// its own words.
public struct CommandLineConfigError: Error, LocalizedError, CommandFailure, Equatable {
    /// Why, as git words it after `error: `.
    public let reason: String

    /// What git prints, `fatal:` and all.
    public var lines: [String] {
        ["error: \(reason)", "fatal: unable to parse command-line config"]
    }

    public var errorDescription: String? { lines.joined(separator: "\n") }
    public var diagnostic: String { lines.map { $0 + "\n" }.joined() }
    public var exitStatus: ShellKit.ExitStatus { ShellKit.ExitStatus(Int32(128)) }
}

/// A diagnostic git prints as is, then exits with `exitCode`.
public struct GitDiagnosticError: Error, LocalizedError, CommandFailure, Equatable {
    public let lines: [String]
    public let exitCode: Int32

    public var errorDescription: String? { lines.joined(separator: "\n") }
    public var diagnostic: String { lines.map { $0 + "\n" }.joined() }
    public var exitStatus: ShellKit.ExitStatus { ShellKit.ExitStatus(exitCode) }
}

extension GitClient {

    // MARK: Resolving what the environment asks

    /// What the shell's environment asks of the config, with the files it
    /// names let through the sandbox: one a sandbox refuses, or whose
    /// `[include]` it won't follow, is a denial; a system file a sandbox
    /// isn't allowed to read (``GitSandboxPolicy/allowsHostSystemConfig``) is
    /// left out, as the host's own system config is.
    func environmentConfig() async throws -> EnvironmentConfig {
        let env = Shell.current.environment
        var plan = EnvironmentConfig()
        if let typed = env["GIT_CONFIG_GLOBAL"] {
            plan.globalOverride = true
            if !typed.isEmpty {
                let resolved = location(of: typed)
                try await authorizeOverride(resolved)
                plan.globalFile = .init(typed: typed, resolved: resolved)
            }
        }
        let noSystem = try Libgit2Sandboxing.boolean(env["GIT_CONFIG_NOSYSTEM"], named: "GIT_CONFIG_NOSYSTEM")
        if !noSystem, let typed = env["GIT_CONFIG_SYSTEM"] {
            plan.systemOverride = true
            if !typed.isEmpty {
                let resolved = location(of: typed)
                var readable = true
                if Shell.current.sandbox != nil, !GitSandboxPolicy.allowsHostSystemConfig {
                    do { try await authorizeOverride(resolved) } catch { readable = false }
                }
                if readable { plan.systemFile = .init(typed: typed, resolved: resolved) }
            }
        }
        // git reads the entries in order, an include as it comes, and
        // stops at the first it can't take: the includes before a bad
        // entry are seen to before it is reported.
        let read = Self.readCommandLineConfig(Shell.current.environment.variables)
        plan.commandLine = try await resolveIncludes(read.entries)
        if let failure = read.failure { throw failure }
        return plan
    }

    /// `include.path` entries as git's `handle_path_include` takes those
    /// of the command line: a value is required, `~` is expanded, the
    /// path must be absolute (there is no file to be relative to), and a
    /// file that isn't there is passed over; one there must be allowed by
    /// the sandbox, and readable. Files it includes in turn are gated by
    /// ``isolatedGated`` / ``ConfigIncludeGate``.
    func resolveIncludes(
        _ entries: [EnvironmentConfig.CommandLineEntry]
    ) async throws -> [EnvironmentConfig.CommandLineEntry] {
        var resolved = entries
        for index in resolved.indices where resolved[index].name == "include.path" {
            guard let value = resolved[index].value else {
                throw CommandLineConfigError(reason: "missing value for 'include.path'")
            }
            guard let expanded = Self.interpolatedPath(value) else {
                throw CommandLineConfigError(reason: "could not expand include path '\(value)'")
            }
            guard Self.isAbsolutePath(expanded) else {
                throw CommandLineConfigError(reason: "relative config includes must come from files")
            }
            let file = Shell.resolve(expanded)
            try await Shell.authorize(file)
            // access_or_die: a missing file is no include; any other
            // reason it can't be read stops git.
            if let reason = Self.unreadableReason(file.path) {
                guard let reason else { continue }
                throw GitDiagnosticError(lines: ["fatal: unable to access '\(expanded)': \(reason)"], exitCode: 128)
            }
            resolved[index].include = file.path
        }
        return resolved
    }

    /// Why `path` can't be read: `nil` when it can, `.some(nil)` when it
    /// isn't there (ENOENT / ENOTDIR), else `strerror`'s words.
    private static func unreadableReason(_ path: String) -> String?? {
        #if os(Windows)
        guard FileManager.default.fileExists(atPath: path) else { return .some(nil) }
        return FileManager.default.isReadableFile(atPath: path) ? nil : .some("Permission denied")
        #else
        guard access(path, R_OK) != 0 else { return nil }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return .some(nil) }
        return .some(String(cString: strerror(code)))
        #endif
    }

    /// git's `interpolate_path` for `~` and `~/…` (the shell's `HOME`),
    /// `~user/…` and `%(prefix)/…` (`/usr`: there is no git install of our
    /// own, as for `gpg.ssh.allowedSignersFile`); `nil` where it can't expand.
    static func interpolatedPath(_ path: String) -> String? {
        if path.hasPrefix("%(prefix)/") { return "/usr" + path.dropFirst("%(prefix)".count) }
        guard path.hasPrefix("~") else { return path }
        let rest = path.dropFirst()
        let user = rest.prefix { $0 != "/" }
        let tail = rest.dropFirst(user.count)
        if user.isEmpty {
            guard let home = Shell.current.environment["HOME"] else { return nil }
            return home + tail
        }
        #if os(Windows)
        return nil
        #else
        guard let entry = getpwnam(String(user)), let directory = entry.pointee.pw_dir else { return nil }
        return String(cString: directory) + tail
        #endif
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        #if os(Windows)
        if path.hasPrefix("\\") { return true }
        if let drive = path.first, drive.isLetter, path.dropFirst().first == ":" { return true }
        #endif
        return path.hasPrefix("/")
    }

    /// A file the environment names is the user's pick, not libgit2's
    /// search: it must be allowed. `[include]` files it opens are gated
    /// by ``isolatedGated`` / ``ConfigIncludeGate``.
    private func authorizeOverride(_ resolved: String) async throws {
        // Reads as an empty config; nothing of the host's is in it.
        guard resolved != "/dev/null" else { return }
        try await Shell.authorize(URL(fileURLWithPath: resolved))
    }

    // MARK: GIT_CONFIG_COUNT and GIT_CONFIG_PARAMETERS

    /// The command-line entries, git's way (`git_config_from_parameters`):
    /// `GIT_CONFIG_COUNT`'s, a count, then a `GIT_CONFIG_KEY_<n>` and
    /// `GIT_CONFIG_VALUE_<n>` for each, followed by `GIT_CONFIG_PARAMETERS`'
    /// (``GitConfigParameters``). What git can't read stops the command.
    static func commandLineConfig(
        _ variables: [String: String]
    ) throws -> [EnvironmentConfig.CommandLineEntry] {
        let read = readCommandLineConfig(variables)
        if let failure = read.failure { throw failure }
        return read.entries
    }

    /// The entries read before the first one git can't take, and that
    /// failure.
    static func readCommandLineConfig(
        _ variables: [String: String]
    ) -> (entries: [EnvironmentConfig.CommandLineEntry], failure: Error?) {
        var entries: [EnvironmentConfig.CommandLineEntry] = []
        do {
            try countedConfig(variables, into: &entries)
            if let parameters = variables["GIT_CONFIG_PARAMETERS"] {
                try GitConfigParameters.entries(parameters) { key, value in
                    entries.append(.init(name: try normalizedKey(key), value: value))
                }
            }
            return (entries, nil)
        } catch {
            return (entries, error)
        }
    }

    /// `GIT_CONFIG_COUNT` entries, added to `entries` one by one.
    private static func countedConfig(
        _ variables: [String: String], into entries: inout [EnvironmentConfig.CommandLineEntry]
    ) throws {
        guard let text = variables["GIT_CONFIG_COUNT"] else { return }
        // git reads the count with `strtoul(…, 10)` and refuses what doesn't
        // end where the number does: an empty value is 0, leading white
        // space and a sign are taken, a negative or overflowing one is
        // "too many".
        var end: UnsafeMutablePointer<CChar>?
        let parsed = text.withCString { start -> (value: UInt, rest: Bool) in
            let value = UInt(strtoul(start, &end, 10))
            return (value, end.map { $0.pointee != 0 } ?? true)
        }
        guard !parsed.rest else {
            throw CommandLineConfigError(reason: "bogus count in GIT_CONFIG_COUNT")
        }
        guard parsed.value <= UInt(Int32.max) else {
            throw CommandLineConfigError(reason: "too many entries in GIT_CONFIG_COUNT")
        }
        let count = Int(parsed.value)
        for index in 0..<count {
            guard let key = variables["GIT_CONFIG_KEY_\(index)"] else {
                throw CommandLineConfigError(reason: "missing config key GIT_CONFIG_KEY_\(index)")
            }
            guard let value = variables["GIT_CONFIG_VALUE_\(index)"] else {
                throw CommandLineConfigError(reason: "missing config value GIT_CONFIG_VALUE_\(index)")
            }
            entries.append(.init(name: try normalizedKey(key), value: value))
        }
    }

    /// A config key as libgit2 stores it, section and variable name
    /// lowercased (an in-memory backend keeps what it is given), or git's
    /// complaint about one it can't take.
    static func normalizedKey(_ key: String) throws -> String {
        guard !key.isEmpty else { throw CommandLineConfigError(reason: "empty config key") }
        // git_config_parse_key: the last dot must come after the first
        // character, and the variable name must be there.
        // Among Unicode scalars, as git's `strrchr` looks among bytes.
        let scalars = key.unicodeScalars
        guard let first = scalars.firstIndex(of: "."), let last = scalars.lastIndex(of: "."),
              last != scalars.startIndex else {
            throw CommandLineConfigError(reason: "key does not contain a section: \(key)")
        }
        guard last != scalars.index(before: scalars.endIndex) else {
            throw CommandLineConfigError(reason: "key does not contain variable name: \(key)")
        }
        // The section and the variable name take letters, digits and `-`,
        // the variable name starting with a letter; a subsection takes
        // anything but a newline.
        func keyCharacter(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D
        }
        let section = Substring(scalars[..<first]), subsection = Substring(scalars[first..<last])
        let variable = Substring(scalars[scalars.index(after: last)...])
        for part in [section, variable] where !part.utf8.allSatisfy(keyCharacter) {
            throw CommandLineConfigError(reason: "invalid key: \(key)")
        }
        if let initial = variable.utf8.first, initial >= 0x30 && initial <= 0x39 || initial == 0x2D {
            throw CommandLineConfigError(reason: "invalid key: \(key)")
        }
        guard !subsection.unicodeScalars.contains("\n") else {
            throw CommandLineConfigError(reason: "invalid key (newline): \(key)")
        }
        return section.lowercased() + subsection + "." + variable.lowercased()
    }

    // MARK: Installing

    /// The raw `git_repository *` a GitKit `Repository` holds, which it keeps
    /// to itself (`internal`). Reflection reads a stored property whatever its
    /// access level and, unlike a layout cast, follows it wherever the
    /// compiler puts it. `nil` if GitKit stops having a `pointer`; a test
    /// fails then.
    static func handle(of repository: Repository) -> OpaquePointer? {
        Mirror(reflecting: repository).children.first { $0.label == "pointer" }?.value as? OpaquePointer
    }

    /// Gives the environment's config to `repository` through GitKit's typed
    /// config-level API: `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` at their
    /// levels, then `GIT_CONFIG_COUNT` above all, as ``commandLineConfiguration(_:)``.
    /// The files come first, so a `hasconfig:remote.*.url:` condition sees
    /// their URLs. Writes keep going to the repository's own file. Call inside
    /// ``Libgit2Sandboxing/runIsolated(_:environment:diagnostics:body:)``.
    static func installEnvironmentConfig(into repository: Repository) throws {
        let plan = Libgit2Sandboxing.shared.environment
        guard plan.needsInstall else { return }
        if let file = plan.globalFile {
            try repository.addConfigFile(at: URL(fileURLWithPath: file.resolved), level: .global)
        }
        if let file = plan.systemFile {
            try repository.addConfigFile(at: URL(fileURLWithPath: file.resolved), level: .system)
        }
        guard !plan.commandLine.isEmpty else { return }
        try withCommandLineFailures {
            Libgit2Sandboxing.shared.record(try repository.setCommandLineConfig(commandLineConfiguration(plan.commandLine)))
        }
    }

    /// The command line's config for GitKit, in its order: the entries up to
    /// an include, then the include, which reads its file in its place, the
    /// entries after it winning over that file and it over those before.
    /// `include.path` is one ``resolveIncludes(_:)`` found; one it passed
    /// over stays an entry. `includeIf.<condition>.path` is followed for each
    /// config that reads it, when its condition holds there.
    static func commandLineConfiguration(_ entries: [EnvironmentConfig.CommandLineEntry]) -> CommandLineConfig {
        var elements: [CommandLineConfig.Element] = []
        var pending: [ConfigEntry] = []
        func flush() {
            guard !pending.isEmpty else { return }
            elements.append(.entries(pending, name: commandLineBackendType))
            pending = []
        }
        for entry in entries {
            if let include = entry.include {
                flush()
                elements.append(.include(path: include))
            } else if let condition = includeCondition(entry.name), let value = entry.value {
                // A path that can't be expanded is git's error only once the
                // condition holds; GitKit takes it as it is
                // (Cocoanetics/GitKit#118). Valueless, it stays an entry.
                flush()
                elements.append(.includeIf(condition: condition, path: interpolatedPath(value) ?? value))
            } else {
                pending.append(ConfigEntry(name: entry.name, value: entry.value))
            }
        }
        flush()
        return CommandLineConfig(elements)
    }

    /// The condition of an `includeIf.<condition>.path` entry (name
    /// normalized), as typed; `nil` for any other entry.
    static func includeCondition(_ name: String) -> String? {
        let scalars = name.unicodeScalars
        guard let first = scalars.firstIndex(of: "."), let last = scalars.lastIndex(of: "."), first != last,
              String(scalars[..<first]) == "includeif",
              String(scalars[scalars.index(after: last)...]) == "path" else { return nil }
        return String(scalars[scalars.index(after: first)..<last])
    }

    /// Gives the environment's config to the live config of `repo`: the
    /// `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` files at their levels and
    /// the `GIT_CONFIG_COUNT` entries above all. Call it after opening, inside
    /// ``Libgit2Sandboxing/runIsolated(_:environment:diagnostics:body:)``.
    static func installEnvironmentConfig(intoRepository repo: OpaquePointer?) throws {
        guard Libgit2Sandboxing.shared.environment.needsInstall else { return }
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo))
        defer { git_config_free(config) }
        try installEnvironmentConfig(into: config, repo: repo)
    }

    /// Gives the environment's config to `config`, which may belong to a
    /// repository (`repo`) or to none; without one, `gitdir:` and
    /// `onbranch:` conditions don't hold. The files come before the command
    /// line, so its `hasconfig:remote.*.url:` conditions see their URLs.
    /// GitKit keeps the files' write order: no command-line element, nor a
    /// file one includes, is written to.
    static func installEnvironmentConfig(into config: OpaquePointer?, repo: OpaquePointer?) throws {
        let plan = Libgit2Sandboxing.shared.environment
        if let file = plan.globalFile {
            try check(git_config_add_file_ondisk(config, file.resolved, GIT_CONFIG_LEVEL_GLOBAL, repo, 1))
        }
        if let file = plan.systemFile {
            try check(git_config_add_file_ondisk(config, file.resolved, GIT_CONFIG_LEVEL_SYSTEM, repo, 1))
        }
        guard !plan.commandLine.isEmpty, let config else { return }
        try withCommandLineFailures {
            Libgit2Sandboxing.shared.record(try commandLineConfiguration(plan.commandLine).install(into: config, repository: repo))
        }
    }

    /// Runs `body`, which installs the command line's config, with GitKit's
    /// failures in git's words (``commandLineConfigFailure(_:)``).
    static func withCommandLineFailures<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw commandLineConfigFailure(error)
        }
    }

    /// What git says, and how it exits, for a failure GitKit reports
    /// reading the command line's includes. Anything else, a refused
    /// include among it (``isolatedGated`` authorizes it and reads again),
    /// is passed on as it is.
    static func commandLineConfigFailure(_ error: any Error) -> any Error {
        guard let failure = error as? Libgit2Error else { return error }
        let message = failure.message
        // A relative path git reached through a condition that holds.
        if message == "relative config includes must come from files" {
            return CommandLineConfigError(reason: message)
        }
        if message.hasPrefix("remote URLs cannot be configured in file directly or indirectly included by") {
            return GitDiagnosticError(lines: ["fatal: " + message], exitCode: 128)
        }
        // An include there but unreadable (`access_or_die`): libgit2's
        // `failed open - '<path>' is locked: Permission denied`.
        if failure.code == GIT_ELOCKED.rawValue, message.hasSuffix(": Permission denied"),
           let open = message.firstIndex(of: "'"), let close = message.lastIndex(of: "'"), open < close {
            let path = message[message.index(after: open)..<close]
            return GitDiagnosticError(lines: ["fatal: unable to access '\(path)': Permission denied"], exitCode: 128)
        }
        return error
    }

    /// The `backend_type` of the command line's entries.
    static let commandLineBackendType = "command line"

    // MARK: - show-origin

    /// What `--show-origin` prints before an entry: `file:<path>`, or
    /// `command line:` for `GIT_CONFIG_COUNT`'s and `GIT_CONFIG_PARAMETERS`'
    /// (a file one of them includes is a `file:`). A file the environment
    /// names is as typed; the repository's own is relative to the work
    /// tree's top (`base`), as git reads it from there.
    func originName(of entry: git_config_entry, base: String?) -> String {
        if entry.level.rawValue >= GIT_CONFIG_LEVEL_APP.rawValue,
           entry.backend_type.map({ String(cString: $0) }) == Self.commandLineBackendType {
            return "command line:"
        }
        guard let origin = entry.origin_path.map({ String(cString: $0) }) else { return "file:" }
        let plan = Libgit2Sandboxing.shared.environment
        if entry.include_depth == 0 {
            if entry.level == GIT_CONFIG_LEVEL_GLOBAL, let file = plan.globalFile, file.resolved == origin {
                return "file:" + file.typed
            }
            if entry.level == GIT_CONFIG_LEVEL_SYSTEM, let file = plan.systemFile, file.resolved == origin {
                return "file:" + file.typed
            }
        }
        if entry.level == GIT_CONFIG_LEVEL_LOCAL || entry.level == GIT_CONFIG_LEVEL_WORKTREE,
           let base, origin.hasPrefix(base) {
            return "file:" + origin.dropFirst(base.count)
        }
        return "file:" + origin
    }
}
