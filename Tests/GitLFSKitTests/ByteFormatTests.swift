import Testing
@testable import GitLFSKit

@Suite("git-lfs decimal byte formatting")
struct ByteFormatTests {
    @Test(arguments: [
        (UInt64(0), "0 B"), (1, "1 B"), (9, "9 B"), (10, "10 B"), (999, "999 B"),
        (1000, "1.0 KB"), (1049, "1.0 KB"), (1050, "1.1 KB"), (1490, "1.5 KB"), (1510, "1.5 KB"),
        (9949, "9.9 KB"), (9950, "10 KB"), (10000, "10 KB"),
        (10450, "10 KB"), (10500, "10 KB"), (10550, "11 KB"),
        (999999, "1000 KB"), (1000000, "1.0 MB"),
        (1000000000, "1.0 GB"), (1000000000000, "1.0 TB"), (1000000000000000, "1.0 PB")
    ])
    func boundaries(_ size: UInt64, _ expected: String) {
        #expect(ByteFormat.formatBytes(size) == expected)
    }
}
