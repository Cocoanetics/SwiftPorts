import Foundation

/// The net bytes reported sent for one upload attempt. URLSession may report
/// fewer than the body held (or none, for a small body), while a curl redirect
/// rewind reports a negative delta that takes previously reported bytes back.
final class LFSSentBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: Int64 = 0

    var total: Int64 { lock.withLock { sent } }

    func record(delta: Int64) { lock.withLock { sent += delta } }
}
