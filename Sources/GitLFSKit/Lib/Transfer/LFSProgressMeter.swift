import Foundation
import ShellKit

/// `tq.Meter` as drained by a `tasklog.Logger`. Progress lines are padded to
/// the terminal width and end in `\r`; they are logged only when stdout is a
/// terminal or progress is forced (`GIT_LFS_FORCE_PROGRESS` / `lfs.forceprogress`),
/// at most every 200 ms unless flushed. ``finish()`` logs the last line with
/// `, done.` whether or not stdout is a terminal. A meter whose `display` is
/// false (git-lfs's `Meter.DryRun`) never logs. `GIT_LFS_PROGRESS` names a
/// file that receives one line per chunk of transferred bytes.
final class LFSProgressMeter: @unchecked Sendable {
    static let throttle: TimeInterval = 0.2
    /// Go's zero `time.Time`, where `lastAvg` starts.
    private static let zeroTime = Date(timeIntervalSince1970: -62_135_596_800)

    let direction: LFSTransferDirection
    private let display: Bool
    private let logsProgress: Bool
    private let width: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var log: FileHandle?

    private var finishedFiles: Int64 = 0
    private var transferringFiles: Int64 = 0
    private var estimatedFiles: Int64 = 0
    private var estimatedBytes: Int64 = 0
    private var currentBytes: Int64 = 0
    private var lastBytes: Int64 = 0
    private var sampleCount: Double = 0
    private var averageBytes: Double = 0
    private var lastAverage = LFSProgressMeter.zeroTime
    private var paused = false
    private var fileIndex: [String: Int64] = [:]
    private var lastLogged = LFSProgressMeter.zeroTime
    private var lastUpdate: String?
    private var output = ""

    init(
        direction: LFSTransferDirection, display: Bool, logsProgress: Bool, width: Int = 80,
        log: FileHandle? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.direction = direction
        self.display = display
        self.logsProgress = logsProgress
        self.width = width
        self.log = log
        self.now = now
    }

    /// `buildProgressMeter` plus the logger's `ForceProgress` option.
    static func make(
        direction: LFSTransferDirection, display: Bool, terminal: Bool,
        configuration: LFSConfiguration, environment: LFSTransferEnvironment
    ) async -> LFSProgressMeter {
        let forced = LFSConfiguration.bool(Shell.env("GIT_LFS_FORCE_PROGRESS"), fallback: false)
            || configuration.boolean("lfs.forceprogress")
        return LFSProgressMeter(
            direction: direction, display: display, logsProgress: terminal || forced,
            log: await progressLog(environment), now: environment.now)
    }

    /// `Meter.LoggerFromEnv`.
    private static func progressLog(_ environment: LFSTransferEnvironment) async -> FileHandle? {
        guard let name = Shell.env("GIT_LFS_PROGRESS"), !name.isEmpty else { return nil }
        func failed(_ message: String) -> FileHandle? {
            environment.stderr("Error creating progress logger: \(message)\n")
            return nil
        }
        guard (name as NSString).isAbsolutePath else {
            return failed("GIT_LFS_PROGRESS must be an absolute path")
        }
        let file = URL(fileURLWithPath: name)
        do {
            try await LocalStore.makeDirectory(file.deletingLastPathComponent())
            try await Shell.authorize(file)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            return handle
        } catch {
            return failed(String(describing: error))
        }
    }

    /// The text logged so far, which is then cleared.
    func drain() -> String {
        lock.withLock {
            defer { output = "" }
            return output
        }
    }

    func start() { lock.withLock { paused = false } }

    func pause() { lock.withLock { paused = true } }

    func add(_ size: Int64) {
        lock.withLock {
            estimatedFiles += 1
            estimatedBytes += size
            update(force: false)
        }
    }

    func skip(_ size: Int64) {
        lock.withLock {
            finishedFiles += 1
            currentBytes += size
            update(force: false)
        }
    }

    func startTransfer(_ name: String) {
        lock.withLock {
            transferringFiles += 1
            fileIndex[name] = transferringFiles
            update(force: false)
        }
    }

    func transferBytes(_ name: String, read: Int64, total: Int64, current: Int64) {
        lock.withLock {
            let now = now()
            let since = now.timeIntervalSince(lastAverage)
            currentBytes += current
            lastBytes += current
            if since > 1 {
                lastAverage = now
                let rate = Double(lastBytes) / since
                averageBytes = (averageBytes * sampleCount + rate) / (sampleCount + 1)
                lastBytes = 0
                sampleCount += 1
            }
            logBytes(name, read: read, total: total)
            update(force: false)
        }
    }

    func finishTransfer(_ name: String) {
        lock.withLock {
            finishedFiles += 1
            fileIndex[name] = nil
            update(force: false)
        }
    }

    func flush() { lock.withLock { update(force: true) } }

    func finish() {
        lock.withLock {
            update(force: false)
            if let lastUpdate { output += lastUpdate + ", done.\n" }
            try? log?.close()
            log = nil
        }
    }

    /// `Meter.update` and `Logger.logTask`. Callers hold `lock`.
    private func update(force: Bool) {
        guard display, estimatedFiles != 0, !paused else { return }
        let line = text()
        let at = now()
        lastUpdate = line
        guard logsProgress else { return }
        if force || at > lastLogged.addingTimeInterval(Self.throttle) {
            output += line + String(repeating: " ", count: max(0, width - line.utf8.count)) + "\r"
            lastLogged = at
        }
    }

    /// `(Uploading|Downloading) LFS objects: 100% (10/10), 100 MB | 10 MB/s`.
    func text() -> String {
        let percentage = 100 * Double(finishedFiles) / Double(estimatedFiles)
        let label = direction == .download ? "Downloading LFS objects" : "Uploading LFS objects"
        let percent = String(format: "%3.f", locale: Locale(identifier: "en_US_POSIX"), percentage)
        let rate = averageBytes < 0 ? 0 : UInt64(min(averageBytes, Double(UInt64.max)))
        return "\(label): \(percent)% (\(finishedFiles)/\(estimatedFiles)), "
            + "\(ByteFormat.formatBytes(UInt64(max(0, currentBytes)))) | \(ByteFormat.formatByteRate(rate))"
    }

    private func logBytes(_ name: String, read: Int64, total: Int64) {
        guard let log else { return }
        let index = fileIndex[name] ?? 0
        let line = "\(direction.rawValue) \(index)/\(estimatedFiles) \(read)/\(total) \(name)\n"
        do {
            try log.write(contentsOf: Data(line.utf8))
        } catch {
            self.log = nil
        }
    }
}
