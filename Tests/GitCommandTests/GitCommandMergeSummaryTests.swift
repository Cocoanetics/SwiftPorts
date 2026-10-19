// `git merge`'s ` create mode` / ` delete mode` lines in git's order.
import Foundation
import Testing
@testable import GitCommand

@Suite("git merge summary lines")
struct GitCommandMergeSummaryTests {

    @Test("mode lines sort by the paths' bytes, quoted ones as they were before quoting")
    func modeLinesSortRawPaths() {
        let lines = Merge.modeLines([" create mode 100644 \"\\303\\251\"", " create mode 100644 a b"],
                                    [" delete mode 100644 z"])
        #expect(lines == [" create mode 100644 a b", " delete mode 100644 z", " create mode 100644 \"\\303\\251\""])
        #expect(Merge.unquoted("\"tab\\t\\\"q\\\"\\\\\"") == Array("tab\t\"q\"\\".utf8))
        #expect(Merge.unquoted("plain") == Array("plain".utf8))
    }
}
