#if !os(Android)
import Foundation
import ShellKit
import Testing
@testable import SSHCommand

@Suite("ssh executable diagnostics")
struct SSHExecutableTests {
    @Test("unknown flag prints OpenSSH usage and exits 255")
    func unknownFlag() async {
        let stdout = OutputSink()
        let stderr = OutputSink()
        let exit = await SSHExecutable.run(
            argv: ["-z"], stdin: .empty, stdout: stdout, stderr: stderr)
        stdout.finish()
        stderr.finish()

        #expect(exit == 255)
        #expect(await stdout.readAllString() == "")
        let diagnostic = await stderr.readAllString()
        #expect(diagnostic.hasPrefix("ssh: illegal option -- z\nusage: ssh "))
        #expect(diagnostic.hasSuffix("       ssh [-Q query_option]\n"))
    }

    @Test("bad port matches OpenSSH and exits 255 without usage")
    func badPort() async {
        let stdout = OutputSink()
        let stderr = OutputSink()
        let exit = await SSHExecutable.run(
            argv: ["-p", "nope", "example.com", "true"],
            stdin: .empty,
            stdout: stdout,
            stderr: stderr)
        stdout.finish()
        stderr.finish()

        #expect(exit == 255)
        #expect(await stderr.readAllString() == "Bad port 'nope'\n")
    }

    @Test("an explicitly selected missing config is fatal")
    func missingExplicitConfig() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-ssh-config-\(UUID().uuidString)").path
        let stdout = OutputSink()
        let stderr = OutputSink()
        let exit = await SSHExecutable.run(
            argv: ["-F", missing, "example.com", "true"],
            stdin: .empty,
            stdout: stdout,
            stderr: stderr)
        stdout.finish()
        stderr.finish()

        #expect(exit == 255)
        #expect(
            await stderr.readAllString()
                == "Can't open user config file \(missing.prefix(100)): No such file or directory\n")
    }
}
#endif
