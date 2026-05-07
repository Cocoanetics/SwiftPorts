import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct VariableList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the project's CI/CD variables."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Flag(name: .customLong("show-values"),
          help: "Print variable values too. Default omits to avoid leaking secrets.")
    var showValues: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let variables: [Variable] = try await client.get(
            "projects/\(target.encodedPath)/variables",
            query: [URLQueryItem(name: "per_page", value: "100")])
        if variables.isEmpty { Stdio.print("No variables."); return }
        for v in variables {
            // `key  scope  protected/masked  value?` — value omitted by
            // default since GitLab returns the cleartext.
            var line = "\(v.key)\t\(v.environmentScope ?? "*")"
            var flags: [String] = []
            if v.protected == true { flags.append("protected") }
            if v.masked == true { flags.append("masked") }
            if !flags.isEmpty { line += "\t[\(flags.joined(separator: ","))]" }
            if showValues { line += "\t\(v.value)" }
            Stdio.print(line)
        }
    }
}
