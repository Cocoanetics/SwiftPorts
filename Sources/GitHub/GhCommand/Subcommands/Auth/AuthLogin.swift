import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct AuthLogin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Authenticate with GitHub.",
        discussion: """
        Runs the OAuth device flow (no browser launch, no localhost
        listener) and stashes the resulting token in the system
        secret store (Keychain on Apple platforms).

        Alternatively, use --with-token to pipe a personal access
        token directly:

          echo $MY_TOKEN | gh auth login --with-token
        """
    )

    @Option(name: [.short, .customLong("hostname")],
            help: "GitHub host. Defaults to github.com.")
    var hostname: String = Configuration.defaultHost

    @Option(name: [.short, .customLong("scopes")],
            parsing: .singleValue,
            help: "Additional OAuth scopes to request; repeatable.")
    var extraScopes: [String] = []

    @Flag(name: .customLong("with-token"),
          help: "Read a personal access token from stdin.")
    var withToken: Bool = false

    @Option(name: .customLong("client-id"),
            help: "OAuth app client ID. Defaults to the upstream gh app.")
    var clientID: String = OAuthDeviceFlow.ghCLIClientID

    @Flag(name: [.short, .customLong("force")],
          help: "Overwrite an existing token for the host.")
    var force: Bool = false

    @Flag(name: [.short, .customLong("web")],
          help: "Open the verification URL automatically after printing the code.")
    var openInBrowser: Bool = false

    @Flag(name: [.customShort("c"), .customLong("clipboard")],
          help: "Copy the user code to the clipboard.")
    var copyToClipboard: Bool = false

    func run() async throws {
        let resolver = ConfigurationResolver()

        // Refuse to clobber an existing token unless --force.
        if !force {
            let existing = try await CommandContext.resolveConfig(host: hostname)
            if existing.token != nil {
                let source = TokenSource.detect(configToken: existing.token)
                Stdio.print("Already logged in to \(hostname) (token from \(source.humanReadable)). " +
                      "Use --force to overwrite.")
                throw ExitCode(0)
            }
        }

        let token: String
        if withToken {
            token = try readTokenFromStdin()
        } else {
            token = try await runDeviceFlow()
        }

        // Verify the token actually works before stashing.
        let probeConfig = Configuration(host: hostname, token: token)
        let client = GraphQLClient(configuration: probeConfig)
        do {
            let result: ViewerQuery = try await client.query(ViewerQuery.query)
            Stdio.print("✓ Authenticated as \(result.viewer.login).")
        } catch {
            Stdio.stderr.write(Data(
                "Token validation failed: \(error.localizedDescription)\n".utf8))
            throw ExitCode(1)
        }

        try await resolver.store(token: token, host: hostname)
        Stdio.print("✓ Token saved to secret store for \(hostname).")
    }

    private func runDeviceFlow() async throws -> String {
        let scopes = (["repo", "read:org", "gist"] + extraScopes).deduplicated()
        let flow = OAuthDeviceFlow(clientID: clientID, host: hostname)
        let openInBrowser = self.openInBrowser
        let copyToClipboard = self.copyToClipboard
        Stdio.print("Starting device-code flow against \(hostname)…")
        let token = try await flow.authorize(scopes: scopes) { code in
            Stdio.print("")
            if copyToClipboard {
                do {
                    try await Clipboard.write(code.userCode)
                    Stdio.print("! One-time code (\(ANSI.bold(code.userCode))) copied to clipboard.")
                } catch {
                    Stdio.print("! \(ANSI.yellow("Couldn't copy to clipboard: \(error.localizedDescription)"))")
                    Stdio.print("! First copy your one-time code: \(ANSI.bold(code.userCode))")
                }
            } else {
                Stdio.print("! First copy your one-time code: \(ANSI.bold(code.userCode))")
            }
            if openInBrowser {
                Stdio.print("! Opening \(code.verificationUri.absoluteString) in your browser…")
                do {
                    try await Browser.open(code.verificationUri)
                } catch {
                    Stdio.print("! \(ANSI.yellow("Couldn't open the browser: \(error.localizedDescription)"))")
                    Stdio.print("! Open this URL in any browser: \(code.verificationUri.absoluteString)")
                }
            } else {
                Stdio.print("! Open this URL in any browser: \(code.verificationUri.absoluteString)")
            }
            Stdio.print("  (waiting for authorization; codes expire in \(code.expiresIn / 60) min)")
            Stdio.print("")
        }
        return token.accessToken
    }

    private func readTokenFromStdin() throws -> String {
        let data = Stdio.stdin.readDataToEndOfFile()
        let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw ValidationError("--with-token: empty stdin")
        }
        return token
    }
}

private extension Array where Element == String {
    func deduplicated() -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for s in self where seen.insert(s).inserted {
            result.append(s)
        }
        return result
    }
}
