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

    func run<T>(_ body: () throws -> T) throws -> T {
        let previous = Thread.current.threadDictionary[Self.threadKey]
        Thread.current.threadDictionary[Self.threadKey] = self
        defer {
            lock.withLock {
                active = false
                deferredFailure = nil
            }
            Thread.current.threadDictionary[Self.threadKey] = previous
        }
        let result = try body()
        if let failure = lock.withLock({ deferredFailure }) { throw failure }
        return result
    }

    /// Delayed process filters report failure after the other checkout entries
    /// have been written. Retain only the first error, never file contents.
    package func deferFailure(_ error: any Error) throws {
        try lock.withLock {
            guard active else { throw Failure.expired }
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
    }

    func withRepository<T>(_ client: GitClient, _ body: (Repository) throws -> T) async throws -> T {
        try await Shell.$current.withValue(shell) {
            try checkActive()
            try await Shell.authorize(client.workingDirectory)
            while true {
                do {
                    return try lock.withLock {
                        guard active else { throw Failure.expired }
                        // The outer isolation cannot change until this lease
                        // is revoked. It already installed this exact plan.
                        assert(Libgit2Sandboxing.shared.environment == environment)
                        return try gate.run {
                            let repo = try Repository.open(at: client.workingDirectory)
                            try GitClient.installEnvironmentConfig(into: repo)
                            try client.checkConfigSyntax(of: repo)
                            return try body(repo)
                        }
                    }
                } catch {
                    guard try await gate.authorizeRefused() else { throw error }
                }
            }
        }
    }
}
