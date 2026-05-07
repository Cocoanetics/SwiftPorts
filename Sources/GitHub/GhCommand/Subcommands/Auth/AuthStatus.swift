import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

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
        let hostsToken = (try? HostsFileStore().read())?[config.host]?.oauthToken
        let source = TokenSource.detect(
            configToken: config.token, hostsToken: hostsToken)

        Stdio.print("\(config.host)")

        guard let token = config.token else {
            Stdio.print("  \(ANSI.red("✗")) Not logged in. Run `gh auth login` or set GH_TOKEN.")
            throw ExitCode(1)
        }

        let client = GraphQLClient(configuration: config)
        // Use REST /user too, just for the X-OAuth-Scopes header.
        let restClient = APIClient(configuration: config)
        do {
            let result: ViewerQuery = try await client.query(ViewerQuery.query)
            Stdio.print("  \(ANSI.green("✓")) Logged in to \(ANSI.bold(config.host)) as \(ANSI.bold(result.viewer.login)) \(ANSI.dim("(token from \(source.humanReadable))"))")
            Stdio.print("    URL: \(result.viewer.url.absoluteString)")
            if let scopesResponse = try? await restClient.raw(method: .get, path: "user"),
               let scopes = scopesResponse.oauthScopes {
                let label = scopes.isEmpty ? "(none)" : scopes.joined(separator: ", ")
                Stdio.print("    Token scopes: \(label)")
            }
            if showToken {
                Stdio.print("    Token: \(token)")
            } else {
                Stdio.print("    Token: \(ANSI.dim(redact(token)))")
            }
        } catch let APIError.unauthenticated(url) {
            Stdio.print("  \(ANSI.red("✗")) Token rejected by \(url.absoluteString) (HTTP 401).")
            Stdio.print("    Source: \(source.humanReadable)")
            throw ExitCode(1)
        } catch {
            Stdio.print("  \(ANSI.red("✗")) Auth probe failed: \(error.localizedDescription)")
            throw ExitCode(1)
        }
    }

    private func redact(_ token: String) -> String {
        guard token.count > 8 else { return String(repeating: "*", count: token.count) }
        let prefix = token.prefix(4)
        return "\(prefix)" + String(repeating: "*", count: token.count - 4)
    }
}
