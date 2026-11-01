// OpenPGP verification of signed tags (#141), with a stand-in `gpg`
// script so no test needs a local gpg. The system `git` sets the
// repositories up.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ShellKit
@testable import SwiftGit

@Suite("GitClient.verifyTag / signed-tag merge messages")
struct GitClientVerifyTagTests {

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @discardableResult
    private func systemGit(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com"] + args
        process.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "git \(args.joined(separator: " ")): \(message)")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A stand-in for gpg printing `stderr` and `status` lines and
    /// exiting with `code`, in its own directory.
    private func fakeGPG(stderr: String, status: [String], code: Int32 = 0) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FakeGPG-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("gpg")
        let lines = status.map { "echo '[GNUPG:] \($0)'" }.joined(separator: "\n")
        try """
            #!/bin/sh
            cat >/dev/null
            echo '\(stderr)' >&2
            \(lines)
            exit \(code)
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private static let good = ["NEWSIG", "GOODSIG ABCD1234 Tester <t@e>", "VALIDSIG FPR 2020-01-01 1 0 4 0 1 8 PRIM",
                               "TRUST_ULTIMATE"]

    /// A repository with a lightweight tag `light`, an unsigned annotated
    /// tag `annotated`, and a tag object `signed` that carries an
    /// OpenPGP signature block (a verifier is what judges it).
    private func makeRepo(program: URL?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VerifyTag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try systemGit(["init", "-q", "-b", "main"], in: dir)
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try systemGit(["add", "."], in: dir)
        try systemGit(["commit", "-q", "-m", "init"], in: dir)
        try systemGit(["tag", "light"], in: dir)
        try systemGit(["tag", "-a", "-m", "annotated message", "annotated"], in: dir)
        try addSignedTag("signed", message: "signed message", in: dir)
        if let program { try systemGit(["config", "gpg.program", program.path], in: dir) }
        return dir
    }

    private func addSignedTag(_ name: String, message: String, in dir: URL) throws {
        let commit = try systemGit(["rev-parse", "HEAD"], in: dir)
        let object = """
            object \(commit)
            type commit
            tag \(name)
            tagger Test <test@example.com> 1700000000 +0000

            \(message)
            -----BEGIN PGP SIGNATURE-----

            abc
            -----END PGP SIGNATURE-----

