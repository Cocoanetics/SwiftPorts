import Foundation
import ShellKit
import SSHKit

public enum SSHKeygenExecutable {
    public typealias PassphrasePrompt = @Sendable (String) async -> String?

    @discardableResult
    public static func run(
        argv: [String], stdin: InputSource, stdout: OutputSink, stderr: OutputSink,
        passphrasePrompt: @escaping PassphrasePrompt = { await SSHPassphrasePrompt.readFromTTY(prompt: $0) }
    ) async -> Int32 {
        let args: SSHKeygenArguments
        do { args = try SSHKeygenArguments.parse(argv) }
        catch {
            stderr.write("\(error)\n" + usage)
            return 1
        }
        if let mode = args["Y"] {
            if let missing = missingArgument(args, mode: mode) {
                stderr.write("Too few arguments for \(missing.0): missing \(missing.1)\n")
                return 1
            }
            guard ["sign", "verify", "find-principals", "check-novalidate"].contains(mode) else {
                stderr.write("Unsupported operation for -Y: \"\(mode)\"\n" + usage)
                return 1
            }
            do {
                if mode == "sign" {
                    return try await sign(args, stdin: stdin, stdout: stdout, stderr: stderr, prompt: passphrasePrompt)
                }
                return try await verify(args, mode: mode, stdin: stdin, stdout: stdout, stderr: stderr)
            } catch {
                stderr.write("\(error)\n")
                if mode == "verify" || mode == "check-novalidate" {
                    if !args.flags.contains("q") { stdout.write("Could not verify signature.\n") }
                } else if mode == "find-principals" { stderr.write("No principal matched.\n") }
                return 255
            }
        }
        do {
            if args.flags.contains("y") || args.flags.contains("l") {
                return try await publicKey(args, stdin: stdin, stdout: stdout, prompt: passphrasePrompt)
            }
            return try await generate(args, stdin: stdin, stdout: stdout, stderr: stderr, prompt: passphrasePrompt)
        } catch {
            stderr.write("\(error)\n")
            return args.flags.contains("y") ? 255 : 1
        }
    }

    static func missingArgument(_ args: SSHKeygenArguments, mode: String) -> (String, String)? {
        if ["sign", "verify", "check-novalidate"].contains(mode), (args["n"] ?? "").isEmpty {
            return (mode, "namespace")
        }
        if ["verify", "find-principals", "check-novalidate"].contains(mode), args["s"] == nil {
            return (mode, "signature file")
        }
        if mode == "sign", args["f"] == nil { return (mode, "key") }
        if ["verify", "find-principals"].contains(mode), args["f"] == nil {
            return (mode == "verify" ? "sign" : mode, "allowed keys file")
        }
        if mode == "verify", args["I"] == nil { return (mode, "principal identity") }
        return nil
    }

    static func read(_ path: String) async throws -> Data {
        let url = Shell.resolve(path)
        try await Shell.authorize(url)
        do { return try Data(contentsOf: url) }
        catch { throw SSHKeygenError("\(path): \(fileReason(error))") }
    }

    static func write(_ data: Data, path: String, permissions: Int) async throws {
        let url = Shell.resolve(path)
        try await Shell.authorize(url)
        do {
            // Create with the final mode before writing any secret material.
            guard FileManager.default.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: permissions]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            try data.write(to: url)
        } catch { throw SSHKeygenError("\(path): \(fileReason(error))") }
    }

    static func confirmOverwrite(_ path: String, stdin: InputSource, stdout: OutputSink) async throws -> Bool {
        let url = Shell.resolve(path)
        try await Shell.authorize(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        stdout.write("\(path) already exists.\nOverwrite (y/n)? ")
        let response = await stdin.readLine() ?? ""
        return response.hasPrefix("y") || response.hasPrefix("Y")
    }

    static func fileReason(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return "No such file or directory"
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return "Permission denied"
            default: break
            }
        }
        return "\(error)"
    }

    static let usage = """
    usage: ssh-keygen [-q] [-b bits] [-C comment] [-f output_keyfile]
                      [-N new_passphrase] [-t ecdsa | ed25519]
           ssh-keygen -l [-f input_keyfile]
           ssh-keygen -y [-f input_keyfile]
           ssh-keygen -Y find-principals -s signature_file -f allowed_signers_file
           ssh-keygen -Y check-novalidate -n namespace -s signature_file
           ssh-keygen -Y sign -f key_file -n namespace file ...
           ssh-keygen -Y verify -f allowed_signers_file -I signer_identity
                      -n namespace -s signature_file [-r revocation_file]

    """
}
