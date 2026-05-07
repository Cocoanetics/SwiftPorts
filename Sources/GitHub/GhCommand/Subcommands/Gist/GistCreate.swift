import ArgumentParser
import Foundation
import GitHub
import Sandbox

struct GistCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new gist.",
        discussion: """
        Source files are read from the local disk; the resulting gist's
        files keep their basenames.

        Pipe stdin with --filename FOO to use stdin as content:
          some-command | gh gist create --filename out.txt
        """
    )

    @Argument(help: "Files to include. Pass - to read stdin.")
    var files: [String] = []

    @Option(name: [.short, .customLong("desc")],
            help: "Gist description.")
    var description: String?

    @Flag(name: [.customLong("public")],
          help: "Create a public gist (default: secret).")
    var publicGist: Bool = false

    @Option(name: [.short, .customLong("filename")],
            help: "Filename to use when reading from stdin.")
    var filename: String?

    func run() async throws {
        var contents: [String: GistFileContent] = [:]

        if files == ["-"] || (files.isEmpty && filename != nil) {
            let data = Stdio.stdin.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let name = filename ?? "stdin.txt"
            contents[name] = GistFileContent(content: text)
        } else {
            guard !files.isEmpty else {
                throw ValidationError("Provide at least one file path or pipe via -.")
            }
            for path in files {
                let url = Sandbox.resolve(path)
                try await Sandbox.authorize(url)
                let data = try Data(contentsOf: url)
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                contents[url.lastPathComponent] = GistFileContent(content: text)
            }
        }

        let request = GistCreateRequest(
            description: description, public: publicGist, files: contents)
        let client = try await CommandContext.apiClient()
        let gist: Gist = try await client.send(
            method: .post, path: "gists", body: request)
        let visibility = gist.public ? "public" : "secret"
        Stdio.print("Created \(visibility) gist (\(gist.id))")
        Stdio.print(gist.htmlUrl.absoluteString)
    }
}
