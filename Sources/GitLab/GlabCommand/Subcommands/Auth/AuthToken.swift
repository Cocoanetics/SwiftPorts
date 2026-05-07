import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct AuthToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Print the resolved access token for a host."
    )

    @Option(name: [.short, .customLong("hostname")],
            help: "Host (default: gitlab.com).")
    var hostname: String?

    func run() async throws {
        let config = try await CommandContext.resolveConfig(host: hostname)
        guard let token = config.token, !token.isEmpty else {
            throw AuthTokenError.notLoggedIn(config.host)
        }
        Stdio.print(token)
    }
}

enum AuthTokenError: Error, LocalizedError {
    case notLoggedIn(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let host):
            return "No token available for \(host). Run `glab auth login` or set GITLAB_TOKEN."
        }
    }
}
