import ArgumentParser
import ShellKit
import Foundation
import GitHub
import ForgeKit
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLError lives here on Linux/Windows
#endif

struct AuthStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "View authentication status."
    )

    @Option(name: [.short, .customLong("hostname")],
            help: "Check a specific hostname (default: github.com or $GH_HOST).")
    var hostname: String?

    @Flag(name: [.short, .customLong("show-token")],
          help: "Print the token in the output. Skipped by default.")
    var showToken: Bool = false

    func run() async throws {
        let config = try await CommandContext.resolveConfig(host: hostname)
        let hostsEntry = (try? HostsFileStore().read())?[config.host]
        let source = TokenSource.detect(
            configToken: config.token, hostsToken: hostsEntry?.oauthToken)

        guard let token = config.token else {
            // Upstream wording: host-specific when --hostname was
            // given, the generic get-started line otherwise.
            let message: String
            if let hostname {
                message = "You are not logged into any accounts on \(hostname)"
            } else {
                message = "You are not logged into any GitHub hosts. To log in, run: \(ANSI.bold("gh auth login"))"
            }
            Shell.current.stderr.write(Data((message + "\n").utf8))
            throw ExitCode(1)
        }

        let sourceLabel = source.ghStatusLabel
        // Upstream trusts the login recorded in hosts.yml for stored
        // tokens and only asks the API when the token came from the
        // environment. The same single GET /user that supplies that
        // fallback also carries the X-OAuth-Scopes header, so the
        // auth probe and the scopes probe can never disagree (#75:
        // a separately-failing scopes probe used to silently drop
        // the "Token scopes:" line).
        var login = sourceLabel.hasSuffix("_TOKEN") ? nil : hostsEntry?.user

        let state: AuthStatusEntry.State
        do {
            let client = APIClient(configuration: config)
            if login != nil {
                // Stored login known — upstream only probes the API
                // root for these (GetScopes) and ignores the body, so
                // app tokens (ghs_…), which can't GET /user, still
                // validate and just render without a scopes line.
                let response = try await client.raw(method: .get, path: "")
                state = .success(scopes: response.oauthScopes)
            } else {
                // No stored login (env tokens, or a stored token with
                // no hosts.yml user): fetch it the way upstream's
                // CurrentLoginName does, from the same response that
                // carries the scopes header. A 200 with no extractable
                // login mirrors upstream's failed login fetch: the
                // entry reports as an error.
                let response = try await client.raw(method: .get, path: "user")
                login = try? JSONDecoder.gitHub()
                    .decode(ProbeLogin.self, from: response.body).login
                state = login == nil ? .invalidToken : .success(scopes: response.oauthScopes)
            }
        } catch {
            state = Self.isTimeout(error) ? .timeout : .invalidToken
        }

        let entry = AuthStatusEntry(
            state: state,
            host: config.host,
            login: login,
            sourceLabel: sourceLabel,
            gitProtocol: hostsEntry?.gitProtocol ?? "https",
            token: showToken ? token : AuthStatusEntry.maskToken(token)
        )

        // Upstream routes the whole listing to stderr when any entry
        // failed, and exits 1.
        if entry.isSuccess {
            Shell.print(ANSI.bold(config.host))
            for line in entry.lines { Shell.print(line) }
        } else {
            var block = ANSI.bold(config.host) + "\n"
            block += entry.lines.joined(separator: "\n") + "\n"
            Shell.current.stderr.write(Data(block.utf8))
            throw ExitCode(1)
        }
    }

    /// Upstream singles out network timeouts for their own entry
    /// state; every other probe failure renders as an invalid token.
    private static func isTimeout(_ error: Error) -> Bool {
        guard case APIError.transport(let underlying) = error else { return false }
        return (underlying as? URLError)?.code == .timedOut
    }
}

/// Minimal slice of the GET /user payload the status probe needs.
private struct ProbeLogin: Decodable {
    let login: String
}
