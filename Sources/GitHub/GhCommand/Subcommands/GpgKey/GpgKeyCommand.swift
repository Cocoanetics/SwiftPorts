import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct GpgKeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gpg-key",
        abstract: "Manage your GPG keys.",
        subcommands: [GpgKeyList.self, GpgKeyAdd.self, GpgKeyDelete.self]
    )
}

struct GpgKeyList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List your GPG keys."
    )

    func run() async throws {
        let client = try await CommandContext.apiClient()
        let keys: [GPGKey] = try await client.get("user/gpg_keys")
        if keys.isEmpty { Stdio.print("No GPG keys."); return }
        for k in keys {
            let when = k.createdAt.map(ISO8601DateFormatter().string(from:)) ?? "?"
            let emails = k.emails?.map(\.email).joined(separator: ", ") ?? ""
            Stdio.print("\(k.id)\t\(k.keyId)\t\(when)\t\(emails)")
        }
    }
}

struct GpgKeyAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a GPG key to your account."
    )

    @Argument(help: "Path to ASCII-armored GPG public key (or - for stdin).")
    var path: String

    func run() async throws {
        let key: String
        if path == "-" {
            let data = Stdio.stdin.readDataToEndOfFile()
            key = String(data: data, encoding: .utf8) ?? ""
        } else {
            key = try String(contentsOfFile: path, encoding: .utf8)
        }
        guard !key.isEmpty else { throw ValidationError("Empty key.") }
        let client = try await CommandContext.apiClient()
        struct Body: Codable { var armoredPublicKey: String }
        let added: GPGKey = try await client.send(
            method: .post,
            path: "user/gpg_keys",
            body: Body(armoredPublicKey: key))
        Stdio.print("\(ANSI.green("✓")) Added GPG key #\(added.id)")
    }
}

struct GpgKeyDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a GPG key from your account."
    )

    @Argument(help: "Key ID (from `gh gpg-key list`).")
    var id: Int

    @Flag(name: [.short, .customLong("yes")], help: "Skip confirmation.")
    var skipPrompt: Bool = false

    func run() async throws {
        if !skipPrompt {
            Stdio.stderr.write(Data("Delete GPG key #\(id)? [y/N] ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else { throw ExitCode(1) }
        }
        let client = try await CommandContext.apiClient()
        try await client.delete("user/gpg_keys/\(id)")
        Stdio.print("\(ANSI.green("✓")) Deleted GPG key #\(id)")
    }
}
