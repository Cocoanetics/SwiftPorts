import Foundation
import ShellKit
import Testing
@testable import GitLFSKit

@Suite("LFS progress meter (git-lfs 3.7.1 tq/meter.go, tasklog)")
struct LFSProgressMeterTests {
    /// A clock tests move by hand.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: @Sendable () -> Date { { self.lock.withLock { self.date } } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    /// The meter's stdout, collected as it is written.
    final class Sink: @unchecked Sendable {
        private let text = TransferTestLock("")
        var write: @Sendable (String) -> Void { { line in self.text.withLock { $0 += line } } }
        func drain() -> String { text.withLock { value in defer { value = "" }; return value } }
    }

    func padded(_ line: String) -> String {
        line + String(repeating: " ", count: 80 - line.count) + "\r"
    }

    @Test(arguments: [
        (UInt64(0), "0 B/s"), (9, "9 B/s"), (999, "999 B/s"), (1000, "1.0 KB/s"),
        (1500, "1.5 KB/s"), (12_345_678, "12 MB/s")
    ])
    func byteRate(_ rate: UInt64, _ expected: String) {
        #expect(ByteFormat.formatByteRate(rate) == expected)
    }

    @Test("off a terminal only the final line is logged, with done")
    func notTerminal() {
        let sink = Sink()
        let meter = LFSProgressMeter(direction: .upload, display: true, logsProgress: false, write: sink.write)
        meter.add(10)
        meter.add(20)
        meter.skip(10)
        meter.startTransfer("b.dat")
        meter.transferBytes("b.dat", read: 20, total: 20, current: 20)
        meter.finishTransfer("b.dat")
        meter.flush()
        #expect(sink.drain() == "")
        meter.finish()
        #expect(sink.drain() == "Uploading LFS objects: 100% (2/2), 30 B | 0 B/s, done.\n")
    }

    @Test("local checkout has its own progress label")
    func checkout() {
        let sink = Sink()
        let meter = LFSProgressMeter(direction: .checkout, display: true, logsProgress: false, write: sink.write)
        meter.add(10)
        meter.skip(10)
        meter.finish()
        #expect(sink.drain() == "Checking out LFS objects: 100% (1/1), 10 B | 0 B/s, done.\n")
    }

