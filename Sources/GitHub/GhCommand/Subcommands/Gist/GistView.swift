import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct GistView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "View a gist."
    )

    @Argument(help: "Gist ID.")
    var id: String

    @Option(name: .customLong("filename"),
            help: "Print just one file from the gist.")
    var filename: String?

    func run() async throws {
        let client = try await CommandContext.apiClient()
        let gist: Gist = try await client.get("gists/\(id)")

        if let filename {
            guard let file = gist.files[filename] else {
                throw ValidationError("Gist has no file '\(filename)'.")
            }
            if let content = file.content { Stdio.print(content) }
            return
        }
        Stdio.print("\(gist.id)  \(gist.description ?? "")")
        if let owner = gist.owner ?? gist.user {
            Stdio.print("author: @\(owner.login)")
        }
        Stdio.print("html: \(gist.htmlUrl.absoluteString)")
        for (name, file) in gist.files.sorted(by: { $0.key < $1.key }) {
            Stdio.print("\n# \(name) (\(file.language ?? file.type))")
            if let content = file.content {
                Stdio.print(content)
            } else {
                Stdio.print("[truncated, fetch raw at \(file.rawUrl.absoluteString)]")
            }
        }
    }
}
