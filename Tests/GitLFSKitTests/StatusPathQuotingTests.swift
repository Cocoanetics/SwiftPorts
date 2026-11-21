import Testing
@testable import GitLFSKit

@Suite("LFS status diff path quoting")
struct StatusPathQuotingTests {
    @Test func cStyleBytes() {
        let controls = "\u{01}\u{07}\u{08}\t\n\u{0B}\u{0C}\r\u{7F}\"\\"
        let quoted = "\"\\001\\a\\b\\t\\n\\v\\f\\r\\177\\\"\\\\\""
        #expect(StatusOptions.diffPath(controls, quotePath: true) == quoted)
        #expect(StatusOptions.diffPath(controls, quotePath: false) == quoted)
        #expect(StatusOptions.diffPath("space name.dat", quotePath: true) == "space name.dat")
        #expect(StatusOptions.diffPath("café.dat", quotePath: true) == "\"caf\\303\\251.dat\"")
        #expect(StatusOptions.diffPath("café.dat", quotePath: false) == "café.dat")
    }
}
