#if os(macOS) || os(Linux)
import Foundation
import ShellKit
import SSHKit
import Testing

@Suite("ssh-keygen system OpenSSH parity",
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")))
struct SSHKeygenParityTests {
    private let command = SSHKeygenTests()

    @discardableResult
    private func system(_ argv: [String], executable: String = "ssh-keygen", in root: URL,
                        input: String = "") throws -> (code: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/" + executable)
        process.arguments = argv
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path,
                               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    @Test(arguments: ["ed25519", "ecdsa256", "ecdsa384", "ecdsa521"])
    func keysAndSignatures(_ type: String) async throws {
        let root = try command.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("key").path
        for password in ["", "pw"] {
            let generated = await command.run([
                "-t", type == "ed25519" ? type : "ecdsa", "-b", String(Int(type.dropFirst(5)) ?? 256),
                "-f", path, "-N", password, "-C", "test"], input: "y\n")
            #expect(generated.code == 0)
            let publicLine = try system(["-y", "-P", password, "-f", path], in: root)
            #expect(publicLine.code == 0)
            let oursPublic = await command.run(["-y", "-f", path])
            #expect(oursPublic.out == publicLine.out)
            let fingerprint = try system(["-l", "-f", path + ".pub"], in: root)
            #expect(await command.run(["-l", "-f", path + ".pub"]).out == fingerprint.out)
            let verbose = try system(["-lv", "-f", path + ".pub"], in: root)
            let key = try await IdentityLoader.loadKey(path: path, passphrasePrompt: { _ in password })
            #expect(verbose.out.hasSuffix(key.publicKey.randomArt + "\n"))
        }
        let allowed = root.appendingPathComponent("allowed").path
        let key = try await IdentityLoader.loadKey(path: path, passphrasePrompt: { _ in "pw" })
        try ("alice " + key.publicKey.openSSHLine() + "\n")
            .write(toFile: allowed, atomically: true, encoding: .utf8)
        let ours = await command.run(["-Ysign", "-ngit", "-f", path], input: "payload\n")
        let signature = root.appendingPathComponent("signature").path
        try ours.out.write(toFile: signature, atomically: true, encoding: .utf8)
        let verified = try system(["-Yverify", "-ngit", "-f", allowed, "-Ialice", "-s", signature],
                                  in: root, input: "payload\n")
        #expect(verified.code == 0)
        // Use the same key unencrypted for the oracle, so it never needs a terminal.
        try key.openSSHFile().write(toFile: path, atomically: true, encoding: .utf8)
        let theirs = try system(["-Ysign", "-ngit", "-f", path], in: root, input: "payload\n")
        #expect(theirs.code == 0)
        try theirs.out.write(toFile: signature, atomically: true, encoding: .utf8)
        let oursVerified = await command.run(["-Yverify", "-ngit", "-f", allowed, "-Ialice", "-s", signature],
                                             input: "payload\n")
        #expect(oursVerified.code == verified.code && oursVerified.out == verified.out)
        #if !canImport(CryptoKit)
        if type == "ed25519" { #expect(ours.out == theirs.out) }
        #endif
    }

    @Test func gitCommitSignature() async throws {
        let root = try command.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyPath = root.appendingPathComponent("key").path
        #expect(await command.run(["-qt", "ed25519", "-f", keyPath, "-N", ""]).code == 0)
        try system(["init", "-q"], executable: "git", in: root)
        for (name, value) in [("user.name", "Test"), ("user.email", "alice@example.com"),
                              ("gpg.format", "ssh"), ("user.signingkey", keyPath)] {
            #expect(try system(["config", name, value], executable: "git", in: root).code == 0)
        }
        #expect(try system(["commit", "--allow-empty", "-S", "-m", "signed"], executable: "git", in: root).code == 0)
        let object = try system(["cat-file", "commit", "HEAD"], executable: "git", in: root).out
        var payload = "", signature = "", inSignature = false
        for line in object.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            if line.hasPrefix("gpgsig ") {
                inSignature = true
                signature += line.dropFirst(7) + "\n"
            } else if inSignature && line.hasPrefix(" ") { signature += line.dropFirst() + "\n" }
            else { inSignature = false; payload += line + "\n" }
        }
        let sig = root.appendingPathComponent("commit.sig").path
        try signature.write(toFile: sig, atomically: true, encoding: .utf8)
        let allowed = root.appendingPathComponent("allowed").path
        let publicKey = try await IdentityLoader.loadKey(path: keyPath).publicKey
        try ("alice@example.com " + publicKey.openSSHLine()).write(toFile: allowed, atomically: true, encoding: .utf8)
        let verified = await command.run(["-Yverify", "-ngit", "-Ialice@example.com", "-f", allowed, "-s", sig],
                                         input: payload)
        #expect(verified.code == 0 && verified.out.hasPrefix("Good \"git\" signature for alice@example.com"))
    }
}
#endif