    @Test("on a terminal updates are padded, end in a carriage return, and are throttled")
    func terminal() {
        let clock = Clock()
        let sink = Sink()
        let meter = LFSProgressMeter(
            direction: .download, display: true, logsProgress: true, now: clock.now, write: sink.write)
        meter.add(4)
        meter.add(4)
        meter.skip(4)
        clock.advance(0.3)
        meter.startTransfer("a.dat")
        meter.finishTransfer("a.dat")
        #expect(sink.drain() == padded("Downloading LFS objects:   0% (0/1), 0 B | 0 B/s")
            + padded("Downloading LFS objects:  50% (1/2), 4 B | 0 B/s"))
        meter.flush()
        #expect(sink.drain() == padded("Downloading LFS objects: 100% (2/2), 4 B | 0 B/s"))
    }

    @Test("a meter that does not display (dry run, --json) never logs")
    func hidden() {
        let sink = Sink()
        let meter = LFSProgressMeter(direction: .upload, display: false, logsProgress: true, write: sink.write)
        meter.add(1)
        meter.flush()
        meter.finish()
        #expect(sink.drain() == "")
    }

    @Test("a meter with nothing to transfer logs nothing, not even done")
    func empty() {
        let sink = Sink()
        let meter = LFSProgressMeter(direction: .upload, display: true, logsProgress: true, write: sink.write)
        meter.flush()
        meter.finish()
        #expect(sink.drain() == "")
    }

    @Test("while paused the meter keeps its last line")
    func paused() {
        let sink = Sink()
        let meter = LFSProgressMeter(direction: .upload, display: true, logsProgress: false, write: sink.write)
        meter.add(3)
        meter.pause()
        meter.skip(3)
        meter.finish()
        #expect(sink.drain() == "Uploading LFS objects:   0% (0/1), 0 B | 0 B/s, done.\n")
    }

    @Test("the rate is a running average of per-second samples")
    func rate() {
        let clock = Clock()
        let sink = Sink()
        let meter = LFSProgressMeter(
            direction: .download, display: true, logsProgress: false, now: clock.now, write: sink.write)
        meter.add(3000)
        meter.startTransfer("a.dat")
        // The first sample is measured from Go's zero time, so it is zero.
        meter.transferBytes("a.dat", read: 1000, total: 3000, current: 1000)
        clock.advance(2)
        meter.transferBytes("a.dat", read: 3000, total: 3000, current: 2000)
        meter.finishTransfer("a.dat")
        meter.finish()
        #expect(sink.drain() == "Downloading LFS objects: 100% (1/1), 3.0 KB | 500 B/s, done.\n")
    }

    @Test("GIT_LFS_PROGRESS receives one line per chunk of bytes")
    func progressLog() async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let file = host.root.appendingPathComponent("logs/progress.log")
        let sink = Sink()
        _ = try await run(host, ["GIT_LFS_PROGRESS": file.path], sink) { environment in
            let meter = await LFSProgressMeter.make(
                direction: .upload, display: false, terminal: false,
                configuration: LFSConfiguration(), environment: environment)
            meter.add(5)
            meter.startTransfer("a.dat")
            meter.transferBytes("a.dat", read: 2, total: 5, current: 2)
            meter.transferBytes("a.dat", read: 5, total: 5, current: 3)
            meter.finish()
            return meter
        }
        #expect(sink.drain() == "")
        #expect(try String(contentsOf: file, encoding: .utf8) == "upload 1/1 2/5 a.dat\nupload 1/1 5/5 a.dat\n")
    }

    @Test("a relative GIT_LFS_PROGRESS is reported and ignored")
    func relativeProgressLog() async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let clock = LFSTransferClock()
        _ = try await run(host, ["GIT_LFS_PROGRESS": "progress.log"], Sink()) { _ in
            await LFSProgressMeter.make(direction: .download, display: true, terminal: false,
                                        configuration: LFSConfiguration(), environment: clock.environment)
        }
        #expect(clock.stderr == "Error creating progress logger: GIT_LFS_PROGRESS must be an absolute path\n")
    }

    @Test("GIT_LFS_FORCE_PROGRESS logs progress off a terminal")
    func forcedByEnvironment() async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let sink = Sink()
        let meter = try await run(host, ["GIT_LFS_FORCE_PROGRESS": "1"], sink) { environment in
            await LFSProgressMeter.make(direction: .upload, display: true, terminal: false,
                                        configuration: LFSConfiguration(), environment: environment)
        }
        meter.add(1)
        #expect(sink.drain() == padded("Uploading LFS objects:   0% (0/1), 0 B | 0 B/s"))
    }

    @Test("two meters on one GIT_LFS_PROGRESS file both append")
    func progressLogAppends() async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let file = host.root.appendingPathComponent("logs/progress.log")
        try await run(host, ["GIT_LFS_PROGRESS": file.path], Sink()) { environment in
            let first = await LFSProgressMeter.make(
                direction: .upload, display: false, terminal: false,
                configuration: LFSConfiguration(), environment: environment)
            let second = await LFSProgressMeter.make(
                direction: .download, display: false, terminal: false,
                configuration: LFSConfiguration(), environment: environment)
            for meter in [first, second] {
                meter.add(1)
                meter.startTransfer("a.dat")
            }
            first.transferBytes("a.dat", read: 1, total: 1, current: 1)
            second.transferBytes("a.dat", read: 1, total: 1, current: 1)
            first.transferBytes("a.dat", read: 1, total: 1, current: 0)
            first.finish()
            second.finish()
        }
        #expect(try String(contentsOf: file, encoding: .utf8)
            == "upload 1/1 1/1 a.dat\ndownload 1/1 1/1 a.dat\nupload 1/1 1/1 a.dat\n")
    }

    @Test("sizes near Int64.max wrap instead of trapping")
    func hugeSizes() {
        let sink = Sink()
        let meter = LFSProgressMeter(direction: .download, display: true, logsProgress: false, write: sink.write)
        let huge: Int64 = 4_611_686_018_427_387_904
        meter.add(huge)
        meter.add(huge)
        meter.skip(huge)
        meter.skip(huge)
        meter.finish()
        #expect(sink.drain() == "Downloading LFS objects: 100% (2/2), 0 B | 0 B/s, done.\n")
        #expect(ByteFormat.formatBytes(UInt64.max) == "18447 PB")
        #expect(ByteFormat.formatByteRate(UInt64.max) == "18447 PB/s")
    }

    @Test("the default stdout sink is the shell that made the environment, even off its task")
    func boundStdout() async throws {
        let captured = TransferTestLock("")
        let shell = Shell(environment: Environment(variables: [:], workingDirectory: "/"))
        shell.stdout = OutputSink(onWrite: { data in
            captured.withLock { $0 += String(decoding: data, as: UTF8.self) }
        })
        let environment = await shell.withCurrent { LFSTransferEnvironment() }
        // URLSession delegate callbacks run outside the task, without its task-locals.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                environment.stdout("progress\r")
                done.resume()
            }
        }
        #expect(captured.withLock { $0 } == "progress\r")
    }

    private func run<T: Sendable>(
        _ host: IsolatedLFSHost, _ variables: [String: String], _ sink: Sink,
        _ body: (LFSTransferEnvironment) async throws -> T
    ) async throws -> T {
        var environment = LFSTransferEnvironment()
        environment.stdout = sink.write
        let shell = Shell(environment: Environment(
            variables: host.variables.merging(variables) { $1 }, workingDirectory: host.root.path))
        shell.sandbox = host.sandbox
        return try await shell.withCurrent { try await body(environment) }
    }
}
