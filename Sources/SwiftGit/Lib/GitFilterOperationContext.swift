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
    private let shell: Shell
    private let credentials: CredentialProvider?
    private let environment: EnvironmentConfig
    private let gate: ConfigIncludeGate

    enum Failure: Error, Equatable {
        case expired
        case unsupportedOperation
        case noOperation
    }

    init(shell: Shell, credentials: CredentialProvider?, environment: EnvironmentConfig, gate: ConfigIncludeGate) {
        self.shell = shell
        self.credentials = credentials
        self.environment = environment
        self.gate = gate
    }

    /// Capture on the libgit2 callback thread, before starting async work.
    package static func capture() throws -> GitFilterOperationContext {
        guard let context = Thread.current.threadDictionary[threadKey] as? GitFilterOperationContext else {
            throw Failure.noOperation
        }
        return context
    }

    func run<T>(_ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[Self.threadKey]
        Thread.current.threadDictionary[Self.threadKey] = self
        defer {
            lock.withLock { active = false }
            Thread.current.threadDictionary[Self.threadKey] = previous
        }
        return try body()
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
    }

    /// The client a push lends its isolation to while it waits for
    /// `beforeSending` (`git push` with git-lfs's pre-push hook): unlike a
    /// filter's, every git operation it runs goes ahead in the push's
    /// isolation, one at a time. The push is blocked until `body` returns.
    func withLentClient<T: Sendable>(
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
