import ArgumentParser
import Foundation
import ForgeKit
import GitHub
import ShellKit
import SwiftGit

/// Per-process defaults for command runtime: a shared resolver, the
/// default secret store, etc. Centralised here so individual
/// subcommands have one line of boilerplate.
enum CommandContext {
    static let resolver = ConfigurationResolver()

    static func resolveConfig(host: String? = nil) async throws -> Configuration {
        try await resolver.resolve(host: host)
    }

    static func apiClient(host: String? = nil) async throws -> APIClient {
        let config = try await resolveConfig(host: host)
        try requireAuthentication(config)
        return APIClient(configuration: config)
    }

    static func graphQLClient(host: String? = nil) async throws -> GraphQLClient {
        let config = try await resolveConfig(host: host)
        try requireAuthentication(config)
        return GraphQLClient(configuration: config)
    }

    /// Upstream gh refuses to start API commands without a token
    /// (`pkg/cmd/root/help.go` authHelp, `exitAuth` = 4) instead of
    /// letting the request fall into the anonymous per-IP rate-limit
    /// pool — which is where the baffling "Authenticate with GH_TOKEN
    /// to raise the limit" errors in issue #75 came from. The auth
    /// subcommands resolve their config directly and stay usable
    /// without a token.
    static func requireAuthentication(_ config: Configuration) throws {
        guard config.token == nil else { return }
        Shell.current.stderr.write(Data(
            """
            To get started with GitHub CLI, please run:  gh auth login
            Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.

            """.utf8))
        throw ExitCode(4)
    }

    /// libgit2-backed git client rooted in the caller's working
    /// directory. HTTPS authentication routes through gh's existing
    /// token resolution (env vars → Keychain → `~/.config/gh/hosts.yml`)
    /// per-host, so `gh repo clone`, `gh repo fork`, `gh pr checkout`
    /// etc. don't need a `git` binary on PATH.
    ///
    /// Returns the protocol-typed value so callers stay compatible
    /// with `NoGitClient` injection in tests / sandboxed embedders.
    static func gitClient(
        workingDirectory: URL = Shell.currentDirectory
    ) -> any ForgeKit.GitClient {
        SwiftGit.GitClient(
            workingDirectory: workingDirectory,
            credentials: tokenResolvingProvider())
    }

    /// Per-host token lookup matching gh's other auth paths. We resolve
    /// `Configuration` for the URL's host on every challenge — that
    /// hits the in-memory cache for repeats, so the cost is fine.
    private static func tokenResolvingProvider() -> CredentialProvider {
        return { url, _, allowed in
            guard allowed.contains(.userPassword) else { return nil }
            guard let host = url.host else { return nil }
            guard let token = blockingResolveToken(host: host) else { return nil }
            // GitHub accepts the token as the username with empty
            // password OR as `x-access-token:<token>`. The latter is
            // what the GitHub docs recommend for app installations.
            return .token(token, username: "x-access-token")
        }
    }

    /// Bridges the libgit2 sync callback to our async resolver. The
    /// libgit2 transport calls our credential closure on a worker
    /// thread it owns, so blocking via `DispatchSemaphore` is safe.
    /// `MutableBox` is `@unchecked Sendable` because writes happen
    /// strictly before `semaphore.signal()` and reads strictly after
    /// `semaphore.wait()` — no concurrent access.
    private static func blockingResolveToken(host: String) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = MutableBox<String?>(value: nil)
        Task.detached { [box] in
            if let config = try? await resolver.resolve(host: host),
               let t = config.token, !t.isEmpty {
                box.value = t
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private final class MutableBox<T>: @unchecked Sendable {
        var value: T
        init(value: T) { self.value = value }
    }
}
