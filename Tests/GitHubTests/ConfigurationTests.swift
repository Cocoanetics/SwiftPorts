import Configuration
import Foundation
import Testing
@testable import GitHub

@Suite struct ConfigurationTests {
    @Test func defaultsToGithubCom() {
        let config = Configuration.fromEnvironment([:])
        #expect(config.host == "github.com")
        #expect(config.token == nil)
        #expect(config.apiRoot.absoluteString == "https://api.github.com")
        #expect(config.graphQLURL.absoluteString == "https://api.github.com/graphql")
    }

    @Test func picksUpGHToken() {
        let config = Configuration.fromEnvironment(["GH_TOKEN": "abc123"])
        #expect(config.token == "abc123")
    }

    @Test func ghTokenWinsOverGithubToken() {
        let config = Configuration.fromEnvironment([
            "GH_TOKEN": "primary",
            "GITHUB_TOKEN": "fallback",
        ])
        #expect(config.token == "primary")
    }

    @Test func fallsBackToGithubToken() {
        let config = Configuration.fromEnvironment([
            "GITHUB_TOKEN": "fallback",
        ])
        #expect(config.token == "fallback")
    }

    @Test func enterpriseHostRewritesAPIRoot() {
        let config = Configuration.fromEnvironment([
            "GH_HOST": "github.example.internal",
        ])
        #expect(config.host == "github.example.internal")
        #expect(config.apiRoot.absoluteString ==
                "https://github.example.internal/api/v3")
        #expect(config.graphQLURL.absoluteString ==
                "https://github.example.internal/api/graphql")
    }

    @Test func ignoresEmptyEnvVars() {
        let config = Configuration.fromEnvironment([
            "GH_HOST": "",
            "GH_TOKEN": "",
        ])
        #expect(config.host == "github.com")
        #expect(config.token == nil)
    }

    // The three `ConfigReader`-based tests below exercise the
    // `swift-configuration` provider chain. `ConfigReader`,
    // `InMemoryProvider`, `AbsoluteConfigKey`, etc. are gated to
    // macOS 15+ / iOS 18+ — same gate as the `Configuration.init(reader:)`
    // initializer they exercise. The env-only tests above cover the
    // same precedence rules without the platform constraint.

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
    @Test func buildsFromConfigReader() {
        // Mirrors the live() path: the same dotted keys
        // EnvironmentVariablesProvider would expose for GH_HOST / GH_TOKEN.
        let provider = InMemoryProvider(values: [
            "gh.host": "ghe.example.com",
            "gh.token": "secret-token",
        ])
        let reader = ConfigReader(provider: provider)
        let config = Configuration(reader: reader)

        #expect(config.host == "ghe.example.com")
        #expect(config.token == "secret-token")
        #expect(config.apiRoot.absoluteString == "https://ghe.example.com/api/v3")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
    @Test func githubTokenFallsBackThroughConfigReader() {
        let provider = InMemoryProvider(values: [
            "github.token": "fallback",
        ])
        let reader = ConfigReader(provider: provider)
        let config = Configuration(reader: reader)
        #expect(config.token == "fallback")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
    @Test func ghTokenWinsOverGithubTokenInConfigReader() {
        let provider = InMemoryProvider(values: [
            "gh.token": "primary",
            "github.token": "fallback",
        ])
        let reader = ConfigReader(provider: provider)
        let config = Configuration(reader: reader)
        #expect(config.token == "primary")
    }
}
