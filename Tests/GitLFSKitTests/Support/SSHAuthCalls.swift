import Foundation

final class SSHAuthCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var time = Date(timeIntervalSince1970: 1_700_000_000)
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var date: Date { lock.lock(); defer { lock.unlock() }; return time }
    func record() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; time.addTimeInterval(seconds) }
}
