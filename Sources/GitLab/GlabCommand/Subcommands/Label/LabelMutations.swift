import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct LabelCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new label in the project."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Label name.")
    var name: String

    @Option(name: [.customShort("c"), .customLong("color")],
            help: "Hex color, with or without leading `#` (e.g. `FF0000`).")
    var color: String = "ededed"

    @Option(name: [.customShort("d"), .customLong("description")],
            help: "Optional description.")
    var labelDescription: String?

    private struct Body: Encodable {
        let name: String
        let color: String
        let description: String?
    }

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let normalized = color.hasPrefix("#") ? color : "#\(color)"
        let label: Label = try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/labels",
            body: Body(name: name, color: normalized, description: labelDescription))
        Stdio.print("Created label \(label.name)")
    }
}

struct LabelDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a label from the project."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Label name.")
    var name: String

    @Flag(name: [.customShort("y"), .customLong("yes")],
          help: "Skip the confirmation prompt.")
    var skipPrompt: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        if !skipPrompt {
            Stdio.stderr.write(
                Data("Delete label '\(name)' in \(target.fullPath)? [y/N] ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else { throw ExitCode(1) }
        }
        let client = try await CommandContext.apiClient(host: target.host)
        let encoded = name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? name
        _ = try await client.raw(
            method: .delete,
            path: "projects/\(target.encodedPath)/labels/\(encoded)")
        Stdio.print("Deleted label \(name)")
    }
}
