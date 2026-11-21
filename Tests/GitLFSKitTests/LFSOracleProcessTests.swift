#if os(macOS) || os(Linux)
import Foundation
import Testing

@Suite("LFS oracle subprocess capture")
struct LFSOracleProcessTests {
    @Test("stderr larger than a pipe buffer cannot block stdin or stdout", .timeLimit(.minutes(1)))
    func backpressure() throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Write stderr before consuming stdin. Sequential pipe I/O deadlocks
        // here on Linux even if a larger macOS pipe happens to mask the cycle.
        process.arguments = ["-c", "dd if=/dev/zero bs=1048576 count=1 1>&2 2>/dev/null; cat; exit 7"]
        let input = Data(repeating: 0x61, count: 1_048_576)
        let result = try LFSOracleProcess.run(process, input: input, directory: host.root, timeout: 5)
        #expect(result.out == input)
        #expect(result.err.utf8.count == 1_048_576)
        #expect(result.err.utf8.allSatisfy { $0 == 0 })
        #expect(result.status == 7)
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.root.path).sorted() == ["home", "xdg"])
    }

    @Test("a stalled child is killed and reports its stderr rather than hanging the suite", arguments: [false, true])
    func deadline(ignoreTermination: Bool) throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // exec keeps the sleeping child at the PID the runner owns and kills.
        let trap = ignoreTermination ? "trap '' TERM; " : ""
        process.arguments = ["-c", trap + "printf 'rejection diagnostic' >&2; exec sleep 30"]
        let start = ContinuousClock.now
        do {
            _ = try LFSOracleProcess.run(process, directory: host.root, timeout: 0.2)
            Issue.record("A stalled oracle must fail at its deadline")
        } catch let error as LFSOracleFailure {
            #expect(error.description.contains("timed out after"))
            #expect(error.description.contains("rejection diagnostic"))
        }
        #expect(!process.isRunning)
        #expect(start.duration(to: .now) < .seconds(5))
    }
}
#endif
