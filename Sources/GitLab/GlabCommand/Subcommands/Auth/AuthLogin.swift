import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct AuthLogin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Authenticate glab with a Personal Access Token.",
        discussion: """
            This port supports PAT-based login only — paste a token created
            at <https://gitlab.com/-/user_settings/personal_access_tokens>
            (or the equivalent on your self-hosted instance). Tokens go
            into the system keychain.

            OAuth device-flow / web-callback login from upstream `glab`
            isn't available here; create a PAT and paste it instead.

            Pipe a token in non-interactively:
                echo $TOKEN | glab auth login --hostname self.example.com --with-token
            """
    )

    @Option(name: [.short, .customLong("hostname")],
            help: "Host to authenticate against (default: gitlab.com).")
    var hostname: String?

    @Flag(name: .customLong("with-token"),
          help: "Read the token from stdin instead of prompting interactively.")
    var withToken: Bool = false

    func run() async throws {
        let host = hostname ?? Configuration.defaultHost

        let token: String
        if withToken {
            guard let line = readLine(strippingNewline: true)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty
            else {
                throw AuthLoginError.missingToken
            }
            token = line
        } else {
            Stdio.print("Paste your Personal Access Token for \(ANSI.bold(host))")
            Stdio.print("(create one at https://\(host)/-/user_settings/personal_access_tokens)")
            Stdio.print("Token: ", terminator: "")
            guard let line = readLine(strippingNewline: true)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty
            else {
                throw AuthLoginError.missingToken
            }
            token = line
        }

        let probeConfig = Configuration(host: host, token: token)
        let client = APIClient(configuration: probeConfig)
        do {
            let user: User = try await client.get("user")
            try await CommandContext.resolver.store(token: token, host: host)
            Stdio.print("\(ANSI.green("✓")) Logged in to \(ANSI.bold(host)) as \(ANSI.bold(user.username))")
            Stdio.print("Token saved to the system keychain.")
        } catch APIError.unauthenticated {
            throw AuthLoginError.tokenRejected(host)
        }
    }
}

enum AuthLoginError: Error, LocalizedError {
    case missingToken
    case tokenRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No token provided."
        case .tokenRejected(let host):
            return "\(host) rejected the token (HTTP 401). Create a fresh PAT and try again."
        }
    }
}
