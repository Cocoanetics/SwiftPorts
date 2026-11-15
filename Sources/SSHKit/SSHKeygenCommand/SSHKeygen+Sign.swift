import Foundation
import ShellKit
import SSHKit

extension SSHKeygenExecutable {
    static func sign(
        _ args: SSHKeygenArguments, stdin: InputSource, stdout: OutputSink, stderr: OutputSink,
        prompt: @escaping PassphrasePrompt
    ) async throws -> Int32 {
        for option in args.options { throw SSHKeygenError("Invalid option \"\(option)\"") }
        if args.files.count > 1, args.files.contains("-") {
            throw SSHKeygenError("Cannot sign mix of paths and standard input")
        }
        if args.flags.contains("U") { throw SSHKeygenError("Couldn't get agent socket") }
        let path = args["f"] ?? ""
        let key = try await loadSigningKey(path, prompt: prompt)
        let files = args.files.isEmpty ? ["-"] : args.files
        for file in files {
            if !args.flags.contains("q") {
                stderr.write(file == "-" ? "Signing data on standard input\n" : "Signing file \(file)\n")
            }
            let data = file == "-" ? await stdin.readAllData() : try await read(file)
            let signature = try SSHSignature(signing: data, namespace: args["n"] ?? "", key: key)
            if file == "-" { stdout.write(signature.armored) }
            else if try await confirmOverwrite(file + ".sig", stdin: stdin, stdout: stdout) {
                try await write(Data(signature.armored.utf8), path: file + ".sig", permissions: 0o644)
                if !args.flags.contains("q") { stderr.write("Write signature to \(file).sig\n") }
            }
        }
        return 0
    }

    static func loadSigningKey(_ path: String, prompt: @escaping PassphrasePrompt) async throws -> SSHPrivateKey {
        // ssh-keygen accepts a public-key pathname and loads its sibling private key without an agent.
        let data = try await read(path)
        var privatePath = path
        if (try? SSHPublicKey(openSSHLine: String(decoding: data, as: UTF8.self))) != nil {
            if path.hasSuffix(".pub") { privatePath = String(path.dropLast(4)) }
        }
        let key = try await loadPrivateKey(privatePath, prompt: prompt)
        if let publicKey = try? SSHPublicKey(openSSHLine: String(decoding: data, as: UTF8.self)),
           publicKey != key.publicKey {
            throw SSHKeygenError("Public key \(path) doesn't match private \(privatePath)")
        }
        return key
    }

    /// ssh-keygen's load_identity prompts once, unlike ssh's three authentication retries.
    static func loadPrivateKey(_ path: String, prompt: @escaping PassphrasePrompt) async throws -> SSHPrivateKey {
        let text = String(decoding: try await read(path), as: UTF8.self)
        do {
            return try SSHPrivateKey(openSSHFile: text)
        } catch is SSHIdentityDecryptionError {
            let passphrase = await prompt("Enter passphrase for \"\(path)\": ") ?? ""
            do { return try SSHPrivateKey(openSSHFile: text, passphrase: passphrase) }
            catch {
                throw SSHKeygenError("Load key \"\(path)\": incorrect passphrase supplied to decrypt private key")
            }
        } catch {
            throw SSHKeygenError("Load key \"\(path)\": invalid format")
        }
    }
}
