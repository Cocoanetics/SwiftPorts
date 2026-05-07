import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct LabelCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new label."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Argument(help: "Label name.") var name: String
    @Option(name: [.short, .customLong("color")],
            help: "Hex color without # (e.g. ff0000).")
    var color: String = "ededed"
    @Option(name: [.short, .customLong("description")])
    var labelDescription: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        struct Body: Codable {
            var name: String
            var color: String
            var description: String?
        }
        let label: Label = try await client.send(
            method: .post,
            path: "repos/\(target.slug)/labels",
            body: Body(name: name, color: color, description: labelDescription))
        Stdio.print("\(ANSI.green("✓")) Created label \(label.name)")
    }
}

struct LabelEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit a label."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Argument(help: "Existing label name.") var name: String
    @Option(name: .customLong("name"), help: "New name.") var newName: String?
    @Option(name: [.short, .customLong("color")]) var color: String?
    @Option(name: [.short, .customLong("description")]) var labelDescription: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        struct Body: Codable {
            var newName: String?
            var color: String?
            var description: String?
            enum CodingKeys: String, CodingKey {
                case newName = "new_name"
                case color, description
            }
        }
        let updated: Label = try await client.send(
            method: .patch,
            path: "repos/\(target.slug)/labels/\(name)",
            body: Body(newName: newName, color: color, description: labelDescription))
        Stdio.print("\(ANSI.green("✓")) Edited label \(updated.name)")
    }
}

struct LabelDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a label."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Argument(help: "Label name.") var name: String
    @Flag(name: [.short, .customLong("yes")]) var skipPrompt: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        if !skipPrompt {
            Stdio.stderr.write(Data("Delete label '\(name)' in \(target.slug)? [y/N] ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else { throw ExitCode(1) }
        }
        let client = try await CommandContext.apiClient()
        try await client.delete("repos/\(target.slug)/labels/\(name)")
        Stdio.print("\(ANSI.green("✓")) Deleted label \(name)")
    }
}
