import Configuration
import Foundation
import Sandbox

/// Static config for an API session: which host, which token, which UA.
///
/// Backed by `swift-configuration` so the live constructor can layer
/// env vars + (future) `~/.config/gh/config.yml` + (future)
/// `~/.config/gh/hosts.yml` with consistent precedence. The struct
/// itself is a snapshot — read once at command start, then read-only.
public struct Configuration: Sendable {
    public var host: String
    public var token: String?
    public var userAgent: String

    public init(
        host: String = Configuration.defaultHost,
        token: String? = nil,
        userAgent: String = Configuration.defaultUserAgent
    ) {
        self.host = host
        self.token = token
        self.userAgent = userAgent
    }

    public static let defaultHost = "github.com"
    public static let defaultUserAgent = "SwiftGH/0.1 (+https://github.com/Cocoanetics/SwiftPorts)"

    /// Build from a `ConfigReader`. Useful for tests (inject an
    /// `InMemoryProvider`) and embedders that want a custom provider
    /// chain.
    ///
    /// Available on macOS 15+ / iOS 18+ / tvOS 18+ / watchOS 11+ —
    /// `swift-configuration`'s `ConfigReader` itself is gated to
    /// those releases. Callers on older OSes use ``init(host:token:userAgent:)``
    /// or ``fromEnvironment(_:)`` instead; ``live()`` automatically
    /// dispatches to whichever path the OS supports.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
    public init(reader: ConfigReader, userAgent: String = Configuration.defaultUserAgent) {
        self.host = reader.string(forKey: "gh.host", default: Configuration.defaultHost)
        // GH_TOKEN beats GITHUB_TOKEN to mirror the upstream gh.
        self.token = reader.string(forKey: "gh.token", isSecret: true)
            ?? reader.string(forKey: "github.token", isSecret: true)
        self.userAgent = userAgent
    }

    /// Build from the real process environment.
    ///
    /// On macOS 15+ / iOS 18+ / tvOS 18+ / watchOS 11+ this routes
    /// through `swift-configuration`'s `EnvironmentVariablesProvider`,
    /// which keeps the door open for the planned config-file layer.
    /// On older OSes it falls back to reading
    /// `ProcessInfo.processInfo.environment` directly via
    /// ``fromEnvironment(_:)`` — same env-var precedence
    /// (`GH_HOST`, `GH_TOKEN` beats `GITHUB_TOKEN`), no provider chain.
    public static func live() -> Configuration {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) {
            let reader = ConfigReader(provider: EnvironmentVariablesProvider())
            return Configuration(reader: reader)
        } else {
            // `Sandbox.environment` falls back to the host process env
            // when no sandbox is set, so this matches `ConfigReader`'s
            // ambient behaviour while still going through the
            // `AmbientAPIBanTests`-approved accessor.
            return fromEnvironment(Sandbox.environment)
        }
    }

    /// Test-only: build from a dict of env-style keys (`GH_TOKEN`,
    /// `GH_HOST`, etc.). Behaves exactly like ``live()`` would for
    /// the same env, but doesn't touch the real process environment.
    public static func fromEnvironment(_ env: [String: String]) -> Configuration {
        let host = env["GH_HOST"]?.nilIfEmpty ?? defaultHost
        let token = env["GH_TOKEN"]?.nilIfEmpty
            ?? env["GITHUB_TOKEN"]?.nilIfEmpty
        return Configuration(host: host, token: token)
    }

    /// Resolve the API root for the configured host.
    ///
    /// `github.com` → `https://api.github.com`
    /// `enterprise.example.com` → `https://enterprise.example.com/api/v3`
    public var apiRoot: URL {
        if host == "github.com" || host == "api.github.com" {
            return URL(string: "https://api.github.com")!
        }
        return URL(string: "https://\(host)/api/v3")!
    }

    public var graphQLURL: URL {
        if host == "github.com" || host == "api.github.com" {
            return URL(string: "https://api.github.com/graphql")!
        }
        return URL(string: "https://\(host)/api/graphql")!
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
