#if !os(Android)  // argv-parsing test; ArgumentParser trips the Android explicit-module scanner
import Foundation
import Testing
@testable import GhCommand

/// `GhCommand.preprocess(_:)` — the bare `--json` rewrite shared by
/// the standalone entry point and the shellkit-bridge wrapper in
/// `SwiftPortsCommands` (issue #69). The input is `$@`-shaped: the
/// program name is not part of it, and preprocess must never eat an
/// argument.
@Suite struct GhArgvPreprocessTests {

    @Test func bareJsonAtEndGetsEmptyValue() {
        #expect(GhCommand.preprocess(["run", "list", "--json"])
                == ["run", "list", "--json", ""])
    }

    @Test func bareJsonBeforeFlagGetsEmptyValue() {
        #expect(GhCommand.preprocess(["pr", "list", "--json", "--limit", "5"])
                == ["pr", "list", "--json", "", "--limit", "5"])
    }

    @Test func jsonWithValuePassesThroughUnchanged() {
        let args = ["repo", "view", "odrobnik/libgit2", "--json", "isFork"]
        #expect(GhCommand.preprocess(args) == args)
    }

    @Test func argvWithoutJsonPassesThroughUnchanged() {
        // Regression for the double-drop: the first element is a real
        // argument (subcommand name), not the program name — it must
        // survive preprocessing verbatim.
        let args = ["repo", "view", "odrobnik/libgit2"]
        #expect(GhCommand.preprocess(args) == args)
    }

    @Test func emptyArgvStaysEmpty() {
        #expect(GhCommand.preprocess([]) == [])
    }
}
#endif  // !os(Android)
