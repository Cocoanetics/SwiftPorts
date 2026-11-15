#if !os(Android)
import Foundation
import ShellKit
import SSHKit
import Testing
@testable import SSHKeygenCommand

@Suite("ssh-keygen command")
struct SSHKeygenTests {
    func run(_ argv: [String], input: String = "") async -> (code: Int32, out: String, err: String) {
        let out = OutputSink(), err = OutputSink()
        let code = await SSHKeygenExecutable.run(
            argv: argv, stdin: .string(input), stdout: out, stderr: err, passphrasePrompt: { _ in "pw" })
        out.finish()
        err.finish()
        return (code, await out.readAllString(), await err.readAllString())
    }

    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Keygen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func parser() throws {
        let args = try SSHKeygenArguments.parse(["-qUfkey", "-Ysign", "-ngit", "-Overify-time=20260101", "", "-x"])
        #expect(args.flags == ["q", "U"])
        #expect(args["f"] == "key" && args["Y"] == "sign" && args["n"] == "git")
        #expect(args.options == ["verify-time=20260101"])
        #expect(args.files == ["", "-x"])
    }

    @Test func usageAndMissingArguments() async {
        let bad = await run(["-z"])
        #expect(bad.code == 1 && bad.err.contains("usage: ssh-keygen"))
        let missing = await run(["-Y", "verify"])
        #expect(missing.code == 1 && missing.err == "Too few arguments for verify: missing namespace\n")
        let agent = await run(["-Ysign", "-ngit", "-fkey", "-U"])
        #expect(agent.code == 255 && agent.err == "Couldn't get agent socket\n")
    }

    @Test(arguments: ["", "pw"])
    func generationAndPublicKey(_ password: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("key").path
        let generated = await run(["-q", "-t", "ed25519", "-f", path, "-N", password, "-C", "test comment"])
        #expect(generated.code == 0 && generated.out.isEmpty && generated.err.isEmpty)
        let key = try await IdentityLoader.loadKey(path: path, passphrasePrompt: { _ in password })
        #expect(key.comment == "test comment")
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #if !os(Windows)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #endif
        let printed = await run(["-y", "-f", path])
        #expect(printed.code == 0 && printed.out == key.publicKey.openSSHLine(comment: key.comment) + "\n")
        let fingerprint = await run(["-l", "-f", path + ".pub"])
        #expect(fingerprint.out == "256 \(key.publicKey.sha256Fingerprint) test comment (ED25519)\n")
        let privateFingerprint = await run(["-l", "-f", path])
        #expect(privateFingerprint.out == fingerprint.out)
        let refused = await run(["-q", "-t", "ed25519", "-f", path, "-N", ""], input: "n\n")
        #expect(refused.code == 1 && refused.out == "\(path) already exists.\nOverwrite (y/n)? ")
        let replaced = await run(["-q", "-t", "ed25519", "-f", path, "-N", ""], input: "y\n")
        #expect(replaced.code == 0)
    }

    @Test func signingModes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyPath = root.appendingPathComponent("key").path
        #expect(await run(["-qt", "ed25519", "-f", keyPath, "-N", ""]).code == 0)
        let key = try await IdentityLoader.loadKey(path: keyPath)
        let allowedPath = root.appendingPathComponent("allowed").path
        try ("alice,bob " + key.publicKey.openSSHLine() + "\n")
            .write(toFile: allowedPath, atomically: true, encoding: .utf8)
        let signed = await run(["-Ysign", "-ngit", "-f", keyPath], input: "message")
        #expect(signed.code == 0 && signed.err == "Signing data on standard input\n")
        let sigPath = root.appendingPathComponent("signature").path
        try signed.out.write(toFile: sigPath, atomically: true, encoding: .utf8)
        let base = ["-ngit", "-s", sigPath]
        let good = await run(["-Yverify", "-f", allowedPath, "-Ialice"] + base, input: "message")
        #expect(good.code == 0 && good.err.isEmpty)
        #expect(good.out == "Good \"git\" signature for alice with ED25519 key \(key.publicKey.sha256Fingerprint)\n")
        let bad = await run(["-Yverify", "-f", allowedPath, "-Ialice"] + base, input: "tampered")
        #expect(bad.code == 255 && bad.out == "Could not verify signature.\n")
        let found = await run(["-Yfind-principals", "-f", allowedPath, "-s", sigPath, ""])
        #expect(found.code == 0 && found.out == "alice\nbob\n")
        let unchecked = await run(["-Ycheck-novalidate"] + base, input: "message")
        #expect(unchecked.code == 0 && unchecked.out.hasPrefix("Good \"git\" signature with ED25519 key "))
        let file = root.appendingPathComponent("payload").path
        try "message".write(toFile: file, atomically: true, encoding: .utf8)
        let fileSign = await run(["-Ysign", "-ngit", "-f", keyPath + ".pub", file])
        #expect(fileSign.code == 0 && fileSign.err == "Signing file \(file)\nWrite signature to \(file).sig\n")
        let declined = await run(["-Ysign", "-ngit", "-f", keyPath, file], input: "n\n")
        #expect(declined.code == 0 && declined.out == "\(file).sig already exists.\nOverwrite (y/n)? ")
    }

    @Test func fingerprintsEveryPublicKeyInFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try SSHPrivateKey.generate(type: "ed25519")
        let second = try SSHPrivateKey.generate(type: "ecdsa")
        let path = root.appendingPathComponent("authorized_keys").path
        let contents = """
        # ignored
        not-a-key
        restrict \(first.publicKey.openSSHLine(comment: "first key"))
        example.com \(second.publicKey.openSSHLine(comment: "second key"))

        """
        try contents.write(toFile: path, atomically: true, encoding: .utf8)

        let result = await run(["-l", "-f", path])

        #expect(result.code == 0 && result.err.isEmpty)
        #expect(result.out == """
        256 \(first.publicKey.sha256Fingerprint) first key (ED25519)
        256 \(second.publicKey.sha256Fingerprint) second key (ECDSA)

        """)
    }

    @Test func confinedPathsAndDenials() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mapping = PathMapping(mounts: [.init(virtual: "/workspace", host: root.path)])
        let shell = Shell(environment: Environment(workingDirectory: "/workspace"))
        shell.sandbox = .confined(to: mapping, home: "/workspace")
        await shell.withCurrent {
            let generated = await run(["-qt", "ed25519", "-f/workspace/key", "-N", ""])
            #expect(generated.code == 0)
            let signed = await run(["-Ysign", "-ngit", "-f/workspace/key"], input: "message")
            #expect(signed.code == 0)
            let denied = await run(["-y", "-f/outside/key"])
            #expect(denied.code != 0)
            #expect(!denied.err.contains(root.path))
        }
    }

    @Test func wrongPassphrasePromptsOnce() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("key").path
        #expect(await run(["-qt", "ed25519", "-f", path, "-N", "pw"]).code == 0)
        let out = OutputSink(), err = OutputSink()
        let code = await SSHKeygenExecutable.run(
            argv: ["-y", "-f", path], stdin: .empty, stdout: out, stderr: err,
            passphrasePrompt: { prompt in
                #expect(prompt == "Enter passphrase for \"\(path)\": ")
                return "incorrect"
            })
        out.finish()
        err.finish()
        #expect(code == 255)
        #expect(await err.readAllString()
            == "Load key \"\(path)\": incorrect passphrase supplied to decrypt private key\n")
    }
}
#endif
