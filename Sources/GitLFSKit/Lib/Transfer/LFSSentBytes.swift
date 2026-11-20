import Foundation

/// The bytes URLSession reported sending for one upload. It may report
/// fewer than the body held (or none, for a small body), while git-lfs's
/// callback reader counts every byte it reads.
final class LFSSentBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: Int64 = 0

    var total: Int64 { lock.withLock { sent } }

    func record(_ total: Int64) { lock.withLock { sent = max(sent, total) } }
}
