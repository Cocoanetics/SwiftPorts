import Foundation
import Testing
import ShellKit
import SwiftGit
@testable import GitLFSKit

@Suite("Git LFS command operations without an oracle")
struct CommandBehaviorTests {
    let host = IsolatedLFSHost()

    @Test func pointerChecks() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let path = host.root.appendingPathComponent("pointer")
            let pointer = Pointer(oid: String(repeating: "a", count: 64), size: 10).encoded
            try pointer.write(to: path, atomically: false, encoding: .utf8)
            var options = LFSPointerOptions()
            options.file = path.path
            options.check = true
            options.strict = true
            #expect(try await options.run().status == 0)
            try ("\n" + pointer).write(to: path, atomically: false, encoding: .utf8)
            #expect(try await options.run().status == 2)
            options.strict = false
            #expect(try await options.run().status == 0)
            try "not a pointer".write(to: path, atomically: false, encoding: .utf8)
            let result = try await options.run()
            #expect(result.status == 1 && result.stdout.isEmpty && result.stderr.isEmpty)
        }
    }

    @Test func fileInstallationOutsideRepo() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            var options = FilterOptions()
            options.file = host.root.appendingPathComponent("config").path
            options.skipSmudge = true
            let client = GitClient(workingDirectory: host.root)
            let installed = try await options.install(client)
            #expect(installed.status == 0 && installed.stdout == "Git LFS initialized.\n")
            let file = FilterConfiguration(path: URL(fileURLWithPath: options.file))
            #expect(try file.value("filter.lfs.clean") == "git-lfs clean -- %f")
            #expect(try file.value("filter.lfs.smudge") == "git-lfs smudge --skip -- %f")
            #expect(try file.value("filter.lfs.process") == "git-lfs filter-process --skip")
            #expect(try file.value("filter.lfs.required") == "true")
            #expect(try await options.uninstall(client).status == 0)
            #expect(try String(contentsOfFile: options.file, encoding: .utf8).isEmpty)
        }
    }

    @Test func hooksRefuseForeignScripts() async throws {
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let hook = Hook(type: "pre-push", directory: host.root.appendingPathComponent("hooks"))
            try await hook.install()
            let bytes = try Data(contentsOf: hook.path)
            #expect(bytes == Data((hook.contents + "\n").utf8))
            try "#!/bin/sh\necho foreign\n".write(to: hook.path, atomically: false, encoding: .utf8)
            await #expect(throws: LFSFailure.self) { try await hook.install() }
            #expect(try String(contentsOf: hook.path, encoding: .utf8) == "#!/bin/sh\necho foreign\n")
            try await hook.install(force: true)
            #expect(try Data(contentsOf: hook.path) == bytes)
            try await hook.uninstall()
            #expect(!FileManager.default.fileExists(atPath: hook.path.path))
        }
    }

    @Test("pointer stdin stops at the upstream 1024-byte cutoff", .timeLimit(.minutes(1)))
    func pointerInputCutoff() async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        defer { continuation.finish() }
        let pointer = Pointer(oid: String(repeating: "a", count: 64), size: 10).encoded
        continuation.yield(Data(pointer.utf8) + Data(repeating: 0x20, count: Pointer.blobSizeCutoff))
        let shell = Shell(stdin: InputSource(bytes: stream))
        let result = try await shell.withCurrent {
            var options = LFSPointerOptions()
            options.stdin = true
            options.check = true
            return try await options.run()
        }
        #expect(result.status == 0)
    }
}
