import Foundation
import ForgeKit
import ShellKit

/// A revocable lease on an outer operation's isolation, not a second turn.
/// Only filter metadata delegates can use it; repository handles stay local to
/// each synchronous read. No libgit2 pointer crosses the async bridge.
package final class GitFilterOperationContext: @unchecked Sendable {
    private static let threadKey = "SwiftGit.filterOperation"
    private let lock = NSLock()
    private var active = true
    private var deferredFailure: (any Error)?
    private var failedPaths: [URL: Set<String>] = [:]
    private let shell: Shell
    private let credentials: CredentialProvider?
    private let environment: EnvironmentConfig
    private let gate: ConfigIncludeGate
    private let deferFilterFailures: Bool
    private let cancellation: BlockingBridgeCancellation?

    enum Failure: Error, Equatable {
        case expired
        case unsupportedOperation
        case noOperation
    }

    init(shell: Shell, credentials: CredentialProvider?, environment: EnvironmentConfig, gate: ConfigIncludeGate,
         deferFilterFailures: Bool = false, cancellation: BlockingBridgeCancellation? = nil) {
        self.shell = shell
        self.credentials = credentials
        self.environment = environment
        self.gate = gate
        self.deferFilterFailures = deferFilterFailures
        self.cancellation = cancellation
    }

    /// Capture on the libgit2 callback thread, before starting async work.
    package static func capture() throws -> GitFilterOperationContext {
        guard let context = Thread.current.threadDictionary[threadKey] as? GitFilterOperationContext else {
            throw Failure.noOperation
        }
        return context
    }

    func run<T>(_ body: () throws -> T) throws -> T {
        let previous = Thread.current.threadDictionary[Self.threadKey]
        Thread.current.threadDictionary[Self.threadKey] = self
        defer {
            lock.withLock {
                active = false
                deferredFailure = nil
                failedPaths.removeAll()
            }
            Thread.current.threadDictionary[Self.threadKey] = previous
        }
        let result = Result { try rethrowDenial(body) }
        // Checkout has finished writing its index. Do not leave empty failed
        // output cached against the original blob, even if another path threw.
        let paths = lock.withLock { failedPaths }
        let repair = Result { try gate.run { try GitFilterIndex.invalidate(paths) } }
        let value = try result.get()
        try repair.get()
        try cancellation?.checkCancellation()
        if let failure = lock.withLock({ deferredFailure }) { throw failure }
        return value
    }

    /// Delayed process filters report failure after the other checkout entries
    /// have been written. Only explicit checkout/clone operations opt in;
    /// composite operations such as stash pop must fail before dropping data.
    /// Retain only the first error, never file contents.
    package func deferFailure(_ error: any Error, source: GitFilterSource? = nil) throws {
        try lock.withLock {
            guard active else { throw Failure.expired }
            guard deferFilterFailures else { throw error }
            if let source { failedPaths[source.gitDirectory, default: []].insert(source.path) }
            if deferredFailure == nil { deferredFailure = error }
        }
    }

    /// The source may be clone's newly created repository or a linked
    /// worktree's private git directory. Never infer it from the shell's cwd.
    package func withSource<T: Sendable>(
        _ source: GitFilterSource,
        _ body: @Sendable (GitClient) async throws -> T
    ) async throws -> T {
        try await shell.withCurrent {
            try checkActive()
            var client = GitClient(workingDirectory: source.gitDirectory, credentials: credentials)
            client.filterContext = self
            return try await body(client)
        }
    }

    private func checkActive() throws {
        try lock.withLock {
            guard active else { throw Failure.expired }
        }
        try cancellation?.checkCancellation()
    }

    /// Throws once the enclosing operation is cancelled, so a filter can tell
    /// cancellation from a transform failure it may fall back from.
    package func checkCancellation() throws {
        try cancellation?.checkCancellation()
    }

    /// Synchronous facilities are usable only on the enclosing GitKit thread.
    package func checkCurrent() throws {
        try checkActive()
        guard try Self.capture() === self else { throw Failure.unsupportedOperation }
    }

    package func runBlocking<T: Sendable>(
        onDiscard: @Sendable (T) -> Void = { _ in },
        _ body: @escaping @Sendable () async throws -> T
    ) throws -> T {
        try checkActive()
        return try BlockingBridge.runBlocking(cancellation: cancellation, onDiscard: onDiscard) { [shell] in
            try await shell.withCurrent(body)
        }
    }

    /// Authorize an `[include]` path encountered during the outer synchronous
    /// operation without replaying host mutations. Never bridges on the async
    /// callback thread (`filterContext.isolated` uses its async retry loop).
    func authorizeInclude(_ path: String) -> Bool {
        let isActive = lock.withLock { active }
        guard isActive else { return false }
        do {
            try cancellation?.checkCancellation()
        } catch {
            gate.recordDenial(error)
            return false
        }
        if !gate.enforcing || gate.isAllowed(path) { return true }
        guard Thread.current.threadDictionary[Self.threadKey] as? GitFilterOperationContext === self else {
            gate.refuse(path)
            return false
        }
        let url = URL(fileURLWithPath: ConfigIncludeGate.readablePath(path))
        do {
            try BlockingBridge.runBlocking(cancellation: cancellation) { [shell] in
                try await shell.withCurrent { try await Shell.authorize(url) }
            }
            gate.allow(path)
            return true
        } catch {
            gate.recordDenial(error)
            return false
        }
    }

    /// Per-repository include policy bound to this operation; refuses includes
    /// once the enclosing operation ends so escaped handles fail closed.
    var includePolicy: ConfigIncludePolicy {
        ConfigIncludePolicy { [weak self] include in
            guard let self else { return false }
            return self.authorizeInclude(include.path)
        }
    }

    /// Surface the exact sandbox denial or cancellation recorded by an include
    /// callback instead of libgit2's generic refusal error.
    package func rethrowDenial<T>(_ body: () throws -> T) throws -> T {
        if let denial = gate.takeDenial() { throw denial }
        let result = Result { try body() }
        // libgit2 can suppress an internal submodule open error and return
        // success. Preserve the include callback's denial in that case too.
        if let denial = gate.takeDenial() { throw denial }
        return try result.get()
    }

    /// Install this operation's include policy, signer, effective configuration
    /// levels and syntax checks on `repository`.
    package func prepareRepository(_ repository: Repository) throws {
        try checkCurrent()
        let directory = try repository.workdirURL
            ?? repository.gitDir().map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: shell.environment.workingDirectory)
        let client = GitClient(workingDirectory: directory, credentials: credentials)
        try rethrowDenial {
            try gate.run(authorizing: { [self] in authorizeInclude($0) }, {
                try repository.setIncludePolicy(includePolicy)
                try client.prepare(repository, cancellation: cancellation)
            })
        }
    }

    /// This operation's effective levels and include policy for every
    /// repository libgit2 opens on this thread, including the submodule
    /// handles it opens itself during status and diff. Settings git reads
    /// from a repository's own config only are left to exposed handles.
    /// A command-line `include.path` reads its file in place, and an
    /// `includeIf` is decided for each repository opened, as on an exposed
    /// handle (``GitClient/commandLineConfiguration(_:)``); their diagnostics
    /// go to the run's.
    var operationConfiguration: OperationConfiguration {
        var levels: [OperationConfiguration.Level] = []
        if let file = environment.globalFile {
            levels.append(.file(URL(fileURLWithPath: file.resolved), .global))
        }
        if let file = environment.systemFile {
            levels.append(.file(URL(fileURLWithPath: file.resolved), .system))
        }
        let entries = environment.commandLine.filter { !Self.isRepositoryOnly($0.name) }
        return OperationConfiguration(
            levels: levels,
            commandLine: entries.isEmpty ? nil : GitClient.commandLineConfiguration(entries),
            includePolicy: includePolicy,
            onDiagnostic: { Libgit2Sandboxing.shared.record($0) }
        )
    }

    /// `core.repositoryformatversion`, `core.bare`, `core.worktree` and
    /// `extensions.*`, which an operation level refuses.
    private static func isRepositoryOnly(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if parts.first == "extensions" { return true }
        return parts.count == 2 && parts[0] == "core"
            && ["repositoryformatversion", "bare", "worktree"].contains(parts[1])
    }

    package func authorize(_ url: URL) throws {
        try checkCurrent()
        try runBlocking { try await Shell.authorize(url) }
    }

    package func client(at directory: URL) -> GitClient {
        GitClient(workingDirectory: directory, credentials: credentials)
    }

    /// The client a push lends its isolation to while it waits for
    /// `beforeSending` (`git push` with git-lfs's pre-push hook): unlike a
    /// filter's, every git operation it runs goes ahead in the push's
    /// isolation, one at a time. The push is blocked until `body` returns.
    package func withLentClient<T: Sendable>(
        _ outer: GitClient, _ body: @Sendable (GitClient) async throws -> T
    ) async throws -> T {
        try await shell.withCurrent {
            try checkActive()
            var client = outer
            client.filterContext = self
            client.borrowsIsolation = true
            return try await body(client)
        }
    }

    func withRepository<T>(_ client: GitClient, _ body: (Repository) throws -> T) async throws -> T {
        try await Shell.$current.withValue(shell) {
            try checkActive()
            try await Shell.authorize(client.workingDirectory)
        }
        return try await isolated {
            let repo = try Repository.open(at: client.workingDirectory)
            try GitClient.installEnvironmentConfig(into: repo)
            try client.checkConfigSyntax(of: repo)
            return try body(repo)
        }
    }

    /// Runs `body` on this thread in the outer operation's isolation.
    func isolated<T>(_ body: () throws -> T) async throws -> T {
        try await Shell.$current.withValue(shell) {
            try checkActive()
            while true {
                do {
                    return try lock.withLock {
                        guard active else { throw Failure.expired }
                        // The outer isolation cannot change until this lease
                        // is revoked. It already installed this exact plan.
                        assert(Libgit2Sandboxing.shared.environment == environment)
                        return try gate.run(body)
                    }
                } catch {
                    guard try await gate.authorizeRefused() else { throw error }
                }
            }
        }
    }
}
