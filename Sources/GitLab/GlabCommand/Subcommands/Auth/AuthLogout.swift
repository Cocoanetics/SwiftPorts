import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct AuthLogout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Remove a saved token from the keychain."
    )

    @Option(name: [.short, .customLong("hostname")],
            help: "Host to log out of (default: gitlab.com).")
    var hostname: String?

    func run() async throws {
        let host = hostname ?? Configuration.defaultHost
        try await CommandContext.resolver.remove(host: host)
        Stdio.print("\(ANSI.green("✓")) Removed token for \(host) from the keychain.")
        Stdio.print(ANSI.dim("(Env vars GITLAB_TOKEN / GITLAB_ACCESS_TOKEN / OAUTH_TOKEN, if set, still take precedence.)"))
    }
}
