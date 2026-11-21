import Foundation
import Testing
@testable import GitLFSKit
#if os(macOS) || os(Linux)
import GitLFSTestSupport
#endif

@Suite("LFS progress rate (git-lfs 3.7.1 tq/meter.go)")
struct LFSProgressRateOracleTests {
    /// A clock tests advance deterministically without sleeping.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: @Sendable () -> Date { { self.lock.withLock { self.date } } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    /// The meter's stdout, collected as it is written.
    private final class Sink: @unchecked Sendable {
        private let text = TransferTestLock("")
        var write: @Sendable (String) -> Void { { line in self.text.withLock { $0 += line } } }
        func drain() -> String { text.withLock { value in defer { value = "" }; return value } }
    }

    #if os(macOS) || os(Linux)
    @Test(
        "fast single-object upload matches git-lfs 3.7.1 final 0 B/s meter line",
        .enabled(if: LFSOracle.isVersion371Available, "git-lfs 3.7.1 is not on PATH")
    )
    func fastUploadMatchesGitLFS371() async throws {
        let payload = Data("small lfs object\n".utf8)
        let oid = LFSServerRepository.oid(payload)
        let zero = String(repeating: "0", count: 40)

        let ours = try await LFSTestServer.withServer { server -> LFSCommandResult in
            var captured: LFSCommandResult?
            try await LFSServerRepository.run(server) { repo in
                try await repo.storeLocally(payload)
                let tip = try await repo.commit([("small.dat", payload)])
                let update = LFSRefUpdate(
                    localRef: "refs/heads/main", localOID: tip,
                    remoteRef: "refs/heads/main", remoteOID: zero)
                captured = try await repo.uploadObjects(for: [update], git: repo.git)
                #expect(server.requests().filter { $0.method == "PUT" }.map(\.path) == ["/objects/\(oid)"])
                #expect(server.bytes(for: oid) == payload)
            }
            return try #require(captured)
        }

        let oracle = LFSOracle()
        defer { try? FileManager.default.removeItem(at: oracle.root) }
        func referencePush() async throws -> (out: String, err: String, status: Int32) {
            try await LFSTestServer.withServer { server -> (out: String, err: String, status: Int32) in
                var captured: (out: String, err: String, status: Int32)?
                try await LFSServerRepository.run(server) { repo in
                    try await repo.storeLocally(payload)
                    _ = try await repo.commit([("small.dat", payload)])
                    let run = try oracle.run(["lfs", "push", "origin", "main"], in: repo.directory)
                    captured = (String(decoding: run.out, as: UTF8.self), run.err, run.status)
                    #expect(server.requests().filter { $0.method == "PUT" }.map(\.path) == ["/objects/\(oid)"])
                    #expect(server.bytes(for: oid) == payload)
                }
                return try #require(captured)
            }
        }
        // git-lfs logs the final meter line on a goroutine and returns without
        // waiting. A quiet run usually still flushes it. A busy one often exits
        // first, leaving stdout empty and status 0. Repeat until that line arrives.
        var theirs = try await referencePush()
        if droppedMeter(theirs, against: ours.stdout) {
            for _ in 0..<8 {
                let again = try await referencePush()
                if !again.out.split(separator: "\n").isEmpty {
                    theirs = again
                    break
                }
            }
        }

        #expect(ours.status == 0)
        #expect(ours.stderr == "")
        #expect(theirs.status == 0, "\(theirs.err)")
        #expect(theirs.err == "")

        let ourLine = try #require(ours.stdout.split(separator: "\n").last).description
        let theirLine = try #require(theirs.out.split(separator: "\n").last).description
        #expect(ourLine.contains("| 0 B/s, done."))
        #expect(theirLine.contains("| 0 B/s, done."))
        #expect(ourLine == theirLine)
    }

    /// The reference printed nothing while our side printed one finished meter line.
    private func droppedMeter(
        _ reference: (out: String, err: String, status: Int32), against actual: String
    ) -> Bool {
        guard reference.status == 0, reference.out.split(separator: "\n").isEmpty,
              !actual.isEmpty else { return false }
        return actual.contains("LFS objects:") && actual.hasSuffix(", done.\n")
    }
    #endif

    @Test(
        "multi-second transfer stays 0 B/s on first sample from zero time, then updates running average",
        arguments: [LFSProgressMeter.Direction.upload, .download]
    )
    func multiSecondRunningAverage(_ direction: LFSProgressMeter.Direction) {
        let clock = Clock()
        let sink = Sink()
        let meter = LFSProgressMeter(
            direction: direction, display: true, logsProgress: false, now: clock.now, write: sink.write)
        let label = direction == .upload ? "Uploading LFS objects" : "Downloading LFS objects"

        meter.add(3000)
        meter.startTransfer("a.dat")
        // First sample measures against Go's zero time.Time, so its rate is 0 B/s
        // while sampleCount increments to 1.
        meter.transferBytes("a.dat", read: 1000, total: 3000, current: 1000)
        #expect(meter.text() == "\(label):   0% (0/1), 1.0 KB | 0 B/s")

        // More than 1 second later, 2000 bytes over 2 s gives 1000 B/s for sample 2;
        // averaged with sample 1 (0 B/s) yields 500 B/s.
        clock.advance(2)
        meter.transferBytes("a.dat", read: 3000, total: 3000, current: 2000)
        #expect(meter.text() == "\(label):   0% (0/1), 3.0 KB | 500 B/s")

        meter.finishTransfer("a.dat")
        meter.finish()
        #expect(sink.drain() == "\(label): 100% (1/1), 3.0 KB | 500 B/s, done.\n")
    }
}
