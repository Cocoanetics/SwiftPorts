import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct SshKeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh-key",
        abstract: "Manage your SSH keys.",
        subcommands: [SshKeyList.self, SshKeyAdd.self, SshKeyDelete.self]
    )
}

struct SshKeyList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List your SSH keys."
    )

    func run() async throws {
        let client = try await CommandContext.apiClient()
        let keys: [SSHKey] = try await client.get("user/keys")
        if keys.isEmpty { Stdio.print("No SSH keys."); return }
        for k in keys {
            let when = k.createdAt.map(ISO8601DateFormatter().string(from:)) ?? "?"
            // Show the key fingerprint-ish prefix; full key bodies are noisy.
            let preview = k.key.prefix(40)
            Stdio.print("\(k.id)\t\(k.title ?? "")\t\(when)\t\(preview)…")
        }
    }
}

struct SshKeyAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add an SSH key to your account.",
        discussion: "Pass the path to a public key (.pub) file, or use - for stdin."
    )

    @Argument(help: "Path to .pub file (or - for stdin).")
    var path: String

    @Option(name: [.short, .customLong("title")], help: "Key title.")
    var title: String?

    func run() async throws {
        let key: String
        if path == "-" {
            let data = Stdio.stdin.readDataToEndOfFile()
            key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else {
            key = try String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !key.isEmpty else { throw ValidationError("Empty key.") }
        let client = try await CommandContext.apiClient()
        struct Body: Codable { var title: String?; var key: String }
        let added: SSHKey = try await client.send(
            method: .post,
            path: "user/keys",
            body: Body(title: title, key: key))
        Stdio.print("\(ANSI.green("✓")) Added SSH key #\(added.id)")
    }
}

struct SshKeyDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an SSH key from your account."
    )

    @Argument(help: "Key ID (from `gh ssh-key list`).")
    var id: Int

    @Flag(name: [.short, .customLong("yes")], help: "Skip confirmation.")
    var skipPrompt: Bool = false

    func run() async throws {
        if !skipPrompt {
            Stdio.stderr.write(Data("Delete SSH key #\(id)? [y/N] ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else { throw ExitCode(1) }
        }
        let client = try await CommandContext.apiClient()
        try await client.delete("user/keys/\(id)")
        Stdio.print("\(ANSI.green("✓")) Deleted SSH key #\(id)")
    }
}
