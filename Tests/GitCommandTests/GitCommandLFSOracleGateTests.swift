#if os(macOS) || os(Linux)
import Testing

/// Not gated itself, so a non-reference git-lfs cannot reopen the command and config oracles.
@Suite("git lfs command oracle gate")
struct GitCommandLFSOracleGateTests {
    @Test func onlyThePinnedReleaseEnablesTheOracle() {
        #expect(LFSCommandFixture.isAvailable("git-lfs/3.7.1 (GitHub; darwin arm64; go 1.24.4)\n"))
        #expect(!LFSCommandFixture.isAvailable("git-lfs/3.8.1 (GitHub; darwin arm64; go 1.25.1)\n"))
        #expect(!LFSCommandFixture.isAvailable(nil))
        #expect(LFSCommandFixture.unavailableReason("git-lfs/3.8.1 (GitHub; darwin arm64; go 1.25.1)\n")
                == "oracle needs git-lfs 3.7.1, found 3.8.1")
        #expect(LFSCommandFixture.unavailableReason(nil) == "git-lfs is not on PATH")
    }
}
#endif