            """
        let file = dir.appendingPathComponent(".tagobject-\(name)")
        try object.write(to: file, atomically: true, encoding: .utf8)
        let oid = try systemGit(["hash-object", "-t", "tag", "-w", file.path], in: dir)
        try FileManager.default.removeItem(at: file)
        try systemGit(["update-ref", "refs/tags/\(name)", oid], in: dir)
    }

    @Test("a valid signature verifies, the program's diagnostics are kept")
    func validSignature() async throws {
        let gpg = try fakeGPG(stderr: "gpg: Good signature", status: Self.good)
        let repo = try makeRepo(program: gpg)
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try await SwiftGit.GitClient(workingDirectory: repo).verifyTag("signed")
        guard case .checked(_, let check) = result else { throw Failure(description: "not checked: \(result)") }
        #expect(check.succeeded)
        #expect(check.output == "gpg: Good signature\n")
        #expect(check.status.contains("\n[GNUPG:] GOODSIG "))
        #expect(String(decoding: check.payload, as: UTF8.self).hasSuffix("signed message\n"))
    }

    @Test("a bad signature, and one whose key is missing, fail with the program's words")
    func badAndUnavailable() async throws {
        let bad = try fakeGPG(stderr: "gpg: BAD signature", status: ["NEWSIG", "BADSIG ABCD1234 Tester <t@e>"], code: 1)
        let missing = try fakeGPG(stderr: "gpg: No public key",
                                  status: ["NEWSIG", "ERRSIG ABCD1234 1 8 00 1700000000 9", "NO_PUBKEY ABCD1234"],
                                  code: 2)
        for (program, words) in [(bad, "BAD signature"), (missing, "No public key")] {
            let repo = try makeRepo(program: program)
            defer { try? FileManager.default.removeItem(at: repo) }
            let result = try await SwiftGit.GitClient(workingDirectory: repo).verifyTag("signed")
            guard case .checked(_, let check) = result else { throw Failure(description: "not checked") }
            #expect(!check.succeeded)
            #expect(check.output?.contains(words) == true)
        }
    }

    @Test("a good signature below gpg.minTrustLevel fails")
    func minimumTrust() async throws {
        let marginal = try fakeGPG(stderr: "gpg: Good", status: ["NEWSIG", "GOODSIG A U", "VALIDSIG F 1", "TRUST_MARGINAL 0 pgp"])
        let repo = try makeRepo(program: marginal)
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = SwiftGit.GitClient(workingDirectory: repo)
        #expect(try await client.verifyTag("signed").succeeded)
        try systemGit(["config", "gpg.minTrustLevel", "fully"], in: repo)
        #expect(try await client.verifyTag("signed").succeeded == false)
    }

    @Test("lightweight, unsigned annotated and missing tags")
    func unsignedAndMissing() async throws {
        let repo = try makeRepo(program: try fakeGPG(stderr: "", status: Self.good))
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = SwiftGit.GitClient(workingDirectory: repo)
        guard case .notATag(let type) = try await client.verifyTag("light") else { throw Failure(description: "light") }
        #expect(type == "commit")
        guard case .unsigned = try await client.verifyTag("annotated") else { throw Failure(description: "annotated") }
        guard case .notFound = try await client.verifyTag("nope") else { throw Failure(description: "nope") }
    }

    /// Runs `body` in a shell that has the given launcher, and returns
    /// what it wrote to stderr.
    private func stderr(
        launcher: (any ProcessLauncher)? = nil, in dir: URL, _ body: @escaping () async throws -> Void
    ) async throws -> String {
        let err = OutputSink()
        let shell = Shell(stderr: err, environment: Environment(workingDirectory: dir.path), processLauncher: launcher)
        try await shell.withCurrent(body)
        err.finish()
        return await err.readAllString()
    }

    @Test("openPGPTagVerificationUnavailableProgram")
    func openPGPTagVerificationUnavailableProgram() async throws {
        let repo = try makeRepo(program: nil)
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = SwiftGit.GitClient(workingDirectory: repo)
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("NotExecutable-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: plain)
        defer { try? FileManager.default.removeItem(at: plain) }
        let cases: [(program: String, message: String)] = [
            ("/nonexistent/gpg", "fatal: cannot exec '/nonexistent/gpg': No such file or directory\n"),
            ("nonexistent-gpg-program", "error: cannot run nonexistent-gpg-program: No such file or directory\n"),
            (plain.path, "fatal: cannot exec '\(plain.path)': Permission denied\n"),
        ]
        for (program, message) in cases {
            try systemGit(["config", "gpg.openpgp.program", program], in: repo)
            var result: SwiftGit.GitClient.TagVerification?
            let printed = try await stderr(in: repo) { result = try await client.verifyTag("signed") }
            #expect(printed == message)
            #expect(result?.succeeded == false)
        }
    }

    @Test("a shell that refuses processes fails verification, never skips it")
    func refusedProcess() async throws {
        let repo = try makeRepo(program: try fakeGPG(stderr: "", status: Self.good))
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = SwiftGit.GitClient(workingDirectory: repo)
        var result: SwiftGit.GitClient.TagVerification?
        let printed = try await stderr(launcher: SandboxedDenyLauncher(reason: "no processes"), in: repo) {
            result = try await client.verifyTag("signed")
        }
        #expect(printed.hasPrefix("error: cannot run "))
        #expect(printed.contains("no processes"))
        #expect(result?.succeeded == false)
        // The merge message says verification failed, not that it passed.
        let message = try await stderr(launcher: SandboxedDenyLauncher(), in: repo) {
            let text = try await client.mergeMessage(describing: ["tag 'signed'"],
                                                     objects: [try await client.resolveOID("signed")])
            #expect(text.contains("# -----BEGIN PGP SIGNATURE-----"))
            #expect(!text.contains("Good signature"))
        }
        #expect(message.hasPrefix("error: cannot run "))
    }

    @Test("merge message: a signed tag's signature and the verifier's words follow, commented")
    func signedTagTemplate() async throws {
        let gpg = try fakeGPG(stderr: "gpg: Good signature", status: Self.good)
        let repo = try makeRepo(program: gpg)
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = SwiftGit.GitClient(workingDirectory: repo)
        let signed = try await client.resolveOID("signed")
        let annotated = try await client.resolveOID("annotated")
        let single = try await client.mergeMessage(describing: ["tag 'signed'"], objects: [signed])
        #expect(single == """
            Merge tag 'signed'

            signed message

            # -----BEGIN PGP SIGNATURE-----
            #
            # abc
            # -----END PGP SIGNATURE-----
            # gpg: Good signature
            """)
        // An unsigned annotated tag has its message only.
        #expect(try await client.mergeMessage(describing: ["tag 'annotated'"], objects: [annotated])
            == "Merge tag 'annotated'\n\nannotated message")
        // Several tags: each under a comment naming it.
        try systemGit(["config", "core.commentChar", ";"], in: repo)
        let octopus = try await client.mergeMessage(
            describing: ["tag 'signed'", "tag 'annotated'"], objects: [signed, annotated])
        #expect(octopus == """
            Merge tags 'signed' and 'annotated'

            ; tag 'signed'
            signed message

            ; -----BEGIN PGP SIGNATURE-----
            ;
            ; abc
            ; -----END PGP SIGNATURE-----
            ; gpg: Good signature

            ; tag 'annotated'
            annotated message
            """)
    }

    @Test("merge message: the verifier's words follow a bad signature")
    func failedVerificationText() async throws {
        let repo = try makeRepo(program: try fakeGPG(stderr: "gpg: BAD signature",
                                                     status: ["NEWSIG", "BADSIG A U"], code: 1))
        defer { try? FileManager.default.removeItem(at: repo) }
        let client = SwiftGit.GitClient(workingDirectory: repo)
        let text = try await client.mergeMessage(describing: ["tag 'signed'"],
                                                 objects: [try await client.resolveOID("signed")])
        #expect(text.hasSuffix("# -----END PGP SIGNATURE-----\n# gpg: BAD signature"))
    }
}
#endif
