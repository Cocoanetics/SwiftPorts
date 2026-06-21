import Foundation
import ForgeKit
import ShellKit

/// Async resolver that builds a ``Configuration`` by layering env vars
/// (sync, via `Configuration.live()`) with the configured ``SecretStore``.
///
/// Precedence for the token, mirroring upstream `glab`:
///   1. `GITLAB_TOKEN` env var
///   2. `GITLAB_ACCESS_TOKEN` env var
///   3. `OAUTH_TOKEN` env var
///   4. SecretStore[service: "com.swiftgl.glab", account: <host>]
///   5. nil
///
/// Hostname order: explicit `host:` argument > `GITLAB_HOST` env >
/// `GITLAB_URI` env > `GL_HOST` env > "gitlab.com".
public struct ConfigurationResolver: Sendable {
    public let secretStore: any SecretStore
    public let service: String

    public static let defaultService = "com.swiftgl.glab"

    public init(
        secretStore: any SecretStore = SystemSecretStore.shared,
        service: String = Self.defaultService
    ) {
        self.secretStore = secretStore
        self.service = service
    }

    /// Build the effective `Configuration`. `host` overrides `GITLAB_HOST`
    /// when non-nil.
    public func resolve(host: String? = nil) async throws -> Configuration {
        var config = Configuration.live()
        if let host { config.host = host }

        if config.token == nil {
            config.token = try await secretStore.get(
                service: service, account: config.host)
        }
        return config
    }

    /// Stash a token into the configured secret store.
    public func store(token: String, host: String) async throws {
        try await secretStore.set(
            service: service, account: host, secret: token)
    }

    /// Drop the stored token (if any) for `host`.
    public func remove(host: String) async throws {
        try await secretStore.delete(service: service, account: host)
    }
}

/// Where the resolved token came from. Used by `glab auth status`.
public enum TokenSource: Sendable {
    case gitlabTokenEnv
    case gitlabAccessTokenEnv
    case oauthTokenEnv
    case secretStore
    case none

    public static func detect(
        env: [String: String] = Shell.current.environment.variables,
        configToken: String?
    ) -> TokenSource {
        if let v = env["GITLAB_TOKEN"], !v.isEmpty, configToken == v {
            return .gitlabTokenEnv
        }
        if let v = env["GITLAB_ACCESS_TOKEN"], !v.isEmpty, configToken == v {
            return .gitlabAccessTokenEnv
        }
        if let v = env["OAUTH_TOKEN"], !v.isEmpty, configToken == v {
            return .oauthTokenEnv
        }
        if configToken != nil { return .secretStore }
        return .none
    }

    public var humanReadable: String {
        switch self {
        case .gitlabTokenEnv: return "GITLAB_TOKEN env var"
        case .gitlabAccessTokenEnv: return "GITLAB_ACCESS_TOKEN env var"
        case .oauthTokenEnv: return "OAUTH_TOKEN env var"
        case .secretStore: return "secret store (e.g. Keychain)"
        case .none: return "(none)"
        }
    }
}
