import Foundation
import ShellKit
import Testing
@testable import GitLFSKit

/// Which pre-push scripts `git push` takes for git-lfs's (issue #234).
@Suite("Hook pre-push detection")
struct HookPrePushTests {
    @Test func installedAndHistoricalScripts() {
        let directory = URL(fileURLWithPath: "/hooks")
        #expect(Hook.runsLFSPrePush(Hook(type: "pre-push", directory: directory).contents))
        #expect(Hook.runsLFSPrePush("#!/bin/sh\ngit lfs push --stdin $*\n"))
        #expect(Hook.runsLFSPrePush("#!/bin/sh\nset -e\n  exec git-lfs pre-push \"$@\"\n"))
    }

    @Test func foreignScripts() {
        #expect(!Hook.runsLFSPrePush("#!/bin/sh\necho custom\n"))
        #expect(!Hook.runsLFSPrePush("#!/bin/sh\n# git lfs pre-push \"$@\"\n  # git-lfs pre-push\nexit 0\n"))
        #expect(!Hook.runsLFSPrePush(""))
        // A trailing comment runs nothing either.
        #expect(!Hook.runsLFSPrePush("#!/bin/sh\nexit 1 # git lfs pre-push \"$@\"\n"))
        #expect(!Hook.runsLFSPrePush("#!/bin/sh\necho 'git lfs pre-push'\n"))
        #expect(!Hook.runsLFSPrePush("#!/bin/sh\ngit lfs pre-pushed\n"))
    }

    /// The sandbox refusing the hook stops the push rather than reading as
    /// no hook, which would push without uploading.
    @Test func refusedHookThrows() async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let (directory, client) = try await host.run { try await LFSFixture.make(host, "hook") }
        let hooks = directory.appendingPathComponent(".git/hooks")
        let installed = try await host.run { () -> Hook? in
            try await Hook(type: "pre-push", directory: hooks).install()
            return try await Hook.lfsPrePush(client)
        }
        #expect(installed?.path.lastPathComponent == "pre-push")
        let shell = Shell(environment: Environment(variables: host.variables, workingDirectory: directory.path))
        shell.sandbox = host.sandbox(refusing: { $0.lastPathComponent == "pre-push" })
        await #expect(throws: Sandbox.Denial.self) {
            try await shell.withCurrent { _ = try await Hook.lfsPrePush(client) }
        }
    }
}
