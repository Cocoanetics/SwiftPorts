import Foundation
import ShellKit
import SSHKit

extension SSHKeygenExecutable {
    static func generate(
        _ args: SSHKeygenArguments, stdin: InputSource, stdout: OutputSink, stderr: OutputSink,
        prompt: @escaping PassphrasePrompt
    ) async throws -> Int32 {
        guard args.files.isEmpty, args.options.isEmpty, args.flags.isSubset(of: ["q"]),
              args.values.keys.allSatisfy({ "tbfNC".contains($0) }) else { stderr.write(usage); return 1 }
        let type = args["t"] ?? "ed25519"
        guard ["ed25519", "ecdsa"].contains(type) else {
            throw SSHKeygenError("unknown key type \(type)")
        }
        let bits: Int
        if let text = args["b"] {
            guard let parsed = Int(text), parsed > 0 else { throw SSHKeygenError("Bits has bad value \(text)") }
            bits = parsed
        } else { bits = 256 }
        let quiet = args.flags.contains("q")
        if !quiet { stdout.write("Generating public/private \(type) key pair.\n") }
        let shell = Shell.current
        let defaultPath = (shell.environment["HOME"] ?? "") + "/.ssh/id_" + type
        var path = args["f"] ?? ""
        if args["f"] == nil {
            stdout.write("Enter file in which to save the key (\(defaultPath)): ")
            path = await stdin.readLine() ?? ""
            if path.isEmpty { path = defaultPath }
        }
        if path == defaultPath {
            let directory = Shell.resolve(path).deletingLastPathComponent()
            try await Shell.authorize(directory)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if !quiet { stderr.write("Created directory '\(shell.displayPath(for: directory))'.\n") }
            }
        }
        guard try await confirmOverwrite(path, stdin: stdin, stdout: stdout) else { return 1 }
        let passphrase: String
        if let provided = args["N"] { passphrase = provided }
        else {
            guard let entered = await generationPassphrase(path, stdout: stdout, prompt: prompt) else { return 1 }
            passphrase = entered
        }
        let comment = args["C"] ?? "\(shell.hostInfo.userName)@\(ProcessInfo.processInfo.hostName)"
        let key = try SSHPrivateKey.generate(type: type, bits: bits, comment: comment)
        let privateFile = try key.openSSHFile(passphrase: passphrase)
        try await write(Data(privateFile.utf8), path: path, permissions: 0o600)
        if !quiet { stdout.write("Your identification has been saved in \(path)\n") }
        try await write(Data((key.publicKey.openSSHLine(comment: comment) + "\n").utf8),
                        path: path + ".pub", permissions: 0o644)
        if !quiet {
            stdout.write("Your public key has been saved in \(path).pub\nThe key fingerprint is:\n"
                + "\(key.publicKey.sha256Fingerprint) \(comment)\nThe key's randomart image is:\n"
                + "\(key.publicKey.randomArt)\n")
        }
        return 0
    }

    static func generationPassphrase(
        _ path: String, stdout: OutputSink, prompt: @escaping PassphrasePrompt
    ) async -> String? {
        while true {
            guard let first = await prompt("Enter passphrase for \"\(path)\" (empty for no passphrase): "),
                  let second = await prompt("Enter same passphrase again: ") else { return nil }
            if first == second { return first }
            stdout.write("Passphrases do not match.  Try again.\n")
        }
    }
}
