import Foundation
import ForgeKit

/// One account's worth of `gh auth status` output, mirroring upstream's
/// `authEntry` and its renderer (`pkg/cmd/auth/status/status.go`). The
/// port's single-account model renders exactly one entry per host.
struct AuthStatusEntry {
    enum State {
        /// Probe succeeded; `scopes` is the parsed `X-OAuth-Scopes`
        /// header (`nil` when GitHub sent none).
        case success(scopes: [String]?)
        /// Probe failed. Upstream renders every non-timeout probe
        /// failure as "The token in <source> is invalid." — even
        /// rate limits — so the port does too.
        case invalidToken
        case timeout
    }

    var state: State
    var host: String
    /// Account name; `nil` renders the "using token (<source>)" header
    /// variant upstream uses for env tokens whose login fetch failed.
    var login: String?
    /// Upstream's token-source column: "keyring", "GH_TOKEN",
    /// "GITHUB_TOKEN", or the hosts.yml path.
    var sourceLabel: String
    var gitProtocol: String
    /// Token as it should appear — already masked unless `--show-token`.
    var token: String

    var isSuccess: Bool {
        if case .success = state { return true }
        return false
    }

    /// Upstream `authTokenWriteable`: env-var tokens can't be replaced
    /// by `gh auth login`, so the re-auth hints are omitted for them.
    var sourceIsWriteable: Bool { !sourceLabel.hasSuffix("_TOKEN") }

    /// The rendered lines, exactly as upstream's `authEntry.String(cs)`
    /// lays them out (minus the trailing newline handling).
    var lines: [String] {
        switch state {
        case .success(let scopes):
            var out = [
                "  \(ANSI.green("✓")) Logged in to \(host) account \(ANSI.bold(login ?? "")) (\(sourceLabel))",
                "  - Active account: \(ANSI.bold("true"))",
                "  - Git operations protocol: \(ANSI.bold(gitProtocol))",
                "  - Token: \(ANSI.bold(token))",
            ]
            // Upstream only expects the scopes header on classic OAuth
            // tokens; fine-grained PATs / app tokens get no line at all.
            if Self.expectScopes(token) {
                out.append("  - Token scopes: \(ANSI.bold(Self.displayScopes(scopes)))")
            }
            return out

        case .invalidToken:
            var out = [failureHeader(verb: "Failed to log in to")]
            out.append("  - Active account: \(ANSI.bold("true"))")
            out.append("  - The token in \(sourceLabel) is invalid.")
            if sourceIsWriteable {
                out.append("  - To re-authenticate, run: \(ANSI.bold("gh auth login -h \(host)"))")
                if let login {
                    out.append("  - To forget about this account, run: \(ANSI.bold("gh auth logout -h \(host) -u \(login)"))")
                }
            }
            return out

        case .timeout:
            return [
                failureHeader(verb: "Timeout trying to log in to"),
                "  - Active account: \(ANSI.bold("true"))",
            ]
        }
    }

    private func failureHeader(verb: String) -> String {
        if let login {
            return "  \(ANSI.red("X")) \(verb) \(host) account \(ANSI.bold(login)) (\(sourceLabel))"
        }
        return "  \(ANSI.red("X")) \(verb) \(host) using token (\(sourceLabel))"
    }

    /// Upstream `maskToken`: keep everything through the last `_`
    /// (the token-type prefix), star the rest, length-preserving.
    static func maskToken(_ token: String) -> String {
        guard let idx = token.lastIndex(of: "_") else {
            return String(repeating: "*", count: token.count)
        }
        let prefix = token[...idx]
        return prefix + String(repeating: "*", count: token.distance(from: token.index(after: idx), to: token.endIndex))
    }

    /// Upstream `displayScopes`: `'repo', 'gist'`, or "none" when the
    /// header was empty or absent.
    static func displayScopes(_ scopes: [String]?) -> String {
        guard let scopes, !scopes.isEmpty else { return "none" }
        return scopes.map { "'\($0)'" }.joined(separator: ", ")
    }

    /// Upstream `expectScopes`: only classic OAuth/PAT prefixes carry
    /// the `X-OAuth-Scopes` header. Works on masked tokens too, since
    /// masking preserves the prefix through the underscore.
    static func expectScopes(_ token: String) -> Bool {
        token.hasPrefix("ghp_") || token.hasPrefix("gho_")
    }
}
