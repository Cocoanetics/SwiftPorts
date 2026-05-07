import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct AuthStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "View authentication status."
    )

    @Option(name: [.short, .customLong("hostname")],
            help: "Check a specific hostname (default: gitlab.com or $GITLAB_HOST).")
    var hostname: String?

    @Flag(name: [.short, .customLong("show-token")],
          help: "Print the token in the output. Skipped by default.")
    var showToken: Bool = false

    func run() async throws {
        let config = try await CommandContext.resolveConfig(host: hostname)
        let source = TokenSource.detect(configToken: config.token)

        Stdio.print("\(config.host)")

        guard let token = config.token else {
            Stdio.print("  \(ANSI.red("✗")) Not logged in. Run `glab auth login` or set GITLAB_TOKEN.")
            throw ExitCode(1)
        }

        let client = APIClient(configuration: config)
        do {
            let user: User = try await client.get("user")
            Stdio.print("  \(ANSI.green("✓")) Logged in to \(ANSI.bold(config.host)) as \(ANSI.bold(user.username)) \(ANSI.dim("(token from \(source.humanReadable))"))")
            if let webUrl = user.webUrl {
                Stdio.print("    URL: \(webUrl.absoluteString)")
            }
            if showToken {
                Stdio.print("    Token: \(token)")
            } else {
                Stdio.print("    Token: \(ANSI.dim(redact(token)))")
            }
        } catch APIError.unauthenticated(let url) {
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
