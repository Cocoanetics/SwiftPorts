// `git push`'s live meter keeps GitKit's framing (issue #264): updates end
// in `\r`, finished phases in `, done.\n`, and neither is rewritten. Fed
// recorded GitKit callback strings — a local-path push never emits them.
import Foundation
import Testing
@testable import SwiftGit

@Suite("git push progress framing")
struct GitCommandPushProgressFramingTests {
    /// The sink's writes, in order.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [String] = []
        var texts: [String] { lock.withLock { written } }
        func append(_ text: String) { lock.withLock { written.append(text) } }
    }

    /// What a sink wrote, one record per callback.
    private func written(_ inputs: [String], by policy: PushProgressSink) -> [String] {
        let records = Recorder()
        let sink = policy.sink(writing: records.append)
        inputs.forEach(sink.write)
        sink.flush()
        return records.texts
    }

    /// `--progress` with stderr not a terminal.
    private let forced = PushProgressSink(reportProgress: true, quiet: false, terminal: false)

    @Test func carriageReturnAndDoneLineRoundTripExactBytes() {
        let inputs = [
            "Compressing objects: 0% (0/4)\r",
            "Compressing objects: 100% (4/4), done.\n"
        ]
        let output = written(inputs, by: forced)
        #expect(output == inputs)
        #expect(Array(output.joined().utf8) == Array(inputs.joined().utf8))
        #expect(Array(output[0].utf8).last == 0x0D)
    }

    @Test func meterUpdateAndRemoteLineStayTwoRecords() {
        let inputs = ["Writing objects: 0% (0/4), 12 bytes\r", "remote: unpack ok\n"]
        #expect(written(inputs, by: forced) == inputs)
    }

    @Test func sidebandContinuationPassesThrough() {
        let inputs = ["remote: Resolving", " deltas: 100% (2/2)\n"]
        #expect(written(inputs, by: forced) == inputs)
    }

    @Test func classification() {
        #expect(PushProgressSink.classify("Counting objects: 50% (1/2)\r") == .update)
        #expect(PushProgressSink.classify("Resolving deltas: 100% (2/2), done.\n") == .phaseComplete)
        #expect(PushProgressSink.classify("Receiving objects: 100% (3/3), done.\n") == .phaseComplete)
        #expect(PushProgressSink.classify("remote: Counting objects: 1\r") == .message)
        #expect(PushProgressSink.classify("To /srv/repo\n") == .message)
        #expect(PushProgressSink.classify("remote: Resolving deltas:  50% (1/2)   \r") == .remoteProgress)
        #expect(PushProgressSink.classify(
            "remote: Receiving objects: 50% (1/2), 1.00 MiB | 2.00 MiB/s\r") == .remoteProgress)
        #expect(PushProgressSink.classify("remote: Unpacking objects: 3, done.\n") == .remoteProgress)
        #expect(PushProgressSink.classify("remote: Checking objects: prohibited file\n") == .message)
        #expect(PushProgressSink.classify("remote: Resolving deltas:5%\n") == .message)
        #expect(PushProgressSink.classify("   6bfcd70..8124fb4  main -> main\n") == .message)
    }
}
