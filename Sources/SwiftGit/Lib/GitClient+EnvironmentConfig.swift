import Foundation
import CGitKit
import GitKit
import ShellKit

/// What the shell's `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM` and
/// `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` ask of
/// the config every git command reads.
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
    /// `GIT_CONFIG_COUNT`'s entries as `name=value`, names normalized.
    var commandLine: [String] = []

    static let none = EnvironmentConfig()

    /// Whether the open config has something to be given.
    var needsInstall: Bool {
        globalFile != nil || systemFile != nil || !commandLine.isEmpty
    }
}

/// git's "unable to parse command-line config": a `GIT_CONFIG_COUNT` it
/// can't read. It stops every command, each with its own words.
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
        if !Libgit2Sandboxing.isTrue(env["GIT_CONFIG_NOSYSTEM"]), let typed = env["GIT_CONFIG_SYSTEM"] {
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
        plan.commandLine = try Self.commandLineConfig(Shell.current.environment.variables)
        return plan
    }

    /// Runs `body` with libgit2's options set to the shell's view, the
    /// environment's config overrides included (see ``environmentConfig()``).
    func isolated<T>(_ body: () throws -> T) async throws -> T {
        let plan = try await environmentConfig()
        return try Libgit2Sandboxing.shared.runIsolated(
            Shell.current.sandbox, environment: plan, body: body)
    }

    /// A file the environment names is the user's pick, not libgit2's
    /// search: it must be allowed, and in a sandbox hold no `[include]`.
    private func authorizeOverride(_ resolved: String) async throws {
        // Reads as an empty config; nothing of the host's is in it.
        guard resolved != "/dev/null" else { return }
        try await Shell.authorize(URL(fileURLWithPath: resolved))
        if Shell.current.sandbox != nil, Self.hasIncludes(resolved) {
            throw Sandbox.Denial(
                url: URL(fileURLWithPath: resolved),
                reason: "git config: a config file with [include] sections is not read in a sandbox")
        }
    }

    // MARK: GIT_CONFIG_COUNT

    /// `GIT_CONFIG_COUNT` entries as `name=value`, git's way: a count, then
    /// a `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>` for each. What git
    /// can't read stops the command.
    static func commandLineConfig(_ variables: [String: String]) throws -> [String] {
        guard let text = variables["GIT_CONFIG_COUNT"] else { return [] }
        guard let count = Int(text) else {
            throw CommandLineConfigError(reason: "bogus count in GIT_CONFIG_COUNT")
        }
        guard count >= 0 else {
            throw CommandLineConfigError(reason: "too many entries in GIT_CONFIG_COUNT")
        }
        var entries: [String] = []
        for index in 0..<count {
            guard let key = variables["GIT_CONFIG_KEY_\(index)"] else {
                throw CommandLineConfigError(reason: "missing config key GIT_CONFIG_KEY_\(index)")
            }
            guard let value = variables["GIT_CONFIG_VALUE_\(index)"] else {
                throw CommandLineConfigError(reason: "missing config value GIT_CONFIG_VALUE_\(index)")
            }
            entries.append("\(try normalizedKey(key))=\(value)")
        }
        return entries
    }

    /// A config key as libgit2 stores it, section and variable name
    /// lowercased (an in-memory backend keeps what it is given), or git's
    /// complaint about one it can't take.
    static func normalizedKey(_ key: String) throws -> String {
        guard !key.isEmpty else { throw CommandLineConfigError(reason: "empty config key") }
        guard let first = key.firstIndex(of: "."), let last = key.lastIndex(of: ".") else {
            throw CommandLineConfigError(reason: "key does not contain a section: \(key)")
        }
        guard last != key.index(before: key.endIndex) else {
            throw CommandLineConfigError(reason: "key does not contain variable name: \(key)")
        }
        let section = key[..<first].lowercased()
        let variable = key[key.index(after: last)...].lowercased()
        let subsection = first < last ? String(key[first..<last]) : ""
        return section + subsection + "." + variable
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

    /// Gives the environment's config to the repository `repository` holds
    /// (see ``installEnvironmentConfig(intoRepository:)``).
    static func installEnvironmentConfig(into repository: Repository) throws {
        guard Libgit2Sandboxing.shared.environment.needsInstall else { return }
        guard let pointer = handle(of: repository) else {
            throw Libgit2Error(
                code: -1, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                message: "cannot reach GitKit's repository handle to apply GIT_CONFIG_* to it")
        }
        try installEnvironmentConfig(intoRepository: pointer)
    }

    /// Gives the environment's config to the live config of `repo`: the
    /// `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` files at their levels and
    /// the `GIT_CONFIG_COUNT` entries above all. Call it after opening, inside
    /// ``Libgit2Sandboxing/runIsolated(_:environment:body:)``.
    static func installEnvironmentConfig(intoRepository repo: OpaquePointer?) throws {
        guard Libgit2Sandboxing.shared.environment.needsInstall else { return }
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo))
        defer { git_config_free(config) }
        try installEnvironmentConfig(into: config, repo: repo)
    }

    /// Gives the environment's config to `config`, which may belong to a
    /// repository (`repo`) or to none.
    static func installEnvironmentConfig(into config: OpaquePointer?, repo: OpaquePointer?) throws {
        let plan = Libgit2Sandboxing.shared.environment
        if let file = plan.globalFile {
            try check(git_config_add_file_ondisk(config, file.resolved, GIT_CONFIG_LEVEL_GLOBAL, repo, 1))
        }
        if let file = plan.systemFile {
            try check(git_config_add_file_ondisk(config, file.resolved, GIT_CONFIG_LEVEL_SYSTEM, repo, 1))
        }
        guard !plan.commandLine.isEmpty else { return }
        var pointers: [UnsafePointer<CChar>?] = plan.commandLine.map { UnsafePointer(strdup($0)) }
        defer { pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var backend: UnsafeMutablePointer<git_config_backend>?
        try "command line".withCString { type in
            var options = git_config_backend_memory_options()
            options.version = UInt32(GIT_CONFIG_BACKEND_MEMORY_OPTIONS_VERSION)
            options.backend_type = type
            try check(git_config_backend_from_values(&backend, &pointers, pointers.count, &options))
        }
        try check(git_config_add_backend(config, backend, GIT_CONFIG_LEVEL_APP, repo, 0))
    }

    // MARK: --show-origin

    /// What `--show-origin` prints before an entry: `file:<path>`, or
    /// `command line:` for `GIT_CONFIG_COUNT`'s. A file the environment
    /// names is as typed; the repository's own is relative to the work
    /// tree's top (`base`), as git reads it from there.
    func originName(of entry: git_config_entry, base: String?) -> String {
        if entry.level == GIT_CONFIG_LEVEL_APP { return "command line:" }
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
