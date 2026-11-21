import Foundation
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
    }
}
