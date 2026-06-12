import Foundation
import ForgeKit
import ShellKit

/// Async resolver that builds a ``Configuration`` by layering env
/// vars (sync, via `Configuration.live()`) with the configured
/// ``SecretStore`` (async) and the on-disk `~/.config/gh/hosts.yml`
/// (sync; interoperable with upstream `gh`).
///
/// Precedence for the token, mirroring upstream `gh`:
///   1. `GH_TOKEN` env var
///   2. `GITHUB_TOKEN` env var
///   3. SecretStore[service: "com.swiftgh.gh", account: <host>]
///   4. hosts.yml[host].oauth_token  (only populated when the user
///      opted into upstream `gh --insecure-storage`)
///   5. nil
///
/// Hostname order: `--hostname` flag > `GH_HOST` env > "github.com".
public struct ConfigurationResolver: Sendable {
    public let secretStore: any SecretStore
    public let service: String
    public let hostsStore: HostsFileStore

    public static let defaultService = "com.swiftgh.gh"

    public init(
        secretStore: any SecretStore = DefaultSecretStore.make(),
        service: String = Self.defaultService,
        hostsStore: HostsFileStore = HostsFileStore()
    ) {
        self.secretStore = secretStore
        self.service = service
        self.hostsStore = hostsStore
    }

    /// Build the effective `Configuration`. `host` overrides `GH_HOST`
    /// when non-nil.
    public func resolve(host: String? = nil) async throws -> Configuration {
        var config = Configuration.live()
        if let host { config.host = host }

        if config.token == nil {
            config.token = try await secretStore.get(
                service: service, account: config.host)
        }
        if config.token == nil {
            // Last-resort plaintext fallback — only present when the
            // user explicitly chose --insecure-storage in upstream gh.
            if let hostsFile = try? hostsStore.read(),
               let entry = hostsFile[config.host],
               let token = entry.oauthToken,
               !token.isEmpty {
                config.token = token
            }
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

/// Where the resolved token came from. Used by `gh auth status` to
/// be honest about the source.
public enum TokenSource: Sendable {
    case ghTokenEnv
    case githubTokenEnv
    case secretStore
    case hostsFile
    case none

    /// Best-effort source detection. `hostsToken` lets us
    /// disambiguate between the keyring and the plaintext fallback
    /// when the env path isn't taken.
    public static func detect(
        env: [String: String] = Shell.current.environment.variables,
        configToken: String?,
        hostsToken: String? = nil
    ) -> TokenSource {
        if let v = env["GH_TOKEN"], !v.isEmpty, configToken == v {
            return .ghTokenEnv
        }
        if let v = env["GITHUB_TOKEN"], !v.isEmpty, configToken == v {
            return .githubTokenEnv
        }
        if let configToken, let hostsToken, configToken == hostsToken {
            return .hostsFile
        }
        if configToken != nil { return .secretStore }
        return .none
    }

    public var humanReadable: String {
        switch self {
        case .ghTokenEnv: return "GH_TOKEN env var"
        case .githubTokenEnv: return "GITHUB_TOKEN env var"
        case .secretStore: return "secret store (e.g. Keychain)"
        case .hostsFile: return "~/.config/gh/hosts.yml (insecure)"
        case .none: return "(none)"
        }
    }

    /// The token-source column upstream `gh auth status` prints
    /// (status.go `buildEntry`): the env var name, "keyring", or the
    /// hosts.yml path. `humanReadable` stays for prose messages.
    public var ghStatusLabel: String {
        switch self {
        case .ghTokenEnv: return "GH_TOKEN"
        case .githubTokenEnv: return "GITHUB_TOKEN"
        case .secretStore: return "keyring"
        case .hostsFile: return HostsFileStore.defaultPath.path
        case .none: return "(none)"
        }
    }
}
